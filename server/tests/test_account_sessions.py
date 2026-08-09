import asyncio
import time
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api, auth
from server.database import Base, RefreshTokenHistory, User, UserToken


_TEST_SECRET = "f2-test-secret-with-at-least-32-bytes"


def _app(sessions):
    async def get_test_session():
        async with sessions() as session:
            yield session

    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session
    return app


def test_refresh_rotates_opaque_token_and_reuse_revokes_family(tmp_path, monkeypatch):
    engine = create_async_engine(f"sqlite+aiosqlite:///{(tmp_path / 'f2.db').as_posix()}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            user = User(
                email="f2@example.com",
                name="f2",
                password_hash=auth.hash_password("password-123"),
            )
            session.add(user)
            await session.flush()
            credentials = await account_api._issue_credentials(
                session,
                user,
                device_id="device-one",
                device_name="Windows",
                platform="windows",
            )
            return credentials

    credentials = asyncio.run(prepare())
    claims = auth.decode_jwt(credentials.access_token)
    assert claims is not None
    assert claims["session_id"] == credentials.session_id
    assert claims["exp"] - int(time.time()) <= 15 * 60

    with patch.object(auth, "SECRET_KEY", _TEST_SECRET):
        with TestClient(_app(sessions)) as client:
            response = client.post(
                "/api/v1/auth/refresh",
                json={"refresh_token": credentials.refresh_token},
            )
            assert response.status_code == 200
            rotated = response.json()
            assert rotated["refresh_token"] != credentials.refresh_token
            assert rotated["session"]["session_id"] == credentials.session_id

            old = client.post(
                "/api/v1/auth/refresh",
                json={"refresh_token": credentials.refresh_token},
            )
            assert old.status_code == 401
            assert old.json()["detail"]["code"] == "refresh_reuse_detected"
            revoked = client.post(
                "/api/v1/auth/refresh",
                json={"refresh_token": rotated["refresh_token"]},
            )
            assert revoked.status_code == 401

    async def inspect_db():
        async with sessions() as session:
            row = await session.scalar(
                select(UserToken).where(UserToken.session_id == credentials.session_id)
            )
            history_count = await session.scalar(
                select(func.count(RefreshTokenHistory.id)).where(
                    RefreshTokenHistory.session_id == credentials.session_id
                )
            )
            return row, history_count

    row, history_count = asyncio.run(inspect_db())
    assert row is not None
    assert row.revoked_at > 0
    assert credentials.refresh_token not in row.token
    assert history_count == 2
    asyncio.run(engine.dispose())


def test_concurrent_refresh_uses_database_claim_and_revokes_new_chain(
    tmp_path, monkeypatch
):
    engine = create_async_engine(
        f"sqlite+aiosqlite:///{(tmp_path / 'f2-concurrent.db').as_posix()}"
    )
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)

    async def exercise():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            user = User(
                email="concurrent-f2@example.com",
                name="concurrent-f2",
                password_hash=auth.hash_password("password-123"),
            )
            session.add(user)
            await session.flush()
            credentials = await account_api._issue_credentials(
                session,
                user,
                device_id="shared-device",
            )

        ready = asyncio.Event()
        waiting = 0

        async def rotate_once():
            nonlocal waiting
            async with sessions() as session:
                waiting += 1
                if waiting == 2:
                    ready.set()
                await ready.wait()
                try:
                    return await auth.rotate_refresh_token(
                        session, credentials.refresh_token
                    )
                except auth.RefreshTokenReuseDetected as error:
                    return error

        first, second = await asyncio.gather(rotate_once(), rotate_once())
        results = (first, second)
        rotations = [
            result for result in results if isinstance(result, auth.SessionCredentials)
        ]
        reuses = [
            result
            for result in results
            if isinstance(result, auth.RefreshTokenReuseDetected)
        ]
        assert len(rotations) == 1
        assert len(reuses) == 1

        rotated = rotations[0]
        async with sessions() as session:
            stored = await session.scalar(
                select(UserToken).where(
                    UserToken.session_id == credentials.session_id
                )
            )
            histories = list(
                await session.scalars(
                    select(RefreshTokenHistory).where(
                        RefreshTokenHistory.session_id == credentials.session_id
                    )
                )
            )
        assert stored is not None
        assert stored.revoked_at > 0
        assert len(histories) == 2
        assert sum(row.used_at > 0 for row in histories) == 1
        assert sum(row.reuse_detected_at > 0 for row in histories) == 1

        async with sessions() as session:
            try:
                await auth.rotate_refresh_token(session, rotated.refresh_token)
            except auth.RefreshTokenRejected:
                pass
            else:
                raise AssertionError("revoked token family produced a valid chain")

    asyncio.run(exercise())
    asyncio.run(engine.dispose())


def test_session_list_and_revoke_are_account_scoped(tmp_path, monkeypatch):
    engine = create_async_engine(f"sqlite+aiosqlite:///{(tmp_path / 'f2-idors.db').as_posix()}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            owner = User(
                email="owner-f2@example.com",
                name="owner-f2",
                password_hash=auth.hash_password("password-123"),
            )
            other = User(
                email="other-f2@example.com",
                name="other-f2",
                password_hash=auth.hash_password("password-123"),
            )
            session.add_all([owner, other])
            await session.flush()
            first = await account_api._issue_credentials(session, owner, device_id="one")
            second = await account_api._issue_credentials(session, owner, device_id="two")
            foreign = await account_api._issue_credentials(session, other, device_id="foreign")
            return first, second, foreign

    first, second, foreign = asyncio.run(prepare())
    with TestClient(_app(sessions)) as client:
        listed = client.get(
            "/api/v1/auth/sessions",
            headers={"Authorization": f"Bearer {first.access_token}"},
        )
        assert listed.status_code == 200
        assert {item["session_id"] for item in listed.json()["sessions"]} == {
            first.session_id,
            second.session_id,
        }
        assert client.delete(
            f"/api/v1/auth/sessions/{foreign.session_id}",
            headers={"Authorization": f"Bearer {first.access_token}"},
        ).status_code == 404
        assert client.delete(
            f"/api/v1/auth/sessions/{second.session_id}",
            headers={"Authorization": f"Bearer {first.access_token}"},
        ).status_code == 204
        assert client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {second.access_token}"},
        ).status_code == 401
    asyncio.run(engine.dispose())
