import unittest

import httpx

from server.scrapers.anime.age import AgeScraper


class AgeScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/search":
                self.assertEqual(request.url.params["query"], "葬送的芙莉莲")
                return httpx.Response(
                    200,
                    text=(
                        '<div><img data-original="/cover.jpg">'
                        '<a href="/detail/20230207">葬送的芙莉莲</a></div>'
                        '<a href="/detail/20230207">资源详情</a>'
                    ),
                )
            if request.url.path == "/detail/20230207":
                return httpx.Response(
                    200,
                    text=(
                        '<meta property="og:image" content="/cover.jpg">'
                        '<meta name="description" content="作品简介">'
                        '<h2 class="video_detail_title">葬送的芙莉莲</h2>'
                        '<button data-bs-target="#playlist-source-one">VIP 西瓜</button>'
                        '<button data-bs-target="#playlist-source-two">非凡</button>'
                        '<div id="playlist-source-one"><ul class="video_detail_episode">'
                        '<li><a href="/play/20230207/1/1">第01集</a></li>'
                        '<li><a href="/play/20230207/1/2">第02集</a></li>'
                        '</ul></div>'
                        '<div id="playlist-source-two"><ul class="video_detail_episode">'
                        '<li><a href="/play/20230207/2/1">第01集</a></li>'
                        '<li><a href="/play/20230207/2/2">第02集</a></li>'
                        '</ul></div>'
                    ),
                )
            if request.url.path == "/play/20230207/1/1":
                return httpx.Response(200, text='<iframe src="/parser/one"></iframe>')
            if request.url.path == "/play/20230207/2/1":
                return httpx.Response(200, text='<iframe src="/parser/two"></iframe>')
            if request.url.path == "/parser/one":
                return httpx.Response(
                    200,
                    text="<script>var Vurl = 'https://media.example/one.m3u8';</script>",
                )
            if request.url.path == "/parser/two":
                return httpx.Response(
                    200,
                    text='<script>var Vurl="https://media.example/two.mp4";</script>',
                )
            return httpx.Response(404)

        self.scraper = AgeScraper(
            base_url="https://age.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_lightweight_player_resolution(self):
        results = await self.scraper.search("葬送的芙莉莲")
        self.assertEqual(
            [(item.source_id, item.title) for item in results],
            [("20230207", "葬送的芙莉莲")],
        )
        detail = await self.scraper.get_detail("20230207")
        self.assertIsNotNone(detail)
        self.assertEqual([item.number for item in detail.episodes], [1, 2])

        lines = await self.scraper.get_video_urls("20230207", 1)
        self.assertEqual(
            [line.url for line in lines],
            [
                "https://media.example/one.m3u8",
                "https://media.example/two.mp4",
            ],
        )
        self.assertEqual([line.format for line in lines], ["hls", "mp4"])
        self.assertEqual(
            [line.title for line in lines],
            ["AGE · VIP 西瓜", "AGE · 非凡"],
        )
        self.assertTrue(all(line.source_name == "age" for line in lines))

    async def test_rejects_invalid_ids_and_untrusted_player_hosts(self):
        self.assertIsNone(await self.scraper.get_detail("../../internal"))
        self.assertEqual(await self.scraper.get_video_urls("https://evil.test", 1), [])
        self.assertFalse(
            self.scraper._is_allowed_player_url("https://127.0.0.1/parser")
        )


if __name__ == "__main__":
    unittest.main()
