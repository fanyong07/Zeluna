import unittest
from unittest.mock import AsyncMock, patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import AggregatedVideoLine
from server.database import Base, PlaybackCache
from server.main import app, get_session


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


if __name__ == "__main__":
    unittest.main()
