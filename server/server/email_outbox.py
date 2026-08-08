"""Encrypted, durable verification-email outbox and bounded worker."""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import time
from collections.abc import Awaitable, Callable
from typing import NamedTuple

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import and_, delete, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from .config import (
    EMAIL_OUTBOX_BATCH_SIZE,
    EMAIL_OUTBOX_ENCRYPTION_KEY,
    EMAIL_OUTBOX_MAX_ATTEMPTS,
    EMAIL_OUTBOX_PROCESSING_TIMEOUT_SECONDS,
    EMAIL_OUTBOX_RETRY_BASE_SECONDS,
    EMAIL_OUTBOX_WORKER_INTERVAL_SECONDS,
)
from .database import EmailOutbox
from .email_service import send_verification_email

logger = logging.getLogger(__name__)


class EmailOutboxConfigurationError(RuntimeError):
    pass


class _ClaimedItem(NamedTuple):
    id: int
    recipient: str
    encrypted_payload: str
    attempts: int
    claim_token: str


def _fernet() -> Fernet:
    key = EMAIL_OUTBOX_ENCRYPTION_KEY.strip()
    if not key:
        raise EmailOutboxConfigurationError(
            "EMAIL_OUTBOX_ENCRYPTION_KEY is not configured"
        )
    try:
        return Fernet(key.encode("ascii"))
    except (UnicodeEncodeError, ValueError, TypeError) as error:
        raise EmailOutboxConfigurationError(
            "EMAIL_OUTBOX_ENCRYPTION_KEY is invalid"
        ) from error


def encrypt_verification_payload(email: str, code: str, purpose: str) -> str:
    payload = json.dumps(
        {"email": email, "code": code, "purpose": purpose},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return _fernet().encrypt(payload).decode("ascii")


def decrypt_verification_payload(encrypted_payload: str) -> dict[str, str]:
    try:
        decoded = json.loads(_fernet().decrypt(encrypted_payload.encode("ascii")))
    except (UnicodeEncodeError, InvalidToken, ValueError, TypeError, json.JSONDecodeError) as error:
        raise EmailOutboxConfigurationError("email outbox payload is invalid") from error
    if not isinstance(decoded, dict):
        raise EmailOutboxConfigurationError("email outbox payload is invalid")
    values = {key: decoded.get(key) for key in ("email", "code", "purpose")}
    if not all(isinstance(value, str) and value for value in values.values()):
        raise EmailOutboxConfigurationError("email outbox payload is invalid")
    return values  # type: ignore[return-value]


async def queue_verification_email(
    session: AsyncSession,
    *,
    email: str,
    code: str,
    purpose: str,
    now: float | None = None,
    encrypted_payload: str | None = None,
) -> EmailOutbox:
    encrypted = encrypted_payload or encrypt_verification_payload(email, code, purpose)
    item = EmailOutbox(
        kind="verification",
        recipient=email,
        encrypted_payload=encrypted,
        status="pending",
        attempts=0,
        next_attempt_at=time.time() if now is None else now,
    )
    session.add(item)
    await session.flush()
    return item


class EmailOutboxWorker:
    def __init__(
        self,
        session_factory: async_sessionmaker[AsyncSession],
        *,
        sender: Callable[[str, str, str], Awaitable[None]] = send_verification_email,
        max_attempts: int = EMAIL_OUTBOX_MAX_ATTEMPTS,
        batch_size: int = EMAIL_OUTBOX_BATCH_SIZE,
        processing_timeout_seconds: int = EMAIL_OUTBOX_PROCESSING_TIMEOUT_SECONDS,
        retry_base_seconds: int = EMAIL_OUTBOX_RETRY_BASE_SECONDS,
        clock: Callable[[], float] = time.time,
    ):
        self._session_factory = session_factory
        self._sender = sender
        self._max_attempts = max(1, max_attempts)
        self._batch_size = max(1, batch_size)
        self._processing_timeout = max(60, processing_timeout_seconds)
        self._retry_base = max(5, retry_base_seconds)
        self._clock = clock

    async def _claim_one(self, session: AsyncSession) -> _ClaimedItem | None:
        now = self._clock()
        stale_before = now - self._processing_timeout
        eligible = or_(
            and_(
                EmailOutbox.status.in_(("pending", "retry")),
                EmailOutbox.next_attempt_at <= now,
            ),
            and_(
                EmailOutbox.status == "processing",
                EmailOutbox.locked_at <= stale_before,
            ),
        )
        candidate = (
            select(EmailOutbox.id)
            .where(eligible)
            .order_by(EmailOutbox.next_attempt_at.asc(), EmailOutbox.id.asc())
            .limit(1)
            .scalar_subquery()
        )
        claim_token = secrets.token_urlsafe(24)
        result = await session.execute(
            update(EmailOutbox)
            .where(EmailOutbox.id == candidate, eligible)
            .values(
                status="processing",
                claim_token=claim_token,
                locked_at=now,
            )
            .returning(
                EmailOutbox.id,
                EmailOutbox.recipient,
                EmailOutbox.encrypted_payload,
                EmailOutbox.attempts,
            )
        )
        row = result.one_or_none()
        await session.commit()
        if row is None:
            return None
        return _ClaimedItem(
            id=int(row.id),
            recipient=str(row.recipient),
            encrypted_payload=str(row.encrypted_payload),
            attempts=int(row.attempts),
            claim_token=claim_token,
        )

    async def _claim_batch(self) -> list[_ClaimedItem]:
        claimed: list[_ClaimedItem] = []
        async with self._session_factory() as session:
            for _ in range(self._batch_size):
                item = await self._claim_one(session)
                if item is None:
                    break
                claimed.append(item)
        return claimed

    async def _deliver(self, item: _ClaimedItem) -> str:
        now = self._clock()
        try:
            payload = decrypt_verification_payload(item.encrypted_payload)
            await self._sender(
                payload["email"], payload["code"], payload["purpose"]
            )
        except Exception as error:
            attempts = item.attempts + 1
            status = "retry" if attempts < self._max_attempts else "failed"
            retry_delay = self._retry_base * (2 ** min(attempts - 1, 6))
            error_code = _error_code(error)
            async with self._session_factory() as session:
                values = {
                    "status": status,
                    "attempts": attempts,
                    "next_attempt_at": now + retry_delay,
                    "last_error_code": error_code,
                    "locked_at": 0.0,
                }
                if status == "failed":
                    values["encrypted_payload"] = ""
                await session.execute(
                    update(EmailOutbox)
                    .where(
                        EmailOutbox.id == item.id,
                        EmailOutbox.claim_token == item.claim_token,
                        EmailOutbox.status == "processing",
                    )
                    .values(**values)
                )
                await session.commit()
            return status

        async with self._session_factory() as session:
            await session.execute(
                update(EmailOutbox)
                .where(
                    EmailOutbox.id == item.id,
                    EmailOutbox.claim_token == item.claim_token,
                    EmailOutbox.status == "processing",
                )
                .values(
                    status="delivered",
                    attempts=item.attempts + 1,
                    delivered_at=now,
                    encrypted_payload="",
                    last_error_code="",
                    claim_token="",
                    locked_at=0.0,
                )
            )
            await session.commit()
        return "delivered"

    async def run_once(self) -> dict[str, int]:
        claimed = await self._claim_batch()
        if not claimed:
            return {"claimed": 0, "delivered": 0, "retry": 0, "failed": 0}
        semaphore = asyncio.Semaphore(self._batch_size)

        async def deliver(item: _ClaimedItem) -> str:
            async with semaphore:
                return await self._deliver(item)

        results = await asyncio.gather(*(deliver(item) for item in claimed))
        return {
            "claimed": len(results),
            "delivered": results.count("delivered"),
            "retry": results.count("retry"),
            "failed": results.count("failed"),
        }

    async def purge_history(self, *, before: float) -> int:
        async with self._session_factory() as session:
            result = await session.execute(
                delete(EmailOutbox).where(
                    EmailOutbox.status.in_(("delivered", "failed")),
                    EmailOutbox.created_at < before,
                )
            )
            await session.commit()
            return max(0, result.rowcount or 0)

    async def run_forever(self) -> None:
        while True:
            try:
                await self.run_once()
                await asyncio.sleep(EMAIL_OUTBOX_WORKER_INTERVAL_SECONDS)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.warning("Email outbox worker degraded: %s", type(error).__name__)
                await asyncio.sleep(EMAIL_OUTBOX_WORKER_INTERVAL_SECONDS)


def _error_code(error: Exception) -> str:
    name = type(error).__name__
    if name == "EmailDeliveryUnavailable":
        return "smtp_unavailable"
    if isinstance(error, EmailOutboxConfigurationError):
        return "outbox_configuration"
    return "delivery_error"


__all__ = [
    "EmailOutboxConfigurationError",
    "EmailOutboxWorker",
    "decrypt_verification_payload",
    "encrypt_verification_payload",
    "queue_verification_email",
]
