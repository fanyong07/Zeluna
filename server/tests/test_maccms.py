import asyncio
import unittest
from unittest.mock import AsyncMock

import httpx

import server.scrapers.maccms_sites as maccms_sites
from server.scrapers.base import SubjectResult
from server.scrapers.maccms import (
    MacCmsScraper,
    episode_number_from_label,
    parse_vod_play_url,
)
from server.scrapers.maccms_sites import MACCMS_SITES, precache_sites


class MacCmsScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.scraper = MacCmsScraper()

    async def asyncTearDown(self):
        await self.scraper.aclose()

    def _configure_single_site(self, item: dict, *, precache: bool = False) -> dict:
        site = {
            "name": "测试站",
            "api": "https://source.example/api.php/provide/vod",
        }
        if precache:
            site["precache"] = True
        self.scraper._sites = [site]
        self.scraper._client.get = AsyncMock(return_value=httpx.Response(
            200,
            json={"list": [item]},
            request=httpx.Request("GET", site["api"]),
        ))
        return site

    def test_parse_vod_play_url_keeps_sources_and_episode_order(self):
        parsed = parse_vod_play_url(
            "第1集$https://cdn.example/a.m3u8#第2集$https://cdn.example/b.m3u8"
            "$$$正片$https://cdn.example/movie.mp4"
        )

        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0][1]["name"], "第2集")
        self.assertEqual(parsed[1][0]["url"], "https://cdn.example/movie.mp4")

    def test_parse_vod_play_url_rejects_obvious_player_pages(self):
        parsed = parse_vod_play_url(
            "播放页$https://source.example/player.html?url=abc"
            "#嵌入页$https://source.example/embed/123"
            "#无扩展直链$https://cdn.example/media/opaque-token"
        )

        self.assertEqual(len(parsed), 1)
        self.assertEqual(len(parsed[0]), 1)
        self.assertEqual(
            parsed[0][0]["url"],
            "https://cdn.example/media/opaque-token",
        )

    def test_episode_number_parser_supports_normal_labels_and_rejects_specials(self):
        cases = {
            "第1集": 1,
            "第01集": 1,
            "第1话": 1,
            "第01话": 1,
            "1": 1,
            "01": 1,
            "EP1": 1,
            "EP01": 1,
            "E1": 1,
            "E01": 1,
            "Episode 1": 1,
            "S01E03": 3,
            "S02E03": 3,
            "SP": None,
            "SP1": None,
            "OVA": None,
            "OAD": None,
            "PV": None,
            "预告": None,
            "花絮": None,
            "特别篇": None,
            "总集篇": None,
            "幕后": None,
        }

        for label, expected in cases.items():
            with self.subTest(label=label):
                self.assertEqual(episode_number_from_label(label), expected)

    async def test_unknown_url_is_not_labeled_mp4_and_safe_site_headers_survive(self):
        self.scraper._sites = [{
            "name": "测试站",
            "api": "https://source.example/api.php/provide/vod",
            "headers": {
                "Referer": "https://source.example/",
                "Origin": "https://source.example",
                "Authorization": "must-not-leave-config",
            },
        }]
        self.scraper._client.get = AsyncMock(return_value=httpx.Response(
            200,
            json={
                "list": [{
                    "vod_play_url": (
                        "第1集$https://cdn.example/media/opaque-token"
                    ),
                }],
            },
            request=httpx.Request(
                "GET",
                "https://source.example/api.php/provide/vod",
            ),
        ))

        lines = await self.scraper.get_video_urls("maccms:测试站:1", 1)

        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0].format, "auto")
        self.assertEqual(lines[0].headers, {
            "Referer": "https://source.example/",
            "Origin": "https://source.example",
        })

    async def test_video_urls_use_explicit_episode_number_after_special(self):
        self._configure_single_site({
            "vod_play_url": (
                "第1集$https://cdn.example/1.m3u8"
                "#第2集$https://cdn.example/2.m3u8"
                "#SP$https://cdn.example/sp.m3u8"
                "#第3集$https://cdn.example/3.m3u8"
            ),
        })

        lines = await self.scraper.get_video_urls("maccms:测试站:1", 3)

        self.assertEqual(
            [(line.title, line.url) for line in lines],
            [("第3集", "https://cdn.example/3.m3u8")],
        )

    async def test_detail_does_not_number_special_as_a_normal_episode(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试作品",
            "vod_play_url": (
                "第1集$https://cdn.example/1.m3u8"
                "#第2集$https://cdn.example/2.m3u8"
                "#SP$https://cdn.example/sp.m3u8"
                "#第3集$https://cdn.example/3.m3u8"
            ),
        })

        detail = await self.scraper.get_detail("maccms:测试站:1")

        self.assertIsNotNone(detail)
        self.assertEqual(
            [(episode.number, episode.title) for episode in detail.episodes],
            [(1, "第1集"), (2, "第2集"), (3, "第3集")],
        )

    async def test_video_urls_do_not_position_fallback_to_specials(self):
        self._configure_single_site({
            "vod_play_url": (
                "SP$https://cdn.example/sp.m3u8"
                "#OVA$https://cdn.example/ova.m3u8"
            ),
        })

        lines = await self.scraper.get_video_urls("maccms:测试站:1", 1)

        self.assertEqual(lines, [])

    async def test_detail_position_fallback_ignores_special_labels(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试作品",
            "vod_play_url": (
                "预告$https://cdn.example/preview.m3u8"
                "#上集$https://cdn.example/a.m3u8"
                "#下集$https://cdn.example/b.m3u8"
            ),
        })

        detail = await self.scraper.get_detail("maccms:测试站:1")

        self.assertIsNotNone(detail)
        self.assertEqual(
            [(episode.number, episode.title) for episode in detail.episodes],
            [(1, "上集"), (2, "下集")],
        )

    async def test_video_urls_map_each_playback_group_by_episode_label(self):
        self._configure_single_site({
            "vod_play_url": (
                "第1集$https://a.example/1.m3u8"
                "#第2集$https://a.example/2.m3u8"
                "#SP$https://a.example/sp.m3u8"
                "#第3集$https://a.example/3.m3u8"
                "$$$"
                "S02E03$https://b.example/3.m3u8"
                "#EP01$https://b.example/1.m3u8"
                "#EP02$https://b.example/2.m3u8"
            ),
        })

        lines = await self.scraper.get_video_urls("maccms:测试站:1", 3)

        self.assertEqual(
            [line.url for line in lines],
            ["https://a.example/3.m3u8", "https://b.example/3.m3u8"],
        )

    async def test_video_urls_only_fallback_when_group_has_no_episode_numbers(self):
        self._configure_single_site({
            "vod_play_url": (
                "上集$https://a.example/upper.m3u8"
                "#下集$https://a.example/lower.m3u8"
                "$$$"
                "第1集$https://b.example/1.m3u8"
                "#第3集$https://b.example/3.m3u8"
            ),
        })

        lines = await self.scraper.get_video_urls("maccms:测试站:1", 2)

        self.assertEqual(
            [line.url for line in lines],
            ["https://a.example/lower.m3u8"],
        )

    async def test_search_preserves_unknown_year_and_type(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试作品",
            "vod_year": "",
            "type_name": "",
        })

        outcome = await self.scraper.search_source("测试站", "测试作品")

        self.assertEqual(
            (outcome.results[0].year, outcome.results[0].type),
            (0, "unknown"),
        )

    async def test_detail_preserves_unknown_year_and_type(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试作品",
            "vod_year": "未知",
            "type_name": "",
        })

        detail = await self.scraper.get_detail("maccms:测试站:1")

        self.assertIsNotNone(detail)
        self.assertEqual((detail.year, detail.type), (0, "unknown"))

    async def test_latest_preserves_unknown_year_and_type(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试作品",
            "vod_year": "未知",
            "type_name": "",
        }, precache=True)

        results = await self.scraper.get_latest()

        self.assertEqual((results[0].year, results[0].type), (0, "unknown"))

    async def test_search_keeps_explicit_series_type(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试剧集",
            "vod_year": "2025",
            "type_name": "国产剧",
        })

        outcome = await self.scraper.search_source("测试站", "测试剧集")

        self.assertEqual(outcome.results[0].type, "tv")

    async def test_search_does_not_treat_genre_name_as_tv_type(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试作品",
            "vod_year": "2025",
            "type_name": "喜剧",
        })

        outcome = await self.scraper.search_source("测试站", "测试作品")

        self.assertEqual(outcome.results[0].type, "unknown")

    async def test_search_treats_unparseable_year_as_unknown(self):
        self._configure_single_site({
            "vod_id": "1",
            "vod_name": "测试作品",
            "vod_year": "未知",
            "type_name": "动漫",
        })

        outcome = await self.scraper.search_source("测试站", "测试作品")

        self.assertEqual(outcome.results[0].year, 0)

    async def test_search_interleaves_sites_by_priority(self):
        high = {"name": "高优先", "api": "https://high.example", "weight": 100}
        low = {"name": "低优先", "api": "https://low.example", "weight": 10}
        self.scraper._sites = [low, high]

        async def fake_search(site, keyword):
            self.assertEqual(keyword, "测试")
            return [
                SubjectResult(
                    source_id=f"maccms:{site['name']}:{index}",
                    title=f"{site['name']}{index}",
                    extra={"site": site["name"]},
                )
                for index in (1, 2)
            ]

        self.scraper._site_search = AsyncMock(side_effect=fake_search)
        results = await self.scraper.search("测试")

        self.assertEqual(
            [item.source_id for item in results],
            [
                "maccms:高优先:1",
                "maccms:低优先:1",
                "maccms:高优先:2",
                "maccms:低优先:2",
            ],
        )

    async def test_search_limits_site_concurrency(self):
        self.scraper._sites = [
            {"name": f"站点{index}", "api": f"https://site{index}.example"}
            for index in range(20)
        ]
        active = 0
        peak = 0

        async def fake_get(url, params):
            nonlocal active, peak
            active += 1
            peak = max(peak, active)
            await asyncio.sleep(0.01)
            active -= 1
            return httpx.Response(
                200,
                json={"list": []},
                request=httpx.Request("GET", url, params=params),
            )

        self.scraper._client.get = AsyncMock(side_effect=fake_get)
        await self.scraper.search("测试")

        self.assertLessEqual(peak, 10)

    async def test_progressive_search_yields_fast_site_without_waiting_for_slow(self):
        slow = {"name": "slow", "api": "https://slow.example"}
        fast = {"name": "fast", "api": "https://fast.example"}
        self.scraper._sites = [slow, fast]
        release_slow = asyncio.Event()
        slow_cancelled = asyncio.Event()

        async def fake_search(site, keyword):
            self.assertEqual(keyword, "test")
            if site["name"] == "slow":
                try:
                    await release_slow.wait()
                except asyncio.CancelledError:
                    slow_cancelled.set()
                    raise
            return [
                SubjectResult(
                    source_id=f"maccms:{site['name']}:1",
                    title="Test",
                    type="anime",
                )
            ]

        self.scraper._site_search = AsyncMock(side_effect=fake_search)
        results = self.scraper.search_progressively("test")
        first = await asyncio.wait_for(anext(results), timeout=0.2)
        self.assertEqual(first[0].source_id, "maccms:fast:1")
        await results.aclose()
        self.assertTrue(slow_cancelled.is_set())

    async def test_progressive_preferred_search_only_queries_quick_sites(self):
        quick = {
            "name": "quick",
            "api": "https://quick.example",
            "enabled": True,
            "tier": "core",
            "quick": True,
            "precache": False,
            "content_types": ["anime", "tv", "movie"],
        }
        self.scraper._sites = [
            quick,
            {
                "name": "precache-only",
                "api": "https://precache.example",
                "enabled": True,
                "tier": "fallback",
                "quick": False,
                "precache": True,
                "content_types": ["anime", "tv", "movie"],
            },
        ]
        self.scraper._site_search = AsyncMock(return_value=[
            SubjectResult(
                source_id="maccms:quick:1",
                title="Test",
                type="anime",
            )
        ])

        results = self.scraper.search_progressively(
            "test",
            preferred_only=True,
        )
        first = await asyncio.wait_for(anext(results), timeout=0.2)
        await results.aclose()

        self.assertEqual(first[0].source_id, "maccms:quick:1")
        self.scraper._site_search.assert_awaited_once_with(quick, "test")

    def test_precache_uses_only_explicit_stable_sites(self):
        sites = precache_sites()

        self.assertTrue(sites)
        self.assertTrue(all(site.get("precache") is True for site in sites))
        self.assertEqual(sites[0]["name"], "iKun")
        self.assertEqual(sites[1]["name"], "光速")

    def test_quick_preference_is_independent_from_precache_and_enabled(self):
        self.scraper._sites = [
            {
                "name": "quick-only",
                "api": "https://quick.example",
                "enabled": True,
                "tier": "core",
                "quick": True,
                "precache": False,
            },
            {
                "name": "precache-only",
                "api": "https://precache.example",
                "enabled": True,
                "tier": "fallback",
                "quick": False,
                "precache": True,
            },
            {
                "name": "disabled",
                "api": "https://disabled.example",
                "enabled": False,
                "tier": "quarantine",
                "quick": False,
                "precache": False,
            },
        ]

        sources = {
            source.name: source for source in self.scraper.discovery_sources
        }

        self.assertTrue(sources["quick-only"].preferred)
        self.assertFalse(sources["precache-only"].preferred)
        self.assertNotIn("disabled", sources)

    def test_site_helpers_keep_operational_dimensions_independent(self):
        sites = [
            {
                "name": "quick-only",
                "api": "https://quick.example",
                "enabled": True,
                "tier": "core",
                "quick": True,
                "precache": False,
                "weight": 90,
                "content_types": ["anime", "tv", "movie"],
            },
            {
                "name": "precache-only",
                "api": "https://precache.example",
                "enabled": True,
                "tier": "fallback",
                "quick": False,
                "precache": True,
                "weight": 80,
                "content_types": ["anime", "tv", "movie"],
            },
            {
                "name": "anime-specialist",
                "api": "https://anime.example",
                "enabled": True,
                "tier": "specialist",
                "quick": False,
                "precache": False,
                "weight": 70,
                "content_types": ["anime"],
            },
            {
                "name": "client-probe",
                "api": "https://client.example",
                "enabled": True,
                "tier": "client_probe",
                "quick": False,
                "precache": False,
                "weight": 60,
                "content_types": ["movie"],
            },
            {
                "name": "quarantine",
                "api": "https://quarantine.example",
                "enabled": False,
                "tier": "quarantine",
                "quick": False,
                "precache": False,
                "weight": 100,
                "content_types": ["anime", "tv", "movie"],
            },
        ]

        names = lambda items: [site["name"] for site in items]

        self.assertEqual(
            names(maccms_sites.enabled_sites(sites)),
            ["quick-only", "precache-only", "anime-specialist", "client-probe"],
        )
        self.assertEqual(names(maccms_sites.core_sites(sites)), ["quick-only"])
        self.assertEqual(names(maccms_sites.quick_sites(sites)), ["quick-only"])
        self.assertEqual(
            names(maccms_sites.fallback_sites(sites)),
            ["precache-only"],
        )
        self.assertEqual(
            names(maccms_sites.specialist_sites(sites, content_type="anime")),
            ["anime-specialist"],
        )
        self.assertEqual(
            names(maccms_sites.client_probe_sites(sites)),
            ["client-probe"],
        )
        self.assertEqual(
            names(maccms_sites.precache_sites(sites)),
            ["precache-only"],
        )

    def test_configured_sites_have_explicit_inventory_fields(self):
        required = {
            "name",
            "api",
            "enabled",
            "tier",
            "quick",
            "precache",
            "weight",
            "content_types",
        }
        allowed_tiers = {
            "core",
            "fallback",
            "specialist",
            "client_probe",
            "quarantine",
            "retired",
        }
        allowed_content_types = {"anime", "tv", "movie"}

        self.assertGreaterEqual(len(MACCMS_SITES), 20)
        for site in MACCMS_SITES:
            with self.subTest(site=site.get("name")):
                self.assertTrue(required.issubset(site))
                self.assertIn(site["tier"], allowed_tiers)
                self.assertTrue(site["content_types"])
                self.assertLessEqual(
                    set(site["content_types"]),
                    allowed_content_types,
                )
                if site["tier"] in {"quarantine", "retired"}:
                    self.assertFalse(site["enabled"])
                    self.assertFalse(site["quick"])
                    self.assertFalse(site["precache"])

    def test_specialists_are_selected_only_for_declared_content_types(self):
        self.scraper._sites = [
            {
                "name": "core",
                "api": "https://core.example",
                "enabled": True,
                "tier": "core",
                "quick": True,
                "precache": True,
                "weight": 100,
                "content_types": ["anime", "tv", "movie"],
            },
            {
                "name": "anime-only",
                "api": "https://anime.example",
                "enabled": True,
                "tier": "specialist",
                "quick": False,
                "precache": False,
                "weight": 80,
                "content_types": ["anime"],
            },
            {
                "name": "tv-only",
                "api": "https://tv.example",
                "enabled": True,
                "tier": "specialist",
                "quick": False,
                "precache": False,
                "weight": 70,
                "content_types": ["tv"],
            },
        ]

        anime = {
            source.name for source in self.scraper.discovery_sources_for("anime")
        }
        tv = {
            source.name for source in self.scraper.discovery_sources_for("series")
        }

        self.assertEqual(anime, {"core", "anime-only"})
        self.assertEqual(tv, {"core", "tv-only"})

    def test_github_candidates_keep_expected_priority_and_precache_policy(self):
        configured = {site["name"]: site for site in MACCMS_SITES}

        self.assertTrue(configured["光速"]["precache"])
        self.assertGreater(configured["光速"]["weight"], configured["如意"]["weight"])
        self.assertFalse(configured["虎牙"]["precache"])
        self.assertLess(configured["虎牙"]["weight"], configured["360"]["weight"])

    def test_client_probe_candidates_do_not_enter_precache(self):
        client_probe_names = {"百度", "无尽", "最大", "360"}
        configured = {
            site["name"]: site for site in MACCMS_SITES
            if site["name"] in client_probe_names
        }

        self.assertEqual(set(configured), client_probe_names)
        self.assertTrue(
            all(
                site["tier"] == "client_probe"
                and site["quick"] is False
                and site["precache"] is False
                for site in configured.values()
            )
        )

    def test_known_isolated_sources_do_not_enter_quick_or_precache(self):
        configured = {site["name"]: site for site in MACCMS_SITES}

        for name in {"极速", "暴风", "风车"}:
            with self.subTest(source=name):
                self.assertFalse(configured[name]["quick"])
                self.assertFalse(configured[name]["precache"])
                self.assertEqual(configured[name]["tier"], "quarantine")
                self.assertFalse(configured[name]["enabled"])
        self.assertEqual(configured["风车"]["content_types"], ["anime"])

if __name__ == "__main__":
    unittest.main()
