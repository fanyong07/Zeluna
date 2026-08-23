"""Persistence interface and SQLAlchemy adapter for managed playback lines."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import ManagedPlaybackLine


@dataclass(frozen=True)
class ManagedLineRecord:
    id: str
    stable_id: str
    episode: int
    provider_key: str
    label: str
    quality: str
    format_hint: str
    canonical_url: str
    url_kind: str
    expires_at: float
    headers: dict[str, str]
    priority: int
    status: str
    review_status: str
    enabled: bool
    provenance_kind: str
    rights_reference: str
    operator_note: str
    last_verified_status: str
    last_verified_at: float
    last_error_category: str
    last_latency_ms: int
    created_at: float
    updated_at: float
    published_at: float
    revoked_at: float


class ManagedLineRepository(Protocol):
    async def add(self, record: ManagedLineRecord) -> ManagedLineRecord: ...

    async def add_many(
        self,
        records: list[ManagedLineRecord],
    ) -> list[ManagedLineRecord]: ...

    async def get(self, line_id: str) -> ManagedLineRecord | None: ...

    async def save(self, record: ManagedLineRecord) -> ManagedLineRecord | None: ...

    async def list(
        self,
        *,
        stable_id: str | None = None,
        episode: int | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[ManagedLineRecord]: ...

    async def publishable(
        self,
        *,
        stable_id: str,
        episode: int,
        now: float,
        limit: int,
    ) -> list[ManagedLineRecord]: ...


def _headers_from_json(value: str) -> dict[str, str]:
    try:
        decoded = json.loads(value)
    except (json.JSONDecodeError, TypeError):
        return {}
    if not isinstance(decoded, dict):
        return {}
    return {
        str(name): str(header_value)
        for name, header_value in decoded.items()
        if str(name).strip() and str(header_value).strip()
    }


def _record(row: ManagedPlaybackLine) -> ManagedLineRecord:
    return ManagedLineRecord(
        id=row.id,
        stable_id=row.stable_id,
        episode=row.episode,
        provider_key=row.provider_key,
        label=row.label,
        quality=row.quality,
        format_hint=row.format_hint,
        canonical_url=row.canonical_url,
        url_kind=row.url_kind,
        expires_at=row.expires_at,
        headers=_headers_from_json(row.headers_json),
        priority=row.priority,
        status=row.status,
        review_status=row.review_status,
        enabled=row.enabled,
        provenance_kind=row.provenance_kind,
        rights_reference=row.rights_reference,
        operator_note=row.operator_note,
        last_verified_status=row.last_verified_status,
        last_verified_at=row.last_verified_at,
        last_error_category=row.last_error_category,
        last_latency_ms=row.last_latency_ms,
        created_at=row.created_at,
        updated_at=row.updated_at,
        published_at=row.published_at,
        revoked_at=row.revoked_at,
    )


def _apply(row: ManagedPlaybackLine, record: ManagedLineRecord) -> None:
    row.stable_id = record.stable_id
    row.episode = record.episode
    row.provider_key = record.provider_key
    row.label = record.label
    row.quality = record.quality
    row.format_hint = record.format_hint
    row.canonical_url = record.canonical_url
    row.url_kind = record.url_kind
    row.expires_at = record.expires_at
    row.headers_json = json.dumps(
        record.headers,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    row.priority = record.priority
    row.status = record.status
    row.review_status = record.review_status
    row.enabled = record.enabled
    row.provenance_kind = record.provenance_kind
    row.rights_reference = record.rights_reference
    row.operator_note = record.operator_note
    row.last_verified_status = record.last_verified_status
    row.last_verified_at = record.last_verified_at
    row.last_error_category = record.last_error_category
    row.last_latency_ms = record.last_latency_ms
    row.created_at = record.created_at
    row.updated_at = record.updated_at
    row.published_at = record.published_at
    row.revoked_at = record.revoked_at


class SqlManagedLineRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def add(self, record: ManagedLineRecord) -> ManagedLineRecord:
        return (await self.add_many([record]))[0]

    async def add_many(
        self,
        records: list[ManagedLineRecord],
    ) -> list[ManagedLineRecord]:
        rows: list[ManagedPlaybackLine] = []
        for record in records:
            row = ManagedPlaybackLine(id=record.id)
            _apply(row, record)
            rows.append(row)
        self._session.add_all(rows)
        try:
            await self._session.commit()
        except Exception:
            await self._session.rollback()
            raise
        return [_record(row) for row in rows]

    async def get(self, line_id: str) -> ManagedLineRecord | None:
        row = await self._session.get(ManagedPlaybackLine, line_id)
        return _record(row) if row is not None else None

    async def save(self, record: ManagedLineRecord) -> ManagedLineRecord | None:
        row = await self._session.get(ManagedPlaybackLine, record.id)
        if row is None:
            return None
        _apply(row, record)
        await self._session.commit()
        return _record(row)

    async def list(
        self,
        *,
        stable_id: str | None = None,
        episode: int | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[ManagedLineRecord]:
        query = select(ManagedPlaybackLine)
        if stable_id is not None:
            query = query.where(ManagedPlaybackLine.stable_id == stable_id)
        if episode is not None:
            query = query.where(ManagedPlaybackLine.episode == episode)
        rows = (
            await self._session.scalars(
                query.order_by(
                    ManagedPlaybackLine.priority.desc(),
                    ManagedPlaybackLine.created_at.desc(),
                    ManagedPlaybackLine.id.asc(),
                )
                .offset(max(0, offset))
                .limit(max(1, limit))
            )
        ).all()
        return [_record(row) for row in rows]

    async def publishable(
        self,
        *,
        stable_id: str,
        episode: int,
        now: float,
        limit: int,
    ) -> list[ManagedLineRecord]:
        rows = (
            await self._session.scalars(
                select(ManagedPlaybackLine)
                .where(
                    ManagedPlaybackLine.stable_id == stable_id,
                    ManagedPlaybackLine.episode == episode,
                    ManagedPlaybackLine.enabled.is_(True),
                    ManagedPlaybackLine.status == "active",
                    ManagedPlaybackLine.review_status == "approved",
                    ManagedPlaybackLine.last_verified_status.in_(
                        ("server_verified", "client_probe_required")
                    ),
                    (
                        (ManagedPlaybackLine.expires_at <= 0)
                        | (ManagedPlaybackLine.expires_at > now + 15)
                    ),
                )
                .order_by(
                    ManagedPlaybackLine.priority.desc(),
                    ManagedPlaybackLine.last_latency_ms.asc(),
                    ManagedPlaybackLine.updated_at.desc(),
                    ManagedPlaybackLine.id.asc(),
                )
                .limit(max(1, limit))
            )
        ).all()
        return [_record(row) for row in rows]
