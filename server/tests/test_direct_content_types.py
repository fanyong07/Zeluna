"""Origin content, not an adapter's directory name, controls discovery."""

import unittest
from dataclasses import replace
from unittest.mock import AsyncMock

import httpx

from server.aggregator import ContentAggregator
from server.scrapers.anime.girigiri import GiriGiriScraper
from server.scrapers.anime.html_direct import (
    HTML_DIRECT_ANIME_SITES,
    HtmlDirectAnimeScraper,
)
from server.scrapers.anime.xgcartoon import XgCartoonScraper
from server.scrapers.anime.yhdmm import YhdmmScraper
from server.scrapers.base import SubjectResult
from server.scrapers.site_index import SiteIndex

PROVIDERS = ("xifan", "xgcartoon", "girigiri", "yhdmm")
TITLE = "同名测试作品"


def make_scraper(
    provider, category="", *, title=TITLE, year=2023, search_metadata=True
):
    calls = []
    metadata = (
        f'<p class="data">类型：<a href="/list/4.html">{category}</a></p>'
        f'<span class="slide-info-remarks">{year}</span>'
    )
    detail = (
        '<nav><a href="/movie">电影</a><a href="/tv">电视剧</a></nav>'
        f'<h1 class="slide-info-title h1">{title}</h1>'
        f'<div class="detail-info">{metadata}</div>'
        '<p class="summary">演员谈电影、电视剧的故事，不是分类。</p>'
        '<div class="anthology-list-play anthology-list-box">'
        '<a href="/v/82-1-1.html">第01集</a>'
        '<a href="/playGV82-1-1/">第01集</a></div>'
    )

    def handler(request):
        calls.append(request.url.path)
        if request.url.path == "/ajax/suggest":
            row = {"id": 82, "name": title, "pic": "/cover.jpg"}
            if search_metadata:
                row.update(type_name=category, vod_year=year)
            return httpx.Response(200, json={"list": [row]})
        if request.url.path in {"/search", "/search.html"}:
            data = metadata if search_metadata else ""
            return httpx.Response(
                200,
                text=(
                    "<nav><a>电影</a><a>电视剧</a></nav>"
                    '<div class="search-box topic-list-box">'
                    '<a class="public-list-exp" href="/detail/82">'
                    f'<div class="topic-list-item__info"><h3 class="h3 thumb-txt">{title}</h3></div>'
                    f"</a>{data}</div>"
                ),
            )
        return httpx.Response(200, text=detail)

    transport = httpx.MockTransport(handler)
    if provider == "xifan":
        site = replace(
            next(s for s in HTML_DIRECT_ANIME_SITES if s.key == provider),
            search_interval_seconds=0,
        )
        scraper = HtmlDirectAnimeScraper(site, transport=transport)
    elif provider == "xgcartoon":
        scraper = XgCartoonScraper(transport=transport)
    elif provider == "girigiri":
        scraper = GiriGiriScraper(transport=transport)
    else:
        index = SiteIndex(site="yhdmm")
        index.add("82", title)
        scraper = YhdmmScraper(transport=transport, index=index)
    return scraper, calls


class DirectContentDiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.aggregator = ContentAggregator(
            crawler_scrapers={}, resolver_search_enabled=False
        )

    async def asyncTearDown(self):
        await self.aggregator.aclose()

    async def test_movie_and_series_are_not_skipped_before_search(self):
        for provider in PROVIDERS:
            scraper, _ = make_scraper(provider)
            try:
                for kind, result_type in (
                    ("movie", "movie"),
                    ("series", "tv"),
                    ("anime", "anime"),
                ):
                    with self.subTest(provider=provider, kind=kind):
                        scraper.search = AsyncMock(
                            return_value=[
                                SubjectResult(
                                    source_id="82",
                                    title=TITLE,
                                    type=result_type,
                                    year=2023,
                                )
                            ]
                        )
                        matches = await self.aggregator._discover_scraper_matches(
                            provider, scraper, [TITLE], content_type=kind, year=2023
                        )
                        self.assertEqual(scraper.search.await_count, 1)
                        self.assertEqual(len(matches), 1)
            finally:
                await scraper.aclose()

    async def test_actual_search_detail_and_discovery_classify_origin_content(self):
        for provider in PROVIDERS:
            for category, kind, expected in (
                ("动漫电影", "movie", "movie"),
                ("国产剧", "series", "tv"),
                ("TV动画", "anime", "anime"),
            ):
                with self.subTest(provider=provider, category=category):
                    scraper, calls = make_scraper(provider, category)
                    try:
                        results = await scraper.search(TITLE)
                        self.assertEqual(len(results), 1)
                        detail = await scraper.get_detail(results[0].source_id)
                        self.assertEqual(detail.type, expected)
                        self.assertEqual(detail.year, 2023)
                        matches = await self.aggregator._discover_scraper_matches(
                            provider, scraper, [TITLE], content_type=kind, year=2023
                        )
                        self.assertEqual(len(matches), 1)
                        self.assertEqual(matches[0].content_type, expected)
                        self.assertTrue(calls)
                    finally:
                        await scraper.aclose()

    async def test_sparse_suggest_and_index_results_use_detail_type(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                scraper, calls = make_scraper(provider, "日本剧", search_metadata=False)
                try:
                    matches = await self.aggregator._discover_scraper_matches(
                        provider, scraper, [TITLE], content_type="series", year=2023
                    )
                    self.assertEqual(len(matches), 1)
                    self.assertEqual(matches[0].content_type, "tv")
                    self.assertTrue(any("82" in p for p in calls))
                finally:
                    await scraper.aclose()

    async def test_unrelated_navigation_and_summary_do_not_classify_results(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                scraper, _ = make_scraper(provider)
                try:
                    result = (await scraper.search(TITLE))[0]
                    detail = await scraper.get_detail(result.source_id)
                    self.assertEqual(result.type, "anime")
                    self.assertEqual(detail.type, "anime")
                finally:
                    await scraper.aclose()


class DirectContentIdentityGuardTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.aggregator = ContentAggregator(
            crawler_scrapers={}, resolver_search_enabled=False
        )

    async def asyncTearDown(self):
        await self.aggregator.aclose()

    async def test_explicit_type_year_and_season_conflicts_are_rejected(self):
        for provider in PROVIDERS:
            cases = (
                ("TV动画", "movie", 2023, TITLE),
                ("国产剧", "anime", 2023, TITLE),
                ("国产剧", "movie", 2023, TITLE),
                ("真人电影", "anime", 2023, TITLE),
                ("电影解说", "movie", 2023, TITLE),
                ("动漫电影", "movie", 1990, TITLE),
                ("日本剧", "series", 2023, TITLE + " 第二季"),
            )
            for category, kind, expected_year, alias in cases:
                with self.subTest(
                    provider=provider, category=category, kind=kind, alias=alias
                ):
                    title = TITLE + " 第一季" if "第二季" in alias else TITLE
                    scraper, _ = make_scraper(provider, category, title=title)
                    try:
                        matches = await self.aggregator._discover_scraper_matches(
                            provider,
                            scraper,
                            [alias, TITLE],
                            content_type=kind,
                            year=expected_year,
                        )
                        self.assertEqual(matches, [])
                    finally:
                        await scraper.aclose()

    async def test_missing_category_is_not_a_movie_or_live_series_claim(self):
        for provider in PROVIDERS:
            scraper, _ = make_scraper(provider)
            try:
                for kind in ("movie", "series"):
                    with self.subTest(provider=provider, kind=kind):
                        self.assertEqual(
                            await self.aggregator._discover_scraper_matches(
                                provider, scraper, [TITLE], content_type=kind, year=2023
                            ),
                            [],
                        )
            finally:
                await scraper.aclose()

    async def test_metadata_detail_budget_is_shared_across_aliases(self):
        from server.scrapers.content_identity import classify_content

        scraper, _ = make_scraper("girigiri")
        scraper.search = AsyncMock(
            return_value=[
                SubjectResult(
                    source_id=str(n),
                    title=TITLE,
                    type="anime",
                    extra=classify_content(TITLE).extra(),
                )
                for n in range(12)
            ]
        )
        scraper.get_detail = AsyncMock(
            side_effect=httpx.ReadTimeout("metadata unavailable")
        )
        try:
            self.assertEqual(
                await self.aggregator._discover_scraper_matches(
                    "girigiri",
                    scraper,
                    [TITLE, TITLE + " 第二季", TITLE + " 国语"],
                    content_type="movie",
                    year=2023,
                ),
                [],
            )
            self.assertEqual(scraper.get_detail.await_count, 3)
        finally:
            await scraper.aclose()

    async def test_wrong_detail_title_does_not_borrow_a_valid_movie_category(self):
        from server.scrapers.base import SubjectDetail
        from server.scrapers.content_identity import classify_content

        scraper, _ = make_scraper("girigiri")
        scraper.search = AsyncMock(
            return_value=[
                SubjectResult(
                    source_id="82",
                    title=TITLE,
                    type="anime",
                    extra=classify_content(TITLE).extra(),
                )
            ]
        )
        scraper.get_detail = AsyncMock(
            return_value=SubjectDetail(
                source_id="82",
                title="另一部完全无关作品",
                type="movie",
                year=2023,
                extra=classify_content("另一部完全无关作品", ["动漫电影"]).extra(),
            )
        )
        try:
            self.assertEqual(
                await self.aggregator._discover_scraper_matches(
                    "girigiri", scraper, [TITLE], content_type="movie", year=2023
                ),
                [],
            )
        finally:
            await scraper.aclose()


class ContentClassificationTests(unittest.TestCase):
    def test_movie_format_has_priority_without_losing_animation_attribute(self):
        from server.scrapers.content_identity import classify_content
        from server.scrapers.maccms import media_type_from_name

        for label in ("动画电影", "动漫电影", "剧场版", "劇場版"):
            with self.subTest(label=label):
                identity = classify_content(TITLE, [label])
                self.assertEqual(identity.type, "movie")
                self.assertTrue(identity.animation)
                self.assertEqual(media_type_from_name(label), "movie")
        self.assertEqual(classify_content(TITLE, ["TV动画"]).media_format, "series")
        self.assertEqual(classify_content(TITLE, ["日本剧"]).type, "tv")
        self.assertEqual(classify_content(TITLE, ["综艺"]).type, "tv")
        self.assertEqual(classify_content(TITLE, ["特摄"]).type, "tv")
        self.assertEqual(classify_content(TITLE, ["特摄电影"]).type, "movie")

    def test_explicit_edition_marker_is_not_an_ordinary_title_keyword(self):
        from server.scrapers.content_identity import classify_content

        self.assertEqual(classify_content("测试 剧场版").type, "movie")
        self.assertEqual(classify_content("电影少女").type, "anime")
        self.assertEqual(classify_content("电视剧创作部").type, "anime")

    def test_only_selected_navigation_category_can_describe_detail(self):
        from bs4 import BeautifulSoup
        from server.scrapers.content_identity import identity_from_html

        soup = BeautifulSoup(
            '<div class="head-nav"><a>电影</a>'
            '<a class="current">日番</a><a>电视剧</a></div>',
            "lxml",
        )
        self.assertEqual(identity_from_html(soup, TITLE, detail=True).type, "anime")
        self.assertEqual(identity_from_html(soup, TITLE).evidence, "default")


class SparseIdentityRegressionTests(unittest.IsolatedAsyncioTestCase):
    async def test_title_only_movie_hit_checks_available_detail_year(self):
        from server.scrapers.base import SubjectDetail
        from server.scrapers.content_identity import classify_content

        title = "电影样本 剧场版"
        scraper, _ = make_scraper("girigiri")
        scraper.search = AsyncMock(
            return_value=[
                SubjectResult(
                    source_id="82",
                    title=title,
                    type="movie",
                    extra=classify_content(title).extra(),
                )
            ]
        )
        identity = classify_content(title, ["动画电影"], year=2001)
        scraper.get_detail = AsyncMock(
            return_value=SubjectDetail(
                source_id="82",
                title=title,
                type=identity.type,
                year=identity.year,
                extra=identity.extra(),
            )
        )
        aggregator = ContentAggregator(
            crawler_scrapers={}, resolver_search_enabled=False
        )
        try:
            self.assertEqual(
                await aggregator._discover_scraper_matches(
                    "girigiri", scraper, [title], content_type="movie", year=2023
                ),
                [],
            )
            scraper.get_detail.assert_awaited_once()
        finally:
            await scraper.aclose()
            await aggregator.aclose()

    async def test_yhdmm_detail_uses_content_heading_not_blank_logo_heading(self):
        def handler(request):
            return httpx.Response(
                200,
                text=(
                    "<title>《紫罗兰永恒花园剧场版》动漫全集高清免费在线观看 - 樱花动漫</title>"
                    '<h1 class="navbar-brand">\n<a href="/"><img alt="樱花动漫"></a>\n</h1>'
                    '<div class="detail-info"><div class="detail-header">'
                    "<h2>紫罗兰永恒花园剧场版<small>正片</small></h2></div>"
                    "<p>类型：动漫电影</p><p>年份：2020</p></div>"
                    '<a href="/v/18917-1-1.html">HD中字</a>'
                ),
            )

        scraper = YhdmmScraper(transport=httpx.MockTransport(handler))
        try:
            detail = await scraper.get_detail("18917")
            self.assertEqual(detail.title, "紫罗兰永恒花园剧场版")
            self.assertEqual(detail.type, "movie")
            self.assertEqual(detail.year, 2020)
        finally:
            await scraper.aclose()


class MovieVersionTests(unittest.IsolatedAsyncioTestCase):
    async def test_full_movie_quality_versions_remain_episode_one_and_keep_routes(self):
        labels = ("HD中字", "1080P", "4K国语")
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                calls = []

                def handler(request):
                    path = request.url.path
                    calls.append(path)
                    if path.startswith(("/v/82-", "/playGV82-")):
                        token = path.rsplit("/", 1)[-1] or path.split("/")[-2]
                        return httpx.Response(
                            200,
                            text=(
                                '<script>var player_aaaa={"encrypt":0,"url":'
                                f'"https://media.test/{token}.m3u8"' + "}</script>"
                            ),
                        )
                    if path.startswith("/video/"):
                        return httpx.Response(
                            200,
                            text=(
                                f'<iframe src="https://pframe.xgcartoon.com/player?vid={path.rsplit("/", 1)[-1].split(".")[0]}"></iframe>'
                            ),
                        )
                    episodes = "".join(
                        f'<a href="/v/82-1-{n}.html">{label}</a>'
                        for n, label in enumerate(labels, 1)
                    )
                    if provider == "girigiri":
                        episodes = "".join(
                            f'<a href="/playGV82-1-{n}/">{label}</a>'
                            for n, label in enumerate(labels, 1)
                        )
                    volume = (
                        '<div class="detail-right__volumes"><div class="row">'
                        '<div class="volume-title">电影</div>'
                        + "".join(
                            f'<div><a class="goto-chapter" href="/user/page_direct?cartoon_id=82&amp;chapter_id=v{n}">{label}</a></div>'
                            for n, label in enumerate(labels, 1)
                        )
                        + "</div></div>"
                    )
                    return httpx.Response(
                        200,
                        text=(
                            '<h1 class="slide-info-title h1">电影样本</h1>'
                            '<div class="detail-info"><p>类型：动漫电影</p></div>'
                            f'<div class="anthology-list-play anthology-list-box">{episodes}</div>{volume}'
                        ),
                    )

                transport = httpx.MockTransport(handler)
                if provider == "xifan":
                    scraper = HtmlDirectAnimeScraper(
                        next(s for s in HTML_DIRECT_ANIME_SITES if s.key == provider),
                        transport=transport,
                    )
                    sid = "detail/82"
                elif provider == "girigiri":
                    scraper = GiriGiriScraper(transport=transport)
                    sid = "82"
                elif provider == "yhdmm":
                    scraper = YhdmmScraper(transport=transport)
                    sid = "82"
                else:
                    scraper = XgCartoonScraper(transport=transport)
                    sid = "82@1"
                try:
                    detail = await scraper.get_detail(sid)
                    self.assertEqual([e.number for e in detail.episodes], [1])
                    lines = await scraper.get_video_urls(sid, 1)
                    self.assertEqual(len(lines), 3)
                    self.assertEqual(await scraper.get_video_urls(sid, 2), [])
                finally:
                    await scraper.aclose()
