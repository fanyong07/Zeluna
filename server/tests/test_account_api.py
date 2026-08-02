import asyncio
import ipaddress
import time

import jwt
import pytest
import run_prod
from fastapi import FastAPI
from fastapi import HTTPException
from fastapi.testclient import TestClient
from starlette.requests import Request
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
    account_api._attempts.clear()
    yield
    account_api._attempts.clear()


def _request(client_host: str, real_ip: str | None = None) -> Request:
    headers = []
    if real_ip is not None:
        headers.append((b"x-real-ip", real_ip.encode("ascii")))
    return Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/api/v1/auth/login",
            "headers": headers,
            "client": (client_host, 12345),
        }
    )


def test_client_ip_header_is_only_honored_for_an_explicit_trusted_proxy(
    monkeypatch,
):
    spoofed = _request("203.0.113.10", "198.51.100.42")
    monkeypatch.setattr(account_api, "ACCOUNT_TRUSTED_PROXY_NETWORKS", ())
    assert account_api._client_key(spoofed) == "203.0.113.10"

    monkeypatch.setattr(
        account_api,
        "ACCOUNT_TRUSTED_PROXY_NETWORKS",
        (ipaddress.ip_network("127.0.0.0/8"),),
    )
    proxied = _request("127.0.0.1", "2001:db8::7")
    malformed = _request("127.0.0.1", "198.51.100.1, 203.0.113.2")
    mapped_proxy = _request("::ffff:127.0.0.1", "::ffff:198.51.100.42")
    assert account_api._client_key(proxied) == "2001:db8::7"
    assert account_api._client_key(malformed) == "127.0.0.1"
    assert account_api._client_key(mapped_proxy) == "198.51.100.42"


def test_attempt_store_is_bounded_and_only_reclaims_expired_keys():
    attempts = account_api._AttemptStore(max_keys=2)
    attempts.check("first", limit=2, window_seconds=10, now=0)
    attempts.check("second", limit=2, window_seconds=10, now=0)

    with pytest.raises(HTTPException) as saturated:
        attempts.check("third", limit=2, window_seconds=10, now=1)
    assert saturated.value.status_code == 429
    assert len(attempts) == 2

    attempts.check("third", limit=2, window_seconds=10, now=11)
    assert len(attempts) == 1


def test_attempt_store_returns_retry_after_without_growing():
    attempts = account_api._AttemptStore(max_keys=2)
    attempts.check("login", limit=1, window_seconds=10, now=5)

    with pytest.raises(HTTPException) as limited:
        attempts.check("login", limit=1, window_seconds=10, now=7)
    assert limited.value.status_code == 429
    assert limited.value.headers == {"Retry-After": "8"}
    assert len(attempts) == 1


def test_production_runner_disables_implicit_proxy_header_trust(monkeypatch):
    for name in ("TMDB_READ_ACCESS_TOKEN", "ADMIN_TOKEN", "SECRET_KEY"):
        monkeypatch.setenv(name, f"test-{name.lower()}-with-at-least-32-bytes")
    monkeypatch.setenv("SMTP_HOST", "smtp.invalid")
    monkeypatch.setenv("SMTP_FROM_EMAIL", "noreply@example.invalid")
    captured = {}
    monkeypatch.setattr(
        run_prod.uvicorn,
        "run",
        lambda *args, **kwargs: captured.update(kwargs),
    )

    run_prod.main()

    assert captured["proxy_headers"] is False


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


def test_verification_code_locks_after_email_and_purpose_failure_budget(
    tmp_path, monkeypatch
):
    database_path = (tmp_path / "code-attempts.db").as_posix()
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
    monkeypatch.setattr(
        account_api,
        "_client_key",
        lambda request: request.headers.get("X-Test-Client", "test-client"),
    )
    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session

    with TestClient(app) as client:
        sent = client.post(
            "/api/v1/auth/code",
            json={"email": "attempts@example.com", "purpose": "register"},
        )
        assert sent.status_code == 202

        payload = {
            "email": "attempts@example.com",
            "nickname": "attempt-budget",
            "password": "password-123",
            "code": "000000" if delivered["code"] != "000000" else "111111",
        }
        for attempt in range(account_api._MAX_CODE_FAILURES - 1):
            response = client.post(
                "/api/v1/auth/register",
                json=payload,
                headers={"X-Test-Client": f"client-{attempt}"},
            )
            assert response.status_code == 400
        locked = client.post(
            "/api/v1/auth/register",
            json=payload,
            headers={"X-Test-Client": "client-lock"},
        )
        assert locked.status_code == 429
        assert int(locked.headers["Retry-After"]) > 0

        payload["code"] = delivered["code"]
        still_locked = client.post(
            "/api/v1/auth/register",
            json=payload,
            headers={"X-Test-Client": "client-correct"},
        )
        assert still_locked.status_code == 429

        resent = client.post(
            "/api/v1/auth/code",
            json={"email": "attempts@example.com", "purpose": "register"},
        )
        assert resent.status_code == 202
        payload["code"] = delivered["code"]
        registered = client.post(
            "/api/v1/auth/register",
            json=payload,
            headers={"X-Test-Client": "client-new-code"},
        )
        assert registered.status_code == 201

    async def stored_attempts():
        async with sessions() as session:
            record = await session.scalar(
                select(VerifyCode).where(
                    VerifyCode.email == "attempts@example.com",
                    VerifyCode.purpose == "register",
                )
            )
            return record.failed_attempts if record else None

    assert asyncio.run(stored_attempts()) is None
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
