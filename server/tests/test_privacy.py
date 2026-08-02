import asyncio
import json

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api
from server import auth
from server.database import (
    Bangumi,
    BangumiCollection,
    BangumiEpisode,
    Base,
    Comment,
    Danmaku,
    PlayHistory,
    Thread,
    ThreadImage,
    User,
    UserToken,
    VerifyCode,
)
from server.privacy import purge_expired_auth_artifacts
from server.scheduler import ContentScheduler

_TEST_SECRET = "zeluna-privacy-test-signing-key-over-32-bytes"


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
        "finalized_accounts": 0,
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


def test_authenticated_export_is_allowlisted_private_and_non_cacheable(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)
    database_path = (tmp_path / "account-export.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            owner = User(
                email="owner@example.com",
                name="owner",
                password_hash="owner-secret-hash",
                address="owner-private-profile",
            )
            other = User(
                email="other@example.com",
                name="other",
                password_hash="other-secret-hash",
            )
            subject = Bangumi(title="Private Export Subject")
            session.add_all([owner, other, subject])
            await session.flush()
            episode = BangumiEpisode(bangumi_id=subject.id, number=1)
            owner_thread = Thread(title="Owner thread", user_id=owner.id)
            other_thread = Thread(title="Other thread", user_id=other.id)
            session.add_all([episode, owner_thread, other_thread])
            await session.flush()
            session.add_all(
                [
                    BangumiCollection(
                        user_id=owner.id,
                        bangumi_id=subject.id,
                        type="watch",
                    ),
                    PlayHistory(
                        user_id=owner.id,
                        bangumi_id=subject.id,
                        episode_id=episode.id,
                        position=42.5,
                    ),
                    Danmaku(
                        user_id=owner.id,
                        bangumi_id=subject.id,
                        episode_id=episode.id,
                        text="owner danmaku",
                    ),
                    Danmaku(
                        user_id=other.id,
                        bangumi_id=subject.id,
                        episode_id=episode.id,
                        text="other danmaku",
                    ),
                    ThreadImage(
                        thread_id=owner_thread.id,
                        original="https://media.example/owner.png",
                    ),
                    Comment(
                        type="thread",
                        target_id=str(owner_thread.id),
                        user_id=owner.id,
                        contents='[{"text":"owner comment"}]',
                    ),
                    Comment(
                        type="thread",
                        target_id=str(other_thread.id),
                        user_id=other.id,
                        contents='[{"text":"other comment"}]',
                    ),
                ]
            )
            await session.commit()
            token = await account_api._issue_token(session, owner)
            return token

    token = asyncio.run(prepare())

    async def get_test_session():
        async with sessions() as session:
            yield session

    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session
    with TestClient(app) as client:
        unauthenticated = client.get("/api/v1/auth/privacy/export")
        response = client.get(
            "/api/v1/auth/privacy/export",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert unauthenticated.status_code == 401
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["content-disposition"].endswith(
        'filename="zeluna-account-data.json"'
    )
    body = response.json()
    assert body["schema_version"] == 1
    assert body["account"]["email"] == "owner@example.com"
    assert body["account"]["address"] == "owner-private-profile"
    assert [item["text"] for item in body["authored_content"]["danmaku"]] == [
        "owner danmaku"
    ]
    assert [item["title"] for item in body["authored_content"]["threads"]] == [
        "Owner thread"
    ]
    assert body["private_library"]["play_history"][0]["position"] == 42.5
    serialized = json.dumps(body, sort_keys=True)
    for forbidden in (
        "owner-secret-hash",
        "other-secret-hash",
        token,
        "other@example.com",
        "other danmaku",
        "other comment",
    ):
        assert forbidden not in serialized
    asyncio.run(engine.dispose())
