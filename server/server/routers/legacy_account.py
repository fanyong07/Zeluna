"""Default-disabled protobuf account compatibility routes."""

import time

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .. import protobuf_encoder as pb
from ..auth import (
    PasswordAccountState,
    generate_verify_code,
    get_current_user,
    hash_password,
    issue_session_token,
    password_hash_needs_upgrade,
    revalidate_password_account,
    run_password_work,
    verify_login_password,
    verify_password,
)
from ..database import User, VerifyCode
from ..dependencies import get_session, require_legacy_account_api
from ..legacy_protocol import parse_account_request, protobuf_bytes, user_to_dict

router = APIRouter(
    tags=["legacy-account"],
    dependencies=[Depends(require_legacy_account_api)],
)


@router.post("/login")
async def login(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> Response:
    """登录 — protobuf 响应。"""

    decoded = parse_account_request(await request.body())
    result = await session.execute(
        select(User).where(User.email == decoded.get("user", ""))
    )
    user = result.scalar_one_or_none()
    password = decoded.get("password", "")
    expected = PasswordAccountState.capture(user) if user is not None else None
    password_valid = await run_password_work(
        verify_login_password,
        password,
        expected.password_hash if expected is not None else None,
    )
    if expected is None or not password_valid:
        return protobuf_bytes(pb.encode_login_response({}, ""))
    upgraded = (
        await run_password_work(hash_password, password)
        if password_hash_needs_upgrade(expected.password_hash)
        else None
    )
    user = await revalidate_password_account(session, expected)
    if user is None or user.deletion_due_at > 0:
        await session.rollback()
        return protobuf_bytes(pb.encode_login_response({}, ""))
    if upgraded is not None:
        user.password_hash = upgraded

    jwt_token = await issue_session_token(session, user.id)
    await session.commit()
    return protobuf_bytes(pb.encode_login_response(user_to_dict(user), jwt_token))


@router.post("/code")
async def send_code(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    """发送验证码。"""

    try:
        form = await request.form()
        email = form.get("email", "")
    except Exception:
        body = await request.json()
        email = body.get("email", "")

    if not email:
        return JSONResponse({"error": True, "message": "邮箱不能为空"})

    code = generate_verify_code()
    session.add(VerifyCode(email=email, code=code, expires_at=time.time() + 600))
    await session.commit()
    return JSONResponse({"error": False, "message": "验证码已发送"})


async def _consume_password_code(
    session: AsyncSession, verification_id: int, email: str, code: str
) -> bool:
    # Hashing may have yielded while another request consumed/replaced the
    # legacy code. Recheck and claim it atomically before creating any account
    # or changing a password; keep the claim in the caller's transaction.
    consumed = await session.scalar(
        delete(VerifyCode)
        .where(
            VerifyCode.id == verification_id,
            VerifyCode.email == email,
            VerifyCode.code == code,
            VerifyCode.expires_at > time.time(),
        )
        .returning(VerifyCode.id)
    )
    if consumed is None:
        await session.rollback()
    return consumed is not None


@router.post("/register")
async def register(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> Response:
    """注册 — protobuf 响应。"""

    decoded = parse_account_request(await request.body())
    email = decoded.get("email", "")
    code = decoded.get("code", "")
    name = decoded.get("name", "")
    password = decoded.get("password", "")
    if not all([email, code, name, password]):
        return protobuf_bytes(pb.encode_login_response({}, ""))

    result = await session.execute(
        select(VerifyCode).where(
            VerifyCode.email == email,
            VerifyCode.code == code,
            VerifyCode.expires_at > time.time(),
        )
    )
    verification = result.scalar_one_or_none()
    if not verification:
        return protobuf_bytes(pb.encode_login_response({}, ""))

    for check_stmt in (
        select(User).where(User.email == email),
        select(User).where(User.name == name),
    ):
        result = await session.execute(check_stmt)
        if result.scalar_one_or_none():
            return protobuf_bytes(pb.encode_login_response({}, ""))

    verification_id = verification.id
    hashed = await run_password_work(hash_password, password)
    if not await _consume_password_code(session, verification_id, email, code):
        return protobuf_bytes(pb.encode_login_response({}, ""))
    user = User(email=email, name=name, password_hash=hashed)
    session.add(user)
    try:
        await session.flush()
    except IntegrityError:
        await session.rollback()
        return protobuf_bytes(pb.encode_login_response({}, ""))
    jwt_token = await issue_session_token(session, user.id)
    await session.commit()
    return protobuf_bytes(pb.encode_login_response(user_to_dict(user), jwt_token))


@router.post("/user/check")
async def check_user(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    """检查邮箱/用户名可用性。"""

    try:
        form = await request.form()
    except Exception:
        form = await request.json()
    email = form.get("email", "")
    name = form.get("name", "")

    if email:
        result = await session.execute(select(User).where(User.email == email))
        if result.scalar_one_or_none():
            return JSONResponse({"error": True, "message": "邮箱已被注册"})
    if name:
        result = await session.execute(select(User).where(User.name == name))
        if result.scalar_one_or_none():
            return JSONResponse({"error": True, "message": "用户名已被使用"})
    return JSONResponse({"error": False, "message": "可用"})


@router.post("/change_password")
async def change_password(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    """修改密码。"""

    decoded = parse_account_request(await request.body())
    email = decoded.get("email", "")
    code = decoded.get("code", "")
    password = decoded.get("password", "")
    result = await session.execute(
        select(VerifyCode).where(
            VerifyCode.email == email,
            VerifyCode.code == code,
            VerifyCode.expires_at > time.time(),
        )
    )
    verification = result.scalar_one_or_none()
    if not verification:
        return JSONResponse({"error": True, "message": "验证码无效"})

    result = await session.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    if not user:
        return JSONResponse({"error": True, "message": "用户不存在"})

    expected = PasswordAccountState.capture(user)
    verification_id = verification.id
    hashed = await run_password_work(hash_password, password)
    user = await revalidate_password_account(session, expected)
    if user is None:
        return JSONResponse({"error": True, "message": "验证码无效"})
    if not await _consume_password_code(session, verification_id, email, code):
        return JSONResponse({"error": True, "message": "验证码无效"})
    user.password_hash = hashed
    user.updated_at = time.time()
    await session.commit()
    return JSONResponse({"error": False, "message": "密码修改成功"})


@router.get("/init")
async def init_user(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> Response:
    """获取用户信息 — protobuf 响应。"""

    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        return protobuf_bytes(pb.encode_init_response({}))
    return protobuf_bytes(pb.encode_init_response(user_to_dict(user)))
