"""Self-contained offline coverage for subscription parsing and all three engines."""
from __future__ import annotations

import asyncio
import base64
import copy
import json
import unittest
from dataclasses import fields, is_dataclass, replace
from urllib.parse import quote

import httpx
import pytest

from server.scrapers.anime.animeko import AnimekoScraper
from server.scrapers.anime.animeko_engines import (
    HttpFetcher, JsonApiEngine, RssEngine, SelectorEngine, SourceBlockedError,
    SourceUnavailableError,
    detect_block_reason, extract_media_urls, json_path_values, parse_html,
    parse_rss_items, select_elements,
)
from server.scrapers.anime.animeko_rules import (
    MatchVideoConfig, RuleRepository, compile_rule_pattern,
    parse_media_source, parse_subscription_payload, rewrite_azusa_named_groups,
)


def selector_payload(source_id="fixture", host="fixture.test"):
    return {
        "id": source_id, "factoryId": "web-selector", "version": 1,
        "arguments": {"name": "测试动漫", "searchConfig": {
            "searchUrl": f"https://{host}/search?q={{keyword}}",
            "rawBaseUrl": f"https://{host}", "requestInterval": 0,
            "subjectFormatId": "a",
            "selectorSubjectFormatA": {"selectLists": ".results a"},
            "channelFormatId": "no-channel",
            "selectorChannelFormatNoChannel": {
                "selectEpisodes": ".episodes a",
                "matchEpisodeSortFromName": r"第(?<ep>\d+)话",
            },
            "matchVideo": {
                "enableNestedUrl": False,
                "matchVideoUrl": r"^https://media\.test/.*\.(mp4|m3u8)(\?.*)?$",
                "cookies": "quality=1080P\nlang=zh; quality=1080P",
                "addHeadersToVideo": {
                    "referer": "https://fixture.test/", "userAgent": "FixturePlayer/1",
                },
            },
        }},
    }


def selector_rule(**kwargs):
    rule = parse_media_source(selector_payload(**kwargs))
    assert rule is not None and rule.selector is not None
    return rule


def json_payload():
    return {
        "id": "json-fixture", "factoryId": "json-api",
        "arguments": {"name": "接口动漫", "searchConfig": {
            "baseUrl": "https://json.test", "requestInterval": 0,
            "headers": "X-Fixture: yes",
            "search": {
                "request": {"url": "/search", "method": "POST", "body": '{"q":"{keyword}"}'},
                "selectItems": "$.items[*]", "selectName": "$.name", "selectId": "$.id",
                "subjectUrlTemplate": "https://json.test/subject/{id}",
            },
            "subject": {
                "request": {"url": "/subject/{id}"},
                "episodes": {
                    "selectEpisodes": "$.episodes[*]", "selectId": "$.id",
                    "selectName": "$.name", "selectSort": "$.number",
                    "episodeUrlTemplate": "https://json.test/play/{id}",
                },
            },
            "play": {"request": {"url": "{url}"}, "selectVideoUrl": "$.url"},
        }},
    }


def test_subscription_top_level_wins_and_deduplicates():
    raw = selector_payload()
    bundle = parse_subscription_payload({
        "schemaVersion": 2, "name": "fixture",
        "mediaSources": [raw, copy.deepcopy(raw), None, {"id": "broken"}],
        "exportedMediaSourceDataList": {"mediaSources": [selector_payload("legacy")]},
    }, source_url="https://subscription.test/", fetched_at=123)
    assert [r.id for r in bundle.rules] == ["fixture"]
    assert bundle.schema_version == 2 and bundle.fetched_at == 123


def test_rule_models_are_validated_pydantic_dataclasses():
    from pydantic.dataclasses import is_pydantic_dataclass
    from pydantic import ValidationError
    from server.scrapers.anime.animeko_rules import SelectorSearchConfig
    assert is_pydantic_dataclass(SelectorSearchConfig)
    assert SelectorSearchConfig(request_interval_ms="100").request_interval_ms == 100
    with pytest.raises(ValidationError):
        SelectorSearchConfig(request_interval_ms="not-a-number")


def test_subscription_legacy_envelope():
    bundle = parse_subscription_payload({
        "schemaVersion": 2,
        "exportedMediaSourceDataList": {"mediaSources": [selector_payload()]},
    })
    assert len(bundle.rules) == 1


@pytest.mark.parametrize("factory,field,playable", [
    ("web-selector", "selector", True), ("json-api", "json_api", True),
    ("rss", "rss", False),
])
def test_factory_dispatch(factory, field, playable):
    raw = selector_payload()
    raw["factoryId"] = factory
    rule = parse_media_source(raw)
    assert rule is not None and getattr(rule, field) is not None
    assert rule.is_playable is playable


def test_regex_normalization_preserves_lookbehind_and_is_idempotent():
    raw = r"(?<=url=)(?<v>https://[^\s]+)(?<!bad)"
    normalized = rewrite_azusa_named_groups(raw)
    assert "(?P<v>" in normalized and "(?<=url=)" in normalized and "(?<!bad)" in normalized
    assert rewrite_azusa_named_groups(normalized) == normalized
    pattern = compile_rule_pattern(raw)
    assert pattern.search("url=https://media.test/1.mp4").group("v") == "https://media.test/1.mp4"
    assert compile_rule_pattern("[") is None


def test_real_subscription_css_form_with_unquoted_hash():
    root = parse_html('<nav class="nav-tabs"><a href="#playlist1">线路1</a><a href="/other">其他</a></nav>')
    assert len(select_elements(root, ".nav-tabs a[href^=#playlist]")) == 1
    assert select_elements(root, "[broken") == []


@pytest.mark.parametrize("expression,expected", [
    ("$.items[*].name", ["甲", "乙"]),
    ("$.items[0].id", [1]),
    ("$.items[*]['title','name']", ["甲", "另一个标题"]),
    ("$.items[99]", []), ("not-a-path", []),
])
def test_json_path_subset(expression, expected):
    data = {"items": [{"name": "甲", "id": 1}, {"name": "乙", "title": "另一个标题"}]}
    assert json_path_values(data, expression) == expected


def test_media_extraction_unescapes_deduplicates_and_excludes_player_page():
    config = MatchVideoConfig(match_video_url=r"^https://media\.test/.*\.m3u8(?:\?.*)?$")
    text = r'<script>{"url":"https:\/\/media.test\/master.m3u8?a=1&amp;b=2"}</script>'
    text += '<a href="https://media.test/master.m3u8?a=1&amp;b=2">same</a>'
    assert extract_media_urls(text, config) == ["https://media.test/master.m3u8?a=1&b=2"]


@pytest.mark.parametrize("variable", ["player_aaaa", "player_data", "window.player_data"])
@pytest.mark.parametrize("mode", [0, 1, 2])
def test_static_maccms_player_json_decodes_only_current_url(variable, mode):
    current = "https://media.test/current.m3u8?token=a+b&name=中文"
    encoded = current
    if mode:
        encoded = quote(current, safe="")
    if mode == 2:
        encoded = base64.b64encode(encoded.encode("utf-8")).decode("ascii")
    data = {
        "encrypt": str(mode), "url": encoded,
        "url_next": "https://media.test/next.m3u8", "url_pre": "https://media.test/previous.m3u8",
        "vod_data": {"name": 'nested } and "quotes"', "url": "https://media.test/poster.mp4"},
    }
    text = f'<script>var {variable}={json.dumps(data, ensure_ascii=True)};</script>'
    config = MatchVideoConfig(match_video_url=r"(?<v>https://media\.test/[^\s\"'<>]+\.m3u8(?:\?[^\s\"'<>]*)?)")
    assert extract_media_urls(text, config) == [current]


def test_static_maccms_url_unicode_json_and_legacy_percent_escapes():
    config = MatchVideoConfig(match_video_url=r"^https://media\.test/.*\.mp4(?:\?.*)?$")
    text = r'<script>player_data={"url":"https:\u002f\u002fmedia.test\u002fcurrent.mp4?name=%u4E2D%u6587&token=a+b","encrypt":1}</script>'
    assert extract_media_urls(text, config) == ["https://media.test/current.mp4?name=中文&token=a+b"]


@pytest.mark.parametrize("data", [
    {"encrypt": 2, "url": "%%%broken-base64%%%"},
    {"encrypt": 2, "url": "////"},
    {"encrypt": 3, "url": "https://media.test/custom-cipher.mp4"},
    {"encrypt": 0, "url": {"nested": "https://media.test/not-current.mp4"}},
    {"encrypt": 0, "url": "javascript:run()"},
])
def test_static_maccms_bad_or_custom_encoding_is_not_a_media_url(data):
    data["url_next"] = "https://media.test/next.mp4"
    config = MatchVideoConfig(match_video_url=r"https://media\.test/.*\.mp4")
    assert extract_media_urls(f'<script>player_aaaa={json.dumps(data)};</script>', config) == []


def test_static_maccms_json_is_not_executed_and_rule_still_filters():
    config = MatchVideoConfig(match_video_url=r"^https://media\.test/.*\.mp4$")
    assert extract_media_urls('<script>player_data=runAnyFunction();</script>', config) == []
    encoded = base64.b64encode(b"https%3A%2F%2Fother.test%2Fcurrent.mp4").decode("ascii")
    assert extract_media_urls(f'<script>player_data={{"encrypt":2,"url":"{encoded}"}}</script>', config) == []


@pytest.mark.parametrize("status", [403, 429, 468])
def test_block_status_detection(status):
    assert str(status) in detect_block_reason(status, "")


@pytest.mark.parametrize("text", [
    '<rss version="2.0"><channel><item><title>测试 第01集</title><link>https://bt.test/a.torrent</link><guid>magnet:?xt=urn:btih:123</guid></item></channel></rss>',
    '<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>测试 第01集</title><link href="https://bt.test/a.torrent"/><id>magnet:?xt=urn:btih:123</id></entry></feed>',
])
def test_rss_and_atom(text):
    items = parse_rss_items(text)
    assert len(items) == 1 and items[0].title == "测试 第01集"
    assert items[0].link == "https://bt.test/a.torrent"
    assert items[0].magnet.startswith("magnet:")


class AnimekoOfflineTests(unittest.IsolatedAsyncioTestCase):
    async def test_selector_provider_end_to_end_and_headers_no_media_download(self):
        requests = []

        def handler(request):
            requests.append(request)
            assert request.url.host == "fixture.test", "provider must return URLs, not download media"
            if request.url.path == "/search":
                assert request.url.params["q"] == "测试"
                return httpx.Response(200, text='<div class="results"><a href="/subject/42">测试</a></div>')
            if request.url.path == "/subject/42":
                return httpx.Response(200, text='<div class="episodes"><a href="/play/1">第01话</a><a href="/play/2">第02话</a></div>')
            if request.url.path == "/play/1":
                return httpx.Response(200, text='<video src="https://media.test/ep1.mp4"></video>')
            raise AssertionError(str(request.url))

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            scraper = AnimekoScraper(rules=[selector_rule()], client=client, enabled=True)
            results = await scraper.search("测试")
            assert len(results) == 1
            detail = await scraper.get_detail(results[0].source_id)
            assert [ep.number for ep in detail.episodes] == [1, 2]
            assert detail.episodes[0].title == "第01话"
            lines = await scraper.get_video_urls(results[0].source_id, 1)
            assert len(lines) == 1 and lines[0].url == "https://media.test/ep1.mp4"
            assert lines[0].headers["Referer"] == "https://fixture.test/"
            assert lines[0].headers["Cookie"] == "quality=1080P; lang=zh"
            assert lines[0].headers["User-Agent"] == "FixturePlayer/1"
            assert sum(r.url.path == "/subject/42" for r in requests) == 1
            await scraper.aclose()

    async def test_failure_isolation_and_disabled_gate(self):
        calls = []

        def handler(request):
            calls.append(str(request.url))
            if request.url.host == "blocked.test":
                return httpx.Response(468, text="captcha")
            return httpx.Response(200, text='<div class="results"><a href="/subject/42">测试</a></div>')

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            rules = [selector_rule(), selector_rule(source_id="blocked", host="blocked.test")]
            disabled = AnimekoScraper(rules=rules, client=client, enabled=False)
            assert await disabled.search("测试") == []
            assert await disabled.get_detail("fixture::https://fixture.test/subject/42") is None
            assert await disabled.get_video_urls("fixture::https://fixture.test/subject/42") == []
            assert calls == []
            enabled = AnimekoScraper(rules=rules, client=client, enabled=True)
            assert len(await enabled.search("测试")) == 1
            assert any("blocked.test" in url for url in calls)
            await enabled.aclose()

    async def test_selector_nested_player(self):
        rule = selector_rule()
        rule = replace(rule, selector=replace(rule.selector, match_video=replace(
            rule.selector.match_video, enable_nested_url=True,
            match_nested_url=r"/embed/",
        )))
        seen = []

        def handler(request):
            seen.append(request)
            if request.url.path == "/play/1":
                return httpx.Response(200, text='<iframe src="/embed/1"></iframe>')
            assert request.headers["referer"] == "https://fixture.test/play/1"
            return httpx.Response(200, text='<video src="https://media.test/ep1.mp4"></video>')

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            engine = SelectorEngine(rule, HttpFetcher(client=client, retries=0))
            assert await engine.media_urls("https://fixture.test/play/1") == ["https://media.test/ep1.mp4"]
            assert len(seen) == 2

    async def test_scraper_transport_without_client_is_used_and_owned(self):
        calls = []

        class Transport(httpx.MockTransport):
            closed = False

            async def aclose(self):
                self.closed = True
                await super().aclose()

        def handler(request):
            calls.append(str(request.url))
            return httpx.Response(200, text='<div class="results"><a href="/subject/42">测试</a></div>')

        transport = Transport(handler)
        scraper = AnimekoScraper(rules=[selector_rule()], transport=transport, enabled=True)
        try:
            assert len(await scraper.search("测试")) == 1
            assert len(calls) == 1
            assert scraper._fetcher._ensure_client()._transport is transport
        finally:
            await scraper.aclose()
        assert transport.closed is True

    async def test_explicit_client_takes_precedence_and_is_not_closed(self):
        calls = []

        def handler(request):
            calls.append("client")
            return httpx.Response(200, text='<div class="results"><a href="/subject/42">测试</a></div>')

        def wrong_transport(request):
            raise AssertionError("injected client takes precedence over transport")

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            scraper = AnimekoScraper(
                rules=[selector_rule()], client=client,
                transport=httpx.MockTransport(wrong_transport), enabled=True,
            )
            assert len(await scraper.search("测试")) == 1
            await scraper.aclose()
            assert not client.is_closed and calls == ["client"]

    async def test_nested_iframe_chain_resolves_document_relative_and_avoids_loop(self):
        rule = selector_rule()
        rule = replace(rule, selector=replace(rule.selector, match_video=replace(
            rule.selector.match_video, enable_nested_url=True, match_nested_url=r"/embed/",
        )))
        seen = []

        def handler(request):
            seen.append(request)
            assert request.url.host == "fixture.test", "media itself must not be downloaded"
            if request.url.path == "/play/1":
                return httpx.Response(200, text='<iframe src="../embed/one?x=1&amp;y=2"></iframe>')
            if request.url.path == "/embed/one":
                assert request.headers["referer"] == "https://fixture.test/play/1"
                assert request.url.params["y"] == "2"
                return httpx.Response(200, text='<iframe src="/play/1"></iframe><iframe data-src="two"></iframe>')
            assert request.url.path == "/embed/two"
            assert request.headers["referer"] == "https://fixture.test/embed/one?x=1&y=2"
            encoded = base64.b64encode(quote("https://media.test/current.mp4", safe="").encode()).decode()
            return httpx.Response(200, text=f'<script>player_data={{"encrypt":2,"url":"{encoded}"}}</script>')

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            engine = SelectorEngine(rule, HttpFetcher(client=client, retries=0))
            assert await engine.media_urls("https://fixture.test/play/1") == ["https://media.test/current.mp4"]
        assert len(seen) == 3

    async def test_nested_iframes_without_regex_but_not_when_disabled(self):
        rule = selector_rule()
        rule = replace(rule, selector=replace(rule.selector, match_video=replace(
            rule.selector.match_video, enable_nested_url=True, match_nested_url="",
        )))
        engine = SelectorEngine(rule, HttpFetcher(retries=0))
        text = '<script src="/assets/app.js"></script><a href="/ads/">ad</a><iframe src="/embed/a"></iframe>'
        assert engine.nested_candidates(text, "https://fixture.test/play/1") == ["https://fixture.test/embed/a"]
        for match_video in (
            replace(rule.selector.match_video, enable_nested_url=False),
            replace(rule.selector.match_video, match_nested_url="$^"),
            replace(rule.selector.match_video, match_nested_url="["),
        ):
            engine = SelectorEngine(replace(rule, selector=replace(rule.selector, match_video=match_video)), HttpFetcher(retries=0))
            assert engine.nested_candidates(text, "https://fixture.test/play/1") == []

    async def test_nested_iframes_are_depth_and_request_bounded(self):
        rule = selector_rule()
        rule = replace(rule, selector=replace(rule.selector, match_video=replace(
            rule.selector.match_video, enable_nested_url=True, match_nested_url="",
        )))
        calls = []
        branching = False

        def handler(request):
            calls.append(request.url.path)
            depth = int(request.url.path.rsplit("/", 1)[-1])
            if branching and depth == 0:
                text = ''.join(f'<iframe src="/embed/{i}"></iframe>' for i in range(1, 30))
            else:
                text = f'<iframe src="/embed/{depth + 1}"></iframe><iframe src="/embed/0"></iframe>'
            return httpx.Response(200, text=text)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            engine = SelectorEngine(rule, HttpFetcher(client=client, retries=0))
            assert await engine.media_urls("https://fixture.test/embed/0") == []
            assert calls == ["/embed/0", "/embed/1", "/embed/2", "/embed/3"]
            calls.clear()
            branching = True
            assert await engine.media_urls("https://fixture.test/embed/0") == []
            assert len(calls) == 7

    async def test_nested_candidates_do_not_fetch_direct_media(self):
        rule = selector_rule()
        rule = replace(rule, selector=replace(rule.selector, match_video=replace(
            rule.selector.match_video, enable_nested_url=True, match_nested_url=".*",
        )))
        engine = SelectorEngine(rule, HttpFetcher(retries=0))
        text = '<iframe src="https://other.test/full.mp4"></iframe><iframe src="javascript:run()"></iframe>'
        assert engine.nested_candidates(text, "https://fixture.test/play/1") == []

    async def test_json_api_full_chain_and_post_escaping(self):
        rule = parse_media_source(json_payload())
        paths = []

        def handler(request):
            paths.append(request.url.path)
            assert request.headers["x-fixture"] == "yes"
            if request.url.path == "/search":
                assert request.method == "POST"
                assert json.loads(request.content)["q"] == "测试"
                return httpx.Response(200, json={"items": [{"id": "42", "name": "测试"}]})
            if request.url.path == "/subject/42":
                return httpx.Response(200, json={"episodes": [{"id": "e1", "name": "第01话", "number": 1}]})
            if request.url.path == "/play/e1":
                return httpx.Response(200, json={"url": "https://media.test/ep1.mp4"})
            raise AssertionError(str(request.url))

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            scraper = AnimekoScraper(rules=[rule], client=client, enabled=True)
            subjects = await scraper.search("测试")
            detail = await scraper.get_detail(subjects[0].source_id)
            assert len(detail.episodes) == 1
            lines = await scraper.get_video_urls(subjects[0].source_id)
            assert lines[0].url == "https://media.test/ep1.mp4"
            assert paths == ["/search", "/subject/42", "/play/e1"]
            engine = JsonApiEngine(rule, HttpFetcher(client=client, retries=0))
            prepared = engine._prepare(rule.json_api.search_request, {"keyword": 'a"b\\c\n'})
            assert json.loads(prepared[3])["q"] == 'a"b\\c\n'
            await scraper.aclose()

    async def test_rss_engine_dispatch(self):
        rule = parse_media_source({"id": "rss", "factoryId": "rss", "arguments": {
            "searchConfig": {"searchUrl": "https://rss.test/?q={keyword}"},
        }})
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, text='<rss><channel><item><title>测试</title><link>https://bt.test/1.torrent</link></item></channel></rss>')
        )) as client:
            engine = RssEngine(rule, HttpFetcher(client=client, retries=0))
            assert len(await engine.search("测试")) == 1

    async def test_http_fetcher_streams_only_bounded_metadata(self):
        class Stream(httpx.AsyncByteStream):
            chunks_read = 0
            closed = False

            async def __aiter__(self):
                for _ in range(10):
                    self.chunks_read += 1
                    yield b"x" * 16

            async def aclose(self):
                self.closed = True

        for headers, expected_reads in (
            ({"Content-Type": "video/mp4"}, 0),
            ({"Content-Type": "text/html", "Content-Length": "2000"}, 0),
            ({"Content-Type": "text/html"}, 2),
        ):
            stream = Stream()
            async with httpx.AsyncClient(transport=httpx.MockTransport(
                lambda request: httpx.Response(200, headers=headers, stream=stream)
            )) as client:
                fetcher = HttpFetcher(client=client, retries=0, max_response_bytes=16)
                with pytest.raises(SourceUnavailableError):
                    await fetcher.get(selector_rule(), "https://fixture.test/play/1")
            assert stream.chunks_read == expected_reads and stream.closed

    async def test_repository_empty_failure_cooldown_and_force_are_independent(self):
        calls = []
        now = [0.0]

        def handler(request):
            calls.append(str(request.url))
            return httpx.Response(503)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            repo = RuleRepository(
                ["https://subscription.test/css.json"], client=client,
                memory_ttl_seconds=3600, failure_retry_seconds=10, clock=lambda: now[0],
            )
            assert await asyncio.gather(repo.load(), repo.load(), repo.load()) == [(), (), ()]
            assert len(calls) == 1
            now[0] = 9.999
            assert await repo.load() == () and len(calls) == 1
            now[0] = 10
            assert await repo.load() == () and len(calls) == 2
            assert await repo.load(force=True) == () and len(calls) == 3
            assert await repo.load() == () and len(calls) == 3

    async def test_repository_stale_memory_uses_failure_retry_not_success_ttl(self):
        calls = []
        now = [0.0]
        failing = [False]

        def handler(request):
            calls.append(str(request.url))
            if failing[0]:
                return httpx.Response(503)
            return httpx.Response(200, json={"mediaSources": [selector_payload()]})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            repo = RuleRepository(
                ["https://subscription.test/css.json"], client=client,
                memory_ttl_seconds=100, failure_retry_seconds=10, clock=lambda: now[0],
            )
            original = await repo.load()
            failing[0] = True
            now[0] = 101
            assert await repo.load() == original and len(calls) == 2
            now[0] = 110
            assert await repo.load() == original and len(calls) == 2
            now[0] = 111
            assert await repo.load() == original and len(calls) == 3
            failing[0] = False
            assert await repo.load(force=True) == original and len(calls) == 4
            now[0] = 160
            assert await repo.load() == original and len(calls) == 4

    async def test_scraper_detail_retries_respect_empty_repository_cooldown(self):
        calls = []

        def handler(request):
            calls.append(str(request.url))
            return httpx.Response(503)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            repo = RuleRepository(["https://subscription.test/css.json"], client=client)
            scraper = AnimekoScraper(repository=repo, client=client, enabled=True)
            source_id = scraper.encode_source_id("fixture", "https://fixture.test/subject/42")
            assert await scraper.get_detail(source_id) is None
            assert await scraper.get_video_urls(source_id) == []
            assert await scraper.get_detail(source_id) is None
            assert len(calls) == 1
            await scraper.rules(force=True)
            assert len(calls) == 2
            await scraper.aclose()

    async def test_scraper_repository_rules_refresh_after_ttl_and_rebuild_engine(self):
        now = [0.0]
        calls = []

        def handler(request):
            calls.append(str(request.url))
            payload = selector_payload()
            payload["version"] = len(calls)
            return httpx.Response(200, json={"mediaSources": [payload]})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            repo = RuleRepository(
                ["https://subscription.test/css.json"], client=client,
                memory_ttl_seconds=10, clock=lambda: now[0],
            )
            scraper = AnimekoScraper(repository=repo, client=client, enabled=True)
            first = (await scraper.rules())[0]
            old_engine = scraper._engine_for(first)
            assert (await scraper.rules())[0].version == 1 and len(calls) == 1
            now[0] = 10
            refreshed = (await scraper.rules())[0]
            assert refreshed.version == 2 and len(calls) == 2
            assert scraper._engine_for(refreshed) is not old_engine
            await scraper.aclose()

    async def test_injected_rules_stay_static_until_explicit_force(self):
        calls = []

        def handler(request):
            calls.append(str(request.url))
            return httpx.Response(200, json={"mediaSources": [selector_payload("loaded")]})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            repo = RuleRepository(["https://subscription.test/css.json"], client=client)
            for injected in ([], [selector_rule()]):
                scraper = AnimekoScraper(rules=injected, repository=repo, client=client, enabled=True)
                assert await scraper.rules() == tuple(injected)
                assert calls == []
                await scraper.aclose()
            scraper = AnimekoScraper(rules=[selector_rule()], repository=repo, client=client, enabled=True)
            assert [rule.id for rule in await scraper.rules(force=True)] == ["loaded"]
            assert len(calls) == 1
            await scraper.aclose()

    async def test_repository_disk_roundtrip_preserves_every_modeled_field(self):
        import tempfile
        from pathlib import Path

        def populated(model):
            """设置每一个模型字段为非默认值,防止新增字段被缓存悄悄丢弃。"""
            values = {}
            for item in fields(model):
                value = getattr(model, item.name)
                if is_dataclass(value):
                    values[item.name] = populated(value)
                elif isinstance(value, bool):
                    values[item.name] = not value
                elif isinstance(value, int):
                    values[item.name] = value + 7
                elif isinstance(value, str):
                    values[item.name] = f"field-{item.name}"
                elif isinstance(value, tuple):
                    values[item.name] = ("item-one", "item-two")
            return replace(model, **values)

        selector = populated(selector_rule().selector)
        api = populated(parse_media_source(json_payload()).json_api)
        api = replace(api,
            search_request=replace(api.search_request, method="POST"),
            subject_request=replace(api.subject_request, method="PUT"),
            play_request=replace(api.play_request, method="GET"),
            episodes=replace(api.episodes, request=replace(api.episodes.request, method="PATCH")),
        )
        rss_rule = parse_media_source({"id": "rss-fixture", "factoryId": "rss", "arguments": {"searchConfig": {}}})
        rules = (
            replace(selector_rule(), selector=selector, tags=("tag",), tier=9,
                    channel_tiers={"线路B": 2}, version=4, description="说明", icon_url="https://fixture.test/icon.png"),
            replace(parse_media_source(json_payload()), json_api=api),
            replace(rss_rule, rss=populated(rss_rule.rss)),
        )
        from server.scrapers.anime.animeko_rules import RuleBundle
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "rules.json"
            writer = RuleRepository([], cache_path=cache)
            writer._bundles = [RuleBundle(rules=rules, source_url="https://subscription.test/")]
            writer._write_disk_cache()
            reader = RuleRepository([], cache_path=cache)
            assert await reader.load() == rules

    async def test_repository_concurrent_load_and_disk_fallback(self):
        import tempfile
        from pathlib import Path
        calls = []

        def handler(request):
            calls.append(str(request.url))
            return httpx.Response(200, json={"schemaVersion": 2, "mediaSources": [selector_payload()]})

        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "rules.json"
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                repo = RuleRepository(["https://subscription.test/css.json"], client=client, cache_path=cache)
                outcomes = await asyncio.gather(repo.load(), repo.load(), repo.load())
                assert all(len(result) == 1 for result in outcomes) and len(calls) == 1
                assert cache.exists()
            async with httpx.AsyncClient(transport=httpx.MockTransport(
                lambda request: httpx.Response(503)
            )) as client:
                repo = RuleRepository(["https://subscription.test/css.json"], client=client, cache_path=cache)
                assert len(await repo.load()) == 1


def test_aggregator_registration():
    from server.aggregator import ContentAggregator
    aggregator = ContentAggregator(enabled_provider_ids={"crawler.animeko"})
    assert "animeko" in aggregator.active_crawler_scrapers
    assert "crawler.animeko" in {meta.provider_id for meta in aggregator.provider_metadata}
