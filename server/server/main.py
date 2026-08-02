"""Zeluna FastAPI lifecycle and application composition."""

from contextlib import asynccontextmanager

from .aggregator import aggregator
from .app import create_app
from .catalog import catalog_service
from .database import init_db
from .m3u8_resolver import resolver as m3u8_resolver
from .playback import playback_service
from .scheduler import scheduler


@asynccontextmanager
async def lifespan(_app):
    await init_db()
    await scheduler.start()
    try:
        yield
    finally:
        await scheduler.stop()
        await playback_service.aclose()
        await aggregator.aclose()
        await catalog_service.aclose()
        await m3u8_resolver.aclose()


app = create_app(lifespan=lifespan)
