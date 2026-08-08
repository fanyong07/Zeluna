import asyncio
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from server.app import create_app
from server.scheduler import ContentScheduler
from server.scrapers import ScraperRegistry
from server.scrapers.base import BaseScraper, SubjectDetail, SubjectResult, VideoLine


class _FailOnCallScraper(BaseScraper):
    def __init__(self, name: str = "maccms") -> None:
        super().__init__()
        self._name = name
        self.calls: list[str] = []

    @property
    def content_types(self) -> list[str]:
        return ["anime", "movie"]

    @property
    def base_url(self) -> str:
        return "https://provider.invalid"

    def _fail(self, operation: str):
        self.calls.append(operation)
        raise AssertionError(f"disabled provider called: {operation}")

    async def search(self, keyword: str) -> list[SubjectResult]:
        return self._fail("search")

    async def get_detail(self, source_id: str) -> SubjectDetail | None:
        return self._fail("detail")

    async def get_video_urls(self, source_id: str, episode: int = 1) -> list[VideoLine]:
        return self._fail("resolve")

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        return self._fail("latest")


def test_empty_allowlist_blocks_legacy_registry_operations():
    async def exercise():
        scraper = _FailOnCallScraper()
        registry = ScraperRegistry(enabled_provider_ids=frozenset())
        registry.register(scraper)

        assert registry.registered_scrapers == [scraper]
        assert registry.all_scrapers == []
        assert registry.get("maccms") is None
        assert await registry.search_all("title") == []
        assert await registry.get_video_sources_all("source") == []
        assert (
            await registry.get_video_sources_all("source", source_name="maccms") == []
        )
        assert await registry.run_full_scan(["anime"]) == []
        assert scraper.calls == []

    asyncio.run(exercise())


def test_explicit_legacy_provider_activation_is_scoped_to_that_provider():
    async def exercise():
        scraper = _FailOnCallScraper()
        registry = ScraperRegistry(enabled_provider_ids=frozenset({"aggregate.maccms"}))
        registry.register(scraper)

        assert await registry.search_all("title") == [("maccms", [])]
        assert scraper.calls == ["search"]

    asyncio.run(exercise())


def test_scheduler_scan_is_noop_without_active_playback_provider():
    async def exercise():
        scheduler = ContentScheduler()
        home = AsyncMock(side_effect=AssertionError("catalog provider called"))
        lines = AsyncMock(side_effect=AssertionError("playback provider called"))
        with (
            patch("server.scheduler.catalog_service.home", new=home),
            patch("server.scheduler.playback_service.lines", new=lines),
        ):
            await scheduler.scan_new_content()
        home.assert_not_awaited()
        lines.assert_not_awaited()

    asyncio.run(exercise())


def test_scheduler_start_has_no_provider_outbound_when_allowlist_is_empty():
    async def exercise():
        scheduler = ContentScheduler()
        home = AsyncMock(side_effect=AssertionError("catalog provider called"))
        with patch("server.scheduler.catalog_service.home", new=home):
            await scheduler.start()
            await asyncio.sleep(0)
            await scheduler.stop()
        home.assert_not_awaited()

    asyncio.run(exercise())


def test_admin_scraper_search_uses_the_same_activation_policy():
    scraper = _FailOnCallScraper()
    registry = ScraperRegistry(enabled_provider_ids=frozenset())
    registry.register(scraper)
    app = create_app()

    with (
        patch("server.dependencies.ADMIN_TOKEN", "test-admin-token"),
        patch("server.routers.admin.scraper_registry", registry),
    ):
        response = TestClient(app).get(
            "/admin/scrapers/search",
            params={"keyword": "title"},
            headers={"X-Zeluna-Admin": "test-admin-token"},
        )

    assert response.status_code == 200
    assert response.json() == []
    assert scraper.calls == []


def test_compat_resolver_has_no_outbound_authority_when_allowlist_is_empty():
    parse = AsyncMock(return_value=[{"url": "https://media.invalid/stream.m3u8"}])
    with (
        patch("server.routers.compat_v2.PLAYBACK_PROVIDER_IDS", frozenset()),
        patch("server.routers.compat_v2.M3U8_SEARCH_ENABLED", True),
        patch(
            "server.routers.compat_v2.m3u8_resolver.resolve_via_parse_services",
            new=parse,
        ),
    ):
        response = TestClient(create_app()).get(
            "/api/v2/resolve",
            params={"url": "https://media.invalid/stream.m3u8"},
        )

    assert response.status_code == 200
    assert response.json() == []
    parse.assert_not_awaited()
