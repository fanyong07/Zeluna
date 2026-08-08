"""Retained v2 catalog and playback compatibility routes."""

import json
import logging
import time

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..aggregator import aggregator
from ..database import PlaybackCache, upsert_playback_cache
from ..dependencies import get_session
from ..m3u8_resolver import resolver as m3u8_resolver
from ..config import M3U8_SEARCH_ENABLED, PLAYBACK_PROVIDER_IDS

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v2", tags=["compat-v2"])


@router.get("/search")
async def unified_search(
    keyword: str = Query(""),
    content_type: str = Query(None),
    max_results: int = Query(30),
) -> JSONResponse:
    """统一搜索 - 聚合所有源。"""

    types = content_type.split(",") if content_type else None
    results = await aggregator.search(keyword, types, max_results)
    return JSONResponse(
        [
            {
                "id": item.id,
                "title": item.title,
                "original_title": item.original_title,
                "cover_url": item.cover_url,
                "banner_url": item.banner_url,
                "summary": item.summary,
                "content_type": item.content_type,
                "language": item.language,
                "year": item.year,
                "regions": item.regions,
                "genres": item.genres,
                "rating": item.rating,
                "rating_count": item.rating_count,
                "total_episodes": item.total_episodes,
                "status": item.status,
                "sources": item.sources,
            }
            for item in results
        ]
    )


@router.get("/episodes/{subject_id:path}")
async def unified_episodes(subject_id: str) -> JSONResponse:
    episodes = await aggregator.get_episodes(subject_id)
    return JSONResponse(
        [
            {
                "number": episode.number,
                "title": episode.title,
                "thumbnail": episode.thumbnail,
                "duration": episode.duration,
            }
            for episode in episodes
        ]
    )


@router.get("/vod/{subject_id:path}")
async def unified_vod(
    subject_id: str,
    episode: int = Query(1),
    title: str = Query(""),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    """Return retained v2 playback lines with the historical cache contract."""

    cache_ttl = 6 * 3600
    result = await session.execute(
        select(PlaybackCache).where(
            PlaybackCache.subject_id == subject_id,
            PlaybackCache.episode == episode,
        )
    )
    row = result.scalar_one_or_none()
    if row and row.line_count > 0 and (time.time() - row.verified_at) < cache_ttl:
        try:
            cached_lines = json.loads(row.lines_json)
            return JSONResponse(
                [
                    {
                        "url": line.get("url", ""),
                        "title": line.get("title", ""),
                        "quality": line.get("quality", ""),
                        "format": line.get("format", ""),
                        "source": line.get("source", ""),
                        "headers": line.get("headers", {}),
                        "cached": True,
                    }
                    for line in cached_lines
                ]
            )
        except (json.JSONDecodeError, TypeError):
            pass

    lines = await aggregator.resolve_verified_lines(
        subject_id,
        episode,
        title,
        verify=True,
    )
    lines_data = [
        {
            "url": line.url,
            "title": line.title,
            "quality": line.quality,
            "format": line.format,
            "source": line.source,
            "headers": line.headers,
        }
        for line in lines
    ]
    if lines_data:
        try:
            await upsert_playback_cache(
                session,
                subject_id=subject_id,
                episode=episode,
                title=title,
                lines_json=json.dumps(lines_data, ensure_ascii=False),
                line_count=len(lines_data),
                verified_at=time.time(),
            )
        except Exception as error:
            logger.warning("Playback cache write failed: %s", error)

    return JSONResponse([{**line, "cached": False} for line in lines_data])


@router.get("/home")
async def unified_home() -> JSONResponse:
    return JSONResponse(await aggregator.get_home_feed())


@router.get("/resolve")
async def resolve_m3u8(
    url: str = Query(""),
    keyword: str = Query(""),
) -> JSONResponse:
    if not PLAYBACK_PROVIDER_IDS or not M3U8_SEARCH_ENABLED:
        results = []
    elif url:
        results = await m3u8_resolver.resolve_via_parse_services(url)
    elif keyword:
        results = await m3u8_resolver.search_and_resolve(keyword)
    else:
        results = []
    return JSONResponse(
        [
            {
                "url": result["url"],
                "format": result.get("format", "hls"),
                "source": result.get("source", "unknown"),
            }
            for result in results
        ]
    )
