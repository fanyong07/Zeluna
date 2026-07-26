"""稳定作品 ID 到已验证播放线路的服务层。"""

from __future__ import annotations

import asyncio
import json
import time

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .aggregator import AggregatedVideoLine, SourceMatch, aggregator
from .catalog import catalog_service, parse_stable_id
from .config import (
    PLAYBACK_CACHE_HOURS,
    PLAYBACK_NEGATIVE_CACHE_MINUTES,
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


class PlaybackService:
    def __init__(self):
        self._locks: dict[tuple[str, int], asyncio.Lock] = {}
        self._refresh_semaphore = asyncio.Semaphore(SOURCE_MAX_CONCURRENCY)

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
        cached = await self._cached_lines(session, stable_id, episode, force=force)
        if cached is not None:
            return cached

        key = (stable_id, episode)
        lock = self._locks.setdefault(key, asyncio.Lock())
        try:
            async with lock:
                cached = await self._cached_lines(
                    session, stable_id, episode, force=force
                )
                if cached is not None:
                    return cached
                async with self._refresh_semaphore:
                    return await self._refresh(
                        stable_id,
                        episode,
                        session,
                        title=title,
                        original_title=original_title,
                        content_type=content_type,
                        year=year,
                    )
        finally:
            if not lock.locked():
                self._locks.pop(key, None)

    async def _cached_lines(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
        *,
        force: bool,
    ) -> list[dict] | None:
        if force:
            return None
        row = await session.scalar(
            select(PlaybackCache).where(
                PlaybackCache.subject_id == stable_id,
                PlaybackCache.episode == episode,
            )
        )
        if row is None:
            return None
        ttl = (
            PLAYBACK_CACHE_HOURS * 3600
            if row.line_count > 0
            else PLAYBACK_NEGATIVE_CACHE_MINUTES * 60
        )
        if time.time() - row.verified_at >= ttl:
            return None
        try:
            items = json.loads(row.lines_json)
        except (json.JSONDecodeError, TypeError):
            return None
        if not isinstance(items, list):
            return None
        return [{**item, "cached": True} for item in items if isinstance(item, dict)]

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
        if not aliases:
            await self._store_cache(session, stable_id, episode, title, [])
            return []

        matches = await self._load_bindings(session, stable_id)
        if not matches:
            matches = await aggregator.discover_source_matches(
                aliases,
                content_type=content_type,
                year=year,
            )
            await self._store_bindings(session, stable_id, matches)

        lines, health = await aggregator.resolve_source_matches(
            matches,
            episode=episode,
            verify=True,
        )
        await self._record_health(session, stable_id, health)
        data = [self._line_dict(line) for line in lines]
        await self._store_cache(session, stable_id, episode, title, data)
        return [{**item, "cached": False} for item in data]

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
                .limit(12)
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
        health: dict[str, bool],
    ) -> None:
        now = time.time()
        for source_name, ok in health.items():
            binding_rows = (
                await session.scalars(
                    select(SourceBinding).where(
                        SourceBinding.stable_id == stable_id,
                        SourceBinding.source_name == source_name,
                    )
                )
            ).all()
            for row in binding_rows:
                if ok:
                    row.success_count += 1
                    row.last_success_at = now
                else:
                    row.failure_count += 1
                    row.last_failure_at = now
                # 连续多次失败后暂停到下次重新发现，避免每次拖慢首播。
                row.enabled = row.failure_count - row.success_count < 5
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
            if ok:
                source.success_count += 1
                source.consecutive_failures = 0
                source.last_status = "healthy"
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
            line_count=len(lines),
            verified_at=time.time(),
        )

    def _line_dict(self, line: AggregatedVideoLine) -> dict:
        return {
            "url": line.url,
            "title": line.title,
            "quality": line.quality,
            "format": line.format,
            "source": line.source,
            "headers": line.headers,
        }

    async def refresh_due(self, *, limit: int = 12) -> dict[str, int]:
        refreshed = 0
        playable = 0
        async with async_session() as session:
            rows = (
                await session.scalars(
                    select(PlaybackCache)
                    .order_by(PlaybackCache.verified_at.asc())
                    .limit(max(1, limit))
                )
            ).all()
        for row in rows:
            async with async_session() as session:
                result = await self.lines(
                    row.subject_id,
                    row.episode,
                    session,
                    title=row.title,
                    force=True,
                )
            refreshed += 1
            if result:
                playable += 1
        return {"refreshed": refreshed, "playable": playable}


playback_service = PlaybackService()
