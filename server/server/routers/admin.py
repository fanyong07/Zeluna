"""Fail-closed administrative routes for modern services."""

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from ..dependencies import require_admin
from ..playback import playback_service

router = APIRouter(
    prefix="/admin/v3",
    tags=["admin"],
    dependencies=[Depends(require_admin)],
)


@router.post("/playback/refresh")
async def refresh_playback_cache(
    limit: int = Query(12, ge=1, le=50),
) -> JSONResponse:
    return JSONResponse(await playback_service.refresh_due(limit=limit))
