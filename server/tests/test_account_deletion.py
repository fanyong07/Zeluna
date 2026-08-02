import asyncio

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api, auth
from server.database import (
    Bangumi,
    BangumiCollection,
    BangumiEpisode,
    Base,
    Comment,
    CommentLike,
    Danmaku,
    PlayHistory,
    Thread,
    ThreadCollection,
    ThreadImage,
    ThreadLike,
    User,
    UserToken,
    VerifyCode,
)
from server.privacy import finalize_due_account_deletions

_TEST_SECRET = "zeluna-account-deletion-test-key-over-32-bytes"


def test_account_erasure_inventory_covers_every_user_foreign_key():
    references = {
        (table.name, column.name, column.nullable)
        for table in Base.metadata.sorted_tables
        for column in table.columns
        for foreign_key in column.foreign_keys
        if foreign_key.target_fullname == "users.id"
    }
    assert references == {
        ("bangumi_collections", "user_id", False),
        ("comment_likes", "user_id", False),
        ("comments", "user_id", True),
        ("danmaku", "user_id", True),
        ("play_history", "user_id", False),
        ("thread_collections", "user_id", False),
        ("thread_likes", "user_id", False),
        ("threads", "user_id", True),
        ("user_tokens", "user_id", False),
    }


def _test_app(sessions) -> FastAPI:
    async def get_test_session():
        async with sessions() as session:
            yield session

    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session
    return app


def test_deletion_request_freezes_sessions_and_valid_password_can_cancel(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)
    account_api._attempts.clear()
    database_path = (tmp_path / "account-deletion-api.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            user = User(
                email="delete@example.com",
                name="delete-user",
                password_hash=auth.hash_password("correct-password"),
            )
            session.add(user)
            await session.flush()
            first_token = await account_api._issue_token(session, user)
            second_token = await account_api._issue_token(session, user)
            return first_token, second_token

    first_token, second_token = asyncio.run(prepare())
    app = _test_app(sessions)
    with TestClient(app) as client:
        wrong = client.post(
            "/api/v1/auth/privacy/deletion",
            headers={"Authorization": f"Bearer {first_token}"},
            json={"password": "wrong-password"},
        )
        requested = client.post(
            "/api/v1/auth/privacy/deletion",
            headers={"Authorization": f"Bearer {first_token}"},
            json={"password": "correct-password"},
        )
        old_session = client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {second_token}"},
        )
        invalid_login = client.post(
            "/api/v1/auth/login",
            json={"email": "delete@example.com", "password": "wrong-password"},
        )
        frozen_login = client.post(
            "/api/v1/auth/login",
            json={"email": "delete@example.com", "password": "correct-password"},
        )
        wrong_cancel = client.post(
            "/api/v1/auth/privacy/deletion/cancel",
            json={"email": "delete@example.com", "password": "wrong-password"},
        )
        cancelled = client.post(
            "/api/v1/auth/privacy/deletion/cancel",
            json={"email": "delete@example.com", "password": "correct-password"},
        )
        restored_login = client.post(
            "/api/v1/auth/login",
            json={"email": "delete@example.com", "password": "correct-password"},
        )

    assert wrong.status_code == 400
    assert requested.status_code == 202
    assert requested.headers["cache-control"] == "no-store"
    requested_body = requested.json()
    assert requested_body["status"] == "pending"
    assert (
        604799
        <= (requested_body["deletion_due_at"] - requested_body["deletion_requested_at"])
        <= 604801
    )
    assert old_session.status_code == 401
    assert invalid_login.status_code == 401
    assert invalid_login.json()["detail"] == "邮箱或密码不正确"
    assert frozen_login.status_code == 423
    assert frozen_login.json()["detail"]["code"] == "account_deletion_pending"
    assert wrong_cancel.status_code == 401
    assert cancelled.status_code == 204
    assert restored_login.status_code == 200

    async def inspect_state():
        async with sessions() as session:
            user = await session.scalar(
                select(User).where(User.email == "delete@example.com")
            )
            return user.deletion_requested_at, user.deletion_due_at

    assert asyncio.run(inspect_state()) == (0, 0)
    asyncio.run(engine.dispose())


def test_due_deletion_anonymizes_public_content_and_erases_private_data(tmp_path):
    database_path = (tmp_path / "account-deletion-finalize.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def exercise():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            owner = User(
                email="owner-delete@example.com",
                name="owner-delete",
                password_hash="owner-hash",
                deletion_requested_at=1,
                deletion_due_at=99,
            )
            keeper = User(
                email="keeper@example.com",
                name="keeper",
                password_hash="keeper-hash",
            )
            later = User(
                email="later@example.com",
                name="later",
                password_hash="later-hash",
                deletion_requested_at=2,
                deletion_due_at=99.5,
            )
            subject = Bangumi(title="Deletion subject")
            session.add_all([owner, keeper, later, subject])
            await session.flush()
            episode = BangumiEpisode(bangumi_id=subject.id, number=1)
            owner_thread = Thread(title="Owner public thread", user_id=owner.id)
            keeper_thread = Thread(
                title="Keeper thread",
                user_id=keeper.id,
                like_count=2,
                collect_count=2,
            )
            session.add_all([episode, owner_thread, keeper_thread])
            await session.flush()
            owner_comment = Comment(
                type="thread",
                target_id=str(owner_thread.id),
                user_id=owner.id,
                contents='[{"text":"owner public comment"}]',
            )
            keeper_comment = Comment(
                type="thread",
                target_id=str(keeper_thread.id),
                user_id=keeper.id,
                reply_to=owner.name,
                contents='[{"text":"keeper reply"}]',
                like_count=2,
            )
            session.add_all([owner_comment, keeper_comment])
            await session.flush()
            session.add_all(
                [
                    BangumiCollection(
                        user_id=owner.id, bangumi_id=subject.id, type="watch"
                    ),
                    PlayHistory(
                        user_id=owner.id,
                        bangumi_id=subject.id,
                        episode_id=episode.id,
                        position=88,
                    ),
                    Danmaku(
                        user_id=owner.id,
                        bangumi_id=subject.id,
                        episode_id=episode.id,
                        text="owner public danmaku",
                    ),
                    ThreadImage(
                        thread_id=owner_thread.id,
                        original="https://media.example/preserved.png",
                    ),
                    ThreadCollection(user_id=owner.id, thread_id=keeper_thread.id),
                    ThreadCollection(user_id=keeper.id, thread_id=keeper_thread.id),
                    ThreadLike(user_id=owner.id, thread_id=keeper_thread.id),
                    ThreadLike(user_id=keeper.id, thread_id=keeper_thread.id),
                    CommentLike(user_id=owner.id, comment_id=keeper_comment.id),
                    CommentLike(user_id=keeper.id, comment_id=keeper_comment.id),
                    UserToken(
                        user_id=owner.id,
                        token="owner-session",
                        token_id="owner-jti",
                        expires_at=1000,
                    ),
                    VerifyCode(
                        email=owner.email,
                        code="owner-code",
                        purpose="reset_password",
                        expires_at=1000,
                    ),
                ]
            )
            await session.commit()

            finalized = await finalize_due_account_deletions(session, now=100, limit=1)
            await session.commit()

            public_thread = await session.get(Thread, owner_thread.id)
            public_comment = await session.get(Comment, owner_comment.id)
            public_danmaku = await session.scalar(
                select(Danmaku).where(Danmaku.text == "owner public danmaku")
            )
            keeper_counts = (
                await session.execute(
                    select(Thread.like_count, Thread.collect_count).where(
                        Thread.id == keeper_thread.id
                    )
                )
            ).one()
            kept_comment = (
                await session.execute(
                    select(Comment.like_count, Comment.reply_to).where(
                        Comment.id == keeper_comment.id
                    )
                )
            ).one()
            return {
                "finalized": finalized,
                "owner": await session.get(User, owner.id),
                "later": await session.get(User, later.id),
                "public_thread": (public_thread.user_id, public_thread.title),
                "public_comment": (
                    public_comment.user_id,
                    public_comment.contents,
                ),
                "public_danmaku": (
                    public_danmaku.user_id,
                    public_danmaku.text,
                ),
                "image_count": await session.scalar(
                    select(func.count(ThreadImage.id)).where(
                        ThreadImage.thread_id == owner_thread.id
                    )
                ),
                "private_counts": (
                    await session.scalar(
                        select(func.count(BangumiCollection.id)).where(
                            BangumiCollection.user_id == owner.id
                        )
                    ),
                    await session.scalar(
                        select(func.count(PlayHistory.id)).where(
                            PlayHistory.user_id == owner.id
                        )
                    ),
                    await session.scalar(
                        select(func.count(UserToken.id)).where(
                            UserToken.user_id == owner.id
                        )
                    ),
                    await session.scalar(
                        select(func.count(VerifyCode.id)).where(
                            VerifyCode.email == owner.email
                        )
                    ),
                ),
                "keeper_counts": (*keeper_counts, kept_comment.like_count),
                "reply_to": kept_comment.reply_to,
            }

    result = asyncio.run(exercise())
    assert result["finalized"] == 1
    assert result["owner"] is None
    assert result["later"] is not None
    assert result["public_thread"] == (None, "Owner public thread")
    assert result["public_comment"][0] is None
    assert "owner public comment" in result["public_comment"][1]
    assert result["public_danmaku"] == (None, "owner public danmaku")
    assert result["image_count"] == 1
    assert result["private_counts"] == (0, 0, 0, 0)
    assert result["keeper_counts"] == (1, 1, 1)
    assert result["reply_to"] == "匿名"
    asyncio.run(engine.dispose())
