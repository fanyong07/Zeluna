"""
定时调度器

负责定时执行爬取任务和元数据同步。

使用 APScheduler 实现定时任务:
  - 每 6 小时扫描一次最新番剧/剧集更新
  - 每 12 小时同步一次元数据
  - 每 1 小时检查一次视频源有效性

启动方式:
  在 main.py 的 startup 事件中调用 scheduler.start()
"""

import asyncio
import logging
from datetime import datetime

from .scrapers import registry
from .scrapers.maccms import MacCmsScraper
from .scrapers.series.vod_common import CommonVodScraper
from .scrapers.tvbox_adapter import TvBoxAdapterScraper
from .database import async_session
from .aggregator import aggregator
from .catalog import catalog_service
from .playback import playback_service
from .privacy import PrivacyCleanup, run_privacy_cleanup
from .config import (
    ACCOUNT_DELETION_BATCH_SIZE,
    PRECACHE_ENABLED,
    PRECACHE_INTERVAL_HOURS,
    PRECACHE_MAX_SUBJECTS,
    PRIVACY_CLEANUP_INTERVAL_HOURS,
)

logger = logging.getLogger(__name__)


class ContentScheduler:
    """
    内容调度器

    管理定时爬取、元数据同步和源健康检查。
    """

    def __init__(self, *, privacy_session_factory=async_session):
        self._tasks: dict[str, asyncio.Task] = {}
        self._running = False
        self._privacy_session_factory = privacy_session_factory
        self._stats = {
            "last_scan": None,
            "last_sync": None,
            "last_health_check": None,
            "last_privacy_cleanup": None,
            "privacy_cleanup": None,
            "total_subjects": 0,
            "total_episodes": 0,
        }

    @property
    def stats(self) -> dict:
        return dict(self._stats)

    @staticmethod
    def _has_active_playback_provider() -> bool:
        return any(item.enabled for item in aggregator.provider_metadata)

    async def start(self):
        """启动调度器"""
        if self._running:
            return

        self._running = True

        # 注册爬虫
        self._register_scrapers()

        # 源质量受服务器地区影响，默认只做按需缓存。管理员确认该地区
        # 有足够活源后，可用 PRECACHE_ENABLED=true 开启后台预爬。
        if PRECACHE_ENABLED:
            self._tasks["precache"] = asyncio.create_task(self._precache_loop())
        self._tasks["cache_refresh"] = asyncio.create_task(
            self._cache_refresh_loop()
        )
        self._tasks["metadata"] = asyncio.create_task(self._metadata_loop())
        self._tasks["health"] = asyncio.create_task(self._health_loop())
        self._tasks["privacy"] = asyncio.create_task(self._privacy_loop())

        logger.info("Scheduler started")

    async def stop(self):
        """停止调度器"""
        self._running = False
        for name, task in self._tasks.items():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        self._tasks.clear()
        await asyncio.gather(
            *(scraper.aclose() for scraper in registry.registered_scrapers),
            return_exceptions=True,
        )
        logger.info("Scheduler stopped")

    def _register_scrapers(self):
        """注册所有爬虫"""
        scrapers = [
            MacCmsScraper(),
            CommonVodScraper(),
            TvBoxAdapterScraper(),
        ]
        for scraper in scrapers:
            registry.register(scraper)
        logger.info(f"Registered {len(scrapers)} scrapers")

    async def scan_new_content(self, content_types: list[str] = None):
        """按稳定作品 ID 预爬热门/近期内容的首集线路。"""
        if not self._has_active_playback_provider():
            logger.info("Content scan skipped: no active playback provider")
            return
        start = datetime.now()
        cached = 0
        requested = content_types or ["anime", "tv", "movie"]
        subjects: list[dict] = []
        async with async_session() as session:
            for media_type in requested:
                if media_type not in {"anime", "tv", "movie"}:
                    continue
                try:
                    subjects.extend(
                        await catalog_service.home(
                            media_type,
                            session,
                            limit=max(8, PRECACHE_MAX_SUBJECTS // 2),
                        )
                    )
                except Exception as error:
                    logger.warning(
                        "Catalog precache list failed for %s: %s",
                        media_type,
                        type(error).__name__,
                    )

        seen: set[str] = set()
        for subject in subjects:
            stable_id = str(subject.get("stable_id") or "")
            if not stable_id or stable_id in seen:
                continue
            seen.add(stable_id)
            if len(seen) > PRECACHE_MAX_SUBJECTS:
                break
            try:
                async with async_session() as session:
                    lines = await playback_service.lines(
                        stable_id,
                        1,
                        session,
                        title=str(subject.get("title") or ""),
                        original_title=str(subject.get("original_title") or ""),
                        content_type=str(subject.get("media_type") or ""),
                        force=True,
                    )
                if lines:
                    cached += 1
            except Exception as e:
                logger.debug("Precache skip %s: %s", stable_id, type(e).__name__)

        duration = (datetime.now() - start).total_seconds()
        logger.info(f"Precache done: {cached} subjects cached in {duration:.1f}s")

    async def _precache_loop(self):
        """启动时立即预爬一次，之后按配置间隔刷新。"""
        try:
            await self.scan_new_content()
        except Exception as e:
            logger.error(f"Initial precache error: {e}")
        while self._running:
            try:
                await asyncio.sleep(PRECACHE_INTERVAL_HOURS * 3600)
                if self._running:
                    await self.scan_new_content()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Precache loop error: {e}")

    async def _cache_refresh_loop(self):
        """持续刷新曾被用户请求过的线路，确保下次打开优先命中活缓存。"""
        while self._running:
            try:
                await asyncio.sleep(300)
                if self._running:
                    if not self._has_active_playback_provider():
                        continue
                    result = await playback_service.refresh_due(limit=12)
                    self._stats["last_scan"] = datetime.now().isoformat()
                    self._stats["cache_refresh"] = result
                await asyncio.sleep(55 * 60)
            except asyncio.CancelledError:
                break
            except Exception as error:
                logger.warning("Playback refresh loop failed: %s", type(error).__name__)

    async def _metadata_loop(self):
        """把三类热门目录保持在本地，客户端无需持有个人 API Token。"""
        while self._running:
            try:
                if not self._has_active_playback_provider():
                    await asyncio.sleep(300)
                    continue
                async with async_session() as session:
                    for media_type in ("anime", "tv", "movie"):
                        await catalog_service.home(media_type, session, limit=240)
                self._stats["last_sync"] = datetime.now().isoformat()
                await asyncio.sleep(12 * 3600)
            except asyncio.CancelledError:
                break
            except Exception as error:
                logger.warning("Metadata sync loop failed: %s", type(error).__name__)
                await asyncio.sleep(30 * 60)

    async def _health_loop(self):
        """每 1 小时检查一次源站健康"""
        while self._running:
            try:
                await asyncio.sleep(3600)
                if self._running:
                    if not self._has_active_playback_provider():
                        continue
                    self._stats["last_health_check"] = datetime.now().isoformat()
                    for scraper in registry.all_scrapers:
                        try:
                            results = await scraper.search("斗罗大陆")
                            logger.info(
                                f"Health {scraper.name}: "
                                f"{'OK' if results else 'NO RESULTS'}"
                            )
                        except Exception as e:
                            logger.warning(f"Health check failed {scraper.name}: {e}")
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Health loop error: {e}")

    async def cleanup_privacy_artifacts(self) -> PrivacyCleanup:
        async with self._privacy_session_factory() as session:
            cleanup = await run_privacy_cleanup(
                session,
                account_limit=ACCOUNT_DELETION_BATCH_SIZE,
            )
            await session.commit()
        self._stats["last_privacy_cleanup"] = datetime.now().isoformat()
        self._stats["privacy_cleanup"] = {
            "verification_codes": cleanup.verification_codes,
            "sessions": cleanup.sessions,
            "finalized_accounts": cleanup.finalized_accounts,
        }
        return cleanup

    async def _privacy_loop(self):
        while self._running:
            try:
                await asyncio.sleep(PRIVACY_CLEANUP_INTERVAL_HOURS * 3600)
                if self._running:
                    await self.cleanup_privacy_artifacts()
            except asyncio.CancelledError:
                break
            except Exception as error:
                logger.warning(
                    "Privacy retention cleanup failed: %s",
                    type(error).__name__,
                )
                await asyncio.sleep(3600)


# 全局调度器实例
scheduler = ContentScheduler()
