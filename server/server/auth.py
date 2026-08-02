"""
JWT 认证 + Protobuf token 解析
"""

import hashlib
import secrets
import struct
import time
from typing import NamedTuple

import bcrypt
import jwt
from fastapi import Header, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import (
    SECRET_KEY,
    JWT_ALGORITHM,
    ACCESS_TOKEN_EXPIRE,
    LEGACY_ACCOUNT_API_ENABLED,
)
from .database import User, UserToken


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


def create_jwt(user_id: int) -> str:
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

    # New sessions are stored as SHA-256 digests so a database leak cannot be
    # replayed as a bearer token. Raw legacy tokens are accepted only when the
    # old account API is explicitly enabled.
    token_digest = "v1:" + hashlib.sha256(parsed.token.encode()).hexdigest()
    accepted_tokens = [token_digest]
    if LEGACY_ACCOUNT_API_ENABLED:
        accepted_tokens.append(parsed.token)
    stmt = select(UserToken).where(UserToken.token.in_(accepted_tokens))
    result = await session.execute(stmt)
    user_token = result.scalar_one_or_none()
    if user_token:
        stmt = select(User).where(User.id == user_token.user_id)
        result = await session.execute(stmt)
        return result.scalar_one_or_none()

    return None
