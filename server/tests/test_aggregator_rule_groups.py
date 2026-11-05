"""Multi-rule providers retain independent sites through discovery and bindings.

All origin/media traffic is offline httpx transport traffic. Persistence uses an
explicit in-memory SQLite database, never the configured/user database.
"""
from __future__ import annotations

import asyncio
from dataclasses import replace
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import (
    CLIENT_PROBE_REQUIRED,
    CLIENT_RESOLVER_REQUIRED,
    EMPTY_MEDIA,
    SERVER_VERIFIED,
    UNAVAILABLE,
    ContentAggregator,
    SourceMatch,
    _client_resolver_descriptor,
)
from server.database import Base, SourceBinding
from server.playback import PlaybackService
from server.playback_discovery import SourceDiscoveryStatus
from server.scrapers.anime.animeko import AnimekoScraper
from server.scrapers.anime.animeko_rules import parse_media_source
from server.scrapers.base import SubjectResult, VideoLine


TITLE = "Fixture Anime"


def rule(rule_id: str, host: str):
    value = parse_media_source({
        "id": rule_id, "factoryId": "web-selector", "version": 1,
        "arguments": {"name": f"动漫 {rule_id}", "searchConfig": {
            "searchUrl": f"https://{host}/search?q={{keyword}}",
            "rawBaseUrl": f"https://{host}", "requestInterval": 0,
            "subjectFormatId": "a",
            "selectorSubjectFormatA": {"selectLists": ".results a"},
            "channelFormatId": "no-channel",
            "selectorChannelFormatNoChannel": {
                "selectEpisodes": ".episodes a",
                "matchEpisodeSortFromName": r"第(?<ep>\d+)话",
            },
            "matchVideo": {
                "enableNestedUrl": False,
                "matchVideoUrl": r"^https://cdn\.example/.*\.m3u8$",
            },
        }},
    })
    assert value is not None and value.is_playable
    return value


class Crawler:
    content_types = ["anime"]

    def __init__(self, results=(), lines=()):
        self.results = list(results)
        self.lines = list(lines)
        self.search_calls = []
        self.resolve_calls = []

    async def search(self, keyword):
        self.search_calls.append(keyword)
        return self.results

    async def get_detail(self, source_id):
        return None

    async def get_video_urls(self, source_id, episode=1):
        self.resolve_calls.append((source_id, episode))
        return self.lines

    async def get_latest(self, **_kwargs):
        return []

    async def aclose(self):
        pass


def match(provider, rule_id, *, score=100, site="", suffix="1"):
    if provider == "animeko":
        source_id = f"crawler:animeko:{rule_id}|https://{site or rule_id + '.example'}/subject/{suffix}"
    elif provider == "kazumi":
        source_id = f"crawler:kazumi:{rule_id}::{suffix}"
    else:
        source_id = f"{provider}:{rule_id}:{suffix}"
    return SourceMatch(
        source_id=source_id, source_name=provider if provider in {"animeko", "kazumi"} else rule_id,
        title=TITLE, content_type="anime", year=0, score=score, site_name=site,
    )


def descriptor(rule_id="alpha", page="https://chapter.example/play/1.html"):
    return {
        "kind": "kazumi_page_v1", "page_url": page,
        "referer": "https://chapter.example/detail/one.html",
        "rule_id": rule_id, "rule_name": f"规则 {rule_id}", "user_agent": "Fixture-UA/1",
        "page_hosts": ["chapter.example"], "media_hosts": ["cdn.example"],
    }


class RuleGroupTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.owned = []
        self.requests = []

    async def asyncTearDown(self):
        for owner in reversed(self.owned):
            await owner.aclose()

    def aggregate(self, crawlers, *, maccms=False):
        aggregator = ContentAggregator(
            crawler_scrapers=crawlers,
            enabled_provider_ids=frozenset({
                *(f"crawler.{key}" for key in crawlers),
                *({"aggregate.maccms"} if maccms else set()),
            }),
            resolver_search_enabled=False,
        )
        self.owned.append(aggregator)
        return aggregator

    def animeko(self, *, extra_rules=(), handler=None):
        def pages(request):
            self.requests.append((request.url.host, request.url.path))
            if request.url.path == "/search":
                return httpx.Response(200, text=(
                    '<div class="results">'
                    '<a href="/subject/weak">Fixture Anime 国语</a>'
                    '<a href="/subject/best">Fixture Anime</a>'
                    '<a href="/subject/wrong">Fixture Anime 第二季</a></div>'
                ))
            if request.url.path == "/subject/best":
                return httpx.Response(200, text=(
                    '<div class="episodes"><a href="/play/1">第01话</a></div>'
                ))
            if request.url.path == "/play/1":
                return httpx.Response(200, text=f'<video src="https://cdn.example/{request.url.host}.m3u8"></video>')
            raise AssertionError(f"Non-best candidate was resolved: {request.url}")

        return AnimekoScraper(
            rules=[rule("alpha", "alpha.example"), rule("beta", "beta.example"), *extra_rules],
            transport=httpx.MockTransport(handler or pages), enabled=True,
        )

    async def test_two_animeko_sites_search_discover_resolve_only_best_per_rule(self):
        scraper = self.animeko()
        aggregator = self.aggregate({"animeko": scraper})
        searched = await scraper.search(TITLE)
        self.assertEqual(len(searched), 6)
        self.assertEqual({item.extra["source_identity"]["rule_id"] for item in searched}, {"alpha", "beta"})
        matches, diagnostics = await aggregator.discover_source_matches(
            [TITLE], content_type="anime", include_diagnostics=True,
        )
        self.assertEqual({item.rule_id for item in matches}, {"alpha", "beta"})
        self.assertEqual({item.site_name for item in matches}, {"alpha.example", "beta.example"})
        self.assertEqual({item.source_name for item in matches}, {"animeko"})
        self.assertTrue(all(item.source_id.endswith("/subject/best") for item in matches))
        self.assertEqual(diagnostics["animeko"].search_hit_count, 6)
        self.assertEqual(diagnostics["animeko"].status, SourceDiscoveryStatus.MATCHED)
        lines, health, resolutions = await aggregator.resolve_source_matches(
            matches, episode=1, verify=False, include_diagnostics=True,
        )
        self.assertEqual(len(lines), 2)
        self.assertEqual({line.rule_id for line in lines}, {"alpha", "beta"})
        self.assertEqual({line.provider_id for line in lines}, {"crawler.animeko"})
        self.assertEqual({line.verification_status for line in lines}, {CLIENT_PROBE_REQUIRED})
        self.assertEqual(health["animeko"], CLIENT_PROBE_REQUIRED)
        self.assertEqual(set(resolutions), {"animeko", "animeko:rule:alpha", "animeko:rule:beta"})
        self.assertFalse(any(path.endswith(("weak", "wrong")) for _, path in self.requests))

    async def test_same_origin_independent_rules_keep_their_route_inventory(self):
        scraper = self.animeko(extra_rules=[rule("alpha-next", "alpha.example")])
        aggregator = self.aggregate({"animeko": scraper})
        matches = await aggregator.discover_source_matches([TITLE], content_type="anime")
        self.assertEqual(len(matches), 3)
        self.assertEqual({item.site_name for item in matches}, {"alpha.example", "beta.example"})
        self.assertEqual({item.rule_id for item in matches}, {"alpha", "alpha-next", "beta"})
        self.assertEqual(len({item.group_key for item in matches}), 3)

    async def test_progressive_keeps_both_rules_and_resolves_them(self):
        aggregator = self.aggregate({"animeko": self.animeko()})
        matches = [item async for item in aggregator.discover_source_matches_progressively(
            [TITLE], content_type="anime", max_matches=2,
        )]
        self.assertEqual({item.rule_id for item in matches}, {"alpha", "beta"})
        lines, _ = await aggregator.resolve_source_matches(matches, episode=1, verify=False)
        self.assertEqual({line.site_name for line in lines}, {"alpha.example", "beta.example"})
        self.assertEqual([item async for item in aggregator.discover_source_matches_progressively([TITLE], max_matches=0)], [])

    async def test_provider_deadline_keeps_completed_rule_and_drains_slow_worker(self):
        slow_started = asyncio.Event()
        cancelled = asyncio.Event()
        baseline = asyncio.all_tasks()

        async def pages(request):
            self.requests.append((request.url.host, request.url.path))
            if request.url.host == "beta.example":
                slow_started.set()
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    cancelled.set()
                    raise
            return httpx.Response(200, text='<div class="results"><a href="/subject/best">Fixture Anime</a></div>')

        aggregator = self.aggregate({"animeko": self.animeko(handler=pages)})
        with patch.dict("server.aggregator._PROVIDER_SEARCH_TIMEOUTS", {"animeko": 0.08}):
            matches, diagnostics = await aggregator.discover_source_matches([TITLE], content_type="anime", include_diagnostics=True)
        self.assertTrue(slow_started.is_set())
        self.assertTrue(cancelled.is_set())
        self.assertEqual([item.rule_id for item in matches], ["alpha"])
        self.assertTrue(diagnostics["animeko"].matched)
        self.assertEqual(diagnostics["animeko"].status, SourceDiscoveryStatus.MATCHED)
        self.assertEqual(asyncio.all_tasks() - baseline, set())

    async def test_progressive_first_rule_arrives_before_slow_rule_deadline(self):
        cancelled = asyncio.Event()

        async def pages(request):
            if request.url.host == "beta.example":
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    cancelled.set()
                    raise
            return httpx.Response(200, text='<div class="results"><a href="/subject/best">Fixture Anime</a></div>')

        aggregator = self.aggregate({"animeko": self.animeko(handler=pages)})
        iterator = aggregator.discover_source_matches_progressively([TITLE], content_type="anime")
        first = await asyncio.wait_for(anext(iterator), timeout=0.5)
        self.assertEqual(first.rule_id, "alpha")
        await iterator.aclose()
        self.assertTrue(cancelled.is_set())

    async def test_completed_alias_survives_later_alias_provider_timeout(self):
        crawler = Crawler()
        cancelled = asyncio.Event()

        async def search(alias):
            crawler.search_calls.append(alias)
            if alias != TITLE:
                try:
                    await asyncio.Event().wait()
                except asyncio.CancelledError:
                    cancelled.set()
                    raise
            return [SubjectResult(source_id=f"{name}::1", title=TITLE, type="anime", extra={"kazumi_rule": name}) for name in ("alpha", "beta")]

        crawler.search = search
        aggregator = self.aggregate({"kazumi": crawler})
        with patch.dict("server.aggregator._PROVIDER_SEARCH_TIMEOUTS", {"kazumi": 0.05}):
            matches, diagnostics = await aggregator.discover_source_matches([TITLE, "Fixture Alternate"], content_type="anime", include_diagnostics=True)
        self.assertEqual({item.rule_id for item in matches}, {"alpha", "beta"})
        self.assertEqual(crawler.search_calls, [TITLE, "Fixture Alternate"])
        self.assertTrue(cancelled.is_set())
        self.assertEqual(diagnostics["kazumi"].aliases_attempted, 2)
        self.assertEqual(diagnostics["kazumi"].search_hit_count, 2)

    async def test_ordinary_crawler_and_maccms_grouping_remain_unchanged(self):
        ordinary = Crawler([
            SubjectResult(source_id="weak", title=TITLE + " 国语", type="anime"),
            SubjectResult(source_id="best", title=TITLE, type="anime"),
        ])
        aggregator = self.aggregate({"ordinary": ordinary}, maccms=True)

        async def maccms(*_args, **_kwargs):
            for site in ("one", "two"):
                yield match("maccms", site, score=105)
                yield match("maccms", site, score=70, suffix="weak")

        aggregator._discover_maccms_matches_progressively = maccms
        matches = await aggregator.discover_source_matches([TITLE], content_type="anime")
        self.assertEqual({item.source_id for item in matches}, {"maccms:one:1", "maccms:two:1", "crawler:ordinary:best"})
        quick = [item async for item in aggregator.discover_source_matches_progressively([TITLE], content_type="anime")]
        self.assertEqual({item.source_id for item in quick}, {item.source_id for item in matches})
        self.assertEqual(ordinary.search_calls, [TITLE, TITLE])

    async def test_result_cap_fairly_samples_rules_beside_many_maccms_sites(self):
        aggregator = self.aggregate({"animeko": self.animeko()}, maccms=True)

        async def maccms(*_args, **_kwargs):
            for index in range(20):
                yield match("maccms", f"site-{index}", score=200-index)

        aggregator._discover_maccms_matches_progressively = maccms
        full = await aggregator.discover_source_matches([TITLE], content_type="anime", max_matches=4)
        self.assertEqual(len(full), 4)
        self.assertEqual({item.rule_id for item in full if item.provider_id == "crawler.animeko"}, {"alpha", "beta"})
        quick = [item async for item in aggregator.discover_source_matches_progressively([TITLE], content_type="anime", max_matches=8)]
        self.assertLessEqual(len(quick), 8)
        self.assertIn("crawler.animeko", {item.provider_id for item in quick})

    async def test_full_discovery_keeps_all_already_found_rules_and_real_display_name(self):
        aggregator = self.aggregate({"animeko": self.animeko(extra_rules=[
            rule(f"extra-{index}", "shared.example") for index in range(12)
        ])})
        matches = await aggregator.discover_source_matches([TITLE], content_type="anime")
        self.assertEqual(len(matches), 14)
        self.assertEqual(len({item.rule_id for item in matches}), 14)
        lines, _ = await aggregator.resolve_source_matches(matches[:2], episode=1, verify=False)
        service = PlaybackService(managed_lines_enabled=False)
        self.owned.append(service)
        public = [service._line_dict(line) for line in lines]
        self.assertTrue(all(item["provider_name"].startswith("动漫 ") for item in public))
        self.assertTrue(all(item["provider_name"] != item["rule_id"] for item in public))
        self.assertEqual(len({item["line_id"] for item in public}), len(public))

    async def test_search_request_concurrency_and_per_rule_sampling_remain_bounded(self):
        active = peak = 0

        async def pages(request):
            nonlocal active, peak
            active += 1
            peak = max(peak, active)
            await asyncio.sleep(0.003)
            active -= 1
            return httpx.Response(200, text='<div class="results">' + ''.join(f'<a href="/subject/{index}">Fixture Anime</a>' for index in range(5)) + '</div>')

        scraper = self.animeko(extra_rules=[rule(f"extra-{index}", f"extra-{index}.example") for index in range(4)], handler=pages)
        self.owned.append(scraper)
        with patch("server.scrapers.anime.animeko.config.MACCMS_SEARCH_MAX_CONCURRENCY", 2), patch("server.scrapers.anime.animeko.config.ANIMEKO_MAX_SUBJECTS_PER_SOURCE", 2):
            results = await scraper.search(TITLE)
        self.assertEqual(len(results), 12)
        self.assertEqual(peak, 2)
        self.assertEqual(active, 0)

    async def test_bindings_round_trip_independent_rules_and_legacy_root_names(self):
        aggregator = self.aggregate({"animeko": self.animeko(), "kazumi": Crawler()})
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        service = PlaybackService(session_factory=sessions, managed_lines_enabled=False)
        try:
            async with engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
            matches = await aggregator.discover_source_matches([TITLE], content_type="anime")
            matches.extend([match("kazumi", "gamma"), match("kazumi", "delta")])
            with patch("server.playback.aggregator", aggregator):
                async with sessions() as session:
                    await service._store_bindings(session, "bangumi:fixture", matches)
                    rows = (await session.scalars(select(SourceBinding))).all()
                    self.assertEqual({row.source_name for row in rows}, {"animeko:rule:alpha", "animeko:rule:beta", "kazumi:rule:gamma", "kazumi:rule:delta"})
                    loaded = await service._load_bindings(session, "bangumi:fixture", source_health={}, aliases=[TITLE], content_type="anime")
                    self.assertEqual({item.rule_id for item in loaded}, {"alpha", "beta", "gamma", "delta"})
                    self.assertEqual({item.source_name for item in loaded}, {"animeko", "kazumi"})
                    # Simulate existing pre-fix bindings with only provider names.
                    for row in rows:
                        row.source_name = row.source_name.partition(":rule:")[0]
                    await session.commit()
                    legacy = await service._load_bindings(session, "bangumi:fixture", source_health={}, aliases=[TITLE], content_type="anime")
                    self.assertEqual({item.binding_key for item in legacy}, {item.binding_key for item in loaded})
                    lines, _ = await aggregator.resolve_source_matches([item for item in legacy if item.source_name == "animeko"], episode=1, verify=False)
                    self.assertEqual({line.rule_id for line in lines}, {"alpha", "beta"})
        finally:
            await service.aclose()
            await engine.dispose()

    async def test_kazumi_descriptors_keep_empty_url_distinct_and_skip_media_probe(self):
        crawler = Crawler(lines=[
            VideoLine(url="", source_name=f"{name}:one", client_resolver=descriptor(name))
            for name in ("alpha", "beta")
        ])
        aggregator = self.aggregate({"kazumi": crawler})
        aggregator._line_verification_status = AsyncMock(return_value=SERVER_VERIFIED)
        matches = [match("kazumi", "alpha")]
        for verify in (False, True):
            lines, health = await aggregator.resolve_source_matches(matches, episode=1, verify=verify)
            self.assertEqual(len(lines), 2)
            self.assertEqual({line.client_resolver["rule_id"] for line in lines}, {"alpha", "beta"})
            self.assertEqual({line.verification_status for line in lines}, {CLIENT_RESOLVER_REQUIRED})
            self.assertTrue(all(line.url == "" for line in lines))
            self.assertEqual(health["kazumi"], CLIENT_RESOLVER_REQUIRED)
        aggregator._line_verification_status.assert_not_awaited()

    async def test_media_probing_is_unchanged_and_provider_summary_keeps_strongest(self):
        crawler = Crawler()

        async def resolve(source_id, _episode):
            if source_id.startswith("beta::"):
                await asyncio.sleep(0.01)
                return []
            return [VideoLine(url="https://cdn.example/good.m3u8", format="hls", source_name="alpha:one")]

        crawler.get_video_urls = resolve
        aggregator = self.aggregate({"kazumi": crawler})
        aggregator._line_verification_status = AsyncMock(return_value=SERVER_VERIFIED)
        lines, health, diagnostics = await aggregator.resolve_source_matches([match("kazumi", "alpha"), match("kazumi", "beta")], episode=1, include_diagnostics=True)
        self.assertEqual(len(lines), 1)
        self.assertEqual(aggregator._line_verification_status.await_count, 1)
        self.assertEqual(health["kazumi"], SERVER_VERIFIED)
        self.assertEqual(health["kazumi:rule:beta"], UNAVAILABLE)
        self.assertEqual(diagnostics["kazumi:rule:beta"].error_category, EMPTY_MEDIA)
        self.assertEqual(diagnostics["kazumi"].match.rule_id, "alpha")


class RuleIdentityTests(unittest.TestCase):
    def test_kazumi_uses_double_colon_id_and_generic_rule_metadata_is_reusable(self):
        results = [SubjectResult(source_id=f"{name}::42", title=TITLE, type="anime") for name in ("alpha", "beta")]
        scored = ContentAggregator._score_scraper_results("kazumi", results, [TITLE], content_type="anime", year=0)
        self.assertEqual({item.rule_id for item in scored}, {"alpha", "beta"})
        self.assertEqual(len(ContentAggregator.select_source_matches(scored)), 2)
        generic = [SubjectResult(source_id=name, title=TITLE, type="anime", extra={"source_identity": {"rule_id": name, "site_name": f"{name}.example", "rule_name": f"规则 {name}"}}) for name in ("alpha", "beta")]
        scored = ContentAggregator._score_scraper_results("fixture-rules", generic, [TITLE], content_type="anime", year=0)
        self.assertEqual({item.rule_name for item in scored}, {"规则 alpha", "规则 beta"})
        self.assertEqual(len(ContentAggregator.select_source_matches(scored)), 2)

    def test_rule_duplicates_select_best_even_if_candidate_hosts_differ(self):
        weak = match("animeko", "alpha", score=70, site="legacy.example")
        best = match("animeko", "alpha", score=108, site="current.example")
        self.assertEqual(ContentAggregator.select_source_matches([weak, best]), [best])
        self.assertLessEqual(len(replace(best, rule_id="x"*300).binding_key), 100)

    def test_descriptor_validation_matches_client_contract(self):
        self.assertEqual(_client_resolver_descriptor(descriptor()), descriptor())
        mutations = [
            {"kind": "run_script"}, {"media_hosts": []}, {"media_hosts": ["*"]},
            {"page_hosts": ["wrong.example"]}, {"page_url": "http://127.0.0.1/private"},
            {"page_url": "https://chapter.example/x#fragment"},
            {"page_url": "https://chapter.example/x\\other"},
            {"referer": "https://user:pass@chapter.example/x"},
            {"media_hosts": ["bad..example"]}, {"media_hosts": ["bad/example"]},
            {"media_hosts": ["a"*254 + ".example"]},
            {"media_hosts": [f"cdn-{i}.example" for i in range(33)]},
            {"rule_id": "x"*129}, {"rule_name": "x"*257}, {"user_agent": "x"*513},
            {"user_agent": "ok\x7f"}, {"rule_id": ""},
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertEqual(_client_resolver_descriptor({**descriptor(), **mutation}), {})
