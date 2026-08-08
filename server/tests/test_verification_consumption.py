import asyncio
import time

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api, auth
from server.database import Base, VerifyCode


def test_correct_verification_code_has_one_atomic_consumer(tmp_path, monkeypatch):
    engine = create_async_engine(
        f"sqlite+aiosqlite:///{(tmp_path / 'verify-concurrency.db').as_posix()}"
    )
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(auth, "SECRET_KEY", "verification-test-key-over-32-bytes")

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            session.add(
                VerifyCode(
                    email="atomic@example.com",
                    purpose="register",
                    code=account_api._code_digest(
                        "atomic@example.com", "register", "123456"
                    ),
                    expires_at=time.time() + 600,
                )
            )
            await session.commit()

    asyncio.run(prepare())

    async def consume_once():
        async with sessions() as session:
            try:
                await account_api._consume_code(
                    session, "atomic@example.com", "register", "123456"
                )
                return "success"
            except HTTPException as error:
                return error.status_code

    async def run_both():
        return await asyncio.gather(consume_once(), consume_once())

    results = asyncio.run(run_both())
    assert sorted(results, key=str) == [400, "success"]

    async def remaining():
        async with sessions() as session:
            return await session.scalar(
                select(VerifyCode).where(VerifyCode.email == "atomic@example.com")
            )

    assert asyncio.run(remaining()) is None
    asyncio.run(engine.dispose())


def test_wrong_attempts_are_atomic_and_fifth_locks_code(tmp_path, monkeypatch):
    engine = create_async_engine(f"sqlite+aiosqlite:///{(tmp_path / 'verify.db').as_posix()}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(auth, "SECRET_KEY", "verification-test-key-over-32-bytes")

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            session.add(
                VerifyCode(
                    email="wrong@example.com",
                    purpose="reset_password",
                    code=account_api._code_digest(
                        "wrong@example.com", "reset_password", "654321"
                    ),
                    expires_at=time.time() + 600,
                )
            )
            await session.commit()

    asyncio.run(prepare())

    async def attempt():
        async with sessions() as session:
            try:
                await account_api._consume_code(
                    session, "wrong@example.com", "reset_password", "000000"
                )
            except HTTPException as error:
                return error.status_code

    assert [asyncio.run(attempt()) for _ in range(4)] == [400, 400, 400, 400]
    assert asyncio.run(attempt()) == 429

    async def correct_after_lock():
        async with sessions() as session:
            try:
                await account_api._consume_code(
                    session, "wrong@example.com", "reset_password", "654321"
                )
            except HTTPException as error:
                return error.status_code

    assert asyncio.run(correct_after_lock()) == 429
    asyncio.run(engine.dispose())
