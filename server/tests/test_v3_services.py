import asyncio
import time
import unittest
from unittest.mock import AsyncMock, patch
from urllib.parse import urlparse

import httpx
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import (
    CLIENT_PROBE_REQUIRED,
    PARSER_MISMATCH,
    SERVER_VERIFIED,
    SERVER_BLOCKED_CLIENT_CANDIDATE,
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
from server.scrapers.maccms_sites import MACCMS_SITES


class CatalogServiceTests(unittest.IsolatedAsyncioTestCase):
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
                await service._persist_many(session, [lightweight])
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

    async def test_bangumi_ranked_home_fetches_all_requested_pages(self):
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
            self.assertEqual(requests, [(0, 100), (100, 100), (200, 40)])
            self.assertEqual(len(items), 3)
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
        with (
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
            async with self.sessions() as session:
                first = await self.service.lines("bangumi:123", 1, session)
            async with self.sessions() as session:
                second = await self.service.lines("bangumi:123", 1, session)

        self.assertFalse(first[0]["cached"])
        self.assertTrue(second[0]["cached"])
        self.assertEqual(len(first), len(aggregator.source_inventory))
        self.assertEqual(
            {item["source"].split(":", 1)[1] for item in first},
            aggregator.configured_source_names,
        )
        self.assertIn("crawler:dm706", {item["source"] for item in first})
        self.assertEqual(sum(item["available"] for item in first), 1)
        self.assertEqual(discover.await_count, 1)
        self.assertEqual(resolve.await_count, 1)
        async with self.sessions() as session:
            cache_count = await session.scalar(select(func.count(PlaybackCache.id)))
            binding_count = await session.scalar(select(func.count(SourceBinding.id)))
        self.assertEqual(cache_count, 1)
        self.assertEqual(binding_count, 2)

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
            )
        )

        self.assertFalse(item["available"])
        self.assertEqual(item["status"], CLIENT_PROBE_REQUIRED)
        self.assertEqual(item["expires_at"], expires_at)
        self.assertEqual(
            item["headers"]["Referer"],
            "https://source.example/watch/1",
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
        generator_closed = asyncio.Event()

        def result(index: int):
            line = AggregatedVideoLine(
                url=f"https://cdn-{index}.example/video.m3u8",
                title=f"Route {index}",
                format="hls",
                source=f"maccms:site-{index}",
                verification_status=CLIENT_PROBE_REQUIRED,
            )
            return matches[index], [line], CLIENT_PROBE_REQUIRED

        async def resolve(*_args, **_kwargs):
            try:
                yield result(0)
                await asyncio.sleep(0.03)
                yield result(1)
                await asyncio.Event().wait()
            finally:
                generator_closed.set()

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
            ) as discover,
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
        self.assertTrue(generator_closed.is_set())
        discover.assert_not_called()

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


if __name__ == "__main__":
    unittest.main()
