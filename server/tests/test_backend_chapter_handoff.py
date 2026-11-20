"""Backend chapter tasks are bounded work, not fabricated playable media."""
from dataclasses import replace
import unittest
from unittest.mock import AsyncMock

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import (
    AggregatedVideoLine, CLIENT_PROBE_REQUIRED, CLIENT_RESOLVER_REQUIRED,
    SERVER_VERIFIED, UNAVAILABLE, SourceMatch, SourceResolutionOutcome,
)
from server.database import Base, SourceBinding
from server.playback import PlaybackService
from server.playback_discovery import SourceDiscoveryDiagnostic, SourceDiscoveryStatus
from server.playback_inventory import (
    RegisteredPlaybackSource, complete_registered_playback_inventory,
)
from server.repositories.playback import SourceBindingWrite, SqlPlaybackRepository


def descriptor(page="https://chapter.example/play/1.html"):
    return {
        "kind": "kazumi_page_v1", "page_url": page,
        "referer": "https://chapter.example/detail/one.html",
        "rule_id": "independent-rule", "rule_name": "独立规则",
        "user_agent": "Rule-UA/1", "page_hosts": ["chapter.example"],
        "media_hosts": ["cdn.example"],
    }


def chapter(page="https://chapter.example/play/1.html"):
    return AggregatedVideoLine(
        url="", title="本集章节", format="auto",
        source="crawler:kazumi:independent-rule:one",
        provider_id="crawler.kazumi", site_name="chapter.example",
        rule_id="independent-rule", rule_name="独立规则",
        client_resolver=descriptor(page), verification_status=CLIENT_RESOLVER_REQUIRED,
    )


class BackendChapterHandoffTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.service = PlaybackService()

    async def asyncTearDown(self):
        await self.service.aclose()

    async def test_serialization_is_empty_url_nonplayable_and_keeps_rule_identity(self):
        result = self.service._line_dict(chapter())
        self.assertEqual(result["url"], "")
        self.assertIs(result["available"], False)
        self.assertEqual(result["status"], CLIENT_RESOLVER_REQUIRED)
        self.assertEqual(result["route_status"], CLIENT_RESOLVER_REQUIRED)
        self.assertEqual(result["provider_id"], "crawler.kazumi")
        self.assertEqual(result["provider_name"], "独立规则")
        self.assertEqual(result["rule_id"], "independent-rule")
        self.assertEqual(result["client_resolver"], descriptor())
        self.assertEqual(result["headers"], {})
        self.assertFalse(result["client_query_supported"], "Media resolution is not local catalog search support")
        self.assertEqual(result["query_location"], "hybrid")
        self.assertTrue(self.service._is_safe_cached_item(result))
        self.assertTrue(self.service._has_usable_cached_route([result]))
        self.assertFalse(self.service._has_playable_line([result]))

    async def test_invalid_descriptors_never_survive_cache_or_acquire_success(self):
        task = self.service._line_dict(chapter())
        for mutation in (
            {"client_resolver": {**descriptor(), "page_url": "http://127.0.0.1/private"}},
            {"client_resolver": {**descriptor(), "media_hosts": []}},
            {"client_resolver": {**descriptor(), "media_hosts": ["*"]}},
            {"client_resolver": {**descriptor(), "page_url": "https://user:password@chapter.example/x"}},
            {"client_resolver": {**descriptor(), "user_agent": "ok\r\nCookie: account"}},
            {"available": True},
            {"url": "https://chapter.example/play/1.html"},
            {"status": SERVER_VERIFIED},
        ):
            with self.subTest(mutation=mutation):
                broken = {**task, **mutation}
                self.assertFalse(self.service._is_safe_cached_item(broken))
                self.assertFalse(self.service._has_playable_line([broken]))
                self.assertEqual(self.service._select_quick_lines([broken]), [])

    async def test_quick_shortlist_can_return_task_but_ranks_real_media_first(self):
        task = self.service._line_dict(chapter())
        real = self.service._line_dict(AggregatedVideoLine(
            url="https://cdn.example/real.mp4", source="maccms:real",
            verification_status=SERVER_VERIFIED,
        ))
        candidate = self.service._line_dict(AggregatedVideoLine(
            url="https://other.example/candidate.mp4", source="maccms:candidate",
            verification_status=CLIENT_PROBE_REQUIRED,
        ))
        tasks = self.service._select_quick_lines([task])
        self.assertEqual(tasks[0]["status"], CLIENT_RESOLVER_REQUIRED)
        self.assertIs(tasks[0]["available"], False)
        selected = self.service._select_quick_lines([task, candidate, real])
        self.assertEqual(selected[0]["status"], SERVER_VERIFIED)
        if len(selected) > 1:
            self.assertEqual(selected[1]["status"], CLIENT_PROBE_REQUIRED)

    async def test_complete_inventory_preserves_hybrid_execution_without_fake_local_search(self):
        registered = RegisteredPlaybackSource("crawler", "kazumi", "crawler", "not_queried", "未查询")
        task = self.service._line_dict(chapter())
        completed = complete_registered_playback_inventory([task], sources=(registered,))
        self.assertEqual(len(completed), 1)
        self.assertEqual(completed[0]["status"], CLIENT_RESOLVER_REQUIRED)
        self.assertEqual(completed[0]["query_location"], "hybrid")
        self.assertFalse(completed[0]["client_query_supported"])
        self.assertEqual(completed[0]["client_resolver"], descriptor())
        self.assertIs(completed[0]["available"], False)

    async def test_task_resolution_means_episode_found_not_missing_or_server_verified(self):
        match = SourceMatch(source_id="crawler:kazumi:independent-rule::one",
                            source_name="kazumi", title="本片", content_type="anime", year=2023)
        diagnostic = SourceDiscoveryDiagnostic(source_name="kazumi", provider_id="crawler.kazumi")
        resolution = SourceResolutionOutcome(match, [chapter()], CLIENT_RESOLVER_REQUIRED)
        self.service._apply_resolution_diagnostic(diagnostic, resolution)
        self.assertEqual(diagnostic.status, SourceDiscoveryStatus.CLIENT_RESOLVER_REQUIRED)
        self.assertTrue(diagnostic.episode_found)
        self.assertTrue(diagnostic.matched)
        self.assertNotEqual(self.service._legacy_discovery_status(diagnostic.status.value), SERVER_VERIFIED)

    async def test_pending_task_does_not_record_success_or_failure_health(self):
        recorder = AsyncMock()
        class Repository:
            record_health = recorder
        service = PlaybackService(repository_factory=lambda _: Repository())
        try:
            await service._record_health(object(), "bangumi:1", {"kazumi": CLIENT_RESOLVER_REQUIRED})
        finally:
            await service.aclose()
        self.assertEqual(recorder.await_count, 1)
        self.assertEqual(recorder.await_args.kwargs["observations"], [])

    async def test_provider_summary_never_upgrades_peer_route_status(self):
        good = self.service._line_dict(AggregatedVideoLine(
            url="https://cdn.example/good.mp4", source="crawler:kazumi:good:one",
            provider_id="crawler.kazumi", rule_name="好规则", verification_status=SERVER_VERIFIED,
        ))
        task = self.service._line_dict(chapter())
        failed = self.service._line_dict(AggregatedVideoLine(
            url="https://cdn.example/failed.mp4", source="crawler:kazumi:failed:one",
            provider_id="crawler.kazumi", rule_name="坏规则", verification_status=UNAVAILABLE,
        ))
        summary = SourceDiscoveryDiagnostic(
            source_name="kazumi", provider_id="crawler.kazumi", queried=True,
            status=SourceDiscoveryStatus.SERVER_VERIFIED, matched=True, episode_found=True,
        )
        result = self.service._complete_site_inventory(
            [good, task, failed], discovery_diagnostics={"kazumi": summary},
        )
        routes = result[:3]
        self.assertEqual([x["diagnostic_status"] for x in routes], [SERVER_VERIFIED, CLIENT_RESOLVER_REQUIRED, "route_unavailable"])
        self.assertEqual([x["provider_diagnostic_status"] for x in routes], [SERVER_VERIFIED] * 3)
        self.assertFalse(routes[1]["available"])
        self.assertFalse(routes[2]["available"])


class BindingIdentityMigrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_existing_binding_acquires_rule_key_without_erasing_history(self):
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        try:
            async with sessions() as session:
                repo = SqlPlaybackRepository(session)
                binding = SourceBindingWrite(
                    source_id="crawler:animeko:encoded-subject", source_name="animeko",
                    matched_title="本片", media_type="anime", year=2023, score=100, episode_count=12,
                )
                await repo.upsert_bindings(stable_id="bangumi:1", bindings=[binding], updated_at=1)
                row = await session.scalar(select(SourceBinding))
                row.success_count = 7
                row.failure_count = 2
                await session.commit()
                await repo.upsert_bindings(stable_id="bangumi:1", bindings=[replace(binding, source_name="animeko:rule:rule-1")], updated_at=2)
                await session.refresh(row)
                self.assertEqual(await session.scalar(select(func.count(SourceBinding.id))), 1)
                self.assertEqual(row.source_name, "animeko:rule:rule-1")
                self.assertEqual((row.success_count, row.failure_count), (7, 2))
        finally:
            await engine.dispose()
