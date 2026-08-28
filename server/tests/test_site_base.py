import unittest
from unittest.mock import patch

from server.scrapers.anime.site_base import (
    SITE_STATUS_OK,
    SITE_STATUS_PARSED_DEAD,
    EpisodeCandidate,
    SiteAnimeScraper,
    decode_play_url,
    safe_request_url,
    select_episode_candidates,
)


class SafeRequestUrlTests(unittest.TestCase):
    def test_ascii_url_is_untouched(self):
        url = "https://cdn.example/a/b.m3u8?x=1"
        self.assertEqual(safe_request_url(url), url)

    def test_chinese_path_is_percent_encoded(self):
        out = safe_request_url("https://cdn.example/新番/福利连01.m3u8")
        self.assertTrue(out.startswith("https://cdn.example/"))
        out.encode("ascii")  # 不抛异常即合法 URI
        self.assertIn("%E6", out)

    def test_already_encoded_parts_are_not_double_encoded(self):
        out = safe_request_url("https://cdn.example/%E6%96%B0/中文.m3u8")
        self.assertIn("%E6%96%B0", out)
        self.assertNotIn("%25E6", out)


class DecodePlayUrlTests(unittest.TestCase):
    def test_plaintext_mode(self):
        self.assertEqual(
            decode_play_url("https://cdn.example/a.m3u8", 0),
            "https://cdn.example/a.m3u8",
        )

    def test_urlencode_mode(self):
        self.assertEqual(
            decode_play_url("https%3A%2F%2Fcdn.example%2Fa.m3u8", 1),
            "https://cdn.example/a.m3u8",
        )

    def test_plain_base64_mode(self):
        import base64

        raw = "https://cdn.example/a.m3u8"
        encoded = base64.b64encode(raw.encode()).decode()
        self.assertEqual(decode_play_url(encoded, 2), raw)

    def test_double_layer_base64_of_urlencoded(self):
        import base64
        from urllib.parse import quote

        raw = "https://cdn.example/a.m3u8"
        encoded = base64.b64encode(quote(raw).encode()).decode()
        # 只解 base64 会停在 %68%74%74... 态;必须再解一层
        self.assertEqual(decode_play_url(encoded, 2), raw)

    def test_undecodable_payload_returns_original(self):
        self.assertEqual(decode_play_url("!!!not-base64!!!", 2), "!!!not-base64!!!")

    def test_blank_and_bad_mode_are_safe(self):
        self.assertEqual(decode_play_url("", 2), "")
        self.assertEqual(
            decode_play_url("https://cdn.example/a.m3u8", "weird"),
            "https://cdn.example/a.m3u8",
        )


def _line(line_key: str, labels: list[str]) -> list[EpisodeCandidate]:
    return [
        EpisodeCandidate(line_key=line_key, label=label,
                         page_path=f"/{line_key}/{i}.html", index=i)
        for i, label in enumerate(labels)
    ]


class SelectEpisodeCandidatesTests(unittest.TestCase):
    def test_every_line_contributes_one_candidate(self):
        """冗余是命门:5 条线路必须出 5 个候选,而非精确命中一条就收工。"""
        pool = []
        for n in range(5):
            pool += _line(f"line{n}", ["第1集", "第2集", "第3集"])
        picked = select_episode_candidates(pool, 2)
        self.assertEqual(len(picked), 5)
        self.assertEqual({p.line_key for p in picked}, {f"line{n}" for n in range(5)})
        self.assertTrue(all(p.label == "第2集" for p in picked))

    def test_unlabeled_line_falls_back_to_positional_pick(self):
        pool = _line("labeled", ["第1集", "第2集"]) + _line(
            "odd", ["HD中字", "OAD01", "特别篇"]
        )
        picked = select_episode_candidates(pool, 2)
        keys = {p.line_key: p.label for p in picked}
        self.assertEqual(keys["labeled"], "第2集")
        self.assertEqual(keys["odd"], "OAD01")     # 位置等价:该线路第 2 个

    def test_fullmatch_prevents_episode_one_swallowing_eleven(self):
        pool = _line("a", ["第11集", "第1集"])
        picked = select_episode_candidates(pool, 1)
        self.assertEqual(len(picked), 1)
        self.assertEqual(picked[0].label, "第1集")

    def test_zero_padded_and_variant_labels_match(self):
        for label in ("第01集", "01", "1话", "第1話"):
            pool = _line("a", [label])
            picked = select_episode_candidates(pool, 1)
            self.assertEqual(len(picked), 1, f"label={label} 未匹配")

    def test_string_episode_requires_exact_label(self):
        pool = _line("a", ["OAD01", "第1集"])
        picked = select_episode_candidates(pool, "OAD01")
        self.assertEqual([p.label for p in picked], ["OAD01"])

    def test_out_of_range_and_empty_inputs(self):
        self.assertEqual(select_episode_candidates([], 1), [])
        self.assertEqual(select_episode_candidates(_line("a", ["第1集"]), 99), [])
        self.assertEqual(select_episode_candidates(_line("a", ["第1集"]), 0), [])


class _DemoScraper(SiteAnimeScraper):
    site = "demo"
    family = "demo-family"
    default_base_url = "https://demo.example"
    detail_template = "/show/{sid}.html"
    play_link_patterns = (
        r'href="(/v/\d+-\d+-\d+\.html)"',
        r'href="(/play/\d+-\d+-\d+\.html)"',
    )

    # BaseScraper 是 ABC;本测试只验形态工具,取流链路由各站测试覆盖
    async def search(self, keyword: str):
        return []

    async def get_detail(self, source_id: str):
        return None

    async def get_video_urls(self, source_id: str, episode: int = 1):
        return []


class SiteAnimeScraperTests(unittest.TestCase):
    def setUp(self):
        self.scraper = _DemoScraper()

    def test_identity_and_content_types(self):
        self.assertEqual(self.scraper.name, "demo")
        self.assertEqual(self.scraper.content_types, ["anime"])
        self.assertEqual(self.scraper.status, SITE_STATUS_OK)

    def test_detail_url_from_template(self):
        self.assertEqual(
            self.scraper.detail_url("123"), "https://demo.example/show/123.html"
        )
        self.assertEqual(self.scraper.detail_url(" "), "")

    def test_base_url_switch_for_domain_rotation(self):
        self.scraper.with_base_url("https://newdomain.example/")
        self.assertEqual(self.scraper.base_url, "https://newdomain.example")
        self.assertEqual(
            self.scraper.detail_url("7"), "https://newdomain.example/show/7.html"
        )

    def test_play_links_use_first_matching_pattern_and_dedupe(self):
        html = (
            '<a href="/v/1-1-1.html">第01集</a>'
            '<a href="/v/1-1-2.html">第02集</a>'
            '<a href="/v/1-1-1.html">重复</a>'
            '<a href="/play/9-9-9.html">别的形态</a>'
        )
        links = self.scraper.extract_play_links(html)
        self.assertEqual(links, ["/v/1-1-1.html", "/v/1-1-2.html"])

    def test_play_links_empty_when_no_pattern_matches(self):
        self.assertEqual(self.scraper.extract_play_links("<a href='/x'>x</a>"), [])

    def test_player_config_parsing(self):
        html = '<script>var player_aaaa={"url":"abc","encrypt":2}</script>'
        cfg = self.scraper.parse_player_config(html)
        self.assertEqual(cfg["url"], "abc")
        self.assertEqual(cfg["encrypt"], 2)

    def test_player_config_missing_or_broken(self):
        self.assertEqual(self.scraper.parse_player_config("<html></html>"), {})
        self.assertEqual(
            self.scraper.parse_player_config("player_aaaa={broken;"), {}
        )

    def test_referer_header_only_when_enabled(self):
        headers = self.scraper.request_headers(referer="https://demo.example/x")
        self.assertEqual(headers["Referer"], "https://demo.example/x")

        class NoReferer(_DemoScraper):
            send_referer = False

        self.assertNotIn(
            "Referer", NoReferer().request_headers(referer="https://demo.example/x")
        )

    def test_session_cookie_from_environment(self):
        with patch.dict("os.environ", {"SCRAPER_COOKIE_DEMO": "PHPSESSID=abc"}):
            self.assertEqual(self.scraper.session_cookie(), "PHPSESSID=abc")
            headers = self.scraper.request_headers()
            self.assertEqual(headers["Cookie"], "PHPSESSID=abc")

    def test_no_cookie_when_env_absent_or_blank(self):
        with patch.dict("os.environ", {"SCRAPER_COOKIE_DEMO": "   "}):
            self.assertIsNone(self.scraper.session_cookie())

    def test_parsed_dead_status_is_expressible(self):
        class Dead(_DemoScraper):
            status = SITE_STATUS_PARSED_DEAD

        self.assertEqual(Dead().status, SITE_STATUS_PARSED_DEAD)


if __name__ == "__main__":
    unittest.main()
