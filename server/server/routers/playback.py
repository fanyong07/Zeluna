"""Stable-identity playback discovery routes."""

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from ..catalog import parse_stable_id
from ..dependencies import get_session
from ..playback import playback_service

router = APIRouter(prefix="/api/v3", tags=["playback"])


@router.get("/quick-playback/{stable_id:path}")
async def quick_stable_playback(
    stable_id: str,
    episode: int = Query(1, ge=1),
    title: str = Query("", max_length=500),
    original_title: str = Query("", max_length=500),
    content_type: str = Query("", max_length=20),
    year: int = Query(0, ge=0, le=9999),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    """Return a compact first-play inventory without waiting for a full scan."""

    if parse_stable_id(stable_id) is None:
        raise HTTPException(400, "作品 ID 格式不正确")
    lines = await playback_service.quick_lines(
        stable_id,
        episode,
        session,
        title=title,
        original_title=original_title,
        content_type=content_type,
        year=year,
    )
    return JSONResponse(lines)


@router.get("/playback/{stable_id:path}")
async def stable_playback(
    stable_id: str,
    episode: int = Query(1, ge=1),
    title: str = Query("", max_length=500),
    original_title: str = Query("", max_length=500),
    content_type: str = Query("", max_length=20),
    year: int = Query(0, ge=0, le=9999),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    if parse_stable_id(stable_id) is None:
        raise HTTPException(400, "作品 ID 格式不正确")
    lines = await playback_service.lines(
        stable_id,
        episode,
        session,
        title=title,
        original_title=original_title,
        content_type=content_type,
        year=year,
    )
    return JSONResponse(lines)
