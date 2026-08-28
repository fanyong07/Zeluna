import base64
import unittest

import httpx

from server.protobuf_encoder import (
    _field_bytes,
    _field_double,
    _field_varint,
    _string_field,
)
from server.scrapers.anime.anich import (
    AniChScraper,
    caption_quality,
    line_display_title,
    line_rank,
    resolve_global_sort,
)
from server.scrapers.anime.anich_transport import AniChTransport

BANGUMI_ID = 37654


def _variant_b64(url: str) -> str:
    encoded = base64.b64encode(url.encode()).decode()
    return encoded[:3] + "0" + encoded[3:]


# 线上实测:date 是毫秒级 double(1774540800000.0 → 2026-03-26)
LIST_DATE_MS = 1711116000000.0
LIST_DATE_YEAR = 2024


def _bangumi_list_payload() -> bytes:
    inner = (
        _field_varint(1, BANGUMI_ID)
        + _string_field(2, "葬送的芙莉莲 第二季")
        + _field_varint(3, 8)
        + _field_varint(4, 10)
        + _string_field(5, "standard")
        + _field_double(6, LIST_DATE_MS)
    )
    return _field_bytes(1, inner)


def _episodes_payload() -> bytes:
    # S2 条目:sort 从 29 开始的 10 集(全局集号坑);
    # 第 3 行是脏数据(status=False + 离谱时长),必须被回退映射跳过。
    rows = []
    for local in range(10):
        sort = 29 + local
        if local == 2:
            rows.append(
                _field_varint(1, 0) + _field_varint(2, sort) + _field_varint(4, 999999)
            )
            continue
        rows.append(_field_varint(1, 1) + _field_varint(2, sort) + _field_varint(4, 1400))
    body = b"".join(_field_bytes(1, row) for row in rows)
    return body


_VOD_LINES = [
    # (url, caption) —— 形态取自线上单集 61 条线路的真实分布:
    # 自建CDN官方二压(无扩展名) / 代取流 / 对象存储转存 / 采集站 m3u8 /
    # 脚本转发端点(必须拒绝) / 同址重复(去重路径)
    ("https://vod-cdn.sends.eu.org.cdn.cloudflare.net/video/zs/1080p/aa11", "第01集(官方简中-全高清-1080P)"),
    ("https://v-cdn.emmmm.eu.org/video/Dg9Zlwn", "第01话"),
    ("https://v1.adkwai.com/bs2/adVideoLp/YWQt", "第01集"),
    ("https://dl.playxf.top/x/01.m3u8", "第01集"),
    ("https://player.91ju.cc/wgart/api.php?action=ad_filter_proxy&video_url=x", "第01集"),
    ("https://dl.playxf.top/x/01.m3u8", "第01集(简中)"),
]


def _vod_items_bytes() -> bytes:
    import json as _json

    items = []
    for url, caption in _VOD_LINES:
        inner = _string_field(1, _variant_b64(url)) + _field_varint(2, 38)
        if caption:
            inner += _string_field(4, caption)
        pb_item = _field_bytes(1, inner)
        items.extend(int(b) for b in pb_item)
    junk_pb = _field_bytes(1, _string_field(1, _variant_b64("not-a-url")))
    items.extend(int(b) for b in junk_pb)
    wrapped = _json.dumps(items).encode()
    return wrapped


class _Handler:
    def __init__(self):
        self.calls: list[str] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request.url.path)
        path = request.url.path
        if path == "/bangumi/search":
            assert request.headers["User-Agent"].startswith("cx.xs.open")
            return httpx.Response(200, content=_bangumi_list_payload())
        if path == "/bangumi/latest":
            return httpx.Response(200, content=_bangumi_list_payload())
        if path == f"/bangumi/detail/{BANGUMI_ID}":
            return httpx.Response(
                200,
                json={
                    "title": "葬送的芙莉莲 第二季",
                    "image": "https://img.example/cover.jpg",
                    "overview": "勇者辛美尔逝世后的旅程",
                    "airdate": "2024-01",
                    "genres": ["奇幻", "冒险"],
                    "rating": [{"site": "bangumi", "score": 9.4}],
                },
            )
        if path == f"/bangumi/episodes/{BANGUMI_ID}":
            return httpx.Response(200, content=_episodes_payload())
        # sort31 是 fixture 脏行所在的全局集号,vod 不为其供数
        expected_sorts = {29, 30}
        marker = path.rsplit("/", 1)[-1]
        if path.startswith("/vod/") and int(marker) in expected_sorts:
            return httpx.Response(200, content=_vod_items_bytes())
        return httpx.Response(404)


def _scraper(handler: _Handler, **kwargs) -> AniChScraper:
    transport = AniChTransport(
        bases=("https://anich.example",),
        transport=httpx.MockTransport(handler),
        interval=0.0,
        backoff_max=0.01,
    )
    return AniChScraper(transport=transport, **kwargs)


class PureFunctionTests(unittest.TestCase):
    def test_resolve_global_sort_exact_hit_wins(self):
        episodes = [
            {"status": True, "sort": 5, "duration": 1400},
            {"status": True, "sort": 6, "duration": 1400},
        ]
        self.assertEqual(resolve_global_sort(episodes, 6), 6)

    def test_resolve_global_sort_season_local_fallback_skips_dirty_rows(self):
        episodes = [
            {"status": True, "sort": 29, "duration": 1400},
            {"status": False, "sort": 30, "duration": 999999},
            {"status": True, "sort": 31, "duration": 1400},
        ]
        # 季内第 2 集 → 无 sort==2 命中 → 回退可信行下标 1(sort=31)
        self.assertEqual(resolve_global_sort(episodes, 2), 31)

    def test_resolve_global_sort_unsolvable_returns_none(self):
        self.assertIsNone(resolve_global_sort([], 1))
        self.assertIsNone(
            resolve_global_sort([{"status": False, "sort": 9, "duration": 0}], 1)
        )
        self.assertIsNone(resolve_global_sort([{"status": True, "sort": 7}], 99))

    def test_caption_quality_priority_order(self):
        self.assertEqual(caption_quality("第1集(官方简中-全高清-1080P)"), "官方简中·1080P")
        self.assertEqual(caption_quality("第1集(官方简中)"), "官方简中")
        self.assertEqual(caption_quality("1(繁体中文)"), "")
        self.assertEqual(caption_quality(""), "")

    def test_line_display_title_strips_prefix_and_dashes(self):
        self.assertEqual(
            line_display_title("第10集(官方简中-全高清-1080P)"),
            "官方简中·全高清·1080P",
        )
        self.assertEqual(line_display_title("第10话"), "")
        self.assertEqual(line_display_title("10(繁体中文)"), "繁体中文")

    def test_line_rank_prefers_own_cdn_then_m3u8(self):
        cdn = line_rank("https://a.vod-cdn.sends.eu.org.cdn.cloudflare.net/v/x", "x")
        plain_m3u8 = line_rank("https://plain.example/a.m3u8", "x")
        plain_mp4_no_caption = line_rank("https://plain.example/a.mp4", "")
        self.assertGreater(cdn, plain_m3u8)
        self.assertGreater(plain_m3u8, plain_mp4_no_caption)


class AniChScraperTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.handler = _Handler()
        self.scraper = _scraper(self.handler)

    async def asyncTearDown(self):
        await self.scraper.aclose()

    async def test_search_maps_pb_entries_to_anime_subjects(self):
        results = await self.scraper.search("芙莉莲")
        self.assertEqual(len(results), 1)
        entry = results[0]
        self.assertEqual(entry.source_id, str(BANGUMI_ID))
        self.assertEqual(entry.title, "葬送的芙莉莲 第二季")
        self.assertEqual(entry.type, "anime")
        self.assertEqual(entry.year, LIST_DATE_YEAR)
        self.assertEqual(entry.episode_count, 10)

    async def test_empty_keyword_issues_no_request(self):
        self.assertEqual(await self.scraper.search("   "), [])
        self.assertEqual(self.handler.calls, [])

    async def test_video_urls_resolve_season_local_episode_via_fallback(self):
        lines = await self.scraper.get_video_urls(str(BANGUMI_ID), 2)
        # 第2集季内序号 → 无精确命中 → 回退可信行下标1 = sort30
        # (fixture 脏行在局部 index2 / sort31,status=False 被剔除)
        self.assertEqual(f"/vod/{BANGUMI_ID}/30", self.handler.calls[-1])
        urls = [line.url for line in lines]
        self.assertIn("https://v-cdn.emmmm.eu.org/video/Dg9Zlwn", urls)
        self.assertNotIn("not-a-url", "".join(urls).lower())
        self.assertTrue(all(line.source_name == "anich" for line in lines))
        self.assertTrue(all(line.headers == {} for line in lines))

    async def test_script_forwarding_endpoint_is_rejected(self):
        subject = _scraper(_Handler(), max_lines=12)
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        # player.91ju.cc/...api.php?action=ad_filter_proxy 是转发页,不是媒体
        self.assertFalse(any("api.php" in line.url for line in lines))
        self.assertFalse(any("91ju" in line.url for line in lines))

    async def test_bare_episode_captions_fall_back_to_positional_names(self):
        subject = _scraper(_Handler(), max_lines=12)
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        # 线上多数 caption 是裸集号;UI 不能出现整排空名线路
        self.assertTrue(all(line.title for line in lines))
        self.assertTrue(any(line.title.startswith("线路") for line in lines))

    async def test_delivery_class_outranks_quality_words(self):
        subject = _scraper(_Handler(), max_lines=12)
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        hosts = [line.url.split("/")[2] for line in lines]
        # 自建 CDN 官方二压 > 代取流 > 对象存储转存 > 采集站
        self.assertTrue(hosts[0].startswith("vod-cdn"))
        self.assertTrue(hosts[1].startswith("v-cdn"))
        self.assertIn("adkwai", hosts[2])

    async def test_lines_are_ranked_and_capped(self):
        subject = _scraper(self.handler, max_lines=3)
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        self.assertEqual(len(lines), 3)
        # 头名必须是自建 CDN 官方二压且保留画质标注
        self.assertTrue(lines[0].url.startswith("https://vod-cdn"))
        self.assertEqual(lines[0].quality, "官方简中·1080P")

    async def test_duplicate_urls_are_deduplicated(self):
        subject = _scraper(_Handler(), max_lines=12)
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        urls = [line.url for line in lines]
        # fixture 六条原始行:一条同址重复、一条脚本端点被拒 → 剩 4 条
        self.assertEqual(len(urls), 4)
        self.assertEqual(len(urls), len(set(urls)))

    async def test_unsolvable_episode_returns_empty_without_vod_call(self):
        lines = await self.scraper.get_video_urls(str(BANGUMI_ID), 999)
        self.assertEqual(lines, [])
        self.assertFalse(any(c.startswith("/vod/") for c in self.handler.calls))

    async def test_detail_merges_json_meta_and_local_numbering(self):
        detail = await self.scraper.get_detail(str(BANGUMI_ID))
        self.assertIsNotNone(detail)
        self.assertEqual(detail.title, "葬送的芙莉莲 第二季")
        self.assertEqual(detail.type, "anime")
        self.assertEqual(detail.rating, 9.4)
        self.assertEqual([item.number for item in detail.episodes][0], 1)
        sorts = [item.source_episode_id for item in detail.episodes]
        self.assertEqual(sorts[0], "29")


class EpochYearTests(unittest.TestCase):
    """量纲自适应:上游给毫秒,历史/异常值不得让整条搜索结果崩掉。"""

    def test_millisecond_epoch_is_the_live_wire_format(self):
        from server.scrapers.anime.anich import _year_from_epoch

        self.assertEqual(_year_from_epoch(1774540800000.0), 2026)
        self.assertEqual(_year_from_epoch(1711116000000.0), 2024)

    def test_second_epoch_still_parses(self):
        from server.scrapers.anime.anich import _year_from_epoch

        self.assertEqual(_year_from_epoch(1711116000.0), 2024)

    def test_out_of_range_and_missing_values_degrade_to_zero(self):
        from server.scrapers.anime.anich import _year_from_epoch

        for raw in (0, None, "", -1, 1e30, "nonsense"):
            self.assertEqual(_year_from_epoch(raw), 0)


if __name__ == "__main__":
    unittest.main()
