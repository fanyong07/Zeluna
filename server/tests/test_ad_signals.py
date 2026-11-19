"""``ad_signals`` 广告标记识别的固化测试。

清单样本取自真实上游形态:CUE-OUT/CUE-IN 成对、SCTE-35 负载、
DATERANGE 携带 SCTE、以及**不带任何标记**的干净清单(最要紧的反例)。
"""

from __future__ import annotations

import unittest

from server.scrapers.ad_signals import (
    AdCarrierCache,
    analyze_manifest,
    has_ad_markers,
)

_CLEAN = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10.000,
seg0.ts
#EXTINF:10.000,
seg1.ts
#EXTINF:10.000,
seg2.ts
#EXT-X-ENDLIST
"""

_CUE_PAIR = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.000,
seg0.ts
#EXT-X-CUE-OUT:30
#EXTINF:10.000,
ad0.ts
#EXTINF:10.000,
ad1.ts
#EXTINF:10.000,
ad2.ts
#EXT-X-CUE-IN
#EXTINF:10.000,
seg1.ts
#EXT-X-ENDLIST
"""

_SCTE = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-SCTE35:CUE="/DAvAAAAAAAA///wBQb+AAAAAAA="
#EXT-X-ASSET:CAID=0x0000000000000000
#EXTINF:6.000,
seg0.ts
#EXT-X-ENDLIST
"""

_DATERANGE = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-DATERANGE:ID="scte",START-DATE="2026-11-04T00:00:00Z",SCTE35-OUT=0xFC30
#EXTINF:6.000,
seg0.ts
#EXT-X-ENDLIST
"""

_UNCLOSED_CUE = """#EXTM3U
#EXT-X-VERSION:3
#EXTINF:10.000,
seg0.ts
#EXT-X-CUE-OUT:20
#EXTINF:10.000,
ad0.ts
#EXTINF:10.000,
ad1.ts
"""


class MarkerDetectionTests(unittest.TestCase):
    def test_clean_manifest_has_no_signals(self):
        signals = analyze_manifest(_CLEAN)
        self.assertEqual(signals.markers, [])
        self.assertFalse(signals.has_any_signal)
        self.assertFalse(signals.has_ad_break)
        self.assertFalse(has_ad_markers(_CLEAN))

    def test_cue_out_and_in_are_detected_and_paired(self):
        signals = analyze_manifest(_CUE_PAIR)
        kinds = [m.kind for m in signals.markers]
        self.assertEqual(kinds, ["cue_out", "cue_in"])
        self.assertTrue(signals.has_ad_break)
        self.assertEqual(len(signals.breaks), 1)
        ad_break = signals.breaks[0]
        self.assertEqual(ad_break.media_references,
                         ("ad0.ts", "ad1.ts", "ad2.ts"))
        self.assertEqual(ad_break.declared_seconds, 30.0)

    def test_scte35_and_asset_are_detected(self):
        signals = analyze_manifest(_SCTE)
        kinds = {m.kind for m in signals.markers}
        self.assertEqual(kinds, {"scte35", "asset"})
        # 这两种标记本身不界定区间,所以不应凭空造出广告区间
        self.assertEqual(signals.breaks, [])

    def test_daterange_carrying_scte35_is_detected(self):
        signals = analyze_manifest(_DATERANGE)
        self.assertEqual([m.kind for m in signals.markers], ["daterange_scte35"])

    def test_plain_daterange_without_scte_is_not_flagged(self):
        text = _DATERANGE.replace("SCTE35-OUT=0xFC30", "X-CUSTOM=1")
        self.assertEqual(analyze_manifest(text).markers, [])

    def test_unclosed_cue_out_spans_to_end_of_manifest(self):
        signals = analyze_manifest(_UNCLOSED_CUE)
        self.assertEqual(len(signals.breaks), 1)
        self.assertEqual(signals.breaks[0].media_references, ("ad0.ts", "ad1.ts"))

    def test_nested_cue_out_closes_previous_break(self):
        text = _UNCLOSED_CUE + "#EXT-X-CUE-OUT:10\nad2.ts\n"
        signals = analyze_manifest(text)
        self.assertEqual(len(signals.breaks), 2)

    def test_case_insensitive_tag_matching(self):
        text = _CUE_PAIR.replace("#EXT-X-CUE-OUT:30", "#ext-x-cue-out:30") \
                        .replace("#EXT-X-CUE-IN", "#EXT-X-Cue-In")
        self.assertEqual(len(analyze_manifest(text).markers), 2)

    def test_non_manifest_input_is_safe(self):
        for text in ("", "not a manifest", "<html></html>", "#EXTM3U"):
            with self.subTest(text=text):
                signals = analyze_manifest(text)
                self.assertIsInstance(signals.markers, list)

    def test_extinf_duration_in_payload_is_not_mistaken_for_seconds(self):
        # SCTE 负载里的十六进制量级不应被当成时长
        text = '#EXTM3U\n#EXT-X-CUE-OUT:0xFC30\nseg.ts\n'
        signals = analyze_manifest(text)
        self.assertEqual(signals.breaks[0].declared_seconds, 0.0)

    def test_declared_seconds_parses_common_forms(self):
        for payload, expected in (
            ("#EXT-X-CUE-OUT:30", 30.0),
            ("#EXT-X-CUE-OUT:30.000", 30.0),
            ("#EXT-X-CUE-OUT:DURATION=15", 15.0),
            ("#EXT-X-CUE-OUT", 0.0),
        ):
            with self.subTest(payload=payload):
                signals = analyze_manifest(
                    f"#EXTM3U\n{payload}\nseg.ts\n"
                )
                self.assertEqual(signals.breaks[0].declared_seconds, expected)


class AdCarrierCacheTests(unittest.TestCase):
    def test_unknown_url_returns_none_not_false(self):
        cache = AdCarrierCache()
        # 区分 None(没验过)与 False(确认干净)是这一层的关键语义
        self.assertIsNone(cache.carries_ads("https://a.example/x.m3u8"))

    def test_records_manifest_conclusion(self):
        cache = AdCarrierCache()
        self.assertTrue(
            cache.record_manifest("https://a.example/x.m3u8", _CUE_PAIR)
        )
        self.assertIs(
            cache.carries_ads("https://a.example/x.m3u8"), True
        )
        cache.record_manifest("https://b.example/y.m3u8", _CLEAN)
        self.assertIs(
            cache.carries_ads("https://b.example/y.m3u8"), False
        )

    def test_blank_url_is_ignored(self):
        cache = AdCarrierCache()
        cache.record("", True)
        cache.record("   ", True)
        self.assertEqual(len(cache), 0)

    def test_lru_eviction(self):
        cache = AdCarrierCache(max_entries=2)
        for i in range(4):
            cache.record(f"https://h{i}.example/x.m3u8", True)
        self.assertEqual(len(cache), 2)
        self.assertIsNone(cache.carries_ads("https://h0.example/x.m3u8"))
        self.assertIs(cache.carries_ads("https://h3.example/x.m3u8"), True)

    def test_forget_and_clear(self):
        cache = AdCarrierCache()
        cache.record("https://a.example/x", True)
        cache.forget("https://a.example/x")
        self.assertIsNone(cache.carries_ads("https://a.example/x"))
        cache.record("https://a.example/x", True)
        cache.clear()
        self.assertEqual(len(cache), 0)

    def test_public_dict_excludes_media_references(self):
        signals = analyze_manifest(_CUE_PAIR)
        payload = signals.as_public_dict()
        serialized = str(payload)
        self.assertNotIn("ad0.ts", serialized)
        self.assertNotIn("seg0.ts", serialized)


class RealUpstreamManifestTests(unittest.TestCase):
    """真实上游清单的回归基线。

    样本取自 2026-11 对 AniCh 官方转存线路的实测抓取(逐条 curl 拉回真实
    清单文本)。**官转存清单里没有任何广告标记**,只有连续等长的正片段:

        vod-cdn.sends.eu.org.cdn.cloudflare.net/video/zs/1080p/*.m3u8
        xgct-video.vzcdn.net/{uuid}/{1920x1080,1280x720,842x480,640x360}/video.m3u8

    这条基线的作用是**防止误报**:如果哪天判据放宽到把这些干净清单也算成
    "含广告",每个请求都会白加一跳重写,而这一跳是真金白银的起播延迟。
    """

    #: 官方转存的真实形态:无 DISCONTINUITY、无 CUE、片段等长。
    _OWN_CDN_MANIFEST = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.000,
b9356e6e0.ts
#EXTINF:4.000,
b9356e6e1.ts
#EXTINF:4.000,
b9356e6e2.ts
#EXTINF:3.960,
b9356e6e3.ts
#EXT-X-ENDLIST
"""

    _MULTIRATE_MANIFEST = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.006,
seg0.ts
#EXTINF:6.006,
seg1.ts
#EXTINF:6.006,
seg2.ts
#EXT-X-ENDLIST
"""

    def test_own_cdn_manifest_is_not_flagged(self):
        signals = analyze_manifest(self._OWN_CDN_MANIFEST)
        self.assertEqual(signals.markers, [])
        self.assertFalse(signals.has_ad_break)

    def test_multirate_manifest_is_not_flagged(self):
        signals = analyze_manifest(self._MULTIRATE_MANIFEST)
        self.assertEqual(signals.markers, [])

    def test_manifest_without_discontinuity_yields_no_breaks(self):
        # 没有 DISCONTINUITY 与 CUE 标记时,不应凭空造出广告区间
        self.assertEqual(analyze_manifest(self._OWN_CDN_MANIFEST).breaks, [])

    def test_uniform_segment_lengths_alone_are_not_a_signal(self):
        # 判据看的是标记与结构,不是"时长整齐"——整齐恰恰是正片的特征
        self.assertFalse(has_ad_markers(self._MULTIRATE_MANIFEST))


if __name__ == "__main__":
    unittest.main()
