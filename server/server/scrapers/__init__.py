"""
爬虫注册表 + 调度器

所有爬虫在此注册，调度器负责定时运行和结果汇总。
"""

import asyncio
import logging
from typing import Optional
from dataclasses import dataclass, field
from datetime import datetime

from .base import BaseScraper, SubjectResult, SubjectDetail, VideoLine

logger = logging.getLogger(__name__)


@dataclass
class ScraperRunStats:
    """单次爬取统计"""
    scraper_name: str = ""
    subjects_found: int = 0
    subjects_new: int = 0
    subjects_updated: int = 0
    video_lines_found: int = 0
    errors: int = 0
    duration_seconds: float = 0
    started_at: Optional[datetime] = None
    finished_at: Optional[datetime] = None


class ScraperRegistry:
    """爬虫注册表 — 管理所有已注册的爬虫"""

    def __init__(self):
        self._scrapers: dict[str, BaseScraper] = {}
        self._stats: dict[str, ScraperRunStats] = {}

    def register(self, scraper: BaseScraper) -> None:
        """注册一个爬虫"""
        self._scrapers[scraper.name] = scraper
        logger.info(f"Registered scraper: {scraper.name} ({scraper.content_types})")

    def get(self, name: str) -> Optional[BaseScraper]:
        return self._scrapers.get(name)

    def get_by_content_type(self, content_type: str) -> list[BaseScraper]:
        """按内容类型获取爬虫"""
        return [
            s for s in self._scrapers.values()
            if content_type in s.content_types
        ]

    @property
    def all_scrapers(self) -> list[BaseScraper]:
        return list(self._scrapers.values())

    @property
    def stats(self) -> dict[str, ScraperRunStats]:
        return dict(self._stats)

    async def search_all(
        self,
        keyword: str,
        content_types: list[str] = None,
    ) -> list[tuple[str, list[SubjectResult]]]:
        """在所有爬虫中搜索"""
        results = []
        scrapers = (
            self.all_scrapers if content_types is None
            else [
                s for s in self.all_scrapers
                if any(ct in s.content_types for ct in content_types)
            ]
        )

        async def _search_one(scraper: BaseScraper):
            try:
                items = await scraper.search(keyword)
                return (scraper.name, items)
            except Exception as e:
                logger.error(f"Search error in {scraper.name}: {e}")
                return (scraper.name, [])

        tasks = [_search_one(s) for s in scrapers]
        results = await asyncio.gather(*tasks)
        return list(results)

    async def get_video_sources_all(
        self,
        subject_id: str,
        episode: int = 1,
        source_name: str = None,
    ) -> list[VideoLine]:
        """从指定爬虫获取视频源，或尝试所有爬虫"""
        if source_name:
            scraper = self.get(source_name)
            if scraper:
                try:
                    return await scraper.get_video_urls(subject_id, episode)
                except Exception as e:
                    logger.error(f"Video source error in {source_name}: {e}")
                    return []
            return []

        # 尝试所有爬虫
        all_lines = []
        for scraper in self.all_scrapers:
            try:
                lines = await scraper.get_video_urls(subject_id, episode)
                all_lines.extend(lines)
            except Exception:
                continue
        return all_lines

    async def run_full_scan(
        self,
        content_types: list[str] = None,
        max_pages: int = 3,
    ) -> list[ScraperRunStats]:
        """运行完整扫描：从所有爬虫拉取最新内容"""
        scrapers = (
            self.all_scrapers if content_types is None
            else self.get_by_content_type(content_types[0])
        ) if len(content_types or []) <= 1 else [
            s for s in self.all_scrapers
            if any(ct in s.content_types for ct in content_types)
        ]

        all_stats = []
        for scraper in scrapers:
            stats = ScraperRunStats(
                scraper_name=scraper.name,
                started_at=datetime.now(),
            )
            try:
                start = datetime.now()
                subjects = await scraper.get_latest(page=1)
                for page in range(2, max_pages + 1):
                    try:
                        more = await scraper.get_latest(page=page)
                        if not more:
                            break
                        subjects.extend(more)
                    except Exception:
                        break

                stats.subjects_found = len(subjects)
                stats.duration_seconds = (datetime.now() - start).total_seconds()
                stats.finished_at = datetime.now()
                logger.info(
                    f"Scan complete: {scraper.name} — "
                    f"{stats.subjects_found} subjects in {stats.duration_seconds:.1f}s"
                )
            except Exception as e:
                stats.errors += 1
                logger.error(f"Scan failed for {scraper.name}: {e}")

            self._stats[scraper.name] = stats
            all_stats.append(stats)

        return all_stats


# 全局注册表实例
registry = ScraperRegistry()
