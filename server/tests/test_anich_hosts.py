"""``anich_hosts`` 主机族判定的固化测试。

每条断言都对应 2026-11 实测清单里的一种真实线路形态;random 数据不参与
判定,避免"改判据就改测试期望"的自我循环。
"""

from __future__ import annotations

import unittest

from server.scrapers.anime import anich_hosts
from server.scrapers.anime.anich_hosts import HostRole


class ClassifyTests(unittest.TestCase):
    # ── 自建 CDN ──────────────────────────────────────────────
    def test_v_cdn_token_line_is_self_hosted(self):
        url = ("https://v-cdn.emmmm.eu.org/video/"
               "Dg9ZlwfSAxnNlxyTmda1mwmWmdeTC2CVB1fvwhjyEK5SrwLLrfLUqKvXr2DiqKqXrNnMuufcr2qYrxvZnwO=")
        self.assertIs(anich_hosts.classify(url), HostRole.SELF_HOSTED)
        self.assertTrue(anich_hosts.is_self_hosted(url))

    def test_vod_cdn_cloudflare_alias_is_self_hosted(self):
        # 自建域以 cloudflare 托管别名形式出现,必须因子串命中
        url = "https://vod-cdn.sends.eu.org.cdn.cloudflare.net/video/zs/720p/87a8598f.m3u8"
        self.assertIs(anich_hosts.classify(url), HostRole.SELF_HOSTED)

    def test_vod_cdn_redirect_target_is_partner_edge(self):
        url = ("https://bkqiuqiu.xn--vhq3x51dn9bivas49nfps.com/within/playaddr/"
               "getaddr.m3u8?vcode=TPVCODE3ee9&definition=720P&vcodec=libx264")
        self.assertIs(anich_hosts.classify(url), HostRole.PARTNER_EDGE)

    # ── 大厂对象存储 ───────────────────────────────────────────
    def test_byte_cdn_signature_line_is_object_store(self):
        url = ("https://lf16-faceu-file-sign.bytecdn.com/obj/tos-alisg-v-0051c001-sg/"
               "oQUXrXzNlEieDYnBEqGgHBD1FsfQABGd2Eus5j?x-expires=1794344219&x-signature=abc")
        self.assertIs(anich_hosts.classify(url), HostRole.OBJECT_STORE)
        self.assertTrue(anich_hosts.is_object_store(url))

    def test_vzcdn_multirate_hls_is_object_store(self):
        url = "https://xgct-video.vzcdn.net/9118edb9-3f19-4e4f-8b6e-135801efe153/842x480/video.m3u8"
        self.assertIs(anich_hosts.classify(url), HostRole.OBJECT_STORE)

    def test_xiaohongshu_playlist_is_object_store(self):
        url = "https://picasso-static.xiaohongshu.com/file/1dd6811d08b3f044f92ee8f210469583/index.m3u8"
        self.assertIs(anich_hosts.classify(url), HostRole.OBJECT_STORE)

    # ── 采集站 HLS ────────────────────────────────────────────
    def test_site_hls_hosts(self):
        for url in (
            "https://m3u8.dlidli.cc/mmmm/0155D045642183CF651C6BE8D5D91319.m3u8",
            "https://m3u8132.yhdmm3u8.top/videos/202609/20/6aaf/index.m3u8",
            "https://yun.92cj.com/video/dmhls/bushanjiao01V2.m3u8",
            "https://akua.girigirilove.com/zijian/oldanime/2026/10/Horemajo/01/playlist.m3u8",
        ):
            with self.subTest(url=url):
                self.assertIs(anich_hosts.classify(url), HostRole.SITE_HLS)

    # ── 广告素材 ──────────────────────────────────────────────
    def test_kwai_ad_delivery_path_is_ad_creative(self):
        # 实测 97 条;主机 kwai.net 同时承载正片转存,只能靠路径判定
        url = ("https://v1.adkwai.com/bs2/adVideoLp/"
               "YWQtYWRWaWRlb0xwOmFkX2FsbGlhbmNlX3NzcDo1NDIwMTQ2OTkxOk1FUkNIQU5UOltCQDQyMjQ2ODU3.mp4")
        self.assertIs(anich_hosts.classify(url), HostRole.AD_CREATIVE)
        self.assertTrue(anich_hosts.is_ad_creative(url))

    def test_ffnews_feedback_creatives_are_ad_creative(self):
        url = "https://cos.ffnews.cn/feedback/20260918/6aad0bfa3ea8f.png"
        self.assertIs(anich_hosts.classify(url), HostRole.AD_CREATIVE)

    def test_kwai_i18n_dsp_directory_is_ad_creative(self):
        # 实测漏网路径:明文 DSP 目录,挂在混合域 s1.kwai.net 上
        url = ("https://s1.kwai.net/bs2/ad-i18n-dsp/"
               "1ebc9bb889fa4155bf56beae45772321.mp4")
        self.assertIs(anich_hosts.classify(url), HostRole.AD_CREATIVE)
        self.assertTrue(anich_hosts.is_ad_creative(url))

    def test_kwai_photo_dsp_upload_is_ad_creative(self):
        # 实测漏网路径:文件名是 base64,解码后为 ``ad_dsp_photo_upload:...``,
        # 所以不能只匹配明文 ``ad-`` 前缀
        import base64

        payload = base64.b64encode(
            b"ad_dsp_photo_upload:5420146991:MERCHANT:[B@b88fdac:236997562519 91"
        ).decode()
        url = (f"https://v1.adkwai.com/bs2/photo-dsp-photo-upload/"
               f"{payload}.mp4")
        self.assertIs(anich_hosts.classify(url), HostRole.AD_CREATIVE)
        decoded = base64.b64decode(payload.split(":")[0] + "==")
        self.assertIn(b"dsp", decoded.lower())

    def test_yximgs_ad_subdomain_is_ad_creative_but_others_are_not(self):
        # v1-ad 子域整域是素材;同域其它子域仍有正片转存
        ad = "https://v1-ad.video.yximgs.com/bs2/adVideoLp/YWQ.mp4"
        real = "https://v2.video.yximgs.com/bs2/normal/YWQ.mp4"
        self.assertIs(anich_hosts.classify(ad), HostRole.AD_CREATIVE)
        self.assertIsNot(anich_hosts.classify(real), HostRole.AD_CREATIVE)

    def test_ordinary_paths_containing_dsp_like_words_are_safe(self):
        # ``dsp`` 判据必须按词元边界生效,不能命中正常目录名
        for url in (
            "https://cdn.example.com/video/dsp/lesson1.m3u8",   # 目录确实叫 dsp
            "https://s1.kwai.net/bs2/normal/lesson.mp4",
            "https://v1.adkwai.com/bs2/normal/wordspersec.mp4",  # 词中不含 dsp 词元
        ):
            with self.subTest(url=url):
                # 前两者:路径里 dsp 不是投放目录,按对象存储处理即可
                self.assertIsNot(anich_hosts.classify(url), HostRole.AD_CREATIVE)

    def test_object_store_without_ad_path_stays_object_store(self):
        # 同一主机的非投放路径不能被误判成贴片
        url = "https://v1.adkwai.com/bs2/normal/YWQtYWRWaWRlb0xw.mp4"
        self.assertIs(anich_hosts.classify(url), HostRole.OBJECT_STORE)

    # ── 容错 ──────────────────────────────────────────────────
    def test_unknown_and_malformed_urls_never_raise(self):
        for url in ("", "not-a-url", "https://", "ftp://x/y.mp4", "http://[bad"):
            with self.subTest(url=url):
                self.assertIs(anich_hosts.classify(url), HostRole.UNKNOWN)

    # ── 延迟带与排序语义 ──────────────────────────────────────
    def test_object_store_band_is_faster_than_self_hosted(self):
        object_store = anich_hosts.latency_band(
            "https://v1.adkwai.com/bs2/normal/x.mp4")
        self_hosted = anich_hosts.latency_band(
            "https://vod-cdn.sends.eu.org.cdn.cloudflare.net/video/zs/720p/x.m3u8")
        self.assertLess(object_store, self_hosted)

    def test_identity_tags_do_not_leak_upstream_name(self):
        for url in (
            "https://v-cdn.emmmm.eu.org/video/abc",
            "https://v1.adkwai.com/bs2/normal/x.mp4",
            "https://m3u8.dlidli.cc/mmmm/x.m3u8",
        ):
            tag = anich_hosts.identity_tag(url)
            self.assertNotIn("anich", tag.lower())
            self.assertNotIn("emmmm", tag.lower())
            self.assertNotIn("sends", tag.lower())


if __name__ == "__main__":
    unittest.main()