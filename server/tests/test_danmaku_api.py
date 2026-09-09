import asyncio

import httpx
import pytest
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api
from server.account_api import current_account
from server.rate_limit import InMemoryRateLimiter
from server.app import create_app
from server.dandanplay import (
    DandanplayClient,
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


def test_dandanplay_total_budget_is_shorter_than_client_timeout():
    assert 0 < danmaku_router._DANDANPLAY_TOTAL_TIMEOUT_SECONDS < 8


@pytest.mark.parametrize("endpoint", ["/api/v3/danmaku", "/api/v3/danmaku/mine"])
@pytest.mark.parametrize("upstream_state", ["hung", "slow_search_and_comments"])
def test_slow_dandanplay_returns_existing_community_within_budget(
    tmp_path, monkeypatch, caplog, endpoint, upstream_state
):
    monkeypatch.setattr(
        danmaku_router, "_DANDANPLAY_TOTAL_TIMEOUT_SECONDS", 0.05, raising=False
    )

    class SlowDandanplayClient:
        async def comments_for_episode(self, *, before_upstream=None, **_kwargs):
            if before_upstream is not None:
                await before_upstream()
            if upstream_state == "hung":
                await asyncio.Event().wait()
            else:
                # Each stage fits the budget; their combined duration does not.
                await asyncio.sleep(0.04)  # Search.
                await asyncio.sleep(0.04)  # Comments.
            return DandanplayResult(source={"provider": "弹弹play", "available": True})

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

        response = await asyncio.wait_for(
            client.get(
                endpoint,
                params={
                    "subject_key": "bangumi:400602",
                    "episode_key": "episode:v2:first",
                    "title": "葬送的芙莉莲",
                    "episode_number": 1,
                    "include_dandanplay": True,
                },
            ),
            timeout=0.5,
        )
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        payload = response.json()
        assert set(payload) == {"comments", "sources", "next_cursor"}
        assert payload["next_cursor"] is None
        assert payload["comments"] == [
            {
                **created.json(),
                "author": {
                    "display_name": "弹幕用户",
                    "is_mine": endpoint.endswith("/mine"),
                },
            }
        ]
        assert [item["provider"] for item in payload["sources"]] == [
            "Zeluna",
            "弹弹play",
        ]
        assert payload["sources"][0]["available"] is True
        assert payload["sources"][0]["comment_count"] == 1
        assert payload["sources"][1]["available"] is False
        assert payload["sources"][1]["error_code"] == "timeout"
        assert payload["sources"][1]["retryable"] is True
        assert "社区弹幕仍可正常使用" in payload["sources"][1]["message"]
        assert not [record for record in caplog.records if record.levelno >= 40]

    asyncio.run(
        _exercise_api(
            tmp_path / "slow-dandanplay.db",
            exercise,
            dandanplay_client=SlowDandanplayClient(),
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


@pytest.mark.parametrize(
    "subject_key", ["bangumi:876", "tmdb:tv:95842", "subject:v1:" + "a" * 64]
)
def test_real_flutter_episode_identity_reads_writes_and_aggregates(
    tmp_path, subject_key
):
    episode_key = f"v1|{subject_key}|episode:1"
    fake = _FakeDandanplayClient(
        result=DandanplayResult(
            source={"provider": "弹弹play", "available": True, "comment_count": 1},
            comments=(
                {
                    "id": "dandanplay:42:1",
                    "provider": "弹弹play",
                    "time_seconds": 1,
                    "text": "真实分集协议回归",
                },
            ),
        )
    )

    async def exercise(client, _switch_user, _owner_id, _other_id):
        params = {
            "subject_key": subject_key,
            "episode_key": episode_key,
            "title": "CLANNAD AFTER STORY",
            "episode_number": 1,
            "include_dandanplay": True,
        }
        # Anonymous playback must reach the upstream, using the *client* key.
        read = await client.get("/api/v3/danmaku", params=params)
        assert read.status_code == 200, read.text
        assert read.json()["sources"][1]["available"] is True
        assert read.json()["comments"][0]["provider"] == "弹弹play"
        created = await client.post(
            "/api/v3/danmaku",
            json={
                "subject_key": subject_key,
                "episode_key": episode_key,
                "time_seconds": 2,
                "text": "兼容客户端稳定分集键",
            },
        )
        assert created.status_code == 201, created.text
        mine = await client.get("/api/v3/danmaku/mine", params=params)
        assert mine.status_code == 200, mine.text
        own = [c for c in mine.json()["comments"] if c["provider"] == "Zeluna"]
        assert len(own) == 1
        assert own[0]["episode_key"] == episode_key
        assert own[0]["author"]["is_mine"] is True
        assert len(fake.calls) == 2

    asyncio.run(
        _exercise_api(tmp_path / "client-identity.db", exercise, dandanplay_client=fake)
    )


@pytest.mark.parametrize(
    "invalid",
    [
        "v1|bangumi:876|episode:1\n",
        "../episode:1",
        "a/b",
        "a?b",
        "a b",
        "a' OR 1=1",
        "a\x00b",
        "a" * 301,
    ],
)
def test_episode_identity_rejects_unsafe_characters(tmp_path, invalid):
    async def exercise(client, _switch_user, _owner_id, _other_id):
        params = {"subject_key": "bangumi:876", "episode_key": invalid}
        for path in ("/api/v3/danmaku", "/api/v3/danmaku/mine"):
            response = await client.get(path, params=params)
            assert response.status_code == 422
        response = await client.post(
            "/api/v3/danmaku",
            json={
                **params,
                "time_seconds": 2,
                "text": "无效分集",
            },
        )
        assert response.status_code == 422

    asyncio.run(_exercise_api(tmp_path / "invalid-identity.db", exercise))


@pytest.mark.parametrize("endpoint", ["/api/v3/danmaku", "/api/v3/danmaku/mine"])
@pytest.mark.parametrize(
    "status,code,retryable,message",
    [
        (401, "authorization", False, "授权失败"),
        (403, "authorization", False, "授权失败"),
        (429, "rate_limited", False, "请求受限"),
        (503, "upstream_unavailable", True, "服务暂时不可用"),
        (504, "timeout", True, "请求超时"),
        (422, "upstream_error", False, "返回异常"),
    ],
)
def test_real_client_partial_http_200_classifies_errors_safely(
    tmp_path, monkeypatch, endpoint, status, code, retryable, message
):
    monkeypatch.setattr(
        account_api, "_rate_limiter", InMemoryRateLimiter(max_keys=1000)
    )

    async def handler(_request):
        return httpx.Response(status, text="private-upstream-body-secret")

    upstream = DandanplayClient(
        enabled=True,
        app_id="fixture",
        app_secret="fixture-secret",
        transport=httpx.MockTransport(handler),
    )

    async def exercise(client, _switch_user, _owner_id, _other_id):
        created = await client.post(
            "/api/v3/danmaku",
            json={
                "subject_key": "bangumi:400602",
                "episode_key": "episode:v2:first",
                "time_seconds": 1,
                "mode": "scroll",
                "color": 0xFFFFFF,
                "text": "社区仍可用",
            },
        )
        assert created.status_code == 201
        response = await client.get(
            endpoint,
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
        assert payload["comments"][0]["text"] == "社区仍可用"
        source = payload["sources"][1]
        assert source["provider"] == "弹弹play"
        assert source["available"] is False
        assert source["error_code"] == code
        assert source["retryable"] is retryable
        assert message in source["message"]
        assert "fixture-secret" not in response.text
        assert "private-upstream-body-secret" not in response.text

    asyncio.run(
        _exercise_api(tmp_path / "classified.db", exercise, dandanplay_client=upstream)
    )


def test_local_upstream_rate_limit_never_becomes_retryable(monkeypatch):
    async def denied(*_args, **_kwargs):
        raise HTTPException(status_code=429)

    monkeypatch.setattr(danmaku_router, "_rate_limit", denied)
    monkeypatch.setattr(danmaku_router, "_client_key", lambda _: "fixture")

    async def exercise():
        with pytest.raises(DandanplayError) as caught:
            await danmaku_router._guard_dandanplay_upstream(None)
        assert caught.value.code == "rate_limited"
        assert caught.value.retryable is False

    asyncio.run(exercise())
