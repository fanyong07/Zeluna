import unittest
from unittest.mock import patch

from server.aggregator import aggregator
from server.scheduler import ContentScheduler
from server.scrapers.site_index import SiteIndex


class _IndexableScraper:
    """带 build_local_index 的站(需要本地索引的那类)。"""

    def __init__(self, *, size: int = 3, age_hours: float = 99.0, fail: bool = False):
        self._size = size
        self._age = age_hours
        self._fail = fail
        self.builds = 0
        self.index: SiteIndex | None = None
        if age_hours < 99.0:
            self.index = SiteIndex(site="pre")
            for i in range(size):
                self.index.add(str(i), f"作品{i}")
            # 让 age_hours() 返回指定值
            import time as _time

            self.index.built_at = _time.time() - age_hours * 3600

    async def build_local_index(self, *, pages: int = 3):
        self.builds += 1
        if self._fail:
            raise RuntimeError("boom")
        index = SiteIndex(site="built")
        for i in range(self._size):
            index.add(str(i), f"作品{i}")
        self.index = index
        return index


class _PlainScraper:
    """普通站(站内搜索可用,不需要索引)。"""


class SiteIndexLoopTests(unittest.IsolatedAsyncioTestCase):
    async def _rebuild(self, scrapers: dict) -> dict:
        """走真实的 active_crawler_scrapers 计算路径,只替换底层字典与启用集。"""
        scheduler = ContentScheduler()
        enabled = frozenset(f"crawler.{name}" for name in scrapers)
        with (
            patch.object(aggregator, "_crawler_scrapers", scrapers),
            patch.object(aggregator, "_enabled_provider_ids", enabled),
        ):
            return await scheduler._rebuild_site_indexes()

    async def test_builds_index_for_scrapers_that_need_one(self):
        indexable = _IndexableScraper(size=4)
        built = await self._rebuild({"needs": indexable, "plain": _PlainScraper()})
        self.assertEqual(built, {"needs": 4})
        self.assertEqual(indexable.builds, 1)

    async def test_fresh_index_is_not_rebuilt(self):
        fresh = _IndexableScraper(size=2, age_hours=1.0)
        built = await self._rebuild({"fresh": fresh})
        self.assertEqual(built, {})
        self.assertEqual(fresh.builds, 0)

    async def test_stale_index_is_rebuilt(self):
        stale = _IndexableScraper(size=5, age_hours=48.0)
        built = await self._rebuild({"stale": stale})
        self.assertEqual(built, {"stale": 5})
        self.assertEqual(stale.builds, 1)

    async def test_one_site_failure_does_not_block_others(self):
        broken = _IndexableScraper(fail=True)
        healthy = _IndexableScraper(size=2)
        built = await self._rebuild({"broken": broken, "healthy": healthy})
        self.assertEqual(built, {"healthy": 2})
        self.assertEqual(broken.builds, 1)

    async def test_scrapers_without_index_support_are_skipped(self):
        built = await self._rebuild({"plain": _PlainScraper()})
        self.assertEqual(built, {})

    async def test_loop_task_is_registered_on_start(self):
        scheduler = ContentScheduler()
        with (
            patch.object(scheduler, "_register_scrapers"),
            patch("server.scheduler.PRECACHE_ENABLED", False),
        ):
            await scheduler.start()
            try:
                self.assertIn("site_index", scheduler._tasks)
            finally:
                await scheduler.stop()


if __name__ == "__main__":
    unittest.main()
