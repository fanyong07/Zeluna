import asyncio

import pytest
from cryptography.fernet import Fernet
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import email_outbox
from server.database import Base, EmailOutbox
from server.email_outbox import (
    EmailOutboxConfigurationError,
    EmailOutboxWorker,
    decrypt_verification_payload,
    queue_verification_email,
)


def _setup(tmp_path, monkeypatch):
    engine = create_async_engine(f"sqlite+aiosqlite:///{(tmp_path / 'outbox.db').as_posix()}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(
        email_outbox,
        "EMAIL_OUTBOX_ENCRYPTION_KEY",
        Fernet.generate_key().decode("ascii"),
    )

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(prepare())
    return engine, sessions


def test_missing_outbox_key_fails_closed_without_a_row(tmp_path, monkeypatch):
    engine, sessions = _setup(tmp_path, monkeypatch)
    monkeypatch.setattr(email_outbox, "EMAIL_OUTBOX_ENCRYPTION_KEY", "")

    async def exercise():
        async with sessions() as session:
            with pytest.raises(EmailOutboxConfigurationError):
                await queue_verification_email(
                    session,
                    email="user@example.com",
                    code="123456",
                    purpose="register",
                )
            await session.rollback()
            return await session.scalar(select(EmailOutbox))

    assert asyncio.run(exercise()) is None
    asyncio.run(engine.dispose())


def test_worker_sends_and_erases_sensitive_payload(tmp_path, monkeypatch):
    engine, sessions = _setup(tmp_path, monkeypatch)
    delivered = []

    async def sender(email, code, purpose):
        delivered.append((email, code, purpose))

    async def exercise():
        async with sessions() as session:
            await queue_verification_email(
                session,
                email="user@example.com",
                code="123456",
                purpose="register",
            )
            await session.commit()
        result = await EmailOutboxWorker(sessions, sender=sender).run_once()
        async with sessions() as session:
            row = await session.scalar(select(EmailOutbox))
            return result, row

    result, row = asyncio.run(exercise())
    assert result == {"claimed": 1, "delivered": 1, "retry": 0, "failed": 0}
    assert delivered == [("user@example.com", "123456", "register")]
    assert row.status == "delivered"
    assert row.encrypted_payload == ""
    asyncio.run(engine.dispose())


def test_worker_retries_after_transient_smtp_failure(tmp_path, monkeypatch):
    engine, sessions = _setup(tmp_path, monkeypatch)
    now = [100.0]
    calls = []

    async def sender(email, code, purpose):
        calls.append(code)
        if len(calls) == 1:
            raise RuntimeError("temporary SMTP error")

    async def exercise():
        async with sessions() as session:
            await queue_verification_email(
                session,
                email="retry@example.com",
                code="654321",
                purpose="reset_password",
                now=now[0],
            )
            await session.commit()
        worker = EmailOutboxWorker(
            sessions,
            sender=sender,
            retry_base_seconds=5,
            clock=lambda: now[0],
        )
        first = await worker.run_once()
        now[0] = 105
        second = await worker.run_once()
        return first, second

    first, second = asyncio.run(exercise())
    assert first["retry"] == 1
    assert second["delivered"] == 1
    assert calls == ["654321", "654321"]
    asyncio.run(engine.dispose())


def test_two_workers_cannot_double_send_and_stale_claim_is_recoverable(
    tmp_path, monkeypatch
):
    engine, sessions = _setup(tmp_path, monkeypatch)
    sent = []
    lock = asyncio.Lock()

    async def sender(email, code, purpose):
        await asyncio.sleep(0.01)
        async with lock:
            sent.append(code)

    async def exercise():
        async with sessions() as session:
            await queue_verification_email(
                session,
                email="restart@example.com",
                code="112233",
                purpose="register",
            )
            await session.commit()
        workers = [EmailOutboxWorker(sessions, sender=sender) for _ in range(2)]
        results = await asyncio.gather(*(worker.run_once() for worker in workers))
        async with sessions() as session:
            row = await session.scalar(select(EmailOutbox))
            await session.execute(
                update(EmailOutbox)
                .where(EmailOutbox.id == row.id)
                .values(
                    status="processing",
                    encrypted_payload=email_outbox.encrypt_verification_payload(
                        "stale@example.com", "445566", "register"
                    ),
                    recipient="stale@example.com",
                    claim_token="crashed-worker",
                    locked_at=0,
                )
            )
            await session.commit()
        recovered = await EmailOutboxWorker(
            sessions, sender=sender, processing_timeout_seconds=60, clock=lambda: 100
        ).run_once()
        return results, recovered

    results, recovered = asyncio.run(exercise())
    assert sum(result["delivered"] for result in results) == 1
    assert sent.count("112233") == 1
    assert recovered["delivered"] == 1
    asyncio.run(engine.dispose())


def test_decrypt_rejects_tampered_payload(tmp_path, monkeypatch):
    engine, _sessions = _setup(tmp_path, monkeypatch)
    encrypted = email_outbox.encrypt_verification_payload(
        "user@example.com", "123456", "register"
    )
    with pytest.raises(EmailOutboxConfigurationError):
        decrypt_verification_payload(encrypted[:-1] + ("A" if encrypted[-1] != "A" else "B"))
    asyncio.run(engine.dispose())
