import unittest
from unittest.mock import AsyncMock, patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import AggregatedVideoLine
from server.database import Base, PlaybackCache
from server.dependencies import get_session
from server.main import app
from server.scrapers.anime.anich_transport import AniChUpstreamError


class PlaybackApiTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

        async def override_session():
            async with self.sessions() as session:
                yield session

        app.dependency_overrides[get_session] = override_session
        self.client = AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://test",
        )

    async def asyncTearDown(self):
        app.dependency_overrides.clear()
        await self.client.aclose()
        await self.engine.dispose()

    async def test_cache_miss_is_stored_and_next_request_preserves_headers(self):
        lines = [
            AggregatedVideoLine(
                url="https://cdn.example/video.m3u8",
                title="高清线路",
                quality="1080P",
                format="hls",
                source="maccms:iKun",
                headers={"Referer": "https://player.example/"},
            )
        ]
        with patch(
            "server.main.aggregator.resolve_verified_lines",
            new=AsyncMock(return_value=lines),
        ) as resolver:
            first = await self.client.get(
                "/api/v2/vod/maccms:iKun:1", params={"episode": 1}
            )
            second = await self.client.get(
                "/api/v2/vod/maccms:iKun:1", params={"episode": 1}
            )

        self.assertEqual(first.status_code, 200)
        self.assertFalse(first.json()[0]["cached"])
        self.assertTrue(second.json()[0]["cached"])
        self.assertEqual(
            second.json()[0]["headers"]["Referer"],
            "https://player.example/",
        )
        self.assertEqual(resolver.await_count, 1)
        async with self.sessions() as session:
            count = await session.scalar(select(func.count(PlaybackCache.id)))
        self.assertEqual(count, 1)

    async def test_anich_episodes_cooldown_returns_neutral_503(self):
        error = AniChUpstreamError(
            "cooldown https://private-upstream.example/episodes?token=secret", status=429
        )
        with patch(
            "server.routers.compat_v2.aggregator.get_episodes",
            new=AsyncMock(side_effect=error),
        ) as fetch:
            response = await self.client.get("/api/v2/episodes/crawler:anich:32564")

        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.headers["Retry-After"], "30")
        self.assertEqual(response.json(), {"message": "来源暂时繁忙，请稍后重试"})
        self.assertNotIn("private-upstream", response.text)
        self.assertNotIn("secret", response.text)
        fetch.assert_awaited_once_with("crawler:anich:32564")

    async def test_anich_vod_cooldown_is_not_cached_and_recovery_stays_fresh(self):
        error = AniChUpstreamError(
            "cooldown https://private-upstream.example/vod?token=secret", status=429
        )
        lines = [AggregatedVideoLine(
            url="https://media.test/recovered.mp4", title="线路1", format="mp4",
            source="crawler:anich:hb-10", headers={"Referer": "https://player.test/"},
        )]
        with patch(
            "server.routers.compat_v2.aggregator.resolve_verified_lines",
            new=AsyncMock(side_effect=[error, lines, error]),
        ) as resolver:
            failed = await self.client.get("/api/v2/vod/crawler:anich:32564")
            self.assertEqual(failed.status_code, 503)
            self.assertEqual(failed.headers["Retry-After"], "30")
            self.assertEqual(failed.json(), {"message": "来源暂时繁忙，请稍后重试"})
            self.assertNotIn("private-upstream", failed.text)
            self.assertNotIn("secret", failed.text)
            async with self.sessions() as session:
                count = await session.scalar(select(func.count(PlaybackCache.id)))
            self.assertEqual(count, 0)

            fresh = await self.client.get("/api/v2/vod/crawler:anich:32564")
            cached = await self.client.get("/api/v2/vod/crawler:anich:32564")

        self.assertEqual(fresh.status_code, 200)
        self.assertFalse(fresh.json()[0]["cached"])
        self.assertEqual(cached.status_code, 200)
        self.assertTrue(cached.json()[0]["cached"])
        self.assertEqual(cached.json()[0]["headers"], {"Referer": "https://player.test/"})
        self.assertNotIn("Retry-After", fresh.headers)
        self.assertNotIn("Retry-After", cached.headers)
        self.assertEqual(resolver.await_count, 2)
        async with self.sessions() as session:
            count = await session.scalar(select(func.count(PlaybackCache.id)))
        self.assertEqual(count, 1)

    async def test_v2_routes_do_not_swallow_other_exceptions(self):
        for path, method in (
            ("/api/v2/episodes/crawler:anich:32564", "get_episodes"),
            ("/api/v2/vod/crawler:anich:32564", "resolve_verified_lines"),
        ):
            with self.subTest(path=path), patch(
                f"server.routers.compat_v2.aggregator.{method}",
                new=AsyncMock(side_effect=ValueError("unrelated fixture failure")),
            ):
                with self.assertRaisesRegex(ValueError, "unrelated fixture failure"):
                    await self.client.get(path)

    async def test_cached_v2_playback_applies_new_resolver_mapping_without_rescan(self):
        import json
        import time
        from server import anich_direct
        wrap = "https://v-cdn.emmmm.eu.org/video/cache-fixture"
        real = "https://media.test/cache-fixture.mp4"
        async with self.sessions() as session:
            session.add(PlaybackCache(subject_id="crawler:anich:123", episode=1,
                title="测试", lines_json=json.dumps([{"url": wrap, "source": "crawler:anich:hb-10"}]),
                line_count=1, verified_at=time.time()))
            await session.commit()
        anich_direct.replace_cache({wrap: (real, 0)})
        try:
            response = await self.client.get("/api/v2/vod/crawler:anich:123")
            assert response.status_code == 200
            assert response.json()[0]["url"] == real
            assert response.json()[0]["source"] == "hb-10"
            assert response.json()[0]["cached"] is True
        finally:
            anich_direct.replace_cache({})

    async def test_quick_playback_route_is_not_captured_by_full_path_route(self):
        expected = [
            {
                "url": "https://cdn.example/quick.m3u8",
                "available": True,
                "quick": True,
            }
        ]
        with patch(
            "server.main.playback_service.quick_lines",
            new=AsyncMock(return_value=expected),
        ) as quick:
            response = await self.client.get(
                "/api/v3/quick-playback/bangumi:123",
                params={"episode": 2},
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload[0], expected[0])
        self.assertEqual(len(payload), 38)
        self.assertTrue(all(item["source_inventory_entry"] for item in payload[1:]))
        self.assertTrue(all(item["available"] is False for item in payload[1:]))
        self.assertEqual(quick.await_args.args[:2], ("bangumi:123", 2))


if __name__ == "__main__":
    unittest.main()
