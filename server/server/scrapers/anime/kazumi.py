"""Kazumi 规则库动漫源适配器(provider id ``crawler.kazumi``)。

章节 → 媒体
-----------
规则描述搜索与章节结构,章节既可能是直媒体,也可能是播放器网页。
``get_video_urls`` 严格选择请求集数的所有线路,先解析直媒体与静态播放器,
再在有界 iframe 内寻找当前媒体。确需 JavaScript 的页面返回独立的
``kazumi_page_v1`` 客户端描述,从不把 HTML 页面伪装成媒体 URL。

引擎要点(逐条都有实测依据)
--------------------------
* 选择器是 **XPath**,用 lxml 原生求值;``apiLevel`` 较高的规则里
  ``searchMode`` / ``chapterMode`` 可能是 ``api``,此时改走
  ``searchApiConfig`` / ``chapterApiConfig`` 的 JSON 接口。
* ``@keyword`` 是搜索词占位符,必须 URL 编码;``usePost: true`` 时把搜索词
  放进 form body 而不是查询串。
* 搜索请求带 ``Referer: {baseURL}/``;**章节请求必须不带 Cookie** —— 实测
  这是隐藏语义,带 Cookie 会被站点的反爬层拒掉或返回错误页(老的 MacCMS
  采集站尤其明显)。
* ``userAgent`` 为空时用随机 UA(规则库里绝大多数规则都是空的)。
* 上游规则由社区维护,语法里有 .NET 正则命名组、CSS 属性选择器等非 XPath
  写法。这些在 :mod:`server.scrapers.anime.kazumi_rules` 的容错改写层里
  机械修复或判坏,本模块只消费"改写后可用"的字段。

失败隔离
--------
87 条规则里有 68 条 ``deprecated: true``(79%),活跃的 18 条里又有一批
站点长期失效(超时/TLS 断连/403 验证码/0 命中)。因此每一轮搜索都是
**逐规则独立 try/except + 总时长上限**,单条规则炸掉只让它的结果缺失,
绝不让整轮 ``search()`` 抛异常。
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
import re
import time
from collections import OrderedDict
from dataclasses import dataclass
from http.cookiejar import CookieJar, DefaultCookiePolicy
from pathlib import Path
from typing import Any, Final, Optional
from urllib.parse import quote, urljoin, urlparse

import httpx
from lxml import etree, html as lxml_html

from ..base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine
from .kazumi_media import KazumiMediaResolver, MediaChapter, public_url_shape
from .kazumi_rules import (
    KazumiChapterApi,
    KazumiRequest,
    KazumiRule,
    KazumiRuleError,
    jsonpath_values,
    load_rules,
    substitute_placeholders,
)

logger = logging.getLogger(__name__)

#: ``source_id`` 里分隔"规则名"与"站内 ID"的分隔符。规则库里 station id 是
#: 数字或 slug,不会含 ``::``,所以用双冒号不会歧义。
SOURCE_ID_SEPARATOR = "::"

#: ``userAgent`` 为空时的候选 UA。规则库里 18 条活跃规则全是空,统一随机。
FALLBACK_USER_AGENTS: tuple[str, ...] = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0",
)

_EPISODE_LABEL_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"第\s*(\d{1,4})\s*[集话話]"),
    re.compile(r"(?:^|[^\d])(\d{1,4})\s*[集话話]"),
    re.compile(r"^\s*(\d{1,4})\s*$"),
    re.compile(r"(?:EP|ep|Ep)\s*(\d{1,4})"),
)

_JAVASCRIPT_PREFIXES = ("javascript:", "mailto:", "tel:", "data:", "#")


#: 接口式搜索失败时的 HTML 兜底选择器。
#:
#: 为什么需要:规则库里 apiLevel 9 的规则走 ``searchApiConfig``,但同一批站点
#: 的 **HTML 搜索页仍然可用** —— 实测 ``moonci`` 的
#: ``index.php/ajax/suggest`` 直接 403(WAF),而
#: ``https://www.moonci.com/search/-------------.html?wd=...`` 正常返回
#: 17262 字节、含 6 个 ``/anime/N.html`` 详情链接。API 模式恰好没写
#: ``searchList/searchName/searchResult``(它们全是空串),这时用一组通用
#: 选择器比"整条规则作废"更接近规则作者的本意。
#:
#: 只按**结构位置**取,不猜站点语义:链接文本当标题、``href`` 当详情页,
#: 去重后截断。取不到就仍按失败处理。
_FALLBACK_SEARCH_LIST: Final = "//a[@href]"
_FALLBACK_SEARCH_NAME: Final = "string(.)"


class KazumiPageError(RuntimeError):
    """规则页取回但结构不符合期望(空响应 / 非 HTML)。"""


#: 引擎向 HTTP 层要数据的调用签名(结构化类型,便于离线注入 mock)。
class KazumiFetcher:
    """协议占位:实现见 :meth:`KazumiScraper._fetch_as`。

    引擎把 ``fetch`` 当**对象**用(take ``fetch.base_url`` 拼绝对地址),所以
    不能直接传爬虫的绑定方法 —— 那样只有 ``__call__``、没有 ``base_url``。
    :class:`KazumiScraper` 用 :class:`_Fetcher` 配一个 ``base_url`` 再交给引擎。
    """

    base_url: str

    async def __call__(
        self,
        method: str,
        url: str,
        *,
        params: dict[str, str] | None = None,
        headers: dict[str, str] | None = None,
        referer: str = "",
        user_agent: str = "",
        form: dict[str, str] | None = None,
        json_body: dict[str, Any] | None = None,
    ) -> bytes:  # pragma: no cover - 仅类型声明
        ...


class _Fetcher:
    """把爬虫的 ``_fetch_as`` 与"当前规则的 baseURL"绑成一个可调用对象。

    ``base_url`` 是规则级的(解析相对链接的基准),不是爬虫级的(规则库没有
    单一源站),所以必须随规则一起传下去。
    """

    __slots__ = ("base_url", "_call")

    def __init__(self, call: Any, base_url: str) -> None:
        self._call = call
        self.base_url = base_url or ""

    async def __call__(self, method: str, url: str, **kwargs: Any) -> bytes:
        return await self._call(method, url, **kwargs)


# ── 通用小工具 ───────────────────────────────────────────────────
def split_source_id(source_id: str) -> tuple[str, str]:
    """把 ``规则名::站内ID`` 拆开;格式不对时返回 ``("", "")``。

    只接受本模块自己产出的 ID,不信任调用方传进来的字符串 —— 上层 API
    的参数直接来自客户端,必须有形状校验。
    """
    text = str(source_id or "").strip()
    if SOURCE_ID_SEPARATOR not in text:
        return "", ""
    rule_name, _, inner = text.partition(SOURCE_ID_SEPARATOR)
    rule_name, inner = rule_name.strip(), inner.strip()
    if not rule_name or not inner:
        return "", ""
    return rule_name, inner


def build_source_id(rule_name: str, inner_id: str) -> str:
    return f"{rule_name}{SOURCE_ID_SEPARATOR}{inner_id}"


def is_fetchable_url(url: str) -> bool:
    """只允许 http/https 出站。

    规则库是外部数据,里面出现 ``file://`` / ``gopher://`` 之类的地址时不能
    真的去请求 —— 这里是服务端,不是浏览器沙箱。
    """
    try:
        parsed = urlparse((url or "").strip())
    except ValueError:
        return False
    return parsed.scheme.lower() in {"http", "https"} and bool(parsed.hostname)


def absolute_url(base: str, candidate: str) -> str:
    """把站内相对链接补成绝对地址;不合法的地址返回空串。"""
    value = (candidate or "").strip()
    if not value or value.lower().startswith(_JAVASCRIPT_PREFIXES):
        return ""
    resolved = urljoin(base, value)
    return resolved if is_fetchable_url(resolved) else ""


def episode_number_from_label(label: str, position: int) -> int:
    """从章节标签推集号,推不出来就退化为位置序号。

    优先读标签里的显式集号 —— 分季站点的集号是**全局**的(第二季第一集标
    "第25集"),用位置序号会把 25 记成 1,同一部番的两季会互相覆盖。
    """
    text = (label or "").strip()
    for pattern in _EPISODE_LABEL_PATTERNS:
        match = pattern.search(text)
        if match is not None:
            number = int(match.group(1))
            if number > 0:
                return number
    return max(1, position)


#: 规则格式里没有"封面字段"的约定,但接口式列表行里确实常见这几个键。
#: 只按**优先级顺序**试,取不到就留空,不猜。
_COVER_KEYS: tuple[str, ...] = (
    "vod_pic",
    "cover",
    "cover_url",
    "coverUrl",
    "pic",
    "image",
    "poster",
    "thumb",
)


def _json_cover(row: Any) -> str:
    """从接口列表行里取封面地址(取不到返回空串)。"""
    if not isinstance(row, dict):
        return ""
    for key in _COVER_KEYS:
        value = row.get(key)
        if isinstance(value, str) and is_fetchable_url(value):
            return value
    return ""


def _text_of(node: Any) -> str:
    """取 XPath 命中项的文字。命中可能是元素,也可能是 ``text()`` 字符串。"""
    if node is None:
        return ""
    if isinstance(node, str):
        return " ".join(node.split())
    if isinstance(node, etree._Element):  # noqa: SLF001 - lxml 公开类型判断
        return " ".join(
            part
            for part in (node.text_content() or "").split("\n")
            if part.strip()
        ).strip()
    return " ".join(str(node).split())


def _href_of(node: Any) -> str:
    if isinstance(node, etree._Element):  # noqa: SLF001
        return str(node.get("href") or node.get("data-src") or "").strip()
    return ""


def first_image_url(nodes: list[Any], page_url: str) -> str:
    """从命中节点或其后代里找一张图,用于搜索结果封面(规则格式没这字段)。"""
    for node in nodes:
        if not isinstance(node, etree._Element):  # noqa: SLF001
            continue
        candidates = [node]
        candidates.extend(node.iter("img"))
        for candidate in candidates:
            for attribute in ("data-src", "data-original", "src"):
                value = str(candidate.get(attribute) or "").strip()
                if value:
                    resolved = absolute_url(page_url, value)
                    if resolved:
                        return resolved
    return ""


# ── XPath 引擎 ──────────────────────────────────────────────────
#: charset 声明必须在文档前部才生效,只看开头这几 KB 就够。
_CHARSET_SNIFF_BYTES = 4096
_CHARSET_RE = re.compile(
    rb"charset\s*=\s*[\"']?\s*([A-Za-z0-9_\-]+)", re.IGNORECASE
)
_UTF8_BOM = b"\xef\xbb\xbf"
_UTF16_BOMS = (b"\xff\xfe", b"\xfe\xff")
_META_TAG_RE = re.compile(rb"<meta\b[^>]*>", re.IGNORECASE)


class _ResponseBytes(bytes):
    """保持 bytes fetcher 接口,仅附带 HTTP 显式声明的 charset。"""
    charset: str

    def __new__(cls, content: bytes, charset: str = "") -> _ResponseBytes:
        value = super().__new__(cls, content)
        value.charset = charset
        return value


def _bom_charset(content: bytes) -> str:
    if content.startswith((b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff")):
        return "utf-32"
    if content.startswith(_UTF8_BOM):
        return "utf-8-sig"
    if content.startswith(_UTF16_BOMS):
        return "utf-16"
    return ""


def _declared_charset(content: bytes) -> str:
    """只检查前部 meta 标签里的 charset,不把正文/脚本文本当声明。"""
    head = re.sub(rb"<!--[\s\S]*?-->", b"", content[:_CHARSET_SNIFF_BYTES])
    for tag in _META_TAG_RE.findall(head):
        match = _CHARSET_RE.search(tag)
        if match:
            return match.group(1).decode("ascii").lower()
    return ""


def parse_document(content: bytes) -> etree._Element:
    """按 BOM、HTTP charset、meta、UTF-8 依次解码,最后交 lxml 解析原字节。

    UTF-8 是本适配器的无声明优先项,不是 HTML 的统一默认编码;不猜无声明 GBK。
    """
    if not content or not content.strip():
        raise KazumiPageError("empty response body")

    encodings = dict.fromkeys((
        _bom_charset(content), getattr(content, "charset", ""),
        _declared_charset(content), "utf-8",
    ))
    last_error: Exception | None = None
    for encoding in encodings:
        if not encoding:
            continue
        try:
            payload = content.decode(encoding)
        except (LookupError, UnicodeDecodeError):
            continue
        try:
            return lxml_html.fromstring(payload)
        except (etree.ParserError, etree.XMLSyntaxError, ValueError) as error:
            last_error = error
    try:
        return lxml_html.fromstring(content)
    except (etree.ParserError, etree.XMLSyntaxError, ValueError) as error:
        last_error = error
    raise KazumiPageError(
        f"html parse failed: {type(last_error).__name__}"
    ) from last_error


def xpath_all(root: Any, expression: str) -> list[Any]:
    """求值 XPath,失败返回空列表。

    选择器已经在改写层过滤过一轮,但上游规则仍可能带 lxml 不认的写法
    (例如 XPath 2.0 的函数)。这里兜底吞掉 ``XPathError``:一条坏选择器
    等于"该站点这条路径不可用",不该升级成整轮异常。
    """
    if not expression or root is None:
        return []
    try:
        result = root.xpath(expression)
    except (etree.XPathError, ValueError, TypeError):
        return []
    if result is None:
        return []
    if not isinstance(result, list):
        return [result]
    return result


def parse_html_fragment(fragment: str) -> Any:
    """把一段 HTML 字符串解析成可求值节点(测试与少量内联场景用)。"""
    return lxml_html.fromstring(fragment)


def relative_selector(expression: str) -> str:
    """把绝对 XPath 变成相对当前节点的等价写法。

    **这是必需的,不是优化**:lxml 对元素调用 ``xpath("//a")`` 时,``//`` 仍然
    从**文档根**开始搜索,与调用者无关(libxml2 的语义)。规则里的
    ``searchName`` / ``searchResult`` 都是相对于 ``searchList`` 命中项的
    (客户端在 JS 里这样解释),若不复写,每一条搜索结果都会拿到同一个
    文档级首个节点 —— 实测会把一页 2 条结果压成 1 条。

    只改前导轴:``//x`` / ``/x`` → ``.//x``;已经是相对写法(``.//x``、
    ``/self::``、``/following-sibling::``)保持原样。
    """
    text = (expression or "").strip()
    if not text:
        return text
    if text.startswith(".//") or text.startswith("./"):
        return text
    if text.startswith("//"):
        return "." + text
    if text.startswith("/") and not text.startswith(("/self::", "/following", "/preceding")):
        return "." + text
    return text


# ── 请求构造 ─────────────────────────────────────────────────────
def _substitute(value: Any, **kwargs: object) -> Any:
    """递归替换请求模板里的 ``@keyword`` / ``@source`` 等占位符。"""
    if isinstance(value, str):
        return substitute_placeholders(value, **kwargs)
    if isinstance(value, dict):
        return {key: _substitute(item, **kwargs) for key, item in value.items()}
    if isinstance(value, list):
        return [_substitute(item, **kwargs) for item in value]
    return value


def _stringify_query(query: dict[str, Any]) -> dict[str, str]:
    """查询串只接受标量。

    规则里确实出现过 ``"page": 1``(int)与 ``"enabled": true``(bool),统一
    转成字符串再交给 httpx;容器值说明规则写法超出预期,直接丢弃该键。
    """
    result: dict[str, str] = {}
    for key, value in query.items():
        if isinstance(value, bool):
            result[str(key)] = "true" if value else "false"
        elif isinstance(value, (str, int, float)):
            result[str(key)] = str(value)
    return result


def _stringify_body(body: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in body.items():
        if isinstance(value, (str, int, float, bool)):
            result[str(key)] = value
    return result


@dataclass
class _KazumiEpisode(EpisodeInfo):
    """内部保留线路身份,不改变公共 EpisodeInfo 或 source_episode_id。"""

    channel: str = "1"


# ── 规则执行器(纯逻辑,不持有连接) ─────────────────────────────
class KazumiRuleEngine:
    """把一条 :class:`KazumiRule` 跑成 :class:`SubjectResult` / 章节列表。

    HTTP 由带 ``base_url`` 的异步 fetcher 注入,返回 bytes;生产 fetcher
    可附带显式 HTTP charset。引擎可用普通 bytes mock 离线测试。
    """

    def __init__(
        self,
        rule: KazumiRule,
        *,
        max_results: int = 30,
        user_agent: str = "",
    ) -> None:
        self._rule = rule
        self._max_results = max(1, max_results)
        self._user_agent = user_agent

    @property
    def rule(self) -> KazumiRule:
        return self._rule

    # ── 搜索 ────────────────────────────────────────────────────
    async def search(
        self,
        fetch: "KazumiFetcher",
        keyword: str,
    ) -> list[tuple[SubjectResult, str]]:
        """搜索,返回 ``(结果, 详情页 URL)`` 列表。

        详情页 URL 是给 :meth:`chapters` 用的:规则格式里没有"详情页前缀"的
        通用约定,最可靠的来源就是**搜索结果里那个链接本身**。
        """
        keyword = (keyword or "").strip()
        if not keyword or not self._rule.can_search:
            return []
        if self._rule.search_via_api:
            return await self._search_via_api(fetch, keyword)
        return await self._search_via_xpath(fetch, keyword)

    async def _search_via_api(
        self, fetch: "KazumiFetcher", keyword: str
    ) -> list[tuple[SubjectResult, str]]:
        api = self._rule.search_api
        if api is not None and api.usable:
            payload = await self._request_json(
                fetch,
                api.request,
                quoted_keyword=quote(keyword),
                keyword=keyword,
                source="",
            )
        else:
            payload = None

        if payload is not None:
            # 关键词必须用原文:查询串由 httpx 按上下文编码,提前 quote() 会
            # 变成双重编码,服务端按字面量匹配 → 0 命中(实测踩过)。
            results = self._rows_from_api_payload(payload, api)
            if results:
                return results

        # 接口挂了(403/TLS/空集)时退回 HTML 搜索页。
        return await self._search_via_html_fallback(fetch, keyword)

    def _rows_from_api_payload(
        self, payload: Any, api: Any
    ) -> list[tuple[SubjectResult, str]]:
        if api is None:
            return []
        try:
            rows = jsonpath_values(payload, api.list_path)
        except KazumiRuleError:
            return []

        results: list[tuple[SubjectResult, str]] = []
        seen: set[str] = set()
        for row in rows:
            try:
                name = str(jsonpath_values(row, api.name_path)[0]).strip()
                raw_source = str(jsonpath_values(row, api.source_path)[0]).strip()
            except (IndexError, KazumiRuleError):
                continue
            if not name or not raw_source or raw_source in seen:
                continue
            seen.add(raw_source)
            detail_url = (
                substitute_placeholders(api.source_template, source=raw_source)
                if api.source_template
                else ""
            )
            if detail_url and not is_fetchable_url(detail_url):
                detail_url = ""
            results.append(
                (
                    self._subject(
                        raw_source,
                        name,
                        cover_url=_json_cover(row),
                        detail_url=detail_url,
                    ),
                    detail_url,
                )
            )
            if len(results) >= self._max_results:
                break
        return results

    async def _search_via_html_fallback(
        self, fetch: "KazumiFetcher", keyword: str
    ) -> list[tuple[SubjectResult, str]]:
        """接口式规则的 HTML 搜索页兜底(只在这类规则上启用)。

        XPath 模式的规则本来就有自己的 ``searchURL`` + 选择器,失败说明站点
        变了,兜底通用选择器也救不回来;所以这里只补接口式规则缺的那一段。
        """
        rule = self._rule
        if not rule.search_url:
            return []
        url = substitute_placeholders(rule.search_url, keyword=quote(keyword))
        if not is_fetchable_url(url):
            return []
        try:
            content = await fetch(
                "GET",
                url,
                referer=self.search_referer,
                user_agent=self._user_agent,
            )
            document = parse_document(content)
        except Exception:  # noqa: BLE001 - 兜底失败即"这条规则没结果"
            return []

        results: list[tuple[SubjectResult, str]] = []
        seen: set[str] = set()
        for node in xpath_all(document, _FALLBACK_SEARCH_LIST):
            detail_url = absolute_url(str(fetch.base_url), _href_of(node))
            if not detail_url:
                continue
            name = _text_of(node)
            title_attr = ""
            if isinstance(node, etree._Element):  # noqa: SLF001
                for attribute in ("title", "alt"):
                    title_attr = str(node.get(attribute) or "").strip()
                    if title_attr:
                        break
            title = name or title_attr
            if not title or detail_url in seen:
                continue
            seen.add(detail_url)
            results.append(
                (
                    self._subject(detail_url, title, detail_url=detail_url),
                    detail_url,
                )
            )
            if len(results) >= self._max_results:
                break
        return results

    async def _search_via_xpath(
        self, fetch: "KazumiFetcher", keyword: str
    ) -> list[tuple[SubjectResult, str]]:
        rule = self._rule
        url = substitute_placeholders(rule.search_url, keyword=quote(keyword))
        if not is_fetchable_url(url):
            return []
        if rule.search_needs_post:
            # usePost: true —— 搜索词放 form body。URL 模板里的 @keyword 位
            # 此时通常已经被站点的固定查询串占住,再拼一次会变成两份关键词。
            content = await fetch(
                "POST",
                url,
                referer=self.search_referer,
                user_agent=self._user_agent,
                form={"wd": keyword, "keyword": keyword},
            )
        else:
            content = await fetch(
                "GET",
                url,
                referer=self.search_referer,
                user_agent=self._user_agent,
            )
        document = parse_document(content)

        items = xpath_all(document, rule.search_list)
        results: list[tuple[SubjectResult, str]] = []
        seen: set[str] = set()
        for item in items:
            # 先按**相对当前条目**求值,取不到才退回整页。
            #
            # 顺序不能反:规则里的 searchName/searchResult 都是相对于
            # searchList 命中项的(客户端就是这样做的)。先取整页会在
            # ``//a`` 这类通用选择器上把**同一个**第一条锚点喂给每一条
            # 结果,去重之后整页只剩 1 条 —— 实测就把 2 条结果压成了 1 条。
            name_nodes = xpath_all(item, relative_selector(rule.search_name))
            if not name_nodes:
                name_nodes = xpath_all(document, rule.search_name)
            name = ""
            for node in name_nodes:
                name = _text_of(node)
                if name:
                    break
            if not name:
                continue

            link_nodes = xpath_all(item, relative_selector(rule.search_result))
            if not link_nodes:
                link_nodes = xpath_all(document, rule.search_result)
            detail_url = ""
            for node in link_nodes:
                detail_url = absolute_url(str(fetch.base_url), _href_of(node))
                if detail_url:
                    break
            cover = first_image_url(link_nodes or [item], str(fetch.base_url) or url)
            if not detail_url:
                # 规则把地址挂在 searchName 命中的 ``<a>`` 上时,名字节点本身
                # 就是链接;这是继 searchResult 之后第二顺位的取值点。
                for node in name_nodes:
                    detail_url = absolute_url(str(fetch.base_url), _href_of(node))
                    if detail_url:
                        break
            if not detail_url:
                # 链接挂在条目自身(``searchResult: "."``)时,取条目元素上的 href。
                detail_url = absolute_url(str(fetch.base_url), _href_of(item))
            if not detail_url:
                continue

            source_key = str(detail_url)
            if source_key in seen:
                continue
            seen.add(source_key)
            results.append(
                (
                    self._subject(
                        source_key, name, cover_url=cover, detail_url=detail_url
                    ),
                    detail_url,
                )
            )
            if len(results) >= self._max_results:
                break
        return results

    @property
    def search_referer(self) -> str:
        """搜索请求的 Referer。规则显式给了就用它,否则用 ``{baseURL}/``。"""
        rule = self._rule
        if rule.referer:
            return rule.referer
        if rule.base_url:
            return rule.base_url.rstrip("/") + "/"
        return ""

    def _subject(
        self,
        source_key: str,
        title: str,
        *,
        cover_url: str = "",
        detail_url: str = "",
    ) -> SubjectResult:
        """组装搜索结果。``detail_url`` 是**已解析的详情页地址**(可空)。

        接口式规则的列表行里没有详情页字段,但 ``sourceTemplate`` 有时能拼出
        来(``LMM``/``dalvdm``/``moonci``),有时拼不出来(``giriGiriLove``)。
        拼不出来时 XPath 模式的章节请求就没有入口 —— 这是规则本身的能力缺口,
        不是实现问题,所以 detail_url 留空并在 ``extra`` 里如实反映。
        """
        resolved_detail = detail_url if is_fetchable_url(detail_url) else ""
        return SubjectResult(
            source_id=build_source_id(self._rule.name, source_key),
            title=title,
            cover_url=cover_url,
            type="anime" if self._rule.type in {"", "anime"} else self._rule.type,
            lang="ja",
            extra={
                "kazumi_rule": self._rule.name,
                "source_identity": {
                    "rule_id": self._rule.name,
                    "rule_name": self._rule.name,
                    "site_name": urlparse(self._rule.base_url).hostname or "",
                },
                "kazumi_api": self._rule.api_level,
                "detail_url": resolved_detail,
            },
        )

    # ── 章节 ────────────────────────────────────────────────────
    async def chapters(
        self,
        fetch: "KazumiFetcher",
        *,
        detail_url: str,
        source_key: str = "",
    ) -> list[EpisodeInfo]:
        """抽取章节列表。

        ``source_key`` 是**规则自己的站内 ID**(接口式搜索的 ``$.vod_id`` 之类),
        接口式章节请求要用它拼 ``@source``,而不是详情页 URL —— 例如
        ``giriGiriLove`` 的 ``get_detail?vod_id=@source`` 只吃数字 ID,塞 URL
        进去返回的是空集。不传时退回详情页 URL(XPath 模式本来就只用 URL)。

        引擎不添加 Cookie。KazumiScraper 的 HTTP 客户端显式禁用 Cookie
        存储与发送(含重定向);自定义 fetcher 应维持同一约定。
        """
        rule = self._rule
        if not rule.can_list_chapters:
            return []
        if rule.chapter_via_api:
            # 接口式章节不依赖详情页 —— 一部分规则(如 giriGiriLove)的
            # sourceTemplate 是空的,详情页 URL 根本拼不出来,但它的
            # get_detail?vod_id=@source 只要站内 ID 就能给出全部线路。
            return await self._chapters_via_api(
                fetch, detail_url, source_key or detail_url
            )
        if not is_fetchable_url(detail_url):
            return []
        content = await fetch(
            "GET",
            detail_url,
            referer=rule.referer or (rule.base_url.rstrip("/") + "/" if rule.base_url else ""),
            user_agent=self._user_agent,
        )
        document = parse_document(content)
        return self._episodes_from_document(document, detail_url)

    def _episodes_from_document(
        self, document: Any, detail_url: str
    ) -> list[EpisodeInfo]:
        rule = self._rule
        roads = xpath_all(document, rule.chapter_roads) if rule.chapter_roads else []
        # 没有 chapterRoads 的规则(以及 chapterRoads 判坏被降级的规则)按
        # "整页找不到线路容器"处理,但 chapterResult 本身仍然有信息量 ——
        # 例如 ezdmw 的 chapterResult 是 ``following-sibling`` 轴,相对整页
        # 也能命中。
        search_roots = roads if roads else [document]
        chapter_result = relative_selector(rule.chapter_result) if roads else rule.chapter_result

        episodes: list[EpisodeInfo] = []
        seen: set[tuple[int, str]] = set()
        for road_index, road in enumerate(search_roots, 1):
            for position, link in enumerate(xpath_all(road, chapter_result), 1):
                href = _href_of(link)
                url = absolute_url(detail_url, href)
                if not url:
                    # chapterResult 直接命中 text() 时没有可跳转的章节地址。
                    continue
                label = _text_of(link) or url.rsplit("/", 1)[-1]
                key = (road_index, url)
                if key in seen:
                    continue
                seen.add(key)
                episodes.append(
                    _KazumiEpisode(
                        number=episode_number_from_label(label, position),
                        title=label,
                        source_episode_id=url,
                        channel=str(road_index),
                    )
                )
        return episodes

    async def _chapters_via_api(
        self, fetch: "KazumiFetcher", detail_url: str, source_key: str = ""
    ) -> list[EpisodeInfo]:
        chapter_api = self._rule.chapter_api
        if chapter_api is None or not chapter_api.usable:
            return []
        # 接口式章节用站内 ID 填 @source(不是详情页 URL);缺省才退回 URL。
        source = source_key or detail_url
        payload = await self._request_json(fetch, chapter_api.request, source=source)
        if payload is None:
            return []
        if chapter_api.format == "delimited":
            return self._chapters_delimited(payload, chapter_api, source)
        if chapter_api.format == "nested":
            return self._chapters_nested(payload, chapter_api, source)
        return []

    def _chapters_delimited(
        self,
        payload: Any,
        chapter_api: KazumiChapterApi,
        source_key: str,
    ) -> list[EpisodeInfo]:
        """``roadNamesPath`` / ``roadEpisodesPath`` 用三个分隔符切分。

        规则库的 ``giriGiriLove`` 就是 MacCMS 的 ``vod_play_url`` 形态:
        ``$$$`` 切线路,``#`` 切集,``$`` 切"名字/地址"。

        层数必须按**实测**来,不是按直觉 —— 两种切法都试过,只有下面这种对得上:

        * ``roadEpisodesPath`` 取到的 **每个字符串内部** 还包含 ``$$$`` 分组:
          ``ep1#ep2$$$ep3#ep4``(同一"分组"下多条线路各占一段);
        * ``roadNamesPath`` 取到的**一个字符串**用同一个分隔符串起全部线名:
          ``cht$$$chs``。

        所以正确配平方式是:线名串先拆成列表,再对**每个 blob 的每个段**按段序
        取对应线名。写成"blob × 线名"两层配对(把每个 blob 当成一条线路)时,
        实测 ``giriGiriLove`` 20 集只剩 1 集。
        """
        try:
            # 线名串:先拆开,得到与"段序"一一对应的线名列表。
            road_names: list[str] = []
            for value in jsonpath_values(payload, chapter_api.road_names_path):
                parts = value if isinstance(value, list) else [value]
                for item in parts:
                    road_names.extend(str(item).split(chapter_api.road_separator))
            road_blobs = [
                str(value)
                for value in jsonpath_values(payload, chapter_api.road_episodes_path)
            ]
        except KazumiRuleError:
            return []
        if not road_blobs:
            return []

        episodes: list[EpisodeInfo] = []
        seen: set[tuple[str, int, str]] = set()
        for blob_index, blob in enumerate(road_blobs, 1):
            if not blob:
                continue
            for segment_index, segment in enumerate(
                blob.split(chapter_api.road_separator)
            ):
                if not segment:
                    continue
                road_name = (
                    road_names[segment_index] if segment_index < len(road_names) else ""
                )
                channel = f"{blob_index}-{segment_index + 1}"
                for position, token in enumerate(segment.split(chapter_api.episode_separator), 1):
                    parts = token.split(chapter_api.field_separator, 1)
                    label = parts[0].strip() if parts else ""
                    target = parts[1].strip() if len(parts) > 1 else ""
                    if not label and not target:
                        continue
                    label = label or target
                    # 去重键必须带线路名:同一条目在 "cht" 与 "chs" 两条线路下都
                    # 有 "01",只按标签去重会把第二条线路整条丢掉。
                    dedupe_key = (channel, position, target or label)
                    if dedupe_key in seen:
                        continue
                    seen.add(dedupe_key)
                    episodes.append(
                        _KazumiEpisode(
                            number=episode_number_from_label(label, position),
                            title=(
                                f"{road_name} {label}".strip() if road_name else label
                            ),
                            source_episode_id=target or label,
                            channel=channel,
                        )
                    )
        return episodes

    def _chapters_nested(
        self,
        payload: Any,
        chapter_api: KazumiChapterApi,
        source_key: str,
    ) -> list[EpisodeInfo]:
        """``roadsPath`` 下每条线路各自带 ``episodesPath`` 的形态。"""
        try:
            roads = jsonpath_values(payload, chapter_api.roads_path)
        except KazumiRuleError:
            return []

        episodes: list[EpisodeInfo] = []
        seen: set[tuple[int, int, str]] = set()
        for road_index, road in enumerate(roads, 1):
            try:
                road_name_values = (
                    jsonpath_values(road, chapter_api.road_name_path)
                    if chapter_api.road_name_path
                    else []
                )
                road_name = (
                    str(road_name_values[0]).strip() if road_name_values else ""
                )
                episode_nodes = jsonpath_values(road, chapter_api.episodes_path)
            except KazumiRuleError:
                continue
            for position, node in enumerate(episode_nodes, 1):
                try:
                    labels = (
                        jsonpath_values(node, chapter_api.episode_name_path)
                        if chapter_api.episode_name_path
                        else []
                    )
                    values = (
                        jsonpath_values(node, chapter_api.episode_url_path)
                        if chapter_api.episode_url_path
                        else []
                    )
                except KazumiRuleError:
                    continue
                label = str(labels[0]).strip() if labels else ""
                episode_key = str(values[0]).strip() if values else ""
                if not label and not episode_key:
                    continue
                label = label or episode_key
                page = chapter_api.episode_page
                target = ""
                if page is not None and page.url and episode_key:
                    target = substitute_placeholders(
                        page.url, source=source_key, episodeUrl=episode_key
                    )
                    query = _stringify_query(_substitute(
                        page.query, source=source_key, episodeUrl=episode_key
                    ))
                    if query and is_fetchable_url(target):
                        target = str(httpx.URL(target).copy_merge_params(query))
                if not target:
                    target = episode_key
                key = (road_index, position, target or label)
                if not label or key in seen:
                    continue
                seen.add(key)
                episodes.append(
                    _KazumiEpisode(
                        number=episode_number_from_label(label, position),
                        title=f"{road_name} {label}".strip() if road_name else label,
                        source_episode_id=target or label,
                        channel=str(road_index),
                    )
                )
        return episodes

    # ── 请求执行 ────────────────────────────────────────────────
    async def _request_json(
        self,
        fetch: "KazumiFetcher",
        request: KazumiRequest,
        **placeholders: object,
    ) -> Any:
        """按 ``request`` 描述发一次接口请求并解析 JSON。

        占位符替换**分两种语境**,混用会让上游直接返回空集(实测):

        * URL 里的 ``@keyword`` 必须 percent-encode(``%E8%91%AC...``),
          否则中文进不了请求行;
        * 查询串与 body 里的 ``@keyword`` 必须是**原文** —— 这些位置由 httpx
          自己按上下文编码,提前 ``quote()`` 会变成双重编码,服务端按字面量
          去匹配 ``%E8%91%AC...`` 这个字符串,结果就是 0 命中。``giriGiriLove``
          / ``xfdmnext`` / ``TvTFun`` / ``sorani`` 四条规则都栽在这里。

        所以调用方同时提供 ``quoted_keyword``(URL 用)与 ``keyword``(参数/body
        用),本函数按位置选。
        """
        if not request.usable:
            return None
        url = _substitute(request.url, **placeholders)
        if not isinstance(url, str) or not is_fetchable_url(url):
            return None
        # 参数与 body 用原文关键词:见上面 docstring 的双重编码说明。
        parameter_values = {
            key: value for key, value in placeholders.items() if key != "quoted_keyword"
        }
        query = _stringify_query(_substitute(request.query, **parameter_values))
        headers = {
            str(key): str(_substitute(value, **parameter_values))
            for key, value in request.headers.items()
        }
        method = request.method or "GET"

        kwargs: dict[str, Any] = {
            "referer": self.search_referer,
            "user_agent": self._user_agent,
            "headers": headers,
        }
        if method == "POST":
            body = _stringify_body(
                _substitute(request.body, **parameter_values)
            )
            if request.body_type == "json":
                kwargs["json_body"] = body
            else:
                kwargs["form"] = {str(k): str(v) for k, v in body.items()}
            # 接口式请求的关键词已经在 body 里,查询串保留原样(通常为空)。
            if query:
                kwargs["params"] = query
        else:
            kwargs["params"] = query

        content = await fetch(method, url, **kwargs)
        if not content:
            return None
        try:
            return json.loads(content.decode("utf-8", "replace"))
        except ValueError:
            return None


class _NoCookiePolicy(DefaultCookiePolicy):
    """元数据请求不存储站点 Cookie。"""
    def set_ok(self, cookie: Any, request: Any) -> bool:
        return False


async def _strip_cookie(request: httpx.Request) -> None:
    """在每次实际请求(含 httpx 跟随的重定向)前移除 Cookie。"""
    request.headers.pop("Cookie", None)


# ── 爬虫本体 ─────────────────────────────────────────────────────
class KazumiScraper(BaseScraper):
    """把整个 Kazumi 规则库当一个聚合源接进来。

    为什么是"一个 scraper 而不是 87 个":``ScraperRegistry`` 用
    ``scraper.name`` 做键、``provider_id_for_scraper`` 生成 ``crawler.<name>``,
    87 条规则各注册一个会淹没 provider 列表;而规则库本身是**同一套引擎的
    数据**,不是 87 个独立实现。聚合在一个 ``crawler.kazumi`` 下,内部按规则
    名隔离失败与报数,既能被上层整体启停,也能单独定位到某条规则。
    """

    def __init__(
        self,
        rules_dir: Any = None,
        *,
        rules: list[KazumiRule] | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float | None = None,
        min_interval: float | None = None,
        max_results_per_rule: int | None = None,
        search_deadline: float | None = None,
        attempts: int = 2,
        retry_backoff: float = 0.6,
        enabled: bool | None = None,
        media_deadline: float = 12.0,
    ) -> None:
        super().__init__()
        self._name = "kazumi"
        # 延迟读 config:模块级 import config 会在测试里把真实配置拽进来,
        # 而这里只需要几个数值。
        from ... import config as _config

        # enabled 采用 crawler.animeko 的同一约定:一个 provider 背后是十几个
        # 外部站点,默认关闭,由运维显式打开(config.KAZUMI_ENABLED)。
        self._enabled = (
            bool(_config.KAZUMI_ENABLED) if enabled is None else bool(enabled)
        )
        self._rules_dir = (
            rules_dir if rules_dir is not None else resolve_rules_dir()
        )
        self._min_interval = (
            float(min_interval)
            if min_interval is not None
            else float(_config.KAZUMI_MIN_REQUEST_INTERVAL_SECONDS)
        )
        self._max_results = (
            int(max_results_per_rule)
            if max_results_per_rule is not None
            else int(_config.KAZUMI_MAX_RESULTS_PER_RULE)
        )
        self._search_deadline = (
            float(search_deadline)
            if search_deadline is not None
            else float(_config.KAZUMI_SEARCH_DEADLINE_SECONDS)
        )
        request_timeout = (
            float(timeout)
            if timeout is not None
            else float(_config.KAZUMI_HTTP_TIMEOUT_SECONDS)
        )
        # 瞬时传输层失败(国内出口偶发丢包)的重试次数与退避基数。
        self._attempts = max(1, min(4, int(attempts)))
        self._retry_backoff = max(0.0, float(retry_backoff))

        if rules is None:
            rules = load_rules(self._rules_dir)
        self._rules: list[KazumiRule] = list(rules)
        self._engines: dict[str, KazumiRuleEngine] = {
            rule.name: KazumiRuleEngine(
                rule,
                max_results=self._max_results,
                user_agent=rule.user_agent or random.choice(FALLBACK_USER_AGENTS),
            )
            for rule in self._rules
        }

        # 节流与结果缓存都是**按规则**隔离的:不同规则打到不同站点,共用一把
        # 锁会把一轮搜索串行化成分钟级。
        self._host_locks: dict[str, asyncio.Lock] = {}
        self._host_last_request: dict[str, float] = {}
        # 搜索缓存只存"能拿来跳详情页"的结果:规则库没有统一的详情页 URL
        # 构造规则,搜索结果里的链接是唯一可靠来源。
        self._detail_urls: "OrderedDict[str, str]" = OrderedDict()
        self._result_cache: "OrderedDict[str, list[SubjectResult]]" = OrderedDict()
        self._cache_limit = 128
        self._metadata_ttl = 60.0
        self._detail_cache: OrderedDict[str, tuple[float, SubjectDetail]] = OrderedDict()
        self._detail_locks: dict[str, asyncio.Lock] = {}
        self._page_cache: OrderedDict[str, tuple[float, bytes]] = OrderedDict()
        self._media_deadline = max(0.1, float(media_deadline))
        self._media_resolver = KazumiMediaResolver(
            transport=transport, timeout=min(request_timeout, 5.0), throttle=self._throttle,
        )

        self._client = httpx.AsyncClient(
            timeout=request_timeout,
            follow_redirects=True,
            transport=transport,
            cookies=CookieJar(policy=_NoCookiePolicy()),
            event_hooks={"request": [_strip_cookie]},
        )

    # ── BaseScraper 接口 ────────────────────────────────────────
    @property
    def content_types(self) -> list[str]:
        return ["anime"]

    @property
    def enabled(self) -> bool:
        return self._enabled

    @property
    def base_url(self) -> str:
        # 规则库没有单一源站。返回第一条规则的 baseURL 会误导上层审计与
        # 域名白名单逻辑,所以给一个语义明确的中性值。
        return "https://kazumi-rules.local/"

    @property
    def rules(self) -> list[KazumiRule]:
        return list(self._rules)

    @property
    def rule_names(self) -> list[str]:
        return [rule.name for rule in self._rules]

    async def search(self, keyword: str) -> list[SubjectResult]:
        """并发跑所有可用规则,逐条隔离失败,返回可用部分。

        失败隔离有三层:
        1. 每条规则各自 ``try/except``,异常只记日志并跳过;
        2. 总时长上限 ``KAZUMI_SEARCH_DEADLINE_SECONDS``,到点取消未完任务;
        3. 结果按规则顺序拼接,谁的顺序不影响谁的成败。
        """
        keyword = (keyword or "").strip()
        if not keyword or not self._enabled:
            return []

        engines = [engine for engine in self._engines.values() if engine.rule.can_search]
        if not engines:
            return []

        tasks: list[asyncio.Task] = [
            asyncio.create_task(
                self._search_one(engine, keyword), name=f"kazumi:{engine.rule.name}"
            )
            for engine in engines
        ]
        done, pending = await asyncio.wait(tasks, timeout=self._search_deadline)
        for task in pending:
            task.cancel()
        if pending:
            # 取消后必须回收,否则 "Task was destroyed but it is pending" 会污染日志。
            await asyncio.gather(*pending, return_exceptions=True)

        results: list[SubjectResult] = []
        for engine, task in zip(engines, tasks):
            if task not in done or task.cancelled():
                continue
            try:
                results.extend(task.result())
            except Exception as error:  # noqa: BLE001 - 隔离边界,见 docstring
                logger.warning(
                    "Kazumi rule %s failed after completion: %s",
                    engine.rule.name,
                    type(error).__name__,
                )
        return results

    async def _search_one(
        self, engine: KazumiRuleEngine, keyword: str
    ) -> list[SubjectResult]:
        """跑一条规则,成功则写缓存。异常向上抛给 :meth:`search` 的统一边界。"""
        fetcher = self._fetcher_for(engine.rule)
        pairs = await engine.search(fetcher, keyword)
        results = [subject for subject, _detail_url in pairs]
        if not results:
            return []
        for subject, detail_url in pairs:
            if detail_url:
                self._remember_detail_url(subject.source_id, detail_url)
        self._remember_results(keyword, engine.rule.name, results)
        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """短期缓存章节,并发详情/播放请求共享一次取数。"""
        rule_name, inner_id = split_source_id(source_id)
        if not self._enabled or rule_name not in self._engines or not inner_id:
            return None
        cached = self._detail_cache.get(source_id)
        if cached and time.monotonic() - cached[0] < self._metadata_ttl:
            self._detail_cache.move_to_end(source_id)
            return cached[1]
        lock = self._detail_locks.setdefault(source_id, asyncio.Lock())
        try:
            async with lock:
                cached = self._detail_cache.get(source_id)
                if cached and time.monotonic() - cached[0] < self._metadata_ttl:
                    return cached[1]
                detail = await self._get_detail_uncached(source_id)
                if detail is not None:
                    self._detail_cache[source_id] = (time.monotonic(), detail)
                    self._detail_cache.move_to_end(source_id)
                    while len(self._detail_cache) > self._cache_limit:
                        self._detail_cache.popitem(last=False)
                return detail
        finally:
            # Existing waiters retain the lock object; new callers read cache.
            if not lock.locked() and not getattr(lock, "_waiters", None):
                self._detail_locks.pop(source_id, None)

    async def _get_detail_uncached(self, source_id: str) -> Optional[SubjectDetail]:
        """取条目详情(实质就是章节列表)。

        规则库里没有"详情页字段"的约定:标题与详情页 URL 都来自搜索结果。
        所以本方法走 "search 缓存 → 现场补搜" 两级:
        * 命中缓存(同一实例内搜索过)直接用,不发请求;
        * 未命中就用该规则对**当前关键词**重搜一次 —— 关键词取不到时退化为
          只按详情页 URL 抽章节,标题留空。
        """
        rule_name, inner_id = split_source_id(source_id)
        engine = self._engines.get(rule_name)
        if engine is None or not inner_id or not self._enabled:
            return None

        cached_subject = self._find_cached_subject(source_id)
        detail_url = self._detail_urls.get(source_id, "")
        if not detail_url and cached_subject is not None:
            detail_url = str(cached_subject.extra.get("detail_url", ""))
        if not detail_url:
            detail_url = self._detail_url_from_rule(engine.rule, inner_id)
        if not detail_url and is_fetchable_url(inner_id):
            detail_url = inner_id
        # 接口式章节不需要详情页(只要站内 ID);若无详情页但规则走接口模式,
        # 仍然可以继续 —— 否则像 giriGiriLove 这种 sourceTemplate 为空的规则
        # 会在这一步被误判成"条目不存在"。
        if not detail_url and not engine.rule.chapter_via_api:
            return None

        title = cached_subject.title if cached_subject is not None else ""
        episodes: list[EpisodeInfo] = []
        try:
            episodes = await engine.chapters(
                self._fetcher_for(engine.rule),
                detail_url=detail_url,
                # 接口式章节的 @source 要**站内 ID**:接口模式下列表的
                # sourcePath 就是 inner_id(例如 ``$.vod_id`` = 26879),塞 URL
                # 进去上游直接返回空集(实测 giriGiriLove)。XPath 模式则只
                # 需要详情页 URL。
                source_key=inner_id if engine.rule.search_via_api else detail_url,
            )
        except Exception as error:  # noqa: BLE001 - 单条规则失败不影响调用方
            logger.warning(
                "Kazumi rule %s chapter fetch failed: %s",
                rule_name,
                type(error).__name__,
            )

        if not title and detail_url:
            title = await self._title_from_detail_page(detail_url)

        return SubjectDetail(
            source_id=source_id,
            title=title or inner_id,
            cover_url=cached_subject.cover_url if cached_subject is not None else "",
            summary=cached_subject.summary if cached_subject is not None else "",
            type=cached_subject.type if cached_subject is not None else "anime",
            lang=cached_subject.lang if cached_subject is not None else "ja",
            episodes=episodes,
            extra={
                "kazumi_rule": rule_name,
                "detail_url": detail_url,
                "playback_capability": "static-media-or-client-resolver",
                "playback_capability_note": (
                    "按当前集解析直媒体、静态播放器和有界 iframe；"
                    "JavaScript 页面返回独立客户端解析描述。"
                ),
                "source_identity": {
                    "rule_id": rule_name,
                    "rule_name": rule_name,
                    "site_name": urlparse(engine.rule.base_url).hostname or "",
                },
            },
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        """保留指定集数的全部已知线路，页面解析保持有界。"""
        rule_name, inner_id = split_source_id(source_id)
        engine = self._engines.get(rule_name)
        if not self._enabled or engine is None or not inner_id:
            return []
        if isinstance(episode, bool) or not isinstance(episode, int) or episode < 1:
            return []
        started = time.monotonic()
        try:
            # Metadata consumes the same total budget. The resolver owns its
            # remaining timer so finished routes survive slower peers timing out.
            async with asyncio.timeout(self._media_deadline):
                detail = await self.get_detail(source_id)
            if detail is None:
                return []
            referer = str(detail.extra.get("detail_url") or engine.search_referer)
            chapters: list[MediaChapter] = []
            seen: set[tuple[str, str]] = set()
            for item in detail.episodes:
                if item.number != episode:
                    continue
                raw = str(item.source_episode_id or "").strip()
                # A bare API id is not a chapter URL. Only a rule-provided
                # page template or an actual absolute/relative URL is used.
                if not is_fetchable_url(raw) and not raw.startswith(("/", "./", "../")):
                    continue
                candidate = absolute_url(referer or engine.rule.base_url, raw)
                if not public_url_shape(candidate):
                    continue
                channel = str(getattr(item, "channel", "") or len(chapters) + 1)
                key = (channel, candidate)
                if key in seen:
                    continue
                seen.add(key)
                chapters.append(MediaChapter(candidate, item.title or f"第{episode}集", channel))
            return await self._media_resolver.resolve(
                chapters, rule=engine.rule, referer=referer,
                user_agent=engine._user_agent,
                deadline=max(0.01, self._media_deadline - (time.monotonic() - started)),
            )
        except (TimeoutError, KazumiPageError, httpx.HTTPError):
            return []

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        """规则库没有"最新更新"字段,不支持列表页扫描。"""
        return []

    async def aclose(self) -> None:
        await self._media_resolver.aclose()
        await self._client.aclose()

    # ── 内部:HTTP ───────────────────────────────────────────────
    def _fetcher_for(self, rule: KazumiRule) -> _Fetcher:
        """给某条规则配一个带 ``base_url`` 的取数对象(引擎自己不会猜源站)。"""
        base = rule.base_url or ""
        return _Fetcher(self._fetch_metadata, base)

    async def _fetch_metadata(self, method: str, url: str, **kwargs: Any) -> bytes:
        """Cache only metadata GETs; avoid fetching detail twice for title+chapters."""
        cacheable = method.upper() == "GET" and not any(
            kwargs.get(key) for key in ("params", "headers", "form", "json_body")
        )
        cached = self._page_cache.get(url) if cacheable else None
        if cached and time.monotonic() - cached[0] < self._metadata_ttl:
            self._page_cache.move_to_end(url)
            return cached[1]
        content = await self._fetch_as(method, url, **kwargs)
        if cacheable:
            self._page_cache[url] = (time.monotonic(), content)
            self._page_cache.move_to_end(url)
            while len(self._page_cache) > self._cache_limit:
                self._page_cache.popitem(last=False)
        return content

    async def _fetch_as(
        self,
        method: str,
        url: str,
        *,
        params: dict[str, str] | None = None,
        headers: dict[str, str] | None = None,
        referer: str = "",
        user_agent: str = "",
        form: dict[str, str] | None = None,
        json_body: dict[str, Any] | None = None,
    ) -> bytes:
        """取元数据响应 bytes,附带 HTTP 显式 charset。

        Referer/UA 由规则引擎提供。客户端显式丢弃 Set-Cookie,请求 hook
        移除 Cookie(含规则头与重定向),不依赖 httpx 默认的会话行为。
        """
        if not is_fetchable_url(url):
            raise KazumiPageError(f"refused non-http url: {url!r}")

        host = urlparse(url).netloc.lower()
        await self._throttle(host)

        request_headers: dict[str, str] = {
            "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,ja;q=0.8",
        }
        if user_agent:
            request_headers["User-Agent"] = user_agent
        if referer:
            request_headers["Referer"] = referer
        if headers:
            request_headers.update({str(k): str(v) for k, v in headers.items()})

        # 一批目标站在国内出口上偶发 SYN 丢包(实测同一 URL 隔几秒再打就 200)。
        # 规则库是外部数据,"站点此刻抽风"不该被记成"规则不可用",所以对
        # 瞬时传输层错误做有限重试;4xx/5xx 属于确定性失败,不重试。
        last_error: Exception | None = None
        for attempt in range(self._attempts):
            try:
                response = await self._client.request(
                    method.upper(),
                    url,
                    params=params or None,
                    headers=request_headers,
                    data=form or None,
                    json=json_body if json_body is not None else None,
                )
            except (
                httpx.ConnectTimeout,
                httpx.ReadTimeout,
                httpx.WriteTimeout,
                httpx.PoolTimeout,
                httpx.ConnectError,
                httpx.ReadError,
                httpx.RemoteProtocolError,
            ) as error:
                last_error = error
                if attempt + 1 < self._attempts:
                    await asyncio.sleep(self._retry_backoff * (attempt + 1))
                    continue
                raise
            if response.status_code >= 400:
                raise KazumiPageError(f"http {response.status_code} for {url}")
            return _ResponseBytes(response.content, response.charset_encoding or "")
        raise last_error or KazumiPageError(f"unreachable request state for {url}")

    async def _throttle(self, host: str) -> None:
        """按主机名串行 + 保底间隔。

        按主机名而不是全局:18 条活跃规则指向几十个站,全局锁会把一轮搜索
        串行化;而同一个站被抓两次(例如 ``aafun`` 与 ``moonci`` 其实指向
        同一个域)时必须排队,否则触发反爬。
        """
        if not host:
            return
        lock = self._host_locks.setdefault(host, asyncio.Lock())
        async with lock:
            if self._min_interval <= 0:
                return
            last = self._host_last_request.get(host)
            now = time.monotonic()
            if last is not None:
                delay = self._min_interval - (now - last)
                if delay > 0:
                    await asyncio.sleep(delay)
            self._host_last_request[host] = time.monotonic()

    # ── 内部:缓存 ───────────────────────────────────────────────
    def _remember_detail_url(self, source_id: str, detail_url: str) -> None:
        self._detail_urls[source_id] = detail_url
        self._detail_urls.move_to_end(source_id)
        while len(self._detail_urls) > self._cache_limit:
            self._detail_urls.popitem(last=False)

    def _remember_results(
        self, keyword: str, rule_name: str, results: list[SubjectResult]
    ) -> None:
        key = f"{rule_name}\x00{keyword}"
        self._result_cache[key] = list(results)
        self._result_cache.move_to_end(key)
        while len(self._result_cache) > self._cache_limit:
            self._result_cache.popitem(last=False)

    def _find_cached_subject(self, source_id: str) -> SubjectResult | None:
        for results in self._result_cache.values():
            for subject in results:
                if subject.source_id == source_id:
                    return subject
        return None

    def _detail_url_from_rule(self, rule: KazumiRule, inner_id: str) -> str:
        """用规则的 ``sourceTemplate``(接口式规则)或 baseURL 拼详情页。"""
        api = rule.search_api
        if api is not None and api.source_template:
            candidate = substitute_placeholders(api.source_template, source=inner_id)
            if is_fetchable_url(candidate):
                return candidate
        if rule.base_url and is_fetchable_url(inner_id):
            return inner_id
        return ""

    async def _title_from_detail_page(self, detail_url: str) -> str:
        """缓存里没标题时,去详情页抓一次 ``<title>`` / ``og:title``。

        只作为兜底:多数情况下 ``search`` 已经把标题带回来了。
        """
        try:
            content = await self._fetch_metadata("GET", detail_url)
            document = parse_document(content)
        except Exception as error:  # noqa: BLE001 - 只是兜底,失败就算了
            logger.debug(
                "Kazumi detail title probe failed for %s: %s",
                detail_url,
                type(error).__name__,
            )
            return ""
        for expression in (
            "//meta[@property='og:title']/@content",
            "//meta[@name='title']/@content",
            "//title/text()",
            "//h1//text()",
        ):
            for node in xpath_all(document, expression):
                text = _text_of(node)
                if text:
                    return text.split("_")[0].split("-")[0].strip()
        return ""


def resolve_rules_dir() -> Any:
    """定位规则目录。

    优先环境变量 ``KAZUMI_RULES_DIR``;否则用仓库内快照。规则是外部数据、
    会随上游更新,所以目录整体可替换而不是把某几条硬编码进代码。

    目录名**故意**叫 ``kazumi_rules_data`` 而不是 ``kazumi_rules``:后者会与
    同目录的 ``kazumi_rules.py`` 同名,同目录下存在"同名模块 + 同名目录"时
    import 结果取决于查找器实现细节(当前实测是 ``.py`` 胜出,因为目录没有
    ``__init__.py``,只能作为命名空间包兜底),这种依赖不该留在代码里。
    """
    from pathlib import Path

    from ... import config as _config

    configured = getattr(_config, "KAZUMI_RULES_DIR", "")
    if configured:
        return Path(configured)
    return Path(__file__).resolve().parent / "kazumi_rules_data"


def rule_diagnostics(rules: list[KazumiRule]) -> list[dict[str, Any]]:
    """把规则的可执行性整理成可打印的诊断表(运维与实测报告共用)。"""
    table: list[dict[str, Any]] = []
    for rule in rules:
        table.append(
            {
                "name": rule.name,
                "api": rule.api_level,
                "search_mode": rule.search_mode,
                "chapter_mode": rule.chapter_mode,
                "can_search": rule.can_search,
                "can_list_chapters": rule.can_list_chapters,
                "rewrites": [
                    {"code": note.code, "from": note.original, "to": note.rewritten}
                    for note in rule.rewritten
                ],
                "base_url": rule.base_url,
            }
        )
    return table


__all__ = [
    "FALLBACK_USER_AGENTS",
    "SOURCE_ID_SEPARATOR",
    "KazumiPageError",
    "KazumiRuleEngine",
    "KazumiScraper",
    "absolute_url",
    "build_source_id",
    "episode_number_from_label",
    "is_fetchable_url",
    "parse_document",
    "resolve_rules_dir",
    "rule_diagnostics",
    "split_source_id",
    "xpath_all",
]
