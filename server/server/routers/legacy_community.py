"""Retained protobuf-era community thread routes."""

import json

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .. import protobuf_encoder as pb
from ..auth import get_current_user
from ..database import Thread, ThreadCollection, ThreadLike
from ..dependencies import get_session
from ..legacy_protocol import protobuf_bytes

router = APIRouter(tags=["legacy-community"])


def _thread_summary(thread: Thread) -> dict:
    image = thread.images[0] if thread.images else None
    image_fields = (
        {
            "image": image.master or image.original,
            "color": image.color,
            "width": image.width,
            "height": image.height,
        }
        if image
        else {}
    )
    return {
        "id": thread.id,
        "ai": thread.ai,
        "nsfw": thread.nsfw,
        "title": thread.title,
        "count": image.id if image else 1,
        **image_fields,
    }


@router.get("/latest")
async def thread_latest(
    sort: int = Query(-1),
    type: str = Query("all"),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> Response:
    stmt = (
        select(Thread)
        .options(selectinload(Thread.images))
        .order_by(Thread.created_at.desc())
        .offset(skip)
        .limit(30)
    )
    if type != "all":
        try:
            filter_tags = json.dumps([type])
        except Exception:
            filter_tags = type
        stmt = stmt.where(Thread.tags.contains(filter_tags))
    result = await session.execute(stmt)
    items = [_thread_summary(thread) for thread in result.scalars().all()]
    return protobuf_bytes(pb.encode_thread_list(items))


@router.get("/tags")
async def thread_tags(
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    return JSONResponse(
        [
            {"id": 1, "name": "cosplay", "count": 50},
            {"id": 2, "name": "artwork", "count": 30},
            {"id": 3, "name": "all", "count": 100},
        ]
    )


@router.get("/t/{tag}/info")
async def tag_info(
    tag: str,
    session: AsyncSession = Depends(get_session),
) -> Response:
    result = await session.execute(select(Thread))
    count = len(
        [thread for thread in result.scalars().all() if tag in (thread.tags or "")]
    )
    info = {"title": tag, "description": f"#{tag}", "count": count, "nsfw": False}
    return protobuf_bytes(pb.encode_tag_info_response(info))


@router.get("/t/{tag}")
async def tag_list(
    tag: str,
    type: str = Query("all"),
    sort: int = Query(-1),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> Response:
    result = await session.execute(
        select(Thread)
        .options(selectinload(Thread.images))
        .order_by(Thread.created_at.desc())
        .offset(skip)
        .limit(30)
    )
    items = [
        _thread_summary(thread)
        for thread in result.scalars().all()
        if tag in (thread.tags or "")
    ]
    return protobuf_bytes(pb.encode_thread_list(items))


@router.get("/r/{id}")
async def thread_detail(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> Response:
    result = await session.execute(
        select(Thread).options(selectinload(Thread.images)).where(Thread.id == id)
    )
    thread = result.scalar_one_or_none()
    if not thread:
        raise HTTPException(404)
    item = {
        "id": thread.id,
        "title": thread.title,
        "body": thread.body,
        "tags": thread.tags,
        "nsfw": thread.nsfw,
        "images": [
            {
                "color": image.color,
                "height": image.height,
                "width": image.width,
                "original": image.original,
                "master": image.master,
                "original_size": image.original_size,
                "master_size": image.master_size,
            }
            for image in thread.images
        ],
    }
    return protobuf_bytes(pb.encode_thread_detail(item))


@router.get("/r/{id}/collect/status")
async def thread_collect_status(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        return JSONResponse({"collected": False})
    result = await session.execute(
        select(ThreadCollection).where(
            ThreadCollection.user_id == user.id,
            ThreadCollection.thread_id == id,
        )
    )
    return JSONResponse({"collected": result.scalar_one_or_none() is not None})


@router.get("/r/{id}/collect")
async def thread_collect(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    existing = (
        await session.execute(
            select(ThreadCollection).where(
                ThreadCollection.user_id == user.id,
                ThreadCollection.thread_id == id,
            )
        )
    ).scalar_one_or_none()
    if not existing:
        session.add(ThreadCollection(user_id=user.id, thread_id=id))
        await session.commit()
    return JSONResponse({"error": False})


@router.delete("/r/{id}/collect/cancel")
async def thread_collect_cancel(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    await session.execute(
        delete(ThreadCollection).where(
            ThreadCollection.user_id == user.id,
            ThreadCollection.thread_id == id,
        )
    )
    await session.commit()
    return JSONResponse({"error": False})


@router.get("/r/{id}/like/status")
async def thread_like_status(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        return JSONResponse({"liked": False})
    result = await session.execute(
        select(ThreadLike).where(
            ThreadLike.user_id == user.id,
            ThreadLike.thread_id == id,
        )
    )
    return JSONResponse({"liked": result.scalar_one_or_none() is not None})


@router.get("/r/{id}/like")
async def thread_like(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    existing = (
        await session.execute(
            select(ThreadLike).where(
                ThreadLike.user_id == user.id,
                ThreadLike.thread_id == id,
            )
        )
    ).scalar_one_or_none()
    if not existing:
        session.add(ThreadLike(user_id=user.id, thread_id=id))
        await session.commit()
    return JSONResponse({"error": False})


@router.delete("/r/{id}/like/cancel")
async def thread_like_cancel(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    await session.execute(
        delete(ThreadLike).where(
            ThreadLike.user_id == user.id,
            ThreadLike.thread_id == id,
        )
    )
    await session.commit()
    return JSONResponse({"error": False})


@router.get("/action/collects/{type}")
async def thread_collect_list(
    type: str,
    request: Request,
    page: int = Query(1),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    result = await session.execute(
        select(ThreadCollection)
        .where(ThreadCollection.user_id == user.id)
        .offset((page - 1) * 20)
        .limit(20)
    )
    ids = [row.thread_id for row in result.scalars().all()]
    threads = (
        (
            await session.execute(
                select(Thread)
                .options(selectinload(Thread.images))
                .where(Thread.id.in_(ids))
            )
        )
        .scalars()
        .all()
        if ids
        else []
    )
    return JSONResponse([_thread_summary(thread) for thread in threads])
