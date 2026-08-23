"""Modern stable-identity JSON danmaku endpoints."""

import time
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from ..account_api import _client_key, _rate_limit, current_account
from ..database import CommunityDanmaku, User, UserToken
from ..dependencies import get_session


router = APIRouter(prefix="/api/v3/danmaku", tags=["danmaku"])
_STABLE_KEY_PATTERN = r"^[A-Za-z0-9._:-]+$"


class DanmakuCreateRequest(BaseModel):
    subject_key: str = Field(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN)
    episode_key: str = Field(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN)
    time_seconds: float = Field(ge=0, le=86400)
    mode: Literal["scroll", "top", "bottom"] = "scroll"
    color: int = Field(default=0xFFFFFF, ge=0, le=0xFFFFFF)
    text: str = Field(min_length=1, max_length=200)

    @field_validator("text")
    @classmethod
    def normalize_text(cls, value: str) -> str:
        normalized = " ".join(value.split())
        if not normalized:
            raise ValueError("danmaku text is empty")
        return normalized


def _payload(row: CommunityDanmaku, *, is_mine: bool) -> dict[str, object]:
    return {
        "id": str(row.id),
        "subject_key": row.subject_key,
        "episode_key": row.episode_key,
        "time_seconds": row.time_seconds,
        "mode": row.mode,
        "color": row.color,
        "text": row.text,
        "created_at": row.created_at,
        "author": {
            "display_name": row.user.name if row.user is not None else "已注销用户",
            "is_mine": is_mine,
        },
    }


async def _list_rows(
    session: AsyncSession,
    *,
    subject_key: str,
    episode_key: str,
    after_id: int,
    limit: int,
) -> tuple[list[CommunityDanmaku], bool]:
    rows = list(
        (
            await session.scalars(
                select(CommunityDanmaku)
                .options(selectinload(CommunityDanmaku.user))
                .where(
                    CommunityDanmaku.subject_key == subject_key,
                    CommunityDanmaku.episode_key == episode_key,
                    CommunityDanmaku.id > after_id,
                )
                .order_by(CommunityDanmaku.id)
                .limit(limit + 1)
            )
        ).all()
    )
    return rows[:limit], len(rows) > limit


def _list_response(
    rows: list[CommunityDanmaku],
    *,
    has_more: bool,
    user_id: int | None,
) -> JSONResponse:
    return JSONResponse(
        {
            "comments": [
                _payload(row, is_mine=user_id is not None and row.user_id == user_id)
                for row in rows
            ],
            "next_cursor": str(rows[-1].id) if has_more and rows else None,
        },
        headers={"Cache-Control": "no-store"},
    )


@router.get("")
async def list_danmaku(
    subject_key: str = Query(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN),
    episode_key: str = Query(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN),
    after_id: int = Query(default=0, ge=0),
    limit: int = Query(default=500, ge=1, le=1000),
    session: AsyncSession = Depends(get_session),
):
    rows, has_more = await _list_rows(
        session,
        subject_key=subject_key,
        episode_key=episode_key,
        after_id=after_id,
        limit=limit,
    )
    return _list_response(rows, has_more=has_more, user_id=None)


@router.get("/mine")
async def list_danmaku_with_ownership(
    subject_key: str = Query(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN),
    episode_key: str = Query(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN),
    after_id: int = Query(default=0, ge=0),
    limit: int = Query(default=500, ge=1, le=1000),
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    rows, has_more = await _list_rows(
        session,
        subject_key=subject_key,
        episode_key=episode_key,
        after_id=after_id,
        limit=limit,
    )
    return _list_response(rows, has_more=has_more, user_id=account[0].id)


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_danmaku(
    payload: DanmakuCreateRequest,
    request: Request,
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    user = account[0]
    await _rate_limit(
        f"danmaku-post:ip:{_client_key(request)}", limit=30, window_seconds=60
    )
    await _rate_limit(
        f"danmaku-post:user:{user.id}", limit=20, window_seconds=60
    )
    row = CommunityDanmaku(
        subject_key=payload.subject_key,
        episode_key=payload.episode_key,
        user_id=user.id,
        time_seconds=payload.time_seconds,
        mode=payload.mode,
        color=payload.color,
        text=payload.text,
        created_at=time.time(),
        user=user,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return JSONResponse(
        _payload(row, is_mine=True),
        status_code=status.HTTP_201_CREATED,
        headers={"Cache-Control": "no-store"},
    )


@router.delete("/{comment_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_danmaku(
    comment_id: int,
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
):
    row = await session.get(CommunityDanmaku, comment_id)
    if row is None:
        raise HTTPException(status_code=404, detail="弹幕不存在或已删除")
    if row.user_id is None or row.user_id != account[0].id:
        raise HTTPException(status_code=403, detail="只能删除自己发送的弹幕")
    await session.delete(row)
    await session.commit()
    return Response(
        status_code=status.HTTP_204_NO_CONTENT,
        headers={"Cache-Control": "no-store"},
    )
