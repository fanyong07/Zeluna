import asyncio
import unittest
from unittest.mock import AsyncMock, patch

import httpx

from server.aggregator import (
    CLIENT_PROBE_REQUIRED,
    MALFORMED_MANIFEST,
    NON_PUBLIC_TARGET,
    PARSER_MISMATCH,
    READ_TIMEOUT,
    SERVER_VERIFIED,
    STARTUP_HLS,
    STARTUP_MP4_FASTSTART,
    STARTUP_MP4_TAIL_MOOV,
    STARTUP_UNKNOWN,
    STALE_ROUTE,
    UNAVAILABLE,
    AggregatedVideoLine,
    ContentAggregator,
    LineVerificationResult,
    SourceMatch,
    _mp4_startup_profile,
    _source_match_score,
)
from server.scrapers.base import SubjectResult, VideoLine


def _mp4_startup_sample(*, moov_before_mdat: bool) -> bytes:
    def box(box_type: bytes, size: int = 8) -> bytes:
        return size.to_bytes(4, "big") + box_type + bytes(size - 8)

    parts = [box(b"ftyp", 24)]
    if moov_before_mdat:
        parts.append(box(b"moov"))
    parts.append(box(b"mdat"))
    if not moov_before_mdat:
        parts.append(box(b"moov"))
    return b"".join(parts)


def _iso_box(box_type: bytes, size: int = 8) -> bytes:
    return size.to_bytes(4, "big") + box_type + bytes(size - 8)


class AggregatorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        aggregator = getattr(self, "aggregator", None)
        if aggregator is not None:
            await aggregator.aclose()

    def test_short_chinese_title_accepts_only_same_year_edition_suffix(self):
        first_season = _source_match_score(
            "庆余年 第一季",
            ["庆余年"],
            candidate_type="tv",
            expected_type="tv",
            candidate_year=2019,
            expected_year=2019,
        )
        wrong_season = _source_match_score(
            "庆余年 第二季",
            ["庆余年"],
            candidate_type="tv",
            expected_type="tv",
            candidate_year=2024,
            expected_year=2019,
        )
        spinoff = _source_match_score(
            "庆余年之帝王业",
            ["庆余年"],
            candidate_type="tv",
            expected_type="tv",
            candidate_year=2019,
            expected_year=2019,
        )

        self.assertGreaterEqual(first_season, 65)
        self.assertLess(wrong_season, 65)
        self.assertLess(spinoff, 65)

    async def test_default_crawlers_are_current_vps_playback_candidates(self):
        self.aggregator = ContentAggregator()

        self.assertEqual(
            set(self.aggregator._crawler_scrapers),
            {
                "age",
                "dm706",
                "dbku",
                "girigiri",
                "jibi",
                "nivod",
                "ppnix",
                "wedm",
                "xgcartoon",
                "yinghua2",
            },
        )

    async def test_same_title_from_different_maccms_sites_is_preserved(self):
        self.aggregator = ContentAggregator(crawler_scrapers={})
        self.aggregator._maccms.search = AsyncMock(return_value=[
            SubjectResult(
                source_id="maccms:iKun:1",
                title="葬送的芙莉莲",
                type="anime",
            ),
            SubjectResult(
                source_id="maccms:魔都:2",
                title="葬送的芙莉莲",
                type="anime",
            ),
        ])
        self.aggregator._tvbox.search = AsyncMock(return_value=[])

        results = await self.aggregator.search(
            "葬送的芙莉莲", ["anime"], max_results=10
        )

        self.assertEqual(
            {item.id for item in results},
            {"maccms:iKun:1", "maccms:魔都:2"},
        )

    async def test_fallback_display_id_is_sha256_stable(self):
        self.aggregator = ContentAggregator(crawler_scrapers={})
        self.aggregator._maccms.search = AsyncMock(return_value=[
            SubjectResult(
                source_id="legacy:42",
                title="Fallback Title",
                type="anime",
            )
        ])
        self.aggregator._tvbox.search = AsyncMock(return_value=[])

        results = await self.aggregator.search(
            "Fallback Title", ["anime"], max_results=10
        )

        self.assertEqual(
            [item.id for item in results],
            ["maccms:display:v1:2dea17a54f90c71c4cde8471"],
        )

    async def test_stable_playback_discovers_and_resolves_custom_crawler(self):
        crawler = AsyncMock()
        crawler.content_types = ["anime"]
        crawler.search = AsyncMock(return_value=[
            SubjectResult(
                source_id="alma-1",
                title="小阿尔玛想要成为家人",
                type="anime",
                year=2025,
            )
        ])
        crawler.get_video_urls = AsyncMock(return_value=[
            VideoLine(
                url="https://cdn.example/alma.m3u8",
                title="AGE 线路",
                format="hls",
                source_name="agefans",
            )
        ])
        self.aggregator = ContentAggregator(
            crawler_scrapers={"agefans": crawler}
        )
        self.aggregator._maccms.search = AsyncMock(return_value=[])
        self.aggregator._tvbox.search = AsyncMock(return_value=[])
        self.aggregator._line_verification_status = AsyncMock(
            return_value=SERVER_VERIFIED
        )

        matches = await self.aggregator.discover_source_matches(
            ["小阿尔玛想要成为家人"],
            content_type="anime",
            year=2025,
        )
        lines, health = await self.aggregator.resolve_source_matches(
            matches,
            episode=1,
        )

        self.assertEqual([item.source_id for item in matches], [
            "crawler:agefans:alma-1"
        ])
        self.assertEqual([line.source for line in lines], ["crawler:agefans"])
        self.assertEqual(health, {"agefans": SERVER_VERIFIED})

    async def test_datacenter_rejected_line_is_returned_for_client_probe(self):
        crawler = AsyncMock()
        crawler.content_types = ["anime"]
        crawler.get_video_urls = AsyncMock(return_value=[
            VideoLine(
                url="https://cdn.example/restricted.m3u8",
                title="客户端候选",
                format="hls",
                headers={"Referer": "https://source.example/watch/1"},
                source_name="dm706",
            )
        ])
        self.aggregator = ContentAggregator(
            crawler_scrapers={"dm706": crawler}
        )
        self.aggregator._line_verification_status = AsyncMock(
            return_value=CLIENT_PROBE_REQUIRED
        )

        lines, health = await self.aggregator.resolve_source_matches(
            [
                SourceMatch(
                    source_id="crawler:dm706:2672",
                    source_name="dm706",
                    title="葬送的芙莉莲",
                    content_type="anime",
                    year=2023,
                )
            ],
            episode=1,
        )

        self.assertEqual(len(lines), 1)
        self.assertEqual(
            lines[0].verification_status,
            CLIENT_PROBE_REQUIRED,
        )
        self.assertEqual(lines[0].headers["Referer"], "https://source.example/watch/1")
        self.assertEqual(health, {"dm706": CLIENT_PROBE_REQUIRED})

    async def test_quick_unverified_lines_are_public_client_candidates_only(self):
        crawler = AsyncMock()
        crawler.content_types = ["anime"]
        crawler.get_video_urls = AsyncMock(return_value=[
            VideoLine(
                url="https://cdn.example/quick.m3u8",
                title="快速候选",
                format="hls",
                source_name="quick",
            ),
            VideoLine(
                url="http://127.0.0.1/private.m3u8",
                title="私网地址",
                format="hls",
                source_name="quick",
            ),
            VideoLine(
                url="https://source.example/player.html?url=video",
                title="网页播放器",
                format="hls",
                source_name="quick",
            ),
            VideoLine(
                url="https://cdn.example/media/opaque-token",
                title="尚未验明的无扩展地址",
                format="auto",
                source_name="quick",
            ),
        ])
        self.aggregator = ContentAggregator(crawler_scrapers={"quick": crawler})
        self.aggregator._line_verification_status = AsyncMock(
            side_effect=AssertionError("quick candidates must not run media probes")
        )

        lines, health = await self.aggregator.resolve_source_matches(
            [
                SourceMatch(
                    source_id="crawler:quick:1",
                    source_name="quick",
                    title="测试动画",
                    content_type="anime",
                    year=2025,
                )
            ],
            episode=1,
            verify=False,
        )

        self.assertEqual([line.url for line in lines], [
            "https://cdn.example/quick.m3u8"
        ])
        self.assertEqual(lines[0].verification_status, CLIENT_PROBE_REQUIRED)
        self.assertEqual(health, {"quick": CLIENT_PROBE_REQUIRED})
        self.aggregator._line_verification_status.assert_not_awaited()

    async def test_full_verifier_accepts_real_extensionless_media(self):
        requests = []

        def handler(request: httpx.Request) -> httpx.Response:
            requests.append(str(request.url))
            return httpx.Response(
                206,
                headers={"content-type": "video/mp4"},
                content=_mp4_startup_sample(moov_before_mdat=True),
            )

        self.aggregator = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler),
            crawler_scrapers={},
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            result = await self.aggregator._line_verification_status(
                AggregatedVideoLine(
                    url="https://cdn.example/media/opaque-token",
                    format="auto",
                ),
                detailed=True,
            )

        self.assertEqual(result.status, SERVER_VERIFIED)
        self.assertEqual(result.startup_profile, STARTUP_MP4_FASTSTART)
        self.assertEqual(requests, ["https://cdn.example/media/opaque-token"])

    async def test_obvious_player_page_is_rejected_without_http_request(self):
        requests = 0

        def handler(request: httpx.Request) -> httpx.Response:
            nonlocal requests
            requests += 1
            return httpx.Response(200, content=b"not used")

        self.aggregator = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler),
            crawler_scrapers={},
        )
        result = await self.aggregator._line_verification_status(
            AggregatedVideoLine(
                url="https://source.example/player.html?url=video",
                format="hls",
            ),
            detailed=True,
        )

        self.assertEqual(result.status, UNAVAILABLE)
        self.assertEqual(result.error_category, PARSER_MISMATCH)
        self.assertEqual(requests, 0)

    async def test_progressive_discovery_uses_first_matching_maccms_site(self):
        self.aggregator = ContentAggregator(crawler_scrapers={})

        async def progressive_search(keyword, *, preferred_only=False):
            self.assertEqual(keyword, "Test Anime")
            self.assertTrue(preferred_only)
            yield [
                SubjectResult(
                    source_id="maccms:fast:1",
                    title="Test Anime",
                    type="anime",
                    year=2025,
                )
            ]

        self.aggregator._maccms.search_progressively = progressive_search
        self.aggregator._maccms.search = AsyncMock(
            side_effect=AssertionError(
                "quick discovery must not wait for full search"
            )
        )
        self.aggregator._tvbox.search = AsyncMock(return_value=[])

        iterator = self.aggregator.discover_source_matches_progressively(
            ["Test Anime"],
            content_type="anime",
            year=2025,
        )
        first = await asyncio.wait_for(anext(iterator), timeout=0.2)
        await iterator.aclose()

        self.assertEqual(first.source_id, "maccms:fast:1")
        self.aggregator._maccms.search.assert_not_awaited()

    async def test_definitive_404_is_not_sent_to_the_client_as_a_candidate(self):
        crawler = AsyncMock()
        crawler.content_types = ["anime"]
        crawler.get_video_urls = AsyncMock(return_value=[
            VideoLine(
                url="https://cdn.example/missing.m3u8",
                title="失效线路",
                format="hls",
                source_name="dead",
            )
        ])
        self.aggregator = ContentAggregator(
            crawler_scrapers={"dead": crawler},
            line_http_transport=httpx.MockTransport(
                lambda request: httpx.Response(404, text="gone")
            ),
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            lines, health, diagnostics = await self.aggregator.resolve_source_matches(
                [
                    SourceMatch(
                        source_id="crawler:dead:1",
                        source_name="dead",
                        title="失效作品",
                        content_type="anime",
                        year=2025,
                    )
                ],
                episode=1,
                include_diagnostics=True,
            )

        self.assertEqual(lines, [])
        self.assertEqual(health, {"dead": UNAVAILABLE})
        self.assertEqual(diagnostics["dead"].error_category, STALE_ROUTE)

    async def test_malformed_hls_manifest_keeps_structured_error_category(self):
        self.aggregator = ContentAggregator(
            crawler_scrapers={},
            line_http_transport=httpx.MockTransport(
                lambda request: httpx.Response(200, text="not an hls manifest")
            ),
        )
        line = AggregatedVideoLine(
            url="https://cdn.example/broken.m3u8",
            format="hls",
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            result = await self.aggregator._line_verification_status(
                line,
                detailed=True,
            )

        self.assertIsInstance(result, LineVerificationResult)
        self.assertEqual(result.status, UNAVAILABLE)
        self.assertEqual(result.error_category, MALFORMED_MANIFEST)

    async def test_read_timeout_keeps_structured_error_category(self):
        def timeout(_request):
            raise httpx.ReadTimeout("slow media response")

        self.aggregator = ContentAggregator(
            crawler_scrapers={},
            line_http_transport=httpx.MockTransport(timeout),
        )
        line = AggregatedVideoLine(
            url="https://cdn.example/slow.m3u8",
            format="hls",
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            result = await self.aggregator._line_verification_status(
                line,
                detailed=True,
            )

        self.assertEqual(result.status, UNAVAILABLE)
        self.assertEqual(result.error_category, READ_TIMEOUT)

    async def test_parser_exception_is_reported_in_source_diagnostics(self):
        crawler = AsyncMock()
        crawler.content_types = ["anime"]
        crawler.get_video_urls = AsyncMock(
            side_effect=ValueError("unexpected source payload")
        )
        self.aggregator = ContentAggregator(
            crawler_scrapers={"broken": crawler}
        )

        lines, health, diagnostics = await self.aggregator.resolve_source_matches(
            [
                SourceMatch(
                    source_id="crawler:broken:1",
                    source_name="broken",
                    title="Broken Anime",
                    content_type="anime",
                    year=2025,
                )
            ],
            episode=1,
            include_diagnostics=True,
        )

        self.assertEqual(lines, [])
        self.assertEqual(health, {"broken": UNAVAILABLE})
        self.assertEqual(diagnostics["broken"].error_category, PARSER_MISMATCH)

    async def test_fake_ip_dns_result_is_deferred_to_public_only_client_probe(self):
        self.aggregator = ContentAggregator(crawler_scrapers={})
        line = AggregatedVideoLine(
            url="https://cdn.example/video.m3u8",
            format="hls",
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=False),
        ):
            status = await self.aggregator._line_verification_status(line)

        self.assertEqual(status, CLIENT_PROBE_REQUIRED)

    async def test_literal_private_media_address_is_never_sent_to_client(self):
        self.aggregator = ContentAggregator(crawler_scrapers={})
        line = AggregatedVideoLine(
            url="http://127.0.0.1/private.m3u8",
            format="hls",
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=False),
        ):
            result = await self.aggregator._line_verification_status(
                line,
                detailed=True,
            )

        self.assertEqual(result.status, UNAVAILABLE)
        self.assertEqual(result.error_category, NON_PUBLIC_TARGET)

    async def test_sinkholed_segment_host_is_reported_as_non_public_target(self):
        """A live manifest whose segments resolve to a sinkhole must not read
        as a parser problem: that mislabels DNS-blackholed sources."""
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200,
                text=(
                    "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n"
                    "#EXTINF:4,\nhttps://sinkholed.example/seg0.ts\n"
                ),
                headers={"content-type": "application/vnd.apple.mpegurl"},
            )

        aggregator = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler),
            crawler_scrapers={},
        )
        self.addAsyncCleanup(aggregator.aclose)
        line = AggregatedVideoLine(
            url="https://cdn.example/index.m3u8",
            format="hls",
        )

        async def only_manifest_is_public(url: str) -> bool:
            return "sinkholed.example" not in url

        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(side_effect=only_manifest_is_public),
        ):
            result = await aggregator._line_verification_status(
                line,
                detailed=True,
            )

        self.assertEqual(result.status, UNAVAILABLE)
        self.assertEqual(result.error_category, NON_PUBLIC_TARGET)

    async def test_search_uses_independent_crawler_without_upstream_aggregator(self):
        crawler = AsyncMock()
        crawler.content_types = ["anime"]
        crawler.search = AsyncMock(return_value=[
            SubjectResult(
                source_id="alma-1",
                title="小阿尔玛想要成为家人",
                type="anime",
                year=2025,
            )
        ])
        self.aggregator = ContentAggregator(
            crawler_scrapers={"agefans": crawler}
        )
        self.aggregator._maccms.search = AsyncMock(return_value=[])
        self.aggregator._tvbox.search = AsyncMock(return_value=[])

        results = await self.aggregator.search(
            "小阿尔玛想要成为家人", ["anime"], max_results=10
        )

        self.assertEqual(
            [item.id for item in results],
            ["crawler:agefans:alma-1"],
        )

    async def test_private_line_is_rejected_before_http_request(self):
        requests = 0

        def handler(request):
            nonlocal requests
            requests += 1
            return httpx.Response(200, text="#EXTM3U")

        self.aggregator = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler)
        )
        reachable = await self.aggregator._line_reachable(
            AggregatedVideoLine(
                url="http://127.0.0.1/private.m3u8",
                format="hls",
            )
        )

        self.assertFalse(reachable)
        self.assertEqual(requests, 0)

    async def test_public_hls_manifest_is_accepted_with_tls_verification(self):
        def handler(request):
            self.assertEqual(request.headers.get("range"), "bytes=0-65535")
            if request.url.path == "/segment-1.ts":
                payload = bytearray(188 * 2)
                payload[0] = 0x47
                payload[188] = 0x47
                return httpx.Response(
                    206,
                    headers={"content-type": "video/mp2t"},
                    content=bytes(payload),
                )
            return httpx.Response(
                200,
                headers={"content-type": "application/vnd.apple.mpegurl"},
                text="#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10,\nsegment-1.ts",
            )

        self.aggregator = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler)
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            result = await self.aggregator._line_verification_status(
                AggregatedVideoLine(
                    url="https://cdn.example/video.m3u8",
                    format="hls",
                ),
                detailed=True,
            )

        self.assertEqual(result.status, SERVER_VERIFIED)
        self.assertEqual(result.startup_profile, STARTUP_HLS)
        self.assertGreaterEqual(result.latency_ms, 0)

    async def test_mp4_verification_classifies_fast_start_and_tail_moov(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                206,
                headers={"content-type": "video/mp4"},
                content=_mp4_startup_sample(
                    moov_before_mdat="fast" in request.url.path
                ),
            )

        self.aggregator = ContentAggregator(
            crawler_scrapers={},
            line_http_transport=httpx.MockTransport(handler),
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            fast_start = await self.aggregator._line_verification_status(
                AggregatedVideoLine(
                    url="https://cdn.example/fast.mp4",
                    format="mp4",
                ),
                detailed=True,
            )
            tail_moov = await self.aggregator._line_verification_status(
                AggregatedVideoLine(
                    url="https://cdn.example/tail.mp4",
                    format="mp4",
                ),
                detailed=True,
            )

        self.assertEqual(fast_start.status, SERVER_VERIFIED)
        self.assertEqual(
            fast_start.startup_profile,
            STARTUP_MP4_FASTSTART,
        )
        self.assertEqual(tail_moov.status, SERVER_VERIFIED)
        self.assertEqual(
            tail_moov.startup_profile,
            STARTUP_MP4_TAIL_MOOV,
        )

    def test_mp4_startup_profile_is_conservative_for_fragmented_samples(self):
        fragmented_samples = (
            _iso_box(b"moof") + _iso_box(b"mdat"),
            _iso_box(b"styp", 24) + _iso_box(b"moof") + _iso_box(b"mdat"),
            _iso_box(b"ftyp", 24)
            + _iso_box(b"moov")
            + _iso_box(b"moof")
            + _iso_box(b"mdat"),
        )
        for sample in fragmented_samples:
            with self.subTest(sample=sample[4:8]):
                self.assertEqual(_mp4_startup_profile(sample), STARTUP_UNKNOWN)

        incomplete_mdat = (
            _iso_box(b"ftyp", 24)
            + (1024).to_bytes(4, "big")
            + b"mdat"
            + bytes(16)
        )
        self.assertEqual(
            _mp4_startup_profile(incomplete_mdat),
            STARTUP_UNKNOWN,
        )
        self.assertEqual(_mp4_startup_profile(b"not-an-mp4"), STARTUP_UNKNOWN)

    async def test_dash_startup_profile_remains_unknown(self):
        self.aggregator = ContentAggregator(
            crawler_scrapers={},
            line_http_transport=httpx.MockTransport(
                lambda request: httpx.Response(
                    200,
                    headers={"content-type": "application/dash+xml"},
                    text='<MPD type="static"><Period /></MPD>',
                )
            ),
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            result = await self.aggregator._line_verification_status(
                AggregatedVideoLine(
                    url="https://cdn.example/video.mpd",
                    format="dash",
                ),
                detailed=True,
            )

        self.assertEqual(result.status, SERVER_VERIFIED)
        self.assertEqual(result.startup_profile, STARTUP_UNKNOWN)

    async def test_hls_manifest_with_dead_first_segment_is_rejected(self):
        def handler(request):
            if request.url.path == "/missing.ts":
                return httpx.Response(404, text="gone")
            return httpx.Response(
                200,
                headers={"content-type": "application/vnd.apple.mpegurl"},
                text="#EXTM3U\n#EXTINF:10,\nmissing.ts",
            )

        self.aggregator = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler),
            crawler_scrapers={},
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            reachable = await self.aggregator._line_reachable(
                AggregatedVideoLine(
                    url="https://cdn.example/video.m3u8",
                    format="hls",
                )
            )

        self.assertFalse(reachable)

    async def test_encrypted_hls_requires_readable_key(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/video.m3u8":
                return httpx.Response(
                    200,
                    text=(
                        "#EXTM3U\n"
                        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
                        "#EXTINF:10,\nsegment.ts\n"
                    ),
                    headers={"content-type": "application/vnd.apple.mpegurl"},
                )
            if request.url.path == "/key.bin":
                return httpx.Response(403)
            if request.url.path == "/segment.ts":
                return httpx.Response(206, content=b"x" * 188)
            return httpx.Response(404)

        self.aggregator = ContentAggregator(
            crawler_scrapers={},
            line_http_transport=httpx.MockTransport(handler),
        )
        line = AggregatedVideoLine(
            url="https://media.example/video.m3u8",
            format="hls",
        )
        with patch(
            "server.aggregator._is_public_http_url",
            new=AsyncMock(return_value=True),
        ):
            status = await self.aggregator._line_verification_status(line)

        self.assertEqual(status, CLIENT_PROBE_REQUIRED)


if __name__ == "__main__":
    unittest.main()
