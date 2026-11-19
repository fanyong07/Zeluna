import unittest
from unittest.mock import patch

from server.aggregator import AggregatedVideoLine
from server.playback import AD_RISK_HOST_HINTS, PlaybackService
from server.scrapers.ad_signals import AD_CARRIER_CACHE

_STRONG_KEY = "z3luna-ad-filter-test-key-0123456789abcdef"
_BASE = "https://api.example.test"


class _PlayableUrlMixin:
    """只提供 ``_playable_url`` 的调用环境,不含任何 ``test_`` 方法。"""

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


class AdFilterWiringTests(_PlayableUrlMixin, unittest.TestCase):
    """采集站的 m3u8 常插贴片广告,这类线路直接下发已剪好的清单地址。

    客户端不需要知道"广告"这件事,也不需要任何开关 —— 拿到的地址就是
    干净的(与 AniCh 的做法一致:服务端包装,客户端只管播)。
    """

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


class AdCarrierCacheWiringTests(_PlayableUrlMixin, unittest.TestCase):
    """验线时判定"这条清单带不带广告",播放时据此决定要不要剪裁。

    这是把剪裁从"按主机猜"升级成"按事实定"的那一层:验线本来就读了清单,
    结论按地址记下来,播放请求不必再读一次。
    """

    def setUp(self):
        super().setUp()
        # 每条用例用干净缓存,避免跨用例串味
        patcher = patch("server.playback.AD_CARRIER_CACHE", AD_CARRIER_CACHE)
        patcher.start()
        self.addCleanup(patcher.stop)
        AD_CARRIER_CACHE.clear()

    def test_confirmed_clean_manifest_passes_through_even_on_risky_host(self):
        # 风险名单上的采集站,但清单已验过且确认干净 → 不该白加一跳
        url = "https://v.lzcdn27.com/abc/index.m3u8"
        AD_CARRIER_CACHE.record(url, False)
        self.assertEqual(self._url(url), url)

    def test_confirmed_ad_carrying_manifest_is_rewritten(self):
        url = "https://v.lzcdn27.com/abc/index.m3u8"
        AD_CARRIER_CACHE.record(url, True)
        out = self._url(url)
        self.assertTrue(out.startswith(f"{_BASE}/api/v3/playlist/"))

    def test_unknown_host_is_not_rewritten(self):
        # 没验过 + 不在风险名单 → 保守,不重写
        url = "https://cdn.example.com/a/index.m3u8"
        out = self._url(url)
        self.assertEqual(out, url)

    def test_unknown_host_confirmed_ad_carrying_is_rewritten(self):
        # 没验过时保守,但**验过并确认含广告**就该剪 —— 与主机无关
        url = "https://cdn.example.com/a/index.m3u8"
        AD_CARRIER_CACHE.record(url, True)
        out = self._url(url)
        self.assertTrue(out.startswith(f"{_BASE}/api/v3/playlist/"))

    def test_verification_records_the_conclusion(self):
        from server.scrapers.ad_signals import analyze_manifest

        manifest_with_ads = (
            "#EXTM3U\n#EXTINF:10,\nseg0.ts\n"
            "#EXT-X-CUE-OUT:30\n#EXTINF:10,\nad0.ts\n#EXT-X-CUE-IN\n"
            "#EXTINF:10,\nseg1.ts\n#EXT-X-ENDLIST\n"
        )
        AD_CARRIER_CACHE.record_manifest(
            "https://site.example/a/index.m3u8", manifest_with_ads
        )
        self.assertIs(
            AD_CARRIER_CACHE.carries_ads("https://site.example/a/index.m3u8"),
            True,
        )
        self.assertTrue(analyze_manifest(manifest_with_ads).has_ad_break)

    def test_clean_manifest_detected_as_clean(self):
        AD_CARRIER_CACHE.record_manifest(
            "https://site.example/b/index.m3u8",
            "#EXTM3U\n#EXTINF:10,\nseg0.ts\n#EXTINF:10,\nseg1.ts\n#EXT-X-ENDLIST\n",
        )
        self.assertIs(
            AD_CARRIER_CACHE.carries_ads("https://site.example/b/index.m3u8"),
            False,
        )


if __name__ == "__main__":
    unittest.main()
