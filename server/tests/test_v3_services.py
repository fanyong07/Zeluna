import asyncio
import json
import time
import unittest
from unittest.mock import AsyncMock, patch
from urllib.parse import urlparse

import httpx
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import (
    CLIENT_PROBE_REQUIRED,
    EMPTY_MEDIA,
    PARSER_MISMATCH,
    READ_TIMEOUT,
    SERVER_VERIFIED,
    SERVER_BLOCKED_CLIENT_CANDIDATE,
    STARTUP_HLS,
    STARTUP_MP4_FASTSTART,
    STARTUP_MP4_TAIL_MOOV,
    UNAVAILABLE,
    AggregatedVideoLine,
    SourceMatch,
    SourceResolutionOutcome,
    aggregator,
)
from server.catalog import CatalogService
from server.config import SOURCE_CIRCUIT_FAILURE_THRESHOLD
from server.database import (
    Base,
    CatalogSubject,
    PlaybackCache,
    SourceBinding,
    SourceHealth,
)
from server.playback import PlaybackService
from server.playback_discovery import (
    SourceDiscoveryDiagnostic,
    SourceDiscoveryStatus,
)
from server.repositories.catalog import SqlCatalogRepository
from server.scrapers.base import SubjectResult
from server.scrapers.maccms import MacCmsScraper
from server.scrapers.maccms_sites import MACCMS_SITES


class CatalogServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_bangumi_playback_aliases_use_verified_tmdb_alternatives(self):
        requested_paths: list[str] = []

        def handler(request: httpx.Request):
            requested_paths.append(request.url.path)
            if request.url.path == "/3/search/tv":
                return httpx.Response(
                    200,
                    json={
                        "results": [
                            {
                                "id": 24835,
                                "name": "CLANNAD",
                                "original_name": "CLANNAD",
                                "first_air_date": "2007-10-05",
                            }
                        ]
                    },
                )
            if request.url.path == "/3/tv/24835":
                return httpx.Response(
                    200,
                    json={
                        "id": 24835,
                        "name": "CLANNAD",
                        "original_name": "CLANNAD",
                        "first_air_date": "2007-10-05",
                        "alternative_titles": {
                            "results": [
                                {"title": "团子大家族"},
                                {"title": "CLANNAD ～AFTER STORY～"},
                            ]
                        },
                        "seasons": [
                            {
                                "season_number": 1,
                                "name": "CLANNAD",
                                "air_date": "2007-10-05",
                                "episode_count": 22,
                            },
                            {
                                "season_number": 2,
                                "name": "CLANNAD 〜AFTER STORY〜",
                                "air_date": "2008-10-03",
                                "episode_count": 22,
                            },
                        ],
                    },
                )
            return httpx.Response(404)

        service = CatalogService(transport=httpx.MockTransport(handler))
        metadata = {
            "stable_id": "bangumi:876",
            "provider": "bangumi",
            "media_type": "anime",
            "title": "CLANNAD 〜AFTER STORY〜",
            "original_title": "CLANNAD 〜AFTER STORY〜",
            "aliases": ["CLANNAD 〜AFTER STORY〜"],
            "date": "2008-10-02",
            "total_episodes": 22,
        }
        try:
            with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"):
                first = await service.playback_aliases(metadata)
                second = await service.playback_aliases(metadata)
        finally:
            await service.aclose()

        self.assertEqual(first[0], "团子大家族 第二季")
        self.assertIn("CLANNAD 〜AFTER STORY〜", first)
        self.assertEqual(second, first)
        self.assertEqual(requested_paths, ["/3/search/tv", "/3/tv/24835"])

    async def test_bangumi_playback_aliases_reject_unrelated_tmdb_result(self):
        def handler(request: httpx.Request):
            if request.url.path == "/3/search/tv":
                return httpx.Response(
                    200,
                    json={"results": [{"id": 999, "name": "After Story"}]},
                )
            if request.url.path == "/3/tv/999":
                return httpx.Response(
                    200,
                    json={
                        "id": 999,
                        "name": "After Story",
                        "original_name": "After Story",
                        "alternative_titles": {
                            "results": [{"title": "完全无关的作品"}]
                        },
                    },
                )
            return httpx.Response(404)

        service = CatalogService(transport=httpx.MockTransport(handler))
        metadata = {
            "stable_id": "bangumi:876",
            "provider": "bangumi",
            "media_type": "anime",
            "title": "CLANNAD 〜AFTER STORY〜",
            "original_title": "CLANNAD 〜AFTER STORY〜",
            "aliases": ["CLANNAD 〜AFTER STORY〜"],
        }
        try:
            with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"):
                aliases = await service.playback_aliases(metadata)
        finally:
            await service.aclose()

        self.assertEqual(aliases, ["CLANNAD 〜AFTER STORY〜"])

    async def test_bangumi_playback_aliases_do_not_cache_transient_tmdb_failure(self):
        search_calls = 0

        def handler(request: httpx.Request):
            nonlocal search_calls
            if request.url.path == "/3/search/tv":
                search_calls += 1
                if search_calls == 1:
                    return httpx.Response(503)
                return httpx.Response(
                    200,
                    json={"results": [{"id": 24835, "name": "CLANNAD"}]},
                )
            if request.url.path == "/3/tv/24835":
                return httpx.Response(
                    200,
                    json={
                        "id": 24835,
                        "name": "CLANNAD",
                        "alternative_titles": {
                            "results": [
                                {"title": "CLANNAD 〜AFTER STORY〜"},
                                {"title": "团子大家族"},
                            ]
                        },
                    },
                )
            return httpx.Response(404)

        service = CatalogService(transport=httpx.MockTransport(handler))
        metadata = {
            "stable_id": "bangumi:876",
            "provider": "bangumi",
            "media_type": "anime",
            "title": "CLANNAD 〜AFTER STORY〜",
            "original_title": "CLANNAD 〜AFTER STORY〜",
            "aliases": ["CLANNAD 〜AFTER STORY〜"],
        }
        try:
            with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"):
                first = await service.playback_aliases(metadata)
                second = await service.playback_aliases(metadata)
        finally:
            await service.aclose()

        self.assertEqual(first, ["CLANNAD 〜AFTER STORY〜"])
        self.assertEqual(second[0], "团子大家族")
        self.assertEqual(search_calls, 2)

    async def test_search_uses_stable_bangumi_and_tmdb_ids(self):
        def handler(request: httpx.Request):
            if request.url.path == "/v0/search/subjects":
                return httpx.Response(
                    200,
                    json={
                        "data": [
                            {
                                "id": 123,
                                "name": "Sousou no Frieren",
                                "name_cn": "葬送的芙莉莲",
                                "date": "2023-09-29",
                                "images": {"large": "https://img/bgm.jpg"},
                                "rating": {"score": 9.1, "total": 1000},
                                "tags": [{"name": "奇幻"}],
                                "eps": 28,
                            }
                        ]
                    },
                )
            if request.url.path in {"/3/search/tv", "/3/search/movie"}:
                media_id = 456 if request.url.path.endswith("tv") else 789
                key = "name" if request.url.path.endswith("tv") else "title"
                return httpx.Response(
                    200,
                    json={
                        "results": [
                            {
                                "id": media_id,
                                key: "测试剧集" if key == "name" else "测试电影",
                                "popularity": 10,
                            }
                        ]
                    },
                )
            return httpx.Response(404)

        service = CatalogService(transport=httpx.MockTransport(handler))
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        try:
            with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"):
                async with sessions() as session:
                    items = await service.search(
                        "测试", ["anime", "tv", "movie"], session
                    )
                self.assertEqual(
                    {item["stable_id"] for item in items},
                    {"bangumi:123", "tmdb:tv:456", "tmdb:movie:789"},
                )
                async with sessions() as session:
                    count = await session.scalar(select(func.count(CatalogSubject.id)))
                self.assertEqual(count, 3)
        finally:
            await service.aclose()
            await engine.dispose()

    async def test_lightweight_catalog_cache_is_enriched_for_detail(self):
        requests: list[str] = []

        def handler(request: httpx.Request):
            requests.append(request.url.path)
            if request.url.path == "/v0/subjects/123":
                return httpx.Response(
                    200,
                    json={
                        "id": 123,
                        "name": "Test Anime",
                        "name_cn": "测试动画",
                        "summary": "完整简介",
                        "eps": 2,
                        "tags": [{"name": "冒险"}],
                    },
                )
            if request.url.path == "/v0/episodes":
                return httpx.Response(
                    200,
                    json={
                        "data": [
                            {"sort": 1, "name_cn": "第一集"},
                            {"sort": 2, "name_cn": "第二集"},
                        ]
                    },
                )
            return httpx.Response(404)

        service = CatalogService(transport=httpx.MockTransport(handler))
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        try:
            lightweight = service._subject_from_bangumi(
                {"id": 123, "name": "Test Anime", "name_cn": "测试动画"}
            )
            self.assertIsNotNone(lightweight)
            self.assertNotIn("detail_complete", lightweight)
            async with sessions() as session:
                await service._persist_many(
                    SqlCatalogRepository(session),
                    [lightweight],
                )
            async with sessions() as session:
                first = await service.get_subject("bangumi:123", session)

            self.assertTrue(first["detail_complete"])
            self.assertEqual(first["summary"], "完整简介")
            self.assertEqual(len(first["episodes"]), 2)
            self.assertEqual(len(requests), 2)

            async with sessions() as session:
                second = await service.get_subject("bangumi:123", session)
            self.assertEqual(second, first)
            self.assertEqual(len(requests), 2)
        finally:
            await service.aclose()
            await engine.dispose()

    async def test_bangumi_ranked_home_fetches_at_most_two_pages(self):
        requests: list[tuple[int, int]] = []

        def handler(request: httpx.Request):
            offset = int(request.url.params["offset"])
            limit = int(request.url.params["limit"])
            requests.append((offset, limit))
            return httpx.Response(
                200,
                json={
                    "data": [
                        {
                            "id": offset + 1,
                            "name": f"Anime {offset + 1}",
                            "name_cn": f"动画 {offset + 1}",
                        }
                    ]
                },
            )

        service = CatalogService(transport=httpx.MockTransport(handler))
        try:
            items = await service._bangumi_ranked(240)
            self.assertEqual(requests, [(0, 100), (100, 100)])
            self.assertEqual(len(items), 2)
        finally:
            await service.aclose()

    async def test_tmdb_home_combines_multiple_rankings(self):
        requested_paths: set[str] = set()

        def handler(request: httpx.Request):
            requested_paths.add(request.url.path)
            media_id = {
                "/3/trending/tv/week": 10,
                "/3/tv/popular": 20,
                "/3/tv/top_rated": 30,
                "/3/tv/on_the_air": 40,
            }[request.url.path]
            return httpx.Response(
                200,
                json={
                    "results": [
                        {"id": media_id, "name": f"Series {media_id}"},
                        {"id": media_id + 1, "name": f"Series {media_id + 1}"},
                    ]
                },
            )

        service = CatalogService(transport=httpx.MockTransport(handler))
        try:
            items = await service._tmdb_home("tv", 6)
            self.assertEqual(len(items), 6)
            self.assertEqual(
                requested_paths,
                {
                    "/3/trending/tv/week",
                    "/3/tv/popular",
                    "/3/tv/top_rated",
                    "/3/tv/on_the_air",
                },
            )
        finally:
            await service.aclose()


class PlaybackServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        self.service = PlaybackService(session_factory=self.sessions)

    async def asyncTearDown(self):
        await self.service.aclose()
        await self.engine.dispose()

    async def test_search_timeout_is_not_reported_as_source_miss(self):
        class TimedOutProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                raise asyncio.TimeoutError

        metadata = {
            "stable_id": "bangumi:999001",
            "title": "超时诊断测试",
            "original_title": "Timeout Diagnostic Test",
            "aliases": ["超时诊断测试"],
            "media_type": "anime",
            "date": "2026-01-01",
        }
        with (
            patch.object(
                aggregator,
                "_crawler_scrapers",
                {"slow": TimedOutProvider()},
            ),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.slow"}),
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=["超时诊断测试"]),
            ),
        ):
            async with self.sessions() as session:
                items = await self.service.lines(
                    "bangumi:999001",
                    1,
                    session,
                )

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["source"], "crawler:slow")
        self.assertEqual(items[0]["status"], "unavailable")
        self.assertEqual(items[0]["diagnostic_status"], "search_timeout")
        self.assertTrue(items[0]["queried"])
        self.assertEqual(items[0]["aliases_attempted"], 1)
        self.assertEqual(items[0]["search_hit_count"], 0)
        self.assertEqual(items[0]["error_category"], "read_timeout")

    async def test_search_error_and_route_failure_remain_distinct(self):
        class SearchErrorProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                raise RuntimeError("provider unavailable")

        class RouteFailureProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                return [
                    SubjectResult(
                        source_id="work-1",
                        title="线路诊断测试",
                        type="anime",
                        year=2026,
                    )
                ]

            async def get_video_urls(self, _source_id: str, _episode: int):
                request = httpx.Request("GET", "https://media.test/episode")
                raise httpx.ReadTimeout("route timeout", request=request)

        class HitNoMatchProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                return [
                    SubjectResult(
                        source_id="other-work",
                        title="完全不同的作品",
                        type="anime",
                        year=1999,
                    )
                ]

        metadata = {
            "stable_id": "bangumi:999007",
            "title": "线路诊断测试",
            "original_title": "Route Diagnostic Test",
            "aliases": ["线路诊断测试"],
            "media_type": "anime",
            "date": "2026-01-01",
        }
        with (
            patch.object(
                aggregator,
                "_crawler_scrapers",
                {
                    "search_error": SearchErrorProvider(),
                    "route_failure": RouteFailureProvider(),
                    "hit_no_match": HitNoMatchProvider(),
                },
            ),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({
                    "crawler.search_error",
                    "crawler.route_failure",
                    "crawler.hit_no_match",
                }),
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=["线路诊断测试"]),
            ),
        ):
            async with self.sessions() as session:
                items = await self.service.lines(
                    "bangumi:999007",
                    1,
                    session,
                )

        by_source = {item["source_name"]: item for item in items}
        self.assertEqual(
            by_source["search_error"]["diagnostic_status"],
            "search_error",
        )
        self.assertEqual(
            by_source["search_error"]["message"],
            "来源暂时无法访问",
        )
        self.assertEqual(
            by_source["route_failure"]["diagnostic_status"],
            "route_unavailable",
        )
        self.assertTrue(by_source["route_failure"]["matched"])
        self.assertEqual(
            by_source["route_failure"]["message"],
            "已匹配作品，但当前线路验证失败",
        )
        self.assertEqual(
            by_source["hit_no_match"]["diagnostic_status"],
            "search_hit_no_match",
        )
        self.assertEqual(by_source["hit_no_match"]["search_hit_count"], 1)
        self.assertEqual(
            by_source["hit_no_match"]["message"],
            "搜索到候选，但没有可信作品匹配",
        )

    async def test_maccms_search_miss_and_timeout_remain_distinct(self):
        sites = [
            {
                "name": "空结果源",
                "api": "https://source.test/miss",
                "weight": 10,
            },
            {
                "name": "超时源",
                "api": "https://source.test/timeout",
                "weight": 9,
            },
        ]

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/timeout":
                raise httpx.ReadTimeout("timed out", request=request)
            return httpx.Response(200, json={"list": []})

        scraper = MacCmsScraper()
        await scraper._client.aclose()
        scraper._sites = sites
        scraper._client = httpx.AsyncClient(
            transport=httpx.MockTransport(handler),
            timeout=5,
        )
        metadata = {
            "stable_id": "bangumi:999002",
            "title": "站点诊断测试",
            "original_title": "Site Diagnostic Test",
            "aliases": ["站点诊断测试"],
            "media_type": "anime",
            "date": "2026-01-01",
        }
        try:
            with (
                patch.object(aggregator, "_maccms", scraper),
                patch.object(
                    aggregator,
                    "_enabled_provider_ids",
                    frozenset({"aggregate.maccms"}),
                ),
                patch(
                    "server.playback.catalog_service.get_subject",
                    new=AsyncMock(return_value=metadata),
                ),
                patch(
                    "server.playback.catalog_service.playback_aliases",
                    new=AsyncMock(return_value=["站点诊断测试"]),
                ),
            ):
                async with self.sessions() as session:
                    items = await self.service.lines(
                        "bangumi:999002",
                        1,
                        session,
                    )
        finally:
            await scraper.aclose()

        by_source = {item["source_name"]: item for item in items}
        self.assertEqual(by_source["空结果源"]["status"], "not_found")
        self.assertTrue(by_source["空结果源"]["queried"])
        self.assertEqual(by_source["超时源"]["status"], "unavailable")
        self.assertTrue(by_source["超时源"]["queried"])

    async def test_matched_work_without_current_episode_is_not_route_failure(self):
        class MissingEpisodeProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                return [
                    SubjectResult(
                        source_id="work-1",
                        title="缺集诊断测试",
                        type="anime",
                        year=2026,
                    )
                ]

            async def get_video_urls(self, _source_id: str, _episode: int):
                return []

        metadata = {
            "stable_id": "bangumi:999003",
            "title": "缺集诊断测试",
            "original_title": "Missing Episode Diagnostic Test",
            "aliases": ["缺集诊断测试"],
            "media_type": "anime",
            "date": "2026-01-01",
        }
        with (
            patch.object(
                aggregator,
                "_crawler_scrapers",
                {"missing_episode": MissingEpisodeProvider()},
            ),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.missing_episode"}),
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=["缺集诊断测试"]),
            ),
        ):
            async with self.sessions() as session:
                items = await self.service.lines(
                    "bangumi:999003",
                    7,
                    session,
                )

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["status"], "unavailable")
        self.assertEqual(
            items[0]["diagnostic_status"],
            "matched_no_episode",
        )
        self.assertTrue(items[0]["matched"])
        self.assertFalse(items[0]["episode_found"])
        self.assertEqual(
            items[0]["message"],
            "已匹配作品，但没有找到当前集",
        )

    async def test_open_source_circuit_is_reported_as_suppressed(self):
        class CircuitProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                return [
                    SubjectResult(
                        source_id="work-1",
                        title="熔断诊断测试特别版",
                        type="anime",
                        year=2026,
                    )
                ]

            async def get_video_urls(self, _source_id: str, _episode: int):
                raise AssertionError("open circuit must suppress route resolution")

        now = time.time()
        async with self.sessions() as session:
            session.add(SourceHealth(
                source_name="circuit",
                consecutive_failures=SOURCE_CIRCUIT_FAILURE_THRESHOLD,
                last_status=UNAVAILABLE,
                last_checked_at=now,
                last_failure_at=now,
            ))
            await session.commit()

        metadata = {
            "stable_id": "bangumi:999004",
            "title": "熔断诊断测试",
            "original_title": "Circuit Diagnostic Test",
            "aliases": ["熔断诊断测试"],
            "media_type": "anime",
            "date": "2026-01-01",
        }
        with (
            patch.object(
                aggregator,
                "_crawler_scrapers",
                {"circuit": CircuitProvider()},
            ),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.circuit"}),
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=["熔断诊断测试"]),
            ),
        ):
            async with self.sessions() as session:
                items = await self.service.lines(
                    "bangumi:999004",
                    1,
                    session,
                )

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["status"], "unavailable")
        self.assertEqual(
            items[0]["diagnostic_status"],
            "circuit_suppressed",
        )
        self.assertTrue(items[0]["queried"])
        self.assertTrue(items[0]["matched"])
        self.assertEqual(
            items[0]["message"],
            "来源近期连续失败，本轮暂缓请求",
        )

    async def test_bound_source_resolution_still_emits_episode_diagnostic(self):
        class BoundProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                raise AssertionError("fresh binding must skip discovery search")

            async def get_video_urls(self, _source_id: str, _episode: int):
                return []

        now = time.time()
        async with self.sessions() as session:
            session.add(SourceBinding(
                stable_id="bangumi:999005",
                source_id="crawler:bound:work-1",
                source_name="bound",
                matched_title="绑定诊断测试",
                media_type="anime",
                year=2026,
                score=118,
                enabled=True,
                updated_at=now,
            ))
            await session.commit()

        metadata = {
            "stable_id": "bangumi:999005",
            "title": "绑定诊断测试",
            "original_title": "Bound Diagnostic Test",
            "aliases": ["绑定诊断测试"],
            "media_type": "anime",
            "date": "2026-01-01",
        }
        with (
            patch.object(
                aggregator,
                "_crawler_scrapers",
                {"bound": BoundProvider()},
            ),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.bound"}),
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=["绑定诊断测试"]),
            ),
        ):
            async with self.sessions() as session:
                items = await self.service.lines(
                    "bangumi:999005",
                    3,
                    session,
                )

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["status"], "unavailable")
        self.assertEqual(
            items[0]["diagnostic_status"],
            "matched_no_episode",
        )
        self.assertFalse(items[0]["queried"])
        self.assertEqual(items[0]["aliases_attempted"], 0)
        self.assertTrue(items[0]["matched"])
        self.assertFalse(items[0]["episode_found"])

    async def test_missing_aliases_report_sources_as_not_queried(self):
        class PendingProvider:
            content_types = ["anime"]

            async def search(self, _keyword: str):
                raise AssertionError("missing aliases must not trigger search")

        with (
            patch.object(
                aggregator,
                "_crawler_scrapers",
                {"pending": PendingProvider()},
            ),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.pending"}),
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=None),
            ),
        ):
            async with self.sessions() as session:
                items = await self.service.lines(
                    "bangumi:999006",
                    1,
                    session,
                )

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["status"], "unavailable")
        self.assertEqual(items[0]["diagnostic_status"], "not_queried")
        self.assertFalse(items[0]["queried"])
        self.assertEqual(items[0]["message"], "本轮未查询该来源")

    async def test_stable_id_discovers_binds_and_caches_multiple_sites(self):
        matches = [
            SourceMatch(
                source_id="maccms:iKun:1",
                source_name="iKun",
                title="葬送的芙莉莲",
                content_type="anime",
                year=2023,
                score=110,
            ),
            SourceMatch(
                source_id="maccms:魔都:2",
                source_name="魔都",
                title="葬送的芙莉莲",
                content_type="anime",
                year=2023,
                score=108,
            ),
        ]
        lines = [
            AggregatedVideoLine(
                url="https://cdn.example/video.m3u8",
                title="线路1",
                format="hls",
                source="maccms:iKun",
                verification_status=SERVER_VERIFIED,
            )
        ]
        metadata = {
            "stable_id": "bangumi:123",
            "title": "葬送的芙莉莲",
            "original_title": "Sousou no Frieren",
            "aliases": ["芙莉莲"],
            "media_type": "anime",
            "date": "2023-09-29",
        }
        enabled_provider_ids = frozenset(
            item.provider_id for item in aggregator.provider_metadata
        )
        with (
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                enabled_provider_ids,
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.aggregator.discover_source_matches",
                new=AsyncMock(return_value=matches),
            ) as discover,
            patch(
                "server.playback.aggregator.resolve_source_matches",
                new=AsyncMock(return_value=(lines, {"iKun": True, "魔都": False})),
            ) as resolve,
        ):
            expected_inventory = aggregator.source_inventory
            expected_source_names = aggregator.configured_source_names
            async with self.sessions() as session:
                first = await self.service.lines("bangumi:123", 1, session)
            async with self.sessions() as session:
                second = await self.service.lines("bangumi:123", 1, session)

        self.assertFalse(first[0]["cached"])
        self.assertTrue(second[0]["cached"])
        self.assertEqual(len(first), len(expected_inventory))
        self.assertEqual(
            {item["source"].split(":", 1)[1] for item in first},
            expected_source_names,
        )
        self.assertIn("crawler:dm706", {item["source"] for item in first})
        self.assertEqual(sum(item["available"] for item in first), 1)
        first_by_source = {
            item["source"].split(":", 1)[1]: item
            for item in first
        }
        self.assertEqual(
            first_by_source["iKun"]["diagnostic_status"],
            "server_verified",
        )
        self.assertEqual(
            first_by_source["魔都"]["diagnostic_status"],
            "route_unavailable",
        )
        self.assertFalse(first_by_source["iKun"]["queried"])
        self.assertEqual(discover.await_count, 1)
        self.assertEqual(resolve.await_count, 1)
        async with self.sessions() as session:
            cache_count = await session.scalar(select(func.count(PlaybackCache.id)))
            binding_count = await session.scalar(select(func.count(SourceBinding.id)))
        self.assertEqual(cache_count, 1)
        self.assertEqual(binding_count, 2)

    async def test_playback_context_uses_catalog_crosswalk_alias_order(self):
        metadata = {
            "stable_id": "bangumi:876",
            "provider": "bangumi",
            "title": "CLANNAD 〜AFTER STORY〜",
            "original_title": "CLANNAD 〜AFTER STORY〜",
            "aliases": ["CLANNAD 〜AFTER STORY〜"],
            "media_type": "anime",
            "date": "2008-10-02",
        }
        localized = ["团子大家族", "CLANNAD 〜AFTER STORY〜"]
        with (
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=localized),
            ) as aliases,
        ):
            async with self.sessions() as session:
                title, content_type, year, result = (
                    await self.service._playback_context(
                        "bangumi:876",
                        session,
                        title="",
                        original_title="",
                        content_type="",
                        year=0,
                    )
                )

        self.assertEqual(title, "CLANNAD 〜AFTER STORY〜")
        self.assertEqual(content_type, "anime")
        self.assertEqual(year, 2008)
        self.assertEqual(result, localized)
        aliases.assert_awaited_once_with(metadata)

    async def test_partial_positive_cache_expires_before_stable_cache(self):
        now = time.time()
        async with self.sessions() as session:
            session.add_all(
                [
                    PlaybackCache(
                        subject_id="bangumi:partial",
                        episode=1,
                        title="Partial",
                        lines_json=(
                            '[{"url":"https://cdn.example/partial.m3u8",'
                            '"source":"maccms:iKun","available":true}]'
                        ),
                        line_count=1,
                        verified_at=now - 11 * 60,
                    ),
                    PlaybackCache(
                        subject_id="bangumi:stable",
                        episode=1,
                        title="Stable",
                        lines_json=(
                            '[{"url":"https://cdn.example/stable.m3u8",'
                            '"source":"maccms:iKun","available":true}]'
                        ),
                        line_count=4,
                        verified_at=now - 11 * 60,
                    ),
                ]
            )
            await session.commit()

        async with self.sessions() as session:
            partial = await self.service._cached_lines(
                session, "bangumi:partial", 1, force=False
            )
            stable = await self.service._cached_lines(
                session, "bangumi:stable", 1, force=False
            )

        self.assertIsNone(partial)
        self.assertIsNotNone(stable)

    def test_client_probe_candidate_keeps_url_headers_and_expiry(self):
        expires_at = int(time.time()) + 3600
        item = self.service._line_dict(
            AggregatedVideoLine(
                url=f"https://cdn.example/video.m3u8?expires={expires_at}",
                title="住宅网络候选",
                format="hls",
                source="crawler:dm706",
                headers={"Referer": "https://source.example/watch/1"},
                verification_status=CLIENT_PROBE_REQUIRED,
                startup_profile=STARTUP_HLS,
                startup_latency_ms=275,
            )
        )

        self.assertFalse(item["available"])
        self.assertEqual(item["status"], CLIENT_PROBE_REQUIRED)
        self.assertEqual(item["startup_profile"], STARTUP_HLS)
        self.assertEqual(item["startup_latency_ms"], 275)
        self.assertEqual(item["expires_at"], expires_at)
        self.assertEqual(
            item["headers"]["Referer"],
            "https://source.example/watch/1",
        )

    async def test_startup_profile_survives_database_cache_round_trip(self):
        item = self.service._line_dict(
            AggregatedVideoLine(
                url="https://cdn.example/video.mp4",
                title="Fast start",
                format="mp4",
                source="crawler:test",
                verification_status=SERVER_VERIFIED,
                startup_profile=STARTUP_MP4_FASTSTART,
                startup_latency_ms=143,
            )
        )
        async with self.sessions() as session:
            await self.service._store_cache(
                session,
                "bangumi:cache-profile",
                1,
                "Cache profile",
                [item],
            )
        async with self.sessions() as session:
            cache_state, cached = await self.service._cache_lookup(
                session,
                "bangumi:cache-profile",
                1,
            )

        self.assertEqual(cache_state, "fresh")
        self.assertEqual(cached[0]["startup_profile"], STARTUP_MP4_FASTSTART)
        self.assertEqual(cached[0]["startup_latency_ms"], 143)

    async def test_client_probe_route_is_not_stored_as_a_negative_cache(self):
        item = self.service._line_dict(
            AggregatedVideoLine(
                url="https://cdn.example/client-probe.m3u8",
                title="Client probe",
                format="hls",
                source="maccms:client-probe",
                verification_status=CLIENT_PROBE_REQUIRED,
            )
        )
        async with self.sessions() as session:
            await self.service._store_cache(
                session,
                "bangumi:client-probe-cache",
                1,
                "Client probe",
                [item],
            )
        async with self.sessions() as session:
            cached = await session.scalar(
                select(PlaybackCache).where(
                    PlaybackCache.subject_id == "bangumi:client-probe-cache",
                    PlaybackCache.episode == 1,
                )
            )

        self.assertIsNotNone(cached)
        self.assertEqual(cached.line_count, 1)

    async def test_full_transient_failure_does_not_create_negative_cache(self):
        diagnostic = SourceDiscoveryDiagnostic(
            source_name="slow",
            provider_id="crawler.slow",
            queried=True,
            aliases_attempted=1,
            status=SourceDiscoveryStatus.SEARCH_TIMEOUT,
            error_category=READ_TIMEOUT,
        )
        with (
            patch.object(
                self.service,
                "_playback_context",
                new=AsyncMock(
                    return_value=("Transient", "anime", 2026, ["Transient"])
                ),
            ),
            patch.object(
                self.service,
                "_load_source_health",
                new=AsyncMock(return_value={}),
            ),
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=[]),
            ),
            patch.object(aggregator, "_crawler_scrapers", {"slow": object()}),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.slow"}),
            ),
            patch.object(
                aggregator,
                "discover_source_matches",
                new=AsyncMock(return_value=([], {"slow": diagnostic})),
            ),
            patch.object(
                aggregator,
                "resolve_source_matches",
                new=AsyncMock(return_value=([], {}, {})),
            ),
        ):
            async with self.sessions() as session:
                await self.service._refresh(
                    "bangumi:991005",
                    1,
                    session,
                    title="Transient",
                    original_title="",
                    content_type="anime",
                    year=2026,
                )
        async with self.sessions() as session:
            cached = await session.scalar(
                select(PlaybackCache).where(
                    PlaybackCache.subject_id == "bangumi:991005",
                    PlaybackCache.episode == 1,
                )
            )

        self.assertIsNone(cached)

    async def test_full_confirmed_miss_keeps_bounded_negative_cache(self):
        diagnostics = {
            name: SourceDiscoveryDiagnostic(
                source_name=name,
                provider_id=f"crawler.{name}",
                queried=True,
                aliases_attempted=1,
                status=SourceDiscoveryStatus.SEARCH_MISS,
            )
            for name in ("one", "two")
        }
        with (
            patch.object(
                self.service,
                "_playback_context",
                new=AsyncMock(
                    return_value=("Confirmed", "anime", 2026, ["Confirmed"])
                ),
            ),
            patch.object(
                self.service,
                "_load_source_health",
                new=AsyncMock(return_value={}),
            ),
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=[]),
            ),
            patch.object(
                aggregator,
                "_crawler_scrapers",
                {"one": object(), "two": object()},
            ),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.one", "crawler.two"}),
            ),
            patch.object(
                aggregator,
                "discover_source_matches",
                new=AsyncMock(return_value=([], diagnostics)),
            ),
            patch.object(
                aggregator,
                "resolve_source_matches",
                new=AsyncMock(return_value=([], {}, {})),
            ),
        ):
            async with self.sessions() as session:
                await self.service._refresh(
                    "bangumi:991006",
                    1,
                    session,
                    title="Confirmed",
                    original_title="",
                    content_type="anime",
                    year=2026,
                )
        async with self.sessions() as session:
            cached = await session.scalar(
                select(PlaybackCache).where(
                    PlaybackCache.subject_id == "bangumi:991006",
                    PlaybackCache.episode == 1,
                )
            )

        self.assertIsNotNone(cached)
        self.assertEqual(cached.line_count, 0)

    def test_only_deterministic_route_failures_confirm_a_full_negative(self):
        deterministic = {
            "queried": True,
            "diagnostic_status": SourceDiscoveryStatus.ROUTE_UNAVAILABLE.value,
            "error_category": EMPTY_MEDIA,
        }
        transient = {**deterministic, "error_category": READ_TIMEOUT}

        self.assertTrue(
            self.service._full_negative_cache_is_confirmed([deterministic])
        )
        self.assertFalse(
            self.service._full_negative_cache_is_confirmed([transient])
        )

    async def test_cache_drops_player_pages_and_unverified_opaque_urls(self):
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:cache-hygiene",
                    episode=1,
                    title="Cache hygiene",
                    lines_json=json.dumps([
                        {
                            "url": "https://source.example/player.html?url=video",
                            "format": "hls",
                            "available": True,
                            "status": SERVER_VERIFIED,
                        },
                        {
                            "url": "https://cdn.example/media/opaque-token",
                            "format": "auto",
                            "available": False,
                            "status": CLIENT_PROBE_REQUIRED,
                        },
                        {
                            "url": "https://cdn.example/media/verified-token",
                            "format": "auto",
                            "available": True,
                            "status": SERVER_VERIFIED,
                        },
                    ]),
                    line_count=2,
                    verified_at=time.time(),
                )
            )
            await session.commit()

        async with self.sessions() as session:
            cache_state, cached = await self.service._cache_lookup(
                session,
                "bangumi:cache-hygiene",
                1,
            )

        self.assertEqual(cache_state, "fresh")
        self.assertEqual(
            [item.get("url") for item in cached if item.get("url")],
            ["https://cdn.example/media/verified-token"],
        )

    def test_playable_statistics_ignore_placeholder_only_inventory(self):
        placeholders = [
            {
                "source": "crawler:dm706",
                "available": False,
                "status": "not_found",
                "message": "当前站点没有匹配到这部作品",
            },
            {
                "source": "maccms:iKun",
                "available": False,
                "status": "unavailable",
            },
        ]
        self.assertFalse(self.service._has_playable_line(placeholders))
        self.assertFalse(
            self.service._has_playable_line(
                [{"available": True, "url": ""}],
            )
        )
        self.assertTrue(
            self.service._has_playable_line(
                [{"available": True, "url": "https://cdn.example/video.m3u8"}],
            )
        )

    async def test_expired_signed_candidate_is_removed_from_cache(self):
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:expired",
                    episode=1,
                    title="Expired",
                    lines_json=(
                        '[{"url":"https://cdn.example/old.m3u8",'
                        '"source":"crawler:dm706","available":false,'
                        f'"status":"{CLIENT_PROBE_REQUIRED}",'
                        f'"expires_at":{int(time.time()) - 60}}}]'
                    ),
                    line_count=0,
                    verified_at=time.time(),
                )
            )
            await session.commit()

        async with self.sessions() as session:
            items = await self.service._cached_lines(
                session, "bangumi:expired", 1, force=False
            )

        self.assertIsNotNone(items)
        self.assertFalse(any(item.get("url") for item in items))

    async def test_stale_positive_cache_returns_before_single_flight_refresh(self):
        now = time.time()
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:991",
                    episode=1,
                    title="Stale",
                    lines_json=(
                        '[{"url":"https://cdn.example/stale.m3u8",'
                        '"source":"maccms:iKun","available":true,'
                        f'"status":"{SERVER_VERIFIED}","expires_at":0}}]'
                    ),
                    line_count=1,
                    verified_at=now - 11 * 60,
                )
            )
            await session.commit()

        started = asyncio.Event()
        release = asyncio.Event()
        refresh_calls = 0

        async def slow_refresh(*_args, **_kwargs):
            nonlocal refresh_calls
            refresh_calls += 1
            started.set()
            await release.wait()
            return [{"url": "https://cdn.example/fresh.m3u8", "available": True}]

        with patch.object(self.service, "_refresh", new=slow_refresh):
            async with self.sessions() as session:
                first = await self.service.lines("bangumi:991", 1, session)
            await asyncio.wait_for(started.wait(), timeout=1)
            async with self.sessions() as session:
                second = await self.service.lines("bangumi:991", 1, session)

            self.assertTrue(first[0]["stale"])
            self.assertTrue(second[0]["stale"])
            self.assertEqual(refresh_calls, 1)
            self.assertEqual(len(self.service._refresh_tasks), 1)
            release.set()
            await asyncio.gather(*self.service._refresh_tasks.values())

        self.assertEqual(self.service.cache_metrics["stale_hit"], 2)
        self.assertEqual(self.service.cache_metrics["refresh_success"], 1)

    async def test_concurrent_cache_misses_share_one_server_refresh(self):
        started = asyncio.Event()
        release = asyncio.Event()
        refresh_calls = 0

        async def slow_refresh(*_args, **_kwargs):
            nonlocal refresh_calls
            refresh_calls += 1
            started.set()
            await release.wait()
            return [{"url": "https://cdn.example/ready.m3u8", "available": True}]

        async def lookup():
            async with self.sessions() as session:
                return await self.service.lines("bangumi:992", 1, session)

        with patch.object(self.service, "_refresh", new=slow_refresh):
            first = asyncio.create_task(lookup())
            second = asyncio.create_task(lookup())
            await asyncio.wait_for(started.wait(), timeout=1)
            release.set()
            results = await asyncio.gather(first, second)

        self.assertEqual(refresh_calls, 1)
        self.assertEqual(results[0], results[1])

    async def test_quick_miss_does_not_block_immediate_full_refresh(self):
        async def discover_none(*_args, **_kwargs):
            if False:
                yield None

        with (
            patch.object(
                self.service,
                "_playback_context",
                new=AsyncMock(
                    return_value=("Quick Miss", "anime", 2026, ["Quick Miss"])
                ),
            ),
            patch.object(
                self.service,
                "_load_source_health",
                new=AsyncMock(return_value={}),
            ),
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=[]),
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover_none,
            ),
        ):
            async with self.sessions() as session:
                quick = await self.service._refresh_quick(
                    "bangumi:991004",
                    1,
                    session,
                    title="Quick Miss",
                    original_title="",
                    content_type="anime",
                    year=2026,
                    deadline=time.monotonic() + 1,
                )

        self.assertEqual(quick, [])
        expected = [
            {
                "url": "https://cdn-a.example/full.m3u8",
                "available": True,
            },
            {
                "url": "https://cdn-b.example/full.m3u8",
                "available": True,
            },
        ]
        full_refresh = AsyncMock(return_value=expected)
        with patch.object(self.service, "_refresh", new=full_refresh):
            async with self.sessions() as session:
                full = await self.service.lines(
                    "bangumi:991004",
                    1,
                    session,
                    title="Quick Miss",
                    content_type="anime",
                    year=2026,
                )

        self.assertEqual(full, expected)
        full_refresh.assert_awaited_once()
        async with self.sessions() as session:
            cached = await session.scalar(
                select(PlaybackCache).where(
                    PlaybackCache.subject_id == "bangumi:991004",
                    PlaybackCache.episode == 1,
                )
            )
        self.assertIsNone(cached)

    async def test_quick_cold_lookup_races_sources_and_returns_fastest(self):
        slow_match = SourceMatch(
            source_id="maccms:slow:1",
            source_name="slow",
            title="Slow Anime",
            content_type="anime",
            year=2024,
            score=100,
        )
        fast_match = SourceMatch(
            source_id="maccms:fast:1",
            source_name="fast",
            title="Fast Anime",
            content_type="anime",
            year=2024,
            score=99,
        )
        fast_lines = [
            AggregatedVideoLine(
                url=f"https://fast-cdn-{index}.example/video.m3u8",
                title=f"Fast route {index}",
                format="hls",
                source="maccms:fast",
                verification_status=CLIENT_PROBE_REQUIRED,
            )
            for index in range(3)
        ]
        slow_cancelled = asyncio.Event()
        resolve_verify_values = []

        async def discover(*_args, **_kwargs):
            yield slow_match
            yield fast_match

        async def resolve(matches, **_kwargs):
            resolve_verify_values.append(_kwargs.get("verify"))
            if matches[0] is slow_match:
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    slow_cancelled.set()
                    raise
            yield fast_match, fast_lines, CLIENT_PROBE_REQUIRED

        with (
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value={
                    "title": "测试动画",
                    "original_title": "Test Anime",
                    "aliases": [],
                    "media_type": "anime",
                    "date": "2024-01-01",
                }),
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover,
            ),
            patch.object(
                aggregator,
                "resolve_source_matches_progressively",
                new=resolve,
            ),
        ):
            async with self.sessions() as session:
                items = await self.service._refresh_quick(
                    "bangumi:quick",
                    1,
                    session,
                    title="Test Anime",
                    original_title="",
                    content_type="anime",
                    year=2024,
                )

        self.assertEqual(resolve_verify_values, [False, False])
        self.assertEqual(len(items), 3)
        self.assertEqual(
            [item["url"] for item in items],
            [line.url for line in fast_lines],
        )
        self.assertTrue(all(item["quick"] for item in items))
        self.assertTrue(slow_cancelled.is_set())

    async def test_quick_discovery_reuses_slots_until_seventh_candidate_succeeds(self):
        matches = [
            SourceMatch(
                source_id=f"maccms:site-{index}:{index}",
                source_name=f"site-{index}",
                title="Slot Anime",
                content_type="anime",
                year=2025,
                score=100 - index,
            )
            for index in range(7)
        ]
        valid_lines = [
            AggregatedVideoLine(
                url=f"https://slot-{index}.example/video.m3u8",
                title=f"Route {index}",
                format="hls",
                source="maccms:site-6",
                verification_status=CLIENT_PROBE_REQUIRED,
            )
            for index in range(3)
        ]
        first_wave_full = asyncio.Event()
        attempts: list[int] = []
        active = 0
        max_active = 0

        async def discover(*_args, **_kwargs):
            for match in matches:
                yield match

        async def resolve(candidates, **_kwargs):
            nonlocal active, max_active
            match = candidates[0]
            index = int(match.source_name.rsplit("-", 1)[1])
            attempts.append(index)
            active += 1
            max_active = max(max_active, active)
            try:
                if index < 6:
                    if active == 6:
                        first_wave_full.set()
                    await first_wave_full.wait()
                    await asyncio.sleep(0)
                    yield SourceResolutionOutcome(
                        match=match,
                        lines=[],
                        status=UNAVAILABLE,
                        error_category="empty_media",
                    )
                else:
                    yield SourceResolutionOutcome(
                        match=match,
                        lines=valid_lines,
                        status=CLIENT_PROBE_REQUIRED,
                    )
            finally:
                active -= 1

        with (
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=[]),
            ),
            patch.object(
                self.service,
                "_store_bindings",
                new=AsyncMock(),
            ),
            patch.object(
                self.service,
                "_record_health",
                new=AsyncMock(),
            ),
            patch.object(
                self.service,
                "_store_cache",
                new=AsyncMock(),
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover,
            ),
            patch.object(
                aggregator,
                "resolve_source_matches_progressively",
                new=resolve,
            ),
        ):
            async with self.sessions() as session:
                items = await self.service._refresh_quick(
                    "bangumi:slot",
                    1,
                    session,
                    title="Slot Anime",
                    original_title="",
                    content_type="anime",
                    year=2025,
                )

        self.assertEqual(attempts, list(range(7)))
        self.assertLessEqual(max_active, 6)
        self.assertEqual(
            {urlparse(item["url"]).hostname for item in items},
            {"slot-0.example", "slot-1.example", "slot-2.example"},
        )

    async def test_quick_hundred_candidates_cancel_after_playable_target(self):
        matches = [
            SourceMatch(
                source_id=f"maccms:bulk-{index}:{index}",
                source_name=f"bulk-{index}",
                title="Bulk Anime",
                content_type="anime",
                year=2025,
                score=200 - index,
            )
            for index in range(100)
        ]
        valid_lines = [
            AggregatedVideoLine(
                url=f"https://bulk-host-{index}.example/video.m3u8",
                title=f"Bulk route {index}",
                format="hls",
                source="maccms:bulk-20",
                verification_status=CLIENT_PROBE_REQUIRED,
            )
            for index in range(3)
        ]
        attempts: list[int] = []
        active = 0
        max_active = 0
        cancelled = 0

        async def discover(*_args, **_kwargs):
            for match in matches:
                yield match

        async def resolve(candidates, **_kwargs):
            nonlocal active, max_active, cancelled
            match = candidates[0]
            index = int(match.source_name.rsplit("-", 1)[1])
            attempts.append(index)
            active += 1
            max_active = max(max_active, active)
            try:
                if index < 20:
                    await asyncio.sleep(0)
                    yield SourceResolutionOutcome(
                        match=match,
                        lines=[],
                        status=UNAVAILABLE,
                        error_category="empty_media",
                    )
                elif index == 20:
                    await asyncio.sleep(0.005)
                    yield SourceResolutionOutcome(
                        match=match,
                        lines=valid_lines,
                        status=CLIENT_PROBE_REQUIRED,
                    )
                else:
                    try:
                        await asyncio.Event().wait()
                    except asyncio.CancelledError:
                        cancelled += 1
                        raise
            finally:
                active -= 1

        with (
            patch.object(
                self.service,
                "_playback_context",
                new=AsyncMock(return_value=(
                    "Bulk Anime",
                    "anime",
                    2025,
                    ["Bulk Anime"],
                )),
            ),
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=[]),
            ),
            patch.object(
                self.service,
                "_store_bindings",
                new=AsyncMock(),
            ),
            patch.object(
                self.service,
                "_record_health",
                new=AsyncMock(),
            ),
            patch.object(
                self.service,
                "_store_cache",
                new=AsyncMock(),
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover,
            ),
            patch.object(
                aggregator,
                "resolve_source_matches_progressively",
                new=resolve,
            ),
        ):
            async with self.sessions() as session:
                items = await self.service._refresh_quick(
                    "bangumi:bulk",
                    1,
                    session,
                    title="Bulk Anime",
                    original_title="",
                    content_type="anime",
                    year=2025,
                )

        self.assertIn(20, attempts)
        self.assertLess(len(attempts), 100)
        self.assertLessEqual(max_active, 6)
        self.assertEqual(active, 0)
        self.assertGreaterEqual(cancelled, 1)
        self.assertEqual(len(items), 3)

    async def test_quick_refresh_uses_catalog_aliases_when_request_has_title(self):
        metadata = {
            "stable_id": "bangumi:aliases",
            "title": "Original Anime",
            "original_title": "Original Anime",
            "aliases": ["Localized Anime", "Original Anime"],
            "media_type": "anime",
            "date": "2025-01-01",
        }
        expected_aliases = [
            "Localized Anime 第二季",
            "Localized Anime Season 2",
            "Original Anime",
        ]
        received_aliases: list[str] = []

        async def discover(aliases, **_kwargs):
            received_aliases.extend(aliases)
            if False:
                yield None

        with (
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=expected_aliases),
            ) as playback_aliases,
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=[]),
            ),
            patch.object(
                self.service,
                "_store_cache",
                new=AsyncMock(),
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover,
            ),
        ):
            async with self.sessions() as session:
                await self.service._refresh_quick(
                    "bangumi:aliases",
                    1,
                    session,
                    title="Original Anime",
                    original_title="",
                    content_type="anime",
                    year=2025,
                )

        self.assertEqual(received_aliases, expected_aliases)
        playback_aliases.assert_awaited_once_with(metadata)

    async def test_quick_deadline_returns_accumulated_lines_and_cleans_tasks(self):
        match = SourceMatch(
            source_id="maccms:deadline:1",
            source_name="deadline",
            title="Deadline Anime",
            content_type="anime",
            year=2025,
            score=100,
        )
        line = AggregatedVideoLine(
            url="https://deadline.example/video.m3u8",
            title="Deadline route",
            format="hls",
            source="maccms:deadline",
            verification_status=CLIENT_PROBE_REQUIRED,
        )
        discovery_closed = asyncio.Event()

        async def discover(*_args, **_kwargs):
            try:
                yield match
                await asyncio.Event().wait()
            finally:
                discovery_closed.set()

        async def resolve(candidates, **_kwargs):
            yield SourceResolutionOutcome(
                match=candidates[0],
                lines=[line],
                status=CLIENT_PROBE_REQUIRED,
            )

        metadata = {
            "stable_id": "bangumi:deadline",
            "title": "Deadline Anime",
            "original_title": "Deadline Anime",
            "aliases": ["Deadline Anime"],
            "media_type": "anime",
            "date": "2025-01-01",
        }
        with (
            patch("server.playback.PLAYBACK_QUICK_TIMEOUT_SECONDS", 0.08),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=["Deadline Anime"]),
            ),
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=[]),
            ),
            patch.object(
                self.service,
                "_store_bindings",
                new=AsyncMock(),
            ),
            patch.object(
                self.service,
                "_record_health",
                new=AsyncMock(),
            ),
            patch.object(
                self.service,
                "_store_cache",
                new=AsyncMock(),
            ),
            patch.object(
                self.service,
                "_start_full_refresh",
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover,
            ),
            patch.object(
                aggregator,
                "resolve_source_matches_progressively",
                new=resolve,
            ),
        ):
            items = await self.service._run_quick_refresh(
                "bangumi:deadline",
                1,
                title="Deadline Anime",
                original_title="",
                content_type="anime",
                year=2025,
            )

        self.assertEqual(
            [item["url"] for item in items],
            ["https://deadline.example/video.m3u8"],
        )
        self.assertTrue(discovery_closed.is_set())

    async def test_quick_existing_bindings_collect_immediate_backup_hosts(self):
        matches = [
            SourceMatch(
                source_id=f"maccms:site-{index}:1",
                source_name=f"site-{index}",
                title="Bound Anime",
                content_type="anime",
                year=2024,
                score=100 - index,
            )
            for index in range(3)
        ]
        generators_closed: set[int] = set()

        def result(index: int):
            line = AggregatedVideoLine(
                url=f"https://cdn-{index}.example/video.m3u8",
                title=f"Route {index}",
                format="hls",
                source=f"maccms:site-{index}",
                verification_status=CLIENT_PROBE_REQUIRED,
            )
            return matches[index], [line], CLIENT_PROBE_REQUIRED

        async def resolve(candidates, **_kwargs):
            index = matches.index(candidates[0])
            try:
                await asyncio.sleep(index * 0.02)
                if index < 2:
                    yield result(index)
                else:
                    yield SourceResolutionOutcome(
                        match=matches[index],
                        lines=[],
                        status=UNAVAILABLE,
                        error_category="empty_media",
                    )
            finally:
                generators_closed.add(index)

        async def discover_none(*_args, **_kwargs):
            if False:
                yield None

        with (
            patch.object(
                self.service,
                "_load_bindings",
                new=AsyncMock(return_value=matches),
            ),
            patch.object(
                aggregator,
                "resolve_source_matches_progressively",
                new=resolve,
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover_none,
            ),
        ):
            started = time.monotonic()
            async with self.sessions() as session:
                items = await self.service._refresh_quick(
                    "bangumi:bound",
                    1,
                    session,
                    title="Bound Anime",
                    original_title="",
                    content_type="anime",
                    year=2024,
                )
            elapsed = time.monotonic() - started

        self.assertEqual(
            [urlparse(item["url"]).hostname for item in items],
            ["cdn-0.example", "cdn-1.example"],
        )
        self.assertLess(elapsed, 1.0)
        self.assertEqual(generators_closed, {0, 1, 2})

    async def test_recent_source_failures_open_then_half_open_and_recover(self):
        now = 1_800_000_000.0
        binding = SourceBinding(
            stable_id="bangumi:circuit",
            source_id="maccms:circuit:1",
            source_name="circuit",
            matched_title="Circuit Anime",
            media_type="anime",
            year=2024,
            score=100,
            enabled=True,
            updated_at=now,
        )
        async with self.sessions() as session:
            session.add(binding)
            await session.commit()

        with patch("server.playback.time.time", return_value=now):
            for _ in range(SOURCE_CIRCUIT_FAILURE_THRESHOLD):
                async with self.sessions() as session:
                    await self.service._record_health(
                        session,
                        "bangumi:circuit",
                        {"circuit": "unavailable"},
                    )
            async with self.sessions() as session:
                self.assertEqual(
                    await self.service._load_bindings(
                        session,
                        "bangumi:circuit",
                    ),
                    [],
                )
                stored_binding = await session.scalar(select(SourceBinding))
                stored_health = await session.scalar(select(SourceHealth))
                self.assertTrue(stored_binding.enabled)
                self.assertEqual(
                    stored_health.consecutive_failures,
                    SOURCE_CIRCUIT_FAILURE_THRESHOLD,
                )
                self.assertFalse(self.service._discovered_match_can_probe(
                    SourceMatch(
                        source_id="crawler:circuit:partial",
                        source_name="circuit",
                        title="Circuit",
                        content_type="anime",
                        year=2024,
                        score=107,
                    ),
                    stored_health,
                    now,
                ))

        cooldown = self.service._source_circuit_cooldown_seconds(
            SOURCE_CIRCUIT_FAILURE_THRESHOLD
        )
        recovered_at = now + cooldown + 1
        with patch("server.playback.time.time", return_value=recovered_at):
            async with self.sessions() as session:
                half_open = await self.service._load_bindings(
                    session,
                    "bangumi:circuit",
                )
                self.assertEqual([item.source_name for item in half_open], ["circuit"])
                await self.service._record_health(
                    session,
                    "bangumi:circuit",
                    {"circuit": SERVER_VERIFIED},
                )
            async with self.sessions() as session:
                healthy = await self.service._load_bindings(
                    session,
                    "bangumi:circuit",
                )
                stored_health = await session.scalar(select(SourceHealth))
                self.assertEqual([item.source_name for item in healthy], ["circuit"])
                self.assertEqual(stored_health.consecutive_failures, 0)
                self.assertEqual(stored_health.last_status, "healthy")

    async def test_exact_new_match_can_recover_open_source_in_full_refresh(self):
        now = 1_800_000_000.0
        match = SourceMatch(
            source_id="crawler:girigiri:4086",
            source_name="girigiri",
            title="团子大家族 第二季",
            content_type="anime",
            year=0,
            score=108,
        )
        line = AggregatedVideoLine(
            url="https://cdn.example/clannad-after-story.mp4",
            title="团子大家族 第二季",
            format="mp4",
            source="crawler:girigiri",
            verification_status=SERVER_VERIFIED,
        )
        metadata = {
            "stable_id": "bangumi:876",
            "title": "CLANNAD 〜AFTER STORY〜",
            "original_title": "CLANNAD 〜AFTER STORY〜",
            "aliases": ["CLANNAD 〜AFTER STORY〜"],
            "media_type": "anime",
            "date": "2008-10-02",
        }
        async with self.sessions() as session:
            session.add(SourceHealth(
                source_name="girigiri",
                failure_count=266,
                consecutive_failures=266,
                last_status="unhealthy",
                last_error_category="empty_media",
                last_checked_at=now,
                last_failure_at=now,
                recent_success_rate=0.0,
            ))
            await session.commit()

        async def resolve(candidates, **_kwargs):
            if not candidates:
                return [], {}, {}
            return [line], {"girigiri": SERVER_VERIFIED}, {}

        with (
            patch("server.playback.time.time", return_value=now),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.girigiri"}),
            ),
            patch(
                "server.playback.catalog_service.get_subject",
                new=AsyncMock(return_value=metadata),
            ),
            patch(
                "server.playback.catalog_service.playback_aliases",
                new=AsyncMock(return_value=[
                    "团子大家族 第二季",
                    "CLANNAD 〜AFTER STORY〜",
                ]),
            ),
            patch.object(
                aggregator,
                "discover_source_matches",
                new=AsyncMock(return_value=[match]),
            ),
            patch.object(
                aggregator,
                "resolve_source_matches",
                new=AsyncMock(side_effect=resolve),
            ) as resolver,
        ):
            async with self.sessions() as session:
                items = await self.service.lines("bangumi:876", 1, session)

        self.assertEqual(
            [item["url"] for item in items if item.get("available")],
            ["https://cdn.example/clannad-after-story.mp4"],
        )
        self.assertEqual(resolver.await_args.args[0], [match])

    async def test_exact_new_match_can_recover_open_source_in_quick_refresh(self):
        now = 1_800_000_000.0
        match = SourceMatch(
            source_id="crawler:girigiri:4086",
            source_name="girigiri",
            title="团子大家族 第二季",
            content_type="anime",
            year=0,
            score=108,
        )
        line = AggregatedVideoLine(
            url="https://cdn.example/clannad-after-story.mp4",
            title="团子大家族 第二季",
            format="mp4",
            source="crawler:girigiri",
            verification_status=SERVER_VERIFIED,
        )
        async with self.sessions() as session:
            session.add(SourceHealth(
                source_name="girigiri",
                failure_count=266,
                consecutive_failures=266,
                last_status="unhealthy",
                last_error_category="empty_media",
                last_checked_at=now,
                last_failure_at=now,
                recent_success_rate=0.0,
            ))
            await session.commit()

        async def discover(*_args, **_kwargs):
            yield match

        async def resolve(candidates, **_kwargs):
            self.assertEqual(candidates, [match])
            yield match, [line], SERVER_VERIFIED

        with (
            patch("server.playback.time.time", return_value=now),
            patch.object(
                aggregator,
                "_enabled_provider_ids",
                frozenset({"crawler.girigiri"}),
            ),
            patch.object(
                aggregator,
                "discover_source_matches_progressively",
                new=discover,
            ),
            patch.object(
                aggregator,
                "resolve_source_matches_progressively",
                new=resolve,
            ),
        ):
            async with self.sessions() as session:
                items = await self.service._refresh_quick(
                    "bangumi:876",
                    1,
                    session,
                    title="团子大家族 第二季",
                    original_title="CLANNAD 〜AFTER STORY〜",
                    content_type="anime",
                    year=2008,
                )

        self.assertEqual(
            [item["url"] for item in items if item.get("url")],
            ["https://cdn.example/clannad-after-story.mp4"],
        )

    async def test_client_probe_candidate_never_opens_source_circuit(self):
        now = 1_800_000_000.0
        async with self.sessions() as session:
            session.add(SourceBinding(
                stable_id="bangumi:client-candidate",
                source_id="maccms:client-candidate:1",
                source_name="client-candidate",
                matched_title="Client Candidate",
                media_type="anime",
                year=2024,
                score=100,
                enabled=True,
                updated_at=now,
            ))
            await session.commit()

        with patch("server.playback.time.time", return_value=now):
            async with self.sessions() as session:
                await self.service._record_health(
                    session,
                    "bangumi:client-candidate",
                    {"client-candidate": CLIENT_PROBE_REQUIRED},
                    diagnostics={
                        "client-candidate": SourceResolutionOutcome(
                            match=SourceMatch(
                                source_id="maccms:client-candidate:1",
                                source_name="client-candidate",
                                title="Client Candidate",
                                content_type="anime",
                                year=2024,
                            ),
                            lines=[],
                            status=CLIENT_PROBE_REQUIRED,
                            error_category=SERVER_BLOCKED_CLIENT_CANDIDATE,
                            latency_ms=800,
                        )
                    },
                )
            async with self.sessions() as session:
                matches = await self.service._load_bindings(
                    session,
                    "bangumi:client-candidate",
                )
                health = await session.scalar(select(SourceHealth))

        self.assertEqual([item.source_name for item in matches], ["client-candidate"])
        self.assertEqual(health.consecutive_failures, 0)
        self.assertEqual(health.last_status, CLIENT_PROBE_REQUIRED)
        self.assertEqual(
            health.last_error_category,
            SERVER_BLOCKED_CLIENT_CANDIDATE,
        )
        self.assertEqual(health.latency_ms, 800)

    async def test_deterministic_failure_updates_recent_health_and_latency(self):
        match = SourceMatch(
            source_id="maccms:broken:1",
            source_name="broken",
            title="Broken Anime",
            content_type="anime",
            year=2024,
        )
        diagnostic = SourceResolutionOutcome(
            match=match,
            lines=[],
            status=UNAVAILABLE,
            error_category=PARSER_MISMATCH,
            latency_ms=1200,
        )

        async with self.sessions() as session:
            await self.service._record_health(
                session,
                "bangumi:broken",
                {"broken": UNAVAILABLE},
                diagnostics={"broken": diagnostic},
            )
        async with self.sessions() as session:
            health = await session.scalar(select(SourceHealth))

        self.assertEqual(health.consecutive_failures, 2)
        self.assertEqual(health.last_error_category, PARSER_MISMATCH)
        self.assertEqual(health.latency_ms, 1200)
        self.assertAlmostEqual(health.recent_success_rate, 0.325)
        self.assertGreater(health.last_failure_at, 0)

    def test_source_rank_prefers_recent_fast_source_over_lifetime_counts(self):
        slow_binding = SourceBinding(
            stable_id="bangumi:rank",
            source_id="maccms:slow:1",
            source_name="slow",
            score=105,
            success_count=500,
            failure_count=0,
            last_success_at=1,
            last_failure_at=0,
        )
        fast_binding = SourceBinding(
            stable_id="bangumi:rank",
            source_id="maccms:fast:1",
            source_name="fast",
            score=100,
            success_count=2,
            failure_count=1,
            last_success_at=2,
            last_failure_at=1,
        )
        slow_health = SourceHealth(
            source_name="slow",
            consecutive_failures=2,
            last_status="unhealthy",
            last_error_category=PARSER_MISMATCH,
            latency_ms=9000,
            recent_success_rate=0.1,
        )
        fast_health = SourceHealth(
            source_name="fast",
            consecutive_failures=0,
            last_status="healthy",
            last_error_category="",
            latency_ms=350,
            recent_success_rate=0.95,
        )

        self.assertGreater(
            self.service._source_binding_rank(fast_binding, fast_health),
            self.service._source_binding_rank(slow_binding, slow_health),
        )

    async def test_quick_refresh_is_not_blocked_by_full_refresh_capacity(self):
        expected = [{"url": "https://cdn.example/quick.m3u8"}]
        self.service._refresh_semaphore = asyncio.Semaphore(0)

        with (
            patch.object(
                self.service,
                "_refresh_quick",
                new=AsyncMock(return_value=expected),
            ),
            patch.object(self.service, "_start_full_refresh") as full_refresh,
        ):
            result = await asyncio.wait_for(
                self.service._run_quick_refresh(
                    "bangumi:foreground",
                    1,
                    title="Foreground",
                    original_title="",
                    content_type="anime",
                    year=2025,
                ),
                timeout=0.2,
            )

        self.assertEqual(result, expected)
        full_refresh.assert_called_once()

    def test_quick_inventory_prefers_three_different_hosts(self):
        items = [
            {
                "url": "https://a.example/one.m3u8",
                "available": True,
                "status": SERVER_VERIFIED,
            },
            {
                "url": "https://a.example/two.m3u8",
                "available": True,
                "status": SERVER_VERIFIED,
            },
            {
                "url": "https://b.example/video.m3u8",
                "available": True,
                "status": SERVER_VERIFIED,
            },
            {
                "url": "https://c.example/video.m3u8",
                "available": False,
                "status": CLIENT_PROBE_REQUIRED,
            },
        ]

        selected = self.service._select_quick_lines(items)

        self.assertEqual(
            [urlparse(item["url"]).hostname for item in selected],
            ["a.example", "b.example", "c.example"],
        )

    def test_quick_inventory_prefers_startable_media_and_drops_tail_moov(self):
        items = [
            {
                "url": "https://tail.example/video.mp4",
                "format": "mp4",
                "available": True,
                "status": SERVER_VERIFIED,
                "startup_profile": STARTUP_MP4_TAIL_MOOV,
                "startup_latency_ms": 10,
            },
            {
                "url": "https://slow-hls.example/video.m3u8",
                "format": "hls",
                "available": True,
                "status": SERVER_VERIFIED,
                "startup_profile": STARTUP_HLS,
                "startup_latency_ms": 900,
            },
            {
                "url": "https://fast-hls.example/video.m3u8",
                "format": "hls",
                "available": True,
                "status": SERVER_VERIFIED,
                "startup_profile": STARTUP_HLS,
                "startup_latency_ms": 120,
            },
            {
                "url": "https://faststart.example/video.mp4",
                "format": "mp4",
                "available": True,
                "status": SERVER_VERIFIED,
                "startup_profile": STARTUP_MP4_FASTSTART,
                "startup_latency_ms": 500,
            },
        ]

        selected = self.service._select_quick_lines(items)

        self.assertEqual(
            [urlparse(item["url"]).hostname for item in selected],
            [
                "faststart.example",
                "fast-hls.example",
                "slow-hls.example",
            ],
        )
        self.assertNotIn(
            "tail.example",
            {urlparse(item["url"]).hostname for item in selected},
        )

    def test_quick_inventory_keeps_input_order_when_scores_are_equal(self):
        items = [
            {
                "url": f"https://{host}.example/video.m3u8",
                "format": "hls",
                "available": True,
                "status": SERVER_VERIFIED,
                "startup_profile": STARTUP_HLS,
                "startup_latency_ms": 125,
            }
            for host in ("first", "second", "third")
        ]

        selected = self.service._select_quick_lines(items)

        self.assertEqual(
            [urlparse(item["url"]).hostname for item in selected],
            ["first.example", "second.example", "third.example"],
        )


if __name__ == "__main__":
    unittest.main()
