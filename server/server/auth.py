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

from .config import SECRET_KEY, JWT_ALGORITHM, ACCESS_TOKEN_EXPIRE
from .database import User, UserToken


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str, hashed: str) -> bool:
    return bcrypt.checkpw(password.encode(), hashed.encode())


def create_jwt(user_id: int) -> str:
    payload = {
        "user_id": user_id,
        "exp": int(time.time()) + ACCESS_TOKEN_EXPIRE,
        "iat": int(time.time()),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALGORITHM)


def decode_jwt(token: str) -> dict | None:
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[JWT_ALGORITHM])
    except jwt.PyJWTError:
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

    # 先尝试从数据库找 token
    stmt = select(UserToken).where(UserToken.token == parsed.token)
    result = await session.execute(stmt)
    user_token = result.scalar_one_or_none()
    if user_token:
        stmt = select(User).where(User.id == user_token.user_id)
        result = await session.execute(stmt)
        return result.scalar_one_or_none()

    # 再尝试 JWT 解码
    payload = decode_jwt(parsed.token)
    if payload:
        user_id = payload.get("user_id")
        if user_id:
            stmt = select(User).where(User.id == user_id)
            result = await session.execute(stmt)
            return result.scalar_one_or_none()

    return None
