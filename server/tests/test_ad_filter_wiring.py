import unittest
from unittest.mock import patch

from server.aggregator import AggregatedVideoLine
from server.playback import AD_RISK_HOST_HINTS, PlaybackService

_STRONG_KEY = "z3luna-ad-filter-test-key-0123456789abcdef"
_BASE = "https://api.example.test"


class AdFilterWiringTests(unittest.TestCase):
    """采集站的 m3u8 常插贴片广告,这类线路直接下发已剪好的清单地址。

    客户端不需要知道"广告"这件事,也不需要任何开关 —— 拿到的地址就是
    干净的(与 AniCh 的做法一致:服务端包装,客户端只管播)。
    """

    def setUp(self):
        for target, kwargs in (
            ("server.playlist_tokens.signing_key", {"return_value": _STRONG_KEY}),
            ("server.playback.PUBLIC_BASE_URL", {"new": _BASE}),
        ):
            patcher = patch(target, **kwargs)
            patcher.start()
            self.addCleanup(patcher.stop)
        # 只用纯函数部分,不起数据库
        self.service = PlaybackService.__new__(PlaybackService)

    def _url(self, url: str, fmt: str = "hls", headers=None) -> str:
        line = AggregatedVideoLine(
            url=url, format=fmt, headers=headers or {}, source="aggregate.maccms"
        )
        return self.service._playable_url(line)

    def test_collection_site_hls_is_served_through_the_cleaner(self):
        out = self._url("https://v.lzcdn27.com/abc/index.m3u8")
        self.assertTrue(out.startswith(f"{_BASE}/api/v3/playlist/"))
        # 地址是绝对的,客户端可直接播
        self.assertTrue(out.startswith("https://"))

    def test_token_is_opaque_and_hides_the_origin_url(self):
        out = self._url("https://v.lzcdn27.com/abc/index.m3u8")
        self.assertNotIn("lzcdn27", out)
        self.assertNotIn("index.m3u8", out)

    def test_own_cdn_lines_pass_through_untouched(self):
        # 自建 CDN 的官方转存通常无贴片,重写只会白加一跳延迟
        url = "https://vod-cdn.sends.eu.org.cdn.cloudflare.net/video/zs/x.m3u8"
        self.assertEqual(self._url(url), url)

    def test_object_storage_lines_pass_through_untouched(self):
        url = "https://v1.adkwai.com/bs2/adVideoLp/x.m3u8"
        self.assertEqual(self._url(url), url)

    def test_mp4_sources_pass_through(self):
        # 整包源无法按分片剪,只能换线
        url = "https://v.lzcdn27.com/abc/movie.mp4"
        self.assertEqual(self._url(url, fmt="mp4"), url)

    def test_blank_or_malformed_urls_are_safe(self):
        for url in ("", "   ", "not-a-url"):
            self.assertEqual(self._url(url), url.strip())

    def test_referer_is_carried_into_the_token(self):
        from server.playlist_tokens import parse_playlist_token

        out = self._url(
            "https://v.lzcdn27.com/abc/index.m3u8",
            headers={"Referer": "https://site.example/play"},
        )
        target = parse_playlist_token(out.rsplit("/", 1)[-1])
        self.assertEqual(target.url, "https://v.lzcdn27.com/abc/index.m3u8")
        self.assertEqual(target.referer, "https://site.example/play")

    def test_weak_signing_key_falls_back_to_the_origin_url(self):
        from server.auth import AuthConfigurationError

        url = "https://v.lzcdn27.com/abc/index.m3u8"
        with patch(
            "server.playlist_tokens.signing_key",
            side_effect=AuthConfigurationError("weak"),
        ):
            self.assertEqual(self._url(url), url)

    def test_missing_public_base_url_falls_back_to_the_origin_url(self):
        url = "https://v.lzcdn27.com/abc/index.m3u8"
        with patch("server.playback.PUBLIC_BASE_URL", ""):
            self.assertEqual(self._url(url), url)

    def test_risk_hints_cover_the_hosts_seen_in_production(self):
        # 这些主机出现在实测的 404/贴片线路里
        for fragment in ("lzcdn", "fengbao", "xgplay", "fsvod", "yhdmm3u8"):
            self.assertIn(fragment, AD_RISK_HOST_HINTS)


if __name__ == "__main__":
    unittest.main()
