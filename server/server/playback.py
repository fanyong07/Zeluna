"""稳定作品 ID 到已验证播放线路的服务层。"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from urllib.parse import parse_qs, urlparse

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .aggregator import (
    CLIENT_PROBE_REQUIRED,
    SERVER_VERIFIED,
    UNAVAILABLE,
    AggregatedVideoLine,
    SourceMatch,
    aggregator,
)
from .catalog import catalog_service, parse_stable_id
from .config import (
    PLAYBACK_CACHE_HOURS,
    PLAYBACK_NEGATIVE_CACHE_MINUTES,
    PLAYBACK_PARTIAL_CACHE_MINUTES,
    PLAYBACK_QUICK_LINE_COUNT,
    PLAYBACK_QUICK_TIMEOUT_SECONDS,
    PLAYBACK_STALE_HOURS,
    PLAYBACK_STABLE_LINE_COUNT,
    SOURCE_BINDING_HOURS,
    SOURCE_MAX_CONCURRENCY,
)
from .database import (
    PlaybackCache,
    SourceBinding,
    SourceHealth,
    async_session,
    upsert_playback_cache,
)


logger = logging.getLogger(__name__)

_QUICK_CANDIDATE_GRACE_SECONDS = 0.35


class PlaybackService:
    def __init__(self, *, session_factory=async_session):
        self._session_factory = session_factory
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
        if not force:
            cache_state, cached = await self._cache_lookup(
                session,
                stable_id,
                episode,
            )
            if cache_state == "fresh":
                self._metrics["fresh_hit"] += 1
                return cached
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
                return cached
            self._metrics["miss"] += 1

        task = self._start_full_refresh(
            stable_id,
            episode,
            title=title,
            original_title=original_title,
            content_type=content_type,
            year=year,
        )
        return await asyncio.shield(task)

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
        cache_state, cached = await self._cache_lookup(
            session,
            stable_id,
            episode,
        )
        if cache_state == "fresh":
            self._metrics["fresh_hit"] += 1
            return self._select_quick_lines(cached)
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
            return self._select_quick_lines(cached)

        self._metrics["miss"] += 1
        task = self._start_quick_refresh(
            stable_id,
            episode,
            title=title,
            original_title=original_title,
            content_type=content_type,
            year=year,
        )
        return await asyncio.shield(task)

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
                    )

        try:
            result = await asyncio.wait_for(
                load(),
                timeout=PLAYBACK_QUICK_TIMEOUT_SECONDS,
            )
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
        row = await session.scalar(
            select(PlaybackCache).where(
                PlaybackCache.subject_id == stable_id,
                PlaybackCache.episode == episode,
            )
        )
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
            await self._store_cache(session, stable_id, episode, title, [])
            return []

        matches = await self._load_bindings(session, stable_id)
        configured_sites = aggregator.configured_source_names
        matched_sites = {
            match.source_name
            for match in matches
            if match.source_name in configured_sites
        }
        if len(matched_sites) < len(configured_sites):
            discovered = await aggregator.discover_source_matches(
                aliases,
                content_type=content_type,
                year=year,
                max_matches=len(aggregator.source_inventory) + 8,
            )
            matches = self._merge_matches(matches, discovered)
            await self._store_bindings(session, stable_id, matches)

        lines, health = await aggregator.resolve_source_matches(
            matches,
            episode=episode,
            verify=True,
        )
        await self._record_health(session, stable_id, health)
        data = self._complete_site_inventory(
            [self._line_dict(line) for line in lines],
            matches=matches,
            health=health,
        )
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
            aliases = [
                title,
                original_title,
                *(metadata.get("aliases") or []),
            ]
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
    ) -> list[dict]:
        title = title.strip()
        original_title = original_title.strip()
        aliases = [value for value in (title, original_title) if value]
        if aliases:
            identity = parse_stable_id(stable_id)
            content_type = content_type or (identity[1] if identity else "")
        else:
            title, content_type, year, aliases = await self._playback_context(
                stable_id,
                session,
                title=title,
                original_title=original_title,
                content_type=content_type,
                year=year,
            )
        if not aliases:
            return []

        matches = await self._load_bindings(session, stable_id)
        resolved: dict[str, AggregatedVideoLine] = {}
        health: dict[str, str] = {}
        quick_candidate_limit = min(
            6,
            max(2, PLAYBACK_QUICK_LINE_COUNT * 2),
        )

        def remember_result(
            match: SourceMatch,
            lines: list[AggregatedVideoLine],
            status: str,
        ) -> bool:
            health[match.source_name] = status
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

        async def resolve_until_usable(candidates: list[SourceMatch]) -> bool:
            async for match, lines, status in (
                aggregator.resolve_source_matches_progressively(
                    candidates,
                    episode=episode,
                    # The quick cold path returns only syntactically public
                    # candidates. The client performs manifest + first-media
                    # validation before display while the full server refresh
                    # verifies every source in the background.
                    verify=False,
                )
            ):
                if remember_result(match, lines, status):
                    return True
            return False

        async def resolve_one(
            match: SourceMatch,
        ) -> tuple[SourceMatch, list[AggregatedVideoLine], str]:
            async for result in aggregator.resolve_source_matches_progressively(
                [match],
                episode=episode,
                verify=False,
            ):
                return result
            return match, [], UNAVAILABLE

        async def discover_until_usable() -> tuple[bool, list[SourceMatch]]:
            # Discovery and source resolution overlap. Up to six foreground
            # candidates race; the first usable one wins and the rest are
            # cancelled. The outer quick semaphore keeps this bounded to one
            # cold foreground lookup per process.
            queue: asyncio.Queue[object] = asyncio.Queue()
            sentinel = object()
            tasks: set[asyncio.Task] = set()
            discovered: list[SourceMatch] = []

            def completed(task: asyncio.Task) -> None:
                queue.put_nowait(task)

            async def produce() -> None:
                try:
                    async for match in (
                        aggregator.discover_source_matches_progressively(
                            aliases,
                            content_type=content_type,
                            year=year,
                            max_matches=len(aggregator.source_inventory) + 8,
                        )
                    ):
                        discovered.append(match)
                        task = asyncio.create_task(resolve_one(match))
                        tasks.add(task)
                        task.add_done_callback(completed)
                        if len(discovered) >= quick_candidate_limit:
                            break
                finally:
                    queue.put_nowait(sentinel)

            producer = asyncio.create_task(produce())
            producer_done = False
            found = False
            first_usable_at: float | None = None
            try:
                while not producer_done or tasks:
                    if first_usable_at is None:
                        item = await queue.get()
                    else:
                        remaining = (
                            _QUICK_CANDIDATE_GRACE_SECONDS
                            - (time.monotonic() - first_usable_at)
                        )
                        if remaining <= 0:
                            break
                        try:
                            item = await asyncio.wait_for(
                                queue.get(),
                                timeout=remaining,
                            )
                        except asyncio.TimeoutError:
                            break
                    if item is sentinel:
                        producer_done = True
                        continue
                    task = item
                    if not isinstance(task, asyncio.Task):
                        continue
                    tasks.discard(task)
                    try:
                        match, lines, status = task.result()
                    except Exception:
                        continue
                    if remember_result(match, lines, status):
                        found = True
                        first_usable_at = first_usable_at or time.monotonic()
                        quick_count = len(self._select_quick_lines([
                            self._line_dict(line)
                            for line in resolved.values()
                        ]))
                        if quick_count >= PLAYBACK_QUICK_LINE_COUNT:
                            break
            finally:
                if not producer.done():
                    producer.cancel()
                for task in tasks:
                    if not task.done():
                        task.cancel()
                await asyncio.gather(
                    producer,
                    *tasks,
                    return_exceptions=True,
                )
            return found, discovered

        found = bool(matches) and await resolve_until_usable(
            matches[:quick_candidate_limit]
        )
        discovered: list[SourceMatch] = []
        if not found:
            found, discovered = await discover_until_usable()
        if discovered:
            matches = self._merge_matches(matches, discovered)
            await self._store_bindings(session, stable_id, matches)
        if health:
            await self._record_health(session, stable_id, health)
        data = self._complete_site_inventory(
            [self._line_dict(line) for line in resolved.values()],
            matches=matches,
            health=health,
        )
        await self._store_cache(session, stable_id, episode, title, data)
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
        self, session: AsyncSession, stable_id: str
    ) -> list[SourceMatch]:
        cutoff = time.time() - SOURCE_BINDING_HOURS * 3600
        rows = (
            await session.scalars(
                select(SourceBinding)
                .where(
                    SourceBinding.stable_id == stable_id,
                    SourceBinding.enabled.is_(True),
                    SourceBinding.updated_at >= cutoff,
                )
                .order_by(
                    SourceBinding.success_count.desc(),
                    SourceBinding.score.desc(),
                    SourceBinding.failure_count.asc(),
                )
                .limit(len(aggregator.source_inventory) + 8)
            )
        ).all()
        return [
            SourceMatch(
                source_id=row.source_id,
                source_name=row.source_name,
                title=row.matched_title,
                content_type=row.media_type,
                year=row.year,
                episode_count=row.episode_count,
                score=row.score,
            )
            for row in rows
        ]

    async def _store_bindings(
        self,
        session: AsyncSession,
        stable_id: str,
        matches: list[SourceMatch],
    ) -> None:
        now = time.time()
        for match in matches:
            row = await session.scalar(
                select(SourceBinding).where(
                    SourceBinding.stable_id == stable_id,
                    SourceBinding.source_id == match.source_id,
                )
            )
            if row is None:
                row = SourceBinding(
                    stable_id=stable_id,
                    source_id=match.source_id,
                    source_name=match.source_name,
                )
                session.add(row)
            row.matched_title = match.title
            row.media_type = match.content_type
            row.year = match.year
            row.score = match.score
            row.episode_count = match.episode_count
            row.enabled = True
            row.updated_at = now
        await session.commit()

    async def _record_health(
        self,
        session: AsyncSession,
        stable_id: str,
        health: dict[str, str | bool],
    ) -> None:
        now = time.time()
        for source_name, raw_status in health.items():
            status = (
                SERVER_VERIFIED if raw_status is True
                else UNAVAILABLE if raw_status is False
                else str(raw_status)
            )
            binding_rows = (
                await session.scalars(
                    select(SourceBinding).where(
                        SourceBinding.stable_id == stable_id,
                        SourceBinding.source_name == source_name,
                    )
                )
            ).all()
            for row in binding_rows:
                if status == SERVER_VERIFIED:
                    row.success_count += 1
                    row.last_success_at = now
                elif status == UNAVAILABLE:
                    row.failure_count += 1
                    row.last_failure_at = now
                # 连续多次失败后暂停到下次重新发现，避免每次拖慢首播。
                row.enabled = (
                    status == CLIENT_PROBE_REQUIRED
                    or row.failure_count - row.success_count < 5
                )
            source = await session.scalar(
                select(SourceHealth).where(SourceHealth.source_name == source_name)
            )
            if source is None:
                source = SourceHealth(
                    source_name=source_name,
                    success_count=0,
                    failure_count=0,
                    consecutive_failures=0,
                    last_status="unknown",
                    last_checked_at=0.0,
                    latency_ms=0,
                )
                session.add(source)
            source.last_checked_at = now
            if status == SERVER_VERIFIED:
                source.success_count += 1
                source.consecutive_failures = 0
                source.last_status = "healthy"
            elif status == CLIENT_PROBE_REQUIRED:
                source.last_status = CLIENT_PROBE_REQUIRED
            else:
                source.failure_count += 1
                source.consecutive_failures += 1
                source.last_status = "unhealthy"
        await session.commit()

    async def _store_cache(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
        title: str,
        lines: list[dict],
    ) -> None:
        await upsert_playback_cache(
            session,
            subject_id=stable_id,
            episode=episode,
            title=title,
            lines_json=json.dumps(lines, ensure_ascii=False),
            line_count=sum(1 for line in lines if line.get("available") is True),
            verified_at=time.time(),
        )

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
    ) -> list[dict]:
        result = [dict(item) for item in items if isinstance(item, dict)]
        represented_sites = {
            self._site_name(item.get("source"))
            for item in result
            if self._site_name(item.get("source"))
        }
        source_inventory = aggregator.source_inventory
        configured_sites = {name for _, name in source_inventory}
        matched_sites = {
            match.source_name
            for match in (matches or [])
            if match.source_name in configured_sites
        }
        health = health or {}
        for provider, name in source_inventory:
            if name in represented_sites:
                continue
            matched = name in matched_sites or name in health
            status = "unavailable" if matched else "not_found"
            message = (
                "已匹配作品，但本集线路验证失败或暂时超时"
                if matched
                else "当前站点没有匹配到这部作品"
            )
            result.append({
                "url": "",
                "title": name,
                "quality": "",
                "format": "",
                "source": f"{provider}:{name}",
                "headers": {},
                "available": False,
                "status": status,
                "message": message,
                "expires_at": 0,
            })
        return result

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
    def _has_playable_line(items: list[dict]) -> bool:
        return any(
            isinstance(item, dict)
            and item.get("available") is True
            and bool(str(item.get("url") or "").strip())
            for item in items
        )

    @staticmethod
    def _has_usable_cached_route(items: list[dict]) -> bool:
        return any(
            isinstance(item, dict)
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
            and bool(str(item.get("url") or "").strip())
            and (
                item.get("available") is True
                or str(item.get("status") or "") == CLIENT_PROBE_REQUIRED
            )
        ]
        candidates.sort(
            key=lambda entry: (
                0 if entry[1].get("available") is True else 1,
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
            rows = (
                await session.scalars(
                    select(PlaybackCache)
                    .order_by(PlaybackCache.verified_at.asc())
                    .limit(max(1, limit))
                )
            ).all()
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
