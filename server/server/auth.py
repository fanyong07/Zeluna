"""
JWT 认证 + Protobuf token 解析
"""

import asyncio
import hashlib
import secrets
import struct
import time
from typing import NamedTuple

import bcrypt
import jwt
from fastapi import Header, HTTPException
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .config import (
    SECRET_KEY,
    JWT_ALGORITHM,
    ACCESS_TOKEN_EXPIRE,
    REFRESH_TOKEN_EXPIRE_SECONDS,
    LEGACY_ACCOUNT_API_ENABLED,
    LEGACY_JWT_COMPATIBILITY_ENABLED,
)
from .database import RefreshTokenHistory, User, UserToken
from .privacy import purge_expired_auth_artifacts


_BCRYPT_SHA256_PREFIX = "$bcrypt-sha256$"
_JWT_ISSUER = "zeluna"
_JWT_AUDIENCE = "zeluna-clients"
_INSECURE_SECRET_KEYS = {
    "anich-secret-key-change-in-production",
    "change-me",
    "secret",
}


class AuthConfigurationError(RuntimeError):
    pass


class RefreshTokenError(RuntimeError):
    """Base error for rejected refresh credentials."""


class RefreshTokenReuseDetected(RefreshTokenError):
    pass


class RefreshTokenRejected(RefreshTokenError):
    pass


class SessionCredentials(NamedTuple):
    access_token: str
    refresh_token: str
    session_id: str
    device_id: str
    device_name: str
    platform: str
    access_expires_at: float
    refresh_expires_at: float


def signing_key() -> str:
    key = SECRET_KEY.strip()
    if (
        len(key.encode("utf-8")) < 32
        or len(set(key)) < 8
        or key.casefold() in _INSECURE_SECRET_KEYS
    ):
        raise AuthConfigurationError(
            "SECRET_KEY must be a unique random value of at least 32 bytes"
        )
    return key


def _password_bytes(password: str) -> bytes:
    return hashlib.sha256(password.encode("utf-8")).digest()


def hash_password(password: str) -> str:
    hashed = bcrypt.hashpw(_password_bytes(password), bcrypt.gensalt()).decode()
    return _BCRYPT_SHA256_PREFIX + hashed


def verify_password(password: str, hashed: str) -> bool:
    try:
        if hashed.startswith(_BCRYPT_SHA256_PREFIX):
            digest = hashed.removeprefix(_BCRYPT_SHA256_PREFIX)
            return bcrypt.checkpw(_password_bytes(password), digest.encode())
        # Compatibility for accounts created before the SHA-256 pre-hash was
        # introduced. New passwords always use the versioned format above.
        return bcrypt.checkpw(password.encode("utf-8"), hashed.encode())
    except ValueError:
        return False


_DUMMY_PASSWORD_HASH = hash_password(secrets.token_urlsafe(32))


def verify_login_password(password: str, hashed: str | None) -> bool:
    """Always perform one current-cost bcrypt check, including missing users."""

    return verify_password(password, hashed or _DUMMY_PASSWORD_HASH)


def password_hash_needs_upgrade(hashed: str) -> bool:
    return not hashed.startswith(_BCRYPT_SHA256_PREFIX)


def create_jwt(user_id: int, session_id: str | None = None) -> str:
    now = int(time.time())
    payload = {
        "user_id": user_id,
        "sub": str(user_id),
        "jti": secrets.token_urlsafe(16),
        "iss": _JWT_ISSUER,
        "aud": _JWT_AUDIENCE,
        "exp": now + ACCESS_TOKEN_EXPIRE,
        "iat": now,
    }
    if session_id:
        payload["session_id"] = session_id
    return jwt.encode(payload, signing_key(), algorithm=JWT_ALGORITHM)


def decode_jwt(token: str) -> dict | None:
    try:
        return jwt.decode(
            token,
            signing_key(),
            algorithms=[JWT_ALGORITHM],
            audience=_JWT_AUDIENCE,
            issuer=_JWT_ISSUER,
            options={
                "require": ["exp", "iat", "jti", "sub", "iss", "aud"],
            },
        )
    except jwt.PyJWTError:
        if not LEGACY_JWT_COMPATIBILITY_ENABLED:
            return None
        try:
            legacy = jwt.decode(
                token,
                signing_key(),
                algorithms=[JWT_ALGORITHM],
                options={
                    "require": ["exp", "iat", "jti", "user_id"],
                    "verify_aud": False,
                },
            )
        except (AuthConfigurationError, jwt.PyJWTError):
            return None
        if "iss" in legacy or "aud" in legacy:
            return None
        return legacy
    except AuthConfigurationError:
        return None


def token_digest(token: str) -> str:
    return "v1:" + hashlib.sha256(token.encode()).hexdigest()


def validate_session_token(
    token: str,
    stored: UserToken,
    *,
    now: float | None = None,
) -> dict | None:
    current = time.time() if now is None else now
    if stored.expires_at > 0 and stored.expires_at <= current:
        return None
    claims = decode_jwt(token)
    if claims is None:
        return None
    if stored.session_id:
        if stored.revoked_at > 0:
            return None
        if claims.get("session_id") != stored.session_id:
            return None
        try:
            if float(claims["exp"]) <= current:
                return None
        except (KeyError, TypeError, ValueError):
            return None
        token_id = claims.get("jti")
        if (
            not isinstance(token_id, str)
            or not token_id
            or not stored.token_id
            or not secrets.compare_digest(stored.token_id, token_id)
        ):
            return None
        return claims
    user_id = claims.get("user_id")
    if isinstance(user_id, bool) or not isinstance(user_id, int):
        return None
    if user_id != stored.user_id:
        return None
    subject = claims.get("sub")
    if subject is not None and subject != str(stored.user_id):
        return None
    token_id = claims.get("jti")
    if not isinstance(token_id, str) or not token_id:
        return None
    if stored.token_id and not secrets.compare_digest(stored.token_id, token_id):
        return None
    try:
        claim_expiry = float(claims["exp"])
    except (KeyError, TypeError, ValueError):
        return None
    if stored.expires_at > 0 and stored.expires_at != claim_expiry:
        return None
    return claims


def bind_session_claims(stored: UserToken, claims: dict) -> bool:
    changed = False
    if stored.expires_at <= 0:
        stored.expires_at = float(claims["exp"])
        changed = True
    if not stored.token_id:
        stored.token_id = str(claims["jti"])
        changed = True
    return changed


_REFRESH_LOCK = asyncio.Lock()


async def issue_session_credentials(
    session: AsyncSession,
    user_id: int,
    *,
    device_id: str = "",
    device_name: str = "",
    platform: str = "",
) -> SessionCredentials:
    now = time.time()
    session_id = secrets.token_urlsafe(24)
    token_family_id = secrets.token_urlsafe(24)
    refresh_token = secrets.token_urlsafe(48)
    access_token = create_jwt(user_id, session_id)
    claims = decode_jwt(access_token)
    if claims is None:
        raise AuthConfigurationError("newly issued account token could not be decoded")
    refresh_expires_at = now + REFRESH_TOKEN_EXPIRE_SECONDS
    await purge_expired_auth_artifacts(session)
    session.add(
        UserToken(
            user_id=user_id,
            token=token_digest(refresh_token),
            token_id=str(claims["jti"]),
            expires_at=refresh_expires_at,
            session_id=session_id,
            device_id=device_id[:128],
            device_name=device_name[:80],
            platform=platform[:32],
            token_family_id=token_family_id,
            last_used_at=now,
        )
    )
    session.add(
        RefreshTokenHistory(
            user_id=user_id,
            session_id=session_id,
            token_family_id=token_family_id,
            digest=token_digest(refresh_token),
            created_at=now,
        )
    )
    await session.flush()
    existing = list(
        await session.scalars(
            select(UserToken)
            .where(UserToken.user_id == user_id)
            .order_by(UserToken.created_at.desc(), UserToken.id.desc())
        )
    )
    for stale_token in existing[4:]:
        await session.delete(stale_token)
    return SessionCredentials(
        access_token=access_token,
        refresh_token=refresh_token,
        session_id=session_id,
        device_id=device_id[:128],
        device_name=device_name[:80],
        platform=platform[:32],
        access_expires_at=float(claims["exp"]),
        refresh_expires_at=refresh_expires_at,
    )


async def issue_session_token(session: AsyncSession, user_id: int) -> str:
    """Compatibility wrapper returning only the new short-lived access token."""
    credentials = await issue_session_credentials(session, user_id)
    return credentials.access_token


async def rotate_refresh_token(
    session: AsyncSession,
    refresh_token: str,
) -> SessionCredentials:
    """Rotate one opaque refresh token and reject any reuse of old digests."""
    digest = token_digest(refresh_token.strip())
    if not refresh_token.strip():
        raise RefreshTokenRejected("refresh token is empty")
    async with _REFRESH_LOCK:
        history = await session.scalar(
            select(RefreshTokenHistory).where(RefreshTokenHistory.digest == digest)
        )
        if history is None:
            raise RefreshTokenRejected("refresh token is invalid")
        if history.used_at > 0:
            now = time.time()
            history.reuse_detected_at = now
            await session.execute(
                update(UserToken)
                .where(UserToken.token_family_id == history.token_family_id)
                .values(revoked_at=now)
            )
            await session.commit()
            raise RefreshTokenReuseDetected("refresh token reuse detected")

        current = await session.scalar(
            select(UserToken).where(
                UserToken.session_id == history.session_id,
                UserToken.token == digest,
            )
        )
        now = time.time()
        if (
            current is None
            or current.revoked_at > 0
            or current.expires_at <= now
            or current.token_family_id != history.token_family_id
        ):
            raise RefreshTokenRejected("refresh session is invalid")

        user = await session.get(User, current.user_id)
        if user is None:
            raise RefreshTokenRejected("refresh session is invalid")
        new_refresh = secrets.token_urlsafe(48)
        new_digest = token_digest(new_refresh)
        access_token = create_jwt(user.id, current.session_id)
        claims = decode_jwt(access_token)
        if claims is None:
            raise AuthConfigurationError("rotated access token could not be decoded")
        history.used_at = now
        history.replaced_by_digest = new_digest
        current.token = new_digest
        current.token_id = str(claims["jti"])
        current.last_used_at = now
        current.refresh_rotated_at = now
        session.add(
            RefreshTokenHistory(
                user_id=current.user_id,
                session_id=current.session_id or "",
                token_family_id=current.token_family_id,
                digest=new_digest,
                created_at=now,
            )
        )
        await session.commit()
        return SessionCredentials(
            access_token=access_token,
            refresh_token=new_refresh,
            session_id=current.session_id or "",
            device_id=current.device_id,
            device_name=current.device_name,
            platform=current.platform,
            access_expires_at=float(claims["exp"]),
            refresh_expires_at=current.expires_at,
        )


def generate_verify_code() -> str:
    return str(secrets.randbelow(900000) + 100000)


class ProtobufToken(NamedTuple):
    token: str
    time: str


def parse_protobuf_token(raw: str) -> ProtobufToken | None:
    """
    解析 AniCh 客户端发来的 protobuf 编码的 token。

    格式：字节流中字段 1 = token 字符串，字段 2 = time 字符串。
    客户端发送的是逗号分隔的字节数组：1,2,3,...
    """
    try:
        parts = [int(x) for x in raw.split(",") if x.strip().isdigit()]
        if not parts:
            return None
        data = bytes(parts)
        return _decode_token_protobuf(data)
    except (ValueError, struct.error):
        pass

    try:
        # 尝试直接作为纯文本 token（兼容直接传 jwt）
        return ProtobufToken(token=raw, time="0")
    except Exception:
        return None


def _decode_token_protobuf(data: bytes) -> ProtobufToken | None:
    token_str = ""
    time_str = ""
    pos = 0
    while pos < len(data):
        if pos >= len(data):
            break
        tag = data[pos]
        pos += 1
        field_number = tag >> 3
        wire_type = tag & 0x07
        if wire_type == 2:  # Length-delimited
            if pos >= len(data):
                break
            length = data[pos]
            pos += 1
            value = data[pos : pos + length].decode("utf-8", errors="replace")
            pos += length
            if field_number == 1:
                token_str = value
            elif field_number == 2:
                time_str = value
        elif wire_type == 0:  # Varint
            value = 0
            shift = 0
            while pos < len(data):
                byte = data[pos]
                pos += 1
                value |= (byte & 0x7F) << shift
                if not (byte & 0x80):
                    break
                shift += 7
        else:
            break

    if token_str:
        return ProtobufToken(token=token_str, time=time_str)
    return None


async def get_current_user(
    token_header: str | None = Header(None, alias="_"),
    session: AsyncSession | None = None,
) -> User | None:
    """从 _ header 解析 protobuf token 并返回用户。"""
    if not token_header or not session:
        return None

    parsed = parse_protobuf_token(token_header)
    if parsed is None:
        return None

    claims = decode_jwt(parsed.token)
    session_id = claims.get("session_id") if isinstance(claims, dict) else None
    if isinstance(session_id, str) and session_id:
        # New access tokens are bound to a device session. The database stores
        # only the refresh-token digest, so resolve them by session id.
        user_token = await session.scalar(
            select(UserToken).where(UserToken.session_id == session_id)
        )
    else:
        # Legacy rows may still contain a digest (or, only when the explicitly
        # bounded legacy API is enabled, the historical raw token).
        accepted_tokens = [token_digest(parsed.token)]
        if LEGACY_ACCOUNT_API_ENABLED:
            accepted_tokens.append(parsed.token)
        result = await session.execute(
            select(UserToken).where(UserToken.token.in_(accepted_tokens))
        )
        user_token = result.scalar_one_or_none()
    if user_token:
        claims = validate_session_token(parsed.token, user_token)
        if claims is None:
            # An expired access token must not destroy a still-valid refresh
            # session. Legacy rows have no refresh lifecycle and can be safely
            # removed once they fail validation.
            if not user_token.session_id:
                await session.delete(user_token)
                await session.commit()
            return None
        if bind_session_claims(user_token, claims):
            await session.commit()
        stmt = select(User).where(User.id == user_token.user_id)
        result = await session.execute(stmt)
        user = result.scalar_one_or_none()
        if user is None:
            await session.delete(user_token)
            await session.commit()
        return user

    return None
