import unittest

from server.aggregator import AggregatedVideoLine, _crawler_line_source
from server.playback import PlaybackService


class CrawlerLineSourceTests(unittest.TestCase):
    """聚合类源单集返回数十条线路,每条必须保留自己的标识。

    写死成站名会让它们共用一个身份,客户端按 provider|来源名 折叠卡片时
    只剩一条 —— 这是实际踩过的问题。
    """

    def test_upstream_line_tag_is_preserved(self):
        self.assertEqual(
            _crawler_line_source("anich", "hb-10"), "crawler:anich:hb-10"
        )

    def test_site_prefixed_tag_is_normalized(self):
        # 适配器若把站名当前缀,只取线路标识部分,不重复站名
        self.assertEqual(
            _crawler_line_source("anich", "anich:jk-18"), "crawler:anich:jk-18"
        )

    def test_tag_equal_to_site_falls_back_to_plain_source(self):
        self.assertEqual(_crawler_line_source("anich", "anich"), "crawler:anich")
        self.assertEqual(_crawler_line_source("girigiri", "girigiri"), "crawler:girigiri")

    def test_blank_tag_falls_back_to_plain_source(self):
        for blank in ("", "   ", None):
            self.assertEqual(_crawler_line_source("yhdmm", blank), "crawler:yhdmm")

    def test_distinct_tags_yield_distinct_sources(self):
        tags = ["hb-10", "hc-5", "jk-18", "xk-12", "ek-20"]
        sources = {_crawler_line_source("anich", tag) for tag in tags}
        self.assertEqual(len(sources), len(tags))


class LineIdentityFieldsTests(unittest.TestCase):
    """对外字段只暴露线路标识,不暴露上游聚合服务的名字。"""

    def setUp(self):
        self.service = PlaybackService.__new__(PlaybackService)

    def _fields(self, source: str) -> dict:
        return self.service._line_identity_fields(
            AggregatedVideoLine(url="https://cdn.example/x.m3u8", source=source)
        )

    def test_line_tag_is_exposed_instead_of_the_aggregator_name(self):
        fields = self._fields("crawler:anich:hb-10")
        self.assertEqual(fields["provider_name"], "hb-10")
        self.assertEqual(fields["tag"], "hb-10")

    def test_aggregator_name_never_reaches_the_client(self):
        for source in (
            "crawler:anich:hb-10",
            "crawler:anich:jk-18",
            "crawler:anich:xk-12",
        ):
            rendered = str(self._fields(source))
            self.assertNotIn(
                "anich", rendered, f"聚合器名泄漏到对外字段: {source}"
            )

    def test_plain_site_sources_expose_the_site_name(self):
        # 独立站(非聚合)本来就该显示自己的站名
        self.assertEqual(self._fields("crawler:girigiri")["tag"], "girigiri")
        self.assertEqual(self._fields("crawler:yhdmm")["tag"], "yhdmm")

    def test_aggregate_sources_add_no_identity_fields(self):
        # maccms 走各站自己的名字,不需要覆盖
        self.assertEqual(self._fields("aggregate.maccms"), {})
        self.assertEqual(self._fields(""), {})

    def test_each_line_gets_a_distinct_identity(self):
        tags = ("hb-10", "hc-5", "jk-18", "xk-12")
        names = {
            self._fields(f"crawler:anich:{tag}")["provider_name"] for tag in tags
        }
        self.assertEqual(len(names), len(tags))


if __name__ == "__main__":
    unittest.main()
