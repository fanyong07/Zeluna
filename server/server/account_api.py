"""Production JSON API for cloud email accounts."""

import hashlib
import hmac
import ipaddress
import time
from collections import deque
from dataclasses import dataclass
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, EmailStr, Field, field_validator
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .auth import (
    AuthConfigurationError,
    create_jwt,
    decode_jwt,
    generate_verify_code,
    hash_password,
    signing_key,
    verify_password,
)
from .config import ACCOUNT_RATE_LIMIT_MAX_KEYS, ACCOUNT_TRUSTED_PROXY_NETWORKS
from .database import User, UserToken, VerifyCode
from .dependencies import get_session
from .email_service import EmailDeliveryUnavailable, send_verification_email

router = APIRouter(prefix="/api/v1/auth", tags=["account"])

_MAX_CODE_FAILURES = 5


class VerificationCodeRequest(BaseModel):
    email: EmailStr
    purpose: Literal["register", "reset_password"] = "register"


class RegisterRequest(BaseModel):
    email: EmailStr
    nickname: str = Field(min_length=1, max_length=40)
    password: str = Field(min_length=8, max_length=128)
    code: str = Field(pattern=r"^\d{6}$")

    @field_validator("nickname")
    @classmethod
    def normalize_nickname(cls, value: str) -> str:
        normalized = " ".join(value.split())
        if not normalized:
            raise ValueError("nickname is empty")
        return normalized


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


class VerifyPasswordRequest(BaseModel):
    password: str = Field(min_length=1, max_length=128)


class ResetPasswordRequest(BaseModel):
    email: EmailStr
    code: str = Field(pattern=r"^\d{6}$")
    new_password: str = Field(min_length=8, max_length=128)


class ProfileRequest(BaseModel):
    nickname: str = Field(min_length=1, max_length=40)

    @field_validator("nickname")
    @classmethod
    def normalize_nickname(cls, value: str) -> str:
        normalized = " ".join(value.split())
        if not normalized:
            raise ValueError("nickname is empty")
        return normalized


@dataclass
class _AttemptBucket:
    events: deque[float]
    window_seconds: int


class _AttemptStore:
    """Bound the process-local fallback limiter without evicting active keys."""

    def __init__(self, max_keys: int):
        self._max_keys = max_keys
        self._buckets: dict[str, _AttemptBucket] = {}

    def clear(self) -> None:
        self._buckets.clear()

    def __len__(self) -> int:
        return len(self._buckets)

    def _purge_expired(self, now: float) -> None:
        expired: list[str] = []
        for key, bucket in self._buckets.items():
            cutoff = now - bucket.window_seconds
            while bucket.events and bucket.events[0] <= cutoff:
                bucket.events.popleft()
            if not bucket.events:
                expired.append(key)
        for key in expired:
            self._buckets.pop(key, None)

    def check(
        self,
        key: str,
        *,
        limit: int,
        window_seconds: int,
        now: float | None = None,
    ) -> None:
        current = time.monotonic() if now is None else now
        bucket = self._buckets.get(key)
        if bucket is None:
            if len(self._buckets) >= self._max_keys:
                self._purge_expired(current)
            if len(self._buckets) >= self._max_keys:
                raise _too_many_requests(window_seconds)
            bucket = _AttemptBucket(deque(), window_seconds)
            self._buckets[key] = bucket
        else:
            bucket.window_seconds = window_seconds

        cutoff = current - window_seconds
        while bucket.events and bucket.events[0] <= cutoff:
            bucket.events.popleft()
        if len(bucket.events) >= limit:
            retry_after = max(1, int(window_seconds - (current - bucket.events[0])))
            raise _too_many_requests(retry_after)
        bucket.events.append(current)


def _too_many_requests(retry_after: int) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        detail="请求过于频繁，请稍后再试",
        headers={"Retry-After": str(max(1, retry_after))},
    )


_attempts = _AttemptStore(ACCOUNT_RATE_LIMIT_MAX_KEYS)


def _client_key(request: Request) -> str:
    peer = request.client.host if request.client else "unknown"
    try:
        peer_address = ipaddress.ip_address(peer)
    except ValueError:
        return peer
    if isinstance(peer_address, ipaddress.IPv6Address) and peer_address.ipv4_mapped:
        peer_address = peer_address.ipv4_mapped

    if any(peer_address in network for network in ACCOUNT_TRUSTED_PROXY_NETWORKS):
        forwarded = request.headers.get("X-Real-IP", "").strip()
        try:
            forwarded_address = ipaddress.ip_address(forwarded)
            if (
                isinstance(forwarded_address, ipaddress.IPv6Address)
                and forwarded_address.ipv4_mapped
            ):
                forwarded_address = forwarded_address.ipv4_mapped
            return forwarded_address.compressed
        except ValueError:
            pass
    return peer_address.compressed


def _rate_limit(key: str, *, limit: int, window_seconds: int) -> None:
    _attempts.check(key, limit=limit, window_seconds=window_seconds)


def _normalize_email(value: str) -> str:
    return value.strip().lower()


def _code_digest(email: str, purpose: str, code: str) -> str:
    payload = f"{purpose}:{email}:{code}".encode()
    try:
        key = signing_key().encode()
    except AuthConfigurationError as error:
        raise HTTPException(
            status_code=503,
            detail="账号服务安全配置不可用",
        ) from error
    return hmac.new(key, payload, hashlib.sha256).hexdigest()


def _token_digest(token: str) -> str:
    return "v1:" + hashlib.sha256(token.encode()).hexdigest()


def _user_payload(user: User) -> dict:
    return {
        "id": str(user.id),
        "email": user.email,
        "nickname": user.name,
        "created_at": user.created_at,
        "updated_at": user.updated_at,
    }


async def _issue_token(session: AsyncSession, user: User) -> str:
    try:
        token = create_jwt(user.id)
    except AuthConfigurationError as error:
        raise HTTPException(
            status_code=503,
            detail="账号服务安全配置不可用",
        ) from error
    session.add(UserToken(user_id=user.id, token=_token_digest(token)))
    existing = list(
        await session.scalars(
            select(UserToken)
            .where(UserToken.user_id == user.id)
            .order_by(UserToken.created_at.desc())
        )
    )
    for stale_token in existing[4:]:
        await session.delete(stale_token)
    await session.commit()
    return token


async def _current_account(
    request: Request, session: AsyncSession = Depends(get_session)
) -> tuple[User, UserToken]:
    try:
        signing_key()
    except AuthConfigurationError as error:
        raise HTTPException(
            status_code=503,
            detail="账号服务安全配置不可用",
        ) from error
    authorization = request.headers.get("Authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    result = await session.execute(
        select(UserToken).where(UserToken.token == _token_digest(token.strip()))
    )
    user_token = result.scalar_one_or_none()
    if user_token is None:
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    claims = decode_jwt(token.strip())
    if claims is None or claims.get("user_id") != user_token.user_id:
        await session.delete(user_token)
        await session.commit()
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    user = await session.get(User, user_token.user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    return user, user_token


async def _consume_code(
    session: AsyncSession, email: str, purpose: str, code: str
) -> VerifyCode:
    digest = _code_digest(email, purpose, code)
    result = await session.execute(
        select(VerifyCode).where(
            VerifyCode.email == email,
            VerifyCode.purpose == purpose,
            VerifyCode.expires_at > time.time(),
        )
        .order_by(VerifyCode.created_at.desc(), VerifyCode.id.desc())
        .limit(1)
        .with_for_update()
    )
    record = result.scalar_one_or_none()
    if record is None:
        raise HTTPException(status_code=400, detail="验证码错误或已过期")
    retry_after = max(1, int(record.expires_at - time.time()))
    if record.failed_attempts >= _MAX_CODE_FAILURES:
        raise _too_many_requests(retry_after)
    if not hmac.compare_digest(record.code, digest):
        updated = await session.execute(
            update(VerifyCode)
            .where(
                VerifyCode.id == record.id,
                VerifyCode.failed_attempts < _MAX_CODE_FAILURES,
            )
            .values(failed_attempts=VerifyCode.failed_attempts + 1)
            .returning(VerifyCode.failed_attempts)
        )
        failed_attempts = updated.scalar_one_or_none()
        await session.commit()
        if failed_attempts is None or failed_attempts >= _MAX_CODE_FAILURES:
            raise _too_many_requests(retry_after)
        raise HTTPException(status_code=400, detail="验证码错误或已过期")
    await session.delete(record)
    return record


@router.post("/code", status_code=202)
async def request_code(
    payload: VerificationCodeRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    email = _normalize_email(str(payload.email))
    _rate_limit(f"code:ip:{_client_key(request)}", limit=10, window_seconds=3600)
    _rate_limit(f"code:email:{email}", limit=5, window_seconds=3600)

    existing = await session.scalar(select(User.id).where(User.email == email))
    if payload.purpose == "register" and existing is not None:
        raise HTTPException(status_code=409, detail="这个邮箱已经注册过了")
    if payload.purpose == "reset_password" and existing is None:
        # Do not reveal whether an account exists.
        return {"message": "如果该邮箱已注册，验证码将发送到邮箱"}

    code = generate_verify_code()
    await session.execute(delete(VerifyCode).where(VerifyCode.email == email))
    session.add(
        VerifyCode(
            email=email,
            code=_code_digest(email, payload.purpose, code),
            purpose=payload.purpose,
            expires_at=time.time() + 600,
        )
    )
    try:
        await send_verification_email(email, code, payload.purpose)
    except EmailDeliveryUnavailable as error:
        await session.rollback()
        raise HTTPException(status_code=503, detail="邮件服务尚未配置") from error
    except Exception as error:
        await session.rollback()
        raise HTTPException(status_code=502, detail="验证码邮件发送失败，请稍后重试") from error
    await session.commit()
    return {"message": "验证码已发送，请检查邮箱"}


@router.post("/register", status_code=201)
async def register(
    payload: RegisterRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    email = _normalize_email(str(payload.email))
    _rate_limit(f"register:ip:{_client_key(request)}", limit=5, window_seconds=3600)
    if await session.scalar(select(User.id).where(User.email == email)) is not None:
        raise HTTPException(status_code=409, detail="这个邮箱已经注册过了")
    await _consume_code(session, email, "register", payload.code)
    user = User(
        email=email,
        name=payload.nickname,
        password_hash=hash_password(payload.password),
    )
    session.add(user)
    try:
        await session.flush()
    except IntegrityError as error:
        await session.rollback()
        raise HTTPException(status_code=409, detail="昵称或邮箱已被使用") from error
    token = await _issue_token(session, user)
    return {"user": _user_payload(user), "access_token": token, "token_type": "bearer"}


@router.post("/login")
async def login(
    payload: LoginRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    email = _normalize_email(str(payload.email))
    _rate_limit(f"login:ip:{_client_key(request)}", limit=30, window_seconds=900)
    _rate_limit(f"login:email:{email}", limit=10, window_seconds=900)
    user = await session.scalar(select(User).where(User.email == email))
    if user is None or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="邮箱或密码不正确")
    user.updated_at = time.time()
    token = await _issue_token(session, user)
    return {"user": _user_payload(user), "access_token": token, "token_type": "bearer"}


@router.get("/me")
async def me(account: tuple[User, UserToken] = Depends(_current_account)):
    return {"user": _user_payload(account[0])}


@router.post("/logout", status_code=204)
async def logout(
    account: tuple[User, UserToken] = Depends(_current_account),
    session: AsyncSession = Depends(get_session),
):
    await session.delete(account[1])
    await session.commit()


@router.patch("/profile")
async def update_profile(
    payload: ProfileRequest,
    account: tuple[User, UserToken] = Depends(_current_account),
    session: AsyncSession = Depends(get_session),
):
    user = account[0]
    user.name = payload.nickname
    user.updated_at = time.time()
    try:
        await session.commit()
    except IntegrityError as error:
        await session.rollback()
        raise HTTPException(status_code=409, detail="这个昵称已被使用") from error
    return {"user": _user_payload(user)}


@router.post("/password")
async def change_password(
    payload: ChangePasswordRequest,
    account: tuple[User, UserToken] = Depends(_current_account),
    session: AsyncSession = Depends(get_session),
):
    user, current_token = account
    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(status_code=400, detail="当前密码不正确")
    if payload.current_password == payload.new_password:
        raise HTTPException(status_code=400, detail="新密码不能与当前密码相同")
    user.password_hash = hash_password(payload.new_password)
    user.updated_at = time.time()
    await session.execute(
        delete(UserToken).where(
            UserToken.user_id == user.id,
            UserToken.id != current_token.id,
        )
    )
    await session.commit()
    return {"message": "密码已修改，其他设备已退出登录"}


@router.post("/password/verify", status_code=204)
async def verify_account_password(
    payload: VerifyPasswordRequest,
    account: tuple[User, UserToken] = Depends(_current_account),
):
    if not verify_password(payload.password, account[0].password_hash):
        raise HTTPException(status_code=400, detail="密码不正确，数据没有清除")


@router.post("/password/reset")
async def reset_password(
    payload: ResetPasswordRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    email = _normalize_email(str(payload.email))
    _rate_limit(f"reset:ip:{_client_key(request)}", limit=10, window_seconds=3600)
    await _consume_code(session, email, "reset_password", payload.code)
    user = await session.scalar(select(User).where(User.email == email))
    if user is None:
        raise HTTPException(status_code=400, detail="验证码错误或已过期")
    user.password_hash = hash_password(payload.new_password)
    user.updated_at = time.time()
    await session.execute(delete(UserToken).where(UserToken.user_id == user.id))
    await session.commit()
    return {"message": "密码已重置，请重新登录"}
