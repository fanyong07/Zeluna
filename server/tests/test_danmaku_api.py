import asyncio

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.account_api import current_account
from server.app import create_app
from server.database import Base, User, UserToken
from server.dependencies import get_session


async def _exercise_api(database_path, exercise):
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    async with sessions() as session:
        owner = User(email="owner@example.com", name="弹幕用户", password_hash="hash")
        other = User(email="other@example.com", name="其他用户", password_hash="hash")
        session.add_all([owner, other])
        await session.commit()
        owner_id = owner.id
        other_id = other.id

    active_user_id = owner_id

    async def override_session():
        async with sessions() as session:
            yield session

    async def override_account():
        async with sessions() as session:
            user = await session.get(User, active_user_id)
            assert user is not None
            return user, UserToken(user_id=user.id, token="test")

    def switch_user(user_id):
        nonlocal active_user_id
        active_user_id = user_id

    app = create_app()
    app.dependency_overrides[get_session] = override_session
    app.dependency_overrides[current_account] = override_account
    try:
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="https://test"
        ) as client:
            await exercise(client, switch_user, owner_id, other_id)
    finally:
        app.dependency_overrides.clear()
        await engine.dispose()


def test_logged_in_user_can_publish_and_guest_can_read(tmp_path):
    async def exercise(client, _switch_user, _owner_id, _other_id):
        created = await client.post(
            "/api/v3/danmaku",
            json={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "time_seconds": 12.5,
                "mode": "scroll",
                "color": 0xFFFFFF,
                "text": "  第一条自建弹幕  ",
            },
        )

        assert created.status_code == 201
        comment = created.json()
        assert comment["subject_key"] == "bangumi:400602"
        assert comment["episode_key"] == "episode:v2:first"
        assert comment["text"] == "第一条自建弹幕"
        assert comment["author"] == {"display_name": "弹幕用户", "is_mine": True}
        assert "email" not in str(comment)
        assert "user_id" not in comment

        read = await client.get(
            "/api/v3/danmaku",
            params={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
            },
        )

        assert read.status_code == 200
        assert read.headers["cache-control"] == "no-store"
        assert read.json() == {
            "comments": [{**comment, "author": {"display_name": "弹幕用户", "is_mine": False}}],
            "next_cursor": None,
        }

        mine = await client.get(
            "/api/v3/danmaku/mine",
            params={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
            },
        )
        assert mine.status_code == 200
        assert mine.json()["comments"][0]["author"] == {
            "display_name": "弹幕用户",
            "is_mine": True,
        }

    asyncio.run(_exercise_api(tmp_path / "danmaku.db", exercise))


def test_only_the_author_can_delete_a_comment(tmp_path):
    async def exercise(client, switch_user, owner_id, other_id):
        created = await client.post(
            "/api/v3/danmaku",
            json={
                "subject_key": "tmdb:tv:95842",
                "episode_key": "episode:v2:first",
                "time_seconds": 30,
                "mode": "top",
                "color": 0xFFCC00,
                "text": "本人可删除",
            },
        )
        assert created.status_code == 201
        comment_id = created.json()["id"]

        switch_user(other_id)
        forbidden = await client.delete(f"/api/v3/danmaku/{comment_id}")
        assert forbidden.status_code == 403

        switch_user(owner_id)
        deleted = await client.delete(f"/api/v3/danmaku/{comment_id}")
        assert deleted.status_code == 204
        assert deleted.content == b""

        read = await client.get(
            "/api/v3/danmaku",
            params={
                "subject_key": "tmdb:tv:95842",
                "episode_key": "episode:v2:first",
            },
        )
        assert read.status_code == 200
        assert read.json()["comments"] == []

    asyncio.run(_exercise_api(tmp_path / "delete-danmaku.db", exercise))
