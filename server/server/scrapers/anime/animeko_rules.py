"""animeko-subs 规则库:订阅拉取、三级信封解析与规则模型。

规则库是 Animeko 客户端的订阅文件(``schemaVersion`` 2)。它把「怎么在某个站点上
搜索 → 拿到条目 → 列线路与剧集 → 从播放页提取视频地址」这一整套站点知识写成
数据,因此本模块只做**数据建模**,不碰 DOM 也不发播放请求(那在 ``animeko_engines``)。

三级信封(实测 __SUB_URL__)::

    {"schemaVersion": 2,
     "mediaSources": [...],                      # 现行字段:21 个
     "exportedMediaSourceDataList": {...}}       # 旧字段:18 个

两个字段的关系不是"新旧的副本":``mediaSources`` 里多出 3 个源
(``xifan-dongman-next`` / ``2k-dongman`` / ``anime7``),且 ``girigiri-ai-dongman``
在两边的 ``arguments`` 完全不同(现行版走 m3u8 API,旧版走 HTML 搜索页)。
上游 ``SubscriptionUpdateDataReader`` 的读取顺序是
``mediaSources`` 优先、``exportedMediaSourceDataList.mediaSources`` 兜底,
本模块照抄该优先级,避免用旧配置覆盖新配置。

单个 source 的形态与上游 ``ExportedMediaSourceData`` 一致::

    {"id", "factoryId", "version", "arguments", "tags"?}

``factoryId`` 决定用哪个引擎执行:``web-selector`` / ``json-api`` / ``rss``。
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from dataclasses import field

from pydantic.dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

import httpx

from ... import config

logger = logging.getLogger(__name__)

#: Azusa(Kotlin/Java)命名捕获组写法 → Python 写法。
#  规则里的 ``matchVideoUrl`` 普遍用 ``(?<v>...)`` 标出"哪一个子串才是真正的
#  视频地址";Python 的 ``re`` 只认 ``(?P<v>...)``。这层改写是**机械**的:
#  实测 86 个正则改完全部可编译,不做任何语义调整。
_AZUSA_NAMED_GROUP_RE = re.compile(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>")

#: 行内开关 (``(?i)`` 等)。Java 允许写在任意位置,Python 只允许在最前面。
_INLINE_FLAG_RE = re.compile(r"\(\?([aiLmsux]+)\)")


def rewrite_azusa_named_groups(pattern: str) -> str:
    """把 ``(?<name>...)`` 改写成 ``(?P<name>...)``,其余字符原样保留。"""
    return _AZUSA_NAMED_GROUP_RE.sub(r"(?P<\1>", pattern or "")


def compile_rule_pattern(pattern: str) -> Optional[re.Pattern[str]]:
    """编译规则里的正则;非法模式返回 ``None`` 而不是抛异常。

    站点规则是外部数据,一条写坏的正则只应该让**那一条规则**不可用,
    不能让整个规则库或整轮搜索炸掉。同样地,行内开关被提到最前面,
    因为 Java 允许 ``^abc(?i)`` 这种写法而 Python 不允许。
    """
    text = (pattern or "").strip()
    if not text:
        return None
    rewritten = rewrite_azusa_named_groups(text)
    flags = 0
    if "(?" in rewritten:
        collected: list[str] = []

        def _collect(match: re.Match[str]) -> str:
            collected.append(match.group(1))
            return ""

        body = _INLINE_FLAG_RE.sub(_collect, rewritten)
        for letters in collected:
            for letter in letters:
                if letter == "i":
                    flags |= re.IGNORECASE
                elif letter == "m":
                    flags |= re.MULTILINE
                elif letter == "s":
                    flags |= re.DOTALL
                elif letter == "x":
                    flags |= re.VERBOSE
                # a / L / u 在 Python 里语义不同或被默认启用,忽略即可。
        rewritten = body
    try:
        return re.compile(rewritten, flags)
    except re.error as error:
        logger.debug("规则正则无法编译(%s): %s", type(error).__name__, text[:80])
        return None


def _as_str(value: Any, default: str = "") -> str:
    if value is None:
        return default
    if isinstance(value, str):
        return value
    return str(value)


def _as_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off", ""}:
            return False
    if isinstance(value, (int, float)):
        return bool(value)
    return default


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _as_mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_str_tuple(value: Any) -> tuple[str, ...]:
    if isinstance(value, (list, tuple)):
        return tuple(item for item in (_as_str(item).strip() for item in value) if item)
    text = _as_str(value).strip()
    return (text,) if text else ()


# ── 条目(搜索结果)格式 ─────────────────────────────────────────────


@dataclass(frozen=True)
class SubjectFormatA:
    """搜索结果页里直接选出一批 ``<a>``:文本作名字,``href`` 作链接。"""

    select_lists: str = ""
    link_template: str = ""


@dataclass(frozen=True)
class SubjectFormatIndexed:
    """两个并列的 CSS 语句按**下标**配对:一边是名字,一边是链接。"""

    select_names: str = ""
    select_links: str = ""
    link_template: str = ""


@dataclass(frozen=True)
class SubjectFormatJsonPathIndexed:
    """搜索接口返回 JSON;用 JSONPath 分别取名字与 id,再靠模板拼详情页地址。"""

    select_names: str = ""
    select_links: str = ""
    link_template: str = ""


# ── 线路/剧集格式 ──────────────────────────────────────────────────


@dataclass(frozen=True)
class ChannelFormatIndexGrouped:
    """tab + 分页形式:线路名与剧集容器按**下标**一一对应。"""

    select_channel_names: str = ""
    match_channel_name: str = ""
    select_episode_lists: str = ""
    select_episodes_from_list: str = ""
    select_episode_links_from_list: str = ""
    match_episode_sort_from_name: str = ""


@dataclass(frozen=True)
class ChannelFormatNoChannel:
    """页面没有线路概念,只有一列剧集。"""

    select_episodes: str = ""
    select_episode_links: str = ""
    match_episode_sort_from_name: str = ""


# ── 视频地址匹配 ───────────────────────────────────────────────────


@dataclass(frozen=True)
class MatchVideoConfig:
    """从播放页里认出视频地址的规则,以及取流时必须带上的请求头。"""

    enable_nested_url: bool = True
    match_nested_url: str = ""
    match_video_url: str = ""
    #: 站点给播放器的 cookie 串(如 ``quality=1080P``)。必须转发到**每一个**
    #  分片请求,只带给播放页会让 CDN 回 403。
    cookies: str = ""
    referer: str = ""
    user_agent: str = ""

    @property
    def nested_pattern(self) -> Optional[re.Pattern[str]]:
        return compile_rule_pattern(self.match_nested_url)

    @property
    def video_pattern(self) -> Optional[re.Pattern[str]]:
        return compile_rule_pattern(self.match_video_url)

    @property
    def cookie_header(self) -> str:
        """把规则里的多行/分号 cookie 规范成单行 ``k=v; k2=v2``。"""
        items: list[str] = []
        for chunk in re.split(r"[\n;]+", self.cookies or ""):
            piece = chunk.strip()
            if piece and "=" in piece and piece not in items:
                items.append(piece)
        return "; ".join(items)


# ── 自动匹配层(节流与关键词归一化) ────────────────────────────────


@dataclass(frozen=True)
class AutoMatchConfig:
    """``autoMatch`` 字段;6.2 以前平铺在 ``searchConfig`` 顶层,两者都读。"""

    search_use_only_first_word: bool = True
    search_remove_special: bool = True
    search_use_subject_names_count: int = 1
    prefer_shorter_name: bool = True
    filter_by_episode_sort: bool = True


@dataclass(frozen=True)
class SelectMediaConfig:
    distinguish_subject_name: bool = True
    distinguish_channel_name: bool = True


# ── web-selector 整体配置 ──────────────────────────────────────────


@dataclass(frozen=True)
class SelectorSearchConfig:
    """``factoryId == "web-selector"`` 的 ``arguments.searchConfig``。"""

    search_url: str = ""
    raw_base_url: str = ""
    request_interval_ms: int = 3000
    search_cache_ttl_ms: int = 2 * 3600 * 1000
    user_agent: str = ""
    subject_format_id: str = "a"
    subject_format_a: SubjectFormatA = field(default_factory=SubjectFormatA)
    subject_format_indexed: SubjectFormatIndexed = field(
        default_factory=SubjectFormatIndexed
    )
    subject_format_json_path: SubjectFormatJsonPathIndexed = field(
        default_factory=SubjectFormatJsonPathIndexed
    )
    channel_format_id: str = "no-channel"
    channel_format_index_grouped: ChannelFormatIndexGrouped = field(
        default_factory=ChannelFormatIndexGrouped
    )
    channel_format_no_channel: ChannelFormatNoChannel = field(
        default_factory=ChannelFormatNoChannel
    )
    default_resolution: str = "1080P"
    default_subtitle_language: str = "CHS"
    only_supports_players: tuple[str, ...] = ()
    select_media: SelectMediaConfig = field(default_factory=SelectMediaConfig)
    match_video: MatchVideoConfig = field(default_factory=MatchVideoConfig)
    auto_match: AutoMatchConfig = field(default_factory=AutoMatchConfig)

    @property
    def final_base_url(self) -> str:
        """相对链接的解析基准:``rawBaseUrl`` 优先,为空时从 ``searchUrl`` 猜源站根。

        上游 ``SelectorSearchConfig.finalBaseUrl`` 就是这个语义;许多源的
        ``searchUrl`` 指向接口路径(``/api.php/Vod/get_list``),只有
        ``rawBaseUrl`` 才给出真正的站点根,所以不能用 searchUrl 的目录。
        """
        explicit = (self.raw_base_url or "").strip()
        if explicit:
            return explicit.rstrip("/")
        return guess_base_url(self.search_url)

    @property
    def user_agent_or_none(self) -> Optional[str]:
        value = (self.user_agent or "").strip()
        return value or None

    @property
    def request_interval_seconds(self) -> float:
        return max(0.0, self.request_interval_ms / 1000.0)

    @property
    def search_cache_ttl_seconds(self) -> float:
        return max(0.0, self.search_cache_ttl_ms / 1000.0)


def guess_base_url(search_url: str) -> str:
    """从 ``searchUrl`` 取 ``scheme://host[:port]``;解析失败时退化为去尾斜杠。"""
    text = (search_url or "").strip()
    if not text:
        return ""
    try:
        parsed = httpx.URL(text)
        if parsed.host:
            port = f":{parsed.port}" if parsed.port else ""
            return f"{parsed.scheme}://{parsed.host}{port}"
    except (TypeError, ValueError):
        pass
    index = text.find("//")
    if index == -1:
        return text.rstrip("/")
    slash = text.find("/", index + 2)
    return text if slash == -1 else text[:slash]


# ── json-api 配置 ─────────────────────────────────────────────────


@dataclass(frozen=True)
class JsonApiRequestConfig:
    url: str = ""
    method: str = "GET"
    body: str = ""
    headers: str = ""


@dataclass(frozen=True)
class JsonApiEpisodesConfig:
    request: JsonApiRequestConfig = field(default_factory=JsonApiRequestConfig)
    select_episodes: str = ""
    select_name: str = ""
    select_id: str = ""
    select_sort: str = ""
    select_type: str = ""
    type_mapping: str = ""
    name_template: str = ""
    episode_url_template: str = ""


@dataclass(frozen=True)
class JsonApiSearchConfig:
    """``factoryId == "json-api"`` 的 ``arguments.searchConfig``。

    与 web-selector 的差别:所有阶段都用**声明式请求模板**驱动,响应一律
    JSONPath 解析,不再有 DOM。
    """

    base_url: str = ""
    headers: str = ""
    user_agent: str = ""
    request_interval_ms: int = 3000
    search_cache_ttl_ms: int = 2 * 3600 * 1000
    default_resolution: str = "1080P"
    default_subtitle_language: str = "CHS"
    search_request: JsonApiRequestConfig = field(default_factory=JsonApiRequestConfig)
    page_size: int = 20
    select_items: str = ""
    select_name: str = ""
    select_id: str = ""
    subject_url_template: str = ""
    subject_request: JsonApiRequestConfig = field(default_factory=JsonApiRequestConfig)
    channel_format_id: str = ""
    select_channels: str = ""
    select_channel_name: str = ""
    episodes: JsonApiEpisodesConfig = field(default_factory=JsonApiEpisodesConfig)
    play_request: JsonApiRequestConfig = field(default_factory=JsonApiRequestConfig)
    select_candidates: str = ""
    select_candidate_channel: str = ""
    select_video_url: str = ""
    fallback_to_first_candidate: bool = False
    play_referer: str = ""
    auto_match: AutoMatchConfig = field(default_factory=AutoMatchConfig)

    @property
    def request_interval_seconds(self) -> float:
        return max(0.0, self.request_interval_ms / 1000.0)

    @property
    def user_agent_or_none(self) -> Optional[str]:
        value = (self.user_agent or "").strip()
        return value or None


@dataclass(frozen=True)
class RssSearchConfig:
    """``factoryId == "rss"`` 的 ``arguments.searchConfig``(BT 站)。"""

    search_url: str = ""
    filter_by_episode_sort: bool = True
    filter_by_subject_name: bool = True

    @property
    def request_interval_seconds(self) -> float:
        # BT 站没有声明 requestInterval;它们本身就是聚合器,给一个温和的默认值。
        return 1.0


# ── 规则 ──────────────────────────────────────────────────────────


@dataclass(frozen=True)
class MediaSourceRule:
    """一条媒体源规则。``factory_id`` 决定交给哪个引擎执行。"""

    id: str
    factory_id: str
    version: int = 1
    name: str = ""
    description: str = ""
    icon_url: str = ""
    tier: int = 0
    tags: tuple[str, ...] = ()
    channel_tiers: dict[str, int] = field(default_factory=dict)
    selector: Optional[SelectorSearchConfig] = None
    json_api: Optional[JsonApiSearchConfig] = None
    rss: Optional[RssSearchConfig] = None

    @property
    def display_name(self) -> str:
        return self.name or self.id

    @property
    def request_interval_seconds(self) -> float:
        if self.selector is not None:
            return self.selector.request_interval_seconds
        if self.json_api is not None:
            return self.json_api.request_interval_seconds
        if self.rss is not None:
            return self.rss.request_interval_seconds
        return 0.0

    @property
    def is_playable(self) -> bool:
        """能否产出 m3u8/mp4。RSS 规则只给 BT 资源,没有直链播放链。"""
        return self.selector is not None or self.json_api is not None

    def channel_tier(self, channel: Optional[str]) -> int:
        if not channel:
            return self.tier
        return self.channel_tiers.get(channel, self.tier)

    def search_url_for(self, keyword: str) -> str:
        """把 ``{keyword}`` 填进搜索模板,并按格式选择内容协商类型。"""
        template = ""
        if self.selector is not None:
            template = self.selector.search_url
        elif self.json_api is not None:
            template = self.json_api.search_request.url
        elif self.rss is not None:
            template = self.rss.search_url
        if not template:
            return ""
        encoded = quote_keyword(keyword)
        return (
            template.replace("{keyword}", encoded)
            .replace("{page}", "1")
            .replace("{pageSize}", str(_template_page_size(self)))
        )

    def expects_json_search(self) -> bool:
        """搜索结果是不是 JSON。

        ``json-path-indexed`` 的搜索页是接口,必须声明 ``application/json``;
        其余是 HTML 页面。这与上游 ``SelectorHttpHeaders`` 的内容协商一致。
        """
        if self.json_api is not None:
            return True
        return (
            self.selector is not None
            and self.selector.subject_format_id == "json-path-indexed"
        )


def _template_page_size(rule: MediaSourceRule) -> int:
    if rule.json_api is not None:
        return max(1, rule.json_api.page_size)
    return 20


def quote_keyword(keyword: str) -> str:
    """按上游 ``encodeUrlSegment`` 的语义做百分号编码(空格 → ``%20``)。"""
    from urllib.parse import quote

    return quote(keyword or "", safe="")


@dataclass(frozen=True)
class RuleBundle:
    """一次订阅拉取的结果。"""

    rules: tuple[MediaSourceRule, ...]
    schema_version: int = 0
    name: str = ""
    description: str = ""
    website_url: str = ""
    icon_url: str = ""
    source_url: str = ""
    fetched_at: float = 0.0


# ── 解析 ──────────────────────────────────────────────────────────


def parse_subscription_payload(
    payload: Any,
    *,
    source_url: str = "",
    fetched_at: float | None = None,
) -> RuleBundle:
    """解析一个订阅文件(或单次导出文件)为规则集合。

    读取顺序照抄上游 ``SubscriptionUpdateDataReader``:顶层 ``mediaSources``
    优先,缺失时才退回 ``exportedMediaSourceDataList.mediaSources``。
    单个 source 解析失败只跳过它自己并把原因记进日志。
    """
    data = _as_mapping(payload)
    raw_sources = data.get("mediaSources")
    if not isinstance(raw_sources, list) or not raw_sources:
        legacy = _as_mapping(data.get("exportedMediaSourceDataList"))
        raw_sources = legacy.get("mediaSources")
    if not isinstance(raw_sources, list):
        raw_sources = []

    rules: list[MediaSourceRule] = []
    seen: set[str] = set()
    for source in raw_sources:
        if not isinstance(source, dict):
            continue
        try:
            rule = parse_media_source(source)
        except Exception as error:  # noqa: BLE001 - 一条坏规则不拖垮整库
            logger.warning(
                "跳过无法解析的规则 %s: %s",
                source.get("id"),
                type(error).__name__,
            )
            continue
        if rule is None or rule.id in seen:
            continue
        seen.add(rule.id)
        rules.append(rule)

    return RuleBundle(
        rules=tuple(rules),
        schema_version=_as_int(data.get("schemaVersion"), 0),
        name=_as_str(data.get("name")),
        description=_as_str(data.get("description")),
        website_url=_as_str(data.get("websiteUrl")),
        icon_url=_as_str(data.get("iconUrl")),
        source_url=source_url,
        fetched_at=time.time() if fetched_at is None else float(fetched_at),
    )


def parse_media_source(source: dict[str, Any]) -> Optional[MediaSourceRule]:
    """把一条 ``ExportedMediaSourceData`` 解析成 :class:`MediaSourceRule`。"""
    arguments = _as_mapping(source.get("arguments"))
    factory_id = _as_str(source.get("factoryId")).strip()
    source_id = _as_str(source.get("id") or arguments.get("name")).strip()
    if not factory_id or not source_id:
        return None

    channel_tiers = {
        _as_str(key): _as_int(value)
        for key, value in _as_mapping(arguments.get("channelTiers")).items()
        if _as_str(key).strip()
    }
    common = {
        "id": source_id,
        "factory_id": factory_id,
        "version": _as_int(source.get("version"), 1),
        "name": _as_str(arguments.get("name")).strip(),
        "description": _as_str(arguments.get("description")).strip(),
        "icon_url": _as_str(arguments.get("iconUrl")).strip(),
        "tier": _as_int(arguments.get("tier"), 0),
        "tags": _as_str_tuple(source.get("tags")),
        "channel_tiers": channel_tiers,
    }

    if factory_id == "web-selector":
        return MediaSourceRule(
            **common, selector=_parse_selector_config(_as_mapping(arguments.get("searchConfig")))
        )
    if factory_id == "json-api":
        return MediaSourceRule(
            **common, json_api=_parse_json_api_config(_as_mapping(arguments.get("searchConfig")))
        )
    if factory_id == "rss":
        return MediaSourceRule(
            **common, rss=_parse_rss_config(_as_mapping(arguments.get("searchConfig")))
        )
    # 未知 factory(如客户端专有的 bt/mikan 类型):保留名字以便上报,但不可执行。
    logger.debug("规则 %s 使用未支持的 factoryId=%s", source_id, factory_id)
    return MediaSourceRule(**common)


def _parse_auto_match(config: dict[str, Any]) -> AutoMatchConfig:
    # 6.2 起这些字段搬到 autoMatch 下,旧文件仍平铺在 searchConfig 顶层。
    nested = _as_mapping(config.get("autoMatch"))
    source = nested or config
    return AutoMatchConfig(
        search_use_only_first_word=_as_bool(source.get("searchUseOnlyFirstWord"), True),
        search_remove_special=_as_bool(source.get("searchRemoveSpecial"), True),
        search_use_subject_names_count=max(
            1, _as_int(source.get("searchUseSubjectNamesCount"), 1)
        ),
        prefer_shorter_name=_as_bool(source.get("preferShorterName"), True),
        filter_by_episode_sort=_as_bool(source.get("filterByEpisodeSort"), True),
    )


def _parse_match_video(config: dict[str, Any]) -> MatchVideoConfig:
    match_video = _as_mapping(config.get("matchVideo"))
    headers = _as_mapping(match_video.get("addHeadersToVideo"))
    return MatchVideoConfig(
        enable_nested_url=_as_bool(match_video.get("enableNestedUrl"), True),
        match_nested_url=_as_str(match_video.get("matchNestedUrl")),
        match_video_url=_as_str(match_video.get("matchVideoUrl")),
        cookies=_as_str(match_video.get("cookies")),
        referer=_as_str(headers.get("referer")),
        user_agent=_as_str(headers.get("userAgent")),
    )


def _parse_selector_config(config: dict[str, Any]) -> SelectorSearchConfig:
    format_a = _as_mapping(config.get("selectorSubjectFormatA"))
    format_indexed = _as_mapping(config.get("selectorSubjectFormatIndexed"))
    format_json = _as_mapping(config.get("selectorSubjectFormatJsonPathIndexed"))
    flattened = _as_mapping(config.get("selectorChannelFormatFlattened"))
    no_channel = _as_mapping(config.get("selectorChannelFormatNoChannel"))
    select_media = _as_mapping(config.get("selectMedia"))
    return SelectorSearchConfig(
        search_url=_as_str(config.get("searchUrl")).strip(),
        raw_base_url=_as_str(config.get("rawBaseUrl")).strip(),
        request_interval_ms=max(0, _as_int(config.get("requestInterval"), 3000)),
        search_cache_ttl_ms=max(
            0, _as_int(config.get("searchCacheTtl"), 2 * 3600 * 1000)
        ),
        user_agent=_as_str(config.get("userAgent")).strip(),
        subject_format_id=_as_str(config.get("subjectFormatId"), "a").strip() or "a",
        subject_format_a=SubjectFormatA(
            select_lists=_as_str(format_a.get("selectLists")).strip(),
            link_template=_as_str(format_a.get("linkTemplate")),
        ),
        subject_format_indexed=SubjectFormatIndexed(
            select_names=_as_str(format_indexed.get("selectNames")).strip(),
            select_links=_as_str(format_indexed.get("selectLinks")).strip(),
            link_template=_as_str(format_indexed.get("linkTemplate")),
        ),
        subject_format_json_path=SubjectFormatJsonPathIndexed(
            select_names=_as_str(format_json.get("selectNames")).strip(),
            select_links=_as_str(format_json.get("selectLinks")).strip(),
            link_template=_as_str(format_json.get("linkTemplate")),
        ),
        channel_format_id=(
            _as_str(config.get("channelFormatId"), "no-channel").strip() or "no-channel"
        ),
        channel_format_index_grouped=ChannelFormatIndexGrouped(
            select_channel_names=_as_str(flattened.get("selectChannelNames")).strip(),
            match_channel_name=_as_str(flattened.get("matchChannelName")),
            select_episode_lists=_as_str(flattened.get("selectEpisodeLists")).strip(),
            select_episodes_from_list=_as_str(
                flattened.get("selectEpisodesFromList")
            ).strip(),
            select_episode_links_from_list=_as_str(
                flattened.get("selectEpisodeLinksFromList")
            ).strip(),
            match_episode_sort_from_name=_as_str(
                flattened.get("matchEpisodeSortFromName")
            ),
        ),
        channel_format_no_channel=ChannelFormatNoChannel(
            select_episodes=_as_str(no_channel.get("selectEpisodes")).strip(),
            select_episode_links=_as_str(no_channel.get("selectEpisodeLinks")).strip(),
            match_episode_sort_from_name=_as_str(
                no_channel.get("matchEpisodeSortFromName")
            ),
        ),
        default_resolution=_as_str(config.get("defaultResolution"), "1080P"),
        default_subtitle_language=_as_str(config.get("defaultSubtitleLanguage"), "CHS"),
        only_supports_players=_as_str_tuple(config.get("onlySupportsPlayers")),
        select_media=SelectMediaConfig(
            distinguish_subject_name=_as_bool(
                select_media.get("distinguishSubjectName"), True
            ),
            distinguish_channel_name=_as_bool(
                select_media.get("distinguishChannelName"), True
            ),
        ),
        match_video=_parse_match_video(config),
        auto_match=_parse_auto_match(config),
    )


def _parse_request(config: dict[str, Any]) -> JsonApiRequestConfig:
    return JsonApiRequestConfig(
        url=_as_str(config.get("url")).strip(),
        method=(_as_str(config.get("method"), "GET").strip() or "GET").upper(),
        body=_as_str(config.get("body")),
        headers=_as_str(config.get("headers")),
    )


def _parse_json_api_config(config: dict[str, Any]) -> JsonApiSearchConfig:
    search = _as_mapping(config.get("search"))
    subject = _as_mapping(config.get("subject"))
    episodes = _as_mapping(subject.get("episodes"))
    grouped = _as_mapping(subject.get("channelFormatGrouped"))
    play = _as_mapping(config.get("play"))
    return JsonApiSearchConfig(
        base_url=_as_str(config.get("baseUrl")).strip(),
        headers=_as_str(config.get("headers")),
        user_agent=_as_str(config.get("userAgent")).strip(),
        request_interval_ms=max(0, _as_int(config.get("requestInterval"), 3000)),
        search_cache_ttl_ms=max(
            0, _as_int(config.get("searchCacheTtl"), 2 * 3600 * 1000)
        ),
        default_resolution=_as_str(config.get("defaultResolution"), "1080P"),
        default_subtitle_language=_as_str(config.get("defaultSubtitleLanguage"), "CHS"),
        search_request=_parse_request(_as_mapping(search.get("request"))),
        page_size=max(1, _as_int(search.get("pageSize"), 20)),
        select_items=_as_str(search.get("selectItems")).strip(),
        select_name=_as_str(search.get("selectName")).strip(),
        select_id=_as_str(search.get("selectId")).strip(),
        subject_url_template=_as_str(search.get("subjectUrlTemplate")),
        subject_request=_parse_request(_as_mapping(subject.get("request"))),
        channel_format_id=_as_str(subject.get("channelFormatId")).strip(),
        select_channels=_as_str(grouped.get("selectChannels")).strip(),
        select_channel_name=_as_str(grouped.get("selectChannelName")).strip(),
        episodes=JsonApiEpisodesConfig(
            request=_parse_request(_as_mapping(episodes.get("request"))),
            select_episodes=_as_str(episodes.get("selectEpisodes")).strip(),
            select_name=_as_str(episodes.get("selectName")).strip(),
            select_id=_as_str(episodes.get("selectId")).strip(),
            select_sort=_as_str(episodes.get("selectSort")).strip(),
            select_type=_as_str(episodes.get("selectType")).strip(),
            type_mapping=_as_str(episodes.get("typeMapping")),
            name_template=_as_str(episodes.get("nameTemplate")),
            episode_url_template=_as_str(episodes.get("episodeUrlTemplate")),
        ),
        play_request=_parse_request(_as_mapping(play.get("request"))),
        select_candidates=_as_str(play.get("selectCandidates")).strip(),
        select_candidate_channel=_as_str(play.get("selectCandidateChannel")).strip(),
        select_video_url=_as_str(play.get("selectVideoUrl")).strip(),
        fallback_to_first_candidate=_as_bool(play.get("fallbackToFirstCandidate"), False),
        play_referer=_as_str(play.get("referer")),
        auto_match=_parse_auto_match(config),
    )


def _parse_rss_config(config: dict[str, Any]) -> RssSearchConfig:
    return RssSearchConfig(
        search_url=_as_str(config.get("searchUrl")).strip(),
        filter_by_episode_sort=_as_bool(config.get("filterByEpisodeSort"), True),
        filter_by_subject_name=_as_bool(config.get("filterBySubjectName"), True),
    )


# ── 订阅拉取与缓存 ─────────────────────────────────────────────────


class RuleRepository:
    """规则库仓储:拉订阅、解析、内存缓存 + 可选磁盘缓存。

    设计要点:

    * **不是启动即拉**:构造函数零副作用,真正的网络请求发生在第一次
      :meth:`load`。这样进程启动、单元测试、以及未启用该 provider 的部署
      都不会碰外网。
    * **逐订阅隔离**:一个订阅 404 不影响另一个;全挂时退回磁盘上一次的快照
      (站点规则是"宁可旧也不能没有"的数据)。
    * **磁盘只是快照**:写失败(只读盘/权限)只记日志,不影响内存结果。
    """

    def __init__(
        self,
        urls: Iterable[str],
        *,
        client: Optional[httpx.AsyncClient] = None,
        cache_path: Optional[Path] = None,
        memory_ttl_seconds: float = 6 * 3600,
        failure_retry_seconds: float = 30.0,
        disk_ttl_seconds: float = 7 * 24 * 3600,
        timeout_seconds: float = 20.0,
        proxy: str = "",
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._urls = tuple(url for url in (url.strip() for url in urls) if url)
        self._client = client
        self._owns_client = client is None
        self._cache_path = cache_path
        self._memory_ttl = max(0.0, memory_ttl_seconds)
        self._failure_retry = max(0.0, failure_retry_seconds)
        self._disk_ttl = max(0.0, disk_ttl_seconds)
        self._timeout = max(1.0, timeout_seconds)
        self._proxy = proxy
        self._bundles: list[RuleBundle] = []
        self._rules: tuple[MediaSourceRule, ...] = ()
        self._clock = clock
        # None 区分“从未加载”和“已加载但结果为空”,包括单调时钟恰好为 0。
        self._loaded_at: Optional[float] = None
        self._last_load_failed = False
        self._lock = asyncio.Lock()

    @property
    def rules(self) -> tuple[MediaSourceRule, ...]:
        """最近一次成功加载的规则;从未加载时为空。"""
        return self._rules

    @property
    def bundles(self) -> tuple[RuleBundle, ...]:
        return tuple(self._bundles)

    def rule(self, rule_id: str) -> Optional[MediaSourceRule]:
        for item in self._rules:
            if item.id == rule_id:
                return item
        return None

    async def load(self, *, force: bool = False) -> tuple[MediaSourceRule, ...]:
        """返回规则集合,必要时拉取订阅。并发调用只触发一次真实拉取。"""
        async with self._lock:
            ttl = self._failure_retry if self._last_load_failed else self._memory_ttl
            fresh = (
                self._loaded_at is not None
                and 0 <= self._clock() - self._loaded_at < ttl
            )
            if fresh and not force:
                return self._rules
            bundles = await self._fetch_bundles()
            if bundles:
                self._bundles = bundles
                merged: dict[str, MediaSourceRule] = {}
                for bundle in bundles:
                    for rule in bundle.rules:
                        merged.setdefault(rule.id, rule)
                self._rules = tuple(merged.values())
                self._loaded_at = self._clock()
                self._last_load_failed = False
                self._write_disk_cache()
                logger.info(
                    "animeko 规则库已加载:%d 条规则 / %d 个订阅",
                    len(self._rules),
                    len(bundles),
                )
                return self._rules

            # 全部订阅失败:退回磁盘快照,并保持短冷却,避免每次请求都重试外网。
            cached = self._read_disk_cache()
            if cached:
                self._rules = cached
                logger.warning(
                    "animeko 订阅全部拉取失败,使用磁盘缓存 %d 条规则", len(self._rules)
                )
            elif not self._rules:
                logger.warning("animeko 订阅不可用且无磁盘缓存,规则库为空")
            # 空结果和旧内存/磁盘回退均执行短冷却;force 始终可立即重试。
            self._loaded_at = self._clock()
            self._last_load_failed = True
            return self._rules

    async def aclose(self) -> None:
        if self._owns_client and self._client is not None:
            await self._client.aclose()
            self._client = None

    # ── 内部 ────────────────────────────────────────────────

    def _ensure_client(self) -> httpx.AsyncClient:
        if self._client is None:
            kwargs: dict[str, Any] = {
                "timeout": httpx.Timeout(self._timeout, connect=min(6.0, self._timeout)),
                "follow_redirects": True,
                "headers": {
                    "User-Agent": config.ANIMEKO_USER_AGENT,
                    "Accept": "application/json;q=1, text/html;q=0.9",
                },
            }
            if self._proxy:
                kwargs["proxy"] = self._proxy
            self._client = httpx.AsyncClient(**kwargs)
        return self._client

    async def _fetch_bundles(self) -> list[RuleBundle]:
        if not self._urls:
            return []
        client = self._ensure_client()

        async def fetch(url: str) -> Optional[RuleBundle]:
            try:
                response = await client.get(url)
            except Exception as error:  # noqa: BLE001 - 单个订阅失败要隔离
                logger.warning(
                    "animeko 订阅拉取失败 %s: %s", url, type(error).__name__
                )
                return None
            if response.status_code != 200:
                logger.warning("animeko 订阅 %s 返回 HTTP %d", url, response.status_code)
                return None
            try:
                payload = response.json()
            except ValueError:
                logger.warning("animeko 订阅 %s 不是合法 JSON", url)
                return None
            bundle = parse_subscription_payload(payload, source_url=url)
            if not bundle.rules:
                logger.warning("animeko 订阅 %s 解析出 0 条规则", url)
                return None
            return bundle

        results = await asyncio.gather(*(fetch(url) for url in self._urls))
        return [bundle for bundle in results if bundle is not None]

    def _write_disk_cache(self) -> None:
        if self._cache_path is None:
            return
        try:
            self._cache_path.parent.mkdir(parents=True, exist_ok=True)
            snapshot = {
                "writtenAt": time.time(),
                "bundles": [
                    {
                        "sourceUrl": bundle.source_url,
                        "schemaVersion": bundle.schema_version,
                        "name": bundle.name,
                        "description": bundle.description,
                        "websiteUrl": bundle.website_url,
                        "iconUrl": bundle.icon_url,
                        "mediaSources": [_rule_to_payload(rule) for rule in bundle.rules],
                    }
                    for bundle in self._bundles
                ],
            }
            self._cache_path.write_text(
                json.dumps(snapshot, ensure_ascii=False), encoding="utf-8"
            )
        except OSError as error:
            logger.debug("animeko 规则磁盘缓存写入失败: %s", type(error).__name__)

    def _read_disk_cache(self) -> tuple[MediaSourceRule, ...]:
        if self._cache_path is None or not self._cache_path.exists():
            return ()
        try:
            snapshot = json.loads(self._cache_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return ()
        written_at = _as_float(snapshot.get("writtenAt"), 0.0)
        if self._disk_ttl and written_at and time.time() - written_at > self._disk_ttl:
            return ()
        merged: dict[str, MediaSourceRule] = {}
        for entry in snapshot.get("bundles") or []:
            bundle = parse_subscription_payload(
                _as_mapping(entry), source_url=_as_str(entry.get("sourceUrl"))
            )
            for rule in bundle.rules:
                merged.setdefault(rule.id, rule)
        return tuple(merged.values())


def _rule_to_payload(rule: MediaSourceRule) -> dict[str, Any]:
    """磁盘缓存写回成订阅原始形态,复用同一套解析器读回。"""
    arguments: dict[str, Any] = {
        "name": rule.name,
        "description": rule.description,
        "iconUrl": rule.icon_url,
        "tier": rule.tier,
    }
    if rule.channel_tiers:
        arguments["channelTiers"] = dict(rule.channel_tiers)
    if rule.selector is not None:
        arguments["searchConfig"] = _selector_config_to_payload(rule.selector)
    elif rule.json_api is not None:
        arguments["searchConfig"] = _json_api_config_to_payload(rule.json_api)
    elif rule.rss is not None:
        arguments["searchConfig"] = {
            "searchUrl": rule.rss.search_url,
            "filterByEpisodeSort": rule.rss.filter_by_episode_sort,
            "filterBySubjectName": rule.rss.filter_by_subject_name,
        }
    payload: dict[str, Any] = {
        "id": rule.id,
        "factoryId": rule.factory_id,
        "version": rule.version,
        "arguments": arguments,
    }
    if rule.tags:
        payload["tags"] = list(rule.tags)
    return payload


def _selector_config_to_payload(config: SelectorSearchConfig) -> dict[str, Any]:
    return {
        "searchUrl": config.search_url,
        "rawBaseUrl": config.raw_base_url,
        "requestInterval": config.request_interval_ms,
        "searchCacheTtl": config.search_cache_ttl_ms,
        "userAgent": config.user_agent,
        "subjectFormatId": config.subject_format_id,
        "selectorSubjectFormatA": {
            "selectLists": config.subject_format_a.select_lists,
            "linkTemplate": config.subject_format_a.link_template,
        },
        "selectorSubjectFormatIndexed": {
            "selectNames": config.subject_format_indexed.select_names,
            "selectLinks": config.subject_format_indexed.select_links,
            "linkTemplate": config.subject_format_indexed.link_template,
        },
        "selectorSubjectFormatJsonPathIndexed": {
            "selectNames": config.subject_format_json_path.select_names,
            "selectLinks": config.subject_format_json_path.select_links,
            "linkTemplate": config.subject_format_json_path.link_template,
        },
        "channelFormatId": config.channel_format_id,
        "selectorChannelFormatFlattened": {
            "selectChannelNames": config.channel_format_index_grouped.select_channel_names,
            "matchChannelName": config.channel_format_index_grouped.match_channel_name,
            "selectEpisodeLists": config.channel_format_index_grouped.select_episode_lists,
            "selectEpisodesFromList": (
                config.channel_format_index_grouped.select_episodes_from_list
            ),
            "selectEpisodeLinksFromList": (
                config.channel_format_index_grouped.select_episode_links_from_list
            ),
            "matchEpisodeSortFromName": (
                config.channel_format_index_grouped.match_episode_sort_from_name
            ),
        },
        "selectorChannelFormatNoChannel": {
            "selectEpisodes": config.channel_format_no_channel.select_episodes,
            "selectEpisodeLinks": config.channel_format_no_channel.select_episode_links,
            "matchEpisodeSortFromName": (
                config.channel_format_no_channel.match_episode_sort_from_name
            ),
        },
        "defaultResolution": config.default_resolution,
        "defaultSubtitleLanguage": config.default_subtitle_language,
        "onlySupportsPlayers": list(config.only_supports_players),
        "selectMedia": {
            "distinguishSubjectName": config.select_media.distinguish_subject_name,
            "distinguishChannelName": config.select_media.distinguish_channel_name,
        },
        "matchVideo": {
            "enableNestedUrl": config.match_video.enable_nested_url,
            "matchNestedUrl": config.match_video.match_nested_url,
            "matchVideoUrl": config.match_video.match_video_url,
            "cookies": config.match_video.cookies,
            "addHeadersToVideo": {
                "referer": config.match_video.referer,
                "userAgent": config.match_video.user_agent,
            },
        },
        "autoMatch": {
            "searchUseOnlyFirstWord": config.auto_match.search_use_only_first_word,
            "searchRemoveSpecial": config.auto_match.search_remove_special,
            "searchUseSubjectNamesCount": (
                config.auto_match.search_use_subject_names_count
            ),
            "preferShorterName": config.auto_match.prefer_shorter_name,
            "filterByEpisodeSort": config.auto_match.filter_by_episode_sort,
        },
    }


def _json_api_config_to_payload(config: JsonApiSearchConfig) -> dict[str, Any]:
    return {
        "baseUrl": config.base_url,
        "headers": config.headers,
        "userAgent": config.user_agent,
        "requestInterval": config.request_interval_ms,
        "searchCacheTtl": config.search_cache_ttl_ms,
        "defaultResolution": config.default_resolution,
        "defaultSubtitleLanguage": config.default_subtitle_language,
        "search": {
            "request": {
                "url": config.search_request.url,
                "method": config.search_request.method,
                "body": config.search_request.body,
                "headers": config.search_request.headers,
            },
            "pageSize": config.page_size,
            "selectItems": config.select_items,
            "selectName": config.select_name,
            "selectId": config.select_id,
            "subjectUrlTemplate": config.subject_url_template,
        },
        "subject": {
            "request": {
                "url": config.subject_request.url,
                "method": config.subject_request.method,
                "body": config.subject_request.body,
                "headers": config.subject_request.headers,
            },
            "channelFormatId": config.channel_format_id,
            "channelFormatGrouped": {
                "selectChannels": config.select_channels,
                "selectChannelName": config.select_channel_name,
            },
            "episodes": {
                "request": {
                    "url": config.episodes.request.url,
                    "method": config.episodes.request.method,
                    "body": config.episodes.request.body,
                    "headers": config.episodes.request.headers,
                },
                "selectEpisodes": config.episodes.select_episodes,
                "selectName": config.episodes.select_name,
                "selectId": config.episodes.select_id,
                "selectSort": config.episodes.select_sort,
                "selectType": config.episodes.select_type,
                "typeMapping": config.episodes.type_mapping,
                "nameTemplate": config.episodes.name_template,
                "episodeUrlTemplate": config.episodes.episode_url_template,
            },
        },
        "play": {
            "request": {
                "url": config.play_request.url,
                "method": config.play_request.method,
                "body": config.play_request.body,
                "headers": config.play_request.headers,
            },
            "selectCandidates": config.select_candidates,
            "selectCandidateChannel": config.select_candidate_channel,
            "selectVideoUrl": config.select_video_url,
            "fallbackToFirstCandidate": config.fallback_to_first_candidate,
            "referer": config.play_referer,
        },
        "autoMatch": {
            "searchUseOnlyFirstWord": config.auto_match.search_use_only_first_word,
            "searchRemoveSpecial": config.auto_match.search_remove_special,
            "searchUseSubjectNamesCount": (
                config.auto_match.search_use_subject_names_count
            ),
            "preferShorterName": config.auto_match.prefer_shorter_name,
            "filterByEpisodeSort": config.auto_match.filter_by_episode_sort,
        },
    }


__all__ = [
    "AutoMatchConfig",
    "ChannelFormatIndexGrouped",
    "ChannelFormatNoChannel",
    "JsonApiSearchConfig",
    "MatchVideoConfig",
    "MediaSourceRule",
    "RuleBundle",
    "RuleRepository",
    "RssSearchConfig",
    "SelectMediaConfig",
    "SelectorSearchConfig",
    "SubjectFormatA",
    "SubjectFormatIndexed",
    "SubjectFormatJsonPathIndexed",
    "compile_rule_pattern",
    "guess_base_url",
    "parse_media_source",
    "parse_subscription_payload",
    "quote_keyword",
    "rewrite_azusa_named_groups",
]
