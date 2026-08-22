"""Public service-health routes."""

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from ..aggregator import aggregator
from ..catalog import catalog_service
from ..playback import playback_service

router = APIRouter(prefix="/api/v3", tags=["health"])


@router.get("/status")
async def unified_status(request: Request) -> JSONResponse:
    return JSONResponse(
        {
            "service": "zeluna",
            "version": 3,
            "providers": catalog_service.provider_status,
            "playback": "server-only",
            "playback_providers": {
                "enabled_ids": [
                    item.provider_id
                    for item in aggregator.provider_metadata
                    if item.enabled
                ],
            },
            "playback_cache": playback_service.cache_metrics,
            "observability": request.app.state.observability.snapshot(),
        }
    )
