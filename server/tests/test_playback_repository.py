import json
import time
import unittest

from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.database import Base
from server.playback import PlaybackService
from server.repositories.playback import PlaybackCacheEntry, SqlPlaybackRepository


class PlaybackRepositoryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def test_sql_cache_repository_upserts_and_orders_oldest_entries(self):
        async with self.sessions() as session:
            repository = SqlPlaybackRepository(session)
            await repository.upsert_cache(
                subject_id="bangumi:1",
                episode=1,
                title="First",
                lines_json="[]",
                line_count=0,
                verified_at=20,
            )
            await repository.upsert_cache(
                subject_id="bangumi:2",
                episode=1,
                title="Older",
                lines_json="[]",
                line_count=0,
                verified_at=10,
            )
            await repository.upsert_cache(
                subject_id="bangumi:1",
                episode=1,
                title="Updated",
                lines_json="[]",
                line_count=0,
                verified_at=30,
            )

            cached = await repository.get_cache("bangumi:1", 1)
            oldest = await repository.oldest_cache(limit=2)

        self.assertIsNotNone(cached)
        self.assertEqual(cached.title, "Updated")
        self.assertEqual(
            [(item.subject_id, item.verified_at) for item in oldest],
            [("bangumi:2", 10), ("bangumi:1", 30)],
        )

    async def test_playback_service_uses_injected_cache_repository(self):
        cached_line = {
            "url": "https://cdn.example/video.m3u8",
            "title": "Cached",
            "source": "test",
            "available": True,
            "expires_at": 0,
        }

        class FakeRepository:
            async def get_cache(self, subject_id: str, episode: int):
                self.lookup = (subject_id, episode)
                return PlaybackCacheEntry(
                    subject_id=subject_id,
                    episode=episode,
                    title="Cached",
                    lines_json=json.dumps([cached_line]),
                    line_count=1,
                    verified_at=time.time(),
                )

            async def upsert_cache(self, **kwargs):
                self.write = kwargs

            async def oldest_cache(self, *, limit: int):
                return []

        repository = FakeRepository()
        service = PlaybackService(repository_factory=lambda _session: repository)
        try:
            state, lines = await service._cache_lookup(
                object(),
                "bangumi:1",
                1,
            )
            await service._store_cache(
                object(),
                "bangumi:1",
                2,
                "Stored",
                [cached_line, {"available": False}],
            )
        finally:
            await service.aclose()

        self.assertEqual(state, "fresh")
        self.assertEqual(repository.lookup, ("bangumi:1", 1))
        self.assertTrue(lines[0]["cached"])
        self.assertEqual(repository.write["subject_id"], "bangumi:1")
        self.assertEqual(repository.write["episode"], 2)
        self.assertEqual(repository.write["line_count"], 1)


if __name__ == "__main__":
    unittest.main()
