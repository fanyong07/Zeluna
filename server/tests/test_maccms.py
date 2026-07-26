import unittest
from unittest.mock import AsyncMock

from server.scrapers.base import SubjectResult
from server.scrapers.maccms import MacCmsScraper, parse_vod_play_url
from server.scrapers.maccms_sites import precache_sites


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

    def test_precache_uses_only_explicit_stable_sites(self):
        sites = precache_sites()

        self.assertTrue(sites)
        self.assertTrue(all(site.get("precache") is True for site in sites))
        self.assertEqual(sites[0]["name"], "iKun")


if __name__ == "__main__":
    unittest.main()
