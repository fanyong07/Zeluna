import json
import time
import unittest

from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import SourceMatch
from server.database import Base
from server.playback import PlaybackService
from server.repositories.playback import (
    PlaybackCacheEntry,
    SourceBindingEntry,
    SourceBindingWrite,
    SourceHealthObservation,
    SqlPlaybackRepository,
)


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

    async def test_sql_repository_preserves_binding_and_health_updates(self):
        async with self.sessions() as session:
            repository = SqlPlaybackRepository(session)
            await repository.upsert_bindings(
                stable_id="bangumi:1",
                bindings=[
                    SourceBindingWrite(
                        source_id="crawler:test:1",
                        source_name="test",
                        matched_title="First",
                        media_type="anime",
                        year=2025,
                        score=80,
                        episode_count=12,
                    )
                ],
                updated_at=10,
            )
            await repository.upsert_bindings(
                stable_id="bangumi:1",
                bindings=[
                    SourceBindingWrite(
                        source_id="crawler:test:1",
                        source_name="test",
                        matched_title="Updated",
                        media_type="anime",
                        year=2025,
                        score=90,
                        episode_count=12,
                    )
                ],
                updated_at=20,
            )
            await repository.record_health(
                stable_id="bangumi:1",
                observations=[
                    SourceHealthObservation(
                        source_name="test",
                        status="server_verified",
                        latency_ms=100,
                        error_category="",
                    )
                ],
                checked_at=30,
                ema_alpha=0.35,
                deterministic_failures=frozenset({"malformed_manifest"}),
                server_verified_status="server_verified",
                client_probe_status="client_probe_required",
                unavailable_status="unavailable",
                unknown_error_category="unknown_exception",
            )
            await repository.record_health(
                stable_id="bangumi:1",
                observations=[
                    SourceHealthObservation(
                        source_name="test",
                        status="unavailable",
                        latency_ms=300,
                        error_category="malformed_manifest",
                    )
                ],
                checked_at=40,
                ema_alpha=0.35,
                deterministic_failures=frozenset({"malformed_manifest"}),
                server_verified_status="server_verified",
                client_probe_status="client_probe_required",
                unavailable_status="unavailable",
                unknown_error_category="unknown_exception",
            )

            bindings = await repository.load_bindings(
                stable_id="bangumi:1",
                updated_after=15,
            )
            health = await repository.load_source_health()

        self.assertEqual(len(bindings), 1)
        self.assertEqual(bindings[0].matched_title, "Updated")
        self.assertEqual(bindings[0].success_count, 1)
        self.assertEqual(bindings[0].failure_count, 1)
        self.assertEqual(health["test"].success_count, 1)
        self.assertEqual(health["test"].failure_count, 1)
        self.assertEqual(health["test"].consecutive_failures, 2)
        self.assertEqual(health["test"].last_error_category, "malformed_manifest")
        self.assertEqual(health["test"].latency_ms, 170)

    async def test_playback_service_delegates_binding_and_health_persistence(self):
        class FakeRepository:
            async def load_bindings(self, **kwargs):
                self.load_binding_kwargs = kwargs
                return [
                    SourceBindingEntry(
                        stable_id="bangumi:1",
                        source_id="crawler:test:1",
                        source_name="test",
                        matched_title="Matched",
                        media_type="anime",
                        year=2025,
                        score=80,
                        episode_count=12,
                        enabled=True,
                        success_count=0,
                        failure_count=0,
                        last_success_at=0,
                        last_failure_at=0,
                        updated_at=time.time(),
                    )
                ]

            async def load_source_health(self):
                return {}

            async def upsert_bindings(self, **kwargs):
                self.binding_write = kwargs

            async def record_health(self, **kwargs):
                self.health_write = kwargs

        repository = FakeRepository()
        service = PlaybackService(repository_factory=lambda _session: repository)
        match = SourceMatch(
            source_id="crawler:test:1",
            source_name="test",
            title="Matched",
            content_type="anime",
            year=2025,
            episode_count=12,
            score=80,
        )
        try:
            loaded = await service._load_bindings(
                object(),
                "bangumi:1",
                source_health={},
            )
            await service._store_bindings(object(), "bangumi:1", [match])
            await service._record_health(
                object(),
                "bangumi:1",
                {"test": True},
            )
        finally:
            await service.aclose()

        self.assertEqual([item.source_id for item in loaded], ["crawler:test:1"])
        self.assertEqual(repository.binding_write["bindings"][0].score, 80)
        observation = repository.health_write["observations"][0]
        self.assertEqual(observation.source_name, "test")
        self.assertEqual(observation.status, "server_verified")


if __name__ == "__main__":
    unittest.main()
