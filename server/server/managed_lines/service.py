"""Managed line lifecycle behind one small administrator-facing interface."""

from __future__ import annotations

import secrets
import time
from collections.abc import Callable
from dataclasses import replace

from sqlalchemy.ext.asyncio import AsyncSession

from ..catalog import parse_stable_id
from ..config import (
    MANAGED_PLAYBACK_LINES_PROBE_TIMEOUT_SECONDS,
    MANAGED_PLAYBACK_LINES_REQUIRE_APPROVAL,
)
from .repository import (
    ManagedLineRecord,
    ManagedLineRepository,
    SqlManagedLineRepository,
)
from .schemas import ManagedLineCreate, ManagedLineUpdate
from .validation import (
    ManagedLineVerifier,
    ManagedLineValidationError,
    PublicMediaUrlPolicy,
    validate_managed_headers,
)


_PUBLISHABLE_VERIFICATION_STATUSES = {
    "server_verified",
    "client_probe_required",
}


class ManagedLineNotFoundError(LookupError):
    pass


class ManagedLineInputError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class ManagedLineStateError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _new_line_id() -> str:
    return f"mpl_{secrets.token_urlsafe(18)}"


class ManagedLineService:
    def __init__(
        self,
        *,
        repository_factory: Callable[[AsyncSession], ManagedLineRepository] = (
            SqlManagedLineRepository
        ),
        url_policy: PublicMediaUrlPolicy | None = None,
        verifier: ManagedLineVerifier | None = None,
        require_approval: bool = MANAGED_PLAYBACK_LINES_REQUIRE_APPROVAL,
        clock: Callable[[], float] = time.time,
        id_factory: Callable[[], str] = _new_line_id,
    ) -> None:
        self._repository_factory = repository_factory
        self._url_policy = url_policy or PublicMediaUrlPolicy()
        self._verifier = verifier or ManagedLineVerifier(
            url_policy=self._url_policy,
            timeout_seconds=MANAGED_PLAYBACK_LINES_PROBE_TIMEOUT_SECONDS,
        )
        self._require_approval = require_approval
        self._clock = clock
        self._id_factory = id_factory

    async def create(
        self,
        session: AsyncSession,
        data: ManagedLineCreate,
    ) -> ManagedLineRecord:
        record = await self._prepare_record(data)
        return await self._repository_factory(session).add(record)

    async def _prepare_record(
        self,
        data: ManagedLineCreate,
    ) -> ManagedLineRecord:
        stable_id = data.stable_id.strip().lower()
        self._validate_identity_episode(stable_id, data.episode)
        canonical_url = await self._url_policy.validate(
            data.canonical_url,
            format_hint=data.format_hint,
        )
        headers = validate_managed_headers(data.headers)
        rights_reference = data.rights_reference.strip()
        if not rights_reference:
            raise ManagedLineInputError(
                "rights_reference_required",
                "管理线路必须填写授权或来源审核记录",
            )
        now = self._clock()
        record = ManagedLineRecord(
            id=self._id_factory(),
            stable_id=stable_id,
            episode=data.episode,
            provider_key=data.provider_key.strip().lower(),
            label=data.label.strip() or "管理线路",
            quality=data.quality.strip(),
            format_hint=data.format_hint.strip().lower(),
            canonical_url=canonical_url,
            url_kind="static_direct",
            expires_at=data.expires_at,
            headers=headers,
            priority=data.priority,
            status="draft",
            review_status="pending",
            enabled=False,
            provenance_kind=data.provenance_kind,
            rights_reference=rights_reference,
            operator_note=data.operator_note.strip(),
            last_verified_status="unverified",
            last_verified_at=0.0,
            last_error_category="",
            last_latency_ms=0,
            created_at=now,
            updated_at=now,
            published_at=0.0,
            revoked_at=0.0,
        )
        return record

    async def import_many(
        self,
        session: AsyncSession,
        items: list[ManagedLineCreate],
    ) -> list[ManagedLineRecord]:
        records = [await self._prepare_record(item) for item in items]
        return await self._repository_factory(session).add_many(records)

    async def list(
        self,
        session: AsyncSession,
        *,
        stable_id: str | None = None,
        episode: int | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[ManagedLineRecord]:
        normalized_stable_id = stable_id.strip().lower() if stable_id else None
        if normalized_stable_id and parse_stable_id(normalized_stable_id) is None:
            raise ManagedLineInputError("invalid_stable_id", "作品 ID 格式不正确")
        return await self._repository_factory(session).list(
            stable_id=normalized_stable_id,
            episode=episode,
            limit=limit,
            offset=offset,
        )

    async def playback_lines(
        self,
        session: AsyncSession,
        *,
        stable_id: str,
        episode: int,
        limit: int,
    ) -> list[dict]:
        records = await self._repository_factory(session).publishable(
            stable_id=stable_id,
            episode=episode,
            now=self._clock(),
            limit=limit,
        )
        return [self._public_playback_line(record) for record in records]

    @staticmethod
    def _public_playback_line(record: ManagedLineRecord) -> dict:
        normalized_format = record.format_hint.strip().lower()
        if normalized_format == "m3u8":
            normalized_format = "hls"
        elif normalized_format == "mpd":
            normalized_format = "dash"
        server_verified = record.last_verified_status == "server_verified"
        provider_segment = record.provider_key.removeprefix("managed.") or "main"
        return {
            "line_id": record.id,
            "url": record.canonical_url,
            "title": record.label or "Zeluna 管理线路",
            "quality": record.quality,
            "format": normalized_format,
            "source": f"managed:{provider_segment}:{record.id}",
            "provider_id": "managed.urls",
            "provider_name": "Zeluna 管理线路",
            "origin_kind": "managed",
            "headers": dict(record.headers),
            "available": server_verified,
            "status": record.last_verified_status,
            "expires_at": int(record.expires_at) if record.expires_at > 0 else 0,
            "verified_at": int(record.last_verified_at),
            "startup_profile": (
                "hls" if normalized_format == "hls" else "unknown"
            ),
            "startup_latency_ms": record.last_latency_ms,
            "message": (
                "在线服务已确认可播"
                if server_verified
                else "服务器出口受限，等待客户端完成清单和首段验证"
            ),
            "cached": False,
            "stale": False,
            "cache_state": "managed",
        }

    async def get(
        self,
        session: AsyncSession,
        line_id: str,
    ) -> ManagedLineRecord:
        record = await self._repository_factory(session).get(line_id)
        if record is None:
            raise ManagedLineNotFoundError(line_id)
        return record

    async def update(
        self,
        session: AsyncSession,
        line_id: str,
        data: ManagedLineUpdate,
    ) -> ManagedLineRecord:
        record = await self.get(session, line_id)
        self._ensure_not_revoked(record)
        raw_changes = data.model_dump(exclude_unset=True)
        if not raw_changes:
            return record
        if any(value is None for value in raw_changes.values()):
            raise ManagedLineInputError(
                "null_field", "更新字段不能使用 null，请省略不需要修改的字段"
            )

        stable_id = str(raw_changes.get("stable_id", record.stable_id)).strip().lower()
        episode = int(raw_changes.get("episode", record.episode))
        self._validate_identity_episode(stable_id, episode)
        format_hint = str(
            raw_changes.get("format_hint", record.format_hint)
        ).strip().lower()
        canonical_url = await self._url_policy.validate(
            str(raw_changes.get("canonical_url", record.canonical_url)),
            format_hint=format_hint,
        )
        headers = validate_managed_headers(
            raw_changes.get("headers", record.headers)
        )
        rights_reference = str(
            raw_changes.get("rights_reference", record.rights_reference)
        ).strip()
        if not rights_reference:
            raise ManagedLineInputError(
                "rights_reference_required",
                "管理线路必须填写授权或来源审核记录",
            )
        source_changed = bool(
            set(raw_changes)
            & {
                "stable_id",
                "episode",
                "provider_key",
                "format_hint",
                "canonical_url",
                "expires_at",
                "headers",
                "provenance_kind",
                "rights_reference",
            }
        )
        now = self._clock()
        updated = replace(
            record,
            stable_id=stable_id,
            episode=episode,
            provider_key=str(
                raw_changes.get("provider_key", record.provider_key)
            ).strip().lower(),
            label=str(raw_changes.get("label", record.label)).strip()
            or "管理线路",
            quality=str(raw_changes.get("quality", record.quality)).strip(),
            format_hint=format_hint,
            canonical_url=canonical_url,
            expires_at=float(raw_changes.get("expires_at", record.expires_at)),
            headers=headers,
            priority=int(raw_changes.get("priority", record.priority)),
            provenance_kind=str(
                raw_changes.get("provenance_kind", record.provenance_kind)
            ),
            rights_reference=rights_reference,
            operator_note=str(
                raw_changes.get("operator_note", record.operator_note)
            ).strip(),
            status="draft" if source_changed else record.status,
            review_status="pending" if source_changed else record.review_status,
            enabled=False if source_changed else record.enabled,
            last_verified_status=(
                "unverified" if source_changed else record.last_verified_status
            ),
            last_verified_at=0.0 if source_changed else record.last_verified_at,
            last_error_category=("" if source_changed else record.last_error_category),
            last_latency_ms=0 if source_changed else record.last_latency_ms,
            published_at=0.0 if source_changed else record.published_at,
            updated_at=now,
        )
        saved = await self._repository_factory(session).save(updated)
        if saved is None:
            raise ManagedLineNotFoundError(line_id)
        return saved

    async def verify(
        self,
        session: AsyncSession,
        line_id: str,
    ) -> ManagedLineRecord:
        record = await self.get(session, line_id)
        if record.status == "revoked":
            raise ManagedLineStateError(
                "line_revoked", "已撤销的管理线路不能重新验线"
            )
        now = self._clock()
        try:
            result = await self._verifier.verify(
                record.canonical_url,
                format_hint=record.format_hint,
                headers=record.headers,
            )
        except ManagedLineValidationError as error:
            quarantined = replace(
                record,
                status="quarantined",
                enabled=False,
                last_verified_status="unavailable",
                last_verified_at=now,
                last_error_category=error.code,
                last_latency_ms=0,
                updated_at=now,
            )
            await self._repository_factory(session).save(quarantined)
            raise

        verified = result.status in _PUBLISHABLE_VERIFICATION_STATUSES
        review_status = record.review_status
        if verified and not self._require_approval:
            review_status = "approved"
        status = (
            "active"
            if verified and review_status == "approved"
            else "draft"
            if verified
            else "degraded"
        )
        updated = replace(
            record,
            status=status,
            review_status=review_status,
            enabled=(record.enabled if status == "active" else False),
            last_verified_status=result.status,
            last_verified_at=now,
            last_error_category=result.error_category,
            last_latency_ms=result.latency_ms,
            updated_at=now,
        )
        saved = await self._repository_factory(session).save(updated)
        if saved is None:
            raise ManagedLineNotFoundError(line_id)
        return saved

    async def approve(
        self,
        session: AsyncSession,
        line_id: str,
    ) -> ManagedLineRecord:
        record = await self.get(session, line_id)
        self._ensure_not_revoked(record)
        self._ensure_current_verification(record)
        now = self._clock()
        updated = replace(
            record,
            status="active",
            review_status="approved",
            updated_at=now,
        )
        return await self._save_existing(session, updated)

    async def enable(
        self,
        session: AsyncSession,
        line_id: str,
    ) -> ManagedLineRecord:
        record = await self.get(session, line_id)
        self._ensure_not_revoked(record)
        self._ensure_current_verification(record)
        if record.review_status != "approved" or record.status != "active":
            raise ManagedLineStateError(
                "approval_required", "管理线路必须先完成审核批准"
            )
        now = self._clock()
        updated = replace(
            record,
            enabled=True,
            published_at=record.published_at or now,
            updated_at=now,
        )
        return await self._save_existing(session, updated)

    async def disable(
        self,
        session: AsyncSession,
        line_id: str,
    ) -> ManagedLineRecord:
        record = await self.get(session, line_id)
        if not record.enabled:
            return record
        return await self._save_existing(
            session,
            replace(record, enabled=False, updated_at=self._clock()),
        )

    async def revoke(
        self,
        session: AsyncSession,
        line_id: str,
    ) -> ManagedLineRecord:
        record = await self.get(session, line_id)
        if record.status == "revoked":
            return record
        now = self._clock()
        return await self._save_existing(
            session,
            replace(
                record,
                status="revoked",
                enabled=False,
                revoked_at=now,
                updated_at=now,
            ),
        )

    def _ensure_not_revoked(self, record: ManagedLineRecord) -> None:
        if record.status == "revoked":
            raise ManagedLineStateError(
                "line_revoked", "已撤销的管理线路不能重新发布"
            )

    @staticmethod
    def _validate_identity_episode(stable_id: str, episode: int) -> None:
        identity = parse_stable_id(stable_id)
        if identity is None:
            raise ManagedLineInputError("invalid_stable_id", "作品 ID 格式不正确")
        if identity[1] == "movie" and episode != 1:
            raise ManagedLineInputError("movie_episode", "电影管理线路的集数必须为 1")

    def _ensure_current_verification(self, record: ManagedLineRecord) -> None:
        now = self._clock()
        if record.last_verified_status not in _PUBLISHABLE_VERIFICATION_STATUSES:
            raise ManagedLineStateError(
                "verification_required", "管理线路必须先完成可发布验线"
            )
        if record.expires_at > 0 and record.expires_at <= now + 15:
            raise ManagedLineStateError("line_expired", "管理线路地址已经过期")

    async def _save_existing(
        self,
        session: AsyncSession,
        record: ManagedLineRecord,
    ) -> ManagedLineRecord:
        saved = await self._repository_factory(session).save(record)
        if saved is None:
            raise ManagedLineNotFoundError(record.id)
        return saved


managed_line_service = ManagedLineService()


__all__ = [
    "ManagedLineInputError",
    "ManagedLineNotFoundError",
    "ManagedLineStateError",
    "ManagedLineService",
    "ManagedLineValidationError",
    "managed_line_service",
]
