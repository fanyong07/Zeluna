"""Production JSON API for cloud email accounts."""

import hashlib
import hmac
import ipaddress
import time
from collections import deque
from dataclasses import dataclass
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, EmailStr, Field, field_validator
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .auth import (
    AuthConfigurationError,
    decode_jwt,
    RefreshTokenRejected,
    RefreshTokenReuseDetected,
    SessionCredentials,
    bind_session_claims,
    generate_verify_code,
    hash_password,
    issue_session_credentials,
    issue_session_token,
    password_hash_needs_upgrade,
    signing_key,
    token_digest,
    rotate_refresh_token,
    validate_session_token,
    verify_login_password,
    verify_password,
)
from .config import (
    ACCOUNT_DELETION_GRACE_SECONDS,
    ACCOUNT_RATE_LIMIT_MAX_KEYS,
    ACCOUNT_TRUSTED_PROXY_NETWORKS,
)
from .database import User, UserToken, VerifyCode
from .dependencies import get_session
from .email_service import EmailDeliveryUnavailable, send_verification_email
from .privacy import build_account_data_export, purge_expired_auth_artifacts

router = APIRouter(prefix="/api/v1/auth", tags=["account"])

_MAX_CODE_FAILURES = 5
_CODE_REQUEST_MESSAGE = "如果该操作可用，验证码将发送到邮箱"


class VerificationCodeRequest(BaseModel):
    email: EmailStr
    purpose: Literal["register", "reset_password"] = "register"


class RegisterRequest(BaseModel):
    email: EmailStr
    nickname: str = Field(min_length=1, max_length=40)
    password: str = Field(min_length=8, max_length=128)
    code: str = Field(pattern=r"^\d{6}$")
    device_id: str = Field(default="", max_length=128)
    device_name: str = Field(default="", max_length=80)
    platform: str = Field(default="", max_length=32)

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
    device_id: str = Field(default="", max_length=128)
    device_name: str = Field(default="", max_length=80)
    platform: str = Field(default="", max_length=32)


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


class VerifyPasswordRequest(BaseModel):
    password: str = Field(min_length=1, max_length=128)


class ResetPasswordRequest(BaseModel):
    email: EmailStr
    code: str = Field(pattern=r"^\d{6}$")
    new_password: str = Field(min_length=8, max_length=128)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=20, max_length=256)


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


def _user_payload(user: User) -> dict:
    return {
        "id": str(user.id),
        "email": user.email,
        "nickname": user.name,
        "created_at": user.created_at,
        "updated_at": user.updated_at,
    }


def _deletion_pending_error(user: User) -> HTTPException:
    finalizing = user.deletion_due_at <= time.time()
    return HTTPException(
        status_code=status.HTTP_410_GONE if finalizing else status.HTTP_423_LOCKED,
        detail={
            "code": (
                "account_deletion_finalizing"
                if finalizing
                else "account_deletion_pending"
            ),
            "message": (
                "删除冷静期已经结束，正在完成账号删除"
                if finalizing
                else "账号处于删除冷静期，可在截止前撤销"
            ),
            "deletion_due_at": user.deletion_due_at,
        },
    )


async def _issue_token(session: AsyncSession, user: User) -> str:
    try:
        token = await issue_session_token(session, user.id)
    except AuthConfigurationError as error:
        raise HTTPException(
            status_code=503,
            detail="账号服务安全配置不可用",
        ) from error
    await session.commit()
    return token


async def _issue_credentials(
    session: AsyncSession,
    user: User,
    *,
    device_id: str = "",
    device_name: str = "",
    platform: str = "",
) -> SessionCredentials:
    try:
        credentials = await issue_session_credentials(
            session,
            user.id,
            device_id=device_id.strip(),
            device_name=device_name.strip(),
            platform=platform.strip(),
        )
    except AuthConfigurationError as error:
        raise HTTPException(
            status_code=503,
            detail="璐﹀彿鏈嶅姟瀹夊叏閰嶇疆涓嶅彲鐢?",
        ) from error
    await session.commit()
    return credentials


def _credentials_payload(
    credentials: SessionCredentials,
    user: User,
) -> dict[str, object]:
    return {
        "user": _user_payload(user),
        "access_token": credentials.access_token,
        "refresh_token": credentials.refresh_token,
        "token_type": "bearer",
        "session": {
            "session_id": credentials.session_id,
            "device_id": credentials.device_id,
            "device_name": credentials.device_name,
            "platform": credentials.platform,
            "access_expires_at": credentials.access_expires_at,
            "refresh_expires_at": credentials.refresh_expires_at,
        },
    }


async def current_account(
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
    raw_token = token.strip()
    decoded = decode_jwt(raw_token)
    session_id = decoded.get("session_id") if isinstance(decoded, dict) else None
    if isinstance(session_id, str) and session_id:
        user_token = await session.scalar(
            select(UserToken).where(UserToken.session_id == session_id)
        )
    else:
        result = await session.execute(
            select(UserToken).where(UserToken.token == token_digest(raw_token))
        )
        user_token = result.scalar_one_or_none()
    if user_token is None:
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    claims = validate_session_token(raw_token, user_token)
    if claims is None:
        if not user_token.session_id:
            await session.delete(user_token)
            await session.commit()
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    if bind_session_claims(user_token, claims):
        await session.commit()
    user = await session.get(User, user_token.user_id)
    if user is None:
        await session.delete(user_token)
        await session.commit()
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    if user.deletion_due_at > 0:
        await session.delete(user_token)
        await session.commit()
        raise _deletion_pending_error(user)
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
    await purge_expired_auth_artifacts(session)
    await session.commit()

    existing = await session.scalar(select(User.id).where(User.email == email))
    if payload.purpose == "register" and existing is not None:
        return {"message": _CODE_REQUEST_MESSAGE}
    if payload.purpose == "reset_password" and existing is None:
        # Do not reveal whether an account exists.
        return {"message": _CODE_REQUEST_MESSAGE}

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
    return {"message": _CODE_REQUEST_MESSAGE}


@router.post("/register", status_code=201)
async def register(
    payload: RegisterRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    email = _normalize_email(str(payload.email))
    _rate_limit(f"register:ip:{_client_key(request)}", limit=5, window_seconds=3600)
    await _consume_code(session, email, "register", payload.code)
    if await session.scalar(select(User.id).where(User.email == email)) is not None:
        raise HTTPException(status_code=409, detail="这个邮箱已经注册过了")
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
    credentials = await _issue_credentials(
        session,
        user,
        device_id=payload.device_id,
        device_name=payload.device_name,
        platform=payload.platform,
    )
    return _credentials_payload(credentials, user)


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
    password_valid = verify_login_password(
        payload.password,
        user.password_hash if user is not None else None,
    )
    if user is None or not password_valid:
        raise HTTPException(status_code=401, detail="邮箱或密码不正确")
    if user.deletion_due_at > 0:
        raise _deletion_pending_error(user)
    if password_hash_needs_upgrade(user.password_hash):
        user.password_hash = hash_password(payload.password)
    user.updated_at = time.time()
    credentials = await _issue_credentials(
        session,
        user,
        device_id=payload.device_id,
        device_name=payload.device_name,
        platform=payload.platform,
    )
    return _credentials_payload(credentials, user)


@router.post("/refresh")
async def refresh(
    payload: RefreshRequest,
    session: AsyncSession = Depends(get_session),
):
    try:
        credentials = await rotate_refresh_token(session, payload.refresh_token)
    except RefreshTokenReuseDetected as error:
        raise HTTPException(
            status_code=401,
            detail={"code": "refresh_reuse_detected", "message": "请重新登录"},
        ) from error
    except (RefreshTokenRejected, AuthConfigurationError) as error:
        raise HTTPException(
            status_code=401,
            detail={"code": "refresh_expired", "message": "登录状态已失效，请重新登录"},
        ) from error
    stored = await session.scalar(
        select(UserToken).where(UserToken.session_id == credentials.session_id)
    )
    user = await session.get(User, stored.user_id) if stored is not None else None
    if user is None:
        raise HTTPException(status_code=401, detail="登录状态已失效，请重新登录")
    return _credentials_payload(credentials, user)


@router.get("/me")
async def me(account: tuple[User, UserToken] = Depends(current_account)):
    return {"user": _user_payload(account[0])}


def _session_payload(row: UserToken, *, current: bool = False) -> dict[str, object]:
    return {
        "session_id": row.session_id,
        "device_name": row.device_name,
        "platform": row.platform,
        "created_at": row.created_at,
        "last_used_at": row.last_used_at,
        "expires_at": row.expires_at,
        "current": current,
    }


@router.get("/sessions")
async def list_sessions(
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    rows = list(
        await session.scalars(
            select(UserToken)
            .where(
                UserToken.user_id == account[0].id,
                UserToken.session_id.is_not(None),
                UserToken.revoked_at == 0,
                UserToken.expires_at > time.time(),
            )
            .order_by(UserToken.created_at.desc(), UserToken.id.desc())
        )
    )
    return {
        "sessions": [
            _session_payload(row, current=row.id == account[1].id) for row in rows
        ]
    }


@router.delete("/sessions/{session_id}", status_code=204)
async def revoke_session(
    session_id: str,
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    target = await session.scalar(
        select(UserToken).where(
            UserToken.user_id == account[0].id,
            UserToken.session_id == session_id.strip(),
            UserToken.session_id.is_not(None),
        )
    )
    if target is None:
        raise HTTPException(status_code=404, detail="session not found")
    target.revoked_at = time.time()
    await session.commit()


@router.post("/sessions/revoke-others", status_code=204)
async def revoke_other_sessions(
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    if account[1].session_id:
        await session.execute(
            update(UserToken)
            .where(
                UserToken.user_id == account[0].id,
                UserToken.session_id.is_not(None),
                UserToken.id != account[1].id,
                UserToken.revoked_at == 0,
            )
            .values(revoked_at=time.time())
        )
    await session.commit()


@router.post("/logout", status_code=204)
async def logout(
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    if account[1].session_id:
        account[1].revoked_at = time.time()
    else:
        await session.delete(account[1])
    await session.commit()


@router.get("/privacy/export")
async def export_account_data(
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    payload = await build_account_data_export(session, account[0])
    return JSONResponse(
        payload,
        headers={
            "Cache-Control": "no-store",
            "Content-Disposition": 'attachment; filename="zeluna-account-data.json"',
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.post("/privacy/deletion", status_code=202)
async def request_account_deletion(
    payload: VerifyPasswordRequest,
    request: Request,
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    user = account[0]
    _rate_limit(f"delete:ip:{_client_key(request)}", limit=5, window_seconds=86400)
    _rate_limit(f"delete:user:{user.id}", limit=3, window_seconds=86400)
    if not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=400, detail="密码不正确，账号没有进入删除流程")
    requested_at = time.time()
    due_at = requested_at + ACCOUNT_DELETION_GRACE_SECONDS
    user.deletion_requested_at = requested_at
    user.deletion_due_at = due_at
    user.updated_at = requested_at
    await session.execute(delete(UserToken).where(UserToken.user_id == user.id))
    await session.commit()
    return JSONResponse(
        {
            "status": "pending",
            "deletion_requested_at": requested_at,
            "deletion_due_at": due_at,
        },
        status_code=202,
        headers={"Cache-Control": "no-store"},
    )


@router.post("/privacy/deletion/cancel", status_code=204)
async def cancel_account_deletion(
    payload: LoginRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    email = _normalize_email(str(payload.email))
    _rate_limit(
        f"cancel-delete:ip:{_client_key(request)}", limit=10, window_seconds=3600
    )
    _rate_limit(f"cancel-delete:email:{email}", limit=5, window_seconds=3600)
    user = await session.scalar(select(User).where(User.email == email))
    password_valid = verify_login_password(
        payload.password,
        user.password_hash if user is not None else None,
    )
    if user is None or not password_valid:
        raise HTTPException(status_code=401, detail="邮箱或密码不正确")
    if user.deletion_due_at > 0 and user.deletion_due_at <= time.time():
        raise HTTPException(status_code=410, detail="删除冷静期已经结束，无法撤销")
    if password_hash_needs_upgrade(user.password_hash):
        user.password_hash = hash_password(payload.password)
    user.deletion_requested_at = 0
    user.deletion_due_at = 0
    user.updated_at = time.time()
    await session.commit()


@router.patch("/profile")
async def update_profile(
    payload: ProfileRequest,
    account: tuple[User, UserToken] = Depends(current_account),
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
    account: tuple[User, UserToken] = Depends(current_account),
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
    account: tuple[User, UserToken] = Depends(current_account),
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
