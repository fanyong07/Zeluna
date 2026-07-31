import base64
import json
import unittest
from urllib.parse import quote

import httpx

from server.scrapers.anime.girigiri import GiriGiriScraper


class GiriGiriScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        encoded_mp4 = base64.b64encode(
            quote("https://media.example/one.mp4").encode()
        ).decode()

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/ajax/suggest":
                self.assertEqual(request.url.params["mid"], "1")
                return httpx.Response(
                    200,
                    json={
                        "code": 1,
                        "list": [
                            {
                                "id": 25524,
                                "name": "葬送的芙莉莲",
                                "pic": "/cover.webp",
                            }
                        ],
                    },
                )
            if request.url.path == "/GV25524/":
                return httpx.Response(
                    200,
                    text=(
                        '<meta name="description" content="作品简介">'
                        '<h3 class="slide-info-title">葬送的芙莉莲</h3>'
                        '<img class="lazy" data-src="/cover.webp">'
                        '<div class="anthology-list-box">'
                        '<a href="/playGV25524-1-1/">01</a>'
                        '<a href="/playGV25524-1-2/">02</a></div>'
                        '<div class="anthology-list-box">'
                        '<a href="/playGV25524-2-1/">01</a>'
                        '<a href="/playGV25524-2-2/">02</a></div>'
                    ),
                )
            if request.url.path == "/playGV25524-1-1/":
                player = {"encrypt": 2, "url": encoded_mp4, "from": "cht"}
                return httpx.Response(
                    200,
                    text=f"<script>var player_aaaa={json.dumps(player)}</script>",
                )
            if request.url.path == "/playGV25524-2-1/":
                return httpx.Response(
                    200,
                    text=(
                        '<script>var player_aaaa={"encrypt":0,'
                        '"url":"https://media.example/two.m3u8"}</script>'
                    ),
                )
            if request.url.path == "/":
                return httpx.Response(
                    200,
                    text=(
                        '<a href="/GV25524/"><img alt="葬送的芙莉莲" '
                        'data-src="/cover.webp"></a>'
                    ),
                )
            return httpx.Response(404)

        self.scraper = GiriGiriScraper(
            base_url="https://giri.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_all_playback_groups(self):
        results = await self.scraper.search("葬送的芙莉莲")
        self.assertEqual(
            [(item.source_id, item.title) for item in results],
            [("25524", "葬送的芙莉莲")],
        )

        detail = await self.scraper.get_detail("25524")
        self.assertIsNotNone(detail)
        self.assertEqual(detail.type, "anime")
        self.assertEqual([item.number for item in detail.episodes], [1, 2])

        lines = await self.scraper.get_video_urls("25524", 1)
        self.assertEqual(
            [line.url for line in lines],
            [
                "https://media.example/one.mp4",
                "https://media.example/two.m3u8",
            ],
        )
        self.assertEqual([line.format for line in lines], ["mp4", "hls"])
        self.assertTrue(all(line.source_name == "girigiri" for line in lines))
        self.assertTrue(all("Referer" in line.headers for line in lines))

    async def test_latest_and_invalid_source_id(self):
        latest = await self.scraper.get_latest()
        self.assertEqual(latest[0].source_id, "25524")
        self.assertEqual(latest[0].cover_url, "https://giri.example/cover.webp")
        self.assertIsNone(await self.scraper.get_detail("https://evil.example/1"))
        self.assertEqual(
            await self.scraper.get_video_urls("../../internal", 1), []
        )


if __name__ == "__main__":
    unittest.main()
