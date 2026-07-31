import asyncio
import unittest

import httpx

from server.scrapers.anime.html_direct import (
    HtmlDirectAnimeScraper,
    HtmlDirectSite,
    create_html_direct_anime_scrapers,
)


class HtmlDirectAnimeScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path.startswith("/search/"):
                return httpx.Response(
                    200,
                    text=(
                        '<div class="title"><a href="/detail/10.html" '
                        'title="葬送的芙莉莲">葬送的芙莉莲</a></div>'
                    ),
                )
            if request.url.path == "/detail/10.html":
                return httpx.Response(
                    200,
                    text=(
                        '<h1>葬送的芙莉莲</h1><div class="episodes">'
                        '<a href="/play/10-1-1.html">第01集</a>'
                        '<a href="/play/10-1-2.html">第02集</a></div>'
                        '<div class="episodes">'
                        '<a href="/play/10-2-1.html">第01集</a></div>'
                    ),
                )
            if request.url.path == "/play/10-1-1.html":
                return httpx.Response(
                    200,
                    text=(
                        '<script>var player_aaaa={"encrypt":0,'
                        '"url":"https://media.example/one.m3u8",'
                        '"from":"line1"}</script>'
                    ),
                )
            if request.url.path == "/play/10-2-1.html":
                return httpx.Response(
                    200,
                    text=(
                        '<script>const parser="https://data.m3u8.in/player/?url=";'
                        'const direct="https://media.example/two.mp4";</script>'
                    ),
                )
            return httpx.Response(404)

        site = HtmlDirectSite(
            key="sample",
            display_name="样例站",
            search_url="https://sample.example/search/{keyword}",
            search_link_selector=".title > a",
            episode_list_selector=".episodes",
        )
        self.scraper = HtmlDirectAnimeScraper(
            site,
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_configured_site_search_detail_and_direct_playback(self):
        results = await self.scraper.search("葬送的芙莉莲")
        self.assertEqual(results[0].source_id, "detail/10.html")

        detail = await self.scraper.get_detail(results[0].source_id)
        self.assertIsNotNone(detail)
        self.assertEqual([item.number for item in detail.episodes], [1, 2])

        lines = await self.scraper.get_video_urls(results[0].source_id, 1)
        self.assertEqual(
            [line.url for line in lines],
            [
                "https://media.example/one.m3u8",
                "https://media.example/two.mp4",
            ],
        )
        self.assertTrue(all(line.source_name == "sample" for line in lines))

    def test_www_redirect_is_treated_as_the_same_site(self):
        source_id = self.scraper._source_id(
            "/detail/10.html",
            "https://www.sample.example/search/title.html",
        )

        self.assertEqual(source_id, "detail/10.html")

    def test_canonical_redirect_host_is_accepted_but_foreign_link_is_not(self):
        redirected = self.scraper._source_id(
            "/detail/10.html",
            "https://canonical.sample.example/search/title.html",
        )
        foreign = self.scraper._source_id(
            "https://unrelated.example/detail/10.html",
            "https://canonical.sample.example/search/title.html",
        )

        self.assertEqual(redirected, "detail/10.html")
        self.assertEqual(foreign, "")

    async def test_production_registry_only_contains_vps_verified_sites(self):
        scrapers = create_html_direct_anime_scrapers()
        try:
            self.assertEqual(set(scrapers), {"jibi", "yinghua2", "wedm"})
        finally:
            await asyncio.gather(
                *(scraper.aclose() for scraper in scrapers.values())
            )


if __name__ == "__main__":
    unittest.main()
