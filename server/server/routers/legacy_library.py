"""Retained danmaku and bangumi collection routes."""

import time

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .. import protobuf_encoder as pb
from ..auth import get_current_user
from ..database import Bangumi, BangumiCollection, Danmaku
from ..dependencies import get_session
from ..legacy_protocol import bangumi_to_dict, protobuf_bytes

router = APIRouter(tags=["legacy-library"])


@router.get("/danmaku")
async def get_danmaku(
    bangumi: int = Query(0),
    episode: int = Query(0),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> Response:
    stmt = (
        select(Danmaku)
        .options(selectinload(Danmaku.user))
        .where(
            Danmaku.bangumi_id == bangumi,
            Danmaku.episode_id == episode,
        )
        .order_by(Danmaku.time)
        .offset(skip)
        .limit(200)
    )
    items = (await session.execute(stmt)).scalars().all()
    payload = [
        {
            "id": item.danmaku_id or str(item.id),
            "color": item.color,
            "date": item.date,
            "text": item.text,
            "t": "",
            "time": item.time,
            "type": item.type,
            "from": item.user.name if item.user else "",
        }
        for item in items
    ]
    return protobuf_bytes(pb.encode_danmaku_list(payload))


@router.post("/danmaku")
async def post_danmaku(
    request: Request,
    bangumi: int = Query(0),
    episode: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401, "请先登录")
    try:
        body = await request.form()
    except Exception:
        body = await request.json()
    session.add(
        Danmaku(
            bangumi_id=bangumi,
            episode_id=episode,
            user_id=user.id,
            type=int(body.get("type", 0)),
            time=float(body.get("time", 0.0)),
            text=str(body.get("text", "")),
            color=str(body.get("color", "#FFFFFF")),
            danmaku_id=str(int(time.time() * 1000)),
        )
    )
    await session.commit()
    return JSONResponse({"error": False, "message": "弹幕已发送"})


@router.get("/bangumi/{id}/collect/status")
async def collect_status(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        return JSONResponse({"collected": False, "type": ""})
    result = await session.execute(
        select(BangumiCollection).where(
            BangumiCollection.user_id == user.id,
            BangumiCollection.bangumi_id == id,
        )
    )
    collection = result.scalar_one_or_none()
    return JSONResponse(
        {
            "collected": collection is not None,
            "type": collection.type if collection else "",
        }
    )


@router.get("/bangumi/{id}/collect/{type}")
async def change_collect(
    id: int,
    type: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    result = await session.execute(
        select(BangumiCollection).where(
            BangumiCollection.user_id == user.id,
            BangumiCollection.bangumi_id == id,
        )
    )
    existing = result.scalar_one_or_none()
    if existing:
        existing.type = type
    else:
        session.add(BangumiCollection(user_id=user.id, bangumi_id=id, type=type))
    await session.commit()
    return JSONResponse({"error": False, "message": "收藏成功"})


@router.delete("/bangumi/{id}/collect/cancel")
async def cancel_collect(
    id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    await session.execute(
        delete(BangumiCollection).where(
            BangumiCollection.user_id == user.id,
            BangumiCollection.bangumi_id == id,
        )
    )
    await session.commit()
    return JSONResponse({"error": False, "message": "已取消收藏"})


@router.get("/action/collect/{type}")
async def collect_list(
    type: str,
    request: Request,
    page: int = Query(1),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    user = await get_current_user(request.headers.get("_", ""), session)
    if not user:
        raise HTTPException(401)
    stmt = (
        select(BangumiCollection, Bangumi)
        .join(Bangumi, BangumiCollection.bangumi_id == Bangumi.id)
        .options(selectinload(Bangumi.episodes))
        .where(
            BangumiCollection.user_id == user.id,
            BangumiCollection.type == type,
        )
        .offset((page - 1) * 20)
        .limit(20)
    )
    rows = (await session.execute(stmt)).all()
    return JSONResponse(
        [
            {
                **bangumi_to_dict(row[1]),
                "collection_type": row[0].type,
            }
            for row in rows
        ]
    )
