import asyncio
from contextlib import asynccontextmanager
from types import SimpleNamespace

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select, update
from sqlalchemy.dialects import postgresql
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api, auth, privacy
from server.database import (
    Bangumi,
    BangumiCollection,
    BangumiEpisode,
    Base,
    Comment,
    CommentLike,
    Danmaku,
    PlayHistory,
    RefreshTokenHistory,
    SyncMutation,
    SyncRecord,
    SyncRevision,
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


def test_poison_account_does_not_block_other_deletions(tmp_path, monkeypatch):
    engine = create_async_engine(
        f"sqlite+aiosqlite:///{(tmp_path / 'poison-deletion.db').as_posix()}"
    )
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            session.add_all(
                [
                    User(
                        email="poison@example.com",
                        name="poison",
                        password_hash="hash",
                        deletion_requested_at=1,
                        deletion_due_at=99,
                    ),
                    User(
                        email="normal-a@example.com",
                        name="normal-a",
                        password_hash="hash",
                        deletion_requested_at=1,
                        deletion_due_at=99,
                    ),
                    User(
                        email="normal-b@example.com",
                        name="normal-b",
                        password_hash="hash",
                        deletion_requested_at=1,
                        deletion_due_at=99,
                    ),
                ]
            )
            await session.commit()

    asyncio.run(prepare())
    original = privacy._finalize_account_deletion

    async def poison_once(session, user):
        if user.email == "poison@example.com":
            raise RuntimeError("fixture poison")
        await original(session, user)

    monkeypatch.setattr(privacy, "_finalize_account_deletion", poison_once)

    async def first_cleanup():
        stats = {}
        async with sessions() as session:
            finalized = await finalize_due_account_deletions(
                session,
                now=100,
                limit=10,
                session_factory=sessions,
                stats=stats,
            )
        async with sessions() as session:
            poison = await session.scalar(
                select(User).where(User.email == "poison@example.com")
            )
            remaining = list(await session.scalars(select(User)))
        return finalized, stats, poison, remaining

    finalized, stats, poison, remaining = asyncio.run(first_cleanup())
    assert finalized == 2
    assert stats == {
        "processed": 3,
        "finalized": 2,
        "failed": 1,
        "errors": {"unknown_internal": 1},
    }
    assert poison.deletion_due_at == 99
    assert poison.deletion_attempts == 1
    assert poison.deletion_last_error_code == "unknown_internal"
    assert [user.email for user in remaining] == ["poison@example.com"]

    monkeypatch.setattr(privacy, "_finalize_account_deletion", original)

    async def second_cleanup():
        async with sessions() as session:
            return await finalize_due_account_deletions(
                session, now=100, limit=10, session_factory=sessions
            )

    assert asyncio.run(second_cleanup()) == 1

    async def count_users():
        async with sessions() as session:
            return await session.scalar(select(func.count(User.id)))

    assert asyncio.run(count_users()) == 0
    asyncio.run(engine.dispose())


def test_candidate_selection_commits_before_locked_finalizer(monkeypatch):
    events = []
    statements = {}
    user = SimpleNamespace(id=7)

    class SelectionSession:
        async def scalars(self, statement):
            statements["selection"] = statement
            events.append("selection")
            return [user.id]

        async def commit(self):
            events.append("selection_commit")

    class AccountSession:
        async def scalar(self, statement):
            statements["claim"] = statement
            events.append("claim")
            return user

        async def commit(self):
            events.append("finalizer_commit")

        async def rollback(self):
            events.append("finalizer_rollback")

    class AccountContext:
        async def __aenter__(self):
            events.append("finalizer_enter")
            return AccountSession()

        async def __aexit__(self, exc_type, exc, traceback):
            events.append("finalizer_exit")

    async def fake_finalize(session, account):
        assert account is user
        events.append("finalize")

    monkeypatch.setattr(privacy, "_finalize_account_deletion", fake_finalize)

    async def exercise():
        stats = {}
        finalized = await finalize_due_account_deletions(
            SelectionSession(),
            now=100,
            limit=1,
            session_factory=AccountContext,
            stats=stats,
        )
        return finalized, stats

    finalized, stats = asyncio.run(exercise())
    assert finalized == 1
    assert stats == {
        "processed": 1,
        "finalized": 1,
        "failed": 0,
        "errors": {},
    }
    assert events == [
        "selection",
        "selection_commit",
        "finalizer_enter",
        "claim",
        "finalize",
        "finalizer_commit",
        "finalizer_exit",
    ]

    selection_sql = str(
        statements["selection"].compile(dialect=postgresql.dialect())
    ).upper()
    claim_sql = str(statements["claim"].compile(dialect=postgresql.dialect())).upper()
    assert "FOR UPDATE" not in selection_sql
    assert "USERS.DELETION_DUE_AT >" in claim_sql
    assert "USERS.DELETION_DUE_AT <=" in claim_sql
    assert "FOR UPDATE SKIP LOCKED" in claim_sql


def test_finalizer_rechecks_due_state_after_candidate_selection(tmp_path):
    engine = create_async_engine(
        f"sqlite+aiosqlite:///{(tmp_path / 'deletion-recheck.db').as_posix()}"
    )
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            user = User(
                email="cancel-before-finalize@example.com",
                name="cancel-before-finalize",
                password_hash="hash",
                deletion_requested_at=1,
                deletion_due_at=99,
            )
            session.add(user)
            await session.commit()
            return user.id

    user_id = asyncio.run(prepare())
    cancellation_applied = False

    @asynccontextmanager
    async def cancel_then_open_finalizer():
        nonlocal cancellation_applied
        if not cancellation_applied:
            async with sessions() as cancellation_session:
                await cancellation_session.execute(
                    update(User)
                    .where(User.id == user_id)
                    .values(deletion_requested_at=0, deletion_due_at=0)
                )
                await cancellation_session.commit()
            cancellation_applied = True
        async with sessions() as account_session:
            yield account_session

    async def exercise():
        stats = {}
        async with sessions() as selection_session:
            finalized = await finalize_due_account_deletions(
                selection_session,
                now=100,
                limit=1,
                session_factory=cancel_then_open_finalizer,
                stats=stats,
            )
        async with sessions() as inspection_session:
            remaining = await inspection_session.get(User, user_id)
        return finalized, stats, remaining

    finalized, stats, remaining = asyncio.run(exercise())
    assert cancellation_applied
    assert finalized == 0
    assert stats == {
        "processed": 0,
        "finalized": 0,
        "failed": 0,
        "errors": {},
    }
    assert remaining is not None
    assert remaining.deletion_requested_at == 0
    assert remaining.deletion_due_at == 0
    asyncio.run(engine.dispose())


def test_concurrent_workers_only_finalize_the_claimed_account(monkeypatch):
    async def exercise():
        first_claimed = asyncio.Event()
        second_attempted = asyncio.Event()
        state = {"locked": False, "finalizations": 0}
        claim_statements = []

        class SelectionSession:
            def __init__(self):
                self.committed = False

            async def scalars(self, statement):
                return [11]

            async def commit(self):
                self.committed = True

        class AccountSession:
            def __init__(self):
                self.owns_claim = False

            async def scalar(self, statement):
                claim_statements.append(statement)
                if not state["locked"]:
                    state["locked"] = True
                    self.owns_claim = True
                    first_claimed.set()
                    await second_attempted.wait()
                    return SimpleNamespace(id=11)
                await first_claimed.wait()
                second_attempted.set()
                return None

            async def commit(self):
                if self.owns_claim:
                    state["locked"] = False

            async def rollback(self):
                if self.owns_claim:
                    state["locked"] = False

        class AccountContext:
            def __init__(self, selection_session):
                self.selection_session = selection_session
                self.account_session = AccountSession()

            async def __aenter__(self):
                assert self.selection_session.committed
                return self.account_session

            async def __aexit__(self, exc_type, exc, traceback):
                return None

        async def fake_finalize(session, account):
            assert account.id == 11
            state["finalizations"] += 1

        monkeypatch.setattr(privacy, "_finalize_account_deletion", fake_finalize)
        first_selection = SelectionSession()
        second_selection = SelectionSession()
        first_stats = {}
        second_stats = {}

        results = await asyncio.gather(
            finalize_due_account_deletions(
                first_selection,
                now=100,
                limit=1,
                session_factory=lambda: AccountContext(first_selection),
                stats=first_stats,
            ),
            finalize_due_account_deletions(
                second_selection,
                now=100,
                limit=1,
                session_factory=lambda: AccountContext(second_selection),
                stats=second_stats,
            ),
        )
        return results, first_stats, second_stats, state, claim_statements

    results, first_stats, second_stats, state, claim_statements = asyncio.run(
        exercise()
    )
    assert sorted(results) == [0, 1]
    assert state["finalizations"] == 1
    assert sorted([first_stats["processed"], second_stats["processed"]]) == [0, 1]
    assert sorted([first_stats["finalized"], second_stats["finalized"]]) == [0, 1]
    assert len(claim_statements) == 2
    for statement in claim_statements:
        claim_sql = str(statement.compile(dialect=postgresql.dialect())).upper()
        assert "FOR UPDATE SKIP LOCKED" in claim_sql


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
        ("sync_mutations", "user_id", False),
        ("sync_records", "user_id", False),
        ("sync_revisions", "user_id", False),
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


def test_expired_deletion_window_rejects_login_and_cancellation(tmp_path, monkeypatch):
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)
    account_api._attempts.clear()
    database_path = (tmp_path / "account-deletion-expired.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            session.add(
                User(
                    email="expired-delete@example.com",
                    name="expired-delete",
                    password_hash=auth.hash_password("correct-password"),
                    deletion_requested_at=1,
                    deletion_due_at=2,
                )
            )
            await session.commit()

    asyncio.run(prepare())
    app = _test_app(sessions)
    with TestClient(app) as client:
        login = client.post(
            "/api/v1/auth/login",
            json={
                "email": "expired-delete@example.com",
                "password": "correct-password",
            },
        )
        cancellation = client.post(
            "/api/v1/auth/privacy/deletion/cancel",
            json={
                "email": "expired-delete@example.com",
                "password": "correct-password",
            },
        )

    assert login.status_code == 410
    assert login.json()["detail"]["code"] == "account_deletion_finalizing"
    assert cancellation.status_code == 410
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
            sync_revision = SyncRevision(
                user_id=owner.id,
                created_at=10,
            )
            session.add(sync_revision)
            await session.flush()
            owner_comment = Comment(
                type="thread",
                target_id=str(owner_thread.id),
                user_id=owner.id,
                contents='[{"text":"owner public comment"}]',
            )
            session.add(owner_comment)
            await session.flush()
            keeper_comment = Comment(
                type="thread",
                target_id=str(keeper_thread.id),
                user_id=keeper.id,
                parent_id=str(owner_comment.id),
                reply_to=owner.name,
                contents='[{"text":"keeper reply"}]',
                like_count=2,
            )
            unrelated_reply = Comment(
                type="thread",
                target_id=str(keeper_thread.id),
                user_id=keeper.id,
                parent_id="unrelated-comment",
                reply_to=owner.name,
                contents='[{"text":"same nickname, different parent"}]',
            )
            session.add_all([keeper_comment, unrelated_reply])
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
                    RefreshTokenHistory(
                        user_id=owner.id,
                        session_id="owner-session-id",
                        token_family_id="owner-family",
                        digest="owner-refresh-digest",
                    ),
                    SyncRecord(
                        user_id=owner.id,
                        record_id="bangumi:1",
                        record_type="favorite",
                        schema_version=1,
                        payload_json='{"subject":{"stableKey":"bangumi:1"}}',
                        created_at=10,
                        updated_at=10,
                        deleted=False,
                        last_mutation_id="owner-sync-mutation-0001",
                        revision=sync_revision.revision,
                    ),
                    SyncMutation(
                        user_id=owner.id,
                        mutation_id="owner-sync-mutation-0001",
                        payload_hash="a" * 64,
                        record_id="bangumi:1",
                        record_type="favorite",
                        revision=sync_revision.revision,
                        created_at=10,
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
            unrelated_reply_to = await session.scalar(
                select(Comment.reply_to).where(Comment.id == unrelated_reply.id)
            )
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
                        select(func.count(RefreshTokenHistory.id)).where(
                            RefreshTokenHistory.user_id == owner.id
                        )
                    ),
                    await session.scalar(
                        select(func.count(VerifyCode.id)).where(
                            VerifyCode.email == owner.email
                        )
                    ),
                    await session.scalar(
                        select(func.count(SyncRecord.id)).where(
                            SyncRecord.user_id == owner.id
                        )
                    ),
                    await session.scalar(
                        select(func.count(SyncMutation.id)).where(
                            SyncMutation.user_id == owner.id
                        )
                    ),
                    await session.scalar(
                        select(func.count(SyncRevision.revision)).where(
                            SyncRevision.user_id == owner.id
                        )
                    ),
                ),
                "keeper_counts": (*keeper_counts, kept_comment.like_count),
                "reply_to": kept_comment.reply_to,
                "unrelated_reply_to": unrelated_reply_to,
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
    assert result["private_counts"] == (0, 0, 0, 0, 0, 0, 0, 0)
    assert result["keeper_counts"] == (1, 1, 1)
    assert result["reply_to"] == "匿名"
    assert result["unrelated_reply_to"] == "owner-delete"
    asyncio.run(engine.dispose())
