import json
import time
import unittest
from unittest.mock import AsyncMock, patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.app import create_app
from server.database import Base, PlaybackCache
from server.dependencies import get_session
from server.managed_lines.repository import ManagedLineRecord, SqlManagedLineRepository
from server.managed_lines.service import ManagedLineService
from server.playback import PlaybackService


def _managed_record(**changes) -> ManagedLineRecord:
    value = {
        "id": "mpl_public_stable_id",
        "stable_id": "bangumi:400602",
        "episode": 1,
        "provider_key": "managed.main",
        "label": "主线路",
        "quality": "1080p",
        "format_hint": "hls",
        "canonical_url": "https://media-one.example/video.m3u8",
        "url_kind": "static_direct",
        "expires_at": 0.0,
        "headers": {"Referer": "https://player.example/"},
        "priority": 900,
        "status": "active",
        "review_status": "approved",
        "enabled": True,
        "provenance_kind": "licensed",
        "rights_reference": "PRIVATE-RIGHTS-REFERENCE",
        "operator_note": "PRIVATE OPERATOR NOTE",
        "last_verified_status": "server_verified",
        "last_verified_at": 100.0,
        "last_error_category": "",
        "last_latency_ms": 35,
        "created_at": 90.0,
        "updated_at": 100.0,
        "published_at": 100.0,
        "revoked_at": 0.0,
    }
    value.update(changes)
    return ManagedLineRecord(**value)


class ManagedLinePlaybackTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def test_negative_aggregate_cache_cannot_hide_approved_managed_line(self):
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:400602",
                    episode=1,
                    title="测试作品",
                    lines_json="[]",
                    line_count=0,
                    verified_at=time.time(),
                )
            )
            await session.commit()
            await SqlManagedLineRepository(session).add(_managed_record())

        service = PlaybackService(
            session_factory=self.sessions,
            managed_lines_enabled=True,
            managed_line_service=ManagedLineService(),
        )
        try:
            async with self.sessions() as session:
                quick = await service.quick_lines("bangumi:400602", 1, session)
                full = await service.lines("bangumi:400602", 1, session)
                cache = await session.scalar(
                    select(PlaybackCache).where(
                        PlaybackCache.subject_id == "bangumi:400602",
                        PlaybackCache.episode == 1,
                    )
                )
        finally:
            await service.aclose()

        self.assertEqual([item["line_id"] for item in quick], ["mpl_public_stable_id"])
        self.assertEqual([item["line_id"] for item in full], ["mpl_public_stable_id"])
        self.assertEqual(quick[0]["provider_id"], "managed.urls")
        self.assertEqual(quick[0]["provider_name"], "Zeluna 管理线路")
        self.assertEqual(quick[0]["origin_kind"], "managed")
        self.assertNotIn("rights_reference", quick[0])
        self.assertNotIn("operator_note", quick[0])
        self.assertEqual(json.loads(cache.lines_json), [])

    async def test_v3_quick_and_full_http_routes_expose_managed_line(self):
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:400602",
                    episode=1,
                    title="测试作品",
                    lines_json="[]",
                    line_count=0,
                    verified_at=time.time(),
                )
            )
            await session.commit()
            await SqlManagedLineRepository(session).add(_managed_record())

        service = PlaybackService(
            session_factory=self.sessions,
            managed_lines_enabled=True,
            managed_line_service=ManagedLineService(),
        )
        app = create_app()

        async def override_session():
            async with self.sessions() as session:
                yield session

        app.dependency_overrides[get_session] = override_session
        client = AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://test",
        )
        try:
            with patch("server.routers.playback.playback_service", service):
                quick = await client.get(
                    "/api/v3/quick-playback/bangumi:400602",
                    params={"episode": 1},
                )
                full = await client.get(
                    "/api/v3/playback/bangumi:400602",
                    params={"episode": 1},
                )
        finally:
            app.dependency_overrides.clear()
            await client.aclose()
            await service.aclose()

        self.assertEqual(quick.status_code, 200)
        self.assertEqual(full.status_code, 200)
        self.assertEqual(quick.json()[0]["line_id"], "mpl_public_stable_id")
        self.assertEqual(full.json()[0]["line_id"], "mpl_public_stable_id")

    async def test_verified_managed_line_leads_quick_with_distinct_backup_hosts(self):
        aggregate_lines = [
            {
                "url": "https://fast-aggregate.example/video.mp4",
                "title": "聚合快线",
                "format": "mp4",
                "source": "maccms:fast",
                "headers": {},
                "available": True,
                "status": "server_verified",
                "startup_profile": "mp4_faststart",
                "startup_latency_ms": 10,
                "expires_at": 0,
            },
            {
                "url": "https://backup-aggregate.example/video.m3u8",
                "title": "聚合备线",
                "format": "hls",
                "source": "maccms:backup",
                "headers": {},
                "available": True,
                "status": "server_verified",
                "startup_profile": "hls",
                "startup_latency_ms": 50,
                "expires_at": 0,
            },
        ]
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:400602",
                    episode=1,
                    title="测试作品",
                    lines_json=json.dumps(aggregate_lines),
                    line_count=2,
                    verified_at=time.time(),
                )
            )
            await session.commit()
            await SqlManagedLineRepository(session).add(_managed_record())

        service = PlaybackService(
            session_factory=self.sessions,
            managed_lines_enabled=True,
            managed_line_service=ManagedLineService(),
        )
        try:
            async with self.sessions() as session:
                quick = await service.quick_lines("bangumi:400602", 1, session)
                full = await service.lines("bangumi:400602", 1, session)
        finally:
            await service.aclose()

        self.assertEqual(quick[0]["line_id"], "mpl_public_stable_id")
        self.assertEqual(full[0]["line_id"], "mpl_public_stable_id")
        self.assertEqual(len(quick), 3)
        self.assertEqual(
            len({item["url"].split("/", 3)[2] for item in quick}),
            3,
        )

    async def test_feature_flag_off_preserves_existing_aggregate_result(self):
        aggregate = {
            "url": "https://aggregate.example/video.m3u8",
            "title": "聚合线路",
            "format": "hls",
            "source": "maccms:existing",
            "headers": {},
            "available": True,
            "status": "server_verified",
            "expires_at": 0,
        }
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:400602",
                    episode=1,
                    title="测试作品",
                    lines_json=json.dumps([aggregate]),
                    line_count=1,
                    verified_at=time.time(),
                )
            )
            await session.commit()
            await SqlManagedLineRepository(session).add(_managed_record())

        service = PlaybackService(
            session_factory=self.sessions,
            managed_lines_enabled=False,
            managed_line_service=ManagedLineService(),
        )
        try:
            async with self.sessions() as session:
                quick = await service.quick_lines("bangumi:400602", 1, session)
                full = await service.lines("bangumi:400602", 1, session)
        finally:
            await service.aclose()

        self.assertEqual([item["url"] for item in quick], [aggregate["url"]])
        self.assertEqual([item["url"] for item in full], [aggregate["url"]])
        self.assertTrue(all(item.get("origin_kind") != "managed" for item in full))

    async def test_enabled_registry_without_records_preserves_aggregate_result(self):
        aggregate = {
            "url": "https://aggregate.example/video.m3u8",
            "title": "聚合线路",
            "format": "hls",
            "source": "maccms:existing",
            "headers": {},
            "available": True,
            "status": "server_verified",
            "expires_at": 0,
        }
        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:400602",
                    episode=1,
                    title="测试作品",
                    lines_json=json.dumps([aggregate]),
                    line_count=1,
                    verified_at=time.time(),
                )
            )
            await session.commit()

        service = PlaybackService(
            session_factory=self.sessions,
            managed_lines_enabled=True,
            managed_line_service=ManagedLineService(),
        )
        try:
            async with self.sessions() as session:
                full = await service.lines("bangumi:400602", 1, session)
        finally:
            await service.aclose()

        self.assertEqual([item["url"] for item in full], [aggregate["url"]])

    async def test_only_active_approved_enabled_unexpired_lines_are_returned(self):
        now = time.time()
        records = [
            _managed_record(id="mpl_valid"),
            _managed_record(id="mpl_draft", status="draft"),
            _managed_record(id="mpl_pending", review_status="pending"),
            _managed_record(id="mpl_disabled", enabled=False),
            _managed_record(id="mpl_revoked", status="revoked", enabled=False),
            _managed_record(id="mpl_expired", expires_at=now - 1),
        ]
        async with self.sessions() as session:
            await SqlManagedLineRepository(session).add_many(records)

        managed = ManagedLineService()
        async with self.sessions() as session:
            lines = await managed.playback_lines(
                session,
                stable_id="bangumi:400602",
                episode=1,
                limit=8,
            )

        self.assertEqual([item["line_id"] for item in lines], ["mpl_valid"])

    async def test_managed_lookup_failure_does_not_block_aggregate_cache(self):
        aggregate = {
            "url": "https://aggregate.example/video.m3u8",
            "title": "聚合线路",
            "format": "hls",
            "source": "maccms:existing",
            "headers": {},
            "available": True,
            "status": "server_verified",
            "expires_at": 0,
        }

        class FailingManagedLines:
            async def playback_lines(self, *_args, **_kwargs):
                raise RuntimeError(
                    "https://media.example/video.m3u8?signature=must-not-log"
                )

        async with self.sessions() as session:
            session.add(
                PlaybackCache(
                    subject_id="bangumi:400602",
                    episode=1,
                    title="测试作品",
                    lines_json=json.dumps([aggregate]),
                    line_count=1,
                    verified_at=time.time(),
                )
            )
            await session.commit()

        service = PlaybackService(
            session_factory=self.sessions,
            managed_lines_enabled=True,
            managed_line_service=FailingManagedLines(),
        )
        try:
            with self.assertLogs(level="WARNING") as captured:
                async with self.sessions() as session:
                    full = await service.lines("bangumi:400602", 1, session)
        finally:
            await service.aclose()

        self.assertEqual([item["url"] for item in full], [aggregate["url"]])
        self.assertNotIn("signature=must-not-log", "\n".join(captured.output))

    async def test_aggregate_refresh_failure_does_not_block_managed_line(self):
        async with self.sessions() as session:
            await SqlManagedLineRepository(session).add(_managed_record())

        service = PlaybackService(
            session_factory=self.sessions,
            managed_lines_enabled=True,
            managed_line_service=ManagedLineService(),
        )
        try:
            with (
                patch(
                    "server.playback.catalog_service.get_subject",
                    new=AsyncMock(return_value=None),
                ),
                patch(
                    "server.playback.aggregator.resolve_source_matches",
                    new=AsyncMock(side_effect=RuntimeError("aggregate failed")),
                ),
            ):
                async with self.sessions() as session:
                    full = await service.lines(
                        "bangumi:400602",
                        1,
                        session,
                        title="测试作品",
                    )
        finally:
            await service.aclose()

        self.assertEqual([item["line_id"] for item in full], ["mpl_public_stable_id"])


if __name__ == "__main__":
    unittest.main()
