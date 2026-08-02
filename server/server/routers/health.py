"""Public service-health routes."""

from fastapi import APIRouter
from fastapi.responses import JSONResponse

from ..catalog import catalog_service
from ..playback import playback_service

router = APIRouter(prefix="/api/v3", tags=["health"])


@router.get("/status")
async def unified_status() -> JSONResponse:
    return JSONResponse(
        {
            "service": "zeluna",
            "version": 3,
            "providers": catalog_service.provider_status,
            "playback": "server-only",
            "playback_cache": playback_service.cache_metrics,
        }
    )
