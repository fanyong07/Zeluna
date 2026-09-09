"""Modern stable-identity JSON danmaku endpoints."""

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable, Mapping
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from ..account_api import _client_key, _rate_limit, current_account
from ..dandanplay import (
    DandanplayClient,
    DandanplayError,
    DandanplayResult,
    get_dandanplay_client,
)
from ..config import DANDANPLAY_CLIENT_RATE_LIMIT_PER_MINUTE
from ..database import CommunityDanmaku, User, UserToken
from ..dependencies import get_session


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v3/danmaku", tags=["danmaku"])
_STABLE_KEY_PATTERN = r"^[A-Za-z0-9._:-]+$"
# Flutter stableEpisodeKey uses v1|<subject key>|episode:<number>. Keep the
# legacy flat keys valid without changing identities or splitting stored comments.
_EPISODE_KEY_PATTERN = (
    r"^(?:[A-Za-z0-9._:-]+|v1\|[A-Za-z0-9._:-]+\|episode:[A-Za-z0-9._:-]+)$"
)
# Leave headroom for the client's 8-second request timeout.
_DANDANPLAY_TOTAL_TIMEOUT_SECONDS = 6.0


class DanmakuCreateRequest(BaseModel):
    subject_key: str = Field(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN)
    episode_key: str = Field(min_length=3, max_length=300, pattern=_EPISODE_KEY_PATTERN)
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
        "provider": "Zeluna",
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


def _zeluna_source(
    rows: list[CommunityDanmaku],
    *,
    title: str,
    episode_number: int,
    episode_key: str,
) -> dict[str, object]:
    return {
        "provider": "Zeluna",
        "title": title or "Zeluna 社区弹幕",
        "episode_title": f"第 {episode_number} 集",
        "episode_id": episode_key,
        "comment_count": len(rows),
        "available": True,
        "message": None if rows else "当前集还没有用户弹幕",
    }


def _failed_dandanplay_source(
    *,
    title: str,
    episode_number: int,
    error: DandanplayError,
) -> dict[str, object]:
    return {
        "provider": "弹弹play",
        "title": title or "弹弹play 弹幕源",
        "episode_title": f"第 {episode_number} 集",
        "episode_id": "",
        "comment_count": 0,
        "available": False,
        "message": {
            "authorization": "弹弹play 授权失败，请联系管理员检查服务端凭据；Zeluna 社区弹幕仍可正常使用",
            "rate_limited": "弹弹play 请求受限，请稍后再试；Zeluna 社区弹幕仍可正常使用",
            "timeout": "弹弹play 请求超时，Zeluna 社区弹幕仍可正常使用",
            "transport": "弹弹play 网络暂时不可用，Zeluna 社区弹幕仍可正常使用",
            "upstream_unavailable": "弹弹play 服务暂时不可用，Zeluna 社区弹幕仍可正常使用",
        }.get(
            error.code,
            "弹弹play 返回异常，请联系管理员检查；Zeluna 社区弹幕仍可正常使用",
        ),
        "error_code": error.code,
        "retryable": error.retryable,
    }


async def _load_dandanplay(
    client: DandanplayClient,
    *,
    enabled: bool,
    after_id: int,
    title: str,
    original_title: str,
    episode_number: int,
    media_type: str,
    before_upstream: Callable[[], Awaitable[None]],
) -> DandanplayResult | None:
    if not enabled or after_id != 0:
        return None
    try:
        async with asyncio.timeout(_DANDANPLAY_TOTAL_TIMEOUT_SECONDS):
            return await client.comments_for_episode(
                title=title,
                original_title=original_title,
                episode_number=episode_number,
                media_type=media_type,
                before_upstream=before_upstream,
            )
    except DandanplayError as error:
        failure = error
    except TimeoutError:
        failure = DandanplayError("dandanplay budget exhausted", code="timeout")
    except Exception:
        logger.exception("unexpected dandanplay integration failure")
        failure = DandanplayError("unexpected upstream failure")
    return DandanplayResult(
        source=_failed_dandanplay_source(
            title=title,
            episode_number=episode_number,
            error=failure,
        )
    )


async def _guard_dandanplay_upstream(request: Request) -> None:
    try:
        await _rate_limit(
            f"dandanplay-get:ip:{_client_key(request)}",
            limit=DANDANPLAY_CLIENT_RATE_LIMIT_PER_MINUTE,
            window_seconds=60,
        )
    except HTTPException as error:
        if error.status_code in {
            status.HTTP_429_TOO_MANY_REQUESTS,
            status.HTTP_503_SERVICE_UNAVAILABLE,
        }:
            raise DandanplayError(
                "dandanplay upstream request was throttled", code="rate_limited"
            ) from error
        raise


def _comment_sort_key(item: Mapping[str, object]) -> tuple[float, str]:
    try:
        time_seconds = float(item.get("time_seconds", 0))
    except (TypeError, ValueError):
        time_seconds = 0
    return time_seconds, str(item.get("id", ""))


async def _list_response(
    rows: list[CommunityDanmaku],
    *,
    has_more: bool,
    user_id: int | None,
    request: Request,
    after_id: int,
    title: str,
    original_title: str,
    episode_number: int,
    episode_key: str,
    media_type: str,
    include_dandanplay: bool,
    dandanplay_client: DandanplayClient,
) -> JSONResponse:
    comments: list[Mapping[str, object]] = [
        _payload(row, is_mine=user_id is not None and row.user_id == user_id)
        for row in rows
    ]
    sources: list[Mapping[str, object]] = [
        _zeluna_source(
            rows,
            title=title,
            episode_number=episode_number,
            episode_key=episode_key,
        )
    ]
    external = await _load_dandanplay(
        dandanplay_client,
        enabled=include_dandanplay,
        after_id=after_id,
        title=title,
        original_title=original_title,
        episode_number=episode_number,
        media_type=media_type,
        before_upstream=lambda: _guard_dandanplay_upstream(request),
    )
    if external is not None:
        comments.extend(external.comments)
        sources.append(external.source)
    comments.sort(key=_comment_sort_key)
    return JSONResponse(
        {
            "comments": comments,
            "sources": sources,
            "next_cursor": str(rows[-1].id) if has_more and rows else None,
        },
        headers={"Cache-Control": "no-store"},
    )


@router.get("")
async def list_danmaku(
    request: Request,
    subject_key: str = Query(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN),
    episode_key: str = Query(
        min_length=3, max_length=300, pattern=_EPISODE_KEY_PATTERN
    ),
    after_id: int = Query(default=0, ge=0),
    limit: int = Query(default=500, ge=1, le=1000),
    title: str = Query(default="", max_length=300),
    original_title: str = Query(default="", max_length=300),
    episode_number: int = Query(default=1, ge=1, le=10000),
    media_type: Literal["anime", "series", "movie"] = Query(default="anime"),
    include_dandanplay: bool = Query(default=False),
    session: AsyncSession = Depends(get_session),
    dandanplay_client: DandanplayClient = Depends(get_dandanplay_client),
):
    rows, has_more = await _list_rows(
        session,
        subject_key=subject_key,
        episode_key=episode_key,
        after_id=after_id,
        limit=limit,
    )
    return await _list_response(
        rows,
        has_more=has_more,
        user_id=None,
        request=request,
        after_id=after_id,
        title=title,
        original_title=original_title,
        episode_number=episode_number,
        episode_key=episode_key,
        media_type=media_type,
        include_dandanplay=include_dandanplay,
        dandanplay_client=dandanplay_client,
    )


@router.get("/mine")
async def list_danmaku_with_ownership(
    request: Request,
    subject_key: str = Query(min_length=3, max_length=300, pattern=_STABLE_KEY_PATTERN),
    episode_key: str = Query(
        min_length=3, max_length=300, pattern=_EPISODE_KEY_PATTERN
    ),
    after_id: int = Query(default=0, ge=0),
    limit: int = Query(default=500, ge=1, le=1000),
    title: str = Query(default="", max_length=300),
    original_title: str = Query(default="", max_length=300),
    episode_number: int = Query(default=1, ge=1, le=10000),
    media_type: Literal["anime", "series", "movie"] = Query(default="anime"),
    include_dandanplay: bool = Query(default=False),
    account: tuple[User, UserToken] = Depends(current_account),
    session: AsyncSession = Depends(get_session),
    dandanplay_client: DandanplayClient = Depends(get_dandanplay_client),
):
    rows, has_more = await _list_rows(
        session,
        subject_key=subject_key,
        episode_key=episode_key,
        after_id=after_id,
        limit=limit,
    )
    return await _list_response(
        rows,
        has_more=has_more,
        user_id=account[0].id,
        request=request,
        after_id=after_id,
        title=title,
        original_title=original_title,
        episode_number=episode_number,
        episode_key=episode_key,
        media_type=media_type,
        include_dandanplay=include_dandanplay,
        dandanplay_client=dandanplay_client,
    )


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
    await _rate_limit(f"danmaku-post:user:{user.id}", limit=20, window_seconds=60)
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
