"""Offline current-episode media/descriptor and public page boundary tests."""

from __future__ import annotations

import asyncio
import base64
import json
import socket
import time
import unittest
from unittest.mock import AsyncMock, patch
from urllib.parse import quote

import httpx
import pytest

from server.scrapers.anime.kazumi import KazumiScraper
from server.scrapers.anime.kazumi_media import page_candidates, public_url_shape
from server.scrapers.anime.kazumi_rules import parse_rule


def _xpath_rule(name="fixture"):
    return parse_rule({
        "name": name, "baseURL": "https://site.example/", "userAgent": "FixtureBrowser/1.0",
        "searchURL": "https://site.example/search?wd=@keyword", "searchList": "//li", "searchName": "//a", "searchResult": "//a",
        "chapterRoads": "//ul[@class='playlist']", "chapterResult": "//li/a",
    })


def _api_rule(nested=False):
    chapter = {
        "request": {"url": "https://api.example/detail", "query": {"vod_id": "@source"}},
        "format": "delimited", "roadNamesPath": "$.from", "roadEpisodesPath": "$.url",
    }
    if nested:
        chapter = {
            "request": {"url": "https://api.example/detail", "query": {"vod_id": "@source"}},
            "format": "nested", "roadsPath": "$.roads[*]", "roadNamePath": "$.name", "episodesPath": "$.episodes[*]",
            "episodeNamePath": "$.title", "episodeUrlPath": "$.url",
        }
    return parse_rule({
        "name": "api-fixture", "baseURL": "https://site.example/", "userAgent": "FixtureBrowser/1.0",
        "searchMode": "api", "chapterMode": "api",
        "searchApiConfig": {
            "request": {"url": "https://api.example/search", "query": {"wd": "@keyword"}},
            "listPath": "$.list[*]", "namePath": "$.title", "sourcePath": "$.id",
        },
        "chapterApiConfig": chapter,
    })


def _detail(roads):
    return ('<html><h1>葬送的芙莉莲</h1>' + ''.join(
        '<ul class="playlist">' + ''.join(f'<li><a href="{url}">{label}</a></li>' for label, url in road) + '</ul>'
        for road in roads
    ) + '</html>').encode()


def _player(value, encrypt=0, **extra):
    return ('<html><script>var player_aaaa=' + json.dumps({"url": value, "encrypt": encrypt, **extra}) + ';</script></html>').encode()


class KazumiMediaTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.requests = []
        self.scrapers = []
        self._dns_patch = patch.object(
            asyncio.get_running_loop(), "getaddrinfo",
            new=AsyncMock(return_value=[(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))]),
        )
        self.dns = self._dns_patch.start()
        self.addCleanup(self._dns_patch.stop)

    async def asyncTearDown(self):
        for scraper in self.scrapers:
            await scraper.aclose()

    def scraper(self, pages, rule=None, **kwargs):
        async def handler(request):
            self.requests.append(request)
            host = request.headers.get("host", request.url.host).split(":")[0]
            entry = pages.get((host, request.url.path), pages.get(request.url.path))
            if entry is None:
                return httpx.Response(404)
            if callable(entry):
                entry = entry(request)
                if hasattr(entry, "__await__"):
                    entry = await entry
            if isinstance(entry, httpx.Response):
                return entry
            if isinstance(entry, dict):
                return httpx.Response(200, json=entry)
            return httpx.Response(200, content=entry, headers={"Content-Type": "text/html; charset=utf-8"})

        scraper = KazumiScraper(
            enabled=True, rules=[rule or _xpath_rule()], transport=httpx.MockTransport(handler),
            min_interval=0, attempts=1, **kwargs,
        )
        self.scrapers.append(scraper)
        return scraper

    async def test_api_direct_media_all_roads_exact_episode_and_no_media_fetch(self):
        scraper = self.scraper({"/detail": {
            "from": "sub$$$dub",
            "url": "01$https://cdn.example/sub/1.m3u8#02$https://cdn.example/sub/2.m3u8"
                   "$$$01$https://cdn.example/dub/1.mp4#02$https://cdn.example/dub/2.mp4",
        }}, rule=_api_rule())
        lines = await scraper.get_video_urls("api-fixture::11", 2)
        self.assertEqual([line.url for line in lines], ["https://cdn.example/sub/2.m3u8", "https://cdn.example/dub/2.mp4"])
        self.assertEqual([line.format for line in lines], ["hls", "mp4"])
        self.assertTrue(all(not line.client_resolver for line in lines))
        self.assertEqual([request.url.path for request in self.requests], ["/detail"])
        self.assertEqual((await scraper.get_detail("api-fixture::11")).episodes[2].number, 1)
        self.assertEqual(len(self.requests), 1, "playback and details share episode cache")
        self.assertEqual(len({line.source_name for line in lines}), 2)
        self.assertTrue(all(line.headers["User-Agent"] == "FixtureBrowser/1.0" for line in lines))

    async def test_known_media_beyond_page_budget_and_many_sources_are_not_truncated(self):
        urls = [f"https://cdn.example/known-{index}.mp4" for index in range(12)]
        scraper = self.scraper({"/detail": {"from": "$$$".join(f"road-{index}" for index in range(12)),
                                             "url": "$$$".join(f"01${url}" for url in urls)}}, rule=_api_rule())
        lines = await scraper.get_video_urls("api-fixture::11", 1)
        self.assertEqual([line.url for line in lines], urls)
        self.assertEqual([request.url.path for request in self.requests], ["/detail"])
        self.requests.clear()
        scraper2 = self.scraper({
            "/detail": _detail([[('01', '/ep1')]]),
            "/ep1": ('<video>' + ''.join(f'<source src="{url}">' for url in urls) + '</video>').encode(),
        })
        lines = await scraper2.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertEqual([line.url for line in lines], urls)
        self.assertEqual([request.url.path for request in self.requests], ["/detail", "/ep1"])

    async def test_nested_roads_keep_same_label_and_reset_fallback_position(self):
        scraper = self.scraper({"/detail": {"roads": [
            {"name": "first", "episodes": [{"title": "启程", "url": "https://cdn.example/a1.mp4"}, {"title": "旅程", "url": "https://cdn.example/a2.mp4"}]},
            {"name": "second", "episodes": [{"title": "启程", "url": "https://cdn.example/b1.mp4"}, {"title": "旅程", "url": "https://cdn.example/b2.mp4"}]},
        ]}}, rule=_api_rule(nested=True))
        detail = await scraper.get_detail("api-fixture::11")
        self.assertEqual([item.number for item in detail.episodes], [1, 2, 1, 2])
        self.assertEqual([line.url for line in await scraper.get_video_urls("api-fixture::11", 2)], ["https://cdn.example/a2.mp4", "https://cdn.example/b2.mp4"])

    async def test_xpath_encrypt_zero_one_two_only_current_value(self):
        current = ["https://cdn.example/a2.m3u8?x=1&y=2", "https://cdn.example/b2.mp4", "https://cdn.example/c2.m3u8"]
        scraper = self.scraper({
            "/detail": _detail([[('第1集', '/a1'), ('第2集', '/a2')], [('第1集', '/b1'), ('第2集', '/b2')], [('第1集', '/c1'), ('第2集', '/c2')]]),
            "/a2": _player(current[0], url_next="https://cdn.example/next.m3u8", ad="https://ads.example/ad.mp4"),
            "/b2": _player(quote(current[1], safe=""), 1),
            "/c2": _player(base64.b64encode(quote(current[2], safe="").encode()).decode(), 2),
        })
        lines = await scraper.get_video_urls("fixture::https://site.example/detail", 2)
        self.assertEqual([line.url for line in lines], current)
        self.assertTrue(all(not line.client_resolver for line in lines))
        self.assertEqual([line.headers["Referer"] for line in lines], ["https://site.example/a2", "https://site.example/b2", "https://site.example/c2"])
        self.assertEqual(len(self.requests), 4, "title reuses fetched detail, no repeated metadata")
        self.assertFalse(any(request.url.path in {"/a1", "/b1", "/c1"} for request in self.requests))

    async def test_explicit_iframe_two_hops_and_video_source(self):
        scraper = self.scraper({
            "/detail": _detail([[('01', '/ep1')]]),
            "/ep1": b'<div id="player"><iframe src="https://embed.example/p1"></iframe></div><iframe class="ad" src="https://ads.example/a"></iframe>',
            ("embed.example", "/p1"): b'<iframe id="video-frame" src="https://inner.example/p2"></iframe>',
            ("inner.example", "/p2"): b'<video><source src="https://cdn.example/one.webm" type="video/webm"></video>',
        })
        lines = await scraper.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertEqual([line.url for line in lines], ["https://cdn.example/one.webm"])
        self.assertEqual(lines[0].format, "webm")
        self.assertEqual(lines[0].headers["Referer"], "https://inner.example/p2")
        self.assertNotIn("/a", [request.url.path for request in self.requests])

    async def test_missing_episode_and_bad_episode_never_fetch_player(self):
        scraper = self.scraper({"/detail": _detail([[('第3集', '/ep3')]])})
        self.assertEqual(await scraper.get_video_urls("fixture::https://site.example/detail", 2), [])
        for episode in (0, -1, True, 1.5):
            self.assertEqual(await scraper.get_video_urls("fixture::https://site.example/detail", episode), [])
        self.assertEqual([request.url.path for request in self.requests], ["/detail"])

    async def test_js_descriptor_exact_hosts_reviewed_cdn_and_no_credentials(self):
        scraper = self.scraper({
            "/detail": _detail([[('01', '/ep1')]]),
            "/ep1": b'<div id="player"><iframe src="https://embed.example/watch"></iframe></div><script src="https://analytics.example/t.js"></script>',
            ("embed.example", "/watch"): _player("https://stream.example/session/episode") + b'<script>const token="do-not-export"; const ad="https://ads.example/ad.mp4";</script>',
        }, rule=_xpath_rule("moonci"))
        lines = await scraper.get_video_urls("moonci::https://site.example/detail", 1)
        self.assertEqual(len(lines), 1)
        line, = lines
        self.assertEqual(line.url, "")
        self.assertEqual(line.format, "auto")
        descriptor = line.client_resolver
        self.assertEqual(descriptor["kind"], "kazumi_page_v1")
        self.assertEqual(descriptor["page_url"], "https://site.example/ep1")
        self.assertEqual(descriptor["referer"], "https://site.example/detail")
        self.assertEqual(set(descriptor["page_hosts"]), {"site.example", "embed.example"})
        self.assertEqual(set(descriptor["media_hosts"]), {"site.example", "embed.example", "stream.example", "play.xfvod.pro"})
        self.assertNotIn("*", str(descriptor))
        self.assertNotIn("do-not-export", str(descriptor))
        self.assertNotIn("ads.example", str(descriptor))
        self.assertNotIn("analytics.example", str(descriptor))
        self.assertEqual(descriptor["rule_id"], "moonci")
        self.assertEqual(line.source_name, "kazumi:moonci:1")
        self.assertTrue(all("cookie" not in request.headers for request in self.requests))

    async def test_next_and_ad_media_are_never_used_for_unresolved_current_player(self):
        scraper = self.scraper({
            "/detail": _detail([[('01', '/ep1')]]),
            "/ep1": _player("opaque-current-id", url_next="https://cdn.example/next.m3u8", pre="https://ads.example/ad.mp4")
                     + b'<a href="https://cdn.example/next2.mp4">next</a>'
                     + b'<script>var ad="https://ads.example/ad2.mp4";</script>'
                     + b'<video class="advertisement" src="https://ads.example/ad3.mp4"></video>',
        })
        lines = await scraper.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertEqual([line.url for line in lines], [""])
        self.assertEqual(lines[0].client_resolver["media_hosts"], ["site.example"])

    async def test_unsafe_chapter_and_media_urls_are_not_emitted_or_fetched(self):
        unsafe = ["http://127.0.0.1/a.mp4", "http://10.1.2.3/a.m3u8", "http://localhost/a", "file:///secret", "https://user:pass@cdn.example/a.mp4"]
        scraper = self.scraper({"/detail": _detail([[(str(index), url)] for index, url in enumerate(unsafe, 1)])})
        for episode in range(1, len(unsafe) + 1):
            self.assertEqual(await scraper.get_video_urls("fixture::https://site.example/detail", episode), [])
        self.assertEqual([request.url.path for request in self.requests], ["/detail"])
        scraper2 = self.scraper({"/detail": _detail([[('01', '/ep1')]]), "/ep1": _player("http://192.168.1.1/a.m3u8")})
        lines = await scraper2.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertTrue(all(not line.url for line in lines))
        self.assertNotIn("192.168", str([line.client_resolver for line in lines]))

    async def test_private_dns_and_private_redirect_stop_before_transport(self):
        scraper = self.scraper({
            "/detail": _detail([[('01', '/ep1')]]),
            "/ep1": httpx.Response(302, headers={"Location": "http://127.0.0.1/secret", "Set-Cookie": "session=secret; Path=/"}),
        })
        self.assertEqual(await scraper.get_video_urls("fixture::https://site.example/detail", 1), [])
        self.assertEqual([request.url.path for request in self.requests], ["/detail", "/ep1"])
        self.requests.clear()
        self.dns.return_value = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.5", 443))]
        self.assertEqual(await scraper.get_video_urls("fixture::https://site.example/detail", 1), [])
        self.assertEqual(self.requests, [])

    async def test_public_redirect_preserves_real_page_referer_and_cookie_policy(self):
        scraper = self.scraper({
            "/detail": _detail([[('01', '/ep1')]]),
            "/ep1": httpx.Response(302, headers={"Location": "https://embed.example/current", "Set-Cookie": "session=secret; Path=/"}),
            ("embed.example", "/current"): _player("https://cdn.example/one.mp4"),
        })
        lines = await scraper.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertEqual([line.url for line in lines], ["https://cdn.example/one.mp4"])
        self.assertEqual(lines[0].headers["Referer"], "https://embed.example/current")
        self.assertEqual(self.requests[-1].headers["Referer"], "https://site.example/ep1")
        self.assertTrue(all("cookie" not in request.headers for request in self.requests))
        self.assertEqual(len(scraper._media_resolver._client.cookies), 0)
        self.assertEqual(self.requests[-1].url.host, "1.1.1.1", "resolver pins mock connection to checked public IP")

    async def test_global_four_page_five_route_budget_and_depth(self):
        scraper = self.scraper({
            "/detail": _detail([[('01', f'/ep{index}')] for index in range(8)]),
            **{f'/ep{index}': _player(f'https://cdn.example/{index}.mp4') for index in range(8)},
        })
        lines = await scraper.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertEqual(len(lines), 8)
        self.assertEqual(sum(bool(line.url) for line in lines), 4)
        self.assertEqual(sum(not line.url and not line.client_resolver for line in lines), 4)
        self.assertEqual(len({line.source_name for line in lines}), 8)
        self.assertEqual(len(self.requests), 5, "one metadata + four resolver HTTP requests globally")
        self.requests.clear()
        scraper2 = self.scraper({
            "/detail": _detail([[('01', '/root')]]),
            "/root": b'<iframe id="player" src="/f1"></iframe>',
            "/f1": b'<iframe id="player" src="/f2"></iframe>',
            "/f2": b'<iframe id="player" src="/f3"></iframe>',
            "/f3": _player("https://cdn.example/deep.mp4"),
        })
        lines = await scraper2.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertTrue(lines[0].client_resolver)
        self.assertEqual([request.url.path for request in self.requests], ["/detail", "/root", "/f1", "/f2"])

    async def test_media_total_deadline_keeps_fast_independent_route_and_cancels_slow(self):
        async def slow(_):
            await asyncio.sleep(5)
            return _player("https://cdn.example/slow.mp4")

        scraper = self.scraper({
            "/detail": _detail([[('01', '/fast')], [('01', '/slow')]]),
            "/fast": _player("https://cdn.example/fast.mp4"), "/slow": slow,
        }, media_deadline=0.15)
        started = time.monotonic()
        lines = await scraper.get_video_urls("fixture::https://site.example/detail", 1)
        self.assertLess(time.monotonic() - started, 0.7)
        self.assertEqual([line.url for line in lines], ["https://cdn.example/fast.mp4", ""])
        self.assertFalse(lines[-1].client_resolver, "deadline does not fabricate JS permission")

    async def test_concurrent_detail_and_media_share_metadata_request(self):
        async def detail(_):
            await asyncio.sleep(0.02)
            return _detail([[('01', '/ep1')]])

        scraper = self.scraper({"/detail": detail, "/ep1": _player("https://cdn.example/one.mp4")})
        first, second, lines = await asyncio.gather(
            scraper.get_detail("fixture::https://site.example/detail"),
            scraper.get_detail("fixture::https://site.example/detail"),
            scraper.get_video_urls("fixture::https://site.example/detail", 1),
        )
        self.assertIs(first, second)
        self.assertEqual(len(lines), 1)
        self.assertEqual([request.url.path for request in self.requests].count("/detail"), 1)


@pytest.mark.parametrize("url", [
    "file:///secret", "http://127.0.0.1/a", "http://[::1]/a", "http://localhost/a", "http://site.local/a",
    "http://10.0.0.1/a", "https://user:pass@cdn.example/a", "https://cdn.example\\evil/a", "https://cdn.example/\nheader",
])
def test_public_shape_filters_unsafe_without_dns(url):
    assert not public_url_shape(url)


def test_static_extraction_never_scans_arbitrary_script_or_comment_urls():
    parsed = page_candidates(
        b'<html><!-- <script>var player_aaaa={"url":"https://cdn.example/comment.mp4"}</script> -->'
        b'<script>var url_next="https://cdn.example/next.m3u8"; var ad="https://ads.example/ad.mp4";</script>'
        b'<a href="https://cdn.example/link.mp4">link</a></html>', "https://site.example/ep1",
    )
    assert parsed.media == []
    assert parsed.current_urls == []
