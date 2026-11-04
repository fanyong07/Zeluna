"""Zeluna FastAPI lifecycle and application composition."""

import asyncio
import logging
from contextlib import asynccontextmanager

from . import anich_refresh, config
from .aggregator import aggregator
from .app import create_app
from .catalog import catalog_service
from .catalog_artwork import catalog_artwork
from .database import async_session, init_db
from .email_outbox import EmailOutboxWorker
from .m3u8_resolver import resolver as m3u8_resolver
from .playback import playback_service
from .scheduler import scheduler
from .scrapers.anime.anich import close_resolver_tasks

logger = logging.getLogger(__name__)


async def _anich_refresh_loop() -> None:
    """周期性重解自建 CDN 包装地址。

    只做"续期",不做首次发现:首次发现由取线路池时触发(见
    ``anich_refresh.resolve_and_store``)。单轮失败只记日志,不影响主服务 ——
    解析要靠外部出口,出口抖动是常态,不能让它传染到播放链路。
    """
    interval = config.ANICH_RESOLVE_REFRESH_SECONDS
    while True:
        await asyncio.sleep(interval)
        try:
            async with async_session() as session:
                await anich_refresh.refresh_expiring(session)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - 后台续期不得中断进程
            logger.warning(
                "AniCh 地址续期失败: %s", type(error).__name__
            )


@asynccontextmanager
async def lifespan(_app):
    await init_db()
    await scheduler.start()
    # 地址缓存必须早于第一次播放装载:scraper 取线路时是**同步查内存**,
    # 缓存空着等于那批自建线路全部交付 403 的包装地址。
    async with async_session() as session:
        await anich_refresh.warm_cache(session)
    refresh_task = asyncio.create_task(_anich_refresh_loop())
    outbox_task = asyncio.create_task(EmailOutboxWorker(async_session).run_forever())
    try:
        yield
    finally:
        outbox_task.cancel()
        refresh_task.cancel()
        try:
            await outbox_task
        except asyncio.CancelledError:
            pass
        try:
            await refresh_task
        except asyncio.CancelledError:
            pass
        await close_resolver_tasks()
        await scheduler.stop()
        await playback_service.aclose()
        await aggregator.aclose()
        await catalog_service.aclose()
        await catalog_artwork.aclose()
        await m3u8_resolver.aclose()


app = create_app(lifespan=lifespan)