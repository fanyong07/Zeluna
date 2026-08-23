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
from collections.abc import AsyncIterator, Iterator
from typing import Optional
from dataclasses import dataclass, field, replace
from urllib.parse import urljoin, urlparse

import httpx

from .m3u8_resolver import resolver as m3u8_resolver
from .scrapers.maccms import MacCmsScraper
from .scrapers.maccms_sites import MACCMS_SITES, site_priority
from .scrapers.tvbox_adapter import TvBoxAdapterScraper
from .scrapers.direct_stream import DbkuScraper, NivodScraper, PpnixScraper
from .scrapers.series.vod_common import CommonVodScraper
from .scrapers.anime.age import AgeScraper
from .scrapers.anime.dm706 import Dm706Scraper
from .scrapers.anime.girigiri import GiriGiriScraper
from .scrapers.anime.html_direct import create_html_direct_anime_scrapers
from .scrapers.anime.xgcartoon import XgCartoonScraper
from .providers import MediaProvider, ProviderMetadata, ProviderRegistry
from .scrapers.base import (
    DIRECT_MEDIA_URL,
    INVALID_MEDIA_URL,
    PLAYER_PAGE_URL,
    SubjectResult,
    classify_media_url,
)
from .config import (
    M3U8_SEARCH_ENABLED,
    PLAYBACK_PROVIDER_IDS,
    SOURCE_MAX_CONCURRENCY,
)
from .stable_identity import stable_digest

logger = logging.getLogger(__name__)

SERVER_VERIFIED = "server_verified"
CLIENT_PROBE_REQUIRED = "client_probe_required"
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


def _normalized_match_title(value: str) -> str:
    import re

    cleaned = (value or "").casefold()
    cleaned = re.sub(r"第\s*\d+\s*[季部期]", "", cleaned)
    cleaned = re.sub(r"\bseason\s*\d+\b", "", cleaned)
    return "".join(char for char in cleaned if char.isalnum())


def _is_safe_short_title_variant(candidate: str, target: str) -> bool:
    """Allow short CJK titles only when the remaining suffix is an edition tag."""
    import re

    if len(target) < 3 or not candidate.startswith(target):
        return False
    suffix = candidate[len(target):]
    return bool(
        suffix
        and re.fullmatch(
            r"(?:"
            r"第?[一二三四五六七八九十\d]+[季部期]"
            r"|season\d+|s\d+"
            r"|特别版|完整版|导演剪辑版|国语|粤语|日语|英语"
            r")+",
            suffix,
        )
    )


def _source_match_score(
    candidate: str,
    aliases: list[str],
    *,
    candidate_type: str,
    expected_type: str,
    candidate_year: int,
    expected_year: int,
) -> int:
    normalized = _normalized_match_title(candidate)
    targets = [_normalized_match_title(alias) for alias in aliases]
    season_specific_bases: dict[str, str] = {}
    for target in targets:
        match = re.search(
            r"(?:第?[一二三四五六七八九十百两\d]+季|season\d+|s\d+)$",
            target,
        )
        if match and target[:match.start()]:
            season_specific_bases[target] = target[:match.start()]
    season_bases = set(season_specific_bases.values())
    score = 0
    for target in targets:
        if not target:
            continue
        if normalized == season_specific_bases.get(target):
            continue
        if target in season_bases and (
            normalized == target or normalized.startswith(target)
        ):
            # Once a verified season-specific alias exists, a bare base title
            # or a different edition (for example a theatrical movie) must not
            # outrank that season merely because it is an exact short match.
            continue
        if normalized == target:
            score = max(score, 100)
        elif min(len(normalized), len(target)) >= 4 and (
            normalized in target or target in normalized
        ):
            score = max(score, 72)
        elif _is_safe_short_title_variant(normalized, target):
            # Keep this below the normal partial-match score. A matching year
            # lifts first-season/edition variants above the acceptance gate,
            # while a different season year remains below it.
            score = max(score, 68)
    if expected_type and candidate_type:
        normalized_expected = "tv" if expected_type == "series" else expected_type
        score += 8 if candidate_type == normalized_expected else -25
    if expected_year and candidate_year:
        distance = abs(expected_year - candidate_year)
        score += 10 if distance == 0 else (4 if distance == 1 else -12)
    return score


def _is_public_ip(value: str) -> bool:
    try:
        return ipaddress.ip_address(value).is_global
    except ValueError:
        return False


async def _is_public_http_url(url: str) -> bool:
    """Reject local/private destinations before the backend probes a line."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return False
    host = parsed.hostname.strip().lower()
    if host == "localhost" or host.endswith(".localhost"):
        return False
    try:
        ipaddress.ip_address(host)
    except ValueError:
        loop = asyncio.get_running_loop()
        try:
            addresses = await loop.run_in_executor(
                None,
                lambda: socket.getaddrinfo(
                    host,
                    parsed.port or (443 if parsed.scheme == "https" else 80),
                    type=socket.SOCK_STREAM,
                ),
            )
        except OSError:
            return False
        resolved = {item[4][0] for item in addresses if item[4]}
        return bool(resolved) and all(_is_public_ip(item) for item in resolved)
    return _is_public_ip(host)


def _is_client_probe_candidate_url(url: str, declared_format: str = "") -> bool:
    """Allow only HTTP(S) candidates that cannot directly name local hosts.

    DNS is deliberately re-checked by the client's public-only HTTP stack.
    This keeps Clash/TUN fake-IP environments usable without allowing a source
    adapter to hand the player a literal loopback or private address.
    """
    if classify_media_url(url, declared_format) != DIRECT_MEDIA_URL:
        return False
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return False
    host = parsed.hostname.strip().lower()
    if host == "localhost" or host.endswith(".localhost"):
        return False
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return True
    return _is_public_ip(host)


@dataclass
class AggregatedSubject:
    """聚合后的条目"""
    id: str                    # 前端展示用 ID
    title: str
    original_title: str = ""
    cover_url: str = ""
    banner_url: str = ""
    summary: str = ""
    content_type: str = "tv"
    language: str = ""
    year: int = 2024
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


@dataclass
class SourceMatch:
    source_id: str
    source_name: str
    title: str
    content_type: str
    year: int
    episode_count: int = 0
    score: int = 0


@dataclass(frozen=True)
class LineVerificationResult:
    status: str
    error_category: str = ""
    latency_ms: int = 0
    startup_profile: str = STARTUP_UNKNOWN


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

    def __iter__(self) -> Iterator[object]:
        # Existing callers intentionally keep the historical three-value
        # unpacking contract while newer callers can read the extra fields.
        yield self.match
        yield self.lines
        yield self.status


def _classify_resolution_exception(error: BaseException) -> str:
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
                "dm706": Dm706Scraper(),
                "girigiri": GiriGiriScraper(),
                "xgcartoon": XgCartoonScraper(),
                **create_html_direct_anime_scrapers(),
                "nivod": NivodScraper(),
                "ppnix": PpnixScraper(),
                "dbku": DbkuScraper(),
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
    def source_inventory(self) -> tuple[tuple[str, str], ...]:
        """Return independently queried sources as ``(provider, name)`` pairs."""
        inventory: list[tuple[str, str]] = []
        if self._provider_enabled("aggregate.maccms"):
            inventory.extend(("maccms", site["name"]) for site in MACCMS_SITES)
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
    ) -> list[SourceMatch]:
        expected_type = "series" if content_type == "tv" else content_type
        if expected_type and expected_type not in scraper.content_types:
            return []

        if provider == "maccms":
            # MacCMS 都是中文聚合站，首选标题的命中率最高。只查一次可避免
            # 站点数 × 别名数造成瞬时连接洪峰；其它独立站仍保留多别名尝试。
            result_groups = await asyncio.gather(
                *(scraper.search(alias) for alias in aliases[:1]),
                return_exceptions=True,
            )
        else:
            result_groups = []
            for alias in aliases[:3]:
                try:
                    result_groups.append(await scraper.search(alias))
                except Exception as error:
                    result_groups.append(error)
        matches: dict[str, SourceMatch] = {}
        for results in result_groups:
            if isinstance(results, BaseException):
                logger.debug(
                    "Source discovery failed [%s]: %s",
                    provider,
                    type(results).__name__,
                )
                continue
            for candidate in self._score_scraper_results(
                provider,
                results,
                aliases,
                content_type=content_type,
                year=year,
            ):
                previous = matches.get(candidate.source_id)
                if previous is None or candidate.score > previous.score:
                    matches[candidate.source_id] = candidate
        return list(matches.values())

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
            score = _source_match_score(
                result.title,
                aliases,
                candidate_type=result.type,
                expected_type=content_type,
                candidate_year=result.year,
                expected_year=year,
            )
            if score < 65:
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
                    score + site_priority(source_name) // 10
                    if provider == "maccms"
                    else score + DIRECT_SOURCE_PRIORITIES.get(provider, 0)
                ),
            )
            previous = matches.get(source_id)
            if previous is None or candidate.score > previous.score:
                matches[source_id] = candidate
        return list(matches.values())

    async def _discover_first_maccms_matches(
        self,
        aliases: list[str],
        *,
        content_type: str,
        year: int,
    ) -> list[SourceMatch]:
        if not self._provider_enabled("aggregate.maccms"):
            return []
        expected_type = "series" if content_type == "tv" else content_type
        if expected_type and expected_type not in self._maccms.content_types:
            return []
        async for results in self._maccms.search_progressively(
            aliases[0],
            preferred_only=True,
        ):
            matches = self._score_scraper_results(
                "maccms",
                results,
                aliases,
                content_type=content_type,
                year=year,
            )
            if matches:
                return matches
        return []

    async def discover_source_matches(
        self,
        aliases: list[str],
        *,
        content_type: str = "",
        year: int = 0,
        max_matches: int = 12,
    ) -> list[SourceMatch]:
        """把稳定元数据条目绑定到各采集站，不把采集站 ID 暴露给客户端。"""
        clean_aliases = []
        seen_aliases = set()
        for value in aliases:
            value = (value or "").strip()
            key = _normalized_match_title(value)
            if value and key and key not in seen_aliases:
                seen_aliases.add(key)
                clean_aliases.append(value)
        if not clean_aliases:
            return []

        providers: list[tuple[str, MediaProvider, float]] = []
        if self._provider_enabled("aggregate.maccms"):
            providers.append(("maccms", self._maccms, 8))
        if self._provider_enabled("aggregate.tvbox"):
            providers.append(("tvbox", self._tvbox, 2))
        providers.extend(
            (
                name,
                scraper,
                5 if name in DIRECT_SOURCE_PRIORITIES else 2,
            )
            for name, scraper in self._active_crawler_scrapers.items()
        )
        jobs = [
            asyncio.wait_for(
                self._discover_scraper_matches(
                    name,
                    scraper,
                    clean_aliases,
                    content_type=content_type,
                    year=year,
                ),
                timeout=timeout,
            )
            for name, scraper, timeout in providers
        ]
        groups = await asyncio.gather(*jobs, return_exceptions=True)
        matches: dict[str, SourceMatch] = {}
        for group in groups:
            if isinstance(group, BaseException):
                continue
            for candidate in group:
                previous = matches.get(candidate.source_id)
                if previous is None or candidate.score > previous.score:
                    matches[candidate.source_id] = candidate

        # 同一站点只保留匹配度最高的一项，避免错季或同名版本刷屏。
        by_site: dict[str, SourceMatch] = {}
        for match in matches.values():
            previous = by_site.get(match.source_name)
            if previous is None or match.score > previous.score:
                by_site[match.source_name] = match
        return sorted(
            by_site.values(),
            key=lambda item: item.score,
            reverse=True,
        )[:max_matches]

    async def discover_source_matches_progressively(
        self,
        aliases: list[str],
        *,
        content_type: str = "",
        year: int = 0,
        max_matches: int = 12,
    ) -> AsyncIterator[SourceMatch]:
        """Yield the first useful source matches without waiting for every site."""
        clean_aliases: list[str] = []
        seen_aliases: set[str] = set()
        for value in aliases:
            value = (value or "").strip()
            key = _normalized_match_title(value)
            if value and key and key not in seen_aliases:
                seen_aliases.add(key)
                clean_aliases.append(value)
        if not clean_aliases:
            return

        providers: list[tuple[str, MediaProvider, float]] = []
        if self._provider_enabled("aggregate.tvbox"):
            providers.append(("tvbox", self._tvbox, 2))
        providers.extend(
            (
                name,
                scraper,
                5 if name in DIRECT_SOURCE_PRIORITIES else 2,
            )
            for name, scraper in self._active_crawler_scrapers.items()
        )
        tasks = []
        if self._provider_enabled("aggregate.maccms"):
            tasks.append(
                asyncio.create_task(
                    asyncio.wait_for(
                        self._discover_first_maccms_matches(
                            clean_aliases,
                            content_type=content_type,
                            year=year,
                        ),
                        timeout=8,
                    )
                )
            )
        tasks.extend(
            asyncio.create_task(
                asyncio.wait_for(
                    self._discover_scraper_matches(
                        name,
                        scraper,
                        clean_aliases[:1],
                        content_type=content_type,
                        year=year,
                    ),
                    timeout=timeout,
                )
            )
            for name, scraper, timeout in providers
        )
        yielded_sites: set[str] = set()
        yielded_count = 0
        try:
            for completed in asyncio.as_completed(tasks):
                try:
                    group = await completed
                except asyncio.CancelledError:
                    raise
                except Exception:
                    continue
                for candidate in sorted(
                    group,
                    key=lambda item: item.score,
                    reverse=True,
                ):
                    if candidate.source_name in yielded_sites:
                        continue
                    yielded_sites.add(candidate.source_name)
                    yield candidate
                    yielded_count += 1
                    if yielded_count >= max_matches:
                        return
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
                if not verify:
                    lines = [
                        replace(
                            line,
                            verification_status=CLIENT_PROBE_REQUIRED,
                            startup_profile=_declared_startup_profile(line),
                        )
                        for line in raw_lines
                        if _is_client_probe_candidate_url(line.url, line.format)
                    ]
                    return SourceResolutionOutcome(
                        match=match,
                        lines=lines,
                        status=(CLIENT_PROBE_REQUIRED if lines else UNAVAILABLE),
                        error_category="" if lines else EMPTY_MEDIA,
                        latency_ms=max(
                            0,
                            int((time.monotonic() - started_at) * 1000),
                        ),
                    )
                lines: list[AggregatedVideoLine] = []
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
                statuses = {line.verification_status for line in lines}
                status = (
                    SERVER_VERIFIED
                    if SERVER_VERIFIED in statuses
                    else CLIENT_PROBE_REQUIRED
                    if CLIENT_PROBE_REQUIRED in statuses
                    else UNAVAILABLE
                )
                if status == SERVER_VERIFIED:
                    error_category = ""
                elif status == CLIENT_PROBE_REQUIRED:
                    error_category = _strongest_error_category(
                        client_categories,
                        SERVER_BLOCKED_CLIENT_CANDIDATE,
                    )
                else:
                    error_category = _strongest_error_category(
                        failure_categories,
                        EMPTY_MEDIA if not raw_lines else UNKNOWN_EXCEPTION,
                    )
                return SourceResolutionOutcome(
                    match=match,
                    lines=lines,
                    status=status,
                    error_category=error_category,
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
        async for outcome in self.resolve_source_matches_progressively(
            matches,
            episode=episode,
            verify=verify,
        ):
            match, lines, status = outcome
            health[match.source_name] = status
            if isinstance(outcome, SourceResolutionOutcome):
                diagnostics[match.source_name] = outcome
            for line in lines:
                previous = unique.get(line.url)
                if previous is None or (
                    previous.verification_status != SERVER_VERIFIED
                    and line.verification_status == SERVER_VERIFIED
                ):
                    unique[line.url] = line
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
                    s.get("type", "tv") if isinstance(s, dict)
                    else getattr(s, 'type', 'tv')
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
                    year=s.get("year", 2024) if isinstance(s, dict) else getattr(s, 'year', 2024),
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
                    format=l.format, source=l.source_name,
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
                    for line in lines:
                        all_lines.append(AggregatedVideoLine(
                            url=line.url,
                            title=line.title,
                            quality=line.quality,
                            format=line.format,
                            source=f"crawler:{parts[1]}",
                            headers=line.headers,
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
            if line.url not in seen:
                seen.add(line.url)
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
                    response_url, status, content_type, body = response
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
                    if media_reference.lower().split("?", 1)[0].endswith(".m3u8"):
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
                        _, key_status, key_type, key_body = key_response
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
                    _, sample_status, sample_type, sample_body = sample
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
