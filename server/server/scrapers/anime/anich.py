"""AniCh 聚合源独立适配器(按需代取,不镜像、不缓存直链)。

职责:把 AniCh 后端的「标题搜索 → 剧集 → 全局集号取流」链路
适配成 Zeluna 的 ``BaseScraper`` 形态。注意两条领域规则:

* 上游 ``episodes[].sort`` 是跨季全局集号(S2 页面里季内第 1 集
  可能是 sort=29);``get_video_urls`` 的 ``episode`` 参数是季内序号,
  用 ``resolve_global_sort`` 做两级对齐;
* 列表元数据不可全信(实测见过 ep 59/12 与大量空值),凡参与回退
  映射的行都必须通过 ``_plausible_episode`` 校验。

线路纯净度参考(排序依据):自建 CDN 官方二压 > 代取流 > 对象存储
转存 > 采集站原始 m3u8。单集可达 58 条线,统一截断到配置上限。
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import urlparse

from ..base import (
    INVALID_MEDIA_URL,
    PLAYER_PAGE_URL,
    BaseScraper,
    EpisodeInfo,
    SubjectDetail,
    SubjectResult,
    VideoLine,
    classify_media_url,
)
from . import anich_proto
from .anich_proto import decode_variant_base64
from .anich_transport import (
    AniChTransport,
    ANICH_FALLBACK_BASES,
    ANICH_OWN_CDN_HOST_TOKENS,
    anich_detail_path,
    anich_episodes_path,
    anich_latest_path,
    anich_search_path,
    anich_vod_path,
)

# 画质词按优先级排列(与逆向套件 pick() 同序);label 同时是 quality 字段文本。
_QUALITY_RULES: tuple[tuple[str, str], ...] = (
    (r"官方简中.*?(?:1080P|全高清)", "官方简中·1080P"),
    (r"官方简中", "官方简中"),
    (r"简中", "简中"),
    (r"国语|中文配音", "国语"),
    (r"4K|超清", "4K"),
    (r"1080P|全高清|蓝光", "1080P"),
    (r"720P|高清", "720P"),
)
_QUALITY_REWARD: dict[str, float] = {
    label: float(reward)
    for reward, label in enumerate(
        (label for _, label in reversed(_QUALITY_RULES)), start=1
    )
}
_EPISODE_PREFIX_RE = re.compile(r"^\s*(?:第\s*\d+\s*[话集]|EP?\s*\d+)\s*")
_PAREN_SPLIT_RE = re.compile(r"[()()【】\[\]]")
_LEADING_NUMBER_RE = re.compile(r"^\d+\s*·\s*")
_SEARCH_PAGE_LIMIT = 20
_OWN_CDN_TOKENS = ANICH_OWN_CDN_HOST_TOKENS


def resolve_global_sort(episodes: list[dict], episode: int) -> Optional[int]:
    """把季内序号映射成上游全局集号。

    1) 精确命中:存在 ``sort == episode`` 且 status=True 的行直接用;
    2) 回退:在可信行里按下标取季内第 N 集(cli 层的历史行为);
    3) 两级都无解返回 None,由调用方产出空线路并交给负缓存兜底。
    """
    target = int(episode)
    if not episodes or target <= 0:
        return None
    for entry in episodes:
        if entry.get("sort") == target and entry.get("status"):
            return target
    valid = [entry for entry in episodes if _plausible_episode(entry)]
    if 1 <= target <= len(valid):
        return int(valid[target - 1].get("sort") or 0) or None
    return None


def _plausible_episode(entry: dict) -> bool:
    """剔除脏元数据行(status=False 或 duration 明显离谱)。"""
    if not entry.get("status"):
        return False
    duration = int(entry.get("duration") or 0)
    return duration == 0 or 60 <= duration <= 7200


def caption_quality(caption: str) -> str:
    text = caption or ""
    for pattern, label in _QUALITY_RULES:
        if re.search(pattern, text):
            return label
    return ""


def line_display_title(caption: str) -> str:
    """「第10集(官方简中-全高清-1080P)」→「官方简中·全高清·1080P」。

    线上多数 caption 是裸集号(``第01集``/``第01话``),这类返回空串,
    由 ``AniChScraper`` 回退成按线路序号命名,避免 UI 出现整排无名线路。
    """
    text = _EPISODE_PREFIX_RE.sub("", (caption or "").strip())
    parts = [part.strip() for part in _PAREN_SPLIT_RE.split(text) if part.strip()]
    merged = "·".join(part.replace("-", "·").replace("×", "·") for part in parts)
    return _LEADING_NUMBER_RE.sub("", merged).strip()


def _is_own_cdn(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    # 上游自建 CDN 以子域形式出现在 cloudflare 托管网域下,
    # 因此按"主域名子串命中"判定(与逆向套件 pick 一致)。
    return any(token in host for token in _OWN_CDN_TOKENS)


# 线上实测的交付形态权重(单集 61 条线路的域名分布分析):
#   自建 CDN 官方二压 > 边缘代取流 > 对象存储转存 > 采集站原始 m3u8。
# caption 带画质括注的只占少数,因此域名类别必须是主排序信号,
# 画质词只作同类内的次级加分。
_DELIVERY_REWARD = 60.0
_PROXY_REWARD = 40.0
_OBJECT_STORE_REWARD = 20.0
_OBJECT_STORE_TOKENS = (
    "adkwai.com",
    "ibyteimg.com",
    "xiaohongshu.com",
    "scsusercontent.cn",
)
# 线上混入的转发/过滤入口:脚本端点带 query 参数,不是媒体本体。
# 例:player.91ju.cc/wgart/api.php?action=ad_filter_proxy&video_url=...
_SCRIPT_ENDPOINT_SUFFIXES = (".php", ".asp", ".aspx", ".jsp", ".cgi")


def _is_script_endpoint(url: str) -> bool:
    try:
        parsed = urlparse(url)
    except ValueError:
        return True
    return parsed.path.lower().endswith(_SCRIPT_ENDPOINT_SUFFIXES)


def line_rank(url: str, caption: str) -> float:
    """服务端排序分;分数越高越优先。"""
    score = _QUALITY_REWARD.get(caption_quality(caption), 0.0)
    host = (urlparse(url).hostname or "").lower()
    if any(token in host for token in ANICH_OWN_CDN_HOST_TOKENS):
        # 自建 CDN 的两种形态:官方二压目录 vs 边缘代取流
        score += _DELIVERY_REWARD if "vod-cdn" in host else _PROXY_REWARD
    elif any(token in host for token in _OBJECT_STORE_TOKENS):
        score += _OBJECT_STORE_REWARD
    if ".m3u8" in url.lower():
        score += 5.0
    return score


class AniChScraper(BaseScraper):
    """AniCh 聚合后端 anime-only 只读适配器。"""

    def __init__(self, *, transport=None, max_lines: int | None = None) -> None:
        super().__init__()
        self._name = "anich"
        self._transport = transport or AniChTransport()
        self._max_lines = max_lines

    @property
    def content_types(self) -> list[str]:
        return ["anime"]

    @property
    def base_url(self) -> str:
        """诊断用途:当前工作主域或首选候选。"""
        return self._transport.base or ANICH_FALLBACK_BASES[0]

    async def search(self, keyword: str) -> list[SubjectResult]:
        keyword = (keyword or "").strip()
        if not keyword:
            return []
        payload = await self._transport.request(anich_search_path(keyword))
        return self._list_results(anich_proto.decode_bangumi_list(payload))

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        # 只取首页:precache 场景足够,深翻页对该源没有增量价值。
        if page > 1:
            return []
        payload = await self._transport.request(anich_latest_path())
        return self._list_results(anich_proto.decode_bangumi_list(payload))

    async def get_home(self) -> list[SubjectResult]:
        return []

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        bangumi_id = _parse_bangumi_id(source_id)
        if bangumi_id is None:
            return None
        detail_payload = await self._transport.request(anich_detail_path(bangumi_id))
        meta = _detail_meta(detail_payload, bangumi_id)
        episodes_payload = await self._transport.request(
            anich_episodes_path(bangumi_id)
        )
        episodes = [
            EpisodeInfo(
                number=index + 1,
                title=(entry.get("title") or f"第{index + 1}集"),
                source_episode_id=str(entry.get("sort") or index + 1),
            )
            for index, entry in enumerate(
                anich_proto.decode_episodes(episodes_payload)
            )
        ]
        return SubjectDetail(
            source_id=str(bangumi_id),
            title=meta["title"],
            cover_url=meta["cover"],
            summary=meta["summary"],
            type="anime",
            year=meta["year"],
            rating=meta["rating"],
            genres=meta["genres"],
            episodes=episodes,
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        bangumi_id = _parse_bangumi_id(source_id)
        if bangumi_id is None:
            return []
        episodes_payload = await self._transport.request(
            anich_episodes_path(bangumi_id)
        )
        global_sort = resolve_global_sort(
            anich_proto.decode_episodes(episodes_payload), int(episode)
        )
        if global_sort is None:
            return []
        vod_payload = await self._transport.request(
            anich_vod_path(bangumi_id, global_sort)
        )
        body = anich_proto.unwrap_vod_body(vod_payload)
        raw_items = anich_proto.decode_vod(body)

        scored: list[tuple[float, int, VideoLine]] = []
        seen_urls: set[str] = set()
        for index, item in enumerate(raw_items):
            try:
                url = decode_variant_base64(item.get("url_raw") or "")
            except ValueError:
                continue
            key = url.lower()
            if not key.startswith(("http://", "https://")) or key in seen_urls:
                continue
            caption = item.get("caption") or ""
            declared_format = "hls" if ".m3u8" in key else ""
            # 拒绝明确的非媒体入口:embed/player 页与脚本转发端点。
            # 自建 CDN 的无扩展名直链保持 unknown,交由服务端内容嗅探,
            # 不在此提前否决(实测头部线路全部是这种形态)。
            if _is_script_endpoint(url) or classify_media_url(
                url, declared_format
            ) in {INVALID_MEDIA_URL, PLAYER_PAGE_URL}:
                continue
            seen_urls.add(key)
            scored.append(
                (
                    line_rank(url, caption),
                    index,
                    VideoLine(
                        url=url,
                        title=line_display_title(caption),
                        quality=caption_quality(caption),
                        format=declared_format,
                        headers={},
                        source_name=self.name,
                    ),
                )
            )
        scored.sort(key=lambda entry: (-entry[0], entry[1]))
        selected = [line for _, _, line in scored[: self._effective_max_lines()]]
        for position, line in enumerate(selected, 1):
            if not line.title:
                line.title = f"线路{position}"
        return selected

    async def aclose(self) -> None:
        close = getattr(self._transport, "aclose", None)
        if callable(close):
            await close()

    # ── 内部 ────────────────────────────────────────────────
    def _effective_max_lines(self) -> int:
        if self._max_lines is not None:
            return max(1, int(self._max_lines))
        from ... import config

        return max(1, int(config.ANICH_MAX_LINES_PER_EPISODE))

    @staticmethod
    def _list_results(entries: list[dict]) -> list[SubjectResult]:
        results: list[SubjectResult] = []
        seen_ids: set[int] = set()
        for entry in entries:
            bangumi_id = entry.get("id")
            title = (entry.get("title") or "").strip()
            if not bangumi_id or not title or bangumi_id in seen_ids:
                continue
            seen_ids.add(int(bangumi_id))
            if len(results) >= _SEARCH_PAGE_LIMIT:
                break
            year = _year_from_epoch(entry.get("date"))
            status_text = (entry.get("status") or "").lower()
            results.append(
                SubjectResult(
                    source_id=str(int(bangumi_id)),
                    title=title,
                    cover_url=entry.get("image") or "",
                    summary=(entry.get("tagline") or "")[:160],
                    type="anime",
                    year=year,
                    episode_count=int(entry.get("episodes_total") or 0),
                    latest_episode=int(entry.get("episode") or 0),
                    status=1 if status_text in {"finale", "released"} else 0,
                )
            )
        return results


# ── 模块级工具 ────────────────────────────────────────────────
def _first_alias(titles: object) -> str:
    """``titles`` 线上是数组(历史资料里出现过 dict 形态,两者都兼容)。"""
    if isinstance(titles, list):
        candidates = titles
    elif isinstance(titles, dict):
        candidates = list(titles.values())
    else:
        return ""
    for candidate in candidates:
        text = str(candidate or "").strip()
        if text:
            return text
    return ""


def _year_from_epoch(value: object) -> int:
    """上游 ``date`` 是毫秒级 double(线上实测 1774540800000.0)。

    量纲自适应而非硬除 1000:秒级与毫秒级都能解析,越界值一律退化为 0
    (年份只作匹配加分用,拿不到不影响播放)。
    """
    try:
        raw = float(value or 0.0)
    except (TypeError, ValueError):
        return 0
    if raw <= 0:
        return 0
    # 按量级判定而不是逐个试除:任何现代日期的毫秒时间戳都 > 1e11,
    # 而秒级时间戳要到公元 5138 年才会达到该量级。这样秒级输入不会
    # 被误除成 1970,毫秒级也不会被当成公元 58202 年。
    seconds = raw / 1000.0 if raw > 1e11 else raw
    try:
        year = datetime.fromtimestamp(seconds, tz=timezone.utc).year
    except (ValueError, OSError, OverflowError):
        return 0
    return year if 1900 <= year <= 2200 else 0


def _parse_bangumi_id(source_id: str) -> Optional[int]:
    try:
        value = int(str(source_id).strip())
    except ValueError:
        return None
    return value if value > 0 else None


def _detail_meta(payload: bytes, fallback_title_hint: int) -> dict:
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    title = str(data.get("title") or "").strip()
    if not title:
        title = _first_alias(data.get("titles"))
    # 线上实测 airdate 同样是毫秒时间戳(1768492800000),不是 "2024-01" 文本
    year = _year_from_epoch(data.get("airdate"))
    scores = data.get("rating")
    values = []
    if isinstance(scores, list):
        values = [
            float(site.get("score"))
            for site in scores
            if isinstance(site, dict) and isinstance(site.get("score"), (int, float))
        ]
    genres = [str(genre) for genre in (data.get("genres") or []) if genre]
    return {
        "title": title or f"bangumi-{fallback_title_hint}",
        "cover": str(data.get("image") or ""),
        "summary": str(data.get("overview") or "")[:400],
        "year": year,
        "rating": round(sum(values) / len(values), 2) if values else 0.0,
        "genres": genres,
    }
