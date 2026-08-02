"""Explicit route groups for the Zeluna HTTP API."""

from .admin import router as admin_router
from .catalog import router as catalog_router
from .health import router as health_router
from .playback import router as playback_router

__all__ = [
    "admin_router",
    "catalog_router",
    "health_router",
    "playback_router",
]
