import unittest

import httpx

from server.scrapers.anime.dm706 import Dm706Scraper


class Dm706ScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path.startswith("/search/"):
                return httpx.Response(
                    200,
                    text=(
                        '<div class="item"><a href="/detail/2672/" '
                        'title="葬送的芙莉莲在线观看">葬送的芙莉莲</a>'
                        '<img data-original="/cover.jpg"></div>'
                    ),
                )
            if request.url.path == "/detail/2672/":
                return httpx.Response(
                    200,
                    text=(
                        '<html><head><meta property="og:image" content="/cover.jpg">'
                        '<meta name="description" content="作品简介"></head>'
                        '<body><h1>葬送的芙莉莲</h1>'
                        '<a href="/play/2672-1-1/">第01集</a>'
                        '<a href="/play/2672-1-2/">第02集</a></body></html>'
                    ),
                )
            if request.url.path == "/play/2672-1-1/":
                return httpx.Response(
                    200,
                    text=(
                        '<script>var player_aaaa={"encrypt":0,'
                        '"url":"https://media.example/one/index.m3u8",'
                        '"from":"ffm3u8"}</script>'
                    ),
                )
            return httpx.Response(404)

        self.scraper = Dm706Scraper(
            base_url="https://dm706.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_playback_use_site_directly(self):
        results = await self.scraper.search("葬送的芙莉莲")
        self.assertEqual([(item.source_id, item.title) for item in results], [
            ("2672", "葬送的芙莉莲")
        ])

        detail = await self.scraper.get_detail("2672")
        self.assertIsNotNone(detail)
        self.assertEqual([item.number for item in detail.episodes], [1, 2])

        lines = await self.scraper.get_video_urls("2672", 1)
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0].url, "https://media.example/one/index.m3u8")
        self.assertEqual(lines[0].format, "hls")
        self.assertEqual(lines[0].source_name, "dm706")
        self.assertEqual(
            lines[0].headers["Referer"],
            "https://dm706.example/play/2672-1-1/",
        )


if __name__ == "__main__":
    unittest.main()
