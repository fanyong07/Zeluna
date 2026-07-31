import asyncio

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api
from server.auth import create_jwt, hash_password, verify_password
from server.database import Base, VerifyCode


def test_email_registration_login_session_and_logout(tmp_path, monkeypatch):
    database_path = (tmp_path / "accounts.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(prepare())

    async def get_test_session():
        async with sessions() as session:
            yield session

    delivered = {}

    async def capture_email(email: str, code: str, purpose: str):
        delivered.update(email=email, code=code, purpose=purpose)

    monkeypatch.setattr(account_api, "send_verification_email", capture_email)
    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session

    with TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/code",
            json={"email": "USER@example.com", "purpose": "register"},
        )
        assert response.status_code == 202
        assert delivered["email"] == "user@example.com"
        assert delivered["purpose"] == "register"
        assert delivered["code"].isdigit()

        async def stored_code():
            async with sessions() as session:
                return await session.scalar(select(VerifyCode.code))

        digest = asyncio.run(stored_code())
        assert digest != delivered["code"]
        assert len(digest) == 64

        response = client.post(
            "/api/v1/auth/register",
            json={
                "email": "USER@example.com",
                "nickname": "星野",
                "password": "password-123",
                "code": delivered["code"],
            },
        )
        assert response.status_code == 201
        body = response.json()
        token = body["access_token"]
        assert body["user"]["email"] == "user@example.com"
        assert token

        response = client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200
        assert response.json()["user"]["nickname"] == "星野"

        response = client.post(
            "/api/v1/auth/password/verify",
            json={"password": "wrong-password"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 400
        response = client.post(
            "/api/v1/auth/password/verify",
            json={"password": "password-123"},
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 204

        response = client.post(
            "/api/v1/auth/logout",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 204
        response = client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401

        response = client.post(
            "/api/v1/auth/login",
            json={"email": "user@example.com", "password": "wrong-password"},
        )
        assert response.status_code == 401
        response = client.post(
            "/api/v1/auth/login",
            json={"email": "user@example.com", "password": "password-123"},
        )
        assert response.status_code == 200
        token = response.json()["access_token"]
        assert token

        monkeypatch.setattr(account_api, "decode_jwt", lambda _token: None)
        response = client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401

        response = client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401

    asyncio.run(engine.dispose())


def test_registration_code_requires_configured_email_delivery(tmp_path, monkeypatch):
    database_path = (tmp_path / "email-unavailable.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(prepare())

    async def get_test_session():
        async with sessions() as session:
            yield session

    async def unavailable(*_args):
        raise account_api.EmailDeliveryUnavailable("SMTP is not configured")

    monkeypatch.setattr(account_api, "send_verification_email", unavailable)
    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session

    with TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/code",
            json={"email": "smtp-missing@example.com", "purpose": "register"},
        )
        assert response.status_code == 503
        assert response.json()["detail"] == "邮件服务尚未配置"

    asyncio.run(engine.dispose())


def test_tokens_are_unique_and_long_unicode_passwords_are_supported():
    assert create_jwt(1) != create_jwt(1)

    password = "星野的安全密码" * 20
    hashed = hash_password(password)
    assert hashed.startswith("$bcrypt-sha256$")
    assert verify_password(password, hashed)
    assert not verify_password(password + "错误", hashed)
