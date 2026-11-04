"""animeko 规则库的三个执行引擎:``web-selector`` / ``json-api`` / ``rss``。

本模块是 :mod:`server.scrapers.animeko_rules` 的**执行层**:规则只描述"怎么做",
这里负责真的发请求、真的解 DOM/JSON/XML。三条纪律:

1. **节流**:规则里的 ``requestInterval`` 只是君子协定,没有任何强制力。
   每个源一个 :class:`SourceThrottle`,同一源的所有请求串行排队,间隔不小于规则值。
2. **能被挡,不能被惊**:站点回 403/468/429 或甩验证码页时会抛
   :class:`SourceBlockedError`。调用方据此**跳过该源**,而不是让整轮搜索失败。
   判定顺序照抄上游 ``PageEvaluator``:先按规则解析,解析出内容就是最终真相,
   解析不出来才去看是不是被挡 —— 否则一个含 "captcha" 字样的正常页面会误判。
3. **URL 必须能落地**:播放页里匹配到的视频地址要带上站点的 cookie 与 Referer,
   因为这两者要跟着每一个 m3u8 分片请求走(见 :func:`extract_media_urls` 的调用方)。
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import re
import time
from dataclasses import dataclass, field
from html import unescape
from typing import Any, Iterable, Optional, Sequence
from urllib.parse import unquote, urljoin, urlparse

import httpx
from lxml import cssselect, etree, html as lxml_html

from ..base import DIRECT_MEDIA_URL, INVALID_MEDIA_URL, PLAYER_PAGE_URL, classify_media_url
from .animeko_rules import (
    ChannelFormatIndexGrouped,
    ChannelFormatNoChannel,
    JsonApiRequestConfig,
    JsonApiSearchConfig,
    MatchVideoConfig,
    MediaSourceRule,
    SelectorSearchConfig,
    compile_rule_pattern,
    quote_keyword,
)

logger = logging.getLogger(__name__)


class SourceBlockedError(Exception):
    """源把请求挡了(验证码 / 限流 / 封禁)。调用方应跳过该源。"""

    def __init__(self, rule_id: str, url: str, reason: str, status: int = 0) -> None:
        super().__init__(f"[{rule_id}] {reason} @ {url} (HTTP {status})")
        self.rule_id = rule_id
        self.url = url
        self.reason = reason
        self.status = status


class SourceUnavailableError(Exception):
    """源解析不出任何东西,也没有被挡特征。同样应当跳过该源。"""

    def __init__(self, rule_id: str, url: str, reason: str) -> None:
        super().__init__(f"[{rule_id}] {reason} @ {url}")
        self.rule_id = rule_id
        self.url = url
        self.reason = reason


# ── 节流 ──────────────────────────────────────────────────────────


class SourceThrottle:
    """按源串行的最小请求间隔闸门(对应规则的 ``requestInterval``)。

    实现照抄上游 ``delayUntilNextAllowedSearch``:抢占式 CAS 循环 —— 谁先抢到
    时间片谁发请求,其余人在等的时候重新计算,避免"同时全部放行"。
    """

    def __init__(self, interval_seconds: float, *, clock=time.monotonic) -> None:
        self._interval = max(0.0, float(interval_seconds))
        self._clock = clock
        self._last = 0.0
        self._lock = asyncio.Lock()

    @property
    def interval_seconds(self) -> float:
        return self._interval

    async def wait(self) -> None:
        if self._interval <= 0:
            return
        async with self._lock:
            now = self._clock()
            wait_for = self._last + self._interval - now
            if wait_for > 0:
                await asyncio.sleep(wait_for)
                now = self._clock()
            self._last = now


# ── HTTP ──────────────────────────────────────────────────────────

_CAPTCHA_MARKERS: tuple[str, ...] = (
    "cf-turnstile",
    "turnstile.render",
    "challenges.cloudflare.com/turnstile",
    "puzzle-container",
    "需要输入验证码",
    "__cf_chl_",
    "/cdn-cgi/challenge-platform/h/",
    "/cdn-cgi/challenge-platform/orchestrate/",
    "challenge-error-text",
    "enable javascript and cookies to continue",
    "cf-browser-verification",
    'id="cf-challenge"',
    "id='cf-challenge'",
    "window._cf_chl_opt",
    "/.safeline/static/favicon.png",
    'id="slg-box"',
    'id="slg-title"',
    "checking your browser before accessing",
)

_COOLDOWN_MARKERS: tuple[str, ...] = ("请不要频繁操作", "請不要頻繁操作", "搜索时间间隔", "搜索時間間隔")

_BLOCKED_STATUSES = frozenset({403, 468, 429})

#: 播放页里可能藏着真实播放器的属性名。规则里的 ``matchNestedUrl`` 就是拿来
#  挑这些地址的(比如 ``?.../addons/dp/player/x.php?``)。
_URL_ATTRIBUTE_RE = re.compile(
    r"""["'](?:src|href|data-url|data-src|data-play|data-video|url)["']\s*:\s*["']([^"']+)["']"""
    r"""|(?:src|href|data-url|data-src|data-play|data-video|url)\s*=\s*["']([^"']+)["']""",
    re.IGNORECASE,
)


def detect_block_reason(status: int, text: str) -> str:
    """判断响应是不是"被挡"。返回空串表示没有识别到被挡特征。"""
    lowered = (text or "").lower()
    if any(marker in lowered for marker in _COOLDOWN_MARKERS[:2]) and any(
        marker in (text or "") for marker in _COOLDOWN_MARKERS[2:]
    ):
        return "站点冷却页"
    if any(marker in lowered for marker in _CAPTCHA_MARKERS):
        return "验证码页"
    if status == 429:
        return "HTTP 429 限流"
    if status == 468:
        return "HTTP 468 验证码要求"
    if status == 403:
        return "HTTP 403 封禁"
    return ""


@dataclass
class PageResponse:
    url: str
    status: int
    text: str


class HttpFetcher:
    """按规则取页面的 HTTP 客户端。

    * **显式超时**:单次 HTTP 请求设置显式预算,避免慢站拖垮整轮搜索。
    * **有限重试**:只重试传输层错误(超时/连接重置),4xx 不重试 —— 被挡就要
      尽快跳开,重试只会加深封禁。
    * **内容协商**:搜索接口为 JSON 格式的源必须声明 ``application/json``,
      否则站点会回 HTML 登录/验证页(不报错,只是解析出 0 条)。
    """

    def __init__(
        self,
        *,
        client: Optional[httpx.AsyncClient] = None,
        transport: Optional[httpx.AsyncBaseTransport] = None,
        timeout_seconds: float = 15.0,
        retries: int = 2,
        retry_backoff_seconds: float = 0.8,
        default_user_agent: str = "",
        max_response_bytes: int = 1024 * 1024,
    ) -> None:
        self._client = client
        self._transport = transport
        self._owns_client = client is None
        self._timeout = max(1.0, timeout_seconds)
        self._retries = max(0, retries)
        self._backoff = max(0.0, retry_backoff_seconds)
        self._default_user_agent = default_user_agent
        self._max_response_bytes = max(1, max_response_bytes)
        self._throttles: dict[str, SourceThrottle] = {}

    def throttle_for(self, rule: MediaSourceRule) -> SourceThrottle:
        throttle = self._throttles.get(rule.id)
        if throttle is None:
            throttle = SourceThrottle(rule.request_interval_seconds)
            self._throttles[rule.id] = throttle
        return throttle

    def _ensure_client(self) -> httpx.AsyncClient:
        if self._client is None:
            headers = {"Accept-Language": "zh-CN,zh;q=0.9"}
            if self._default_user_agent:
                headers["User-Agent"] = self._default_user_agent
            self._client = httpx.AsyncClient(
                timeout=httpx.Timeout(self._timeout, connect=min(6.0, self._timeout)),
                follow_redirects=True,
                headers=headers,
                transport=self._transport,
            )
        return self._client

    async def aclose(self) -> None:
        if self._owns_client and self._client is not None:
            await self._client.aclose()
            self._client = None

    async def get(
        self,
        rule: MediaSourceRule,
        url: str,
        *,
        headers: Optional[dict[str, str]] = None,
        user_agent: Optional[str] = None,
        referer: str = "",
        expect_json: bool = False,
    ) -> PageResponse:
        """取一个页面。传输失败会重试,HTTP 错误状态原样返回给调用方判断。"""
        client = self._ensure_client()
        request_headers: dict[str, str] = {}
        if user_agent:
            request_headers["User-Agent"] = user_agent
        if referer:
            # 播放页普遍查 Referer,缺了会回"空壳页"(HTTP 200 但没有播放数据)。
            request_headers["Referer"] = referer
        if expect_json:
            # 与上游 SelectorHttpHeaders 一致:JSON 优先,同时接受 HTML,
            # 因为接口在验证码状态下会回 HTML 页面。
            request_headers["Accept"] = "application/json;q=1, text/html;q=0.9"
        else:
            request_headers["Accept"] = "text/html,application/xhtml+xml"
        if headers:
            request_headers.update({k: v for k, v in headers.items() if v})

        await self.throttle_for(rule).wait()
        last_error: Optional[BaseException] = None
        for attempt in range(self._retries + 1):
            if attempt:
                await asyncio.sleep(self._backoff * attempt)
            try:
                async with client.stream("GET", url, headers=request_headers) as response:
                    content_type = response.headers.get("Content-Type", "").split(";", 1)[0].lower().strip()
                    if content_type.startswith(("video/", "audio/")) or content_type in {
                        "application/vnd.apple.mpegurl", "application/x-mpegurl",
                        "application/dash+xml", "application/octet-stream",
                    }:
                        raise SourceUnavailableError(rule.id, url, "页面返回媒体而非元数据")
                    content_length = response.headers.get("Content-Length", "")
                    if content_length.isdigit() and int(content_length) > self._max_response_bytes:
                        raise SourceUnavailableError(rule.id, url, "页面超过元数据大小限制")
                    body = bytearray()
                    async for chunk in response.aiter_bytes(
                        chunk_size=min(64 * 1024, self._max_response_bytes + 1)
                    ):
                        if len(body) + len(chunk) > self._max_response_bytes:
                            raise SourceUnavailableError(rule.id, url, "页面超过元数据大小限制")
                        body.extend(chunk)
                    # 编码交给 httpx(它读 charset);BT 站常回 GBK。
                    return PageResponse(
                        url=str(response.url), status=response.status_code,
                        text=bytes(body).decode(response.encoding or "utf-8", errors="replace"),
                    )
            except httpx.HTTPError as error:
                last_error = error
                continue
        raise SourceUnavailableError(
            rule.id, url, f"网络错误 {type(last_error).__name__}"
        )


# ── CSS 选择器 ────────────────────────────────────────────────────

_UNQUOTED_ATTRIBUTE_RE = re.compile(
    r"""\[(\w[\w-]*)\s*([~^$*|]?=)\s*([^"'\]\s]+)\]"""
)


def _compile_css(selector: str) -> Optional[cssselect.CSSSelector]:
    """编译 CSS 选择器;失败时补引号再试一次。

    ``cssselect`` 比浏览器严格:``a[href^=#playlist]`` 这种没引号的属性值
    会被拒(# 不是合法 identifier),而站点规则里确实这么写。
    补引号是纯语法层面的等价改写,不改语义。
    """
    text = (selector or "").strip()
    if not text:
        return None
    for candidate in (
        text,
        _UNQUOTED_ATTRIBUTE_RE.sub(r'[\1\2"\3"]', text),
    ):
        try:
            # translator="html" 与 lxml 自己的 ``element.cssselect("...")`` 一致;
            # 用默认的 xml 翻译器会在 HTML 上把标签名当成大小写敏感。
            return cssselect.CSSSelector(candidate, translator="html")
        except Exception:  # noqa: BLE001 - 选择器来自外部数据
            continue
    logger.debug("CSS 选择器无法编译: %s", text[:80])
    return None


def parse_html(text: str) -> Optional[lxml_html.HtmlElement]:
    if not text:
        return None
    try:
        return lxml_html.fromstring(text)
    except (etree.ParserError, ValueError):
        return None


def select_elements(root: Any, selector: str) -> list[Any]:
    """在 ``root`` 上求一个 CSS 选择器。

    ``cssselect.CSSSelector`` 编译出来的对象本身就是可调用的 XPath,必须直接调用;
    把它再喂给 ``element.cssselect()`` 会抛 ``TypeError``(lxml 只接受字符串或
    翻译器),那样的失败会被下面的兜底吞掉 —— 表现就是"选择器全对却一条都选不到"。
    """
    compiled = _compile_css(selector)
    if compiled is None or root is None:
        return []
    try:
        return list(compiled(root))
    except Exception as error:  # noqa: BLE001 - 一个坏选择器只应让这一步为空
        logger.debug("CSS 选择器求值失败 %s: %s", selector[:60], type(error).__name__)
        return []


def element_text(element: Any) -> str:
    try:
        return (element.text_content() or "").strip()
    except AttributeError:
        return ""


def element_href(element: Any) -> str:
    """从元素上取链接:自身是 ``<a>`` 就用自身,否则找它内部第一个 ``<a>``。

    上游只认自身(非 ``<a>`` 时必须配 ``selectEpisodeLinksFromList``),但站点
    规则里存在"选中的是 ``li``、链接在子 ``a`` 上"的写法。向下找一层是对规则
    的超集兼容:规则写对了行为不变,写松了也能跑通。
    """
    if element is None:
        return ""
    href = str(element.get("href") or "").strip() if hasattr(element, "get") else ""
    if href:
        return href
    if hasattr(element, "get"):
        for attribute in ("data-href", "data-url", "data-src", "data-play"):
            value = str(element.get(attribute) or "").strip()
            if value:
                return value
    anchors = select_elements(element, "a[href]")
    if anchors:
        return str(anchors[0].get("href") or "").strip()
    return ""


def resolve_url(base: str, href: str) -> str:
    """把页面上的链接解析成绝对地址。

    ``base`` 可能是一个**目录**(详情页去掉最后一段),也可能只是源站根。
    两种情况都按"目录"处理:先补尾斜杠再 ``urljoin``,``/abs`` 与完整 URL
    不受影响。
    """
    value = (href or "").strip()
    if not value:
        return ""
    if value.startswith("//"):
        scheme = urlparse(base).scheme or "https"
        return f"{scheme}:{value}"
    if value.lower().startswith(("http://", "https://")):
        return value
    if value.startswith("data:") or value.startswith("javascript:"):
        return ""
    root = (base or "").strip()
    if not root:
        return value
    if not root.endswith("/"):
        root += "/"
    return urljoin(root, value)


def apply_link_template(template: str, raw_href: str) -> str:
    text = (template or "").strip()
    if not text:
        return raw_href
    return text.replace("{value}", raw_href)


def guess_id_from_url(href: str) -> str:
    """上游 ``guessIdFromUrl``:去掉尾斜杠与 ``.html``,取最后一段。"""
    text = (href or "").strip().rstrip("/")
    text = text.split("?")[0]
    if ".html" in text:
        text = text.rsplit(".html", 1)[0]
    return text.rsplit("/", 1)[-1]


# ── 剧集数据 ──────────────────────────────────────────────────────


@dataclass
class WebSubject:
    internal_id: str
    name: str
    url: str
    partial_url: str = ""


@dataclass
class WebEpisode:
    """一条剧集记录(属于某条线路)。"""

    name: str
    play_url: str
    channel: Optional[str] = None
    number: int = 0
    #: 页面上解析出的原始集号文本(可能是 "12" / "12.5" / "剧场版")。
    sort_text: str = ""
    #: 该记录在页面上的顺序。排序兜底时用得到。
    index: int = 0


_EPISODE_TOKEN_RE = re.compile(r"(\d+(?:\.\d+)?)")

#: "整部作品"式的标签:去掉画质/语言词后什么都不剩,这时按第 1 集处理。
_WHOLE_WORK_TOKENS = re.compile(
    "HD|BD|TC|HC|4K|2K|2160P|1440P|1080P|720P|"
    "超清|高清|清晰|流畅|标准|抢先|正片|全片|"
    "原声|原版|国语|日语|粤语|普通话|中字|中文|双语|字幕|版",
    re.IGNORECASE,
)
_WHOLE_WORK_SEPARATORS = set(" \t·・-—_/|+()（）【】[]")


def _is_whole_work_label(name: str) -> bool:
    text = (name or "").strip()
    if not text:
        return False
    remainder = _WHOLE_WORK_TOKENS.sub("", text)
    return not any(char not in _WHOLE_WORK_SEPARATORS for char in remainder)


def episode_number(name: str, sort_text: str, index: int) -> int:
    """把页面上的集号文本折算成整数集号。

    顺序:规则正则的 ``ep`` 命名组 → 名称里的第一串数字 → 页面顺序 +1。
    "正片/高清版/1080P" 这类整部作品标签按第 1 集算(上游
    ``convertSpecialEpisodes`` 的同款处理),否则一部剧场版会被算成第 0 集。
    """
    for candidate in (sort_text, name):
        match = _EPISODE_TOKEN_RE.search(candidate or "")
        if match:
            try:
                value = float(match.group(1))
            except ValueError:
                continue
            if value <= 0:
                continue
            return max(1, int(value))
    if _is_whole_work_label(name):
        return 1
    return max(1, index + 1)


# ── JSONPath(子集) ────────────────────────────────────────────────

_JSON_PATH_STEP_RE = re.compile(
    r"""\.([A-Za-z_][\w-]*)"""          # .name
    r"""|\[\s*'([^']+)'\s*(?:,\s*'([^']+)'\s*)*\]"""  # ['a','b']
    r"""|\[(\*|\d+)\]"""                # [*] / [0]
)
_JSON_PATH_KEY_RE = re.compile(r"""\[\s*'([^']+)'\s*\]""")


def _tokenize_json_path(expression: str) -> Optional[list[tuple[str, Any]]]:
    text = (expression or "").strip()
    if not text.startswith("$"):
        return None
    steps: list[tuple[str, Any]] = []
    rest = text[1:]
    position = 0
    while position < len(rest):
        chunk = rest[position:]
        if chunk.startswith("."):
            match = re.match(r"\.([A-Za-z_][\w-]*)", chunk)
            if not match:
                return None
            steps.append(("key", match.group(1)))
            position += match.end()
            continue
        bracket = re.match(r"\[([^\]]*)\]", chunk)
        if not bracket:
            return None
        inner = bracket.group(1).strip()
        position += bracket.end()
        if inner == "*":
            steps.append(("wildcard", None))
            continue
        if re.fullmatch(r"\d+", inner):
            steps.append(("index", int(inner)))
            continue
        keys = _JSON_PATH_KEY_RE.findall(f"[{inner}]")
        if not keys and inner.startswith("'") is False:
            return None
        if not keys:
            keys = [item.strip().strip("'") for item in inner.split(",")]
        steps.append(("keys", keys))
    return steps


def json_path_values(data: Any, expression: str) -> list[Any]:
    """求一个 JSONPath 子集,返回**全部**命中值。

    支持规则库里实际出现的三种形态:``$.a.b``、``$[*]``、``$[*]['title','name']``。
    多键写法(``['title','name']``)取**第一个存在**的键 —— 这与上游
    ``JsonElement.getSingleStringValueOrNull`` 的行为一致(按顺序回落到别名)。
    """
    steps = _tokenize_json_path(expression)
    if steps is None:
        return []
    current: list[Any] = [data]
    for kind, payload in steps:
        nxt: list[Any] = []
        for node in current:
            if kind == "key":
                if isinstance(node, dict) and payload in node:
                    nxt.append(node[payload])
            elif kind == "index":
                if isinstance(node, list) and -len(node) <= payload < len(node):
                    nxt.append(node[payload])
            elif kind == "wildcard":
                if isinstance(node, list):
                    nxt.extend(node)
                elif isinstance(node, dict):
                    nxt.extend(node.values())
            elif kind == "keys":
                if isinstance(node, dict):
                    for key in payload:
                        if key in node:
                            nxt.append(node[key])
                            break
        current = nxt
    return current


def json_path_first_string(data: Any, expression: str) -> Optional[str]:
    values = json_path_values(data, expression)
    for value in values:
        text = json_scalar_to_string(value)
        if text:
            return text
    return None


def json_scalar_to_string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        if isinstance(value, float) and value.is_integer():
            return str(int(value))
        return str(value)
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, list):
        for item in value:
            text = json_scalar_to_string(item)
            if text:
                return text
        return ""
    if isinstance(value, dict):
        for item in value.values():
            text = json_scalar_to_string(item)
            if text:
                return text
    return ""


# ── 关键词归一化 ──────────────────────────────────────────────────

#: 上游 ``MediaListFilters.removeSpecials(removeWhitespace=false, replaceNumbers=false,
#  removeMarkers=true)`` 里会被删掉的标记词。删掉它们是为了让"剧场版 命运石之门"
#  这种写法退化成"命运石之门",否则搜索接口一个字都对不上。
_MARKER_TOKENS = re.compile(
    r"剧场版|劇場版|完全版|导演剪辑版|導演剪輯版|特别篇|特別篇|"
    r"OVA|OAD|SP|TV版|合集|全集|高清版|蓝光版|藍光版",
    re.IGNORECASE,
)
_SPECIAL_CHARS = "【】〖〗[]()（）「」『』《》〈〉\"'“”‘’·・、,，。．.!！?？:：;；~～-_—+=*/\\|&^%$#@`"


def normalize_search_keyword(
    keyword: str, *, remove_special: bool, use_only_first_word: bool
) -> str:
    text = (keyword or "").strip()
    if remove_special:
        text = _MARKER_TOKENS.sub(" ", text)
        text = "".join(char for char in text if char not in _SPECIAL_CHARS)
        text = re.sub(r"\s+", " ", text).strip()
    if use_only_first_word and " " in text:
        head = text.split(" ", 1)[0].strip()
        if head:
            text = head
    return text or (keyword or "").strip()


# ── web-selector 引擎 ─────────────────────────────────────────────


class SelectorEngine:
    """执行 ``web-selector`` 规则:搜索 → 详情 → 线路/剧集 → 播放页取地址。"""

    def __init__(self, rule: MediaSourceRule, fetcher: HttpFetcher) -> None:
        assert rule.selector is not None
        self.rule = rule
        self.config: SelectorSearchConfig = rule.selector
        self.fetcher = fetcher

    # ── 搜索 ────────────────────────────────────────────────

    async def search(self, keyword: str) -> list[WebSubject]:
        """按规则搜索。返回条目列表;被挡时抛 :class:`SourceBlockedError`。

        关键词先按规则自己的 ``searchRemoveSpecial`` / ``searchUseOnlyFirstWord``
        归一化(与上游一致)。归一化后与原文不同且没搜到东西时,**再用原文补搜
        一次** —— 服务端的调用方已经给了完整标题,不必因为规则想泛化就丢结果。
        """
        normalized = normalize_search_keyword(
            keyword,
            remove_special=self.config.auto_match.search_remove_special,
            use_only_first_word=self.config.auto_match.search_use_only_first_word,
        )
        subjects = await self._search_once(normalized)
        if subjects or normalized == (keyword or "").strip():
            return subjects
        return await self._search_once((keyword or "").strip())

    async def _search_once(self, keyword: str) -> list[WebSubject]:
        url = self.config.search_url.replace("{keyword}", quote_keyword(keyword))
        if not url:
            return []
        response = await self.fetcher.get(
            self.rule,
            url,
            user_agent=self.config.user_agent_or_none,
            expect_json=self.rule.expects_json_search(),
        )
        subjects = self.parse_search(response.text)
        if subjects:
            return subjects
        reason = detect_block_reason(response.status, response.text)
        if reason:
            raise SourceBlockedError(self.rule.id, url, reason, response.status)
        if response.status >= 400:
            raise SourceUnavailableError(
                self.rule.id, url, f"搜索返回 HTTP {response.status}"
            )
        return []

    def parse_search(self, text: str) -> list[WebSubject]:
        format_id = self.config.subject_format_id
        if format_id == "json-path-indexed":
            return self._parse_search_json(text)
        base_url = self.config.final_base_url
        if format_id == "indexed":
            return self._parse_search_indexed(text, base_url)
        return self._parse_search_anchors(text, base_url)

    def _parse_search_anchors(self, text: str, base_url: str) -> list[WebSubject]:
        config = self.config.subject_format_a
        root = parse_html(text)
        subjects: list[WebSubject] = []
        for element in select_elements(root, config.select_lists):
            # 上游优先用 title 属性:站点的图片链接常没有文本,只有 title。
            name = str(element.get("title") or "").strip() or element_text(element)
            href = element_href(element)
            subject = self._build_subject(name, href, base_url, config.link_template)
            if subject is not None:
                subjects.append(subject)
        return subjects

    def _parse_search_indexed(self, text: str, base_url: str) -> list[WebSubject]:
        config = self.config.subject_format_indexed
        root = parse_html(text)
        names = [
            element_text(element)
            for element in select_elements(root, config.select_names)
        ]
        names = [name for name in names if name]
        links = [
            str(element.get("href") or "").strip()
            for element in select_elements(root, config.select_links)
        ]
        links = [link for link in links if link]
        subjects: list[WebSubject] = []
        for name, href in zip(names, links):
            subject = self._build_subject(name, href, base_url, config.link_template)
            if subject is not None:
                subjects.append(subject)
        return subjects

    def _parse_search_json(self, text: str) -> list[WebSubject]:
        import json as _json

        config = self.config.subject_format_json_path
        try:
            data = _json.loads(text)
        except ValueError:
            return []
        names = [
            value
            for value in (
                json_scalar_to_string(item)
                for item in json_path_values(data, config.select_names)
            )
            if value
        ]
        links = [
            value
            for value in (
                json_scalar_to_string(item)
                for item in json_path_values(data, config.select_links)
            )
            if value
        ]
        base_url = self.config.final_base_url
        subjects: list[WebSubject] = []
        for name, href in zip(names, links):
            subject = self._build_subject(name, href, base_url, config.link_template)
            if subject is not None:
                subjects.append(subject)
        return subjects

    def _build_subject(
        self, name: str, raw_href: str, base_url: str, link_template: str
    ) -> Optional[WebSubject]:
        if not name or not raw_href:
            return None
        href = apply_link_template(link_template, raw_href)
        full_url = resolve_url(base_url, href)
        if not full_url:
            return None
        return WebSubject(
            internal_id=guess_id_from_url(href) or guess_id_from_url(full_url),
            name=name,
            url=full_url,
            partial_url=href,
        )

    # ── 详情页:线路与剧集 ──────────────────────────────────

    async def episodes(self, subject_url: str) -> list[WebEpisode]:
        response = await self.fetcher.get(
            self.rule,
            subject_url,
            user_agent=self.config.user_agent_or_none,
        )
        episodes = self.parse_episodes(response.text, subject_url)
        if episodes:
            return episodes
        reason = detect_block_reason(response.status, response.text)
        if reason:
            raise SourceBlockedError(self.rule.id, subject_url, reason, response.status)
        raise SourceUnavailableError(
            self.rule.id, subject_url, f"详情页无可解析剧集(HTTP {response.status})"
        )

    def parse_episodes(self, text: str, subject_url: str) -> list[WebEpisode]:
        root = parse_html(text)
        if root is None:
            return []
        # 相对链接的解析基准是"详情页所在目录"(上游 dropLast(1))。
        base_url = subject_url.rstrip("/")
        if "/" in base_url.split("//")[-1]:
            base_url = base_url.rsplit("/", 1)[0]
        if self.config.channel_format_id == "index-grouped":
            return self._parse_episodes_grouped(root, base_url)
        return self._parse_episodes_no_channel(root, base_url)

    def _parse_episodes_grouped(
        self, root: Any, base_url: str
    ) -> list[WebEpisode]:
        config: ChannelFormatIndexGrouped = self.config.channel_format_index_grouped
        channel_pattern = compile_rule_pattern(config.match_channel_name)
        sort_pattern = compile_rule_pattern(config.match_episode_sort_from_name)
        labels: list[Optional[tuple[str, str]]] = []
        for element in select_elements(root, config.select_channel_names):
            label = element_text(element)
            if not label:
                labels.append(None)
                continue
            if channel_pattern is None:
                labels.append((label, label))
                continue
            match = channel_pattern.search(label)
            name = match.group("ch") if match and "ch" in (match.groupdict() or {}) else None
            if match and name is None:
                name = match.group(0)
            labels.append((label, name.strip()) if name else None)

        lists = select_elements(root, config.select_episode_lists)
        episodes: list[WebEpisode] = []
        counter = 0
        for channel, container in zip(labels, lists):
            if channel is None:
                continue
            _, channel_name = channel
            link_values: Optional[list[str]] = None
            if config.select_episode_links_from_list:
                link_values = [
                    str(element.get("href") or "").strip()
                    for element in select_elements(
                        container, config.select_episode_links_from_list
                    )
                ]
            for index, element in enumerate(
                select_elements(container, config.select_episodes_from_list)
            ):
                name = element_text(element)
                href = (
                    link_values[index]
                    if link_values is not None and index < len(link_values)
                    else element_href(element)
                )
                episode = self._build_episode(
                    name, href, base_url, channel_name, counter, sort_pattern
                )
                if episode is not None:
                    episodes.append(episode)
                    counter += 1
        return episodes

    def _parse_episodes_no_channel(self, root: Any, base_url: str) -> list[WebEpisode]:
        config: ChannelFormatNoChannel = self.config.channel_format_no_channel
        sort_pattern = compile_rule_pattern(config.match_episode_sort_from_name)
        link_values: Optional[list[str]] = None
        if config.select_episode_links:
            link_values = [
                str(element.get("href") or "").strip()
                for element in select_elements(root, config.select_episode_links)
            ]
        episodes: list[WebEpisode] = []
        for index, element in enumerate(
            select_elements(root, config.select_episodes)
        ):
            name = element_text(element)
            href = (
                link_values[index]
                if link_values is not None and index < len(link_values)
                else element_href(element)
            )
            episode = self._build_episode(name, href, base_url, None, index, sort_pattern)
            if episode is not None:
                episodes.append(episode)
        return episodes

    def _build_episode(
        self,
        name: str,
        href: str,
        base_url: str,
        channel: Optional[str],
        index: int,
        sort_pattern: Optional[re.Pattern[str]],
    ) -> Optional[WebEpisode]:
        if not href:
            return None
        sort_text = ""
        if sort_pattern is not None:
            match = sort_pattern.search(name or "")
            if match:
                groups = match.groupdict()
                sort_text = groups.get("ep") or match.group(0)
        play_url = resolve_url(base_url, href)
        if not play_url:
            return None
        return WebEpisode(
            name=name or f"第{index + 1}集",
            play_url=play_url,
            channel=channel,
            number=episode_number(name, sort_text, index),
            sort_text=sort_text,
            index=index,
        )

    # ── 播放页:提取视频地址 ────────────────────────────────

    async def media_urls(self, play_url: str) -> list[str]:
        """静态取流;嵌套最多 3 层/6 页,去重循环且不请求已知媒体地址。"""
        response = await self.fetcher.get(
            self.rule,
            play_url,
            headers={"Referer": self.config.final_base_url or play_url},
            user_agent=self._user_agent_for_play(),
        )
        urls = extract_media_urls(response.text, self.config.match_video)
        if urls:
            return urls
        reason = detect_block_reason(response.status, response.text)
        if reason:
            raise SourceBlockedError(self.rule.id, play_url, reason, response.status)
        page_url = response.url or play_url
        pending = [(response, page_url, 0)]
        visited = {play_url, page_url}
        followed = 0
        blocked: Optional[SourceBlockedError] = None
        for page, parent_url, depth in pending:
            if depth >= 3:
                continue
            for nested in self.nested_candidates(page.text, parent_url):
                if nested in visited or followed >= 6:
                    continue
                visited.add(nested)
                followed += 1
                try:
                    nested_response = await self.fetcher.get(
                        self.rule,
                        nested,
                        headers={"Referer": parent_url},
                        user_agent=self._user_agent_for_play(),
                    )
                except SourceUnavailableError:
                    continue
                nested_url = nested_response.url or nested
                # 重定向别名也加入集合,避免 A -> B -> A 反复跟进。
                visited.add(nested_url)
                urls = extract_media_urls(nested_response.text, self.config.match_video)
                if urls:
                    return urls
                reason = detect_block_reason(nested_response.status, nested_response.text)
                if reason:
                    blocked = SourceBlockedError(
                        self.rule.id, nested_url, reason, nested_response.status
                    )
                    continue
                pending.append((nested_response, nested_url, depth + 1))
        if blocked is not None:
            raise blocked
        return []

    def _user_agent_for_play(self) -> Optional[str]:
        # 6.3 起 UA 归 searchConfig.userAgent;旧规则只在 addHeadersToVideo 里写。
        return self.config.user_agent_or_none or (
            self.config.match_video.user_agent or None
        )

    def nested_candidates(self, text: str, page_url: str) -> list[str]:
        """规则匹配的嵌套入口;未配模式时只信 DOM 中的实际 iframe。

        典型的嵌套入口长这样:``https://站点/static/player/artplayer.html?url=``
        或 ``https://vip.example/?url=`` —— 页面本身没有视频地址,真正的地址要进
        这一层才有。
        """
        match_video = self.config.match_video
        if not match_video.enable_nested_url:
            return []
        pattern = match_video.nested_pattern
        # 空模式仅跟进真实 iframe;显式无效/不匹配模式仍按规则关闭跟进。
        if pattern is None and match_video.match_nested_url.strip():
            return []
        _, remainder = _static_player_urls(text)
        frames: list[str] = []
        for element in select_elements(parse_html(remainder), "iframe[src], iframe[data-src]"):
            value = element.get("src") or element.get("data-src") or ""
            if value.strip():
                frames.append(_clean_candidate(value))
        candidates = frames + (candidate_urls(text) if pattern is not None else [])
        resolved: list[str] = []
        seen: set[str] = set()
        for candidate in candidates:
            # 嵌套链接遵循当前文档 URL 的标准相对解析,不是站点目录拼接。
            url = urljoin(page_url, candidate)
            if (
                not url or url in seen
                or classify_media_url(url) in {INVALID_MEDIA_URL, DIRECT_MEDIA_URL}
            ):
                continue
            seen.add(url)
            if pattern is None or pattern.search(url):
                resolved.append(url)
            if len(resolved) >= 12:
                break
        return resolved


# ── 视频地址提取 ──────────────────────────────────────────────────

_TRAILING_JUNK = "\"'<>),;、。,\\}"
_PLAYER_ASSIGNMENT_RE = re.compile(
    r"(?<![\w$.])(?:window\s*\.\s*)?player_(?:aaaa|data)\s*=\s*",
    re.IGNORECASE,
)
_MAX_PLAYER_JSON_CHARS = 256 * 1024
_MAX_PLAYER_OBJECTS = 16
_JS_UNICODE_ESCAPE_RE = re.compile(r"%u([0-9a-fA-F]{4})")


def _decode_player_url(data: dict[str, Any]) -> str:
    """只解释 MacCMS 已知的 0/1/2 编码,不求值任何 JavaScript。"""
    value = data.get("url")
    if not isinstance(value, str) or len(value) > _MAX_PLAYER_JSON_CHARS:
        return ""
    mode = str(data.get("encrypt", 0))
    if mode not in {"0", "1", "2"}:
        return ""
    try:
        if mode == "2":
            value = base64.b64decode(value, validate=True).decode("utf-8")
        if mode in {"1", "2"}:
            # MacCMS 的 unescape(base64decode(url)) 也接受旧式 %uXXXX。
            value = _JS_UNICODE_ESCAPE_RE.sub(
                lambda match: chr(int(match.group(1), 16)), value
            )
            value = unquote(value, errors="strict")
    except (ValueError, UnicodeError, binascii.Error):
        return ""
    return _clean_candidate(value)


def _static_player_urls(text: str) -> tuple[list[str], str]:
    """解析静态 JSON 赋值并遮掉整个对象,避免误提取 url_next/url_pre。

    JSONDecoder 能处理嵌套 vod_data 与转义引号,不靠贪婪对象正则;
    大小/对象数均有上限,自定义加密和 JS 表达式不执行。
    """
    decoder = json.JSONDecoder()
    urls: list[str] = []
    spans: list[tuple[int, int]] = []
    for index, match in enumerate(_PLAYER_ASSIGNMENT_RE.finditer(text)):
        if index >= _MAX_PLAYER_OBJECTS:
            break
        start = match.end()
        try:
            data, end = decoder.raw_decode(text[start:start + _MAX_PLAYER_JSON_CHARS])
        except (ValueError, RecursionError):
            continue
        if not isinstance(data, dict):
            continue
        spans.append((start, start + end))
        value = _decode_player_url(data)
        if value and value not in urls:
            urls.append(value)
    if not spans:
        return urls, text
    chunks: list[str] = []
    position = 0
    for start, end in spans:
        if start < position:
            continue
        chunks.append(text[position:start])
        chunks.append(" ")
        position = end
    chunks.append(text[position:])
    return urls, "".join(chunks)


#: 页面里出现的"像 URL 的字符串"。这是视频地址匹配的**输入单位**。
_CANDIDATE_URL_RE = re.compile(
    r"""https?://[^\s"'<>\\\)\]\}\u3000]+""", re.IGNORECASE
)


def _clean_candidate(value: str) -> str:
    return unescape(value).replace("\\/", "/").strip().strip(_TRAILING_JUNK)


def _accept(
    candidate: str, pattern: re.Pattern[str], seen: set[str], urls: list[str]
) -> None:
    if not candidate or candidate in seen:
        return
    lowered = candidate.lower()
    if not lowered.startswith(("http://", "https://")):
        return
    # 明确的播放页/无效地址不交付;无扩展名的直链保留,交给服务端嗅探。
    if classify_media_url(candidate) in {INVALID_MEDIA_URL, PLAYER_PAGE_URL}:
        return
    seen.add(candidate)
    urls.append(candidate)


def candidate_urls(text: str) -> list[str]:
    """从页面源码里捞出所有候选 URL(去重、保序)。

    站点把真实地址藏在 JSON、内联 ``<script>``、``data-*`` 属性里,形态极不统一;
    与其为每种写法写一个正则,不如先把"像 URL 的东西"全捞出来,再交给规则自己的
    ``matchVideoUrl`` 过滤 —— 这正是上游的做法(它匹配的是浏览器发出去的**请求
    URL**,而不是页面文本)。
    """
    found: list[str] = []
    seen: set[str] = set()
    player_urls, remainder = _static_player_urls(text)
    for value in player_urls:
        if value not in seen:
            seen.add(value)
            found.append(value)
    normalized = remainder.replace("\\/", "/")
    for match in _CANDIDATE_URL_RE.finditer(normalized):
        value = _clean_candidate(match.group(0))
        if value and value not in seen:
            seen.add(value)
            found.append(value)
    for match in _URL_ATTRIBUTE_RE.finditer(normalized):
        value = _clean_candidate(match.group(1) or match.group(2) or "")
        if value and value not in seen:
            seen.add(value)
            found.append(value)
    return found


def extract_media_urls(text: str, config: MatchVideoConfig) -> list[str]:
    """用规则的 ``matchVideoUrl`` 从播放页源码里抠出视频地址。

    匹配分两轮,顺序不能换:

    1. **按候选 URL 匹配**(主路径)。规则的 ``matchVideoUrl`` 几乎都以 ``^http``
       开头并带 URL 形状的分支(``(akamaized)``、``\\.m3u8``),
       它是拿来过滤**一条 URL**的,不是拿来在整页 HTML 里搜索的 —— 上游把它用在
       WebView 发出的每个请求 URL 上。所以先把页面里的候选地址捞出来再逐条过规则。
    2. **整页文本匹配**(兜底)。少数规则写成 ``url=(?<v>http...)`` 这种"带前缀"
   形态,靠命名组 ``v`` 取地址,这种只在原文上匹配才成立。

    只做提取,不验证可播性:最终能不能播由服务端验线决定。
    """
    pattern = config.video_pattern
    if pattern is None or not text:
        return []
    urls: list[str] = []
    seen: set[str] = set()
    for candidate in candidate_urls(text):
        match = pattern.search(candidate)
        if not match:
            continue
        groups = match.groupdict()
        value = groups.get("v") if "v" in groups else None
        _accept(_clean_candidate(value or candidate), pattern, seen, urls)

    _, remainder = _static_player_urls(text)
    haystack = remainder.replace("\\/", "/")
    for match in pattern.finditer(haystack):
        groups = match.groupdict()
        value = groups.get("v") if "v" in groups else None
        _accept(_clean_candidate(value or match.group(0)), pattern, seen, urls)
    return urls


# ── json-api 引擎 ─────────────────────────────────────────────────


def escape_json_string(value: str) -> str:
    """把值塞进 JSON 字符串字面量里(不含两侧引号)。"""
    if not any(char in value for char in '"\\\n\r\t') and not any(
        ord(char) < 0x20 for char in value
    ):
        return value
    out: list[str] = []
    for char in value:
        if char == '"':
            out.append('\\"')
        elif char == "\\":
            out.append("\\\\")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif char == "\b":
            out.append("\\b")
        elif char == "\f":
            out.append("\\f")
        elif ord(char) < 0x20:
            out.append(f"\\u{ord(char):04x}")
        else:
            out.append(char)
    return "".join(out)


_VARIABLE_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


def substitute_template(template: str, variables: dict[str, str], *, json_mode: bool) -> str:
    """``{var}`` 模板代入。未定义的变量原样保留(便于定位规则缺字段)。"""
    text = template or ""
    if "{" not in text:
        return text

    def render(match: re.Match[str]) -> str:
        value = variables.get(match.group(1))
        if value is None:
            return match.group(0)
        return escape_json_string(value) if json_mode else value

    return _VARIABLE_RE.sub(render, text)


def parse_header_lines(text: str) -> list[tuple[str, str]]:
    """解析 json-api 规则里的 ``k: v`` 多行头。"""
    headers: list[tuple[str, str]] = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        name, _, value = line.partition(":")
        name = name.strip()
        if name:
            headers.append((name, value.strip()))
    return headers


class JsonApiEngine:
    """执行 ``json-api`` 规则:全部内容都靠请求模板 + JSONPath。"""

    def __init__(self, rule: MediaSourceRule, fetcher: HttpFetcher) -> None:
        assert rule.json_api is not None
        self.rule = rule
        self.config: JsonApiSearchConfig = rule.json_api
        self.fetcher = fetcher

    # ── 请求构造 ────────────────────────────────────────────

    def _prepare(
        self, request: JsonApiRequestConfig, variables: dict[str, str]
    ) -> Optional[tuple[str, str, dict[str, str], str]]:
        url_template = substitute_template(request.url, variables, json_mode=False)
        if not url_template:
            return None
        url = url_template
        if not url.lower().startswith(("http://", "https://")):
            base = (self.config.base_url or "").strip()
            if not base:
                return None
            url = resolve_url(base, url_template)
        headers: dict[str, str] = {}
        for name, value in parse_header_lines(self.config.headers) + parse_header_lines(
            request.headers
        ):
            headers[name] = substitute_template(value, variables, json_mode=False)
        body = ""
        if request.body.strip() and request.method != "GET":
            body = substitute_template(request.body, variables, json_mode=True)
        return url, request.method, headers, body

    async def _send(
        self, request: JsonApiRequestConfig, variables: dict[str, str]
    ) -> Optional[Any]:
        prepared = self._prepare(request, variables)
        if prepared is None:
            return None
        url, method, headers, body = prepared
        client = self.fetcher._ensure_client()  # noqa: SLF001 - 同一连接池与节流
        await self.fetcher.throttle_for(self.rule).wait()
        if body:
            headers.setdefault("Content-Type", "application/json")
        headers.setdefault("Accept", "application/json")
        if self.config.user_agent_or_none:
            headers["User-Agent"] = self.config.user_agent_or_none or ""
        try:
            response = await client.request(
                method, url, headers=headers, content=body.encode("utf-8") if body else None
            )
        except httpx.HTTPError as error:
            raise SourceUnavailableError(
                self.rule.id, url, f"网络错误 {type(error).__name__}"
            ) from error
        if response.status_code >= 400:
            reason = detect_block_reason(response.status_code, response.text)
            if reason:
                raise SourceBlockedError(
                    self.rule.id, url, reason, response.status_code
                )
            raise SourceUnavailableError(
                self.rule.id, url, f"接口返回 HTTP {response.status_code}"
            )
        try:
            return response.json()
        except ValueError as error:
            raise SourceUnavailableError(self.rule.id, url, "接口未返回 JSON") from error

    # ── 搜索 ────────────────────────────────────────────────

    async def search(self, keyword: str) -> list[WebSubject]:
        normalized = normalize_search_keyword(
            keyword,
            remove_special=self.config.auto_match.search_remove_special,
            use_only_first_word=self.config.auto_match.search_use_only_first_word,
        )
        subjects = await self._search_once(normalized)
        if subjects or normalized == (keyword or "").strip():
            return subjects
        return await self._search_once((keyword or "").strip())

    async def _search_once(self, keyword: str) -> list[WebSubject]:
        variables = {
            "keyword": keyword,
            "page": "1",
            "pageSize": str(max(1, self.config.page_size)),
        }
        data = await self._send(self.config.search_request, variables)
        if data is None:
            return []
        return self.parse_search(data)

    def parse_search(self, data: Any) -> list[WebSubject]:
        subjects: list[WebSubject] = []
        for item in json_path_values(data, self.config.select_items):
            name = json_path_first_string(item, self.config.select_name)
            identifier = json_path_first_string(item, self.config.select_id)
            if not name or not identifier:
                continue
            url = substitute_template(
                self.config.subject_url_template, {"id": identifier}, json_mode=False
            )
            subjects.append(
                WebSubject(
                    internal_id=identifier,
                    name=name,
                    url=url,
                    partial_url=url,
                )
            )
        return subjects

    # ── 详情 ────────────────────────────────────────────────

    async def episodes(self, subject: WebSubject) -> list[WebEpisode]:
        variables = {
            "id": subject.internal_id,
            "url": subject.url,
            "name": subject.name,
        }
        data = await self._send(self.config.subject_request, variables)
        if data is None:
            return []
        return self.parse_episodes(data, variables)

    def parse_episodes(
        self, data: Any, subject_variables: dict[str, str]
    ) -> list[WebEpisode]:
        episodes_config = self.config.episodes
        type_mapping = self._parse_type_mapping(episodes_config.type_mapping)
        episodes: list[WebEpisode] = []
        channels = self._channels(data)
        for index, item in enumerate(
            json_path_values(data, episodes_config.select_episodes)
        ):
            name = json_path_first_string(item, episodes_config.select_name) or ""
            identifier = json_path_first_string(item, episodes_config.select_id) or ""
            sort_text = json_path_first_string(item, episodes_config.select_sort) or ""
            kind = json_path_first_string(item, episodes_config.select_type) or ""
            kind = type_mapping.get(kind.lower(), kind)
            display = self._episode_display_name(
                episodes_config.name_template, sort_text, name, identifier
            )
            # grouped 格式里线路表与剧集表同序;数量对不上时宁可不标线路,
            # 免得把线路名错配到别的剧集上。
            channel_name = channels[index][0] if index < len(channels) else None
            url_variables = dict(subject_variables)
            url_variables.update({"id": identifier, "subjectId": subject_variables.get("id", "")})
            play_url = substitute_template(
                episodes_config.episode_url_template, url_variables, json_mode=False
            )
            if not play_url:
                continue
            episodes.append(
                WebEpisode(
                    name=display,
                    play_url=play_url,
                    channel=channel_name,
                    number=episode_number(display, sort_text, index),
                    sort_text=sort_text,
                    index=index,
                )
            )
            if kind:
                # ``selectType`` 只在同一集有正片/SP 之分时用来区分展示;
                # 目前不参与编号,记录在 sort_text 之外不额外建字段。
                episodes[-1].sort_text = sort_text or kind
        return episodes

    @staticmethod
    def _parse_type_mapping(text: str) -> dict[str, str]:
        mapping: dict[str, str] = {}
        for line in (text or "").splitlines():
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            if key.strip():
                mapping[key.strip().lower()] = value.strip()
        return mapping

    @staticmethod
    def _episode_display_name(
        template: str, sort_text: str, name: str, identifier: str
    ) -> str:
        if not template:
            return name or (f"第{sort_text}集" if sort_text else identifier)
        return substitute_template(
            template,
            {"sort": sort_text, "name": name, "id": identifier},
            json_mode=False,
        ).strip() or name

    def _channels(self, data: Any) -> list[tuple[str, str]]:
        """按 ``channelFormatGrouped`` 取线路名。索引对齐剧集表的顺序。"""
        if self.config.channel_format_id not in {"grouped", "index-grouped"}:
            return []
        channel_items = json_path_values(data, self.config.select_channels)
        result: list[tuple[str, str]] = []
        for item in channel_items:
            name = json_path_first_string(item, self.config.select_channel_name)
            if name:
                result.append((name, name))
        return result

    # ── 播放 ────────────────────────────────────────────────

    async def media_urls(self, episode: WebEpisode, subject: WebSubject) -> list[str]:
        variables = {
            "id": "",
            "url": episode.play_url,
            "name": episode.name,
            "subjectId": subject.internal_id,
            "subjectUrl": subject.url,
            "subjectName": subject.name,
        }
        if episode.channel:
            variables["channel"] = episode.channel
            variables["channelMatch"] = episode.channel
        data = await self._send(self.config.play_request, variables)
        if data is None:
            return []
        return self.parse_video(data, episode.channel)

    def parse_video(self, data: Any, channel_match: Optional[str]) -> list[str]:
        select_video_url = self.config.select_video_url
        if not select_video_url:
            return []
        if not self.config.select_candidates:
            value = json_path_first_string(data, select_video_url)
            return [value] if value and value.lower().startswith("http") else []
        candidates: list[tuple[Optional[str], str]] = []
        for item in json_path_values(data, self.config.select_candidates):
            url = json_path_first_string(item, select_video_url)
            if not url or not url.lower().startswith("http"):
                continue
            channel = (
                json_path_first_string(item, self.config.select_candidate_channel)
                if self.config.select_candidate_channel
                else None
            )
            candidates.append((channel, url))
        if not candidates:
            return []
        if channel_match and self.config.select_candidate_channel:
            for channel, url in candidates:
                if channel and channel.lower() == channel_match.lower():
                    return [url]
            if not self.config.fallback_to_first_candidate:
                return []
        return [candidates[0][1]]


# ── rss 引擎 ──────────────────────────────────────────────────────


@dataclass
class TorrentItem:
    title: str
    link: str = ""
    guid: str = ""
    magnet: str = ""
    size_text: str = ""


class RssEngine:
    """执行 ``rss`` 规则。BT 站只给资源列表,没有直链播放链。"""

    def __init__(self, rule: MediaSourceRule, fetcher: HttpFetcher) -> None:
        assert rule.rss is not None
        self.rule = rule
        self.config = rule.rss
        self.fetcher = fetcher

    async def search(self, keyword: str) -> list[TorrentItem]:
        url = (self.config.search_url or "").replace(
            "{keyword}", quote_keyword(keyword)
        )
        if not url:
            return []
        response = await self.fetcher.get(self.rule, url)
        if response.status >= 400:
            reason = detect_block_reason(response.status, response.text)
            if reason:
                raise SourceBlockedError(self.rule.id, url, reason, response.status)
            raise SourceUnavailableError(
                self.rule.id, url, f"RSS 返回 HTTP {response.status}"
            )
        return parse_rss_items(response.text)


def parse_rss_items(text: str) -> list[TorrentItem]:
    """解析 RSS 2.0 与 Atom。命名空间一律按 local-name 匹配,免得写死前缀。"""
    if not text or "<" not in text:
        return []
    try:
        root = etree.fromstring(text.encode("utf-8", errors="replace"))
    except etree.XMLSyntaxError:
        return []
    items: list[TorrentItem] = []
    for element in root.iter():
        tag = etree.QName(element).localname.lower() if isinstance(
            element.tag, str
        ) else ""
        if tag not in {"item", "entry"}:
            continue
        title = ""
        link = ""
        guid = ""
        magnet = ""
        size_text = ""
        for child in element:
            child_tag = (
                etree.QName(child).localname.lower()
                if isinstance(child.tag, str)
                else ""
            )
            child_text = (child.text or "").strip()
            if child_tag == "title" and not title:
                title = child_text
            elif child_tag == "link" and not link:
                link = child_text or str(child.get("href") or "").strip()
            elif child_tag in {"guid", "id"} and not guid:
                guid = child_text
            elif child_tag in {"enclosure", "content"} and not link:
                link = str(child.get("url") or "").strip()
            elif child_tag in {"contentLength", "length", "size"} and not size_text:
                size_text = child_text or str(child.get("length") or "")
            if child_text.lower().startswith("magnet:"):
                magnet = child_text
        if not title:
            continue
        # nyaa 的 RSS 把种子链接放在 <link>,磁力在 <guid> 或 enclosure 里。
        for value in (guid, link):
            if value.lower().startswith("magnet:") and not magnet:
                magnet = value
        items.append(
            TorrentItem(
                title=title,
                link=link,
                guid=guid,
                magnet=magnet,
                size_text=size_text,
            )
        )
    return items


__all__ = [
    "HttpFetcher",
    "JsonApiEngine",
    "PageResponse",
    "RssEngine",
    "SelectorEngine",
    "SourceBlockedError",
    "SourceThrottle",
    "SourceUnavailableError",
    "TorrentItem",
    "WebEpisode",
    "WebSubject",
    "candidate_urls",
    "detect_block_reason",
    "episode_number",
    "extract_media_urls",
    "json_path_first_string",
    "json_path_values",
    "normalize_search_keyword",
    "parse_html",
    "parse_rss_items",
    "resolve_url",
    "select_elements",
    "substitute_template",
]
