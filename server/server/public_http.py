"""Public-only HTTP destinations and DNS-pinned transport for playlist reads."""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from collections.abc import Awaitable, Callable
from urllib.parse import urlsplit

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
