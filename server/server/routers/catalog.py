"""Stable-identity catalog routes."""

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from ..catalog import catalog_service, parse_stable_id
from ..dependencies import get_session

router = APIRouter(prefix="/api/v3/catalog", tags=["catalog"])


@router.get("/search")
async def catalog_search(
    query: str = Query(""),
    content_type: str = Query("anime,tv,movie"),
    limit: int = Query(40, ge=1, le=100),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    requested = [
        value.strip()
        for value in content_type.split(",")
        if value.strip() in {"anime", "tv", "movie"}
    ]
    return JSONResponse(
        await catalog_service.search(query, requested, session, limit=limit)
    )


@router.get("/home/{content_type}")
async def catalog_home(
    content_type: str,
    limit: int = Query(60, ge=1, le=300),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    if content_type not in {"anime", "tv", "movie"}:
        raise HTTPException(400, "不支持的内容类型")
    return JSONResponse(await catalog_service.home(content_type, session, limit=limit))


@router.get("/subject/{stable_id:path}")
async def catalog_subject(
    stable_id: str,
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    if parse_stable_id(stable_id) is None:
        raise HTTPException(400, "作品 ID 格式不正确")
    item = await catalog_service.get_subject(stable_id, session)
    if item is None:
        raise HTTPException(404, "作品信息暂不可用")
    return JSONResponse(item)
