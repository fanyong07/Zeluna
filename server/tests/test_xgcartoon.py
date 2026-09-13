import unittest

import httpx

from server.scrapers.anime.xgcartoon import XgCartoonScraper


class XgCartoonScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        detail_html = (
            '<div class="detail-right">'
            '<div class="detail-right__title"><h1>测试番剧 第1-2季</h1></div>'
            '<div class="detail-right__desc"><p>作品简介</p></div>'
            '<div class="detail-right__volumes"><div class="row">'
            '<div class="volume-title">第1季</div>'
            '<div><a class="goto-chapter" '
            'href="/user/page_direct?cartoon_id=test-anime&amp;chapter_id=s1e1">'
            '第01话</a></div>'
            '<div class="volume-title">第2季</div>'
            '<div><a class="goto-chapter" '
            'href="/user/page_direct?cartoon_id=test-anime&amp;chapter_id=s2e1">'
            '第01话</a></div>'
            '</div></div></div>'
        )

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/search":
                return httpx.Response(
                    200,
                    text=(
                        '<div class="topic-list-box">'
                        '<a href="/detail/test-anime">'
                        '<amp-img src="/cover.jpg"></amp-img>'
                        '<div class="topic-list-item__info">'
                        '<div>作者</div><div class="h3">测试番剧 第1-2季</div>'
                        '</div></a></div>'
                    ),
                )
            if request.url.path == "/detail/test-anime":
                return httpx.Response(200, text=detail_html)
            if request.url.path == "/video/test-anime/s2e1.html":
                return httpx.Response(
                    200,
                    text=(
                        '<div id="video_content"><iframe '
                        'src="https://player.example/player.htm?vid=media-2">'
                        '</iframe></div>'
                    ),
                )
            return httpx.Response(404)

        self.scraper = XgCartoonScraper(
            base_url="https://content.example",
            video_base_url="https://video.example",
            player_host="player.example",
            media_base_url="https://media.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_second_season_playback(self):
        results = await self.scraper.search("测试番剧 第二季")
        self.assertEqual(results[0].source_id, "test-anime@2")
        self.assertEqual(results[0].title, "测试番剧 第1-2季")

        detail = await self.scraper.get_detail("test-anime@2")
        self.assertIsNotNone(detail)
        self.assertEqual([item.number for item in detail.episodes], [1])
        self.assertEqual(detail.episodes[0].source_episode_id, "s2e1")

        lines = await self.scraper.get_video_urls("test-anime@2", 1)
        self.assertEqual(
            [line.url for line in lines],
            ["https://media.example/media-2/playlist.m3u8"],
        )
        self.assertEqual(lines[0].source_name, "xgcartoon")
        self.assertEqual(lines[0].headers["Referer"], (
            "https://video.example/video/test-anime/s2e1.html"
        ))

    async def test_invalid_ids_and_player_hosts_are_rejected(self):
        self.assertIsNone(await self.scraper.get_detail("../../internal"))
        self.assertEqual(await self.scraper.get_video_urls("test-anime@3", 1), [])
        self.assertEqual(XgCartoonScraper._requested_season("动画 Season 3"), 3)

class XgCartoonDynamicPlayerTests(unittest.IsolatedAsyncioTestCase):
    async def resolve(self, payload, *, status=200):
        calls = []

        def handler(request):
            calls.append(request.url)
            if request.url.path == "/video/cartoon/chapter-1.html":
                return httpx.Response(200, text=(
                    '<div id="video_content"><iframe id="xgct_player_iframe" '
                    'loading="lazy"></iframe></div>'
                ))
            if request.url.path == "/user/amp/content_pframe_url":
                self.assertEqual(request.url.params["chapter_id"], "chapter-1")
                self.assertEqual(request.url.params["level"], "middle")
                self.assertNotIn("Cookie", request.headers)
                return httpx.Response(status, json=payload)
            return httpx.Response(404)

        scraper = XgCartoonScraper(
            video_base_url="https://video.example", player_host="player.example",
            media_base_url="https://media.example", transport=httpx.MockTransport(handler),
        )
        try:
            line = await scraper._resolve_chapter("cartoon", 1, "chapter-1")
        finally:
            await scraper.aclose()
        return line, calls

    async def test_empty_dynamic_iframe_uses_public_site_endpoint(self):
        line, calls = await self.resolve({
            "result": True, "data": "https://player.example/pframe?vid=movie-1",
        })
        self.assertIsNotNone(line)
        self.assertEqual(line.url, "https://media.example/movie-1/playlist.m3u8")
        self.assertEqual(len(calls), 2)

    async def test_supports_current_object_response_without_executing_scripts(self):
        line, _ = await self.resolve({
            "result": True, "data": {"player_url": "https://player.example/pframe?vid=movie-2"},
        })
        self.assertIsNotNone(line)
        self.assertIn("movie-2/playlist.m3u8", line.url)

    async def test_denied_untrusted_invalid_and_non_https_results_stay_unavailable(self):
        for payload, status in [
            ({"result": False, "data": "https://player.example/pframe?vid=x"}, 200),
            ({"result": True, "data": "https://player.example/pframe?vid=x"}, 401),
            ({"result": True, "data": "https://127.0.0.1/pframe?vid=x"}, 200),
            ({"result": True, "data": "https://evil.example/pframe?vid=x"}, 200),
            ({"result": True, "data": "http://player.example/pframe?vid=x"}, 200),
            ({"result": True, "data": "https://player.example/pframe?vid=../../secret"}, 200),
            ({"result": True, "data": ["unexpected"]}, 200),
        ]:
            with self.subTest(status=status, data_type=type(payload["data"]).__name__):
                line, _ = await self.resolve(payload, status=status)
                self.assertIsNone(line)


if __name__ == "__main__":
    unittest.main()
