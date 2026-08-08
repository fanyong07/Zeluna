"""Conflict resolution and idempotency for local-first cloud synchronization."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

from pydantic import TypeAdapter

from .database import SyncRecord
from .sync_contracts import (
    AppearanceSettingsMutation,
    HistoryMutation,
    LibraryPayload,
    PlaybackPositionMutation,
    PlaybackPositionPayload,
    PlaybackSettingsMutation,
    SyncMutationRequest,
)
from .sync_repository import SyncRepository, utc_timestamp


class SyncMutationConflict(Exception):
    """The same account reused an idempotency key for different content."""


@dataclass(frozen=True)
class SyncPushResult:
    records: list[dict[str, Any]]
    next_revision: int


class SyncService:
    def __init__(self, repository: SyncRepository):
        self._repository = repository

    async def push(
        self, user_id: int, mutations: list[SyncMutationRequest]
    ) -> SyncPushResult:
        results: list[dict[str, Any]] = []
        next_revision = 0
        for mutation in mutations:
            self._validate_identity(mutation)
            digest = _mutation_hash(mutation)
            receipt = await self._repository.get_mutation(
                user_id, mutation.mutation_id
            )
            if receipt is not None:
                if receipt.payload_hash != digest:
                    raise SyncMutationConflict(
                        "mutationId was already used for different content"
                    )
                record = await self._repository.get_record(
                    user_id, receipt.record_type, receipt.record_id
                )
                if record is None:
                    raise RuntimeError("sync mutation receipt has no record")
                results.append(_record_payload(record))
                next_revision = max(next_revision, record.revision)
                continue

            existing = await self._repository.get_record(
                user_id, mutation.type, mutation.record_id
            )
            payload, deleted, changed = _resolve(existing, mutation)
            now = utc_timestamp()
            if changed:
                revision = await self._repository.allocate_revision(user_id, now=now)
                record = await self._repository.save_record(
                    existing=existing,
                    user_id=user_id,
                    record_id=mutation.record_id,
                    record_type=mutation.type,
                    schema_version=mutation.schema_version,
                    payload_json=_canonical_json(payload),
                    deleted=deleted,
                    mutation_id=mutation.mutation_id,
                    revision=revision,
                    now=now,
                )
            else:
                if existing is None:
                    raise RuntimeError("unchanged sync mutation has no existing record")
                record = existing
                revision = existing.revision
            await self._repository.add_mutation_receipt(
                user_id=user_id,
                mutation_id=mutation.mutation_id,
                payload_hash=digest,
                record_id=mutation.record_id,
                record_type=mutation.type,
                revision=revision,
                now=now,
            )
            results.append(_record_payload(record))
            next_revision = max(next_revision, record.revision)

        await self._repository.commit()
        return SyncPushResult(records=results, next_revision=next_revision)

    async def pull(
        self, user_id: int, *, after_revision: int, limit: int
    ) -> dict[str, Any]:
        records, has_more = await self._repository.pull_records(
            user_id=user_id,
            after_revision=after_revision,
            limit=limit,
        )
        return {
            "records": [_record_payload(item) for item in records],
            "next_revision": records[-1].revision if records else after_revision,
            "has_more": has_more,
        }

    @staticmethod
    def _validate_identity(mutation: SyncMutationRequest) -> None:
        if isinstance(mutation, AppearanceSettingsMutation):
            expected = "settings:appearance"
        elif isinstance(mutation, PlaybackSettingsMutation):
            expected = "settings:playback"
        elif isinstance(mutation, PlaybackPositionMutation):
            expected = mutation.payload.episode.stable_key
        else:
            expected = mutation.payload.subject.stable_key
        if mutation.record_id != expected:
            raise ValueError("recordId does not match the stable payload identity")


def _resolve(
    existing: SyncRecord | None, mutation: SyncMutationRequest
) -> tuple[dict[str, Any], bool, bool]:
    incoming = mutation.payload.model_dump(mode="json", by_alias=True)
    if existing is None or mutation.deleted or existing.deleted:
        return incoming, mutation.deleted, True
    if isinstance(mutation, HistoryMutation):
        current = TypeAdapter(LibraryPayload).validate_json(existing.payload_json)
        latest = mutation.payload
        if current.updated_at > latest.updated_at:
            selected = current
        else:
            selected = latest
        merged = selected.model_copy(
            update={
                "position_seconds": max(
                    current.position_seconds, latest.position_seconds
                ),
                "duration_seconds": max(
                    current.duration_seconds, latest.duration_seconds
                ),
            }
        )
        return merged.model_dump(mode="json", by_alias=True), False, True
    if isinstance(mutation, PlaybackPositionMutation):
        current = TypeAdapter(PlaybackPositionPayload).validate_json(
            existing.payload_json
        )
        incoming_time = mutation.payload.updated_at
        current_time = current.updated_at
        if incoming_time < current_time:
            return json.loads(existing.payload_json), False, False
        if incoming_time == current_time:
            if current.completed and not mutation.payload.completed:
                return json.loads(existing.payload_json), False, False
            if current.completed == mutation.payload.completed:
                selected = mutation.payload.model_copy(
                    update={
                        "position_seconds": max(
                            current.position_seconds,
                            mutation.payload.position_seconds,
                        ),
                        "duration_seconds": max(
                            current.duration_seconds,
                            mutation.payload.duration_seconds,
                        ),
                    }
                )
                return selected.model_dump(mode="json", by_alias=True), False, True
        return incoming, False, True
    return incoming, mutation.deleted, True


def _mutation_hash(mutation: SyncMutationRequest) -> str:
    canonical = _canonical_json(mutation.model_dump(mode="json", by_alias=True))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _canonical_json(payload: dict[str, Any]) -> str:
    return json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def _record_payload(record: SyncRecord) -> dict[str, Any]:
    return {
        "account_id": str(record.user_id),
        "record_id": record.record_id,
        "type": record.record_type,
        "schema_version": record.schema_version,
        "payload": json.loads(record.payload_json),
        "created_at": record.created_at,
        "updated_at": record.updated_at,
        "deleted": record.deleted,
        "client_mutation_id": record.last_mutation_id,
        "server_revision": record.revision,
    }
