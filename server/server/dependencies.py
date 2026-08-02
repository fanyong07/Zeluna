"""Shared FastAPI dependencies for the Zeluna application."""

import secrets
from collections.abc import AsyncIterator

from fastapi import HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession

from .config import ADMIN_TOKEN, LEGACY_ACCOUNT_API_ENABLED, LEGACY_CONFIG_API_ENABLED
from .database import async_session


async def get_session() -> AsyncIterator[AsyncSession]:
    async with async_session() as session:
        yield session


async def require_admin(request: Request) -> None:
    """Keep administrative routes undiscoverable without explicit config."""

    supplied = request.headers.get("X-Zeluna-Admin", "").strip()
    if not ADMIN_TOKEN or not secrets.compare_digest(supplied, ADMIN_TOKEN):
        raise HTTPException(status_code=404, detail="Not found")


def require_legacy_account_api() -> None:
    """Legacy protobuf account routes remain disabled by default."""

    if not LEGACY_ACCOUNT_API_ENABLED:
        raise HTTPException(status_code=404, detail="Not found")


def require_legacy_config_api() -> None:
    """Historical client configuration stays disabled by default."""

    if not LEGACY_CONFIG_API_ENABLED:
        raise HTTPException(status_code=404, detail="Not found")
