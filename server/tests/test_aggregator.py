import unittest
from unittest.mock import AsyncMock, patch

import httpx

from server.aggregator import AggregatedVideoLine, ContentAggregator
from server.scrapers.base import SubjectResult


class AggregatorTests(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        aggregator = getattr(self, "aggregator", None)
        if aggregator is not None:
            await aggregator.aclose()

    async def test_same_title_from_different_maccms_sites_is_preserved(self):
        self.aggregator = ContentAggregator()
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
            return httpx.Response(
                200,
                headers={"content-type": "application/vnd.apple.mpegurl"},
                text="#EXTM3U\n#EXT-X-VERSION:3",
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


if __name__ == "__main__":
    unittest.main()
