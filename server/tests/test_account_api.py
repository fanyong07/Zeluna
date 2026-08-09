import asyncio
import ipaddress
import time

import bcrypt
import jwt
import pytest
import run_prod
from cryptography.fernet import Fernet
from fastapi import FastAPI
from fastapi import HTTPException
from fastapi.testclient import TestClient
from starlette.requests import Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import account_api
from server import auth
from server import email_outbox
from server.auth import (
    AuthConfigurationError,
    create_jwt,
    decode_jwt,
    hash_password,
    token_digest,
    validate_session_token,
    verify_password,
)
from server.database import Base, EmailOutbox, User, UserToken, VerifyCode
from server.email_outbox import EmailOutboxWorker

_TEST_SECRET = "zeluna-test-signing-key-with-more-than-32-bytes"


@pytest.fixture(autouse=True)
def secure_test_signing_key(monkeypatch):
    monkeypatch.setattr(auth, "SECRET_KEY", _TEST_SECRET)
    monkeypatch.setattr(
        email_outbox,
        "EMAIL_OUTBOX_ENCRYPTION_KEY",
        Fernet.generate_key().decode("ascii"),
    )
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
        async def queued_outbox():
            async with sessions() as session:
                return await session.scalar(select(EmailOutbox))

        queued = asyncio.run(queued_outbox())
        assert queued is not None
        assert queued.encrypted_payload
        assert "123456" not in queued.encrypted_payload
        asyncio.run(EmailOutboxWorker(sessions, sender=capture_email).run_once())
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
        first_login_token = response.json()["access_token"]
        assert first_login_token

        response = client.post(
            "/api/v1/auth/login",
            json={"email": "user@example.com", "password": "password-123"},
        )
        assert response.status_code == 200
        current_token = response.json()["access_token"]
        changed = client.post(
            "/api/v1/auth/password",
            json={
                "current_password": "password-123",
                "new_password": "password-456",
            },
            headers={"Authorization": f"Bearer {current_token}"},
        )
        assert changed.status_code == 200
        assert client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {first_login_token}"},
        ).status_code == 401
        assert client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {current_token}"},
        ).status_code == 200

        reset_code = client.post(
            "/api/v1/auth/code",
            json={"email": "user@example.com", "purpose": "reset_password"},
        )
        assert reset_code.status_code == 202
        asyncio.run(EmailOutboxWorker(sessions, sender=capture_email).run_once())
        reset = client.post(
            "/api/v1/auth/password/reset",
            json={
                "email": "user@example.com",
                "code": delivered["code"],
                "new_password": "password-789",
            },
        )
        assert reset.status_code == 200
        assert client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {current_token}"},
        ).status_code == 401
        assert client.post(
            "/api/v1/auth/login",
            json={"email": "user@example.com", "password": "password-456"},
        ).status_code == 401
        response = client.post(
            "/api/v1/auth/login",
            json={"email": "user@example.com", "password": "password-789"},
        )
        token = response.json()["access_token"]

        monkeypatch.setattr(
            account_api,
            "validate_session_token",
            lambda *_args: None,
        )
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
        assert response.status_code == 202
        result = asyncio.run(
            EmailOutboxWorker(sessions, sender=unavailable).run_once()
        )
        assert result["retry"] == 1

    asyncio.run(engine.dispose())


def test_unverified_email_cannot_enumerate_existing_registration(
    tmp_path, monkeypatch
):
    database_path = (tmp_path / "registration-enumeration.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            session.add(
                User(
                    email="existing@example.com",
                    name="existing-user",
                    password_hash=hash_password("password-123"),
                )
            )
            await session.commit()

    asyncio.run(prepare())

    async def get_test_session():
        async with sessions() as session:
            yield session

    async def reject_email(*_args):
        raise AssertionError("existing registration must not send a new code")

    monkeypatch.setattr(account_api, "send_verification_email", reject_email)
    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session

    with TestClient(app) as client:
        code_response = client.post(
            "/api/v1/auth/code",
            json={"email": "existing@example.com", "purpose": "register"},
        )
        register_response = client.post(
            "/api/v1/auth/register",
            json={
                "email": "existing@example.com",
                "nickname": "attacker",
                "password": "password-456",
                "code": "000000",
            },
        )

    assert code_response.status_code == 202
    assert code_response.json() == {"message": account_api._CODE_REQUEST_MESSAGE}
    assert register_response.status_code == 400
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
        asyncio.run(EmailOutboxWorker(sessions, sender=capture_email).run_once())

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
        asyncio.run(EmailOutboxWorker(sessions, sender=capture_email).run_once())
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


def test_login_checks_dummy_hash_for_missing_user(tmp_path, monkeypatch):
    database_path = (tmp_path / "missing-login.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    asyncio.run(prepare())

    async def get_test_session():
        async with sessions() as session:
            yield session

    checked = []
    real_verify = account_api.verify_login_password

    def capture_verify(password: str, hashed: str | None) -> bool:
        checked.append(hashed)
        return real_verify(password, hashed)

    monkeypatch.setattr(account_api, "verify_login_password", capture_verify)
    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session

    with TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/login",
            json={"email": "missing@example.com", "password": "password-123"},
        )

    assert response.status_code == 401
    assert checked == [None]
    asyncio.run(engine.dispose())


def test_successful_login_upgrades_legacy_bcrypt_hash(tmp_path):
    database_path = (tmp_path / "legacy-password.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    password = "legacy-password-123"
    legacy_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()

    async def prepare():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            session.add(
                User(
                    email="legacy-login@example.com",
                    name="legacy-login",
                    password_hash=legacy_hash,
                )
            )
            await session.commit()

    asyncio.run(prepare())

    async def get_test_session():
        async with sessions() as session:
            yield session

    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session

    with TestClient(app) as client:
        rejected = client.post(
            "/api/v1/auth/login",
            json={"email": "legacy-login@example.com", "password": "wrong"},
        )
        assert rejected.status_code == 401
        accepted = client.post(
            "/api/v1/auth/login",
            json={"email": "legacy-login@example.com", "password": password},
        )
        assert accepted.status_code == 200

    async def stored_hash():
        async with sessions() as session:
            user = await session.scalar(
                select(User).where(User.email == "legacy-login@example.com")
            )
            return user.password_hash

    upgraded = asyncio.run(stored_hash())
    assert upgraded != legacy_hash
    assert upgraded.startswith("$bcrypt-sha256$")
    assert verify_password(password, upgraded)
    asyncio.run(engine.dispose())


def test_session_issue_removes_expired_rows_and_keeps_latest_four(tmp_path):
    database_path = (tmp_path / "session-lifecycle.db").as_posix()
    engine = create_async_engine(f"sqlite+aiosqlite:///{database_path}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)

    async def exercise():
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            user = User(
                email="sessions@example.com",
                name="session-user",
                password_hash=hash_password("password-123"),
            )
            session.add(user)
            await session.flush()
            session.add(
                UserToken(
                    user_id=user.id,
                    token=token_digest("expired-token"),
                    token_id="expired-id",
                    expires_at=time.time() - 1,
                )
            )
            await session.commit()
            tokens = []
            for _ in range(5):
                tokens.append(await account_api._issue_token(session, user))
            rows = list(
                await session.scalars(
                    select(UserToken).where(UserToken.user_id == user.id)
                )
            )
            return tokens, rows

    tokens, rows = asyncio.run(exercise())
    assert len(rows) == 4
    assert all(row.expires_at > time.time() for row in rows)
    assert all(row.token_id for row in rows)
    assert token_digest("expired-token") not in {row.token for row in rows}

    async def get_test_session():
        async with sessions() as session:
            yield session

    app = FastAPI()
    app.include_router(account_api.router)
    app.dependency_overrides[account_api.get_session] = get_test_session
    with TestClient(app) as client:
        oldest = client.get(
            "/api/v1/auth/me",
            headers={"Authorization": f"Bearer {tokens[0]}"},
        )
        newest = [
            client.get(
                "/api/v1/auth/me",
                headers={"Authorization": f"Bearer {token}"},
            ).status_code
            for token in tokens[1:]
        ]

    assert oldest.status_code == 401
    assert newest == [200, 200, 200, 200]
    asyncio.run(engine.dispose())


def test_stored_session_binds_subject_and_token_identifier():
    token = create_jwt(7)
    claims = decode_jwt(token)
    stored = UserToken(
        user_id=7,
        token=token_digest(token),
        token_id=claims["jti"],
        expires_at=float(claims["exp"]),
    )
    assert validate_session_token(token, stored) is not None

    stored.token_id = "different-token-id"
    assert validate_session_token(token, stored) is None
    stored.token_id = claims["jti"]
    stored.expires_at = float(claims["exp"]) + 1
    assert validate_session_token(token, stored) is None

    now = int(time.time())
    wrong_subject = jwt.encode(
        {
            "user_id": 7,
            "sub": "8",
            "jti": "wrong-subject",
            "iss": "zeluna",
            "aud": "zeluna-clients",
            "iat": now,
            "exp": now + 60,
        },
        _TEST_SECRET,
        algorithm="HS256",
    )
    wrong_subject_row = UserToken(
        user_id=7,
        token=token_digest(wrong_subject),
        token_id="wrong-subject",
        expires_at=now + 60,
    )
    assert validate_session_token(wrong_subject, wrong_subject_row) is None


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


def test_legacy_jwt_compatibility_is_disabled_by_default():
    assert auth.LEGACY_JWT_COMPATIBILITY_ENABLED is False


def test_legacy_signed_session_can_be_enabled_for_migration(monkeypatch):
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

    monkeypatch.setattr(auth, "LEGACY_JWT_COMPATIBILITY_ENABLED", True)

    assert decode_jwt(legacy)["user_id"] == 7
    assert decode_jwt(wrong_issuer) is None


def test_legacy_signed_session_is_rejected_after_compatibility_gate_closes(
    monkeypatch,
):
    now = int(time.time())
    legacy = jwt.encode(
        {
            "user_id": 7,
            "jti": "legacy-disabled",
            "iat": now,
            "exp": now + 60,
        },
        _TEST_SECRET,
        algorithm="HS256",
    )
    monkeypatch.setattr(auth, "LEGACY_JWT_COMPATIBILITY_ENABLED", False)

    assert decode_jwt(legacy) is None


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


def test_issue_credentials_reports_utf8_auth_configuration_error(monkeypatch):
    async def reject_credentials(*_args, **_kwargs):
        raise AuthConfigurationError("missing signing key")

    monkeypatch.setattr(account_api, "issue_session_credentials", reject_credentials)

    with pytest.raises(HTTPException) as raised:
        asyncio.run(
            account_api._issue_credentials(
                object(),
                User(id=7),
                device_id="test-device",
                device_name="Test Device",
                platform="test",
            )
        )

    assert raised.value.status_code == 503
    assert raised.value.detail == "账号服务安全配置不可用"


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
