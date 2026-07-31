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
    SERVER_VERIFIED,
    AggregatedVideoLine,
    SourceMatch,
    aggregator,
)
from server.catalog import CatalogService
from server.database import Base, CatalogSubject, PlaybackCache, SourceBinding
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

    async def test_quick_cold_lookup_stops_after_first_verified_source(self):
        match = SourceMatch(
            source_id="maccms:iKun:1",
            source_name="iKun",
            title="测试动画",
            content_type="anime",
            year=2024,
            score=100,
        )
        line = AggregatedVideoLine(
            url="https://first-cdn.example/video.m3u8",
            title="首条可播线路",
            format="hls",
            source="maccms:iKun",
            verification_status=SERVER_VERIFIED,
        )
        yielded_matches = 0
        resolve_verify_values = []

        async def discover(*_args, **_kwargs):
            nonlocal yielded_matches
            yielded_matches += 1
            yield match
            raise AssertionError("quick lookup continued after a verified route")

        async def resolve(matches, **_kwargs):
            resolve_verify_values.append(_kwargs.get("verify"))
            yield matches[0], [line], SERVER_VERIFIED

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
                    title="测试动画",
                    original_title="",
                    content_type="anime",
                    year=2024,
                )

        self.assertEqual(yielded_matches, 1)
        self.assertEqual(resolve_verify_values, [False])
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["url"], line.url)
        self.assertTrue(items[0]["quick"])

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
