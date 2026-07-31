import asyncio
import unittest
from unittest.mock import AsyncMock

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
