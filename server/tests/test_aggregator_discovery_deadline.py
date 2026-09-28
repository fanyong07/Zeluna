import asyncio
import time
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import ContentAggregator, READ_TIMEOUT
from server.database import Base
from server.playback import PlaybackService
from server.playback_discovery import SourceDiscoveryStatus
from server.repositories.playback import SqlPlaybackRepository
from server.scrapers.base import SubjectResult


class _Crawler:
    content_types = frozenset({"anime"})

    async def search(self, _alias):
        return [
            SubjectResult(
                source_id="9",
                title="Fixture Anime",
                type="anime",
                year=2025,
            )
        ]

    async def get_detail(self, _source_id):
        raise AssertionError("Unexpected detail request in discovery fixture")

    async def get_video_urls(self, _source_id, _episode):
        return []

    async def get_latest(self, **_kwargs):
        return []

    async def aclose(self):
        pass


class DiscoveryDeadlineTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.blocked = set()
        self.empty = False
        self.details = []
        self.started = set()
        self.cancelled = set()
        self.release = asyncio.Event()
        self.slow_started = asyncio.Event()
        self.aggregator = ContentAggregator(
            crawler_scrapers={"fixture-crawler": _Crawler()},
            enabled_provider_ids=frozenset(
                {
                    "aggregate.maccms",
                    "crawler.fixture-crawler",
                }
            ),
        )
        scraper = self.aggregator._maccms
        await scraper._client.aclose()
        scraper._sites = [
            {
                "name": name,
                "api": f"https://source.test/{name}",
                "weight": 100,
                "precache": True,
            }
            for name in ("fixture-fast", "fixture-slow")
        ]

        async def handler(request):
            site = request.url.path.strip("/")
            if request.url.params.get("ids"):
                self.details.append(site)
                return httpx.Response(
                    200,
                    json={
                        "list": [
                            {
                                "vod_play_url": "第1集$https://93.184.216.34/fixture.m3u8",
                            }
                        ]
                    },
                )
            self.started.add(site)
            if self.empty:
                return httpx.Response(200, json={"list": []})
            if site in self.blocked:
                self.slow_started.set()
                try:
                    await self.release.wait()
                except asyncio.CancelledError:
                    self.cancelled.add(site)
                    raise
            return httpx.Response(
                200,
                json={
                    "list": [
                        {
                            "vod_id": "9",
                            "vod_name": "Fixture Anime",
                            "type_name": "动漫",
                            "vod_year": "2025",
                        },
                        # Strong identity checks still exclude a different season.
                        {
                            "vod_id": "10",
                            "vod_name": "Fixture Anime 第二季",
                            "type_name": "动漫",
                            "vod_year": "2026",
                        },
                    ]
                },
            )

        scraper._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    async def asyncTearDown(self):
        await self.aggregator.aclose()

    async def discover(self):
        return await self.aggregator.discover_source_matches(
            ["Fixture Anime"],
            content_type="anime",
            year=2025,
            include_diagnostics=True,
        )

    async def test_deadline_keeps_completed_maccms_matches_and_crawler(self):
        self.blocked.add("fixture-slow")
        started = time.monotonic()
        matches, diagnostics = await self.discover()
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, 7.8)
        self.assertLess(elapsed, 10)
        self.assertEqual(self.cancelled, {"fixture-slow"})
        self.assertEqual(
            diagnostics["fixture-fast"].status, SourceDiscoveryStatus.MATCHED
        )
        self.assertEqual(
            diagnostics["fixture-slow"].status, SourceDiscoveryStatus.SEARCH_TIMEOUT
        )
        self.assertEqual(diagnostics["fixture-slow"].error_category, READ_TIMEOUT)
        self.assertEqual(
            [match.source_id for match in matches],
            [
                "maccms:fixture-fast:9",
                "crawler:fixture-crawler:9",
            ],
        )

    async def test_completed_control_retains_order_identity_and_diagnostics(self):
        matches, diagnostics = await self.discover()
        self.assertEqual(
            [match.source_id for match in matches],
            [
                "maccms:fixture-fast:9",
                "maccms:fixture-slow:9",
                "crawler:fixture-crawler:9",
            ],
        )
        self.assertEqual(self.cancelled, set())
        self.assertTrue(all(item.matched for item in diagnostics.values()))
        self.assertTrue(
            all(item.aliases_attempted == 1 for item in diagnostics.values())
        )

    async def test_external_cancellation_propagates_and_drains_workers(self):
        self.blocked.add("fixture-slow")
        baseline = asyncio.all_tasks()
        task = asyncio.create_task(self.discover())
        try:
            await asyncio.wait_for(self.slow_started.wait(), timeout=2)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            self.assertEqual(self.cancelled, {"fixture-slow"})
            self.assertEqual(asyncio.all_tasks() - baseline, set())
        finally:
            if not task.done():
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

    async def test_all_slow_sources_timeout_without_negative_maccms_matches(self):
        self.blocked.update({"fixture-fast", "fixture-slow"})
        baseline = asyncio.all_tasks()
        matches, diagnostics = await self.discover()
        self.assertEqual(
            [match.source_id for match in matches], ["crawler:fixture-crawler:9"]
        )
        self.assertEqual(self.cancelled, self.blocked)
        for name in self.blocked:
            self.assertEqual(
                diagnostics[name].status, SourceDiscoveryStatus.SEARCH_TIMEOUT
            )
            self.assertTrue(diagnostics[name].queried)
            self.assertFalse(diagnostics[name].matched)
        self.assertEqual(asyncio.all_tasks() - baseline, set())

    async def test_empty_search_and_empty_alias_controls_keep_truthful_diagnostics(
        self,
    ):
        self.empty = True
        matches, diagnostics = await self.discover()
        self.assertEqual(
            [match.source_id for match in matches], ["crawler:fixture-crawler:9"]
        )
        for name in ("fixture-fast", "fixture-slow"):
            self.assertEqual(
                diagnostics[name].status, SourceDiscoveryStatus.SEARCH_MISS
            )
            self.assertTrue(diagnostics[name].queried)
            self.assertFalse(diagnostics[name].matched)
        matches, diagnostics = await self.aggregator.discover_source_matches(
            [],
            include_diagnostics=True,
        )
        self.assertEqual(matches, [])
        self.assertTrue(
            all(
                item.status == SourceDiscoveryStatus.NOT_QUERIED
                for item in diagnostics.values()
            )
        )

    async def test_cold_full_lookup_resolves_and_caches_completed_partial_match(self):
        self.blocked.add("fixture-slow")
        media_requests = []

        def media(request):
            media_requests.append(request.url.path)
            if request.url.path.endswith(".ts"):
                payload = bytearray(188 * 2)
                payload[0] = payload[188] = 0x47
                return httpx.Response(
                    206, content=bytes(payload), headers={"content-type": "video/mp2t"}
                )
            return httpx.Response(
                200,
                text="#EXTM3U\n#EXTINF:10,\nsegment.ts",
                headers={"content-type": "application/vnd.apple.mpegurl"},
            )

        self.aggregator._line_http_transport = httpx.MockTransport(media)
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        service = PlaybackService(session_factory=sessions, managed_lines_enabled=False)
        try:
            async with engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
            with (
                patch("server.playback.aggregator", self.aggregator),
                patch(
                    "server.playback.catalog_service.get_subject",
                    new=AsyncMock(return_value=None),
                ),
            ):
                async with sessions() as session:
                    items = await service.lines(
                        "bangumi:7003",
                        1,
                        session,
                        title="Fixture Anime",
                        content_type="anime",
                        year=2025,
                    )
                available = [item for item in items if item.get("available")]
                self.assertEqual(
                    [item["source"] for item in available], ["maccms:fixture-fast"]
                )
                self.assertEqual(available[0]["status"], "server_verified")
                self.assertEqual(self.details, ["fixture-fast"])
                self.assertEqual(media_requests, ["/fixture.m3u8", "/segment.ts"])
                self.assertEqual(self.cancelled, {"fixture-slow"})
                async with sessions() as session:
                    row = await SqlPlaybackRepository(session).get_cache(
                        "bangumi:7003", 1
                    )
                    self.assertEqual(row.scan_scope, "full")
                    self.assertEqual(row.line_count, 1)
                    cached = await service.lines("bangumi:7003", 1, session)
                self.assertTrue(all(item["cached"] for item in cached))
                self.assertEqual(
                    [item["url"] for item in cached if item.get("available")],
                    [item["url"] for item in available],
                )
                self.assertEqual(self.details, ["fixture-fast"])
        finally:
            await service.aclose()
            await engine.dispose()
