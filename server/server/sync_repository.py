"""SQL persistence boundary for incremental account synchronization."""

from __future__ import annotations

import time

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import SyncMutation, SyncRecord, SyncRevision


class SyncRepository:
    def __init__(self, session: AsyncSession):
        self._session = session

    async def get_mutation(self, user_id: int, mutation_id: str) -> SyncMutation | None:
        return await self._session.scalar(
            select(SyncMutation).where(
                SyncMutation.user_id == user_id,
                SyncMutation.mutation_id == mutation_id,
            )
        )

    async def get_record(
        self, user_id: int, record_type: str, record_id: str
    ) -> SyncRecord | None:
        return await self._session.scalar(
            select(SyncRecord).where(
                SyncRecord.user_id == user_id,
                SyncRecord.record_type == record_type,
                SyncRecord.record_id == record_id,
            )
        )

    async def allocate_revision(self, user_id: int, *, now: float) -> int:
        revision = SyncRevision(user_id=user_id, created_at=now)
        self._session.add(revision)
        await self._session.flush()
        return revision.revision

    async def save_record(
        self,
        *,
        existing: SyncRecord | None,
        user_id: int,
        record_id: str,
        record_type: str,
        schema_version: int,
        payload_json: str,
        deleted: bool,
        mutation_id: str,
        revision: int,
        now: float,
    ) -> SyncRecord:
        if existing is None:
            record = SyncRecord(
                user_id=user_id,
                record_id=record_id,
                record_type=record_type,
                schema_version=schema_version,
                payload_json=payload_json,
                created_at=now,
                updated_at=now,
                deleted=deleted,
                last_mutation_id=mutation_id,
                revision=revision,
            )
            self._session.add(record)
        else:
            record = existing
            record.schema_version = schema_version
            record.payload_json = payload_json
            record.updated_at = now
            record.deleted = deleted
            record.last_mutation_id = mutation_id
            record.revision = revision
        await self._session.flush()
        return record

    async def add_mutation_receipt(
        self,
        *,
        user_id: int,
        mutation_id: str,
        payload_hash: str,
        record_id: str,
        record_type: str,
        revision: int,
        now: float,
    ) -> None:
        self._session.add(
            SyncMutation(
                user_id=user_id,
                mutation_id=mutation_id,
                payload_hash=payload_hash,
                record_id=record_id,
                record_type=record_type,
                revision=revision,
                created_at=now,
            )
        )
        await self._session.flush()

    async def pull_records(
        self,
        *,
        user_id: int,
        after_revision: int,
        limit: int,
    ) -> tuple[list[SyncRecord], bool]:
        rows = list(
            await self._session.scalars(
                select(SyncRecord)
                .where(
                    SyncRecord.user_id == user_id,
                    SyncRecord.revision > after_revision,
                )
                .order_by(SyncRecord.revision.asc(), SyncRecord.id.asc())
                .limit(limit + 1)
            )
        )
        return rows[:limit], len(rows) > limit

    async def commit(self) -> None:
        await self._session.commit()

    async def rollback(self) -> None:
        await self._session.rollback()


def utc_timestamp() -> float:
    return time.time()
