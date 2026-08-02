import asyncio

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.database import Base, User, UserToken, VerifyCode
from server.privacy import purge_expired_auth_artifacts
from server.scheduler import ContentScheduler


def test_expired_auth_cleanup_preserves_accounts_and_active_artifacts(tmp_path):
    database_path = (tmp_path / "privacy-retention.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def exercise():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            user = User(
                email="privacy@example.com",
                name="privacy-user",
                password_hash="not-used",
            )
            session.add(user)
            await session.flush()
            session.add_all(
                [
                    VerifyCode(
                        email=user.email,
                        code="expired-code",
                        purpose="register",
                        expires_at=99,
                    ),
                    VerifyCode(
                        email=user.email,
                        code="active-code",
                        purpose="reset_password",
                        expires_at=101,
                    ),
                    UserToken(
                        user_id=user.id,
                        token="expired-session",
                        token_id="expired",
                        expires_at=99,
                    ),
                    UserToken(
                        user_id=user.id,
                        token="active-session",
                        token_id="active",
                        expires_at=101,
                    ),
                    UserToken(
                        user_id=user.id,
                        token="legacy-session",
                        token_id="",
                        expires_at=0,
                    ),
                ]
            )
            await session.commit()

            cleanup = await purge_expired_auth_artifacts(session, now=100)
            await session.commit()

            users = await session.scalar(select(func.count(User.id)))
            codes = set(await session.scalars(select(VerifyCode.code)))
            tokens = set(await session.scalars(select(UserToken.token)))
            return cleanup, users, codes, tokens

    cleanup, users, codes, tokens = asyncio.run(exercise())
    assert cleanup.verification_codes == 1
    assert cleanup.sessions == 1
    assert users == 1
    assert codes == {"active-code"}
    assert tokens == {"active-session", "legacy-session"}
    asyncio.run(engine.dispose())


def test_scheduled_cleanup_exposes_counts_without_identifiers(tmp_path):
    database_path = (tmp_path / "scheduled-retention.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def exercise():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            session.add(
                VerifyCode(
                    email="private-address@example.com",
                    code="expired-code",
                    purpose="register",
                    expires_at=1,
                )
            )
            await session.commit()
        scheduler = ContentScheduler(privacy_session_factory=sessions)
        cleanup = await scheduler.cleanup_privacy_artifacts()
        return cleanup, scheduler.stats

    cleanup, stats = asyncio.run(exercise())
    assert cleanup.verification_codes == 1
    assert stats["privacy_cleanup"] == {
        "verification_codes": 1,
        "sessions": 0,
    }
    assert stats["last_privacy_cleanup"] is not None
    assert "private-address" not in repr(stats)
    asyncio.run(engine.dispose())


def test_scheduler_registers_and_cancels_privacy_retention_task():
    async def exercise():
        scheduler = ContentScheduler()

        async def idle_loop():
            await asyncio.Event().wait()

        scheduler._register_scrapers = lambda: None
        scheduler._cache_refresh_loop = idle_loop
        scheduler._metadata_loop = idle_loop
        scheduler._health_loop = idle_loop
        scheduler._privacy_loop = idle_loop
        await scheduler.start()
        task_names = set(scheduler._tasks)
        await scheduler.stop()
        return task_names, scheduler._tasks

    task_names, remaining = asyncio.run(exercise())
    assert task_names == {"cache_refresh", "metadata", "health", "privacy"}
    assert remaining == {}
