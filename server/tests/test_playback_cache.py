import json
import unittest

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.database import Base, PlaybackCache, upsert_playback_cache


class PlaybackCacheTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def test_upsert_keeps_one_row_and_preserves_headers(self):
        first = [{"url": "https://cdn.example/a.m3u8", "headers": {}}]
        second = [{
            "url": "https://cdn.example/b.m3u8",
            "headers": {"Referer": "https://player.example/"},
        }]
        async with self.sessions() as session:
            await upsert_playback_cache(
                session,
                subject_id="maccms:iKun:1",
                episode=1,
                title="测试",
                lines_json=json.dumps(first),
                line_count=1,
                verified_at=1.0,
            )
        async with self.sessions() as session:
            await upsert_playback_cache(
                session,
                subject_id="maccms:iKun:1",
                episode=1,
                title="测试",
                lines_json=json.dumps(second),
                line_count=1,
                verified_at=2.0,
            )
        async with self.sessions() as session:
            count = await session.scalar(select(func.count(PlaybackCache.id)))
            row = await session.scalar(select(PlaybackCache))

        self.assertEqual(count, 1)
        self.assertEqual(row.verified_at, 2.0)
        self.assertEqual(
            json.loads(row.lines_json)[0]["headers"]["Referer"],
            "https://player.example/",
        )


if __name__ == "__main__":
    unittest.main()
