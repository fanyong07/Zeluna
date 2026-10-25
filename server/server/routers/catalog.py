"""Stable-identity catalog routes."""

from typing import Annotated, Literal

import httpx

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
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


@router.get("/discover/{content_type}")
async def catalog_discover(
    content_type: Literal["tv", "movie"],
    sort: Literal["recommended", "popular", "topRated", "latest"] = "recommended",
    genre: str = Query("全部", max_length=24),
    language: Literal["全部", "日语", "国语", "英语", "韩语", "其他"] = "全部",
    year: int | None = Query(None, ge=1900, le=2100),
    page: int = Query(1, ge=1, le=500),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    if genre not in {"全部", "动画", "电影", "剧情", "犯罪", "喜剧", "冒险", "奇幻", "动作", "科幻", "音乐", "美剧", "英剧", "日剧", "韩剧"}:
        raise HTTPException(400, "不支持的分类")
    try:
        result = await catalog_service.discover(content_type, session, sort=sort,
                                               genre=genre, language=language,
                                               year=year, page=page)
    except (httpx.HTTPError, ValueError, RuntimeError) as error:
        raise HTTPException(503, "片库暂时无法查询，请稍后重试") from error
    return JSONResponse(result)


class _PublicBangumiFilter(BaseModel):
    model_config = ConfigDict(extra="forbid")
    type: list[Literal[2]] = Field(default_factory=lambda: [2], min_length=1, max_length=1)
    nsfw: Literal[False] = False
    tag: list[Annotated[str, Field(min_length=1, max_length=32)]] | None = Field(None, max_length=6)
    air_date: list[Annotated[str, Field(pattern=r"^[<>]=?\d{4}-\d{2}-\d{2}$")]] | None = Field(None, max_length=2)


class _PublicBangumiSearch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    keyword: Literal[""] = ""
    sort: Literal["heat", "score"] = "heat"
    filter: _PublicBangumiFilter = Field(default_factory=_PublicBangumiFilter)


async def _public_bangumi_response(route: str, **kwargs) -> JSONResponse:
    try:
        return JSONResponse(await catalog_service.public_bangumi_catalog(route, **kwargs))
    except (httpx.HTTPError, ValueError, RuntimeError) as error:
        raise HTTPException(503, "番剧片库暂时无法查询，请稍后重试") from error


@router.get("/bangumi/calendar")
async def public_bangumi_calendar() -> JSONResponse:
    return await _public_bangumi_response("calendar")


@router.get("/bangumi/v0/subjects")
async def public_bangumi_subjects(
    type: Literal["2"] = "2",
    sort: Literal["date"] = "date",
    year: int = Query(..., ge=1900, le=2100),
    limit: int = Query(100, ge=1, le=100),
    offset: int = Query(0, ge=0, le=100000),
) -> JSONResponse:
    return await _public_bangumi_response("subjects", params={
        "type": int(type), "sort": sort, "year": year, "limit": limit, "offset": offset})


@router.post("/bangumi/v0/search/subjects")
async def public_bangumi_search(
    body: _PublicBangumiSearch,
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0, le=100000),
) -> JSONResponse:
    return await _public_bangumi_response("search", params={"limit": limit, "offset": offset},
                                         body=body.model_dump(exclude_none=True))


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
