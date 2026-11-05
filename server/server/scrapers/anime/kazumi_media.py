"""Bounded current-episode media extraction for Kazumi chapter URLs.

Only a current ``player_aaaa.url``, video/source element or explicit player
iframe is followed. Scripts are never executed and arbitrary URL-looking text
(next episodes, ads, script bundles) is never promoted to a media candidate.
"""

from __future__ import annotations

import asyncio
import base64
import html
import ipaddress
import json
import re
from dataclasses import dataclass, field
from http.cookiejar import CookieJar, DefaultCookiePolicy
from typing import Any, Awaitable, Callable
from urllib.parse import unquote, urljoin, urlsplit

import httpx
from lxml import etree, html as lxml_html

from ...public_http import PublicHttpTransport, UnsafeDestination, is_public_ip, resolve_public_http_url
from ..base import DIRECT_MEDIA_URL, VideoLine, classify_media_url, media_format_from_url
from .kazumi_rules import KazumiRule

# Only page extraction is budgeted. Already discovered media/route identities
# are not a five-item display shortlist and must not be sliced on return.
MAX_PAGE_ROUTES = 5
MAX_MEDIA_ROUTES = MAX_PAGE_ROUTES  # backwards-compatible budget name
MAX_PAGE_REQUESTS = 4
MAX_IFRAME_DEPTH = 2
MAX_PAGE_BYTES = 1024 * 1024

# Exact hosts already reviewed in lib/src/rules/bundled_kazumi_rules.dart.
# These are rule-scoped, not suffixes/wildcards and not all downloaded domains.
REVIEWED_MEDIA_HOSTS: dict[str, tuple[str, ...]] = {
    "MXdm": ("yzzy.play-cdn19.com", "yzzy.play-cdn2.com"),
    "mxdm": ("yzzy.play-cdn19.com", "yzzy.play-cdn2.com"),
    "moonci": ("play.xfvod.pro",),
    "xfdm": ("play.xfvod.pro",),
    "xfdmneo": ("play.xfvod.pro",),
    "xfdmnext": ("play.xfvod.pro",),
}

_PLAYER_ASSIGNMENT = re.compile(r"\bplayer_aaaa\s*=\s*")
_AD_CONTEXT = re.compile(
    r"(?:^|[^a-z0-9])(?:ads?|advert(?:isement|ising)?|banner|preroll|trailer|preview|next)(?:$|[^a-z0-9])",
    re.I,
)
_PLAYER_CONTEXT = re.compile(r"player|video|playbox|embed|dplayer|artplayer|播放器|播放", re.I)
_MIME_FORMATS = {
    "application/vnd.apple.mpegurl": "hls",
    "application/x-mpegurl": "hls",
    "audio/mpegurl": "hls",
    "audio/x-mpegurl": "hls",
    "application/dash+xml": "dash",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/x-matroska": "mkv",
    "video/x-flv": "flv",
    "video/quicktime": "mov",
}


def public_url_shape(value: str) -> bool:
    """Reject local/ambiguous URL shapes before any DNS or mock transport call."""
    try:
        if not value or any(ord(char) <= 32 for char in value) or "\\" in value:
            return False
        parsed, authority = httpx.URL(value), urlsplit(value)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.host
            or authority.username is not None
            or authority.password is not None
            or "%" in parsed.host
        ):
            return False
        host = parsed.raw_host.decode("ascii").lower().rstrip(".")
        if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
            return False
        try:
            ipaddress.ip_address(host)
        except ValueError:
            return True
        return is_public_ip(host)
    except (ValueError, UnicodeError, httpx.InvalidURL):
        return False


def _absolute(page_url: str, value: Any) -> str:
    if not isinstance(value, str):
        return ""
    value = html.unescape(value).strip().replace(r"\/", "/")
    if not value or value.startswith("#"):
        return ""
    try:
        candidate = urljoin(page_url, value)
    except ValueError:
        return ""
    return candidate if public_url_shape(candidate) else ""


def _host(value: str) -> str:
    return httpx.URL(value).raw_host.decode("ascii").lower().rstrip(".")


def _media_format(value: str, declared: str = "") -> str:
    inferred = media_format_from_url(value)
    if inferred != "auto":
        return inferred
    declared = declared.lower().split(";", 1)[0].strip()
    if declared in {"m3u8", "mpd"}:
        return "hls" if declared == "m3u8" else "dash"
    return _MIME_FORMATS.get(declared, declared if declared in {"hls", "dash", "mp4", "webm", "mkv", "flv", "mov"} else "auto")


def _is_media(value: str, declared: str = "") -> bool:
    return public_url_shape(value) and classify_media_url(value, _media_format(value, declared)) == DIRECT_MEDIA_URL


def _ad_node(node: etree._Element) -> bool:
    for element in (node, *node.iterancestors()):
        context = " ".join(str(element.get(key) or "") for key in ("id", "class", "role", "title", "data-role"))
        if _AD_CONTEXT.search(context) or element.get("data-ad") is not None:
            return True
    return False


def _visible_iframe(node: etree._Element) -> bool:
    style = re.sub(r"\s+", "", str(node.get("style") or "").lower())
    return not (
        _ad_node(node)
        or "display:none" in style
        or "visibility:hidden" in style
        or node.get("hidden") is not None
        or str(node.get("width") or "").strip() in {"0", "1"}
        or str(node.get("height") or "").strip() in {"0", "1"}
    )


def _player_iframe(node: etree._Element) -> bool:
    return any(
        _PLAYER_CONTEXT.search(" ".join(str(element.get(key) or "") for key in ("id", "class", "title")))
        for element in (node, *node.iterancestors())
    )


@dataclass
class PageCandidates:
    media: list[tuple[str, str]] = field(default_factory=list)
    iframes: list[str] = field(default_factory=list)
    current_urls: list[str] = field(default_factory=list)
    dynamic: bool = False


def page_candidates(content: bytes, page_url: str, charset: str = "") -> PageCandidates:
    """Parse only structurally current player values; never scan the whole page."""
    result = PageCandidates()
    try:
        text = content.decode(charset or "utf-8")
    except (LookupError, UnicodeDecodeError):
        text = content.decode("utf-8", "replace")
    try:
        document = lxml_html.fromstring(text)
    except (etree.ParserError, ValueError):
        return result

    # Inspect executable script nodes, not comments, HTML text or ad scripts.
    for script in document.xpath("//script[not(@type) or @type='text/javascript' or @type='application/javascript' or @type='module']"):
        if _ad_node(script):
            continue
        script_text = script.text or ""
        if script_text.strip() or script.get("src"):
            result.dynamic = True
        match = _PLAYER_ASSIGNMENT.search(script_text)
        if not match:
            continue
        try:
            player, _ = json.JSONDecoder().raw_decode(script_text[match.end():].lstrip())
            if not isinstance(player, dict) or not isinstance(player.get("url"), str):
                break
            value = html.unescape(player["url"]).strip()
            encrypt = int(player.get("encrypt", 0) or 0)
            if encrypt == 1:
                value = unquote(value)
            elif encrypt == 2:
                value = unquote(base64.b64decode(value + "=" * (-len(value) % 4), validate=True).decode("utf-8"))
            elif encrypt != 0:
                break
            current = _absolute(page_url, value)
            if current:
                result.current_urls.append(current)
                declared = str(player.get("type") or "")
                if _is_media(current, declared):
                    result.media.append((current, _media_format(current, declared)))
        except (ValueError, TypeError, UnicodeDecodeError):
            break
        # A second assignment often belongs to a preview/ad player. The first
        # current player_aaaa object is authoritative, even if it is unresolved.
        break

    for node in document.xpath("//video[@src] | //video//source[@src]"):
        if _ad_node(node):
            continue
        value = _absolute(page_url, str(node.get("src") or ""))
        declared = str(node.get("type") or "")
        if value:
            result.current_urls.append(value)
            if _is_media(value, declared):
                result.media.append((value, _media_format(value, declared)))
            result.dynamic = True

    frames = [node for node in document.xpath("//iframe[@src or @data-src]") if _visible_iframe(node)]
    explicit = [node for node in frames if _player_iframe(node)]
    # A lone visible iframe is an unambiguous embed; multiple unrelated frames
    # are not a reason to crawl ads/widgets until a media file happens to appear.
    for node in explicit or (frames if len(frames) == 1 else []):
        value = _absolute(page_url, str(node.get("src") or node.get("data-src") or ""))
        if value and value not in result.iframes:
            result.iframes.append(value)
            result.dynamic = True
    if document.xpath("//*[@id='root' or @id='app' or @id='__next' or @id='player' or @id='dplayer']"):
        result.dynamic = True
    result.media = list(dict.fromkeys(result.media))
    result.current_urls = list(dict.fromkeys(result.current_urls))
    return result


@dataclass(frozen=True)
class MediaChapter:
    url: str
    title: str
    channel: str


@dataclass
class _Page:
    url: str
    content: bytes
    charset: str
    content_type: str
    visited: tuple[str, ...]


@dataclass
class _Context:
    used: int = 0
    deferred: set[str] = field(default_factory=set)
    checks: dict[str, asyncio.Task[bool]] = field(default_factory=dict)
    pages: dict[tuple[str, str], asyncio.Task[_Page | None]] = field(default_factory=dict)
    semaphore: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(3))


class _NoCookiePolicy(DefaultCookiePolicy):
    def set_ok(self, cookie: Any, request: Any) -> bool:
        return False


async def _strip_cookie(request: httpx.Request) -> None:
    request.headers.pop("Cookie", None)


class KazumiMediaResolver:
    """Keep known routes; inspect five pages/four requests/two iframe hops."""

    def __init__(
        self,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = 5.0,
        throttle: Callable[[str], Awaitable[None]] | None = None,
    ) -> None:
        self._throttle = throttle
        # The public transport pins every connection (including redirects) to
        # checked DNS answers, rather than check-then-resolve with a normal client.
        self._client = httpx.AsyncClient(
            transport=PublicHttpTransport(transport=transport, resolve=resolve_public_http_url),
            trust_env=False,
            timeout=max(0.1, timeout),
            follow_redirects=False,
            cookies=CookieJar(policy=_NoCookiePolicy()),
            event_hooks={"request": [_strip_cookie]},
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _public(self, url: str, context: _Context) -> bool:
        if not public_url_shape(url):
            return False
        parsed = httpx.URL(url)
        key = f"{parsed.host}:{parsed.port or (443 if parsed.scheme == 'https' else 80)}"

        async def check() -> bool:
            try:
                await resolve_public_http_url(url)
                return True
            except (UnsafeDestination, ValueError, OSError, TimeoutError):
                return False

        if key not in context.checks:
            context.checks[key] = asyncio.create_task(check())
        return await context.checks[key]

    async def _fetch_page(self, url: str, referer: str, user_agent: str, context: _Context) -> _Page | None:
        key = (url, referer)
        if key not in context.pages:
            context.pages[key] = asyncio.create_task(self._fetch_uncached(url, referer, user_agent, context))
        return await context.pages[key]

    async def _fetch_uncached(self, url: str, referer: str, user_agent: str, context: _Context) -> _Page | None:
        visited: list[str] = []
        headers = {"User-Agent": user_agent, "Accept": "text/html,application/xhtml+xml,*/*;q=0.8"}
        if public_url_shape(referer):
            headers["Referer"] = referer
        try:
            async with context.semaphore:
                while context.used < MAX_PAGE_REQUESTS and url not in visited:
                    if not await self._public(url, context):
                        return None
                    # There is no await between the final budget test and its
                    # reservation: concurrent routes cannot spend a fifth slot.
                    if context.used >= MAX_PAGE_REQUESTS:
                        context.deferred.add(url)
                        return None
                    context.used += 1
                    visited.append(url)
                    if self._throttle:
                        await self._throttle(httpx.URL(url).netloc.decode("ascii"))
                    async with self._client.stream("GET", url, headers=headers) as response:
                        if response.status_code in {301, 302, 303, 307, 308}:
                            target = _absolute(url, response.headers.get("Location", ""))
                            if not target or len(visited) >= MAX_PAGE_REQUESTS:
                                return None
                            headers["Referer"] = url
                            url = target
                            continue
                        if response.status_code != 200:
                            return None
                        content_type = response.headers.get("Content-Type", "").split(";", 1)[0].lower().strip()
                        if content_type in _MIME_FORMATS:
                            return _Page(url, b"", response.charset_encoding or "", content_type, tuple(visited))
                        body = bytearray()
                        async for chunk in response.aiter_bytes():
                            body.extend(chunk)
                            if len(body) > MAX_PAGE_BYTES:
                                return None
                        return _Page(url, bytes(body), response.charset_encoding or "", content_type, tuple(visited))
        except (httpx.HTTPError, ValueError, OSError):
            return None
        if context.used >= MAX_PAGE_REQUESTS:
            context.deferred.add(url)
        return None

    async def resolve(
        self,
        chapters: list[MediaChapter],
        *,
        rule: KazumiRule,
        referer: str,
        user_agent: str,
        deadline: float = 12.0,
    ) -> list[VideoLine]:
        context = _Context()
        # Shape-checked media URLs require no extraction request or extra DNS
        # lookup here; the aggregator/client retains the normal public probe.
        direct: dict[int, list[VideoLine]] = {}
        page_indices: list[int] = []
        for index, chapter in enumerate(chapters):
            if _is_media(chapter.url):
                direct[index] = [VideoLine(
                    url=chapter.url, title=f"{rule.name} · {chapter.title}".strip(),
                    format=_media_format(chapter.url),
                    headers={"Referer": referer, "User-Agent": user_agent},
                    source_name=f"kazumi:{rule.name}:{chapter.channel}",
                )]
            elif public_url_shape(chapter.url) and len(page_indices) < MAX_PAGE_ROUTES:
                page_indices.append(index)
        tasks_by_index = {
            index: asyncio.create_task(self._resolve_chapter(chapters[index], rule, referer, user_agent, context))
            for index in page_indices
        }
        tasks = list(tasks_by_index.values())
        if not chapters:
            return []
        try:
            done, pending = await asyncio.wait(tasks, timeout=max(0.01, deadline)) if tasks else (set(), set())
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            lines: list[VideoLine] = []
            seen: set[tuple[str, str]] = set()
            for index, chapter in enumerate(chapters):
                candidates = direct.get(index, [])
                task = tasks_by_index.get(index)
                if task in done and not task.cancelled():
                    try:
                        candidates = task.result()
                    except Exception:
                        candidates = []
                deferred = task is None or task in pending or chapter.url in context.deferred
                if not candidates and deferred and public_url_shape(chapter.url):
                    # No inspected dynamic page means no JS descriptor. Keep
                    # discovery identity only; never expose HTML as media URL.
                    candidates = [VideoLine(
                        url="", title=f"{rule.name} · {chapter.title}".strip(), format="auto",
                        source_name=f"kazumi:{rule.name}:{chapter.channel}",
                    )]
                for line in candidates:
                    key = (line.source_name, line.url or str(line.client_resolver.get("page_url", "")) or chapter.url)
                    if key not in seen:
                        seen.add(key)
                        lines.append(line)
            return lines
        finally:
            # _fetch_page and _public use shared tasks for single-flight reads;
            # cancellation must collect those too, not leave a background fetch.
            owned = [*tasks, *context.pages.values(), *context.checks.values()]
            for task in owned:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*owned, return_exceptions=True)

    async def _resolve_chapter(
        self,
        chapter: MediaChapter,
        rule: KazumiRule,
        referer: str,
        user_agent: str,
        context: _Context,
    ) -> list[VideoLine]:
        if not await self._public(chapter.url, context):
            return []
        source_name = f"kazumi:{rule.name}:{chapter.channel}"
        title = f"{rule.name} · {chapter.title}".strip()

        def line(url: str, page_url: str, declared: str = "") -> VideoLine:
            return VideoLine(url=url, title=title, format=_media_format(url, declared),
                             headers={"Referer": page_url, "User-Agent": user_agent}, source_name=source_name)

        if _is_media(chapter.url):
            return [line(chapter.url, referer)]

        root = await self._fetch_page(chapter.url, referer, user_agent, context)
        if root is None:
            return []
        page_hosts: dict[str, None] = {}
        media_hosts: dict[str, None] = {}
        visited: set[str] = set()
        dynamic = False
        queue: list[tuple[_Page, int]] = [(root, 0)]
        direct: list[VideoLine] = []
        while queue:
            page, depth = queue.pop(0)
            if page.url in visited:
                continue
            visited.add(page.url)
            for url in page.visited:
                page_hosts[_host(url)] = None
            media_hosts[_host(page.url)] = None
            declared = _MIME_FORMATS.get(page.content_type, "")
            if declared or page.content.lstrip().startswith(b"#EXTM3U"):
                direct.append(line(page.url, page.visited[-2] if len(page.visited) > 1 else referer, declared or "hls"))
                continue
            # JSON, images and arbitrary binary responses are not browser player
            # pages and should not become a WebView fallback.
            if page.content_type and page.content_type not in {"text/html", "application/xhtml+xml", "text/plain"}:
                continue
            parsed = page_candidates(page.content, page.url, page.charset)
            dynamic = dynamic or parsed.dynamic
            for value, fmt in parsed.media:
                if await self._public(value, context):
                    direct.append(line(value, page.url, fmt))
            for value in parsed.current_urls:
                if await self._public(value, context):
                    media_hosts[_host(value)] = None
            if not direct:
                for frame_url in parsed.iframes:
                    if not await self._public(frame_url, context):
                        continue
                    page_hosts[_host(frame_url)] = None
                    media_hosts[_host(frame_url)] = None
                    if _is_media(frame_url):
                        direct.append(line(frame_url, page.url))
                    elif depth < MAX_IFRAME_DEPTH and frame_url not in visited:
                        nested = await self._fetch_page(frame_url, page.url, user_agent, context)
                        if nested is not None:
                            queue.append((nested, depth + 1))
            # Once a current media source is known, there is no reason to visit
            # additional iframes or turn the same route into a JS descriptor.
            if direct:
                break
        if direct:
            return list({candidate.url: candidate for candidate in direct}.values())
        if not dynamic:
            return []

        for api in (rule.search_api, rule.chapter_api):
            if api and api.request.url and await self._public(api.request.url, context):
                page_hosts[_host(api.request.url)] = None
        # Browser loading may legitimately return from the chapter host to its
        # public detail/base host; permit that explicit origin, not every domain.
        if await self._public(referer, context):
            page_hosts[_host(referer)] = None
        for host in REVIEWED_MEDIA_HOSTS.get(rule.name, ()):
            if await self._public(f"https://{host}/", context):
                media_hosts[host] = None
        # Keep exact hosts even for same-origin JS media. An empty list must
        # never mean "allow every host" in the client permission layer.
        descriptor = {
            "kind": "kazumi_page_v1",
            "page_url": root.url,
            "referer": referer if await self._public(referer, context) else "",
            "rule_id": rule.name,
            "rule_name": rule.name,
            "user_agent": user_agent,
            "page_hosts": list(page_hosts)[:16],
            "media_hosts": list(media_hosts)[:16],
        }
        return [VideoLine(url="", title=title, format="auto",
                          headers={"Referer": root.url, "User-Agent": user_agent},
                          source_name=source_name, client_resolver=descriptor)]
