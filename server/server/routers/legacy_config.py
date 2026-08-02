"""Default-disabled compatibility configuration endpoint."""

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from ..config import PUBLIC_BASE_URL
from ..dependencies import require_legacy_config_api

router = APIRouter(
    tags=["legacy-config"],
    dependencies=[Depends(require_legacy_config_api)],
)


@router.get("/check/api")
async def check_api() -> JSONResponse:
    """Return a sanitized compatibility shape without third-party routes."""

    return JSONResponse(
        {
            "baseUrl": PUBLIC_BASE_URL,
            "bilibiliApiUrl": "",
            "qqVideoApiUrl": "",
            "dandanApiUrl": "",
            "updateUrl": "",
            "githubProxyUrl": "",
            "apis": [PUBLIC_BASE_URL],
            "ghproxy": [],
        }
    )
