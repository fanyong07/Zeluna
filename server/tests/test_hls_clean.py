import unittest

import httpx

from server.scrapers.hls_clean import (
    clean_playlist,
    clean_url,
    is_master_playlist,
    needs_clean,
    pick_variant,
)

_HEAD = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n"


def _seg(duration: float, name: str) -> str:
    return f"#EXTINF:{duration:.3f},\n{name}\n"


def _feature_playlist() -> str:
    """20 条 10s 正片 + 中间插一簇 6 条 2s 广告(以 DISCONTINUITY 隔开)。"""
    parts = [_HEAD]
    for i in range(10):
        parts.append(_seg(10.0, f"main{i}.ts"))
    parts.append("#EXT-X-DISCONTINUITY\n")
    for i in range(6):
        parts.append(_seg(2.0, f"ad{i}.ts"))
    parts.append("#EXT-X-DISCONTINUITY\n")
    for i in range(10, 20):
        parts.append(_seg(10.0, f"main{i}.ts"))
    parts.append("#EXT-X-ENDLIST\n")
    return "".join(parts)


class CleanPlaylistTests(unittest.TestCase):
    def test_short_segment_cluster_group_is_cut(self):
        out, report = clean_playlist(_feature_playlist(), "https://cdn.example/v/")
        self.assertGreaterEqual(report.groups_cut, 1)
        self.assertEqual(report.segments_cut, 6)
        self.assertNotIn("ad0.ts", out)
        self.assertIn("main0.ts", out)
        self.assertIn("main19.ts", out)
        self.assertEqual(report.segments_kept, 20)

    def test_relative_uris_become_absolute(self):
        out, _ = clean_playlist(_feature_playlist(), "https://cdn.example/v/")
        self.assertIn("https://cdn.example/v/main0.ts", out)

    def test_endlist_is_emitted_after_media_segments(self):
        out, _ = clean_playlist(_feature_playlist(), "https://cdn.example/v/")
        lines = [line for line in out.splitlines() if line.strip()]
        self.assertEqual(lines[-1], "#EXT-X-ENDLIST")
        self.assertEqual(out.count("#EXT-X-ENDLIST"), 1)

    def test_encryption_key_is_kept_and_uri_absolutized(self):
        text = (
            _HEAD
            + '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1\n'
            + "".join(_seg(10.0, f"m{i}.ts") for i in range(6))
            + "#EXT-X-ENDLIST\n"
        )
        out, _ = clean_playlist(text, "https://cdn.example/v/")
        self.assertIn("#EXT-X-KEY", out)
        self.assertIn('URI="https://cdn.example/v/key.bin"', out)

    def test_mid_stream_key_rotation_is_preserved(self):
        text = (
            _HEAD
            + _seg(10.0, "a.ts")
            + '#EXT-X-KEY:METHOD=AES-128,URI="k2.bin"\n'
            + _seg(10.0, "b.ts")
            + "".join(_seg(10.0, f"c{i}.ts") for i in range(4))
            + "#EXT-X-ENDLIST\n"
        )
        out, _ = clean_playlist(text, "https://cdn.example/v/")
        self.assertIn('URI="https://cdn.example/v/k2.bin"', out)

    def test_isolated_short_segment_is_protected(self):
        # 单条 2s 分片夹在正片中间:孤立短分片不得剪(可能是正常换轨)
        text = (
            _HEAD
            + "".join(_seg(10.0, f"a{i}.ts") for i in range(5))
            + _seg(2.0, "lonely.ts")
            + "".join(_seg(10.0, f"b{i}.ts") for i in range(5))
            + "#EXT-X-ENDLIST\n"
        )
        out, report = clean_playlist(text, "https://cdn.example/v/")
        self.assertIn("lonely.ts", out)
        self.assertEqual(report.micro_cut, 0)

    def test_consecutive_short_segments_are_micro_cut(self):
        # 同组内连续 3 条短分片(无 DISCONTINUITY)→ 条目级剪裁
        text = (
            _HEAD
            + "".join(_seg(10.0, f"a{i}.ts") for i in range(6))
            + "".join(_seg(1.5, f"ad{i}.ts") for i in range(3))
            + "".join(_seg(10.0, f"b{i}.ts") for i in range(6))
            + "#EXT-X-ENDLIST\n"
        )
        out, report = clean_playlist(text, "https://cdn.example/v/")
        self.assertEqual(report.micro_cut, 3)
        for i in range(3):
            self.assertNotIn(f"ad{i}.ts", out)

    def test_playlist_without_ads_is_left_intact(self):
        text = (
            _HEAD
            + "".join(_seg(10.0, f"m{i}.ts") for i in range(12))
            + "#EXT-X-ENDLIST\n"
        )
        out, report = clean_playlist(text, "https://cdn.example/v/")
        self.assertFalse(report.changed)
        self.assertEqual(report.segments_kept, 12)
        self.assertEqual(out.count(".ts"), 12)

    def test_report_public_dict_has_no_media_urls(self):
        _out, report = clean_playlist(_feature_playlist(), "https://cdn.example/v/")
        public = report.as_public_dict()
        self.assertNotIn("cdn.example", str(public))
        self.assertIn("segments_cut", public)

    def test_empty_or_headerless_input_is_safe(self):
        for raw in ("", "#EXTM3U\n"):
            out, report = clean_playlist(raw, "https://cdn.example/v/")
            self.assertFalse(report.changed)
            self.assertIsInstance(out, str)


class MasterPlaylistTests(unittest.TestCase):
    _MASTER = (
        "#EXTM3U\n"
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
        "low/index.m3u8\n"
        '#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080\n'
        "high/index.m3u8\n"
    )

    def test_master_detection(self):
        self.assertTrue(is_master_playlist(self._MASTER))
        self.assertFalse(is_master_playlist(_HEAD + _seg(10, "a.ts")))

    def test_pick_variant_takes_highest_bandwidth(self):
        self.assertEqual(
            pick_variant(self._MASTER, "https://cdn.example/v/master.m3u8"),
            "https://cdn.example/v/high/index.m3u8",
        )


class NeedsCleanTests(unittest.TestCase):
    def test_only_hls_is_cleanable(self):
        self.assertTrue(needs_clean("https://cdn.example/a/index.m3u8"))
        self.assertTrue(needs_clean("https://cdn.example/a/opaque", "hls"))
        self.assertFalse(needs_clean("https://cdn.example/a/movie.mp4"))
        self.assertFalse(needs_clean("https://cdn.example/a/opaque", "mp4"))


class CleanUrlTests(unittest.IsolatedAsyncioTestCase):
    async def _run(self, handler, url, **kwargs):
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(handler)
        ) as client:
            return await clean_url(url, client=client, **kwargs)

    async def test_media_playlist_is_fetched_and_cleaned(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, text=_feature_playlist())

        result = await self._run(handler, "https://cdn.example/v/index.m3u8")
        self.assertIsNotNone(result)
        self.assertEqual(result.report.segments_cut, 6)
        self.assertIsNone(result.variant_url)

    async def test_master_playlist_follows_variant_then_cleans(self):
        master = MasterPlaylistTests._MASTER

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path.endswith("master.m3u8"):
                return httpx.Response(200, text=master)
            return httpx.Response(200, text=_feature_playlist())

        result = await self._run(handler, "https://cdn.example/v/master.m3u8")
        self.assertIsNotNone(result)
        self.assertEqual(result.variant_url, "https://cdn.example/v/high/index.m3u8")
        self.assertEqual(result.report.segments_cut, 6)

    async def test_upstream_failure_returns_none_for_caller_fallback(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(404, text="")

        self.assertIsNone(
            await self._run(handler, "https://cdn.example/v/index.m3u8")
        )

    async def test_transport_error_returns_none(self):
        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("boom", request=request)

        self.assertIsNone(
            await self._run(handler, "https://cdn.example/v/index.m3u8")
        )

    async def test_oversized_playlist_is_refused(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, text="#EXTM3U\n" + "x" * 5000)

        self.assertIsNone(
            await self._run(
                handler, "https://cdn.example/v/index.m3u8", max_bytes=1024
            )
        )

    async def test_referer_header_is_forwarded(self):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["referer"] = request.headers.get("Referer")
            return httpx.Response(200, text=_feature_playlist())

        await self._run(
            handler,
            "https://cdn.example/v/index.m3u8",
            headers={"Referer": "https://site.example/play"},
        )
        self.assertEqual(seen["referer"], "https://site.example/play")


if __name__ == "__main__":
    unittest.main()
