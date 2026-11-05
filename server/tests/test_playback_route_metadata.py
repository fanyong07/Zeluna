"""Offline metadata provenance, strict boundaries and full route identity tests."""
from __future__ import annotations

from dataclasses import replace
import unittest
from unittest.mock import AsyncMock, patch

import httpx
import pytest

from server.aggregator import (
    AggregatedVideoLine, ContentAggregator, SERVER_VERIFIED, UNAVAILABLE,
    _line_metadata, _non_negative_metadata_int, _response_media_size,
)
from server.playback import PlaybackService


@pytest.mark.parametrize("value", [-1, -0.1, "-1", True, False, 1.5, "1.5", "NaN", float("nan"), float("inf"), 2**53, str(2**53), {}, []])
def test_metadata_rejects_non_integral_negative_or_lossy_values(value):
    assert _non_negative_metadata_int(value) is None


@pytest.mark.parametrize("value,expected", [(0, 0), ("0", 0), (1080.0, 1080), (" 1920 ", 1920), (2**53 - 1, 2**53 - 1)])
def test_metadata_accepts_exact_non_negative_json_integers(value, expected):
    assert _non_negative_metadata_int(value) == expected


@pytest.mark.parametrize("status,headers,expected", [
    (206, {"Content-Range": "bytes 0-99/500000000", "Content-Length": "100"}, 500000000),
    (206, {"Content-Length": "65536"}, None),
    (206, {"Content-Range": "bytes 0-99/*"}, None),
    (206, {"Content-Range": "bytes 0-99/99"}, None),
    (206, {"Content-Range": "bytes 100-99/200"}, None),
    (200, {"Content-Length": "-10"}, None),
    (200, {"Content-Length": "100", "Content-Encoding": "gzip"}, None),
])
def test_response_size_uses_only_whole_resource_evidence(status, headers, expected):
    assert _response_media_size(status, httpx.Headers(headers)) == expected


class PlaybackMetadataTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.owned = []
        self.requests = []

    async def asyncTearDown(self):
        for owner in reversed(self.owned):
            await owner.aclose()

    def aggregate(self, handler):
        def transport(request):
            self.requests.append(request.url.path)
            return handler(request)
        aggregator = ContentAggregator(crawler_scrapers={}, line_http_transport=httpx.MockTransport(transport))
        self.owned.append(aggregator)
        return aggregator

    async def probe(self, aggregator, path, fmt):
        with patch("server.aggregator._is_public_http_url", new=AsyncMock(return_value=True)):
            return await aggregator._line_verification_status(
                AggregatedVideoLine(url=f"https://cdn.example/{path}", format=fmt), detailed=True,
            )

    async def test_mp4_range_total_survives_public_serialization(self):
        aggregator = self.aggregate(lambda _: httpx.Response(
            206, content=b"video-data", headers={"Content-Type": "video/mp4", "Content-Range": "bytes 0-9/104857600"},
        ))
        result = await self.probe(aggregator, "file.mp4", "mp4")
        self.assertEqual(result.status, SERVER_VERIFIED)
        self.assertEqual(result.size_bytes, 104857600)
        service = PlaybackService(managed_lines_enabled=False)
        self.owned.append(service)
        item = service._line_dict(AggregatedVideoLine(
            url="https://cdn.example/file.mp4", source="crawler:fixture",
            verification_status=result.status, **_line_metadata(result),
        ))
        self.assertEqual(item["size_bytes"], 104857600)
        self.assertFalse(item["size_estimated"])
        self.assertIsNone(item["video_width"])
        self.assertIsNone(item["video_height"])
        self.assertEqual(self.requests, ["/file.mp4"])

    async def test_hls_explicit_variant_metadata_without_manifest_or_segment_size(self):
        master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"\nvariant\n'
        media = '#EXTM3U\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n'
        def response(request):
            if request.url.path == "/master.m3u8":
                return httpx.Response(200, text=master, headers={"Content-Type": "application/vnd.apple.mpegurl"})
            if request.url.path == "/variant":
                return httpx.Response(200, text=media)
            return httpx.Response(206, content=b"\x47" * 376, headers={"Content-Type": "video/mp2t", "Content-Range": "bytes 0-375/12345678"})
        result = await self.probe(self.aggregate(response), "master.m3u8", "hls")
        self.assertEqual(result.status, SERVER_VERIFIED)
        self.assertEqual((result.video_width, result.video_height, result.bitrate), (1920, 1080, 4000000))
        self.assertEqual(result.codecs, "avc1.640028,mp4a.40.2")
        self.assertTrue(result.adaptive)
        self.assertFalse(result.is_live)
        self.assertIsNone(result.size_bytes, "manifest Content-Length and first-segment total are not full media bytes")
        self.assertEqual(self.requests, ["/master.m3u8", "/variant", "/seg.ts"])

    async def test_hls_live_and_full_vod_byte_range_are_explicit_facts(self):
        for suffix, manifest, expected_size, live in (
            ("vod", '#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:500@0\nseg.ts\n#EXTINF:4,\n#EXT-X-BYTERANGE:700@500\nseg.ts\n#EXT-X-ENDLIST\n', 1200, False),
            ("live", '#EXTM3U\n#EXTINF:4,\nseg.ts\n', None, True),
        ):
            aggregator = self.aggregate(lambda request: httpx.Response(
                200, text=manifest,
            ) if request.url.path.endswith(".m3u8") else httpx.Response(200, content=b"\x47" * 376))
            result = await self.probe(aggregator, suffix + ".m3u8", "hls")
            self.assertEqual(result.size_bytes, expected_size)
            self.assertEqual(result.is_live, live)
            self.assertEqual(result.size_estimated, expected_size is not None)

    async def test_dash_text_length_is_not_video_size(self):
        result = await self.probe(self.aggregate(lambda _: httpx.Response(
            200, text='<MPD type="static"><Period/></MPD>', headers={"Content-Type": "application/dash+xml"},
        )), "manifest.mpd", "dash")
        self.assertIsNone(result.size_bytes)

    async def test_same_url_routes_and_unknown_chapters_have_independent_public_identity(self):
        service = PlaybackService(managed_lines_enabled=False)
        self.owned.append(service)
        original = AggregatedVideoLine(
            url="https://cdn.example/shared.m3u8", source="crawler:animeko:稀饭动漫:one",
            provider_id="crawler.animeko", rule_id="xfdmneo", rule_name="稀饭动漫", site_name="site.example",
        )
        peer = replace(original, source="crawler:animeko:稀饭动漫:two")
        unknown = replace(original, source="crawler:animeko:稀饭动漫:three", url="")
        serialized = [service._line_dict(line) for line in (original, peer, unknown)]
        self.assertEqual(len({item["line_id"] for item in serialized}), 3)
        self.assertTrue(all(item["provider_name"] == "稀饭动漫" for item in serialized))
        self.assertTrue(all(item["rule_id"] == "xfdmneo" for item in serialized))
        self.assertTrue(serialized[-1]["chapter_discovered"])
        self.assertFalse(serialized[-1]["available"])
        self.assertNotIn("client_resolver", serialized[-1])
        self.assertTrue(service._is_safe_inventory_item(serialized[-1]))
        self.assertEqual(len(service._merge_managed_lines([], serialized)), 3)
        invalid = replace(original, size_bytes=-1, video_width=1.5, video_height=True, bitrate=2**53, codecs="bad\ncodec")
        item = service._line_dict(invalid)
        self.assertTrue(all(item[key] is None for key in ("size_bytes", "video_width", "video_height", "bitrate")))
        self.assertEqual(item["codecs"], "")
        self.assertEqual(item["status"], UNAVAILABLE)
