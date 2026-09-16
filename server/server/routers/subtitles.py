"""Original-language supplements; no uploads, auth tokens or arbitrary URLs."""

import re

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, Response

from ..account_api import _client_key, _rate_limit
from ..subtitles import (
    SubtitleSearchRequest,
    SubtitleService,
    SubtitleServiceError,
    get_subtitle_service,
)

router = APIRouter(prefix="/api/v3/subtitles", tags=["subtitles"])


@router.post("/search")
async def search_subtitles(
    body: SubtitleSearchRequest,
    request: Request,
    service: SubtitleService = Depends(get_subtitle_service),
):
    await _rate_limit(
        f"subtitles-search:{_client_key(request)}", limit=30, window_seconds=60
    )
    return await service.search(body)


@router.get("/{candidate_id}/content")
async def subtitle_content(
    candidate_id: str,
    request: Request,
    service: SubtitleService = Depends(get_subtitle_service),
):
    if re.fullmatch(r"[a-f0-9]{32}", candidate_id) is None:
        raise HTTPException(404, detail={"code": "candidate_expired"})
    await _rate_limit(
        f"subtitles-file:{_client_key(request)}", limit=30, window_seconds=60
    )
    try:
        content, _ = await service.content(candidate_id)
    except SubtitleServiceError as error:
        raise HTTPException(error.status, detail={"code": error.code}) from None
    except (httpx.HTTPError, TimeoutError):
        raise HTTPException(503, detail={"code": "provider_unavailable"}) from None
    return Response(
        content,
        media_type="application/octet-stream",
        headers={
            "Cache-Control": "private, max-age=300",
            "X-Content-Type-Options": "nosniff",
        },
    )
