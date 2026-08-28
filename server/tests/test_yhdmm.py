import unittest

import httpx

from server.scrapers.anime.yhdmm import YhdmmScraper, relevance_ok
from server.scrapers.site_index import SiteIndex

SID = "82"

# 两条线路 × 三集。形态取自 2026-08-28 实测:/show/{sid}.html + /v/{sid}-{线}-{集}.html
_DETAIL_HTML = (
    "<html><head>"
    '<meta property="og:image" content="/upload/vod/cover.jpg">'
    "<title>死神 千年血战篇 - 樱花动漫</title></head><body>"
    "<h1>死神 千年血战篇</h1>"
    '<div class="anthology-list">'
    f'<a href="/v/{SID}-1-1.html">第01集</a>'
    f'<a href="/v/{SID}-1-2.html">第02集</a>'
    f'<a href="/v/{SID}-1-3.html">第03集</a>'
    f'<a href="/v/{SID}-2-1.html">HD中字</a>'
    f'<a href="/v/{SID}-2-2.html">HD中字</a>'
    f'<a href="/v/{SID}-2-3.html">HD中字</a>'
    "</div></body></html>"
)

_LIST_HTML = (
    f'<div class="item"><a href="/show/{SID}.html" title="死神 千年血战篇">'
    "<img src='/x.jpg'></a><span>更新至第13集</span></div>"
    '<div class="item"><a href="/show/91.html" title="葬送的芙莉莲">'
    "<img src='/y.jpg'></a></div>"
)


def _player_page(media_url: str, encrypt: int = 0) -> str:
    return (
        "<html><body><script>var player_aaaa="
        f'{{"flag":"play","encrypt":{encrypt},"url":"{media_url}"}}'
        "</script></body></html>"
    )


class _Handler:
    def __init__(self):
        self.calls: list[str] = []
        self.referers: list[str | None] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.calls.append(path)
        self.referers.append(request.headers.get("Referer"))
        if path == f"/show/{SID}.html":
            return httpx.Response(200, text=_DETAIL_HTML)
        if path in ("/", "/list/1.html"):
            return httpx.Response(200, text=_LIST_HTML)
        if path.startswith("/list/"):
            return httpx.Response(200, text=_LIST_HTML)  # 分页被缓存:同内容
        match = path.startswith(f"/v/{SID}-")
        if match:
            line = path.split("-")[1]
            return httpx.Response(
                200,
                text=_player_page(
                    f"https://fengbao12.com/{line}/index.m3u8"
                ),
            )
        return httpx.Response(404, text="")


def _scraper(handler: _Handler, **kwargs) -> YhdmmScraper:
    return YhdmmScraper(
        base_url="https://yhdmm.test",
        transport=httpx.MockTransport(handler),
        **kwargs,
    )


class YhdmmScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.handler = _Handler()
        self.scraper = _scraper(self.handler)

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_site_search_is_declared_unusable(self):
        # 该站搜索被边缘缓存冻结,必须走本地索引
        self.assertFalse(self.scraper.site_search_usable)

    async def test_search_lazily_builds_index_when_missing(self):
        # 空窗期(进程刚起、后台首轮重建未完成)应当场建一次索引
        results = await self.scraper.search("死神")
        self.assertTrue(self.handler.calls, "未尝试建索引")
        self.assertEqual(results[0].source_id, SID)
        self.assertIsNotNone(self.scraper.index)

    async def test_blank_keyword_issues_no_request(self):
        self.assertEqual(await self.scraper.search("   "), [])
        self.assertEqual(self.handler.calls, [])

    async def test_search_returns_empty_when_index_build_fails(self):
        def dead(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("boom", request=request)

        scraper = YhdmmScraper(
            base_url="https://yhdmm.test",
            transport=httpx.MockTransport(dead),
        )
        try:
            self.assertEqual(await scraper.search("死神"), [])
        finally:
            await scraper.aclose()

    async def test_search_uses_local_index(self):
        index = await self.scraper.build_local_index(pages=2)
        self.assertGreaterEqual(index.size, 2)
        results = await self.scraper.search("死神")
        self.assertEqual(results[0].source_id, SID)
        self.assertEqual(results[0].type, "anime")

    async def test_search_rejects_unrelated_keyword(self):
        await self.scraper.build_local_index(pages=1)
        self.assertEqual(await self.scraper.search("流浪地球"), [])

    async def test_detail_lists_episodes_from_all_lines(self):
        detail = await self.scraper.get_detail(SID)
        self.assertIsNotNone(detail)
        self.assertEqual(detail.title, "死神 千年血战篇")
        self.assertTrue(detail.cover_url.endswith("/upload/vod/cover.jpg"))
        self.assertEqual([e.number for e in detail.episodes], [1, 2, 3])

    async def test_video_urls_return_one_line_per_source_group(self):
        lines = await self.scraper.get_video_urls(SID, 2)
        # 两条线路 → 两个候选(冗余最大化);死链可自动换线
        self.assertEqual(len(lines), 2)
        self.assertEqual(
            sorted(line.url for line in lines),
            [
                "https://fengbao12.com/1/index.m3u8",
                "https://fengbao12.com/2/index.m3u8",
            ],
        )
        self.assertTrue(all(line.format == "hls" for line in lines))
        self.assertTrue(all(line.source_name == "yhdmm" for line in lines))

    async def test_referer_is_sent_to_play_page(self):
        await self.scraper.get_video_urls(SID, 1)
        play_referers = [
            ref for path, ref in zip(self.handler.calls, self.handler.referers)
            if path.startswith(f"/v/{SID}-")
        ]
        self.assertTrue(play_referers)
        self.assertTrue(
            all(ref == f"https://yhdmm.test/show/{SID}.html" for ref in play_referers)
        )

    async def test_unlabeled_line_falls_back_to_positional_pick(self):
        # 线路2 的标签全是 "HD中字",靠位置取第 3 个
        lines = await self.scraper.get_video_urls(SID, 3)
        self.assertEqual(len(lines), 2)

    async def test_out_of_range_episode_returns_empty(self):
        self.assertEqual(await self.scraper.get_video_urls(SID, 99), [])

    async def test_non_numeric_source_id_is_rejected(self):
        self.assertEqual(await self.scraper.get_video_urls("abc", 1), [])
        self.assertIsNone(await self.scraper.get_detail("abc"))

    async def test_encrypted_player_url_is_decoded(self):
        import base64

        media = "https://fengbao12.com/enc/index.m3u8"
        encoded = base64.b64encode(media.encode()).decode()

        class EncHandler(_Handler):
            def __call__(self, request: httpx.Request) -> httpx.Response:
                if request.url.path.startswith(f"/v/{SID}-"):
                    self.calls.append(request.url.path)
                    return httpx.Response(200, text=_player_page(encoded, encrypt=2))
                return super().__call__(request)

        scraper = _scraper(EncHandler())
        try:
            lines = await scraper.get_video_urls(SID, 1)
        finally:
            await scraper.aclose()
        self.assertTrue(all(line.url == media for line in lines))

    async def test_injected_index_is_used_directly(self):
        index = SiteIndex(site="yhdmm")
        index.add(SID, "死神 千年血战篇")
        scraper = _scraper(_Handler(), index=index)
        try:
            results = await scraper.search("死神 千年血战篇")
        finally:
            await scraper.aclose()
        self.assertEqual(results[0].source_id, SID)


class RelevanceTests(unittest.TestCase):
    def test_containment_counts_as_relevant(self):
        self.assertTrue(relevance_ok("死神", "死神 千年血战篇"))
        self.assertTrue(relevance_ok("死神 千年血战篇 更新至第13集", "死神 千年血战篇"))

    def test_unrelated_titles_rejected(self):
        self.assertFalse(relevance_ok("流浪地球", "死神 千年血战篇"))
        self.assertFalse(relevance_ok("", "死神"))


if __name__ == "__main__":
    unittest.main()
