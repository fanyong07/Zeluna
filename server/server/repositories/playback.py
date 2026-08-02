"""Playback cache persistence contract and SQLAlchemy implementation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import PlaybackCache, upsert_playback_cache


@dataclass(frozen=True)
class PlaybackCacheEntry:
    subject_id: str
    episode: int
    title: str
    lines_json: str
    line_count: int
    verified_at: float


class PlaybackRepository(Protocol):
    async def get_cache(
        self,
        subject_id: str,
        episode: int,
    ) -> PlaybackCacheEntry | None: ...

    async def upsert_cache(
        self,
        *,
        subject_id: str,
        episode: int,
        title: str,
        lines_json: str,
        line_count: int,
        verified_at: float,
    ) -> None: ...

    async def oldest_cache(self, *, limit: int) -> list[PlaybackCacheEntry]: ...


def _cache_entry(row: PlaybackCache) -> PlaybackCacheEntry:
    return PlaybackCacheEntry(
        subject_id=row.subject_id,
        episode=row.episode,
        title=row.title,
        lines_json=row.lines_json,
        line_count=row.line_count,
        verified_at=row.verified_at,
    )


class SqlPlaybackRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def get_cache(
        self,
        subject_id: str,
        episode: int,
    ) -> PlaybackCacheEntry | None:
        row = await self._session.scalar(
            select(PlaybackCache).where(
                PlaybackCache.subject_id == subject_id,
                PlaybackCache.episode == episode,
            )
        )
        return _cache_entry(row) if row is not None else None

    async def upsert_cache(
        self,
        *,
        subject_id: str,
        episode: int,
        title: str,
        lines_json: str,
        line_count: int,
        verified_at: float,
    ) -> None:
        await upsert_playback_cache(
            self._session,
            subject_id=subject_id,
            episode=episode,
            title=title,
            lines_json=lines_json,
            line_count=line_count,
            verified_at=verified_at,
        )

    async def oldest_cache(self, *, limit: int) -> list[PlaybackCacheEntry]:
        rows = (
            await self._session.scalars(
                select(PlaybackCache)
                .order_by(PlaybackCache.verified_at.asc())
                .limit(max(1, limit))
            )
        ).all()
        return [_cache_entry(row) for row in rows]
