"""采集站解析器统一基类。

在 ``BaseScraper`` 之上固化几条被实测反复验证的经验:

* **冗余最大化的集号匹配**:一集必须尽量在**每条线路**下各出一个候选。
  只要"精确匹配到一条就收工",5 条线路会退化成 1 条候选,首条死链即全灭。
* **两级 URL 解码不假定层序**:MacCMS 的 ``encrypt=2`` 通常是 base64,
  但有站是 ``base64(urlencode(明文))`` 双层。按"解完再探测残留编码"处理,
  新站接入不必改代码。
* **含中文的地址必须转 URI**:否则请求阶段抛编码错误,会把好线路误判成死线。
* **域名按族解析**:这类站换域极勤,``base_url`` 不写死,经 DomainWatch 取当前活域。
* **站点状态三值**:``ok`` / ``parsed-dead``(解析通但货源没了)/ ``dead``。
  区分"解析错了"和"货源没了"决定该改代码还是该等——货源回来时
  ``parsed-dead`` 的解析器零改动即可复活。
"""

from __future__ import annotations

import base64
import os
import re
from dataclasses import dataclass, field
from urllib.parse import quote, unquote, urljoin, urlsplit, urlunsplit

from ..base import BaseScraper

SITE_STATUS_OK = "ok"
SITE_STATUS_PARSED_DEAD = "parsed-dead"
SITE_STATUS_DEAD = "dead"
SITE_STATUSES = frozenset({SITE_STATUS_OK, SITE_STATUS_PARSED_DEAD, SITE_STATUS_DEAD})

_EPISODE_LABEL_RE_CACHE: dict[int, re.Pattern[str]] = {}


@dataclass(frozen=True)
class EpisodeCandidate:
    """一条线路下的某一集(播放页尚未解析)。"""

    line_key: str          # 线路分组标识:同一集在不同线路下重复出现
    label: str             # 站点标注:"第1集" / "OAD01" / "HD中字"
    page_path: str         # 播放页路径或完整 URL
    index: int = 0         # 该线路内的顺序(0 基)


@dataclass(frozen=True)
class PlayCandidate:
    """播放页解析出的媒体候选。"""

    url: str
    line_key: str = ""
    label: str = ""
    headers: dict = field(default_factory=dict)


def safe_request_url(url: str) -> str:
    """把含中文/空格的 IRI 转成合法 URI;已编码部分不二次编码。"""
    try:
        url.encode("ascii")
        return url
    except UnicodeEncodeError:
        parts = urlsplit(url)
        netloc = parts.netloc
        try:
            netloc = netloc.encode("idna").decode("ascii")
        except (UnicodeError, ValueError):
            pass
        return urlunsplit((
            parts.scheme,
            netloc,
            quote(parts.path, safe="/%:@&=+$,~"),
            quote(parts.query, safe="/%:@&=+$,~?"),
            quote(parts.fragment, safe="/%:@&=+$,~"),
        ))


def decode_play_url(url: str, encrypt: object = 0) -> str:
    """MacCMS ``encrypt`` 语义:0=明文 1=urlencode 2=base64。

    各站 ``encrypt=2`` 层序不一致(有的还套一层 urlencode),因此两级都做
    并探测残留编码,而不是假定固定顺序。解不出就原样返回,交给上层验活。
    """
    raw = (url or "").strip()
    if not raw:
        return ""
    try:
        mode = int(encrypt or 0)
    except (TypeError, ValueError):
        mode = 0
    if mode == 1:
        return unquote(raw)
    if mode == 2:
        text = unquote(raw) if "%" in raw else raw
        try:
            text = base64.b64decode(
                text + "=" * (-len(text) % 4)
            ).decode("utf-8", "replace")
        except (ValueError, TypeError):
            return raw
        return unquote(text) if "%" in text else text
    return raw


def _episode_label_regex(number: int) -> re.Pattern[str]:
    """匹配"第N集/N话/N",用 fullmatch 防止 1 吞掉 11。"""
    cached = _EPISODE_LABEL_RE_CACHE.get(number)
    if cached is None:
        cached = re.compile(rf"(?:第)?0*{number}(?:[集话話])?")
        _EPISODE_LABEL_RE_CACHE[number] = cached
    return cached


def select_episode_candidates(
    candidates: list[EpisodeCandidate], episode: int | str
) -> list[EpisodeCandidate]:
    """按集号在**每条线路**下各挑一个候选(冗余最大化)。

    1. 该线路内标签精确匹配 → 用它;
    2. 否则退化为该线路内的第 N 个(位置等价,应对 "OAD01"/"HD中字" 这类标签);
    3. 非整数集号只做标签精确匹配。
    """
    if not candidates:
        return []
    grouped: dict[str, list[EpisodeCandidate]] = {}
    for item in candidates:
        grouped.setdefault(item.line_key, []).append(item)

    if not isinstance(episode, int):
        wanted = str(episode).strip()
        return [item for item in candidates if item.label.strip() == wanted]

    if episode <= 0:
        return []
    regex = _episode_label_regex(episode)
    selected: list[EpisodeCandidate] = []
    for items in grouped.values():
        exact = [item for item in items if regex.fullmatch(item.label.strip())]
        if exact:
            selected.append(exact[0])
        elif 1 <= episode <= len(items):
            selected.append(items[episode - 1])
    return selected


class SiteAnimeScraper(BaseScraper):
    """站点解析器基类。子类通过类属性描述形态,通常无需重写请求逻辑。"""

    site: str = "abstract"
    family: str = ""
    default_base_url: str = ""
    #: 站点状态三值。``parsed-dead`` 的站保留解析器但不应被注册进运行时。
    status: str = SITE_STATUS_OK
    #: 详情页路径模板,``{sid}`` 占位
    detail_template: str = ""
    #: 播放页链接正则(按顺序尝试,第一个命中者胜)
    play_link_patterns: tuple[str, ...] = ()
    #: 建本地索引用的列表页
    list_paths: tuple[str, ...] = ()
    #: 详情链接正则(用于从列表页抽 sid),需含一个捕获组
    detail_link_pattern: str = ""
    #: 站内搜索是否可用;False 时上层应改用本地索引
    site_search_usable: bool = True
    #: 播放时是否需要带 Referer(多数采集站 CDN 会校验)
    send_referer: bool = True

    def __init__(self, base_url: str | None = None) -> None:
        super().__init__()
        self._name = self.site
        self._base_url = (base_url or self.default_base_url).rstrip("/")

    @property
    def content_types(self) -> list[str]:
        return ["anime"]

    @property
    def base_url(self) -> str:
        return self._base_url

    def with_base_url(self, base_url: str) -> None:
        """域名族解析出新活域后就地切换(DomainWatch 的消费点)。"""
        if base_url:
            self._base_url = base_url.rstrip("/")

    # ── 站点级 Cookie ────────────────────────────────────────
    def session_cookie(self) -> str | None:
        """读取用户自备的会话 Cookie。

        某些站只在**首次搜索**时弹验证码,人过一次后 session 长期有效。
        本项目不去绕验证码,而是允许运维把自己的 Cookie 通过环境变量交给
        程序复用;没有则走无 Cookie 路径(通常退回本地索引)。
        """
        key = "SCRAPER_COOKIE_" + re.sub(r"[^A-Z0-9]", "", self.site.upper())
        value = os.environ.get(key, "").strip()
        return value or None

    def request_headers(self, *, referer: str = "") -> dict[str, str]:
        headers: dict[str, str] = {}
        if referer and self.send_referer:
            headers["Referer"] = referer
        cookie = self.session_cookie()
        if cookie:
            headers["Cookie"] = cookie
        return headers

    # ── 形态工具 ─────────────────────────────────────────────
    def detail_url(self, sid: str) -> str:
        if not self.detail_template or not str(sid).strip():
            return ""
        return urljoin(
            self._base_url + "/",
            self.detail_template.format(sid=str(sid).strip()).lstrip("/"),
        )

    def extract_play_links(self, html: str) -> list[str]:
        """按 ``play_link_patterns`` 顺序抽播放页链接,保序去重。"""
        for pattern in self.play_link_patterns:
            try:
                found = re.findall(pattern, html or "")
            except re.error:
                continue
            if found:
                links = [m if isinstance(m, str) else m[0] for m in found]
                return list(dict.fromkeys(links))
        return []

    @staticmethod
    def parse_player_config(html: str) -> dict:
        """取播放页内联的 ``player_aaaa`` JSON。解析失败返回空字典。"""
        import json

        for pattern in (
            r"player_aaaa\s*=\s*(\{.*?\})\s*</script>",
            r"player_aaaa\s*=\s*(\{.*?\});",
        ):
            match = re.search(pattern, html or "", re.S)
            if not match:
                continue
            try:
                data = json.loads(match.group(1))
            except ValueError:
                continue
            if isinstance(data, dict):
                return data
        return {}
