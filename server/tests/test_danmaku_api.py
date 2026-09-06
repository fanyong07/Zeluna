import asyncio

from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.account_api import current_account
from server.app import create_app
from server.dandanplay import (
    DandanplayError,
    DandanplayResult,
    get_dandanplay_client,
)
from server.database import Base, User, UserToken
from server.routers import danmaku as danmaku_router
from server.dependencies import get_session


async def _exercise_api(database_path, exercise, *, dandanplay_client=None):
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
    if dandanplay_client is not None:
        app.dependency_overrides[get_dandanplay_client] = lambda: dandanplay_client
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
            "comments": [
                {
                    **comment,
                    "author": {"display_name": "弹幕用户", "is_mine": False},
                }
            ],
            "sources": [
                {
                    "provider": "Zeluna",
                    "title": "Zeluna 社区弹幕",
                    "episode_title": "第 1 集",
                    "episode_id": "episode:v2:first",
                    "comment_count": 1,
                    "available": True,
                    "message": None,
                }
            ],
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


class _FakeDandanplayClient:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.calls = []

    async def comments_for_episode(self, *, before_upstream=None, **kwargs):
        if before_upstream is not None:
            await before_upstream()
        self.calls.append(kwargs)
        if self.error is not None:
            raise self.error
        return self.result


def test_list_aggregates_community_and_dandanplay_comments(tmp_path):
    external = DandanplayResult(
        source={
            "provider": "弹弹play",
            "title": "葬送的芙莉莲",
            "episode_title": "第1话",
            "episode_id": "12345",
            "comment_count": 1,
            "available": True,
            "message": None,
        },
        comments=(
            {
                "id": "dandanplay:12345:88",
                "provider": "弹弹play",
                "time_seconds": 5.0,
                "mode": "top",
                "color": 0xFFFF00,
                "text": "外部弹幕",
                "author": {"display_name": "external", "is_mine": False},
            },
        ),
    )
    fake = _FakeDandanplayClient(result=external)

    async def exercise(client, _switch_user, _owner_id, _other_id):
        created = await client.post(
            "/api/v3/danmaku",
            json={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "time_seconds": 10,
                "mode": "scroll",
                "color": 0xFFFFFF,
                "text": "社区弹幕",
            },
        )
        assert created.status_code == 201

        response = await client.get(
            "/api/v3/danmaku",
            params={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "title": "葬送的芙莉莲",
                "original_title": "Frieren",
                "episode_number": 1,
                "media_type": "anime",
                "include_dandanplay": True,
            },
        )
        assert response.status_code == 200
        payload = response.json()
        assert [item["provider"] for item in payload["sources"]] == [
            "Zeluna",
            "弹弹play",
        ]
        assert [item["text"] for item in payload["comments"]] == [
            "外部弹幕",
            "社区弹幕",
        ]
        assert [item["provider"] for item in payload["comments"]] == [
            "弹弹play",
            "Zeluna",
        ]
        assert fake.calls == [
            {
                "title": "葬送的芙莉莲",
                "original_title": "Frieren",
                "episode_number": 1,
                "media_type": "anime",
            }
        ]

    asyncio.run(
        _exercise_api(
            tmp_path / "aggregate-danmaku.db",
            exercise,
            dandanplay_client=fake,
        )
    )


def test_dandanplay_failure_degrades_to_community_source(tmp_path):
    fake = _FakeDandanplayClient(error=DandanplayError("upstream failed"))

    async def exercise(client, _switch_user, _owner_id, _other_id):
        response = await client.get(
            "/api/v3/danmaku",
            params={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "title": "葬送的芙莉莲",
                "episode_number": 1,
                "include_dandanplay": True,
            },
        )
        assert response.status_code == 200
        payload = response.json()
        assert payload["comments"] == []
        assert payload["sources"][0]["provider"] == "Zeluna"
        assert payload["sources"][1]["provider"] == "弹弹play"
        assert payload["sources"][1]["available"] is False
        assert "社区弹幕仍可正常使用" in payload["sources"][1]["message"]
        assert len(fake.calls) == 1

    asyncio.run(
        _exercise_api(
            tmp_path / "degraded-danmaku.db",
            exercise,
            dandanplay_client=fake,
        )
    )


def test_unexpected_dandanplay_exception_also_degrades_to_community_source(
    tmp_path,
):
    fake = _FakeDandanplayClient(error=RuntimeError("unexpected upstream failure"))

    async def exercise(client, _switch_user, _owner_id, _other_id):
        response = await client.get(
            "/api/v3/danmaku",
            params={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "title": "葬送的芙莉莲",
                "episode_number": 1,
                "include_dandanplay": True,
            },
        )
        assert response.status_code == 200
        payload = response.json()
        assert payload["comments"] == []
        assert [item["provider"] for item in payload["sources"]] == [
            "Zeluna",
            "弹弹play",
        ]
        assert payload["sources"][1]["available"] is False
        assert "社区弹幕仍可正常使用" in payload["sources"][1]["message"]
        assert len(fake.calls) == 1

    asyncio.run(
        _exercise_api(
            tmp_path / "unexpected-degraded-danmaku.db",
            exercise,
            dandanplay_client=fake,
        )
    )


def test_incremental_page_does_not_refetch_dandanplay(tmp_path):
    fake = _FakeDandanplayClient(
        result=DandanplayResult(
            source={"provider": "弹弹play", "available": True},
        )
    )

    async def exercise(client, _switch_user, _owner_id, _other_id):
        response = await client.get(
            "/api/v3/danmaku",
            params={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "after_id": 1,
                "title": "葬送的芙莉莲",
                "episode_number": 1,
                "include_dandanplay": True,
            },
        )
        assert response.status_code == 200
        payload = response.json()
        assert [item["provider"] for item in payload["sources"]] == ["Zeluna"]
        assert fake.calls == []

    asyncio.run(
        _exercise_api(
            tmp_path / "incremental-danmaku.db",
            exercise,
            dandanplay_client=fake,
        )
    )


def test_dandanplay_rate_limit_degrades_without_failing_community(
    tmp_path, monkeypatch
):
    fake = _FakeDandanplayClient(
        result=DandanplayResult(source={"provider": "弹弹play", "available": True})
    )
    rate_limit_calls = []

    async def reject_rate_limit(key, *, limit, window_seconds):
        rate_limit_calls.append((key, limit, window_seconds))
        raise HTTPException(status_code=429, detail="limited")

    monkeypatch.setattr(danmaku_router, "_rate_limit", reject_rate_limit)

    async def exercise(client, _switch_user, _owner_id, _other_id):
        response = await client.get(
            "/api/v3/danmaku",
            params={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "title": "葬送的芙莉莲",
                "episode_number": 1,
                "include_dandanplay": True,
            },
        )
        assert response.status_code == 200
        payload = response.json()
        assert payload["comments"] == []
        assert [item["provider"] for item in payload["sources"]] == [
            "Zeluna",
            "弹弹play",
        ]
        assert payload["sources"][1]["available"] is False
        assert "社区弹幕仍可正常使用" in payload["sources"][1]["message"]
        assert fake.calls == []
        assert len(rate_limit_calls) == 1
        assert rate_limit_calls[0][0].startswith("dandanplay-get:ip:")
        assert rate_limit_calls[0][2] == 60

    asyncio.run(
        _exercise_api(
            tmp_path / "rate-limited-danmaku.db",
            exercise,
            dandanplay_client=fake,
        )
    )
