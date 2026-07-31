import unittest

import httpx

from server.scrapers.anime.mifun import MiFunScraper


class MiFunScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/vodsearch/":
                return httpx.Response(
                    200,
                    text=(
                        '<div class="hl-item"><div class="hl-item-content">'
                        '<h2 class="hl-item-title"><a href="/voddetail/100.html" '
                        'title="葬送的芙莉莲">葬送的芙莉莲</a></h2></div></div>'
                    ),
                )
            if request.url.path == "/voddetail/100.html":
                return httpx.Response(
                    200,
                    text=(
                        '<h1 class="hl-dc-title">葬送的芙莉莲</h1>'
                        '<div class="hl-tabs-box">'
                        '<div class="hl-list-wrap">'
                        '<a href="/vodplay/100-1-1.html">第01集</a>'
                        '<a href="/vodplay/100-1-2.html">第02集</a>'
                        '</div><div class="hl-list-wrap">'
                        '<a href="/vodplay/100-2-1.html">第01集</a>'
                        '</div></div>'
                    ),
                )
            if request.url.path == "/vodplay/100-1-1.html":
                return httpx.Response(
                    200,
                    text=(
                        '<script>const parser="https:\\/\\/data.m3u8.in\\/player\\/?url=";'
                        'const media="https:\\/\\/media.example\\/one.m3u8";'
                        "</script>"
                    ),
                )
            if request.url.path == "/vodplay/100-2-1.html":
                return httpx.Response(
                    200,
                    text='<video src="https://media.example/two.mp4"></video>',
                )
            return httpx.Response(404)

        self.scraper = MiFunScraper(
            base_url="https://mifun.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_multiple_playback_roads(self):
        results = await self.scraper.search("葬送的芙莉莲")
        self.assertEqual(results[0].source_id, "voddetail/100.html")

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
        self.assertTrue(all(line.source_name == "mifun" for line in lines))
        self.assertTrue(all("Referer" in line.headers for line in lines))


if __name__ == "__main__":
    unittest.main()
