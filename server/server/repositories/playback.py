"""Playback cache persistence contract and SQLAlchemy implementation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import (
    PlaybackCache,
    SourceBinding,
    SourceHealth,
    upsert_playback_cache,
)
from ..playback_health import SourceFailureScope


@dataclass(frozen=True)
class PlaybackCacheEntry:
    subject_id: str
    episode: int
    title: str
    lines_json: str
    line_count: int
    verified_at: float


@dataclass(frozen=True)
class SourceBindingEntry:
    stable_id: str
    source_id: str
    source_name: str
    matched_title: str
    media_type: str
    year: int
    score: int
    episode_count: int
    enabled: bool
    success_count: int
    failure_count: int
    last_success_at: float
    last_failure_at: float
    updated_at: float


@dataclass(frozen=True)
class SourceBindingWrite:
    source_id: str
    source_name: str
    matched_title: str
    media_type: str
    year: int
    score: int
    episode_count: int


@dataclass(frozen=True)
class SourceHealthEntry:
    source_name: str
    success_count: int
    failure_count: int
    consecutive_failures: int
    last_status: str
    last_error_category: str
    last_checked_at: float
    last_success_at: float
    last_failure_at: float
    latency_ms: int
    recent_success_rate: float


@dataclass(frozen=True)
class SourceHealthObservation:
    source_name: str
    status: str
    latency_ms: int
    error_category: str
    failure_scope: SourceFailureScope = SourceFailureScope.PROVIDER


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

    async def load_bindings(
        self,
        *,
        stable_id: str,
        updated_after: float,
    ) -> list[SourceBindingEntry]: ...

    async def load_source_health(self) -> dict[str, SourceHealthEntry]: ...

    async def upsert_bindings(
        self,
        *,
        stable_id: str,
        bindings: list[SourceBindingWrite],
        updated_at: float,
    ) -> None: ...

    async def record_health(
        self,
        *,
        stable_id: str,
        observations: list[SourceHealthObservation],
        checked_at: float,
        ema_alpha: float,
        deterministic_failures: frozenset[str],
        server_verified_status: str,
        client_probe_status: str,
        unavailable_status: str,
        unknown_error_category: str,
    ) -> None: ...


def _cache_entry(row: PlaybackCache) -> PlaybackCacheEntry:
    return PlaybackCacheEntry(
        subject_id=row.subject_id,
        episode=row.episode,
        title=row.title,
        lines_json=row.lines_json,
        line_count=row.line_count,
        verified_at=row.verified_at,
    )


def _binding_entry(row: SourceBinding) -> SourceBindingEntry:
    return SourceBindingEntry(
        stable_id=row.stable_id,
        source_id=row.source_id,
        source_name=row.source_name,
        matched_title=row.matched_title,
        media_type=row.media_type,
        year=row.year,
        score=row.score,
        episode_count=row.episode_count,
        enabled=row.enabled,
        success_count=row.success_count,
        failure_count=row.failure_count,
        last_success_at=row.last_success_at,
        last_failure_at=row.last_failure_at,
        updated_at=row.updated_at,
    )


def _health_entry(row: SourceHealth) -> SourceHealthEntry:
    return SourceHealthEntry(
        source_name=row.source_name,
        success_count=row.success_count,
        failure_count=row.failure_count,
        consecutive_failures=row.consecutive_failures,
        last_status=row.last_status,
        last_error_category=row.last_error_category,
        last_checked_at=row.last_checked_at,
        last_success_at=row.last_success_at,
        last_failure_at=row.last_failure_at,
        latency_ms=row.latency_ms,
        recent_success_rate=row.recent_success_rate,
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

    async def load_bindings(
        self,
        *,
        stable_id: str,
        updated_after: float,
    ) -> list[SourceBindingEntry]:
        rows = (
            await self._session.scalars(
                select(SourceBinding).where(
                    SourceBinding.stable_id == stable_id,
                    SourceBinding.updated_at >= updated_after,
                )
            )
        ).all()
        return [_binding_entry(row) for row in rows]

    async def load_source_health(self) -> dict[str, SourceHealthEntry]:
        rows = (await self._session.scalars(select(SourceHealth))).all()
        return {row.source_name: _health_entry(row) for row in rows}

    async def upsert_bindings(
        self,
        *,
        stable_id: str,
        bindings: list[SourceBindingWrite],
        updated_at: float,
    ) -> None:
        for binding in bindings:
            row = await self._session.scalar(
                select(SourceBinding).where(
                    SourceBinding.stable_id == stable_id,
                    SourceBinding.source_id == binding.source_id,
                )
            )
            if row is None:
                row = SourceBinding(
                    stable_id=stable_id,
                    source_id=binding.source_id,
                    source_name=binding.source_name,
                )
                self._session.add(row)
            row.matched_title = binding.matched_title
            row.media_type = binding.media_type
            row.year = binding.year
            row.score = binding.score
            row.episode_count = binding.episode_count
            row.enabled = True
            row.updated_at = updated_at
        await self._session.commit()

    async def record_health(
        self,
        *,
        stable_id: str,
        observations: list[SourceHealthObservation],
        checked_at: float,
        ema_alpha: float,
        deterministic_failures: frozenset[str],
        server_verified_status: str,
        client_probe_status: str,
        unavailable_status: str,
        unknown_error_category: str,
    ) -> None:
        for observation in observations:
            binding_rows = (
                await self._session.scalars(
                    select(SourceBinding).where(
                        SourceBinding.stable_id == stable_id,
                        SourceBinding.source_name == observation.source_name,
                    )
                )
            ).all()
            for row in binding_rows:
                if observation.status == server_verified_status:
                    row.success_count += 1
                    row.last_success_at = checked_at
                elif observation.status == unavailable_status:
                    row.failure_count += 1
                    row.last_failure_at = checked_at
                row.enabled = True

            if (
                observation.status == unavailable_status
                and observation.failure_scope != SourceFailureScope.PROVIDER
            ):
                # Route/media failures belong to this work binding. They must
                # not open or extend the provider-level circuit.
                continue

            source = await self._session.scalar(
                select(SourceHealth).where(
                    SourceHealth.source_name == observation.source_name
                )
            )
            if source is None:
                source = SourceHealth(
                    source_name=observation.source_name,
                    success_count=0,
                    failure_count=0,
                    consecutive_failures=0,
                    last_status="unknown",
                    last_error_category="",
                    last_checked_at=0.0,
                    last_success_at=0.0,
                    last_failure_at=0.0,
                    latency_ms=0,
                    recent_success_rate=0.5,
                )
                self._session.add(source)
            source.last_checked_at = checked_at
            if observation.latency_ms > 0:
                source.latency_ms = (
                    observation.latency_ms
                    if not source.latency_ms
                    else round(
                        source.latency_ms * (1 - ema_alpha)
                        + observation.latency_ms * ema_alpha
                    )
                )
            current_rate = source.recent_success_rate
            if current_rate is None:
                current_rate = 0.5
            if observation.status == server_verified_status:
                source.success_count += 1
                source.consecutive_failures = 0
                source.last_status = "healthy"
                source.last_error_category = ""
                source.last_success_at = checked_at
                target_rate = 1.0
            elif observation.status == client_probe_status:
                source.consecutive_failures = 0
                source.last_status = client_probe_status
                source.last_error_category = observation.error_category
                target_rate = 0.65
            else:
                source.failure_count += 1
                source.consecutive_failures += (
                    2 if observation.error_category in deterministic_failures else 1
                )
                source.last_status = "unhealthy"
                source.last_error_category = (
                    observation.error_category or unknown_error_category
                )
                source.last_failure_at = checked_at
                target_rate = 0.0
            source.recent_success_rate = (
                current_rate * (1 - ema_alpha) + target_rate * ema_alpha
            )
        await self._session.commit()
