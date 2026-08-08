"""Zeluna FastAPI lifecycle and application composition."""

import asyncio
from contextlib import asynccontextmanager

from .aggregator import aggregator
from .app import create_app
from .catalog import catalog_service
from .database import async_session, init_db
from .email_outbox import EmailOutboxWorker
from .m3u8_resolver import resolver as m3u8_resolver
from .playback import playback_service
from .scheduler import scheduler


@asynccontextmanager
async def lifespan(_app):
    await init_db()
    await scheduler.start()
    outbox_task = asyncio.create_task(EmailOutboxWorker(async_session).run_forever())
    try:
        yield
    finally:
        outbox_task.cancel()
        try:
            await outbox_task
        except asyncio.CancelledError:
            pass
        await scheduler.stop()
        await playback_service.aclose()
        await aggregator.aclose()
        await catalog_service.aclose()
        await m3u8_resolver.aclose()


app = create_app(lifespan=lifespan)
