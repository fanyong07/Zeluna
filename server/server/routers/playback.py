"""Stable-identity playback discovery routes."""

import logging

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse, PlainTextResponse
from sqlalchemy.ext.asyncio import AsyncSession

from ..aggregator import _is_public_http_url
from ..catalog import parse_stable_id
from ..dependencies import get_session
from ..playback import playback_service
from ..playlist_tokens import PlaylistTokenError, parse_playlist_token
from ..scrapers.hls_clean import clean_url

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v3", tags=["playback"])

#: 剪裁只处理清单文本(非媒体字节),清单体量远小于媒体。
_PLAYLIST_MAX_BYTES = 4 * 1024 * 1024
_PLAYLIST_TIMEOUT_SECONDS = 12.0
#: 测试注入点:置为 httpx.MockTransport 即可拦下出站请求。
playlist_transport: httpx.AsyncBaseTransport | None = None


def _playlist_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=_PLAYLIST_TIMEOUT_SECONDS,
        follow_redirects=True,
        transport=playlist_transport,
    )


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


@router.get("/playlist/{token:path}")
async def cleaned_playlist(token: str) -> PlainTextResponse:
    """返回剔除广告分片后的 HLS 清单文本。

    安全边界:
      * 只接受服务端签发的 token,**不接受任何裸 URL 参数**(否则该端点
        会变成开放代理 / SSRF 跳板);
      * 目标须为公网 HTTP(S),经 ``_is_public_http_url`` 复核;
      * 只读取清单文本、只在内存中重写,不落盘、不代理媒体分片;
      * 剪裁失败一律 502 交由客户端回退原直链,不静默返回坏清单。
    """
    try:
        target = parse_playlist_token(token)
    except PlaylistTokenError as error:
        raise HTTPException(400, str(error)) from error

    if not await _is_public_http_url(target.url):
        raise HTTPException(400, "清单地址不在允许范围内")

    headers = {"Referer": target.referer} if target.referer else None
    async with _playlist_client() as client:
        result = await clean_url(
            target.url,
            client=client,
            headers=headers,
            max_bytes=_PLAYLIST_MAX_BYTES,
        )
    if result is None:
        raise HTTPException(502, "清单不可用,请回退原始线路")

    logger.debug(
        "playlist cleaned: %s", result.report.as_public_dict()
    )
    return PlainTextResponse(
        result.playlist,
        media_type="application/vnd.apple.mpegurl",
        headers={"Cache-Control": "no-store"},
    )
