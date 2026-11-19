"""Public-only HTTP destinations and DNS-pinned transport for playlist reads."""

from __future__ import annotations

import asyncio
import ipaddress
import posixpath
import re
import socket
from collections.abc import Awaitable, Callable
from urllib.parse import unquote, urlsplit

import httpx


class UnsafeDestination(httpx.RequestError):
    """A destination is invalid, non-public, or cannot be safely resolved."""


def is_public_ip(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    if "%" in value or not address.is_global or address.is_multicast:
        return False
    if isinstance(address, ipaddress.IPv6Address):
        if address.ipv4_mapped:
            return is_public_ip(str(address.ipv4_mapped))
        if address.sixtofour:
            return is_public_ip(str(address.sixtofour))
        if address.teredo:
            return all(is_public_ip(str(item)) for item in address.teredo)
        if address in ipaddress.ip_network("64:ff9b::/96"):
            return is_public_ip(str(ipaddress.IPv4Address(int(address) & 0xFFFFFFFF)))
        if address.is_site_local:
            return False
    return True


async def resolve_public_http_url(url: str) -> tuple[str, ...]:
    """Validate the same normalized host HTTPX uses, then return only public IPs.

    All answers must be public. The caller must connect to these returned IPs,
    not resolve the original hostname again after this check.
    """
    try:
        parsed = httpx.URL(url)
        authority = urlsplit(url)
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.host
            or authority.username is not None
            or authority.password is not None
            or any(ord(char) <= 32 for char in url)
            or "\\" in url
            or "%" in parsed.host
        ):
            raise ValueError("invalid URL")
        host = parsed.raw_host.decode("ascii").rstrip(".").lower()
        if host == "localhost" or host.endswith((".localhost", ".local")):
            raise ValueError("local hostname")
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except (ValueError, httpx.InvalidURL) as error:
        raise UnsafeDestination("Destination is not public HTTP(S)") from error

    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None:
        addresses = (str(literal),)
    else:
        try:
            async with asyncio.timeout(5.0):
                records = await asyncio.get_running_loop().getaddrinfo(
                    host,
                    port,
                    type=socket.SOCK_STREAM,
                )
        except (OSError, TimeoutError, UnicodeError) as error:
            raise UnsafeDestination("Destination DNS lookup failed") from error
        addresses = tuple(
            dict.fromkeys(record[4][0] for record in records if record[4])
        )
    if not addresses or not all(is_public_ip(item) for item in addresses):
        raise UnsafeDestination("Destination resolved to a non-public address")
    return addresses


async def is_public_http_url(url: str) -> bool:
    try:
        await resolve_public_http_url(url)
    except UnsafeDestination:
        return False
    return True


#: 中继对外交付媒体用的路径前缀。线段与清单都走它,别的路径没有理由放行。
RELAY_MEDIA_PREFIX = "/media/"


def _normalized_path(path: str) -> str:
    """归一化路径,让前缀判断无法被穿越写法绕过。

    只做字符串 ``startswith`` 会被 ``/media/../../etc/passwd`` 这类写法骗过,
    百分号编码(``%2e%2e%2f``)同理。所以先解编码、再去掉重复斜杠、最后用
    ``normpath`` 把 ``..`` 折叠掉,拿归一化后的结果比较。

    两个容易踩的点:
      * ``posixpath.normpath("")`` 返回 ``"."`` 而不是 ``"/"`` —— 空路径在这里
        代表根,必须显式处理,否则基址会被拼成 ``/./media/``,判断永远为假;
      * 结尾斜杠要保留 —— ``/media/`` 掉成 ``/media`` 后,前缀判断就会把
        ``/media`` 本身也当成命中。
    """
    if not path or path == "/":
        return "/"
    decoded = unquote(path)
    collapsed = re.sub(r"/+", "/", decoded)
    normalized = posixpath.normpath(collapsed)
    if not normalized.startswith("/"):
        normalized = "/" + normalized
    if collapsed.endswith("/") and not normalized.endswith("/"):
        normalized += "/"
    return normalized


def is_relay_media_url(url: str, relay_base: str) -> bool:
    """判断 ``url`` 是否正好是 ``relay_base`` 上的媒体入口。

    精确比较 scheme/host/port,并要求**归一化后**的路径落在 ``/media/`` 之下
    —— 只放行中继真正会交付的那一类地址,不放行它的其他端点,也不放行同主机
    的其他服务。``resolve_fetch_url`` 与 ``hls_clean.validate_fetch_url`` 共用
    它,避免两处规则漂移。
    """
    if not relay_base:
        return False
    candidate = urlsplit(url)
    expected = urlsplit(relay_base)
    if not (candidate.hostname and candidate.port and expected.hostname):
        return False
    if (candidate.hostname != expected.hostname
            or candidate.scheme != expected.scheme
            or candidate.port != expected.port):
        return False
    base_path = _normalized_path(expected.path).rstrip("/")
    if base_path == "/":
        base_path = ""
    prefix = f"{base_path}{RELAY_MEDIA_PREFIX}"
    return _normalized_path(candidate.path).startswith(prefix)


async def resolve_fetch_url(url: str) -> tuple[str, ...]:
    """``resolve_public_http_url`` 加上自建中继媒体入口这一个例外。

    ``PublicHttpTransport`` 把连接钉到 resolve 返回的地址上 —— 所以 resolve
    就是**唯一的校验点**,放行什么地址完全由它决定。自建中继在本机,后端取
    它的清单纯属内部调用,但它的地址是 ``127.0.0.1``,会被公网校验判为非法,
    于是剪广告功能静默失效。

    只放行**配置里那一个中继地址上的媒体入口**(前缀 ``/media/``),不是整个
    回环网段、不是中继的任意路径、也不接任意私网地址。返回的仍是"经过校验的
    地址",调用方照常钉着它连、Host 与 SNI 照常设成原主机名 —— 防 SSRF 的
    语义没有松动,只是多了一条显式白名单。
    """
    from . import config

    local = config.ANICH_RELAY_FETCH_BASE
    if local and is_relay_media_url(url, local):
        expected = urlsplit(local)
        return (str(expected.hostname),)
    return await resolve_public_http_url(url)


class PublicHttpTransport(httpx.AsyncBaseTransport):
    """Connect to validated IPs while preserving origin Host and TLS identity.

    No environment proxy and no keep-alive reuse: two hostnames sharing an IP
    must not accidentally share a TLS connection authenticated for one origin.
    This transport is scoped to small GET-only playlist fetches.
    """

    def __init__(
        self,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        resolve: Callable[[str], Awaitable[tuple[str, ...]]] = resolve_public_http_url,
    ) -> None:
        self._resolve = resolve
        self._transport = transport or httpx.AsyncHTTPTransport(
            trust_env=False,
            limits=httpx.Limits(max_connections=8, max_keepalive_connections=0),
        )

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        addresses = await self._resolve(str(request.url))
        headers = request.headers.copy()
        headers["Host"] = request.url.netloc.decode("ascii")
        extensions = {
            **request.extensions,
            "sni_hostname": request.url.raw_host.decode("ascii"),
        }
        for index, address in enumerate(addresses):
            pinned = httpx.Request(
                request.method,
                request.url.copy_with(host=address),
                headers=headers,
                stream=request.stream,
                extensions=extensions,
            )
            try:
                return await self._transport.handle_async_request(pinned)
            except (httpx.ConnectError, httpx.ConnectTimeout):
                if index + 1 == len(addresses):
                    raise
        raise UnsafeDestination("Destination has no public addresses")

    async def aclose(self) -> None:
        await self._transport.aclose()
