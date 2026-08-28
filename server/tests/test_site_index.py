import unittest

import httpx

from server.scrapers.site_index import (
    SiteIndex,
    build_index,
    extract_entries,
    normalize_title,
    paginate,
)

_DETAIL_PAT = r"/show/(\d+)\.html"


def _card(sid: int, title: str, note: str = "更新至第12集") -> str:
    return (
        f'<div class="item"><a href="/show/{sid}.html" title="{title}">'
        f"<img src='/x.jpg'></a><span>{note}</span></div>"
    )


class NormalizeTitleTests(unittest.TestCase):
    def test_strips_whitespace_and_update_noise(self):
        self.assertEqual(normalize_title(" 葬送的芙莉莲 更新至第12集 "), "葬送的芙莉莲")
        self.assertEqual(normalize_title("死神 千年血战篇 完结"), "死神千年血战篇")
        self.assertEqual(normalize_title("咒术回战 中字"), "咒术回战")

    def test_empty_input(self):
        self.assertEqual(normalize_title(""), "")
        self.assertEqual(normalize_title("   "), "")


class ExtractEntriesTests(unittest.TestCase):
    def test_prefers_title_attribute(self):
        html = _card(101, "葬送的芙莉莲") + _card(102, "咒术回战")
        self.assertEqual(
            extract_entries(html, _DETAIL_PAT),
            [("101", "葬送的芙莉莲"), ("102", "咒术回战")],
        )

    def test_falls_back_to_adjacent_text(self):
        html = '<li><a href="/show/205.html">紫罗兰永恒花园</a></li>'
        entries = extract_entries(html, _DETAIL_PAT)
        self.assertEqual(entries[0][0], "205")
        self.assertIn("紫罗兰", entries[0][1])

    def test_duplicate_sids_collapse(self):
        html = _card(101, "作品A") + _card(101, "作品A")
        self.assertEqual(len(extract_entries(html, _DETAIL_PAT)), 1)

    def test_invalid_pattern_and_empty_html_are_safe(self):
        self.assertEqual(extract_entries("", _DETAIL_PAT), [])
        self.assertEqual(extract_entries("<a>x</a>", "([unclosed"), [])


class PaginateTests(unittest.TestCase):
    def test_known_shapes(self):
        self.assertEqual(paginate("/list/1.html", 3), "/list/1-3.html")
        self.assertEqual(
            paginate("/vodshow/2--------1---/", 4), "/vodshow/2--------4---/"
        )
        self.assertEqual(paginate("/type_5.html", 2), "/type_5-2.html")
        self.assertEqual(
            paginate("/s/ribendongman.html", 2), "/s/ribendongman-2.html"
        )

    def test_first_page_is_unchanged_and_unknown_shape_is_none(self):
        self.assertEqual(paginate("/whatever", 1), "/whatever")
        self.assertIsNone(paginate("/whatever", 2))


class SiteIndexSearchTests(unittest.TestCase):
    def setUp(self):
        self.index = SiteIndex(site="demo")
        for sid, title in (
            ("1", "葬送的芙莉莲"),
            ("2", "葬送的芙莉莲 第二季"),
            ("3", "咒术回战"),
            ("4", "死神 千年血战篇"),
        ):
            self.index.add(sid, title)

    def test_exact_match_ranks_first(self):
        hits = self.index.search("咒术回战")
        self.assertEqual(hits[0][0], "3")
        self.assertEqual(hits[0][2], 1.0)

    def test_containment_matches_both_seasons(self):
        hits = self.index.search("葬送的芙莉莲")
        sids = {h[0] for h in hits}
        self.assertIn("1", sids)
        self.assertIn("2", sids)
        # 完全相等的应排在包含关系之前
        self.assertEqual(hits[0][0], "1")

    def test_unrelated_keyword_returns_nothing(self):
        self.assertEqual(self.index.search("流浪地球"), [])

    def test_limit_is_respected(self):
        self.assertLessEqual(len(self.index.search("的", limit=2)), 2)

    def test_add_rejects_blanks_and_duplicates(self):
        self.assertFalse(self.index.add("", "x"))
        self.assertFalse(self.index.add("9", ""))
        self.assertTrue(self.index.add("9", "新作品"))
        self.assertFalse(self.index.add("9", "新作品"))

    def test_roundtrip_serialization(self):
        data = self.index.to_dict()
        restored = SiteIndex.from_dict(data)
        self.assertEqual(restored.size, self.index.size)
        self.assertEqual(restored.search("咒术回战")[0][0], "3")

    def test_age_hours_reports_infinity_when_never_built(self):
        self.assertEqual(SiteIndex(site="x").age_hours(), float("inf"))
        self.index.built_at = 1000.0
        self.assertAlmostEqual(self.index.age_hours(now=1000.0 + 7200), 2.0, places=3)


class BuildIndexTests(unittest.IsolatedAsyncioTestCase):
    async def _build(self, handler, **kwargs):
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(handler)
        ) as client:
            return await build_index(
                site="demo",
                base_url="https://demo.example",
                list_paths=kwargs.pop("list_paths", ("/list/1.html",)),
                detail_pattern=_DETAIL_PAT,
                client=client,
                request_gap_seconds=0.0,
                **kwargs,
            )

    async def test_multi_page_index_accumulates(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/list/1.html":
                return httpx.Response(200, text=_card(1, "作品一") + _card(2, "作品二"))
            if request.url.path == "/list/1-2.html":
                return httpx.Response(200, text=_card(3, "作品三"))
            return httpx.Response(404, text="")

        index = await self._build(handler, pages=3)
        self.assertEqual(index.size, 3)
        self.assertGreater(index.built_at, 0)

    async def test_cached_pagination_stops_early(self):
        calls = []

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append(request.url.path)
            # 所有页返回同一内容 = 分页被缓存
            return httpx.Response(200, text=_card(1, "作品一"))

        index = await self._build(handler, pages=5)
        self.assertEqual(index.size, 1)
        # 第 2 页发现内容重复即停,不会打满 5 页
        self.assertLessEqual(len(calls), 2)

    async def test_http_error_stops_that_path_without_raising(self):
        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("boom", request=request)

        index = await self._build(handler, pages=3)
        self.assertEqual(index.size, 0)

    async def test_multiple_list_paths_are_merged(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/list/1.html":
                return httpx.Response(200, text=_card(1, "作品一"))
            if request.url.path == "/list/2.html":
                return httpx.Response(200, text=_card(2, "作品二"))
            return httpx.Response(404, text="")

        index = await self._build(
            handler, pages=1, list_paths=("/list/1.html", "/list/2.html")
        )
        self.assertEqual(index.size, 2)


if __name__ == "__main__":
    unittest.main()
