import asyncio
import time

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api
from server import auth
from server.auth import (
    AuthConfigurationError,
    create_jwt,
    decode_jwt,
    hash_password,
    verify_password,
)
from server.database import Base, VerifyCode

_TEST_SECRET = "zeluna-test-signing-key-with-more-than-32-bytes"


@pytest.fixture(autouse=True)
def secure_test_signing_key(monkeypatch):
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)


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

    claims = decode_jwt(create_jwt(1))
    assert claims is not None
    assert claims["sub"] == "1"
    assert claims["iss"] == "zeluna"
    assert claims["aud"] == "zeluna-clients"

    password = "星野的安全密码" * 20
    hashed = hash_password(password)
    assert hashed.startswith("$bcrypt-sha256$")
    assert verify_password(password, hashed)
    assert not verify_password(password + "错误", hashed)


def test_legacy_signed_session_without_issuer_remains_temporarily_compatible():
    now = int(time.time())
    legacy = jwt.encode(
        {
            "user_id": 7,
            "jti": "legacy-session",
            "iat": now,
            "exp": now + 60,
        },
        _TEST_SECRET,
        algorithm="HS256",
    )
    wrong_issuer = jwt.encode(
        {
            "user_id": 7,
            "sub": "7",
            "jti": "wrong-issuer",
            "iss": "other-service",
            "aud": "zeluna-clients",
            "iat": now,
            "exp": now + 60,
        },
        _TEST_SECRET,
        algorithm="HS256",
    )

    assert decode_jwt(legacy)["user_id"] == 7
    assert decode_jwt(wrong_issuer) is None


@pytest.mark.parametrize(
    "value",
    [
        "short-secret",
        "a" * 64,
        "anich-secret-key-change-in-production",
    ],
)
def test_weak_or_historical_signing_keys_are_rejected(value, monkeypatch):
    monkeypatch.setattr(auth, "SECRET_KEY", value)

    with pytest.raises(AuthConfigurationError):
        auth.signing_key()


def test_missing_or_weak_signing_key_fails_closed(tmp_path, monkeypatch):
    monkeypatch.setattr(auth, "SECRET_KEY", "")
    with pytest.raises(AuthConfigurationError):
        create_jwt(1)

    database_path = (tmp_path / "missing-secret.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(prepare())

    async def get_test_session():
        async with sessions() as session:
            yield session

    async def reject_email(*_args):
        raise AssertionError("missing signing key must stop before email delivery")

    monkeypatch.setattr(account_api, "send_verification_email", reject_email)
    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session

    with TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/code",
            json={"email": "missing-secret@example.com", "purpose": "register"},
        )

    assert response.status_code == 503
    assert response.json()["detail"] == "账号服务安全配置不可用"
    asyncio.run(engine.dispose())
