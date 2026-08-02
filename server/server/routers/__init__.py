"""Explicit route groups for the Zeluna HTTP API."""

from .admin import router as admin_router
from .catalog import router as catalog_router
from .compat_v2 import router as compat_v2_router
from .health import router as health_router
from .legacy_account import router as legacy_account_router
from .legacy_config import router as legacy_config_router
from .legacy_community import router as legacy_community_router
from .legacy_media import router as legacy_media_router
from .playback import router as playback_router

__all__ = [
    "admin_router",
    "catalog_router",
    "compat_v2_router",
    "health_router",
    "legacy_account_router",
    "legacy_config_router",
    "legacy_community_router",
    "legacy_media_router",
    "playback_router",
]
