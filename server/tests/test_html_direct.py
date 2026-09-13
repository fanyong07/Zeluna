import asyncio
import json
import unittest
from unittest.mock import patch

import httpx

from server.scrapers.anime.html_direct import (
    HTML_DIRECT_ANIME_SITES,
    HtmlDirectAnimeScraper,
    HtmlDirectSite,
    OriginSearchThrottledError,
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

    async def test_registry_preserves_existing_sites_and_adds_xifan(self):
        scrapers = create_html_direct_anime_scrapers()
        try:
            self.assertEqual(set(scrapers), {"jibi", "yinghua2", "wedm", "xifan"})
        finally:
            await asyncio.gather(*(scraper.aclose() for scraper in scrapers.values()))

    def test_structured_player_does_not_leak_next_episode_or_ad_urls(self):
        for ending in ("", ";", "; const after = 1;"):
            with self.subTest(ending=ending):
                player = {
                    "encrypt": 0,
                    "vod_data": {"vod_name": "作品名"},
                    "url": "https://media.example/ep1.mp4",
                    "url_next": "https://media.example/ep2.mp4",
                }
                text = (
                    f"<script>var player_aaaa={json.dumps(player)}{ending}</script>"
                    '<script>const ad="https://ads.example/ad.mp4";</script>'
                )
                self.assertEqual(
                    self.scraper._player_urls(text), ["https://media.example/ep1.mp4"]
                )

    def test_unresolved_current_episode_must_not_fall_back_to_next_episode(self):
        for current in ("", "https://site.example/player.html?id=1"):
            player = {"url": current, "url_next": "https://media.example/ep2.mp4"}
            self.assertEqual(
                self.scraper._player_urls(
                    f"<script>var player_aaaa={json.dumps(player)};</script>"
                ),
                [],
            )

    async def test_one_play_page_timeout_does_not_discard_other_routes(self):
        original_handler = self.scraper._client._transport.handler

        def handler(request):
            if request.url.path == "/play/10-1-1.html":
                raise httpx.ReadTimeout("transient", request=request)
            return original_handler(request)

        self.scraper._client._transport.handler = handler
        lines = await self.scraper.get_video_urls("detail/10.html", 1)
        self.assertEqual(
            [line.url for line in lines], ["https://media.example/two.mp4"]
        )

    async def test_xifan_uses_only_origin_and_keeps_two_independent_line_ids(self):
        from server.aggregator import AggregatedVideoLine, _crawler_line_source
        from server.playback import PlaybackService

        site = next(site for site in HTML_DIRECT_ANIME_SITES if site.key == "xifan")
        calls = []

        def handler(request):
            self.assertEqual(request.url.host, "dm1.xfdm.pro")
            calls.append(request.url.path)
            if request.url.path == "/search.html":
                return httpx.Response(
                    200,
                    text=(
                        '<div class="search-box"><a class="public-list-exp" href="/bangumi/44.html">'
                        '<img data-src="/cover.jpg"></a><div class="thumb-txt">葬送的芙莉莲</div></div>'
                        '<a href="/bangumi/unrelated.html">推荐其他作品</a>'
                    ),
                )
            if request.url.path == "/bangumi/44.html":
                return httpx.Response(
                    200,
                    text=(
                        '<h3 class="slide-info-title">葬送的芙莉莲</h3>'
                        '<ul class="anthology-list-play"><li><a href="/watch/44/1/1.html">第01集</a></li>'
                        '<li><a href="/watch/44/1/2.html">第02集</a></li></ul>'
                        '<ul class="anthology-list-play"><li><a href="/watch/44/2/1.html">第01集</a></li></ul>'
                    ),
                )
            if request.url.path.startswith("/watch/44/"):
                route = request.url.path.split("/")[3]
                return httpx.Response(
                    200,
                    text="<script>var player_aaaa="
                    + json.dumps(
                        {
                            "url": f"https://media.example/route{route}/ep1.mp4",
                            "url_next": f"https://media.example/route{route}/ep2.mp4",
                            "vod_data": {"vod_name": "葬送的芙莉莲"},
                        }
                    )
                    + ";</script>",
                )
            raise AssertionError(f"Unexpected origin path: {request.url.path}")

        scraper = HtmlDirectAnimeScraper(site, transport=httpx.MockTransport(handler))
        try:
            results = await scraper.search("葬送的芙莉莲")
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0].title, "葬送的芙莉莲")
            self.assertEqual(results[0].cover_url, "https://dm1.xfdm.pro/cover.jpg")
            detail = await scraper.get_detail(results[0].source_id)
            self.assertEqual(detail.title, "葬送的芙莉莲")
            self.assertEqual([ep.number for ep in detail.episodes], [1, 2])
            lines = await scraper.get_video_urls(results[0].source_id, 1)
            self.assertEqual(len(lines), 2)
            self.assertTrue(all(line.url.endswith("/ep1.mp4") for line in lines))
            payloads = [
                PlaybackService()._line_dict(
                    AggregatedVideoLine(
                        url=line.url,
                        title=line.title,
                        source=_crawler_line_source("xifan", line.source_name),
                        verification_status="client_probe_required",
                    )
                )
                for line in lines
            ]
            self.assertEqual(len({row["provider_id"] for row in payloads}), 2)
            self.assertEqual(calls.count("/search.html"), 1)
        finally:
            await scraper.aclose()

    async def test_xifan_search_respects_interval_and_reuses_positive_metadata(self):
        site = next(site for site in HTML_DIRECT_ANIME_SITES if site.key == "xifan")
        now = [100.0]
        request_times = []

        def handler(request):
            request_times.append(now[0])
            now[0] += 0.1
            return httpx.Response(
                200,
                text=(
                    '<div class="search-box"><a class="public-list-exp" href="/bangumi/44.html"></a>'
                    '<div class="thumb-txt">Frieren</div></div>'
                ),
            )

        async def sleep(delay):
            now[0] += delay

        scraper = HtmlDirectAnimeScraper(site, transport=httpx.MockTransport(handler))
        try:
            with (
                patch(
                    "server.scrapers.anime.html_direct.time.monotonic",
                    side_effect=lambda: now[0],
                ),
                patch(
                    "server.scrapers.anime.html_direct.asyncio.sleep", side_effect=sleep
                ),
            ):
                first = await scraper.search("first")
                await scraper.search("second")
                cached = await scraper.search("first")
                self.assertEqual(first, cached)
                self.assertEqual(len(request_times), 2)
                self.assertGreaterEqual(
                    request_times[1] - request_times[0],
                    site.search_interval_seconds - 0.001,
                )
                now[0] += 61
                await scraper.search("first")
                self.assertEqual(len(request_times), 3)
        finally:
            await scraper.aclose()

    async def test_search_throttling_is_not_a_cached_catalog_miss(self):
        from server.aggregator import RATE_LIMITED, _classify_resolution_exception

        site = next(site for site in HTML_DIRECT_ANIME_SITES if site.key == "xifan")
        calls = []

        def handler(request):
            calls.append(request)
            if len(calls) == 1:
                return httpx.Response(200, text="请不要频繁操作，搜索时间间隔为3秒")
            return httpx.Response(
                200,
                text=(
                    '<div class="search-box"><a class="public-list-exp" href="/bangumi/44.html"></a>'
                    '<div class="thumb-txt">Frieren</div></div>'
                ),
            )

        scraper = HtmlDirectAnimeScraper(site, transport=httpx.MockTransport(handler))
        try:
            with self.assertRaises(OriginSearchThrottledError) as context:
                await scraper.search("Frieren")
            self.assertEqual(
                _classify_resolution_exception(context.exception), RATE_LIMITED
            )
            with patch("server.scrapers.anime.html_direct.asyncio.sleep"):
                results = await scraper.search("Frieren")
            self.assertEqual(len(results), 1)
            self.assertEqual(len(calls), 2)
        finally:
            await scraper.aclose()

    async def test_partial_episode_lists_keep_route_identity_and_ignore_foreign_pages(
        self,
    ):
        site = next(site for site in HTML_DIRECT_ANIME_SITES if site.key == "xifan")
        calls = []

        def handler(request):
            calls.append(request.url.path)
            self.assertEqual(request.url.host, "dm1.xfdm.pro")
            if request.url.path == "/bangumi/44.html":
                return httpx.Response(
                    200,
                    text=(
                        '<ul class="anthology-list-play"><a href="/watch/44/1/1.html">第01集</a></ul>'
                        '<ul class="anthology-list-play"><a href="/watch/44/2/2.html">第02集</a></ul>'
                        '<ul class="anthology-list-play"><a href="https://foreign.example/play">第02集</a></ul>'
                    ),
                )
            return httpx.Response(
                200,
                text=(
                    '<script>var player_aaaa={"url":"https://media.example/ep2.mp4"};</script>'
                ),
            )

        scraper = HtmlDirectAnimeScraper(site, transport=httpx.MockTransport(handler))
        try:
            lines = await scraper.get_video_urls("bangumi/44.html", 2)
            self.assertEqual(len(lines), 1)
            self.assertEqual(lines[0].source_name, "xifan:xifan-2")
            self.assertEqual(calls, ["/bangumi/44.html", "/watch/44/2/2.html"])
        finally:
            await scraper.aclose()


if __name__ == "__main__":
    unittest.main()
