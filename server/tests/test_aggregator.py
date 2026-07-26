import unittest
from unittest.mock import AsyncMock, patch

import httpx

from server.aggregator import AggregatedVideoLine, ContentAggregator
from server.scrapers.base import SubjectResult, VideoLine


class AggregatorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        aggregator = getattr(self, "aggregator", None)
        if aggregator is not None:
            await aggregator.aclose()

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
        self.aggregator._get_anich_client = AsyncMock(return_value=None)
        self.aggregator._line_reachable = AsyncMock(return_value=True)

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
        self.assertEqual(health, {"agefans": True})

    async def test_stable_playback_discovers_configured_anich_client(self):
        client = AsyncMock()
        client.search = lambda keyword: [
            {
                "id": 289217,
                "title": "小阿尔玛想要成为家人",
                "year": 2025,
                "episodes_total": 11,
            }
        ]
        self.aggregator = ContentAggregator(crawler_scrapers={})
        self.aggregator._maccms.search = AsyncMock(return_value=[])
        self.aggregator._tvbox.search = AsyncMock(return_value=[])
        self.aggregator._get_anich_client = AsyncMock(return_value=client)

        matches = await self.aggregator.discover_source_matches(
            ["小阿尔玛想要成为家人"],
            content_type="anime",
            year=2025,
        )

        self.assertEqual([item.source_id for item in matches], ["anich:289217"])
        self.assertEqual(matches[0].source_name, "AniCh")

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
            reachable = await self.aggregator._line_reachable(
                AggregatedVideoLine(
                    url="https://cdn.example/video.m3u8",
                    format="hls",
                )
            )

        self.assertTrue(reachable)

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


if __name__ == "__main__":
    unittest.main()
