"""Retained protobuf-era media catalog routes."""

import json

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from .. import protobuf_encoder as pb
from ..database import Bangumi, BangumiEpisode
from ..dependencies import get_session
from ..legacy_protocol import bangumi_to_dict, protobuf_bytes

router = APIRouter(tags=["legacy-media"])


@router.get("/bangumi/list")
async def bangumi_list(
    skip: int = Query(0),
    type: str = Query(None),
    lang: str = Query(None),
    year: int = Query(None),
    genre: str = Query(None),
    mark: str = Query(None),
    session: AsyncSession = Depends(get_session),
) -> Response:
    stmt = (
        select(Bangumi).options(selectinload(Bangumi.episodes)).limit(40).offset(skip)
    )
    if type:
        stmt = stmt.where(Bangumi.type == type)
    if lang:
        stmt = stmt.where(Bangumi.lang == lang)
    if year:
        stmt = stmt.where(Bangumi.year == year)
    result = await session.execute(stmt)
    items = [bangumi_to_dict(item) for item in result.scalars().all()]
    return protobuf_bytes(pb.encode_bangumi_list(items))


@router.get("/bangumi/tag")
async def bangumi_tags(
    type: str = Query("genre"),
    skip: int = Query(0),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    result = await session.execute(select(Bangumi).limit(100))
    genre_counts: dict[str, int] = {}
    for bangumi in result.scalars().all():
        try:
            genres = json.loads(bangumi.genres or "[]")
        except (json.JSONDecodeError, TypeError):
            genres = []
        for genre in genres:
            genre_counts[genre] = genre_counts.get(genre, 0) + 1
    return JSONResponse(
        [
            {"id": index + 1, "name": name, "count": count}
            for index, (name, count) in enumerate(sorted(genre_counts.items()))
        ]
    )


@router.get("/bangumi/latest")
async def bangumi_latest(
    session: AsyncSession = Depends(get_session),
) -> Response:
    stmt = (
        select(Bangumi)
        .options(selectinload(Bangumi.episodes))
        .order_by(Bangumi.updated_at.desc())
        .limit(20)
    )
    result = await session.execute(stmt)
    items = [bangumi_to_dict(item) for item in result.scalars().all()]
    return protobuf_bytes(pb.encode_bangumi_list(items))


@router.get("/bangumi/detail/{id}")
async def bangumi_detail(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    result = await session.execute(select(Bangumi).where(Bangumi.id == id))
    bangumi = result.scalar_one_or_none()
    if not bangumi:
        raise HTTPException(404, "番剧不存在")
    episodes_result = await session.execute(
        select(BangumiEpisode)
        .where(BangumiEpisode.bangumi_id == id)
        .order_by(BangumiEpisode.number)
    )
    episodes = episodes_result.scalars().all()
    return JSONResponse(
        {
            "id": bangumi.id,
            "title": bangumi.title,
            "summary": bangumi.summary,
            "cover_url": bangumi.cover_url,
            "banner_url": bangumi.banner_url,
            "type": bangumi.type,
            "lang": bangumi.lang,
            "year": bangumi.year,
            "status": bangumi.status,
            "tags": json.loads(bangumi.tags or "[]") if bangumi.tags else [],
            "genres": json.loads(bangumi.genres or "[]") if bangumi.genres else [],
            "rating": bangumi.rating,
            "rating_count": bangumi.rating_count,
            "episode_count": len(episodes),
            "episodes": [
                {
                    "id": episode.id,
                    "number": episode.number,
                    "title": episode.title,
                    "duration": episode.duration,
                }
                for episode in episodes
            ],
            "created_at": bangumi.created_at,
            "updated_at": bangumi.updated_at,
        }
    )


@router.get("/bangumi/episodes/{id}")
async def bangumi_episodes(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> Response:
    result = await session.execute(
        select(BangumiEpisode)
        .where(BangumiEpisode.bangumi_id == id)
        .order_by(BangumiEpisode.number)
    )
    items = []
    for episode in result.scalars().all():
        try:
            vod_data = json.loads(episode.vod_url or "[]")
        except (json.JSONDecodeError, TypeError):
            vod_data = [
                {
                    "url": episode.vod_url,
                    "type": "auto",
                    "caption": f"EP{episode.number}",
                }
            ]
        items.extend(vod_data)
    return protobuf_bytes(pb.encode_episodes_list(items))


@router.get("/bangumi/related/{id}")
async def bangumi_related(
    id: int,
    session: AsyncSession = Depends(get_session),
) -> Response:
    bangumi = (
        await session.execute(select(Bangumi).where(Bangumi.id == id))
    ).scalar_one_or_none()
    if not bangumi:
        return protobuf_bytes(pb.encode_related_list([]))
    result = await session.execute(
        select(Bangumi)
        .options(selectinload(Bangumi.episodes))
        .where(Bangumi.id != id)
        .limit(10)
    )
    items = [bangumi_to_dict(item) for item in result.scalars().all()]
    return protobuf_bytes(pb.encode_related_list(items))


@router.get("/vod/{id}/{episode}")
async def vod_detail(
    id: int,
    episode: int,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    result = await session.execute(
        select(BangumiEpisode).where(
            BangumiEpisode.bangumi_id == id,
            BangumiEpisode.number == episode,
        )
    )
    item = result.scalar_one_or_none()
    if not item:
        raise HTTPException(404, "剧集不存在")
    try:
        vod_data = json.loads(item.vod_url or "[]")
    except (json.JSONDecodeError, TypeError):
        vod_data = [
            {"url": item.vod_url, "type": "auto", "caption": f"EP{item.number}"}
        ]
    return JSONResponse(
        {
            "id": item.id,
            "bangumi_id": item.bangumi_id,
            "number": item.number,
            "title": item.title,
            "vod": vod_data,
        }
    )
