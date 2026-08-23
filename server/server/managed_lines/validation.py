"""Safety policy and bounded verifier adapters for managed remote URLs."""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from urllib.parse import urlsplit

from ..aggregator import (
    READ_TIMEOUT,
    STARTUP_UNKNOWN,
    UNAVAILABLE,
    UNKNOWN_EXCEPTION,
    AggregatedVideoLine,
    LineVerificationResult,
    aggregator as playback_aggregator,
)
from ..scrapers.base import PLAYER_PAGE_URL, classify_media_url


HostResolver = Callable[[str, int], Awaitable[set[str]]]
MediaProbe = Callable[[AggregatedVideoLine], Awaitable[LineVerificationResult]]
_ALLOWED_HEADERS = {"referer": "Referer", "origin": "Origin"}


class ManagedLineValidationError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def validate_managed_headers(headers: dict[str, str] | None) -> dict[str, str]:
    normalized: dict[str, str] = {}
    for raw_name, raw_value in (headers or {}).items():
        name = str(raw_name).strip().lower()
        value = str(raw_value).strip()
        canonical_name = _ALLOWED_HEADERS.get(name)
        if canonical_name is None:
            raise ManagedLineValidationError(
                "forbidden_header", "管理线路只允许 Referer 和 Origin 请求头"
            )
        if len(value) > 2048 or any(
            ord(character) < 0x20 or ord(character) == 0x7F
            for character in value
        ):
            raise ManagedLineValidationError(
                "invalid_header_value", "管理线路请求头内容格式不正确"
            )
        if value:
            normalized[canonical_name] = value
    return normalized


@dataclass(frozen=True)
class ManagedLineVerification:
    status: str
    error_category: str
    latency_ms: int
    startup_profile: str


async def _default_media_probe(line: AggregatedVideoLine) -> LineVerificationResult:
    result = await playback_aggregator._line_verification_status(
        line,
        detailed=True,
    )
    if isinstance(result, LineVerificationResult):
        return result
    return LineVerificationResult(status=str(result))


class ManagedLineVerifier:
    """Validate policy and probe limited in-memory bytes without media storage."""

    def __init__(
        self,
        *,
        url_policy: PublicMediaUrlPolicy | None = None,
        probe: MediaProbe = _default_media_probe,
        timeout_seconds: float = 12,
    ) -> None:
        self._url_policy = url_policy or PublicMediaUrlPolicy()
        self._probe = probe
        self._timeout_seconds = max(0.5, min(60.0, timeout_seconds))

    async def verify(
        self,
        url: str,
        *,
        format_hint: str,
        headers: dict[str, str],
    ) -> ManagedLineVerification:
        canonical_url = await self._url_policy.validate(
            url,
            format_hint=format_hint,
        )
        safe_headers = validate_managed_headers(headers)
        line = AggregatedVideoLine(
            url=canonical_url,
            format=format_hint,
            source="managed:verification",
            headers=safe_headers,
        )
        try:
            result = await asyncio.wait_for(
                self._probe(line),
                timeout=self._timeout_seconds,
            )
        except asyncio.CancelledError:
            raise
        except asyncio.TimeoutError:
            result = LineVerificationResult(
                status=UNAVAILABLE,
                error_category=READ_TIMEOUT,
            )
        except Exception:
            result = LineVerificationResult(
                status=UNAVAILABLE,
                error_category=UNKNOWN_EXCEPTION,
            )
        return ManagedLineVerification(
            status=result.status,
            error_category=result.error_category,
            latency_ms=max(0, result.latency_ms),
            startup_profile=result.startup_profile or STARTUP_UNKNOWN,
        )


async def _resolve_host(host: str, port: int) -> set[str]:
    loop = asyncio.get_running_loop()
    try:
        addresses = await loop.run_in_executor(
            None,
            lambda: socket.getaddrinfo(host, port, type=socket.SOCK_STREAM),
        )
    except OSError as error:
        raise ManagedLineValidationError(
            "dns_unavailable", "远程媒体主机当前无法解析"
        ) from error
    return {str(item[4][0]) for item in addresses if item[4]}


class PublicMediaUrlPolicy:
    def __init__(self, *, resolve: HostResolver = _resolve_host) -> None:
        self._resolve = resolve

    async def validate(self, value: str, *, format_hint: str = "auto") -> str:
        url = str(value or "").strip()
        try:
            parsed = urlsplit(url)
        except ValueError as error:
            raise ManagedLineValidationError(
                "invalid_url", "远程媒体地址格式不正确"
            ) from error
        if parsed.scheme.lower() not in {"http", "https"}:
            raise ManagedLineValidationError(
                "unsupported_scheme", "远程媒体地址只允许 HTTP 或 HTTPS"
            )
        if parsed.username is not None or parsed.password is not None:
            raise ManagedLineValidationError(
                "url_userinfo", "远程媒体地址不能包含用户名或密码"
            )
        host = (parsed.hostname or "").strip().lower()
        if not host:
            raise ManagedLineValidationError(
                "invalid_host", "远程媒体地址缺少有效主机"
            )
        if classify_media_url(url, format_hint) == PLAYER_PAGE_URL:
            raise ManagedLineValidationError(
                "player_page", "只能添加直接媒体地址，不能添加播放器网页"
            )
        if host == "localhost" or host.endswith((".localhost", ".local")):
            raise ManagedLineValidationError(
                "non_public_target", "远程媒体地址必须指向公共网络主机"
            )
        try:
            port = parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
        except ValueError as error:
            raise ManagedLineValidationError(
                "invalid_port", "远程媒体地址端口不正确"
            ) from error
        try:
            ipaddress.ip_address(host)
        except ValueError:
            addresses = await self._resolve(host, port)
        else:
            addresses = {host}
        if not addresses:
            raise ManagedLineValidationError(
                "dns_unavailable", "远程媒体主机当前无法解析"
            )
        try:
            public = all(ipaddress.ip_address(item).is_global for item in addresses)
        except ValueError as error:
            raise ManagedLineValidationError(
                "dns_invalid", "远程媒体主机解析结果不正确"
            ) from error
        if not public:
            raise ManagedLineValidationError(
                "non_public_target", "远程媒体地址必须指向公共网络主机"
            )
        return url
