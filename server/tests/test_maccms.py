import asyncio
import unittest
from unittest.mock import AsyncMock, patch

import httpx

from server.scrapers.base import SubjectResult
from server.scrapers.maccms import MacCmsScraper, parse_vod_play_url
from server.scrapers.maccms_sites import MACCMS_SITES, precache_sites


class MacCmsScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.scraper = MacCmsScraper()

    async def asyncTearDown(self):
        await self.scraper.aclose()

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

    async def test_progressive_preferred_search_only_queries_precache_sites(self):
        preferred = {
            "name": "preferred",
            "api": "https://preferred.example",
            "precache": True,
        }
        self.scraper._sites = [
            preferred,
            {"name": "fallback", "api": "https://fallback.example"},
        ]
        self.scraper._site_search = AsyncMock(return_value=[
            SubjectResult(
                source_id="maccms:preferred:1",
                title="Test",
                type="anime",
            )
        ])

        with patch(
            "server.scrapers.maccms.precache_sites",
            return_value=[preferred],
        ):
            results = self.scraper.search_progressively(
                "test",
                preferred_only=True,
            )
            first = await asyncio.wait_for(anext(results), timeout=0.2)
            await results.aclose()

        self.assertEqual(first[0].source_id, "maccms:preferred:1")
        self.scraper._site_search.assert_awaited_once_with(preferred, "test")

    def test_precache_uses_only_explicit_stable_sites(self):
        sites = precache_sites()

        self.assertTrue(sites)
        self.assertTrue(all(site.get("precache") is True for site in sites))
        self.assertEqual(sites[0]["name"], "iKun")
        self.assertEqual(sites[1]["name"], "光速")

    def test_github_candidates_keep_expected_priority_and_precache_policy(self):
        configured = {site["name"]: site for site in MACCMS_SITES}

        self.assertTrue(configured["光速"]["precache"])
        self.assertGreater(configured["光速"]["weight"], configured["如意"]["weight"])
        self.assertFalse(configured["虎牙"]["precache"])
        self.assertLess(configured["虎牙"]["weight"], configured["360"]["weight"])

    def test_client_probe_candidates_do_not_enter_precache(self):
        client_probe_names = {"暴风", "百度", "无尽", "最大", "360"}
        configured = {
            site["name"]: site for site in MACCMS_SITES
            if site["name"] in client_probe_names
        }

        self.assertEqual(set(configured), client_probe_names)
        self.assertTrue(
            all(site.get("precache") is False for site in configured.values())
        )

if __name__ == "__main__":
    unittest.main()
