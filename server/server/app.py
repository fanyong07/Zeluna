"""FastAPI application construction without route implementation details."""

from collections.abc import Callable
from contextlib import AbstractAsyncContextManager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .account_api import router as account_router
from .config import CORS_ORIGINS
from .routers import (
    admin_router,
    catalog_router,
    compat_v2_router,
    health_router,
    legacy_account_router,
    legacy_config_router,
    playback_router,
)

Lifespan = Callable[[FastAPI], AbstractAsyncContextManager[None]]


def create_app(*, lifespan: Lifespan | None = None) -> FastAPI:
    app = FastAPI(title="Zeluna API", version="3.0.0", lifespan=lifespan)
    app.include_router(account_router)
    app.include_router(legacy_account_router)
    app.include_router(legacy_config_router)
    app.include_router(compat_v2_router)
    app.include_router(health_router)
    app.include_router(catalog_router)
    app.include_router(playback_router)
    app.include_router(admin_router)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=CORS_ORIGINS,
        allow_credentials="*" not in CORS_ORIGINS,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    return app
