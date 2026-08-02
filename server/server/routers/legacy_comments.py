"""Retained community comment routes."""

import json

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth import get_current_user
from ..database import Comment, CommentLike, User
from ..dependencies import get_session

router = APIRouter(tags=["legacy-comments"])


async def _comment_user(comment: Comment, session: AsyncSession) -> User | None:
    result = await session.execute(select(User).where(User.id == comment.user_id))
    return result.scalar_one_or_none()


async def _comment_liked(
    comment: Comment,
    request: Request | None,
    session: AsyncSession,
) -> bool:
    token_header = request.headers.get("_", "") if request else ""
    if not token_header:
        return False
    current_user = await get_current_user(token_header, session)
    if not current_user:
        return False
    result = await session.execute(
        select(CommentLike).where(
            CommentLike.user_id == current_user.id,
            CommentLike.comment_id == comment.id,
        )
    )
    return result.scalar_one_or_none() is not None


def _contents(comment: Comment) -> list:
    try:
        return json.loads(comment.contents or "[]")
    except (json.JSONDecodeError, TypeError):
        return [comment.contents] if comment.contents else []


@router.get("/comment")
async def get_comments(
    type: str = Query("thread"),
    id: str = Query(""),
    skip: int = Query(0),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    stmt = (
        select(Comment)
        .where(
            Comment.type == type,
            Comment.target_id == id,
            Comment.parent_id == "",
        )
        .order_by(Comment.created_at.desc())
        .offset(skip)
        .limit(30)
    )
    comments = (await session.execute(stmt)).scalars().all()
    items = []
    for comment in comments:
        user = await _comment_user(comment, session)
        items.append(
            {
                "id": str(comment.id),
                "user": {
                    "id": user.id if user else 0,
                    "name": user.name if user else "匿名",
                    "avatar": user.avatar if user else "",
                },
                "contents": _contents(comment),
                "like_count": comment.like_count,
                "user_liked": await _comment_liked(comment, request, session),
                "created_at": comment.created_at,
                "parent_id": comment.parent_id,
                "reply_to": comment.reply_to,
            }
        )
    return JSONResponse(items)


@router.post("/comment")
async def post_comment(
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    body = await request.json()
    comment = Comment(
        type=body.get("type", "thread"),
        target_id=str(body.get("id", "")),
        user_id=user.id,
        parent_id=str(body.get("parent", "")),
        reply_to=str(body.get("reply", "")),
        contents=json.dumps(body.get("contents", []), ensure_ascii=False),
    )
    session.add(comment)
    await session.commit()
    await session.refresh(comment)
    return JSONResponse({"id": str(comment.id), "error": False})


@router.get("/comment/{id}/replies")
async def comment_replies(
    id: str,
    skip: int = Query(0),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    stmt = (
        select(Comment)
        .where(Comment.parent_id == id)
        .order_by(Comment.created_at)
        .offset(skip)
        .limit(20)
    )
    comments = (await session.execute(stmt)).scalars().all()
    items = []
    for comment in comments:
        user = await _comment_user(comment, session)
        items.append(
            {
                "id": str(comment.id),
                "user": {
                    "id": user.id if user else 0,
                    "name": user.name if user else "匿名",
                    "avatar": user.avatar if user else "",
                },
                "contents": _contents(comment),
                "like_count": comment.like_count,
                "user_liked": await _comment_liked(comment, request, session),
                "created_at": comment.created_at,
                "reply_to": comment.reply_to,
            }
        )
    return JSONResponse(items)


@router.get("/comment/like")
async def like_comment(
    id: str = Query(""),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    token_header = request.headers.get("_", "") if request else ""
    user = await get_current_user(token_header, session)
    if not user:
        raise HTTPException(401)
    comment_id = int(id)
    existing = (
        await session.execute(
            select(CommentLike).where(
                CommentLike.user_id == user.id,
                CommentLike.comment_id == comment_id,
            )
        )
    ).scalar_one_or_none()
    if not existing:
        session.add(CommentLike(user_id=user.id, comment_id=comment_id))
        comment = (
            await session.execute(select(Comment).where(Comment.id == comment_id))
        ).scalar_one_or_none()
        if comment:
            comment.like_count += 1
        await session.commit()
    return JSONResponse({"error": False})


@router.delete("/comment/like")
async def cancel_like_comment(
    id: str = Query(""),
    request: Request = None,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    token_header = request.headers.get("_", "") if request else ""
    user = await get_current_user(token_header, session)
    if not user:
        raise HTTPException(401)
    comment_id = int(id)
    await session.execute(
        delete(CommentLike).where(
            CommentLike.user_id == user.id,
            CommentLike.comment_id == comment_id,
        )
    )
    comment = (
        await session.execute(select(Comment).where(Comment.id == comment_id))
    ).scalar_one_or_none()
    if comment and comment.like_count > 0:
        comment.like_count -= 1
    await session.commit()
    return JSONResponse({"error": False})
