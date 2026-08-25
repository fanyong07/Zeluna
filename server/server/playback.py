"""稳定作品 ID 到已验证播放线路的服务层。"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections import deque
from collections.abc import Callable
from urllib.parse import parse_qs, urlparse

from sqlalchemy.ext.asyncio import AsyncSession

from .aggregator import (
    CLIENT_PROBE_REQUIRED,
    CONNECT_TIMEOUT,
    DIRECT_SOURCE_PRIORITIES,
    DNS_FAILURE,
    EMPTY_MEDIA,
    MALFORMED_MANIFEST,
    NON_PUBLIC_TARGET,
    PARSER_MISMATCH,
    RATE_LIMITED,
    READ_TIMEOUT,
    RESTRICTED,
    SERVER_VERIFIED,
    SERVER_BLOCKED_CLIENT_CANDIDATE,
    STARTUP_HLS,
    STARTUP_MP4_FASTSTART,
    STARTUP_MP4_TAIL_MOOV,
    STARTUP_UNKNOWN,
    STALE_ROUTE,
    UNAVAILABLE,
    UNKNOWN_EXCEPTION,
    AggregatedVideoLine,
    SourceMatch,
    SourceResolutionOutcome,
    aggregator,
)
from .catalog import catalog_service, parse_stable_id
from .config import (
    MANAGED_PLAYBACK_LINES_ENABLED,
    MANAGED_PLAYBACK_LINES_MAX_PER_EPISODE,
    PLAYBACK_CACHE_HOURS,
    PLAYBACK_NEGATIVE_CACHE_MINUTES,
    PLAYBACK_PARTIAL_CACHE_MINUTES,
    PLAYBACK_QUICK_LINE_COUNT,
    PLAYBACK_QUICK_MAX_IN_FLIGHT_CANDIDATES,
    PLAYBACK_QUICK_TIMEOUT_SECONDS,
    PLAYBACK_STALE_HOURS,
    PLAYBACK_STABLE_LINE_COUNT,
    SOURCE_BINDING_HOURS,
    SOURCE_CIRCUIT_BASE_COOLDOWN_SECONDS,
    SOURCE_CIRCUIT_FAILURE_THRESHOLD,
    SOURCE_CIRCUIT_MAX_COOLDOWN_SECONDS,
    SOURCE_MAX_CONCURRENCY,
)
from .database import async_session
from .managed_lines.service import (
    ManagedLineService,
    managed_line_service as default_managed_line_service,
)
from .playback_discovery import SourceDiscoveryDiagnostic, SourceDiscoveryStatus
from .playback_health import SourceFailureScope
from .repositories.playback import (
    PlaybackRepository,
    SourceBindingEntry,
    SourceBindingWrite,
    SourceHealthEntry,
    SourceHealthObservation,
    SqlPlaybackRepository,
)
from .scrapers.base import (
    DIRECT_MEDIA_URL,
    INVALID_MEDIA_URL,
    PLAYER_PAGE_URL,
    classify_media_url,
)
from .title_matching import analyze_source_match


logger = logging.getLogger(__name__)

_SOURCE_HEALTH_EMA_ALPHA = 0.35
_DETERMINISTIC_SOURCE_FAILURES = {
    STALE_ROUTE,
    MALFORMED_MANIFEST,
    EMPTY_MEDIA,
    PARSER_MISMATCH,
}
_SOURCE_ERROR_PENALTIES = {
    "": 0,
    SERVER_BLOCKED_CLIENT_CANDIDATE: 0,
    RESTRICTED: 30,
    RATE_LIMITED: 45,
    DNS_FAILURE: 65,
    NON_PUBLIC_TARGET: 70,
    CONNECT_TIMEOUT: 75,
    READ_TIMEOUT: 90,
    UNKNOWN_EXCEPTION: 120,
    STALE_ROUTE: 230,
    EMPTY_MEDIA: 250,
    MALFORMED_MANIFEST: 280,
    PARSER_MISMATCH: 320,
}


class PlaybackService:
    def __init__(
        self,
        *,
        session_factory=async_session,
        repository_factory: Callable[[AsyncSession], PlaybackRepository] = (
            SqlPlaybackRepository
        ),
        managed_lines_enabled: bool = MANAGED_PLAYBACK_LINES_ENABLED,
        managed_line_service: ManagedLineService = default_managed_line_service,
    ):
        self._session_factory = session_factory
        self._repository_factory = repository_factory
        self._managed_lines_enabled = managed_lines_enabled
        self._managed_line_service = managed_line_service
        self._closing = False
        self._refresh_semaphore = asyncio.Semaphore(SOURCE_MAX_CONCURRENCY)
        # Foreground first-route discovery must never wait behind long-running
        # precache or full-refresh work. Keep one small, dedicated lane for it.
        self._quick_refresh_semaphore = asyncio.Semaphore(1)
        self._refresh_tasks: dict[tuple[str, int], asyncio.Task[list[dict]]] = {}
        self._quick_tasks: dict[tuple[str, int], asyncio.Task[list[dict]]] = {}
        self._metrics = {
            "fresh_hit": 0,
            "stale_hit": 0,
            "miss": 0,
            "refresh_success": 0,
            "refresh_failure": 0,
            "quick_success": 0,
        }

    @property
    def cache_metrics(self) -> dict[str, int]:
        return dict(self._metrics)

    async def aclose(self) -> None:
        self._closing = True
        tasks = {*self._refresh_tasks.values(), *self._quick_tasks.values()}
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._refresh_tasks.clear()
        self._quick_tasks.clear()

    async def lines(
        self,
        stable_id: str,
        episode: int,
        session: AsyncSession,
        *,
        title: str = "",
        original_title: str = "",
        content_type: str = "",
        year: int = 0,
        force: bool = False,
    ) -> list[dict]:
        if parse_stable_id(stable_id) is None:
            return []
        episode = max(1, episode)
        managed = await self._managed_playback_lines(session, stable_id, episode)
        if not force:
            cache_state, cached = await self._cache_lookup(
                session,
                stable_id,
                episode,
            )
            if cache_state == "fresh":
                self._metrics["fresh_hit"] += 1
                return self._merge_managed_lines(managed, cached)
            if cache_state == "stale":
                self._metrics["stale_hit"] += 1
                self._start_full_refresh(
                    stable_id,
                    episode,
                    title=title,
                    original_title=original_title,
                    content_type=content_type,
                    year=year,
                )
                return self._merge_managed_lines(managed, cached)
            self._metrics["miss"] += 1

        task = self._start_full_refresh(
            stable_id,
            episode,
            title=title,
            original_title=original_title,
            content_type=content_type,
            year=year,
        )
        discovered = await asyncio.shield(task)
        return self._merge_managed_lines(managed, discovered)

    async def quick_lines(
        self,
        stable_id: str,
        episode: int,
        session: AsyncSession,
        *,
        title: str = "",
        original_title: str = "",
        content_type: str = "",
        year: int = 0,
    ) -> list[dict]:
        if parse_stable_id(stable_id) is None:
            return []
        episode = max(1, episode)
        managed = await self._managed_playback_lines(session, stable_id, episode)
        cache_state, cached = await self._cache_lookup(
            session,
            stable_id,
            episode,
        )
        if cache_state == "fresh":
            self._metrics["fresh_hit"] += 1
            return self._select_quick_lines([*managed, *cached])
        if cache_state == "stale":
            self._metrics["stale_hit"] += 1
            self._start_full_refresh(
                stable_id,
                episode,
                title=title,
                original_title=original_title,
                content_type=content_type,
                year=year,
            )
            return self._select_quick_lines([*managed, *cached])

        self._metrics["miss"] += 1
        task = self._start_quick_refresh(
            stable_id,
            episode,
            title=title,
            original_title=original_title,
            content_type=content_type,
            year=year,
        )
        if managed:
            return self._select_quick_lines(managed)
        return await asyncio.shield(task)

    async def _managed_playback_lines(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
    ) -> list[dict]:
        if not self._managed_lines_enabled:
            return []
        try:
            return await self._managed_line_service.playback_lines(
                session,
                stable_id=stable_id,
                episode=episode,
                limit=MANAGED_PLAYBACK_LINES_MAX_PER_EPISODE,
            )
        except asyncio.CancelledError:
            raise
        except Exception as error:
            logger.warning(
                "Managed playback line lookup failed for %s episode %s: %s",
                stable_id,
                episode,
                type(error).__name__,
            )
            return []

    @staticmethod
    def _merge_managed_lines(
        managed: list[dict],
        aggregate: list[dict],
    ) -> list[dict]:
        result: list[dict] = []
        seen_urls: set[str] = set()
        for item in [*managed, *aggregate]:
            if not isinstance(item, dict):
                continue
            url = str(item.get("url") or "").strip()
            if url and url in seen_urls:
                continue
            if url:
                seen_urls.add(url)
            result.append(dict(item))
        return result

    def _start_full_refresh(
        self,
        stable_id: str,
        episode: int,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
    ) -> asyncio.Task[list[dict]]:
        key = (stable_id, episode)
        current = self._refresh_tasks.get(key)
        if current is not None and not current.done():
            return current
        task = asyncio.create_task(
            self._run_full_refresh(
                stable_id,
                episode,
                title=title,
                original_title=original_title,
                content_type=content_type,
                year=year,
            )
        )
        self._refresh_tasks[key] = task

        def remove(completed: asyncio.Task[list[dict]]) -> None:
            if self._refresh_tasks.get(key) is completed:
                self._refresh_tasks.pop(key, None)

        task.add_done_callback(remove)
        return task

    async def _run_full_refresh(
        self,
        stable_id: str,
        episode: int,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
    ) -> list[dict]:
        try:
            async with self._refresh_semaphore:
                async with self._session_factory() as session:
                    result = await self._refresh(
                        stable_id,
                        episode,
                        session,
                        title=title,
                        original_title=original_title,
                        content_type=content_type,
                        year=year,
                    )
            self._metrics["refresh_success"] += 1
            return result
        except asyncio.CancelledError:
            raise
        except Exception as error:
            self._metrics["refresh_failure"] += 1
            logger.warning(
                "Playback refresh failed for %s episode %s: %s",
                stable_id,
                episode,
                type(error).__name__,
            )
            return []

    def _start_quick_refresh(
        self,
        stable_id: str,
        episode: int,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
    ) -> asyncio.Task[list[dict]]:
        key = (stable_id, episode)
        current = self._quick_tasks.get(key)
        if current is not None and not current.done():
            return current
        task = asyncio.create_task(
            self._run_quick_refresh(
                stable_id,
                episode,
                title=title,
                original_title=original_title,
                content_type=content_type,
                year=year,
            )
        )
        self._quick_tasks[key] = task

        def remove(completed: asyncio.Task[list[dict]]) -> None:
            if self._quick_tasks.get(key) is completed:
                self._quick_tasks.pop(key, None)

        task.add_done_callback(remove)
        return task

    async def _run_quick_refresh(
        self,
        stable_id: str,
        episode: int,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
    ) -> list[dict]:
        result: list[dict] = []
        deadline = time.monotonic() + PLAYBACK_QUICK_TIMEOUT_SECONDS

        async def load() -> list[dict]:
            async with self._quick_refresh_semaphore:
                async with self._session_factory() as session:
                    return await self._refresh_quick(
                        stable_id,
                        episode,
                        session,
                        title=title,
                        original_title=original_title,
                        content_type=content_type,
                        year=year,
                        deadline=deadline,
                    )

        try:
            # _refresh_quick owns the deadline so it can return routes already
            # accumulated when the budget expires. An outer wait_for would
            # cancel the coroutine and turn a partial success back into zero.
            result = await load()
            if result:
                self._metrics["quick_success"] += 1
        except asyncio.TimeoutError:
            result = []
        except asyncio.CancelledError:
            raise
        except Exception as error:
            logger.debug(
                "Quick playback lookup failed for %s episode %s: %s",
                stable_id,
                episode,
                type(error).__name__,
            )
        finally:
            if not self._closing:
                self._start_full_refresh(
                    stable_id,
                    episode,
                    title=title,
                    original_title=original_title,
                    content_type=content_type,
                    year=year,
                )
        return result

    async def _cached_lines(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
        *,
        force: bool,
        allow_stale: bool = False,
    ) -> list[dict] | None:
        if force:
            return None
        state, items = await self._cache_lookup(session, stable_id, episode)
        if state == "fresh" or (allow_stale and state == "stale"):
            return items
        return None

    async def _cache_lookup(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
    ) -> tuple[str, list[dict]]:
        row = await self._repository_factory(session).get_cache(stable_id, episode)
        if row is None:
            return "miss", []
        if row.line_count <= 0:
            ttl = PLAYBACK_NEGATIVE_CACHE_MINUTES * 60
        elif row.line_count < PLAYBACK_STABLE_LINE_COUNT:
            # Slower sites may still be absent from an early positive result.
            ttl = PLAYBACK_PARTIAL_CACHE_MINUTES * 60
        else:
            ttl = PLAYBACK_CACHE_HOURS * 3600
        try:
            items = json.loads(row.lines_json)
        except (json.JSONDecodeError, TypeError):
            return "miss", []
        if not isinstance(items, list):
            return "miss", []
        now = time.time()
        fresh_items: list[dict] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            if not self._is_safe_cached_item(item):
                continue
            try:
                expires_at = float(item.get("expires_at") or 0)
            except (TypeError, ValueError):
                expires_at = 0
            if expires_at <= 0 or expires_at > now + 15:
                fresh_items.append(item)
        if row.line_count > 0 and not self._has_usable_cached_route(fresh_items):
            return "miss", []
        age = max(0.0, now - row.verified_at)
        if age < ttl:
            state = "fresh"
        elif (
            row.line_count > 0
            and age < PLAYBACK_STALE_HOURS * 3600
            and self._has_usable_cached_route(fresh_items)
        ):
            state = "stale"
        else:
            return "miss", []
        return state, [
            {
                **item,
                "cached": True,
                "stale": state == "stale",
                "cache_state": state,
            }
            for item in self._complete_site_inventory(fresh_items)
        ]

    async def _refresh(
        self,
        stable_id: str,
        episode: int,
        session: AsyncSession,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
    ) -> list[dict]:
        title, content_type, year, aliases = await self._playback_context(
            stable_id,
            session,
            title=title,
            original_title=original_title,
            content_type=content_type,
            year=year,
        )
        if not aliases:
            data = self._complete_site_inventory([])
            return [
                {
                    **item,
                    "cached": False,
                    "stale": False,
                    "cache_state": "cold",
                }
                for item in data
            ]

        source_health = await self._load_source_health(session)
        discovery_diagnostics: dict[str, SourceDiscoveryDiagnostic] = {}
        matches = await self._load_bindings(
            session,
            stable_id,
            source_health=source_health,
            aliases=aliases,
            content_type=content_type,
            year=year,
        )
        configured_sites = aggregator.configured_source_names
        matched_sites = {
            match.source_name
            for match in matches
            if match.source_name in configured_sites
        }
        if len(matched_sites) < len(configured_sites):
            discovery = await aggregator.discover_source_matches(
                aliases,
                content_type=content_type,
                year=year,
                max_matches=len(aggregator.source_inventory) + 8,
                include_diagnostics=True,
            )
            if isinstance(discovery, tuple):
                discovered, discovery_diagnostics = discovery
            else:
                discovered = discovery
                discovery_diagnostics = {}
            now = time.time()
            probeable: list[SourceMatch] = []
            for match in discovered:
                if self._discovered_match_can_probe(
                    match,
                    source_health.get(match.source_name),
                    now,
                ):
                    probeable.append(match)
                    continue
                diagnostic = discovery_diagnostics.get(match.source_name)
                if diagnostic is not None:
                    diagnostic.status = (
                        SourceDiscoveryStatus.CIRCUIT_SUPPRESSED
                    )
                    diagnostic.matched = True
            discovered = probeable
            matches = self._merge_matches(matches, discovered)
            await self._store_bindings(session, stable_id, matches)

        resolution = await aggregator.resolve_source_matches(
            matches,
            episode=episode,
            verify=True,
            include_diagnostics=True,
        )
        if len(resolution) == 3:
            lines, health, diagnostics = resolution
        else:
            # Preserve compatibility with older provider extensions and test
            # doubles that still return only lines + status.
            lines, health = resolution
            diagnostics = {}
        await self._record_health(
            session,
            stable_id,
            health,
            diagnostics=diagnostics,
        )
        data = self._complete_site_inventory(
            [self._line_dict(line) for line in lines],
            matches=matches,
            health=health,
            diagnostics=diagnostics,
            discovery_diagnostics=discovery_diagnostics,
        )
        if self._should_store_full_result(data):
            await self._store_cache(session, stable_id, episode, title, data)
        return [
            {
                **item,
                "cached": False,
                "stale": False,
                "cache_state": "cold",
            }
            for item in data
        ]

    async def _playback_context(
        self,
        stable_id: str,
        session: AsyncSession,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
    ) -> tuple[str, str, int, list[str]]:
        metadata = await catalog_service.get_subject(stable_id, session)
        if metadata:
            title = str(metadata.get("title") or title).strip()
            original_title = str(
                metadata.get("original_title") or original_title
            ).strip()
            content_type = str(metadata.get("media_type") or content_type).strip()
            date = str(metadata.get("date") or "")
            if not year and len(date) >= 4 and date[:4].isdigit():
                year = int(date[:4])
            aliases = await catalog_service.playback_aliases(metadata)
        else:
            aliases = [title, original_title]
            identity = parse_stable_id(stable_id)
            content_type = content_type or (identity[1] if identity else "")
        aliases = [str(value).strip() for value in aliases if str(value).strip()]
        return title, content_type, year, aliases

    async def _refresh_quick(
        self,
        stable_id: str,
        episode: int,
        session: AsyncSession,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
        deadline: float | None = None,
    ) -> list[dict]:
        deadline = deadline or (time.monotonic() + PLAYBACK_QUICK_TIMEOUT_SECONDS)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return []
        try:
            title, content_type, year, aliases = await asyncio.wait_for(
                self._playback_context(
                    stable_id,
                    session,
                    title=title.strip(),
                    original_title=original_title.strip(),
                    content_type=content_type,
                    year=year,
                ),
                timeout=remaining,
            )
        except asyncio.TimeoutError:
            return []
        if not aliases:
            return []

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return []
        try:
            source_health = await asyncio.wait_for(
                self._load_source_health(session),
                timeout=remaining,
            )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return []
            matches = await asyncio.wait_for(
                self._load_bindings(
                    session,
                    stable_id,
                    source_health=source_health,
                    aliases=aliases,
                    content_type=content_type,
                    year=year,
                ),
                timeout=remaining,
            )
        except asyncio.TimeoutError:
            return []
        resolved: dict[str, AggregatedVideoLine] = {}
        health: dict[str, str] = {}
        diagnostics: dict[str, SourceResolutionOutcome] = {}

        def remember_result(
            match: SourceMatch,
            lines: list[AggregatedVideoLine],
            status: str,
            outcome: object | None = None,
        ) -> bool:
            health[match.source_name] = status
            if isinstance(outcome, SourceResolutionOutcome):
                diagnostics[match.source_name] = outcome
            for line in lines:
                previous = resolved.get(line.url)
                if previous is None or (
                    previous.verification_status != SERVER_VERIFIED
                    and line.verification_status == SERVER_VERIFIED
                ):
                    resolved[line.url] = line
            # The app performs manifest + first-segment validation for public
            # client candidates while the full server refresh verifies every
            # source in the background.
            return status in {SERVER_VERIFIED, CLIENT_PROBE_REQUIRED}

        async def resolve_one(
            match: SourceMatch,
        ) -> object:
            async for result in aggregator.resolve_source_matches_progressively(
                [match],
                episode=episode,
                verify=False,
            ):
                return result
            return SourceResolutionOutcome(
                match=match,
                lines=[],
                status=UNAVAILABLE,
                error_category=EMPTY_MEDIA,
            )

        discovered: list[SourceMatch] = []
        discovered_queue: deque[SourceMatch] = deque()
        existing_queue: deque[SourceMatch] = deque(matches)
        completed_tasks: deque[asyncio.Task[object]] = deque()
        active_tasks: set[asyncio.Task[object]] = set()
        attempted_source_ids: set[str] = set()
        wake = asyncio.Event()
        producer_done = False

        async def produce() -> None:
            nonlocal producer_done
            try:
                async for match in aggregator.discover_source_matches_progressively(
                    aliases,
                    content_type=content_type,
                    year=year,
                    max_matches=len(aggregator.source_inventory) + 8,
                ):
                    if not self._discovered_match_can_probe(
                        match,
                        source_health.get(match.source_name),
                        time.time(),
                    ):
                        continue
                    discovered.append(match)
                    discovered_queue.append(match)
                    wake.set()
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.debug(
                    "Quick playback discovery failed: %s",
                    type(error).__name__,
                )
            finally:
                producer_done = True
                wake.set()

        def completed(task: asyncio.Task[object]) -> None:
            completed_tasks.append(task)
            wake.set()

        def consume_completed(task: asyncio.Task[object]) -> None:
            if task.cancelled():
                return
            try:
                outcome = task.result()
                match, lines, status = outcome
            except Exception as error:
                logger.debug(
                    "Quick candidate resolution failed: %s",
                    type(error).__name__,
                )
                return
            remember_result(match, lines, status, outcome)

        def next_candidate() -> SourceMatch | None:
            # After the initial binding wave, prefer freshly discovered exact
            # matches over draining a long list of stale bindings.
            for queue in (discovered_queue, existing_queue):
                while queue:
                    candidate = queue.popleft()
                    if candidate.source_id in attempted_source_ids:
                        continue
                    attempted_source_ids.add(candidate.source_id)
                    return candidate
            return None

        def start_candidate(match: SourceMatch) -> None:
            task = asyncio.create_task(resolve_one(match))
            active_tasks.add(task)
            task.add_done_callback(completed)

        def quick_count() -> int:
            return len(self._select_quick_lines([
                self._line_dict(line)
                for line in resolved.values()
            ]))

        producer = asyncio.create_task(produce())
        try:
            while True:
                # Clear before inspecting shared queues so a callback racing
                # with this pass leaves the event set for the next iteration.
                wake.clear()
                while completed_tasks:
                    task = completed_tasks.popleft()
                    active_tasks.discard(task)
                    consume_completed(task)

                if quick_count() >= PLAYBACK_QUICK_LINE_COUNT:
                    break

                while (
                    len(active_tasks)
                    < PLAYBACK_QUICK_MAX_IN_FLIGHT_CANDIDATES
                ):
                    candidate = next_candidate()
                    if candidate is None:
                        break
                    start_candidate(candidate)

                no_more_candidates = (
                    producer_done
                    and not discovered_queue
                    and not existing_queue
                )
                if no_more_candidates and not active_tasks:
                    break

                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                if wake.is_set():
                    continue
                try:
                    await asyncio.wait_for(wake.wait(), timeout=remaining)
                except asyncio.TimeoutError:
                    break
        finally:
            if not producer.done():
                producer.cancel()
            # Preserve a result that completed at the deadline before
            # cancelling the genuinely pending candidates.
            for task in tuple(active_tasks):
                if task.done():
                    active_tasks.discard(task)
                    consume_completed(task)
            for task in active_tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(
                producer,
                *active_tasks,
                return_exceptions=True,
            )
            for task in tuple(active_tasks):
                active_tasks.discard(task)
                if not task.cancelled():
                    consume_completed(task)

        if discovered:
            matches = self._merge_matches(matches, discovered)
            remaining = deadline - time.monotonic()
            if remaining > 0:
                try:
                    await asyncio.wait_for(
                        self._store_bindings(session, stable_id, matches),
                        timeout=remaining,
                    )
                except asyncio.TimeoutError:
                    pass
        if health:
            remaining = deadline - time.monotonic()
            if remaining > 0:
                try:
                    await asyncio.wait_for(
                        self._record_health(
                            session,
                            stable_id,
                            health,
                            diagnostics=diagnostics,
                        ),
                        timeout=remaining,
                    )
                except asyncio.TimeoutError:
                    pass
        data = self._complete_site_inventory(
            [self._line_dict(line) for line in resolved.values()],
            matches=matches,
            health=health,
            diagnostics=diagnostics,
        )
        remaining = deadline - time.monotonic()
        if remaining > 0 and self._has_usable_cached_route(data):
            try:
                await asyncio.wait_for(
                    self._store_cache(session, stable_id, episode, title, data),
                    timeout=remaining,
                )
            except asyncio.TimeoutError:
                pass
        return self._select_quick_lines([
            {
                **item,
                "cached": False,
                "stale": False,
                "cache_state": "cold",
            }
            for item in data
        ])

    async def _load_bindings(
        self,
        session: AsyncSession,
        stable_id: str,
        *,
        source_health: dict[str, SourceHealthEntry] | None = None,
        aliases: list[str] | None = None,
        content_type: str = "",
        year: int = 0,
    ) -> list[SourceMatch]:
        now = time.time()
        cutoff = now - SOURCE_BINDING_HOURS * 3600
        rows = await self._repository_factory(session).load_bindings(
            stable_id=stable_id,
            updated_after=cutoff,
        )
        health = source_health
        if health is None:
            health = await self._load_source_health(session)
        analyzed_rows = []
        for row in rows:
            analysis = analyze_source_match(
                row.matched_title,
                aliases or [],
                candidate_type=row.media_type,
                expected_type=content_type,
                candidate_year=row.year,
                expected_year=year,
            )
            if aliases and not analysis.playback_eligible:
                continue
            circuit_open = self._source_circuit_is_open(
                health.get(row.source_name),
                now,
            )
            trusted_binding = (
                bool(aliases)
                and row.success_count > 0
                and row.last_success_at > 0
                and row.last_success_at >= row.last_failure_at
                and analysis.evidence.allows_circuit_recovery
            )
            if circuit_open and not trusted_binding:
                continue
            analyzed_rows.append((row, analysis.evidence))
        analyzed_rows.sort(
            key=lambda item: self._source_binding_rank(
                item[0],
                health.get(item[0].source_name),
            ),
            reverse=True,
        )
        analyzed_rows = analyzed_rows[:len(aggregator.source_inventory) + 8]
        return [
            SourceMatch(
                source_id=row.source_id,
                source_name=row.source_name,
                title=row.matched_title,
                content_type=row.media_type,
                year=row.year,
                episode_count=row.episode_count,
                score=row.score,
                evidence=evidence,
            )
            for row, evidence in analyzed_rows
        ]

    async def _load_source_health(
        self,
        session: AsyncSession,
    ) -> dict[str, SourceHealthEntry]:
        return await self._repository_factory(session).load_source_health()

    @staticmethod
    def _source_circuit_cooldown_seconds(consecutive_failures: int) -> int:
        if consecutive_failures < SOURCE_CIRCUIT_FAILURE_THRESHOLD:
            return 0
        exponent = min(
            6,
            consecutive_failures - SOURCE_CIRCUIT_FAILURE_THRESHOLD,
        )
        return min(
            SOURCE_CIRCUIT_MAX_COOLDOWN_SECONDS,
            SOURCE_CIRCUIT_BASE_COOLDOWN_SECONDS * (2 ** exponent),
        )

    @classmethod
    def _source_circuit_is_open(
        cls,
        health: SourceHealthEntry | None,
        now: float,
    ) -> bool:
        if health is None:
            return False
        cooldown = cls._source_circuit_cooldown_seconds(
            health.consecutive_failures
        )
        return cooldown > 0 and now < health.last_checked_at + cooldown

    @classmethod
    def _discovered_match_can_probe(
        cls,
        match: SourceMatch,
        health: SourceHealthEntry | None,
        now: float,
    ) -> bool:
        if not cls._source_circuit_is_open(health, now):
            return True
        # Ranking includes provider priority and is not correctness evidence.
        # Only explicit title/season/type/year facts may authorize recovery.
        return match.evidence.allows_circuit_recovery

    @staticmethod
    def _source_binding_rank(
        binding: SourceBindingEntry,
        health: SourceHealthEntry | None,
    ) -> tuple[int, int, int, int, int]:
        if health is None:
            recent_success_rate = 0.5
            latency_ms = 0
            error_category = ""
            consecutive_failures = 0
            status_bonus = 100
            half_open_penalty = 0
        elif health.consecutive_failures >= SOURCE_CIRCUIT_FAILURE_THRESHOLD:
            # The cooldown has elapsed, so this is a half-open recovery probe.
            recent_success_rate = health.recent_success_rate
            latency_ms = health.latency_ms
            error_category = health.last_error_category
            consecutive_failures = health.consecutive_failures
            status_bonus = 0
            half_open_penalty = 900
        elif health.last_status in {"healthy", CLIENT_PROBE_REQUIRED}:
            recent_success_rate = health.recent_success_rate
            latency_ms = health.latency_ms
            error_category = health.last_error_category
            consecutive_failures = health.consecutive_failures
            status_bonus = (
                240 if health.last_status == "healthy" else 170
            )
            half_open_penalty = 0
        elif health.last_status == "unknown":
            recent_success_rate = health.recent_success_rate
            latency_ms = health.latency_ms
            error_category = health.last_error_category
            consecutive_failures = health.consecutive_failures
            status_bonus = 100
            half_open_penalty = 0
        else:
            recent_success_rate = health.recent_success_rate
            latency_ms = health.latency_ms
            error_category = health.last_error_category
            consecutive_failures = health.consecutive_failures
            status_bonus = 0
            half_open_penalty = 0
        recent_success_rate = max(0.0, min(1.0, recent_success_rate or 0.0))
        latency_ms = max(0, latency_ms or 0)
        recent_binding_success = int(
            binding.last_success_at >= binding.last_failure_at
            and binding.last_success_at > 0
        )
        bounded_lifetime_balance = max(
            -20,
            min(20, binding.success_count - binding.failure_count),
        )
        total_score = (
            binding.score * 6
            + DIRECT_SOURCE_PRIORITIES.get(binding.source_name, 0) * 10
            + int(recent_success_rate * 500)
            + status_bonus
            + recent_binding_success * 60
            + bounded_lifetime_balance
            - min(latency_ms, 15_000) // 15
            - consecutive_failures * 140
            - _SOURCE_ERROR_PENALTIES.get(error_category or "", 120)
            - half_open_penalty
        )
        return (
            total_score,
            recent_binding_success,
            binding.score,
            -latency_ms,
            -_SOURCE_ERROR_PENALTIES.get(error_category or "", 120),
        )

    async def _store_bindings(
        self,
        session: AsyncSession,
        stable_id: str,
        matches: list[SourceMatch],
    ) -> None:
        now = time.time()
        await self._repository_factory(session).upsert_bindings(
            stable_id=stable_id,
            bindings=[
                SourceBindingWrite(
                    source_id=match.source_id,
                    source_name=match.source_name,
                    matched_title=match.title,
                    media_type=match.content_type,
                    year=match.year,
                    score=match.score,
                    episode_count=match.episode_count,
                )
                for match in matches
            ],
            updated_at=now,
        )

    async def _record_health(
        self,
        session: AsyncSession,
        stable_id: str,
        health: dict[str, str | bool],
        *,
        diagnostics: dict[str, SourceResolutionOutcome] | None = None,
    ) -> None:
        now = time.time()
        observations: list[SourceHealthObservation] = []
        for source_name, raw_status in health.items():
            status = (
                SERVER_VERIFIED if raw_status is True
                else UNAVAILABLE if raw_status is False
                else str(raw_status)
            )
            diagnostic = (diagnostics or {}).get(source_name)
            latency_ms = max(0, int(getattr(diagnostic, "latency_ms", 0) or 0))
            error_category = str(
                getattr(diagnostic, "error_category", "") or ""
            )
            observations.append(
                SourceHealthObservation(
                    source_name=source_name,
                    status=status,
                    latency_ms=latency_ms,
                    error_category=error_category,
                    failure_scope=getattr(
                        diagnostic,
                        "failure_scope",
                        SourceFailureScope.PROVIDER,
                    ),
                )
            )
        await self._repository_factory(session).record_health(
            stable_id=stable_id,
            observations=observations,
            checked_at=now,
            ema_alpha=_SOURCE_HEALTH_EMA_ALPHA,
            deterministic_failures=frozenset(_DETERMINISTIC_SOURCE_FAILURES),
            server_verified_status=SERVER_VERIFIED,
            client_probe_status=CLIENT_PROBE_REQUIRED,
            unavailable_status=UNAVAILABLE,
            unknown_error_category=UNKNOWN_EXCEPTION,
        )

    async def _store_cache(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
        title: str,
        lines: list[dict],
    ) -> None:
        await self._repository_factory(session).upsert_cache(
            subject_id=stable_id,
            episode=episode,
            title=title,
            lines_json=json.dumps(lines, ensure_ascii=False),
            line_count=sum(
                1
                for line in lines
                if isinstance(line, dict)
                and self._has_usable_cached_route([line])
            ),
            verified_at=time.time(),
        )

    @classmethod
    def _should_store_full_result(cls, items: list[dict]) -> bool:
        return cls._has_usable_cached_route(items) or (
            cls._full_negative_cache_is_confirmed(items)
        )

    @staticmethod
    def _full_negative_cache_is_confirmed(items: list[dict]) -> bool:
        observations = [item for item in items if isinstance(item, dict)]
        if not observations:
            return False
        confirmed_statuses = {
            SourceDiscoveryStatus.SEARCH_MISS.value,
            SourceDiscoveryStatus.SEARCH_HIT_NO_MATCH.value,
            SourceDiscoveryStatus.MATCHED_NO_EPISODE.value,
        }
        for item in observations:
            if item.get("queried") is not True:
                return False
            status = str(item.get("diagnostic_status") or "").strip().lower()
            if status in confirmed_statuses:
                continue
            if (
                status == SourceDiscoveryStatus.ROUTE_UNAVAILABLE.value
                and str(item.get("error_category") or "")
                in _DETERMINISTIC_SOURCE_FAILURES
            ):
                continue
            return False
        return True

    def _line_dict(self, line: AggregatedVideoLine) -> dict:
        server_verified = line.verification_status == SERVER_VERIFIED
        client_probe_required = (
            line.verification_status == CLIENT_PROBE_REQUIRED
        )
        return {
            "url": line.url,
            "title": line.title,
            "quality": line.quality,
            "format": line.format,
            "source": line.source,
            "headers": line.headers,
            "startup_profile": line.startup_profile,
            "startup_latency_ms": line.startup_latency_ms,
            "available": server_verified,
            "status": (
                SERVER_VERIFIED
                if server_verified
                else CLIENT_PROBE_REQUIRED
                if client_probe_required
                else UNAVAILABLE
            ),
            "message": (
                "服务器已验证清单和首个媒体分片"
                if server_verified
                else "服务器出口受限，等待客户端完成清单和首段验证"
                if client_probe_required
                else "当前线路验证失败"
            ),
            "expires_at": self._line_expiry(line.url),
        }

    def _merge_matches(
        self,
        current: list[SourceMatch],
        discovered: list[SourceMatch],
    ) -> list[SourceMatch]:
        merged = {match.source_id: match for match in current}
        for match in discovered:
            previous = merged.get(match.source_id)
            if previous is None or match.score > previous.score:
                merged[match.source_id] = match
        return sorted(merged.values(), key=lambda item: item.score, reverse=True)

    def _complete_site_inventory(
        self,
        items: list[dict],
        *,
        matches: list[SourceMatch] | None = None,
        health: dict[str, str | bool] | None = None,
        diagnostics: dict[str, SourceResolutionOutcome] | None = None,
        discovery_diagnostics: (
            dict[str, SourceDiscoveryDiagnostic] | None
        ) = None,
    ) -> list[dict]:
        result = [dict(item) for item in items if isinstance(item, dict)]
        diagnostics = diagnostics or {}
        discovery_diagnostics = discovery_diagnostics or {}
        source_inventory = aggregator.source_inventory
        matches_by_source: dict[str, SourceMatch] = {}
        for match in matches or []:
            previous = matches_by_source.get(match.source_name)
            if previous is None or match.score > previous.score:
                matches_by_source[match.source_name] = match
            discovery = discovery_diagnostics.get(match.source_name)
            if discovery is None:
                discovery_diagnostics[match.source_name] = (
                    SourceDiscoveryDiagnostic(
                        source_name=match.source_name,
                        provider_id=self._provider_id_for_match(match),
                        best_match_score=match.score,
                        matched=True,
                        status=SourceDiscoveryStatus.MATCHED,
                    )
                )
            else:
                discovery.matched = True
                discovery.best_match_score = max(
                    discovery.best_match_score or match.score,
                    match.score,
                )
        for source_name, raw_status in (health or {}).items():
            discovery = discovery_diagnostics.get(source_name)
            match = matches_by_source.get(source_name)
            if discovery is None and match is not None:
                discovery = SourceDiscoveryDiagnostic(
                    source_name=source_name,
                    provider_id=self._provider_id_for_match(match),
                    best_match_score=match.score,
                    matched=True,
                    status=SourceDiscoveryStatus.MATCHED,
                )
                discovery_diagnostics[source_name] = discovery
            if discovery is None:
                continue
            status = (
                SERVER_VERIFIED
                if raw_status is True
                else UNAVAILABLE
                if raw_status is False
                else str(raw_status)
            )
            if status == SERVER_VERIFIED:
                discovery.status = SourceDiscoveryStatus.SERVER_VERIFIED
                discovery.episode_found = True
            elif status == CLIENT_PROBE_REQUIRED:
                discovery.status = SourceDiscoveryStatus.CLIENT_PROBE_REQUIRED
                discovery.episode_found = True
            else:
                discovery.status = SourceDiscoveryStatus.ROUTE_UNAVAILABLE
        for source_name, resolution in diagnostics.items():
            discovery = discovery_diagnostics.get(source_name)
            if discovery is None:
                discovery = SourceDiscoveryDiagnostic(
                    source_name=source_name,
                    provider_id=self._provider_id_for_match(resolution.match),
                    best_match_score=resolution.match.score,
                    matched=True,
                    status=SourceDiscoveryStatus.MATCHED,
                )
                discovery_diagnostics[source_name] = discovery
            self._apply_resolution_diagnostic(discovery, resolution)
        for item in result:
            source_name = self._site_name(item.get("source"))
            diagnostic = diagnostics.get(source_name)
            discovery = discovery_diagnostics.get(source_name)
            if diagnostic is not None:
                item["error_category"] = diagnostic.error_category
                item["source_latency_ms"] = diagnostic.latency_ms
            if discovery is not None:
                self._apply_discovery_fields(item, discovery)
        represented_sites = {
            self._site_name(item.get("source"))
            for item in result
            if self._site_name(item.get("source"))
        }
        for provider, name in source_inventory:
            if name in represented_sites:
                continue
            discovery = discovery_diagnostics.get(name)
            if discovery is None:
                discovery = SourceDiscoveryDiagnostic(
                    source_name=name,
                    provider_id=(
                        "aggregate.maccms"
                        if provider == "maccms"
                        else f"crawler.{name}"
                    ),
                )
            diagnostic_status = discovery.status.value
            item = {
                "url": "",
                "title": name,
                "quality": "",
                "format": "",
                "source": f"{provider}:{name}",
                "headers": {},
                "available": False,
                "status": self._legacy_discovery_status(diagnostic_status),
                "message": self._discovery_message(diagnostic_status),
                "error_category": (
                    getattr(diagnostics.get(name), "error_category", "")
                    or discovery.error_category
                ),
                "source_latency_ms": (
                    getattr(diagnostics.get(name), "latency_ms", 0)
                    or discovery.elapsed_ms
                ),
                "expires_at": 0,
            }
            self._apply_discovery_fields(item, discovery)
            result.append(item)
        return result

    @staticmethod
    def _apply_discovery_fields(
        item: dict,
        diagnostic: SourceDiscoveryDiagnostic,
    ) -> None:
        item.update({
            "provider_id": diagnostic.provider_id,
            "source_name": diagnostic.source_name,
            "diagnostic_status": diagnostic.status.value,
            "queried": diagnostic.queried,
            "aliases_attempted": diagnostic.aliases_attempted,
            "search_hit_count": diagnostic.search_hit_count,
            "best_match_score": diagnostic.best_match_score,
            "matched": diagnostic.matched,
            "episode_found": diagnostic.episode_found,
            "elapsed_ms": diagnostic.elapsed_ms,
        })

    @staticmethod
    def _apply_resolution_diagnostic(
        diagnostic: SourceDiscoveryDiagnostic,
        resolution: SourceResolutionOutcome,
    ) -> None:
        diagnostic.matched = True
        diagnostic.error_category = resolution.error_category
        if resolution.status == SERVER_VERIFIED:
            diagnostic.status = SourceDiscoveryStatus.SERVER_VERIFIED
            diagnostic.episode_found = True
        elif resolution.status == CLIENT_PROBE_REQUIRED:
            diagnostic.status = SourceDiscoveryStatus.CLIENT_PROBE_REQUIRED
            diagnostic.episode_found = True
        elif resolution.error_category == EMPTY_MEDIA:
            diagnostic.status = SourceDiscoveryStatus.MATCHED_NO_EPISODE
            diagnostic.episode_found = False
        else:
            diagnostic.status = SourceDiscoveryStatus.ROUTE_UNAVAILABLE

    @staticmethod
    def _provider_id_for_match(match: SourceMatch) -> str:
        parts = match.source_id.split(":", 2)
        if parts[0] == "maccms":
            return "aggregate.maccms"
        if parts[0] == "tvbox":
            return "aggregate.tvbox"
        if parts[0] == "crawler" and len(parts) >= 2:
            return f"crawler.{parts[1]}"
        return parts[0] if parts else ""

    @staticmethod
    def _discovery_message(status: str) -> str:
        return {
            SourceDiscoveryStatus.NOT_QUERIED.value: "本轮未查询该来源",
            SourceDiscoveryStatus.SEARCHING.value: "正在搜索该来源",
            SourceDiscoveryStatus.SEARCH_TIMEOUT.value: "来源搜索超时",
            SourceDiscoveryStatus.SEARCH_ERROR.value: "来源暂时无法访问",
            SourceDiscoveryStatus.SEARCH_MISS.value: "当前站点没有匹配到这部作品",
            SourceDiscoveryStatus.SEARCH_HIT_NO_MATCH.value: (
                "搜索到候选，但没有可信作品匹配"
            ),
            SourceDiscoveryStatus.MATCHED.value: "已匹配作品，正在检查线路",
            SourceDiscoveryStatus.CIRCUIT_SUPPRESSED.value: (
                "来源近期连续失败，本轮暂缓请求"
            ),
            SourceDiscoveryStatus.MATCHED_NO_EPISODE.value: (
                "已匹配作品，但没有找到当前集"
            ),
            SourceDiscoveryStatus.ROUTE_UNAVAILABLE.value: (
                "已匹配作品，但当前线路验证失败"
            ),
            SourceDiscoveryStatus.CLIENT_PROBE_REQUIRED.value: (
                "服务器网络无法确认，可在当前设备尝试"
            ),
            SourceDiscoveryStatus.SERVER_VERIFIED.value: "在线服务已确认可播",
            SourceDiscoveryStatus.QUARANTINED.value: "来源已隔离，等待复查",
            SourceDiscoveryStatus.RETIRED.value: "来源已停用",
        }.get(status, "来源暂时不可用")

    @staticmethod
    def _legacy_discovery_status(status: str) -> str:
        if status in {
            SourceDiscoveryStatus.SEARCH_MISS.value,
            SourceDiscoveryStatus.SEARCH_HIT_NO_MATCH.value,
        }:
            return "not_found"
        if status == SourceDiscoveryStatus.SERVER_VERIFIED.value:
            return SERVER_VERIFIED
        if status == SourceDiscoveryStatus.CLIENT_PROBE_REQUIRED.value:
            return CLIENT_PROBE_REQUIRED
        return UNAVAILABLE

    @staticmethod
    def _line_expiry(url: str) -> int:
        """Extract common signed-URL expiry values without guessing short IDs."""
        try:
            query = parse_qs(urlparse(url).query)
        except ValueError:
            return 0
        lowered = {str(key).lower(): values for key, values in query.items()}
        now = int(time.time())
        for key in ("expires", "expire", "exp", "deadline", "wsTime"):
            values = lowered.get(key.lower()) or []
            for raw in values:
                value = str(raw).strip()
                try:
                    timestamp = int(value, 16) if key == "wsTime" else int(value)
                except ValueError:
                    continue
                if timestamp > 10_000_000_000:
                    timestamp //= 1000
                if now - 7 * 86400 <= timestamp <= now + 366 * 86400:
                    return timestamp
        return 0

    @staticmethod
    def _site_name(source: object) -> str:
        parts = str(source or "").split(":", 2)
        return parts[1].strip() if len(parts) >= 2 else ""

    @staticmethod
    def _is_safe_cached_item(item: dict) -> bool:
        url = str(item.get("url") or "").strip()
        if not url:
            return True
        classification = classify_media_url(
            url,
            str(item.get("format") or ""),
        )
        if classification in {INVALID_MEDIA_URL, PLAYER_PAGE_URL}:
            return False
        if classification == DIRECT_MEDIA_URL:
            return True
        return (
            item.get("available") is True
            or str(item.get("status") or "") == SERVER_VERIFIED
        )

    @staticmethod
    def _has_playable_line(items: list[dict]) -> bool:
        return any(
            isinstance(item, dict)
            and PlaybackService._is_safe_cached_item(item)
            and item.get("available") is True
            and bool(str(item.get("url") or "").strip())
            for item in items
        )

    @staticmethod
    def _has_usable_cached_route(items: list[dict]) -> bool:
        return any(
            isinstance(item, dict)
            and PlaybackService._is_safe_cached_item(item)
            and bool(str(item.get("url") or "").strip())
            and (
                item.get("available") is True
                or str(item.get("status") or "") == CLIENT_PROBE_REQUIRED
            )
            for item in items
        )

    @staticmethod
    def _select_quick_lines(items: list[dict]) -> list[dict]:
        candidates = [
            (index, dict(item))
            for index, item in enumerate(items)
            if isinstance(item, dict)
            and PlaybackService._is_safe_cached_item(item)
            and bool(str(item.get("url") or "").strip())
            and (
                item.get("available") is True
                or str(item.get("status") or "") == CLIENT_PROBE_REQUIRED
            )
        ]
        def startup_profile(item: dict) -> str:
            return str(
                item.get("startup_profile") or STARTUP_UNKNOWN
            ).strip().lower()

        has_non_tail_available = any(
            item.get("available") is True
            and startup_profile(item) != STARTUP_MP4_TAIL_MOOV
            for _, item in candidates
        )
        if has_non_tail_available:
            candidates = [
                entry
                for entry in candidates
                if not (
                    entry[1].get("available") is True
                    and startup_profile(entry[1]) == STARTUP_MP4_TAIL_MOOV
                )
            ]

        def startup_rank(item: dict) -> int:
            profile = startup_profile(item)
            if profile == STARTUP_MP4_FASTSTART:
                return 0
            if profile == STARTUP_HLS:
                return 1
            if profile == STARTUP_MP4_TAIL_MOOV:
                return 3
            normalized_format = str(item.get("format") or "").strip().lower()
            if normalized_format in {"hls", "dash"} or "m3u8" in normalized_format:
                return 1
            return 2

        def startup_latency(item: dict) -> int:
            try:
                value = int(item.get("startup_latency_ms") or 0)
            except (TypeError, ValueError):
                return 2**31 - 1
            return value if value > 0 else 2**31 - 1

        candidates.sort(
            key=lambda entry: (
                0 if entry[1].get("available") is True else 1,
                0 if entry[1].get("origin_kind") == "managed" else 1,
                startup_rank(entry[1]),
                startup_latency(entry[1]),
                entry[0],
            )
        )
        selected: list[dict] = []
        hosts: set[str] = set()
        for _, item in candidates:
            try:
                host = (urlparse(str(item.get("url") or "")).hostname or "").lower()
            except ValueError:
                continue
            if not host or host in hosts:
                continue
            hosts.add(host)
            selected.append({**item, "quick": True})
            if len(selected) >= PLAYBACK_QUICK_LINE_COUNT:
                break
        return selected

    async def refresh_due(self, *, limit: int = 12) -> dict[str, int]:
        refreshed = 0
        playable = 0
        async with self._session_factory() as session:
            rows = await self._repository_factory(session).oldest_cache(limit=limit)
        for row in rows:
            async with self._session_factory() as session:
                result = await self.lines(
                    row.subject_id,
                    row.episode,
                    session,
                    title=row.title,
                    force=True,
                )
            refreshed += 1
            if self._has_playable_line(result):
                playable += 1
        return {"refreshed": refreshed, "playable": playable}


playback_service = PlaybackService()
