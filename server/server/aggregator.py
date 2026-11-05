"""
统一聚合层

整合独立站点适配器、MacCMS、TVBox、TVMaze、TMDB 与媒体解析器，
提供统一的搜索、详情和视频源获取接口。

所有内容仅存储元数据和 URL，不存储视频文件。
"""

import json
import time
import logging
import asyncio
import ipaddress
import re
import socket
from collections import deque
from collections.abc import AsyncIterator, Awaitable, Callable, Iterator
from typing import Optional
from dataclasses import dataclass, field, replace
from urllib.parse import urljoin, urlparse

import httpx

from .m3u8_resolver import resolver as m3u8_resolver
from .public_http import is_public_http_url as _is_public_http_url
from .public_http import is_public_ip as _is_public_ip
from .playback_discovery import SourceDiscoveryDiagnostic, SourceDiscoveryStatus
from .playback_discovery.strategy import (
    DiscoverySource,
    progressive_alias_search,
)
from .playback_health import SourceFailureScope
from .scrapers.maccms import MacCmsScraper, MacCmsSearchOutcome
from .scrapers.maccms_sites import site_priority
from .scrapers.content_identity import content_matches_request, needs_content_detail
from .scrapers.tvbox_adapter import TvBoxAdapterScraper
from .scrapers.direct_stream import NivodScraper, PpnixScraper
from .scrapers.series.vod_common import CommonVodScraper
from .scrapers.anime.age import AgeScraper
from .scrapers.anime.anich import AniChScraper
from .scrapers.anime.anich_transport import AniChUpstreamError
from .scrapers.anime.animeko import AnimekoScraper
from .scrapers.anime.girigiri import GiriGiriScraper
from .scrapers.anime.html_direct import (
    OriginSearchThrottledError,
    create_html_direct_anime_scrapers,
)
from .scrapers.anime.kazumi import KazumiScraper
from .scrapers.anime.xgcartoon import XgCartoonScraper
from .scrapers.anime.yhdmm import YhdmmScraper
from .providers import MediaProvider, ProviderMetadata, ProviderRegistry
from .scrapers.base import (
    DIRECT_MEDIA_URL,
    INVALID_MEDIA_URL,
    PLAYER_PAGE_URL,
    SubjectResult,
    classify_media_url,
)
from .config import (
    MACCMS_FALLBACK_WAVE_DELAY_SECONDS,
    MACCMS_FULL_ALIAS_LIMIT,
    MACCMS_FULL_QUERY_BUDGET,
    MACCMS_QUICK_ALIAS_LIMIT,
    MACCMS_QUICK_QUERY_BUDGET,
    MACCMS_SEARCH_MAX_CONCURRENCY,
    M3U8_SEARCH_ENABLED,
    PLAYBACK_PROVIDER_IDS,
    SOURCE_MAX_CONCURRENCY,
)
from .stable_identity import stable_digest
from .title_matching import SourceMatchEvidence, analyze_source_match

logger = logging.getLogger(__name__)

SERVER_VERIFIED = "server_verified"
CLIENT_PROBE_REQUIRED = "client_probe_required"
CLIENT_RESOLVER_REQUIRED = "client_resolver_required"
UNAVAILABLE = "unavailable"

STARTUP_UNKNOWN = "unknown"
STARTUP_HLS = "hls"
STARTUP_MP4_FASTSTART = "mp4_faststart"
STARTUP_MP4_TAIL_MOOV = "mp4_tail_moov"

DNS_FAILURE = "dns_failure"
CONNECT_TIMEOUT = "connect_timeout"
READ_TIMEOUT = "read_timeout"
RESTRICTED = "restricted"
NON_PUBLIC_TARGET = "non_public_target"
STALE_ROUTE = "stale_route"
MALFORMED_MANIFEST = "malformed_manifest"
EMPTY_MEDIA = "empty_media"
PARSER_MISMATCH = "parser_mismatch"
SERVER_BLOCKED_CLIENT_CANDIDATE = "server_blocked_client_candidate"
RATE_LIMITED = "rate_limited"
UNKNOWN_EXCEPTION = "unknown_exception"

_ERROR_CATEGORY_PRIORITY = {
    SERVER_BLOCKED_CLIENT_CANDIDATE: 0,
    RATE_LIMITED: 20,
    RESTRICTED: 30,
    DNS_FAILURE: 40,
    NON_PUBLIC_TARGET: 45,
    CONNECT_TIMEOUT: 50,
    READ_TIMEOUT: 60,
    UNKNOWN_EXCEPTION: 70,
    STALE_ROUTE: 80,
    EMPTY_MEDIA: 90,
    MALFORMED_MANIFEST: 100,
    PARSER_MISMATCH: 110,
}

# Direct sites that passed search/detail/manifest/key/segment checks from the
# production VPS.  The bonus keeps these direct candidates ahead of
# lower-confidence bulk collection sites when the per-title result cap applies.
DIRECT_SOURCE_PRIORITIES = {"nivod": 16, "ppnix": 14, "dbku": 12}

# 发现路径的 per-provider 超时与别名预算(独立于排名加成)。
# anich 每次搜索必须保持 ≥1.2s 礼貌间隔且串行排队,
# 缺省的 crawler 档位(2s/3别名)必然把它误判成 SEARCH_TIMEOUT。
# 稀饭公开搜索要求间隔至少 3 秒；允许别名回退礼貌排队，不把等待当作失效。
# HTML/index results may need one bounded parallel metadata-detail round (2s).
# Keep it inside the provider budget rather than cancelling all search hits at 2s.
_PROVIDER_SEARCH_TIMEOUTS: dict[str, float] = {
    "anich": 8.0, "xifan": 16.0, "xgcartoon": 6.0, "girigiri": 6.0,
    "yhdmm": 10.0, "jibi": 6.0, "yinghua2": 6.0, "wedm": 6.0,
    "animeko": 30.0, "kazumi": 18.0,
}
#: 该源对短标题命中良好,对带季号的长关键词几乎全是噪声,所以要多给一个
#  别名的余量(别名序里基础标题通常排在带季号的之后)。
_PROVIDER_SEARCH_ALIAS_BUDGET: dict[str, int] = {"anich": 2}


def _prepare_discovery_aliases(values: list[str]) -> list[str]:
    """Deduplicate aliases and put precise season titles before broad names."""

    unique: list[str] = []
    seen: set[str] = set()
    for raw_value in values:
        value = (raw_value or "").strip()
        # Alias identity must retain season markers. The looser title matcher
        # intentionally removes some edition suffixes, but using it here would
        # collapse "Title" and "Title 第2季" before the search budget sees the
        # precise seasonal query.
        key = "".join(char for char in value.casefold() if char.isalnum())
        if value and key and key not in seen:
            seen.add(key)
            unique.append(value)

    def priority(pair: tuple[int, str]) -> tuple[int, int, int]:
        index, value = pair
        season_specific = bool(re.search(
            r"(?:"
            r"第\s*[一二三四五六七八九十百两\d]+\s*季"
            r"|\bseason\s*0*\d+\b"
            r"|\bs\s*0*\d+\b"
            r")",
            value,
            flags=re.IGNORECASE,
        ))
        script_tier = (
            0
            if any("\u3400" <= char <= "\u9fff" for char in value)
            else 1
            if any(char.isascii() and char.isalnum() for char in value)
            else 2
        )
        return (0 if season_specific else 1, script_tier, index)

    return [
        value
        for _index, value in sorted(enumerate(unique), key=priority)
    ]


def _is_client_probe_candidate_url(url: str, declared_format: str = "") -> bool:
    """Allow only HTTP(S) candidates that cannot directly name local hosts.

    DNS is deliberately re-checked by the client's public-only HTTP stack.
    This keeps Clash/TUN fake-IP environments usable without allowing a source
    adapter to hand the player a literal loopback or private address.
    """
    if classify_media_url(url, declared_format) != DIRECT_MEDIA_URL:
        return False
    return _is_inventory_candidate_url(url, declared_format)


def _is_inventory_candidate_url(url: str, declared_format: str = "") -> bool:
    """Allow display of failed HTTP media routes, never authorize playback.

    Opaque paths may be listed, but browser pages and literal private targets
    remain excluded. Resolver DNS safety failures are also excluded separately.
    """
    if classify_media_url(url, declared_format) in {
        INVALID_MEDIA_URL, PLAYER_PAGE_URL,
    }:
        return False
    try:
        parsed = urlparse(url)
        parsed.port
    except ValueError:
        return False
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        return False
    host = parsed.hostname.strip().lower()
    if host == "localhost" or host.endswith((".localhost", ".local")):
        return False
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return True
    return _is_public_ip(host)


def _client_resolver_descriptor(value: object) -> dict:
    """Validate the bounded page-execution contract, not a playable media URL."""
    if not isinstance(value, dict) or value.get("kind") != "kazumi_page_v1":
        return {}

    def public_url(raw: object) -> str:
        if not isinstance(raw, str) or not raw or len(raw) > 8192:
            return ""
        if any(ord(char) < 32 or ord(char) == 127 for char in raw) or "\\" in raw:
            return ""
        try:
            parsed = urlparse(raw)
            parsed.port
        except ValueError:
            return ""
        host = (parsed.hostname or "").lower().rstrip(".")
        if (
            parsed.scheme not in {"http", "https"}
            or not host
            or parsed.username is not None
            or parsed.password is not None
            or parsed.fragment
            or host == "localhost"
            or host.endswith((".localhost", ".local"))
        ):
            return ""
        try:
            ipaddress.ip_address(host)
        except ValueError:
            return raw
        return raw if _is_public_ip(host) else ""

    def public_hosts(raw: object) -> list[str]:
        if not isinstance(raw, list) or not 1 <= len(raw) <= 32:
            return []
        hosts: list[str] = []
        for item in raw:
            if not isinstance(item, str) or len(item) > 253:
                return []
            host = item.strip().lower().rstrip(".")
            if (
                not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z0-9-]+", host)
                or ".." in host
                or not public_url(f"https://{host}/")
            ):
                return []
            if host not in hosts:
                hosts.append(host)
        return hosts

    page_url = public_url(value.get("page_url"))
    referer = public_url(value.get("referer") or page_url)
    page_hosts = public_hosts(value.get("page_hosts"))
    media_hosts = public_hosts(value.get("media_hosts"))
    if (
        not page_url or not referer or not page_hosts or not media_hosts
        or _source_site_name(page_url) not in page_hosts
        or _source_site_name(referer) not in page_hosts
    ):
        return {}
    labels: dict[str, str] = {}
    for name, limit in (("rule_id", 128), ("rule_name", 256), ("user_agent", 512)):
        raw = value.get(name, "")
        if not isinstance(raw, str) or len(raw) > limit or any(
            ord(char) < 32 or ord(char) == 127 for char in raw
        ):
            return {}
        labels[name] = raw
    if not labels["rule_id"]:
        return {}
    return {
        "kind": "kazumi_page_v1", "page_url": page_url, "referer": referer,
        **labels, "page_hosts": page_hosts, "media_hosts": media_hosts,
    }


@dataclass
class AggregatedSubject:
    """聚合后的条目"""
    id: str                    # 前端展示用 ID
    title: str
    original_title: str = ""
    cover_url: str = ""
    banner_url: str = ""
    summary: str = ""
    content_type: str = "unknown"
    language: str = ""
    year: int = 0
    regions: list[str] = field(default_factory=list)
    genres: list[str] = field(default_factory=list)
    rating: float = 0.0
    rating_count: int = 0
    total_episodes: int = 0
    status: str = ""
    sources: list[str] = field(default_factory=list)
    # 内部使用：保存原始 source_id 以便后续获取视频
    _source_refs: dict = field(default_factory=dict)


@dataclass
class AggregatedEpisode:
    """聚合后的剧集"""
    number: int
    title: str = ""
    thumbnail: str = ""
    duration: str = ""


@dataclass
class AggregatedVideoLine:
    """聚合后的视频线路"""
    url: str
    title: str = ""
    quality: str = ""
    format: str = ""           # hls, mp4
    source: str = ""           # 来源标识
    headers: dict = field(default_factory=dict)
    verification_status: str = "unverified"
    startup_profile: str = STARTUP_UNKNOWN
    startup_latency_ms: int = 0
    client_resolver: dict = field(default_factory=dict)
    provider_id: str = ""
    site_name: str = ""
    rule_id: str = ""
    rule_name: str = ""
    size_bytes: int | None = None
    size_estimated: bool = False
    video_width: int | None = None
    video_height: int | None = None
    bitrate: int | None = None
    codecs: str = ""
    is_live: bool = False
    adaptive: bool = False


def _non_negative_metadata_int(value: object) -> int | None:
    """Keep integral JSON values portable to Dart/web without lossy coercion."""
    if isinstance(value, bool):
        return None
    if isinstance(value, str):
        if not re.fullmatch(r"[0-9]+", value.strip()):
            return None
        try:
            value = int(value.strip())
        except ValueError:
            return None
    if isinstance(value, float):
        if not value.is_integer():
            return None
        value = int(value)
    return value if isinstance(value, int) and 0 <= value <= 2**53 - 1 else None


def _line_metadata(value: object) -> dict:
    size = _non_negative_metadata_int(getattr(value, "size_bytes", None))
    codecs = getattr(value, "codecs", "")
    if not isinstance(codecs, str) or len(codecs) > 512 or any(
        ord(char) < 32 or ord(char) == 127 for char in codecs
    ):
        codecs = ""
    return {
        "size_bytes": size,
        "size_estimated": size is not None and getattr(value, "size_estimated", False) is True,
        "video_width": _non_negative_metadata_int(getattr(value, "video_width", None)),
        "video_height": _non_negative_metadata_int(getattr(value, "video_height", None)),
        "bitrate": _non_negative_metadata_int(getattr(value, "bitrate", None)),
        "codecs": codecs.strip(),
        "is_live": getattr(value, "is_live", False) is True,
        "adaptive": getattr(value, "adaptive", False) is True,
    }


def _source_site_name(value: object) -> str:
    """Extract a site host, never retain a subject URL as a public label."""
    if not isinstance(value, str) or not value.strip():
        return ""
    text = value.strip()
    try:
        parsed = urlparse(text if "://" in text else f"//{text}")
        if parsed.username is not None or parsed.password is not None:
            return ""
        return (parsed.hostname or "").lower().rstrip(".")
    except ValueError:
        return ""


@dataclass
class SourceMatch:
    source_id: str
    source_name: str
    title: str
    content_type: str
    year: int
    episode_count: int = 0
    score: int = 0
    evidence: SourceMatchEvidence = field(default_factory=SourceMatchEvidence)
    provider_id: str = ""
    site_name: str = ""
    rule_id: str = ""
    rule_name: str = ""

    def __post_init__(self) -> None:
        # Old bindings contain only source_id/source_name. Recover rule identity
        # from the adapters' existing IDs without a schema/data migration.
        parts = self.source_id.split(":", 2)
        if len(parts) == 3 and parts[0] == "crawler":
            provider, inner_id = parts[1:]
            self.provider_id = self.provider_id or f"crawler.{provider}"
            if provider == "animeko":
                decoded = AnimekoScraper.decode_source_id(inner_id)
                if decoded is not None:
                    rule_id, subject_url = decoded
                    self.rule_id = self.rule_id or rule_id
                    self.site_name = self.site_name or _source_site_name(subject_url)
            elif provider == "kazumi":
                rule_id, separator, inner = inner_id.partition("::")
                if separator and rule_id.strip() and inner.strip():
                    self.rule_id = self.rule_id or rule_id.strip()
            # A persisted rule key is not a new provider/inventory entry.
            if self.source_name.startswith(f"{provider}:rule:"):
                self.source_name = provider
        elif parts[0] in {"maccms", "tvbox"}:
            self.provider_id = self.provider_id or f"aggregate.{parts[0]}"
        else:
            self.provider_id = self.provider_id or parts[0]
        self.site_name = self.site_name or self.rule_id or self.source_name
        self.rule_name = self.rule_name or self.rule_id

    @property
    def group_key(self) -> tuple[str, str]:
        """One work per rule, even when independent rules share an origin host."""
        return self.provider_id, self.rule_id or self.site_name

    @property
    def binding_key(self) -> str:
        """Persist rule-isolated bindings within the existing 100-char column."""
        if not self.rule_id:
            return self.source_name
        prefix = f"{self.source_name}:rule:"
        rule_key = self.rule_id
        if len(prefix) + len(rule_key) > 100:
            rule_key = f"v1:{stable_digest(rule_key)[:32]}"
        return f"{prefix}{rule_key}"


def _video_line_identity(line: AggregatedVideoLine) -> str:
    # A shared CDN URL/host is not a route identity: independent channel/rule
    # choices (and different Referer/Cookie headers) must survive full inventory.
    descriptor = line.client_resolver
    canonical = json.dumps(
        {
            "provider_id": line.provider_id,
            "rule_id": line.rule_id or descriptor.get("rule_id", ""),
            "source": line.source,
            "url": line.url,
            "page_url": descriptor.get("page_url", ""),
            "headers": line.headers,
        },
        sort_keys=True, ensure_ascii=True, separators=(",", ":"),
    )
    return f"route:{stable_digest(canonical)}"


@dataclass(frozen=True)
class LineVerificationResult:
    status: str
    error_category: str = ""
    latency_ms: int = 0
    startup_profile: str = STARTUP_UNKNOWN
    size_bytes: int | None = None
    size_estimated: bool = False
    video_width: int | None = None
    video_height: int | None = None
    bitrate: int | None = None
    codecs: str = ""
    is_live: bool = False
    adaptive: bool = False


def _crawler_line_source(site: str, line_source_name: str) -> str:
    """独立站线路的来源标识。

    适配器返回的 ``source_name`` 若已是具体线路标识(聚合类源单集会给出数十
    条,各自带上游线路号),就用它——否则数十条线路会共用一个身份,客户端按
    ``provider|来源名`` 折叠卡片时只剩一条。

    标识里不包含上游服务名:那是实现细节,不该出现在用户可见的线路名上。
    """
    tag = (line_source_name or "").strip()
    if not tag or tag == site:
        return f"crawler:{site}"
    # 适配器可能把站名当前缀(site:tag),只取后面的线路标识部分
    if tag.startswith(f"{site}:"):
        tag = tag[len(site) + 1:].strip() or site
    if tag == site:
        return f"crawler:{site}"
    return f"crawler:{site}:{tag}"


def _declared_startup_profile(line: AggregatedVideoLine) -> str:
    if line.startup_profile != STARTUP_UNKNOWN:
        return line.startup_profile
    normalized_format = (line.format or "").strip().lower()
    try:
        path = urlparse(line.url).path.lower()
    except ValueError:
        path = ""
    if normalized_format == "hls" or path.endswith(".m3u8"):
        return STARTUP_HLS
    return STARTUP_UNKNOWN


def _mp4_startup_profile(sample: bytes) -> str:
    offset = 0
    saw_moov = False
    saw_mdat = False
    while offset + 8 <= len(sample):
        size = int.from_bytes(sample[offset:offset + 4], "big")
        box_type = sample[offset + 4:offset + 8]
        header_size = 8
        if size == 1:
            if offset + 16 > len(sample):
                break
            size = int.from_bytes(sample[offset + 8:offset + 16], "big")
            header_size = 16
        # styp/moof identifies fragmented ISO-BMFF. It does not prove that a
        # classic MP4 stores its moov box at the tail.
        if box_type in {b"styp", b"moof"}:
            return STARTUP_UNKNOWN
        if box_type == b"moov":
            if saw_mdat:
                return STARTUP_MP4_TAIL_MOOV
            saw_moov = True
        if box_type == b"mdat":
            if saw_moov:
                return STARTUP_MP4_FASTSTART
            saw_mdat = True
        if size == 0 or size < header_size:
            break
        next_offset = offset + size
        if next_offset <= offset or next_offset > len(sample):
            break
        offset = next_offset
    return STARTUP_UNKNOWN


def _sample_startup_profile(
    line: AggregatedVideoLine,
    response_url: str,
    content_type: str,
    body: bytes,
) -> str:
    normalized_format = (line.format or "").strip().lower()
    try:
        path = urlparse(response_url).path.lower()
    except ValueError:
        path = ""
    looks_like_mp4 = (
        normalized_format in {"mp4", "m4v", "mov"}
        or path.endswith((".mp4", ".m4v", ".mov"))
        or "video/mp4" in content_type
        or "video/quicktime" in content_type
        or (len(body) >= 8 and body[4:8] in {b"ftyp", b"styp", b"moof"})
    )
    return _mp4_startup_profile(body) if looks_like_mp4 else STARTUP_UNKNOWN


@dataclass(frozen=True)
class SourceResolutionOutcome:
    """Tuple-compatible source result with health diagnostics attached."""

    match: SourceMatch
    lines: list[AggregatedVideoLine]
    status: str
    error_category: str = ""
    latency_ms: int = 0
    failure_scope: SourceFailureScope = SourceFailureScope.PROVIDER

    def __iter__(self) -> Iterator[object]:
        # Existing callers intentionally keep the historical three-value
        # unpacking contract while newer callers can read the extra fields.
        yield self.match
        yield self.lines
        yield self.status


def _classify_resolution_exception(
    error: BaseException, _seen: set[int] | None = None,
) -> str:
    seen = _seen if _seen is not None else set()
    if id(error) in seen:
        return UNKNOWN_EXCEPTION
    seen.add(id(error))
    if isinstance(error, AniChUpstreamError):
        # Only structured transport errors get reason-based classification.
        # An arbitrary RuntimeError(message='dns_failure') is still unknown.
        known_reasons = {
            "dns_failure": DNS_FAILURE, "connect_timeout": CONNECT_TIMEOUT,
            "read_timeout": READ_TIMEOUT, "rate_limited": RATE_LIMITED,
            "restricted": RESTRICTED, "stale_route": STALE_ROUTE,
            "empty_response": EMPTY_MEDIA, "parser_mismatch": PARSER_MISMATCH,
        }
        reasons = (
            (error.cause_reason, error.reason)
            if error.reason == "upstream_cooldown"
            else (error.reason, error.cause_reason)
        )
        for reason in reasons:
            if reason in known_reasons:
                return known_reasons[reason]
        cause = error.__cause__ or error.__context__
        if cause is not None:
            category = _classify_resolution_exception(cause, seen)
            if category != UNKNOWN_EXCEPTION:
                return category
        if error.status == 429:
            return RATE_LIMITED
        if error.status in {401, 403, 451}:
            return RESTRICTED
        if error.status in {404, 410}:
            return STALE_ROUTE
        if "connect_error" in reasons:
            return CONNECT_TIMEOUT
        return UNKNOWN_EXCEPTION
    if isinstance(error, OriginSearchThrottledError):
        return RATE_LIMITED
    if isinstance(error, socket.gaierror):
        return DNS_FAILURE
    if isinstance(error, httpx.ConnectTimeout):
        return CONNECT_TIMEOUT
    if isinstance(error, (httpx.ReadTimeout, httpx.WriteTimeout)):
        return READ_TIMEOUT
    if isinstance(error, (asyncio.TimeoutError, httpx.PoolTimeout)):
        return READ_TIMEOUT
    if isinstance(error, httpx.HTTPStatusError):
        status = error.response.status_code
        if status == 429:
            return RATE_LIMITED
        if status in {401, 403, 451}:
            return RESTRICTED
        if status in {404, 410}:
            return STALE_ROUTE
    if isinstance(error, httpx.ConnectError):
        cause = error.__cause__ or error.__context__
        if cause is not None:
            category = _classify_resolution_exception(cause, seen)
            if category != UNKNOWN_EXCEPTION:
                return category
        message = str(error).casefold()
        if any(
            marker in message
            for marker in ("getaddrinfo", "name or service", "nodename", "dns")
        ):
            return DNS_FAILURE
        return CONNECT_TIMEOUT
    if isinstance(error, (json.JSONDecodeError, KeyError, IndexError, ValueError)):
        return PARSER_MISMATCH
    return UNKNOWN_EXCEPTION


def _strongest_error_category(categories: list[str], fallback: str) -> str:
    values = [value for value in categories if value]
    if not values:
        return fallback
    return max(values, key=lambda value: _ERROR_CATEGORY_PRIORITY.get(value, 0))


def _response_media_size(status: int, headers: httpx.Headers) -> int | None:
    """Whole resource bytes, never a 206 sample length or manifest length."""
    if headers.get("content-encoding", "identity").lower() not in {"", "identity"}:
        return None
    if status == 206:
        match = re.fullmatch(r"bytes\s+(\d+)-(\d+)/(\d+)", headers.get("content-range", "").strip(), re.I)
        if match is None:
            return None
        start, end, total = (int(value) for value in match.groups())
        return _non_negative_metadata_int(total) if 0 <= start <= end < total else None
    if status == 200 and headers.get("content-encoding", "identity").lower() in {"", "identity"}:
        return _non_negative_metadata_int(headers.get("content-length"))
    return None


def _hls_sample_metadata(manifest: str, *, complete: bool) -> dict:
    """Read only explicit playlist facts; no URL/quality-label resolution guesses."""
    lines = [line.strip() for line in manifest.splitlines() if line.strip()]
    result: dict = {}
    for index, line in enumerate(lines):
        if not line.startswith("#EXT-X-STREAM-INF:"):
            continue
        # Verification follows the first variant. Its metadata must describe
        # that same variant, not an untested highest-quality sibling.
        if not any(not item.startswith("#") for item in lines[index + 1:]):
            continue
        attributes = {
            key.upper(): quoted or bare
            for key, quoted, bare in re.findall(r'([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))', line.split(":", 1)[1], re.I)
        }
        dimensions = re.fullmatch(r"(\d+)x(\d+)", attributes.get("RESOLUTION", ""), re.I)
        if dimensions:
            result.update(video_width=_non_negative_metadata_int(dimensions[1]),
                          video_height=_non_negative_metadata_int(dimensions[2]))
        result.update(
            bitrate=_non_negative_metadata_int(attributes.get("AVERAGE-BANDWIDTH") or attributes.get("BANDWIDTH")),
            codecs=attributes.get("CODECS", ""), adaptive=True,
        )
        return result
    has_end = "#EXT-X-ENDLIST" in lines
    if complete:
        result["is_live"] = not has_end
    # Byte-range sums describe declared segment payload, not an exact complete
    # download: initialization maps, repeated ranges and packaging may differ.
    # Ordinary segment sizes/durations cannot justify a whole-file size.
    if complete and has_end:
        sizes: list[int | None] = []
        pending: int | None = None
        for line in lines:
            if line.startswith("#EXT-X-BYTERANGE:"):
                pending = _non_negative_metadata_int(line.split(":", 1)[1].split("@", 1)[0])
            elif not line.startswith("#"):
                sizes.append(pending)
                pending = None
        if sizes and all(size is not None and size > 0 for size in sizes):
            total = _non_negative_metadata_int(sum(sizes))
            if total is not None:
                result.update(size_bytes=total, size_estimated=True)
    return result


class ContentAggregator:
    """
    内容聚合器

    统一搜索入口，自动从多个源聚合结果:
      - anime:  独立动漫站适配器 + MacCMS + TVBox
      - series: TVMaze + TVBox + M3U8解析
      - movie:  TMDB + TVBox + M3U8解析
    """

    def __init__(
        self,
        *,
        line_http_transport: httpx.AsyncBaseTransport | None = None,
        crawler_scrapers: dict[str, MediaProvider] | None = None,
        enabled_provider_ids: frozenset[str] | None = None,
        resolver_search_enabled: bool = True,
    ):
        self._maccms = MacCmsScraper()
        self._tvbox = TvBoxAdapterScraper()
        self._vod = CommonVodScraper()
        self._crawler_scrapers = (
            {
                "age": AgeScraper(),
                "girigiri": GiriGiriScraper(),
                "anich": AniChScraper(),
                "xgcartoon": XgCartoonScraper(),
                # 2026-08-28 真机实测 4/4 hls-media 206;站内搜索被缓存冻结,
                # 依赖本地标题索引(见 scrapers/anime/anime_sites.py)
                "yhdmm": YhdmmScraper(),
                **create_html_direct_anime_scrapers(),
                "nivod": NivodScraper(),
                "ppnix": PpnixScraper(),
                # animeko-subs 规则库(21 个站点共用一个 provider)。默认关闭:
                # 规则库要联网拉,打开方式见 config.ANIMEKO_ENABLED。
                "animeko": AnimekoScraper(),
                # Kazumi 规则库(18 条活跃规则共用一个 provider;规则快照随
                # 仓库走,不再额外联网拉规则)。默认关闭:一个 provider 背后
                # 是十几个外部站点,打开方式见 config.KAZUMI_ENABLED。
                "kazumi": KazumiScraper(),
            }
            if crawler_scrapers is None
            else dict(crawler_scrapers)
        )
        available_provider_ids = {
            "aggregate.maccms",
            "aggregate.tvbox",
            "aggregate.vod",
            *(f"crawler.{name}" for name in self._crawler_scrapers),
        }
        requested_provider_ids = (
            available_provider_ids
            if enabled_provider_ids is None
            else {
                item.strip().lower()
                for item in enabled_provider_ids
                if item.strip()
            }
        )
        unknown_provider_ids = requested_provider_ids - available_provider_ids
        if unknown_provider_ids:
            unknown = ", ".join(sorted(unknown_provider_ids))
            raise ValueError(f"Unknown playback provider ids: {unknown}")
        self._enabled_provider_ids = frozenset(requested_provider_ids)
        self._resolver_search_enabled = resolver_search_enabled
        self._line_http_transport = line_http_transport
        self._providers = ProviderRegistry()
        self._providers.register(
            provider_id="aggregate.maccms",
            family="aggregate",
            display_name="MacCMS",
            adapter=self._maccms,
            enabled=self._provider_enabled("aggregate.maccms"),
        )
        self._providers.register(
            provider_id="aggregate.tvbox",
            family="aggregate",
            display_name="TVBox",
            adapter=self._tvbox,
            enabled=self._provider_enabled("aggregate.tvbox"),
        )
        self._providers.register(
            provider_id="aggregate.vod",
            family="aggregate",
            display_name="VOD compatibility",
            adapter=self._vod,
            enabled=self._provider_enabled("aggregate.vod"),
        )
        for provider_id, adapter in self._crawler_scrapers.items():
            self._providers.register(
                provider_id=f"crawler.{provider_id}",
                family="crawler",
                display_name=provider_id,
                adapter=adapter,
                capabilities=("search", "detail") if provider_id == "kazumi"
                else ("search", "detail", "resolve", "latest"),
                enabled=self._provider_enabled(f"crawler.{provider_id}"),
            )

    def _provider_enabled(self, provider_id: str) -> bool:
        return provider_id in self._enabled_provider_ids

    @property
    def _active_crawler_scrapers(self) -> dict[str, MediaProvider]:
        return {
            name: scraper
            for name, scraper in self._crawler_scrapers.items()
            if self._provider_enabled(f"crawler.{name}")
        }

    @property
    def active_crawler_scrapers(self) -> dict[str, MediaProvider]:
        """已启用的独立站适配器。供后台任务(如索引重建)使用。"""
        return self._active_crawler_scrapers

    @property
    def source_inventory(self) -> tuple[tuple[str, str], ...]:
        """Return independently queried sources as ``(provider, name)`` pairs."""
        inventory: list[tuple[str, str]] = []
        if self._provider_enabled("aggregate.maccms"):
            inventory.extend(
                ("maccms", source.name)
                for source in self._maccms.discovery_sources
            )
        inventory.extend(
            ("crawler", name) for name in self._active_crawler_scrapers
        )
        return tuple(inventory)

    @property
    def configured_source_names(self) -> frozenset[str]:
        return frozenset(name for _, name in self.source_inventory)

    @property
    def provider_metadata(self) -> tuple[ProviderMetadata, ...]:
        """Return contract metadata without endpoint or request internals."""
        return self._providers.metadata

    async def aclose(self) -> None:
        await self._providers.aclose()

    async def _discover_scraper_matches(
        self,
        provider: str,
        scraper: MediaProvider,
        aliases: list[str],
        *,
        content_type: str,
        year: int,
        diagnostics: dict[str, SourceDiscoveryDiagnostic] | None = None,
        partial_matches: dict[str, SourceMatch] | None = None,
        on_matches: Callable[[list[SourceMatch]], None] | None = None,
    ) -> list[SourceMatch]:
        expected_type = "series" if content_type == "tv" else content_type
        if (
            expected_type in {"anime", "series", "movie"}
            and expected_type not in scraper.content_types
        ):
            # Deliberately inapplicable is terminal, not an incomplete scan.
            # Otherwise movie-only providers prevent every anime full cache.
            diagnostic = diagnostics.get(provider) if diagnostics is not None else None
            if diagnostic is not None:
                diagnostic.status = SourceDiscoveryStatus.UNSUPPORTED_CONTENT_TYPE
            return []
        if provider == "maccms":
            raise ValueError(
                "MacCMS discovery must use the bounded progressive strategy"
            )

        started_at = time.monotonic()
        search_aliases = aliases
        if provider == "anich":
            # Catalog aliases prioritize Chinese for MacCMS. AniCh indexes
            # original titles too: do not spend its two-query serial budget
            # on two localized spellings before reaching the original title.
            # Keep identity scoring against ALL aliases unchanged.
            original = next((alias for alias in aliases
                             if re.search(r"[A-Za-z\u3040-\u30ff]", alias)
                             and not re.search(r"[\u3400-\u9fff]", alias)), None)
            if original is not None:
                search_aliases = [original, *(a for a in aliases if a != original)]
        attempted_aliases = search_aliases[
            : _PROVIDER_SEARCH_ALIAS_BUDGET.get(provider, 3)
        ]
        failures: list[BaseException] = []
        successful_searches = 0
        search_hit_count = 0
        # Keep completed aliases/rules outside a wait_for-cancelled collector.
        matches = partial_matches if partial_matches is not None else {}
        content_details: dict[str, SubjectResult | None] = {}
        aliases_queried = 0
        cancelled = False
        diagnostic = diagnostics.get(provider) if diagnostics is not None else None

        async def accept(results: list[SubjectResult]) -> None:
            nonlocal search_hit_count
            search_hit_count += len(results)
            # Score raw results first: a cancelled metadata refinement must not
            # discard already valid identities from completed rule searches.
            raw_scored = self._score_scraper_results(
                provider, results, aliases, content_type=content_type, year=year,
            )
            before_refinement = {
                candidate.source_id: matches.get(candidate.source_id)
                for candidate in raw_scored
            }
            for candidate in raw_scored:
                previous = matches.get(candidate.source_id)
                if previous is None or candidate.score > previous.score:
                    matches[candidate.source_id] = candidate
            results = await self._refine_content_results(
                scraper, results, aliases, content_type=content_type, year=year,
                cache=content_details,
            )
            scored = self._score_scraper_results(
                provider, results, aliases, content_type=content_type, year=year,
            )
            # The completed detail is authoritative even when it lowers a
            # provisional raw score; raw scores are retained only on timeout.
            for candidate in raw_scored:
                previous = before_refinement[candidate.source_id]
                if previous is None:
                    matches.pop(candidate.source_id, None)
                else:
                    matches[candidate.source_id] = previous
            for candidate in scored:
                previous = matches.get(candidate.source_id)
                if previous is None or candidate.score > previous.score:
                    matches[candidate.source_id] = candidate
            if on_matches is not None:
                on_matches(self.select_source_matches(scored))

        try:
            for alias in attempted_aliases:
                aliases_queried += 1
                if diagnostic is not None:
                    diagnostic.queried = True
                    diagnostic.aliases_attempted = aliases_queried
                    diagnostic.status = SourceDiscoveryStatus.SEARCHING
                try:
                    # Optional rule-batch API. Ordinary crawlers retain exactly
                    # their historical search contract and alias budgets.
                    if callable(getattr(type(scraper), "search_progressively", None)):
                        async for results in scraper.search_progressively(alias):
                            await accept(results)
                    else:
                        await accept(await scraper.search(alias))
                    successful_searches += 1
                    if provider in {"anich", "xifan"} and any(
                        match.evidence.exact_title or match.evidence.safe_title_variant
                        for match in matches.values()
                    ):
                        break
                except Exception as error:
                    failures.append(error)
                    logger.debug(
                        "Source discovery failed [%s]: %s", provider,
                        type(error).__name__,
                    )
        except asyncio.CancelledError:
            cancelled = True
            raise
        finally:
            if diagnostic is not None:
                diagnostic.queried = bool(aliases_queried)
                diagnostic.aliases_attempted = aliases_queried
                diagnostic.search_hit_count = search_hit_count
                diagnostic.best_match_score = max(
                    (match.score for match in matches.values()), default=None,
                )
                diagnostic.matched = bool(matches)
                diagnostic.elapsed_ms = max(
                    0, int((time.monotonic() - started_at) * 1000),
                )
                if matches:
                    diagnostic.status = SourceDiscoveryStatus.MATCHED
                    diagnostic.error_category = ""
                elif cancelled or any(
                    isinstance(error, (asyncio.TimeoutError, TimeoutError))
                    for error in failures
                ):
                    diagnostic.status = SourceDiscoveryStatus.SEARCH_TIMEOUT
                    diagnostic.error_category = READ_TIMEOUT
                elif search_hit_count:
                    diagnostic.status = SourceDiscoveryStatus.SEARCH_HIT_NO_MATCH
                elif successful_searches:
                    diagnostic.status = SourceDiscoveryStatus.SEARCH_MISS
                elif failures:
                    diagnostic.status = SourceDiscoveryStatus.SEARCH_ERROR
                    diagnostic.error_category = _classify_resolution_exception(failures[0])
        return list(matches.values())

    def _new_discovery_diagnostics(self) -> dict[str, SourceDiscoveryDiagnostic]:
        result: dict[str, SourceDiscoveryDiagnostic] = {}
        for provider, name in self.source_inventory:
            provider_id = (
                "aggregate.maccms"
                if provider == "maccms"
                else f"crawler.{name}"
            )
            result[name] = SourceDiscoveryDiagnostic(
                source_name=name,
                provider_id=provider_id,
            )
        return result

    @staticmethod
    async def _refine_content_results(
        scraper: MediaProvider,
        results: list[SubjectResult],
        aliases: list[str],
        *,
        content_type: str,
        year: int,
        cache: dict[str, SubjectResult | None],
    ) -> list[SubjectResult]:
        """Resolve sparse suggest/index identities without crawling every search hit."""
        ranked: dict[str, tuple[int, SubjectResult]] = {}
        for result in results:
            if result.source_id in cache or not needs_content_detail(
                result, content_type, expected_year=year
            ):
                continue
            analysis = analyze_source_match(
                result.title, aliases, candidate_type="unknown", expected_type=content_type,
                candidate_year=result.year, expected_year=year,
            )
            if analysis.playback_eligible:
                ranked[result.source_id] = (analysis.ranking_score, result)
        candidates = sorted(ranked.values(), key=lambda item: item[0], reverse=True)
        selected = [result for _, result in candidates[:max(0, 3 - len(cache))]]

        async def refine(result: SubjectResult) -> None:
            cache[result.source_id] = None
            try:
                detail = await asyncio.wait_for(scraper.get_detail(result.source_id), timeout=2)
            except Exception as error:
                logger.debug("Content identity detail unavailable: %s", type(error).__name__)
                return
            if detail is None or not detail.title:
                return
            title_check = analyze_source_match(
                detail.title, [result.title, *aliases], candidate_type="unknown",
                expected_type=content_type, candidate_year=0, expected_year=0,
            )
            if not title_check.evidence.allows_circuit_recovery:
                return
            identity = detail.extra.get("content_identity")
            explicit_detail = isinstance(identity, dict) and identity.get("evidence") != "default"
            # A sparse detail page must not overwrite an explicit search-card category.
            cache[result.source_id] = replace(
                result,
                title=detail.title,
                type=detail.type if explicit_detail else result.type,
                year=detail.year or result.year,
                episode_count=len(detail.episodes) or result.episode_count,
                extra={**result.extra, **({"content_identity": identity} if explicit_detail else {})},
            )

        await asyncio.gather(*(refine(result) for result in selected))
        return [cache.get(result.source_id) or result for result in results]

    @staticmethod
    def _rule_identity(provider: str, result: SubjectResult) -> dict[str, str]:
        """Shared extra contract for multi-rule adapters; legacy extras still work."""
        identity = result.extra.get("source_identity")
        if not isinstance(identity, dict):
            identity = {}
        rule_id = str(identity.get("rule_id") or "").strip()
        rule_name = str(identity.get("rule_name") or "").strip()
        site_name = _source_site_name(identity.get("site_name"))
        if provider == "animeko":
            rule_id = rule_id or str(result.extra.get("animeko_source") or "")
            rule_name = rule_name or str(result.extra.get("animeko_source_name") or "")
        elif provider == "kazumi":
            rule_id = rule_id or str(result.extra.get("kazumi_rule") or "")
            site_name = site_name or _source_site_name(result.extra.get("detail_url"))
        if not rule_id:
            return {}
        return {"rule_id": rule_id, "rule_name": rule_name, "site_name": site_name}

    @staticmethod
    def select_source_matches(
        matches: list[SourceMatch], *, max_matches: int | None = None,
    ) -> list[SourceMatch]:
        """Deduplicate by site identity, then sample fairly across providers."""
        by_rule: dict[tuple[str, str], SourceMatch] = {}
        for match in matches:
            key = (match.provider_id, match.rule_id or match.site_name)
            previous = by_rule.get(key)
            if previous is None or match.score > previous.score:
                by_rule[key] = match
        by_site: dict[tuple[str, str], SourceMatch] = {}
        for match in by_rule.values():
            previous = by_site.get(match.group_key)
            if previous is None or match.score > previous.score:
                by_site[match.group_key] = match
        ranked = sorted(by_site.values(), key=lambda item: item.score, reverse=True)
        if max_matches is None:
            return ranked
        limit = max(0, max_matches)
        if len(ranked) <= limit:
            return ranked
        buckets: dict[str, list[SourceMatch]] = {}
        for match in ranked:
            buckets.setdefault(match.provider_id, []).append(match)
        selected: list[SourceMatch] = []
        depth = 0
        while len(selected) < limit:
            wave = [group[depth] for group in buckets.values() if len(group) > depth]
            if not wave:
                break
            for match in wave:
                selected.append(match)
                if len(selected) >= limit:
                    break
            depth += 1
        # The cap is fair; keep historical score ordering for downstream callers.
        return sorted(selected, key=lambda item: item.score, reverse=True)

    @staticmethod
    def _score_scraper_results(
        provider: str,
        results: list[SubjectResult],
        aliases: list[str],
        *,
        content_type: str,
        year: int,
    ) -> list[SourceMatch]:
        matches: dict[str, SourceMatch] = {}
        for result in results:
            if not content_matches_request(result, content_type):
                continue
            analysis = analyze_source_match(
                result.title,
                aliases,
                candidate_type=result.type,
                expected_type=content_type,
                candidate_year=result.year,
                expected_year=year,
            )
            if provider == "anich" and not analysis.evidence.has_explicit_identity_conflict:
                # Detail aliases are identity evidence, not fuzzy ranking hints.
                # The card title still vetoes explicit season/derivative conflicts.
                for title in result.extra.get("aliases", []):
                    alias_analysis = analyze_source_match(
                        title, aliases, candidate_type=result.type,
                        expected_type=content_type, candidate_year=result.year,
                        expected_year=year,
                    )
                    if (
                        alias_analysis.playback_eligible
                        and (alias_analysis.evidence.exact_title
                             or alias_analysis.evidence.safe_title_variant)
                        and alias_analysis.ranking_score > analysis.ranking_score
                    ):
                        analysis = alias_analysis
            if not analysis.playback_eligible:
                continue
            parts = result.source_id.split(":", 2)
            if provider in {"maccms", "tvbox"} and len(parts) == 3:
                source_name = parts[1]
                source_id = result.source_id
            else:
                source_name = provider
                source_id = f"crawler:{provider}:{result.source_id}"
            candidate = SourceMatch(
                source_id=source_id,
                source_name=source_name,
                title=result.title,
                content_type=result.type,
                year=result.year,
                episode_count=result.episode_count,
                score=(
                    analysis.ranking_score + site_priority(source_name) // 10
                    if provider == "maccms"
                    else (
                        analysis.ranking_score
                        + DIRECT_SOURCE_PRIORITIES.get(provider, 0)
                    )
                ),
                evidence=analysis.evidence,
                **ContentAggregator._rule_identity(provider, result),
            )
            previous = matches.get(source_id)
            if previous is None or candidate.score > previous.score:
                matches[source_id] = candidate
        return list(matches.values())

    async def _discover_maccms_matches_progressively(
        self,
        aliases: list[str],
        *,
        content_type: str,
        year: int,
        query_budget: int,
        alias_limit: int,
        diagnostics: dict[str, SourceDiscoveryDiagnostic] | None = None,
    ) -> AsyncIterator[SourceMatch]:
        if not self._provider_enabled("aggregate.maccms"):
            return
        expected_type = "series" if content_type == "tv" else content_type
        if (
            expected_type in {"anime", "series", "movie"}
            and expected_type not in self._maccms.content_types
        ):
            return
        eligible = self._maccms.discovery_sources_for(content_type)
        if diagnostics is not None:
            eligible_names = {source.name for source in eligible}
            for source in self._maccms.discovery_sources:
                diagnostic = diagnostics.get(source.name)
                if diagnostic is not None and source.name not in eligible_names:
                    diagnostic.status = SourceDiscoveryStatus.UNSUPPORTED_CONTENT_TYPE
        sources = [
            DiscoverySource(
                key=source.name,
                preferred=source.preferred,
                priority_group=source.priority_group,
                weight=source.weight,
            )
            for source in eligible
        ]
        scored_outcomes: dict[int, list[SourceMatch]] = {}

        def score_outcome(outcome: MacCmsSearchOutcome) -> list[SourceMatch]:
            return self._score_scraper_results(
                "maccms",
                outcome.results,
                aliases,
                content_type=content_type,
                year=year,
            )

        def is_terminal(outcome: MacCmsSearchOutcome) -> bool:
            matches = score_outcome(outcome)
            scored_outcomes[id(outcome)] = matches
            return not outcome.succeeded or bool(matches)

        async def query(
            source: DiscoverySource,
            alias: str,
        ) -> MacCmsSearchOutcome:
            diagnostic = diagnostics.get(source.key) if diagnostics else None
            if diagnostic is not None:
                diagnostic.queried = True
                diagnostic.aliases_attempted += 1
                diagnostic.status = SourceDiscoveryStatus.SEARCHING
            return await self._maccms.search_source(source.key, alias)

        yielded_sites: set[str] = set()
        async for outcome in progressive_alias_search(
            sources,
            aliases[:alias_limit],
            query=query,
            is_terminal=is_terminal,
            query_budget=query_budget,
            max_concurrency=MACCMS_SEARCH_MAX_CONCURRENCY,
            fallback_delay_seconds=MACCMS_FALLBACK_WAVE_DELAY_SECONDS,
        ):
            matches = scored_outcomes.pop(id(outcome), None)
            if matches is None:
                matches = score_outcome(outcome)
            diagnostic = diagnostics.get(outcome.site_name) if diagnostics else None
            if diagnostic is not None:
                diagnostic.search_hit_count += len(outcome.results)
                diagnostic.elapsed_ms = max(
                    diagnostic.elapsed_ms,
                    outcome.elapsed_ms,
                )
                if matches:
                    diagnostic.matched = True
                    diagnostic.best_match_score = max(
                        (match.score for match in matches),
                        default=diagnostic.best_match_score,
                    )
                    diagnostic.status = SourceDiscoveryStatus.MATCHED
                    diagnostic.error_category = ""
                elif outcome.succeeded:
                    diagnostic.status = (
                        SourceDiscoveryStatus.SEARCH_HIT_NO_MATCH
                        if diagnostic.search_hit_count
                        else SourceDiscoveryStatus.SEARCH_MISS
                    )
                    diagnostic.error_category = ""
                elif outcome.timed_out:
                    diagnostic.status = SourceDiscoveryStatus.SEARCH_TIMEOUT
                    diagnostic.error_category = outcome.error_category
                else:
                    diagnostic.status = SourceDiscoveryStatus.SEARCH_ERROR
                    diagnostic.error_category = outcome.error_category
            for candidate in sorted(
                matches,
                key=lambda item: item.score,
                reverse=True,
            ):
                if candidate.source_name in yielded_sites:
                    continue
                yielded_sites.add(candidate.source_name)
                yield candidate

    async def discover_source_matches(
        self,
        aliases: list[str],
        *,
        content_type: str = "",
        year: int = 0,
        max_matches: int | None = None,
        include_diagnostics: bool = False,
    ) -> (
        list[SourceMatch]
        | tuple[list[SourceMatch], dict[str, SourceDiscoveryDiagnostic]]
    ):
        """把稳定元数据条目绑定到各采集站，不把采集站 ID 暴露给客户端。"""
        clean_aliases = _prepare_discovery_aliases(aliases)
        diagnostics = self._new_discovery_diagnostics()
        if not clean_aliases:
            return ([], diagnostics) if include_diagnostics else []

        providers: list[tuple[str, MediaProvider, float]] = []
        if self._provider_enabled("aggregate.tvbox"):
            providers.append(("tvbox", self._tvbox, 2))
        providers.extend(
            (
                name,
                scraper,
                _PROVIDER_SEARCH_TIMEOUTS.get(
                    name, 5 if name in DIRECT_SOURCE_PRIORITIES else 2
                ),
            )
            for name, scraper in self._active_crawler_scrapers.items()
        )
        # The batch deadline may cancel later sites after earlier matches
        # have arrived. Keep those results outside the cancelled collector.
        maccms_matches: list[SourceMatch] = []

        async def collect_maccms() -> list[SourceMatch]:
            async for match in self._discover_maccms_matches_progressively(
                clean_aliases,
                content_type=content_type,
                year=year,
                query_budget=MACCMS_FULL_QUERY_BUDGET,
                alias_limit=MACCMS_FULL_ALIAS_LIMIT,
                diagnostics=diagnostics,
            ):
                maccms_matches.append(match)
            return maccms_matches

        provider_partials: dict[str, dict[str, SourceMatch]] = {
            name: {} for name, _scraper, _timeout in providers
        }
        jobs: list[tuple[str, Awaitable[list[SourceMatch]]]] = []
        if self._provider_enabled("aggregate.maccms"):
            jobs.append(("maccms", asyncio.wait_for(collect_maccms(), timeout=8)))
        jobs.extend(
            (
                name,
                asyncio.wait_for(
                    self._discover_scraper_matches(
                        name,
                        scraper,
                        clean_aliases,
                        content_type=content_type,
                        year=year,
                        diagnostics=diagnostics,
                        partial_matches=provider_partials[name],
                    ),
                    timeout=timeout,
                ),
            )
            for name, scraper, timeout in providers
        )
        groups = await asyncio.gather(
            *(job for _name, job in jobs),
            return_exceptions=True,
        )
        matches: dict[str, SourceMatch] = {}
        for (name, _job), group in zip(jobs, groups):
            if isinstance(group, BaseException):
                affected = (
                    [
                        diagnostic
                        for diagnostic in diagnostics.values()
                        if diagnostic.provider_id == "aggregate.maccms"
                    ]
                    if name == "maccms"
                    else [diagnostics.get(name)]
                )
                for diagnostic in affected:
                    if diagnostic is None:
                        continue
                    if name == "maccms":
                        if diagnostic.status == SourceDiscoveryStatus.SEARCHING:
                            diagnostic.status = SourceDiscoveryStatus.SEARCH_TIMEOUT
                            diagnostic.error_category = READ_TIMEOUT
                        continue
                    diagnostic.queried = True
                    diagnostic.aliases_attempted = max(
                        diagnostic.aliases_attempted, min(1, len(clean_aliases)),
                    )
                    if provider_partials.get(name):
                        diagnostic.status = SourceDiscoveryStatus.MATCHED
                        diagnostic.matched = True
                        diagnostic.error_category = ""
                        continue
                    if isinstance(group, (asyncio.TimeoutError, TimeoutError)):
                        diagnostic.status = SourceDiscoveryStatus.SEARCH_TIMEOUT
                        diagnostic.error_category = READ_TIMEOUT
                    else:
                        diagnostic.status = SourceDiscoveryStatus.SEARCH_ERROR
                        diagnostic.error_category = _classify_resolution_exception(
                            group
                        )
                group = (
                    maccms_matches if name == "maccms"
                    else list(provider_partials.get(name, {}).values())
                )
            for candidate in group:
                previous = matches.get(candidate.source_id)
                if previous is None or candidate.score > previous.score:
                    matches[candidate.source_id] = candidate

        # One best work per site/rule, not one work for the entire rule provider.
        result = self.select_source_matches(
            list(matches.values()), max_matches=max_matches,
        )
        return (result, diagnostics) if include_diagnostics else result

    async def discover_source_matches_progressively(
        self,
        aliases: list[str],
        *,
        content_type: str = "",
        year: int = 0,
        max_matches: int = 12,
    ) -> AsyncIterator[SourceMatch]:
        """Yield the first useful source matches without waiting for every site."""
        clean_aliases = _prepare_discovery_aliases(aliases)
        if not clean_aliases or max_matches <= 0:
            return

        providers: list[tuple[str, MediaProvider, float]] = []
        if self._provider_enabled("aggregate.tvbox"):
            providers.append(("tvbox", self._tvbox, 2))
        providers.extend(
            (
                name,
                scraper,
                _PROVIDER_SEARCH_TIMEOUTS.get(
                    name, 5 if name in DIRECT_SOURCE_PRIORITIES else 2
                ),
            )
            for name, scraper in self._active_crawler_scrapers.items()
        )
        queue: asyncio.Queue[tuple[str, SourceMatch | object]] = asyncio.Queue()
        completed_producer = object()

        async def produce_maccms() -> None:
            try:
                async for candidate in self._discover_maccms_matches_progressively(
                    clean_aliases,
                    content_type=content_type,
                    year=year,
                    query_budget=MACCMS_QUICK_QUERY_BUDGET,
                    alias_limit=MACCMS_QUICK_ALIAS_LIMIT,
                ):
                    queue.put_nowait(("aggregate.maccms", candidate))
                    # Give already-ready rule providers a scheduling turn.
                    await asyncio.sleep(0)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.debug(
                    "Progressive MacCMS discovery failed: %s",
                    type(error).__name__,
                )
            finally:
                queue.put_nowait(("aggregate.maccms", completed_producer))

        async def produce_provider(
            name: str,
            scraper: MediaProvider,
            timeout: float,
        ) -> None:
            def publish(group: list[SourceMatch]) -> None:
                for candidate in group:
                    queue.put_nowait((candidate.provider_id, candidate))

            try:
                await asyncio.wait_for(
                    self._discover_scraper_matches(
                        name,
                        scraper,
                        clean_aliases[:1],
                        content_type=content_type,
                        year=year,
                        on_matches=publish,
                    ),
                    timeout=timeout,
                )
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.debug(
                    "Progressive source discovery failed [%s]: %s",
                    name,
                    type(error).__name__,
                )
            finally:
                queue.put_nowait((
                    f"aggregate.{name}" if name == "tvbox" else f"crawler.{name}",
                    completed_producer,
                ))

        tasks: list[asyncio.Task[None]] = []
        if self._provider_enabled("aggregate.maccms"):
            tasks.append(asyncio.create_task(produce_maccms()))
        tasks.extend(
            asyncio.create_task(produce_provider(name, scraper, timeout))
            for name, scraper, timeout in providers
        )
        yielded_sites: set[tuple[str, str]] = set()
        yielded_rules: set[tuple[str, str]] = set()
        yielded_count = 0
        active_producers = len(tasks)
        pending: dict[str, deque[SourceMatch]] = {}
        provider_turns: dict[str, int] = {}

        def accept_message(message: tuple[str, SourceMatch | object]) -> None:
            nonlocal active_producers
            provider_id, value = message
            if value is completed_producer:
                active_producers -= 1
            elif isinstance(value, SourceMatch):
                pending.setdefault(provider_id, deque()).append(value)

        try:
            while active_producers or any(pending.values()):
                if not any(pending.values()):
                    accept_message(await queue.get())
                # Inspect all already-ready producers before taking another item
                # from a large batch. A slow provider never blocks early output.
                while not queue.empty():
                    accept_message(queue.get_nowait())
                ready = [provider_id for provider_id, group in pending.items() if group]
                if not ready:
                    continue
                provider_id = min(ready, key=lambda key: provider_turns.get(key, 0))
                candidate = pending[provider_id].popleft()
                rule_key = (candidate.provider_id, candidate.rule_id or candidate.site_name)
                if candidate.group_key in yielded_sites or rule_key in yielded_rules:
                    continue
                yielded_sites.add(candidate.group_key)
                yielded_rules.add(rule_key)
                provider_turns[provider_id] = provider_turns.get(provider_id, 0) + 1
                yield candidate
                yielded_count += 1
                if yielded_count >= max_matches:
                    return
                await asyncio.sleep(0)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def resolve_source_matches_progressively(
        self,
        matches: list[SourceMatch],
        *,
        episode: int,
        verify: bool = True,
    ) -> AsyncIterator[SourceResolutionOutcome]:
        """Yield each resolved site as soon as its media checks finish."""
        semaphore = asyncio.Semaphore(SOURCE_MAX_CONCURRENCY)

        async def resolve_one(match: SourceMatch) -> SourceResolutionOutcome:
            async with semaphore:
                started_at = time.monotonic()
                try:
                    raw_lines = await self.get_video_urls(match.source_id, episode)
                except asyncio.CancelledError:
                    raise
                except Exception as error:
                    return SourceResolutionOutcome(
                        match=match,
                        lines=[],
                        status=UNAVAILABLE,
                        error_category=_classify_resolution_exception(error),
                        latency_ms=max(
                            0,
                            int((time.monotonic() - started_at) * 1000),
                        ),
                    )
                raw_lines = [replace(
                    line, provider_id=line.provider_id or match.provider_id,
                    site_name=line.site_name or match.site_name,
                    rule_id=line.rule_id or match.rule_id,
                    rule_name=(line.rule_name if line.rule_name and line.rule_name != line.rule_id
                               else match.rule_name or line.rule_name),
                ) for line in raw_lines]
                descriptor_lines: list[AggregatedVideoLine] = []
                unresolved_lines: list[AggregatedVideoLine] = []
                media_lines: list[AggregatedVideoLine] = []
                for line in raw_lines:
                    descriptor = _client_resolver_descriptor(line.client_resolver)
                    if (
                        match.provider_id == "crawler.kazumi"
                        and not line.url and descriptor
                    ):
                        descriptor_lines.append(replace(
                            line, client_resolver=descriptor,
                            verification_status=CLIENT_RESOLVER_REQUIRED,
                        ))
                    elif line.url:
                        media_lines.append(line)
                    elif match.provider_id in {"crawler.animeko", "crawler.kazumi"}:
                        # A discovered chapter outside the page-extraction
                        # budget is inventory, not a playable URL/JS permission.
                        unresolved_lines.append(replace(line, verification_status=UNAVAILABLE))
                raw_lines = media_lines
                if not verify:
                    lines = [*unresolved_lines, *descriptor_lines, *[
                        replace(
                            line,
                            verification_status=CLIENT_PROBE_REQUIRED,
                            startup_profile=_declared_startup_profile(line),
                        )
                        for line in raw_lines
                        if _is_client_probe_candidate_url(line.url, line.format)
                    ]]
                    return SourceResolutionOutcome(
                        match=match,
                        lines=lines,
                        status=(
                            CLIENT_PROBE_REQUIRED if any(line.url for line in lines)
                            else CLIENT_RESOLVER_REQUIRED if descriptor_lines
                            else UNAVAILABLE
                        ),
                        error_category=("" if any(line.url or line.client_resolver for line in lines)
                                        else READ_TIMEOUT if unresolved_lines else EMPTY_MEDIA),
                        failure_scope=SourceFailureScope.ROUTE,
                        latency_ms=max(
                            0,
                            int((time.monotonic() - started_at) * 1000),
                        ),
                    )
                lines: list[AggregatedVideoLine] = [*descriptor_lines, *unresolved_lines]
                client_categories: list[str] = []
                failure_categories: list[str] = []
                if raw_lines:
                    checks = await asyncio.gather(
                        *(
                            self._line_verification_status(line, detailed=True)
                            for line in raw_lines
                        ),
                        return_exceptions=True,
                    )
                    for line, raw_check in zip(raw_lines, checks):
                        if isinstance(raw_check, BaseException):
                            check = LineVerificationResult(
                                status=UNAVAILABLE,
                                error_category=_classify_resolution_exception(raw_check),
                            )
                        elif isinstance(raw_check, LineVerificationResult):
                            check = raw_check
                        else:
                            # Test doubles and older extensions may still
                            # return the historical plain status string.
                            check = LineVerificationResult(status=str(raw_check))
                        status = check.status
                        if check.error_category:
                            if status == CLIENT_PROBE_REQUIRED:
                                client_categories.append(check.error_category)
                            elif status != SERVER_VERIFIED:
                                failure_categories.append(check.error_category)
                        if status == SERVER_VERIFIED:
                            lines.append(replace(
                                line,
                                verification_status=SERVER_VERIFIED,
                                startup_profile=check.startup_profile,
                                startup_latency_ms=check.latency_ms,
                                **_line_metadata(check),
                            ))
                        elif (
                            status == CLIENT_PROBE_REQUIRED
                            and _is_client_probe_candidate_url(line.url, line.format)
                        ):
                            lines.append(replace(
                                line,
                                verification_status=CLIENT_PROBE_REQUIRED,
                                startup_profile=(
                                    check.startup_profile
                                    if check.startup_profile != STARTUP_UNKNOWN
                                    else _declared_startup_profile(line)
                                ),
                                startup_latency_ms=check.latency_ms,
                            ))
                        elif (
                            check.error_category != NON_PUBLIC_TARGET
                            and _is_inventory_candidate_url(line.url, line.format)
                        ):
                            # Visibility is not playability: keep failed routes
                            # (including 404/invalid media) disabled in inventory.
                            lines.append(replace(
                                line,
                                verification_status=UNAVAILABLE,
                                startup_profile=_declared_startup_profile(line),
                                startup_latency_ms=check.latency_ms,
                            ))
                statuses = {
                    line.verification_status
                    for line in lines
                    if line.verification_status != UNAVAILABLE
                }
                status = (
                    SERVER_VERIFIED
                    if SERVER_VERIFIED in statuses
                    else CLIENT_PROBE_REQUIRED
                    if CLIENT_PROBE_REQUIRED in statuses
                    else CLIENT_RESOLVER_REQUIRED
                    if CLIENT_RESOLVER_REQUIRED in statuses
                    else UNAVAILABLE
                )
                if status in {SERVER_VERIFIED, CLIENT_RESOLVER_REQUIRED}:
                    error_category = ""
                elif status == CLIENT_PROBE_REQUIRED:
                    error_category = _strongest_error_category(
                        client_categories,
                        SERVER_BLOCKED_CLIENT_CANDIDATE,
                    )
                else:
                    error_category = _strongest_error_category(
                        failure_categories,
                        READ_TIMEOUT if unresolved_lines and not raw_lines
                        else EMPTY_MEDIA if not raw_lines else UNKNOWN_EXCEPTION,
                    )
                return SourceResolutionOutcome(
                    match=match,
                    lines=lines,
                    status=status,
                    error_category=error_category,
                    failure_scope=SourceFailureScope.ROUTE,
                    latency_ms=max(
                        0,
                        int((time.monotonic() - started_at) * 1000),
                    ),
                )

        tasks = [asyncio.create_task(resolve_one(match)) for match in matches]
        try:
            for completed in asyncio.as_completed(tasks):
                try:
                    outcome = await completed
                except asyncio.CancelledError:
                    raise
                except Exception as error:
                    logger.debug(
                        "Source resolution task failed: %s",
                        type(error).__name__,
                    )
                    continue
                yield outcome
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def resolve_source_matches(
        self,
        matches: list[SourceMatch],
        *,
        episode: int,
        verify: bool = True,
        include_diagnostics: bool = False,
    ) -> (
        tuple[list[AggregatedVideoLine], dict[str, str]]
        | tuple[
            list[AggregatedVideoLine],
            dict[str, str],
            dict[str, SourceResolutionOutcome],
        ]
    ):
        """低并发解析多站线路，并区分服务器实播与客户端候选。"""
        health: dict[str, str] = {}
        diagnostics: dict[str, SourceResolutionOutcome] = {}
        unique: dict[str, AggregatedVideoLine] = {}
        status_rank = {
            UNAVAILABLE: 0, CLIENT_RESOLVER_REQUIRED: 1,
            CLIENT_PROBE_REQUIRED: 2, SERVER_VERIFIED: 3,
        }
        async for outcome in self.resolve_source_matches_progressively(
            matches,
            episode=episode,
            verify=verify,
        ):
            match, lines, status = outcome
            if match.binding_key != match.source_name:
                health[match.binding_key] = status
                if isinstance(outcome, SourceResolutionOutcome):
                    diagnostics[match.binding_key] = outcome
            previous_status = health.get(match.source_name)
            if previous_status is None or status_rank.get(status, 0) > status_rank.get(previous_status, 0):
                health[match.source_name] = status
                if isinstance(outcome, SourceResolutionOutcome):
                    diagnostics[match.source_name] = outcome
            for line in lines:
                key = _video_line_identity(line)
                previous = unique.get(key)
                if previous is None or (
                    previous.verification_status != SERVER_VERIFIED
                    and line.verification_status == SERVER_VERIFIED
                ):
                    unique[key] = line
        if include_diagnostics:
            return list(unique.values()), health, diagnostics
        return list(unique.values()), health

    async def search(
        self,
        keyword: str,
        content_types: list[str] = None,
        max_results: int = 30,
    ) -> list[AggregatedSubject]:
        """
        统一搜索。

        Args:
            keyword: 搜索关键词
            content_types: 内容类型过滤，如 ["anime", "tv", "movie"]
            max_results: 最大结果数
        """
        if content_types is None:
            content_types = ["anime", "tv", "movie"]

        all_results: list[AggregatedSubject] = []
        seen_titles: set[str] = set()

        async def add_results(source_label: str, subjects: list, type_override: str = None,
                              orig_ids: list = None):
            for idx, s in enumerate(subjects):
                title = s.get("title", "") if isinstance(s, dict) else (
                    s.title if hasattr(s, 'title') else str(s)
                )
                # 保存原始 source_id
                orig_id = ""
                if orig_ids and idx < len(orig_ids):
                    orig_id = orig_ids[idx]
                elif isinstance(s, dict):
                    orig_id = s.get("source_id", s.get("id", ""))
                else:
                    orig_id = getattr(s, 'source_id', '')

                title_lower = title.strip().lower()
                # MacCMS 同一标题的不同站点代表不同播放线路，不能在排序前
                # 以统一的 "maccms:标题" 去重，否则后返回的稳定站会消失。
                dedup_key = (
                    orig_id.strip().lower()
                    if orig_id and orig_id.startswith("maccms:")
                    else f"{source_label}:{title_lower}"
                )
                if dedup_key in seen_titles:
                    continue
                seen_titles.add(dedup_key)

                ct = type_override or (
                    s.get("type", "unknown") if isinstance(s, dict)
                    else getattr(s, 'type', 'unknown')
                )

                # 若 orig_id 已是带源前缀的完整可反查 ID (maccms:/tvbox:/intl:),
                # 直接用它作为对外 id, 使 /api/v2/vod 能据此反查线路。
                # 否则退回 display hash (仅用于展示)。
                if source_label.startswith("crawler:") and orig_id:
                    display_id = f"{source_label}:{orig_id}"
                elif orig_id and orig_id.split(":", 1)[0] in ("maccms", "tvbox", "intl"):
                    display_id = orig_id
                else:
                    title_fingerprint = stable_digest(
                        f"display|v1|{source_label}|{title_lower}"
                    )
                    display_id = f"{source_label}:display:v1:{title_fingerprint[:24]}"

                all_results.append(AggregatedSubject(
                    id=display_id,
                    title=title,
                    cover_url=s.get("cover_url", "") if isinstance(s, dict) else getattr(s, 'cover_url', ''),
                    summary=s.get("summary", "") if isinstance(s, dict) else getattr(s, 'summary', ''),
                    content_type=ct,
                    language=s.get("lang", "") if isinstance(s, dict) else getattr(s, 'lang', ''),
                    year=s.get("year", 0) if isinstance(s, dict) else getattr(s, 'year', 0),
                    sources=[source_label],
                    _source_refs={source_label: orig_id},
                ))

        # 并行搜索所有源
        tasks = []

        # 0. MacCMS 多站聚合 (主力源: 国内外电影/剧/番/综艺)
        async def search_maccms():
            try:
                results = await self._maccms.search(keyword)
                limit = max(60, max_results * 6)
                selected = results[:limit]
                await add_results("maccms", [
                    {"title": r.title, "cover_url": r.cover_url,
                     "type": r.type, "lang": r.lang,
                     "year": r.year, "summary": r.summary}
                    for r in selected
                ],
                orig_ids=[r.source_id for r in selected])
            except Exception as e:
                logger.warning(f"MacCMS search failed: {e}")
        if self._provider_enabled("aggregate.maccms"):
            tasks.append(search_maccms())

        # 1. 独立动漫站适配器：每个站点直接搜索，不经过其它聚合服务。
        if "anime" in content_types:
            for provider, scraper in self._active_crawler_scrapers.items():
                async def search_crawler(
                    provider_name: str = provider,
                    provider_scraper: MediaProvider = scraper,
                ):
                    try:
                        results = await provider_scraper.search(keyword)
                        await add_results(f"crawler:{provider_name}", [
                            {"title": r.title, "cover_url": r.cover_url,
                             "type": "anime", "lang": r.lang,
                             "year": r.year, "summary": r.summary}
                            for r in results[:10]
                        ], "anime",
                        orig_ids=[r.source_id for r in results[:10]])
                    except Exception as e:
                        logger.warning(
                            "Crawler search failed [%s]: %s",
                            provider_name,
                            type(e).__name__,
                        )
                tasks.append(search_crawler())

        # 2. TVBox (国产剧+电影+动漫)
        if (
            self._provider_enabled("aggregate.tvbox")
            and any(ct in content_types for ct in ["tv", "movie", "anime"])
        ):
            async def search_tvbox():
                try:
                    results = await self._tvbox.search(keyword)
                    await add_results("tvbox", [
                        {"title": r.title, "cover_url": r.cover_url,
                         "type": r.type, "lang": r.lang,
                         "year": r.year, "summary": r.summary}
                        for r in results[:10]
                    ],
                    orig_ids=[r.source_id for r in results[:10]])
                except Exception as e:
                    logger.warning(f"TVBox search failed: {e}")
            tasks.append(search_tvbox())

        # 3. TVMaze + TMDB (美剧/英剧/电影)
        if (
            self._provider_enabled("aggregate.vod")
            and any(ct in content_types for ct in ["tv", "movie"])
        ):
            async def search_intl():
                try:
                    results = await self._vod.search(keyword)
                    await add_results("intl", [
                        {"title": r.title, "cover_url": r.cover_url,
                         "type": r.type, "lang": r.lang,
                         "year": r.year, "summary": r.summary}
                        for r in results[:10]
                    ],
                    orig_ids=[r.source_id for r in results[:10]])
                except Exception as e:
                    logger.warning(f"International search failed: {e}")
            tasks.append(search_intl())

        # 等待所有搜索完成
        await asyncio.gather(*tasks, return_exceptions=True)

        # 排序: 活源站优先 (经验上 CDN 稳定的站排前), 再按评分
        # MacCMS 各站可靠度差异大, 把已知自带新鲜 CDN 的站顶到前面,
        # 死链率高的聚合站沉底, 这样客户端优先命中能播的线路。
        def _site_of(x):
            xid = getattr(x, "id", "") or ""
            if xid.startswith("maccms:"):
                p = xid.split(":")
                if len(p) >= 2:
                    return p[1]
            return xid.split(":", 1)[0] if ":" in xid else "other"

        def _rank(x):
            return (site_priority(_site_of(x)), x.rating)

        all_results.sort(key=_rank, reverse=True)

        # 每站限额轮转: 避免单个站(如暴风)刷屏, 保证活源站(iKun/魔都)也进结果。
        from collections import defaultdict
        per_site = defaultdict(list)
        for r in all_results:
            per_site[_site_of(r)].append(r)
        # 按站权重高→低轮流取, 每轮每站取一个
        ordered_sites = sorted(per_site.keys(),
                               key=site_priority, reverse=True)
        interleaved = []
        idx = 0
        while len(interleaved) < max_results:
            added = False
            for s in ordered_sites:
                if idx < len(per_site[s]):
                    interleaved.append(per_site[s][idx])
                    added = True
                    if len(interleaved) >= max_results:
                        break
            if not added:
                break
            idx += 1
        return interleaved

    async def get_episodes(self, subject_id: str) -> list[AggregatedEpisode]:
        """获取剧集列表。subject_id 支持两种格式：源ID 或 搜索结果的 display ID"""
        # 如果是搜索结果返回的 display ID，从缓存中查找
        # 否则直接解析 source:original_id 格式
        source, sid = subject_id.split(":", 1) if ":" in subject_id else ("unknown", subject_id)

        if source == "maccms" and self._provider_enabled("aggregate.maccms"):
            # subject_id 形如 maccms:站名:vod_id
            detail = await self._maccms.get_detail(subject_id)
            if detail:
                return [
                    AggregatedEpisode(number=ep.number, title=ep.title)
                    for ep in detail.episodes
                ]
            return []

        if source == "tvbox" and self._provider_enabled("aggregate.tvbox"):
            # sid 可能是 display hash, 也可能是 tvbox:源名:vod_id 格式
            # 尝试直接作为 source_id 使用
            lookup_id = subject_id
            if not subject_id.startswith("tvbox:"):
                # display ID - 无法精确获取，返回空
                return []
            detail = await self._tvbox.get_detail(lookup_id)
            if detail:
                return [
                    AggregatedEpisode(number=ep.number, title=ep.title)
                    for ep in detail.episodes
                ]

        elif source == "intl" and self._provider_enabled("aggregate.vod"):
            if not subject_id.startswith("intl:"):
                return []
            detail = await self._vod.get_detail(subject_id.replace("intl:", "", 1))
            if detail:
                return [
                    AggregatedEpisode(number=ep.number, title=ep.title)
                    for ep in detail.episodes
                ]

        elif source == "crawler":
            parts = subject_id.split(":", 2)
            if len(parts) != 3:
                return []
            scraper = self._active_crawler_scrapers.get(parts[1])
            if scraper is None:
                return []
            detail = await scraper.get_detail(parts[2])
            if detail:
                return [
                    AggregatedEpisode(number=ep.number, title=ep.title)
                    for ep in detail.episodes
                ]

        return []

    async def get_video_urls(
        self, subject_id: str, episode: int = 1, title_hint: str = ""
    ) -> list[AggregatedVideoLine]:
        """
        获取视频播放地址（多条线路）。

        subject_id 格式:
          - crawler:agefans:12345 → 独立站点适配器
          - tvbox:暴风:47131 → TVBox 源
          - intl:tvmaze_123 → 国际源
        """
        all_lines: list[AggregatedVideoLine] = []

        if (
            subject_id.startswith("maccms:")
            and self._provider_enabled("aggregate.maccms")
        ):
            lines = await self._maccms.get_video_urls(subject_id, episode)
            for l in lines:
                all_lines.append(AggregatedVideoLine(
                    url=l.url, title=l.title,
                    format=l.format, source=l.source_name, headers=dict(l.headers),
                ))

        elif (
            subject_id.startswith("tvbox:")
            and self._provider_enabled("aggregate.tvbox")
        ):
            lines = await self._tvbox.get_video_urls(subject_id, episode)
            for l in lines:
                all_lines.append(AggregatedVideoLine(
                    url=l.url, title=l.title,
                    format=l.format, source=f"tvbox:{l.source_name}",
                ))

        elif (
            subject_id.startswith("intl:")
            and self._provider_enabled("aggregate.vod")
        ):
            real_id = subject_id.replace("intl:", "", 1)
            lines = await self._vod.get_video_urls(real_id, episode)
            for l in lines:
                all_lines.append(AggregatedVideoLine(
                    url=l.url, title=l.title,
                    format=l.format, source=f"intl:{l.source_name}",
                ))

        elif subject_id.startswith("crawler:"):
            parts = subject_id.split(":", 2)
            if len(parts) == 3:
                scraper = self._active_crawler_scrapers.get(parts[1])
                if scraper is not None:
                    lines = await scraper.get_video_urls(parts[2], episode)
                    identity = SourceMatch(
                        source_id=subject_id, source_name=parts[1], title="",
                        content_type="", year=0,
                    )
                    rule_name = identity.rule_name
                    if isinstance(scraper, AnimekoScraper):
                        rule = scraper._rule_by_id(identity.rule_id)
                        if rule is not None:
                            rule_name = rule.display_name
                    for line in lines:
                        descriptor = dict(getattr(line, "client_resolver", {}) or {})
                        all_lines.append(AggregatedVideoLine(
                            url=line.url,
                            title=line.title,
                            quality=line.quality,
                            format=line.format,
                            # 保留适配器给出的线路标识:聚合源单集可返回数十条
                            # 线路,写死成站名会让它们共用一个身份,客户端按
                            # provider|来源名 折叠时就只剩一条。
                            source=_crawler_line_source(parts[1], line.source_name),
                            headers=line.headers,
                            client_resolver=descriptor,
                            provider_id=identity.provider_id,
                            site_name=identity.site_name,
                            rule_id=identity.rule_id,
                            rule_name=str(descriptor.get("rule_name") or rule_name),
                            **_line_metadata(line),
                        ))

        # M3U8 fallback for under-served results
        if (
            self._resolver_search_enabled
            and self._enabled_provider_ids
            and len(all_lines) < 3
            and title_hint
        ):
            try:
                extra_urls = await m3u8_resolver.search_and_resolve(title_hint)
                for u in extra_urls[:10]:
                    all_lines.append(AggregatedVideoLine(
                        url=u["url"],
                        title=f"M3U8:{u.get('source', 'unknown')}",
                        format=u.get("format", "hls"),
                        source=f"m3u8:{u.get('source', 'unknown')}",
                    ))
            except Exception as e:
                logger.warning(f"M3U8 fallback error: {e}")

        # 去重
        seen = set()
        unique = []
        for line in all_lines:
            key = _video_line_identity(line)
            if key not in seen:
                seen.add(key)
                unique.append(line)
        return unique

    async def _line_verification_status(
        self,
        line: "AggregatedVideoLine",
        *,
        detailed: bool = False,
    ) -> str | LineVerificationResult:
        """
        校验一条线路是否真能播:
          - m3u8: 清单有效，加密密钥（如有）和首个媒体分片均可读取
          - mp4/其它: HEAD 或 GET, 状态码 < 400 且非 HTML
        """
        started_at = time.monotonic()
        metadata: dict = {}

        def finish(
            status: str,
            error_category: str = "",
            startup_profile: str = STARTUP_UNKNOWN,
        ):
            result = LineVerificationResult(
                status=status,
                error_category=error_category,
                latency_ms=max(0, int((time.monotonic() - started_at) * 1000)),
                startup_profile=startup_profile,
                **(metadata if status == SERVER_VERIFIED else {}),
            )
            return result if detailed else result.status

        def finish_http_failure(status: int):
            if status == 429:
                return finish(CLIENT_PROBE_REQUIRED, RATE_LIMITED)
            if status in {401, 403, 451}:
                return finish(CLIENT_PROBE_REQUIRED, RESTRICTED)
            if status in {404, 410}:
                return finish(UNAVAILABLE, STALE_ROUTE)
            return finish(UNAVAILABLE, UNKNOWN_EXCEPTION)

        url = line.url
        initial_classification = classify_media_url(url, line.format)
        if initial_classification == INVALID_MEDIA_URL:
            return finish(UNAVAILABLE, STALE_ROUTE)
        if initial_classification == PLAYER_PAGE_URL:
            return finish(UNAVAILABLE, PARSER_MISMATCH)
        headers = {"User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
        ), "Accept": "application/vnd.apple.mpegurl,video/*,*/*;q=0.8",
           "Range": "bytes=0-65535"}
        for name, value in (line.headers or {}).items():
            if str(name).lower() in {"referer", "origin"} and str(value):
                headers[str(name)] = str(value)
        try:
            async with httpx.AsyncClient(
                follow_redirects=False,
                timeout=httpx.Timeout(8, connect=5),
                headers=headers,
                transport=self._line_http_transport,
            ) as c:
                client_probe_sentinel = object()
                unsafe_target_sentinel = object()
                stale_redirect_sentinel = object()

                async def fetch(target: str):
                    current = target
                    for _ in range(6):
                        if not await _is_public_http_url(current):
                            return (
                                client_probe_sentinel
                                if _is_client_probe_candidate_url(current)
                                else unsafe_target_sentinel
                            )
                        async with c.stream("GET", current) as resp:
                            if resp.status_code in (301, 302, 303, 307, 308):
                                location = resp.headers.get("location", "").strip()
                                if not location:
                                    return stale_redirect_sentinel
                                current = urljoin(str(resp.url), location)
                                continue
                            body = bytearray()
                            async for chunk in resp.aiter_bytes():
                                remaining = 65536 - len(body)
                                if remaining <= 0:
                                    break
                                body.extend(chunk[:remaining])
                                if len(body) >= 65536:
                                    break
                            return (
                                str(resp.url),
                                resp.status_code,
                                resp.headers.get("content-type", "").lower(),
                                bytes(body),
                                resp.headers,
                            )
                    return stale_redirect_sentinel

                current = url
                for depth in range(4):
                    response = await fetch(current)
                    if response is client_probe_sentinel:
                        return finish(
                            CLIENT_PROBE_REQUIRED,
                            SERVER_BLOCKED_CLIENT_CANDIDATE,
                        )
                    if response is unsafe_target_sentinel:
                        return finish(UNAVAILABLE, NON_PUBLIC_TARGET)
                    if response is stale_redirect_sentinel:
                        return finish(UNAVAILABLE, STALE_ROUTE)
                    response_url, status, content_type, body, response_headers = response
                    if status >= 400:
                        return finish_http_failure(status)
                    if classify_media_url(response_url, line.format) == PLAYER_PAGE_URL:
                        return finish(UNAVAILABLE, PARSER_MISMATCH)
                    body_head = body[:512].decode("utf-8", errors="ignore").lstrip()
                    looks_html = (
                        "text/html" in content_type
                        or body_head.lower().startswith(("<html", "<!doctype html"))
                    )
                    if looks_html:
                        return finish(UNAVAILABLE, PARSER_MISMATCH)
                    is_hls = (
                        "m3u8" in current.lower()
                        or line.format.lower() == "hls"
                        or body_head.startswith("#EXTM3U")
                        or "mpegurl" in content_type
                    )
                    if not is_hls:
                        # DASH/other manifests are metadata documents too.
                        is_manifest = (
                            line.format.lower() in {"dash", "mpd"}
                            or urlparse(response_url).path.lower().endswith(".mpd")
                            or "dash+xml" in content_type
                            or body_head.lower().startswith(("<?xml", "<mpd"))
                        )
                        if not is_manifest:
                            metadata["size_bytes"] = _response_media_size(status, response_headers)
                        startup_profile = _sample_startup_profile(
                            line,
                            response_url,
                            content_type,
                            body,
                        )
                        return (
                            finish(
                                SERVER_VERIFIED,
                                startup_profile=startup_profile,
                            )
                            if status in (200, 206) and bool(body)
                            else finish(UNAVAILABLE, EMPTY_MEDIA)
                        )
                    if not body_head.startswith("#EXTM3U"):
                        return finish(UNAVAILABLE, MALFORMED_MANIFEST)
                    manifest_text = body.decode("utf-8", errors="ignore")
                    whole_length = _response_media_size(status, response_headers)
                    complete = (
                        status == 200 and len(body) < 65536
                        and (whole_length is None or whole_length == len(body))
                    )
                    metadata.update(_hls_sample_metadata(manifest_text, complete=complete))
                    media_reference = next(
                        (
                            item.strip()
                            for item in manifest_text.splitlines()
                            if item.strip() and not item.lstrip().startswith("#")
                        ),
                        "",
                    )
                    if not media_reference:
                        return finish(UNAVAILABLE, EMPTY_MEDIA)
                    media_url = urljoin(response_url, media_reference)
                    if (
                        "#EXT-X-STREAM-INF:" in manifest_text
                        or media_reference.lower().split("?", 1)[0].endswith(".m3u8")
                    ):
                        if depth == 3:
                            return finish(UNAVAILABLE, MALFORMED_MANIFEST)
                        current = media_url
                        continue
                    key_reference = ""
                    for manifest_line in manifest_text.splitlines():
                        stripped_line = manifest_line.strip()
                        if not stripped_line.upper().startswith("#EXT-X-KEY:"):
                            continue
                        attributes = stripped_line.split(":", 1)[1]
                        if re.search(
                            r"(?:^|,)\s*METHOD\s*=\s*NONE(?:,|$)",
                            attributes,
                            re.I,
                        ):
                            continue
                        key_match = re.search(
                            r"(?:^|,)\s*URI\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^,\s]+))",
                            attributes,
                            re.I,
                        )
                        if key_match:
                            key_reference = next(
                                value
                                for value in key_match.groups()
                                if value is not None
                            ).strip()
                            break
                    if key_reference:
                        key_response = await fetch(
                            urljoin(response_url, key_reference)
                        )
                        if key_response is client_probe_sentinel:
                            return finish(
                                CLIENT_PROBE_REQUIRED,
                                SERVER_BLOCKED_CLIENT_CANDIDATE,
                            )
                        if key_response is unsafe_target_sentinel:
                            return finish(UNAVAILABLE, NON_PUBLIC_TARGET)
                        if key_response is stale_redirect_sentinel:
                            return finish(UNAVAILABLE, STALE_ROUTE)
                        _, key_status, key_type, key_body, _key_headers = key_response
                        if key_status >= 400:
                            return finish_http_failure(key_status)
                        key_head = key_body[:512].decode(
                            "utf-8", errors="ignore"
                        ).lstrip().lower()
                        if (
                            len(key_body) < 16
                            or "text/html" in key_type
                            or key_head.startswith(("<html", "<!doctype html"))
                        ):
                            return finish(UNAVAILABLE, MALFORMED_MANIFEST)
                    sample = await fetch(media_url)
                    if sample is client_probe_sentinel:
                        return finish(
                            CLIENT_PROBE_REQUIRED,
                            SERVER_BLOCKED_CLIENT_CANDIDATE,
                        )
                    if sample is unsafe_target_sentinel:
                        return finish(UNAVAILABLE, NON_PUBLIC_TARGET)
                    if sample is stale_redirect_sentinel:
                        return finish(UNAVAILABLE, STALE_ROUTE)
                    _, sample_status, sample_type, sample_body, _sample_headers = sample
                    if sample_status >= 400:
                        return finish_http_failure(sample_status)
                    if len(sample_body) < 188:
                        return finish(UNAVAILABLE, EMPTY_MEDIA)
                    sample_head = sample_body[:512].decode(
                        "utf-8", errors="ignore"
                    ).lstrip().lower()
                    if "text/html" in sample_type or sample_head.startswith(
                        ("<html", "<!doctype html")
                    ):
                        return finish(UNAVAILABLE, EMPTY_MEDIA)
                    return finish(
                        SERVER_VERIFIED,
                        startup_profile=STARTUP_HLS,
                    )
                return finish(UNAVAILABLE, MALFORMED_MANIFEST)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            return finish(UNAVAILABLE, _classify_resolution_exception(error))

    async def _line_reachable(self, line: "AggregatedVideoLine") -> bool:
        return await self._line_verification_status(line) == SERVER_VERIFIED

    async def resolve_verified_lines(
        self, subject_id: str, episode: int = 1, title_hint: str = "",
        verify: bool = True,
    ) -> list["AggregatedVideoLine"]:
        """
        解析播放线路, 并(可选)只保留通过可达性验证的。
        预爬缓存和 /api/v2/vod 都调用它。
        """
        lines = await self.get_video_urls(subject_id, episode, title_hint)
        if not verify or not lines:
            return lines
        checks = await asyncio.gather(
            *[self._line_reachable(l) for l in lines],
            return_exceptions=True,
        )
        alive = [
            l for l, ok in zip(lines, checks)
            if ok is True
        ]
        return alive

    async def get_home_feed(self) -> dict:
        """获取首页推荐 (各类型混合)"""
        result = {
            "anime_trending": [],
            "series_trending": [],
            "movies_trending": [],
        }

        # 独立动漫站分别取最新列表，再统一归一化；不依赖外部聚合服务。
        providers = list(self._active_crawler_scrapers.items())
        latest_groups = await asyncio.gather(
            *(scraper.get_latest(page=1) for _, scraper in providers),
            return_exceptions=True,
        )
        seen_anime: set[tuple[str, str]] = set()
        for (provider, _), items in zip(providers, latest_groups):
            if isinstance(items, BaseException):
                continue
            for item in items[:10]:
                key = (provider, item.source_id)
                if not item.title or key in seen_anime:
                    continue
                seen_anime.add(key)
                result["anime_trending"].append({
                    "id": f"crawler:{provider}:{item.source_id}",
                    "title": item.title,
                    "cover_url": item.cover_url,
                    "type": "anime",
                    "summary": item.summary,
                    "source": provider,
                })

        # 从 TVBox 获取最新
        if self._provider_enabled("aggregate.tvbox"):
            try:
                latest = await self._tvbox.get_latest(page=1)
                for item in latest[:20]:
                    entry = {
                        "id": item.source_id,
                        "title": item.title,
                        "cover_url": item.cover_url,
                        "type": item.type,
                    }
                    if item.type == "movie":
                        result["movies_trending"].append(entry)
                    else:
                        result["series_trending"].append(entry)
            except Exception:
                pass

        return result


# 全局聚合器实例
aggregator = ContentAggregator(
    enabled_provider_ids=PLAYBACK_PROVIDER_IDS,
    resolver_search_enabled=M3U8_SEARCH_ENABLED,
)
