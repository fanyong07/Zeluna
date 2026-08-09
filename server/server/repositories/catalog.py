"""Catalog cache persistence contract and SQLAlchemy implementation."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Protocol

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import CatalogSubject


@dataclass(frozen=True)
class CatalogCacheEntry:
    metadata: dict
    updated_at: float


@dataclass(frozen=True)
class CatalogWrite:
    stable_id: str
    provider: str
    provider_id: str
    media_type: str
    title: str
    original_title: str
    aliases_json: str
    metadata_json: str
    popularity: float
    updated_at: float
    ranking_json: str | None = None
    ranking_score: float | None = None
    ranked_at: float | None = None


class CatalogRepository(Protocol):
    async def search_cached(
        self,
        *,
        query: str,
        fresh_after: float,
        limit: int,
    ) -> list[dict]: ...

    async def home_cached(
        self,
        *,
        media_type: str,
        fresh_after: float,
        limit: int,
    ) -> list[dict]: ...

    async def get_cached(self, stable_id: str) -> CatalogCacheEntry | None: ...

    async def persist_many(self, entries: list[CatalogWrite]) -> None: ...


def _metadata(value: str) -> dict | None:
    try:
        parsed = json.loads(value)
    except (json.JSONDecodeError, TypeError):
        return None
    return parsed if isinstance(parsed, dict) else None


class SqlCatalogRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def search_cached(
        self,
        *,
        query: str,
        fresh_after: float,
        limit: int,
    ) -> list[dict]:
        rows = (
            await self._session.scalars(
                select(CatalogSubject)
                .where(
                    CatalogSubject.updated_at >= fresh_after,
                    or_(
                        CatalogSubject.title.contains(query),
                        CatalogSubject.original_title.contains(query),
                    ),
                )
                .order_by(CatalogSubject.popularity.desc())
                .limit(limit)
            )
        ).all()
        return [
            item
            for row in rows
            if (item := _metadata(row.metadata_json)) is not None
        ]

    async def home_cached(
        self,
        *,
        media_type: str,
        fresh_after: float,
        limit: int,
    ) -> list[dict]:
        rows = (
            await self._session.scalars(
                select(CatalogSubject)
                .where(
                    CatalogSubject.media_type == media_type,
                    CatalogSubject.ranked_at >= fresh_after,
                )
                .order_by(
                    CatalogSubject.ranking_score.desc(),
                    CatalogSubject.popularity.desc(),
                    CatalogSubject.stable_id.asc(),
                )
                .limit(limit)
            )
        ).all()
        items: list[dict] = []
        for row in rows:
            item = _metadata(row.metadata_json)
            if item is None:
                continue
            ranking = _metadata(row.ranking_json)
            if ranking is not None:
                ranking.setdefault("globalScore", row.ranking_score)
                ranking.setdefault("rankedAt", row.ranked_at)
                item["ranking"] = ranking
            items.append(item)
        return items

    async def get_cached(self, stable_id: str) -> CatalogCacheEntry | None:
        row = await self._session.scalar(
            select(CatalogSubject).where(CatalogSubject.stable_id == stable_id)
        )
        if row is None or (metadata := _metadata(row.metadata_json)) is None:
            return None
        return CatalogCacheEntry(metadata=metadata, updated_at=row.updated_at)

    async def persist_many(self, entries: list[CatalogWrite]) -> None:
        if not entries:
            return
        for entry in entries:
            row = await self._session.scalar(
                select(CatalogSubject).where(
                    CatalogSubject.stable_id == entry.stable_id
                )
            )
            if row is None:
                row = CatalogSubject(
                    stable_id=entry.stable_id,
                    provider=entry.provider,
                    provider_id=entry.provider_id,
                    media_type=entry.media_type,
                    title=entry.title,
                )
                self._session.add(row)
            row.title = entry.title
            row.original_title = entry.original_title
            row.aliases_json = entry.aliases_json
            row.metadata_json = entry.metadata_json
            row.popularity = entry.popularity
            row.updated_at = entry.updated_at
            # Search and detail refreshes intentionally carry no ranking
            # payload. They may improve metadata, but must never make an item
            # look like a fresh home-ranking candidate.
            if entry.ranked_at is not None:
                row.ranking_json = entry.ranking_json or "{}"
                row.ranking_score = entry.ranking_score or 0.0
                row.ranked_at = entry.ranked_at
        await self._session.commit()
