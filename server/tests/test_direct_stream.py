import unittest

import httpx

from server.scrapers.direct_stream import DbkuScraper, NivodScraper, PpnixScraper


class NivodScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def handler(request: httpx.Request) -> httpx.Response:
            path = request.url.path
            if path.startswith("/s/"):
                return httpx.Response(
                    200,
                    text=(
                        '<div class="module-card-item">'
                        '<div class="module-card-item-class">剧集</div>'
                        '<a href="/nivod/10/"><img alt="庆余年 第一季" '
                        'data-original="/cover.jpg"></a>'
                        '<div class="module-card-item-title">庆余年 第一季</div>'
                        '<div class="module-item-note">46集全</div>'
                        '<div class="module-info-item-content">2019 / 大陆</div>'
                        '</div>'
                    ),
                )
            if path == "/nivod/10/":
                return httpx.Response(
                    200,
                    text=(
                        '<meta property="og:image" content="/cover.jpg">'
                        '<meta name="description" content="简介">'
                        '<h1>庆余年 第一季</h1>'
                        '<div class="module-info-heading">2019 大陆</div>'
                        '<div class="module-info-introduction">完整简介</div>'
                        '<div class="module-tab-item">自营4K <span>2</span></div>'
                        '<div class="module-tab-item">全球线 <span>2</span></div>'
                        '<a href="/niplay/10-1-1/">1</a>'
                        '<a href="/niplay/10-1-2/">2</a>'
                        '<a href="/niplay/10-2-1/">第01集</a>'
                        '<a href="/niplay/10-2-2/">第02集</a>'
                    ),
                )
            if path == "/niplay/10-1-1/":
                return httpx.Response(
                    200,
                    text=(
                        '<script>var player_aaaa={"encrypt":0,'
                        '"url":"https://media.example/one.m3u8"}</script>'
                    ),
                )
            if path == "/niplay/10-2-1/":
                return httpx.Response(
                    200,
                    text=(
                        '<script>var player_aaaa={"encrypt":0,'
                        '"url":"https://media.example/two.m3u8"}</script>'
                    ),
                )
            return httpx.Response(404)

        self.scraper = NivodScraper(
            base_url="https://nivod.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_all_episode_lines(self):
        results = await self.scraper.search("庆余年")
        self.assertEqual(results[0].source_id, "tv:10")
        self.assertEqual(results[0].type, "tv")
        self.assertEqual(results[0].year, 2019)
        self.assertEqual(results[0].episode_count, 46)

        detail = await self.scraper.get_detail("tv:10")
        self.assertIsNotNone(detail)
        self.assertEqual(detail.title, "庆余年 第一季")
        self.assertEqual([item.number for item in detail.episodes], [1, 2])

        lines = await self.scraper.get_video_urls("tv:10", 1)
        self.assertEqual(
            [line.url for line in lines],
            [
                "https://media.example/one.m3u8",
                "https://media.example/two.m3u8",
            ],
        )
        self.assertEqual(lines[0].quality, "4K")
        self.assertTrue(all(line.headers["Origin"] == "https://nivod.example" for line in lines))

    async def test_invalid_source_id_is_rejected(self):
        self.assertIsNone(await self.scraper.get_detail("https://private.example/"))
        self.assertEqual(await self.scraper.get_video_urls("tv:../10", 1), [])


class DbkuScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def handler(request: httpx.Request) -> httpx.Response:
            path = request.url.path
            if path.startswith("/vodsearch/"):
                return httpx.Response(
                    200,
                    text=(
                        '<li class="clearfix"><div class="thumb">'
                        '<a class="myui-vodlist__thumb" href="/voddetail/30.html" '
                        'title="庆余年" data-original="/cover.jpg">'
                        '<span class="pic-text">全46集</span></a></div>'
                        '<div class="detail"><h4 class="title">庆余年</h4>'
                        '<p>分类：陆剧 地区：大陆 年份：2019</p></div></li>'
                    ),
                )
            if path == "/voddetail/30.html":
                return httpx.Response(
                    200,
                    text=(
                        '<meta name="description" content="完整简介">'
                        '<h1>庆余年</h1>'
                        '<div class="myui-content__detail">分类：陆剧 年份：2019</div>'
                        '<div class="myui-content__thumb"><img data-original="/cover.jpg"></div>'
                        '<div class="myui-content__list">'
                        '<a href="/vodplay/30-1-1.html">第1集</a>'
                        '<a href="/vodplay/30-1-2.html">第2集</a>'
                        '</div>'
                    ),
                )
            if path == "/vodplay/30-1-1.html":
                return httpx.Response(
                    200,
                    text=(
                        '<script>window.adsbygoogle=[];</script>'
                        '<script>var player_aaaa={"encrypt":2,'
                        '"url":"aHR0cHM6Ly9tZWRpYS5leGFtcGxlL2Ria3UubTN1OA=="}</script>'
                    ),
                )
            return httpx.Response(404)

        self.scraper = DbkuScraper(
            base_url="https://dbku.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_ad_page_direct_manifest(self):
        results = await self.scraper.search("庆余年")
        self.assertEqual(results[0].source_id, "tv:30")
        self.assertEqual(results[0].type, "tv")
        self.assertEqual(results[0].year, 2019)
        self.assertEqual(results[0].episode_count, 46)

        detail = await self.scraper.get_detail("tv:30")
        self.assertIsNotNone(detail)
        self.assertEqual(detail.title, "庆余年")
        self.assertEqual([item.number for item in detail.episodes], [1, 2])

        lines = await self.scraper.get_video_urls("tv:30", 1)
        self.assertEqual(lines[0].url, "https://media.example/dbku.m3u8")
        self.assertEqual(lines[0].format, "hls")
        self.assertEqual(lines[0].headers["Origin"], "https://dbku.example")

    async def test_invalid_source_id_is_rejected(self):
        self.assertIsNone(await self.scraper.get_detail("tv:../30"))
        self.assertEqual(await self.scraper.get_video_urls("movie:https://x", 1), [])


class PpnixScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        def handler(request: httpx.Request) -> httpx.Response:
            path = request.url.path
            if path.startswith("/cn/search/"):
                return httpx.Response(
                    200,
                    text=(
                        '<ul><li><a href="/cn/tv/20.html">'
                        '<img class="thumb" alt="庆余年 第一季" src="/cover.jpg">'
                        '</a><h2>庆余年 第一季</h2><span>2019</span></li></ul>'
                    ),
                )
            if path == "/cn/tv/20.html":
                return httpx.Response(
                    200,
                    text=(
                        '<meta name="description" content="完整简介">'
                        '<header><img alt="PPnix" src="/logo.svg"></header>'
                        '<h1 class="product-title">庆余年 第一季 '
                        '<span>(2019)</span><span class="rate">8.2</span></h1>'
                        '<img class="thumb" alt="庆余年 第一季" src="/cover.jpg">'
                        "<script>classid=2;infoid=20;m3u8=['1','2']</script>"
                    ),
                )
            return httpx.Response(404)

        self.scraper = PpnixScraper(
            base_url="https://ppnix.example",
            transport=httpx.MockTransport(handler),
        )

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_detail_and_direct_manifest(self):
        results = await self.scraper.search("庆余年")
        self.assertEqual(results[0].source_id, "tv:20")
        self.assertEqual(results[0].type, "tv")
        self.assertEqual(results[0].year, 2019)

        detail = await self.scraper.get_detail("tv:20")
        self.assertIsNotNone(detail)
        self.assertEqual(detail.title, "庆余年 第一季")
        self.assertEqual(detail.cover_url, "https://ppnix.example/cover.jpg")
        self.assertEqual([item.number for item in detail.episodes], [1, 2])

        lines = await self.scraper.get_video_urls("tv:20", 2)
        self.assertEqual(
            lines[0].url,
            "https://ppnix.example/info/m3u8/20/2.m3u8",
        )
        self.assertEqual(lines[0].headers["Referer"], "https://ppnix.example/cn/tv/20.html")

    async def test_invalid_source_id_and_episode_are_rejected(self):
        self.assertIsNone(await self.scraper.get_detail("movie:../20"))
        self.assertEqual(await self.scraper.get_video_urls("tv:20", 3), [])


if __name__ == "__main__":
    unittest.main()
