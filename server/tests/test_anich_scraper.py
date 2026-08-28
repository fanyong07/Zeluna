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


#: 上游的线路标识(字段5),用作 UI 展示名
_VOD_TAGS = ("hb-10", "aw-11", "jk-18", "dl-7", "bf-3", "xs-6")


def _vod_items_bytes() -> bytes:
    import json as _json

    items = []
    for index, (url, caption) in enumerate(_VOD_LINES):
        inner = _string_field(1, _variant_b64(url)) + _field_varint(2, 38)
        if caption:
            inner += _string_field(4, caption)
        inner += _string_field(5, _VOD_TAGS[index % len(_VOD_TAGS)])
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

    def test_line_rank_prefers_low_latency_delivery(self):
        """排序主信号是实测延迟:大厂对象存储 ~400ms,自建 CDN ~2000ms+。"""
        object_store = line_rank("https://v1.adkwai.com/bs2/adVideoLp/x", "")
        site_hls = line_rank("https://m3u8.site.example/a/index.m3u8", "")
        own_cdn = line_rank(
            "https://a.vod-cdn.sends.eu.org.cdn.cloudflare.net/v/x",
            "第1集(官方简中-全高清-1080P)",
        )
        proxy = line_rank("https://v-cdn.emmmm.eu.org/video/x", "")
        self.assertGreater(object_store, site_hls)
        self.assertGreater(site_hls, own_cdn)
        self.assertGreater(own_cdn, proxy)  # 二压带画质加分,略高于纯代取流

    def test_quality_only_breaks_ties_within_a_delivery_class(self):
        base = "https://v1.adkwai.com/bs2/adVideoLp/"
        premium = line_rank(base + "a", "第1集(官方简中-全高清-1080P)")
        plain = line_rank(base + "b", "第1集")
        self.assertGreater(premium, plain)
        # 但画质加分不足以让慢的交付形态翻到快的前面
        slow_premium = line_rank(
            "https://vod-cdn.sends.eu.org.cdn.cloudflare.net/video/zs/x",
            "第1集(官方简中-全高清-1080P)",
        )
        self.assertGreater(plain, slow_premium)


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
        # 每条线路都要有独立身份,否则客户端按 providerId|sourceName 折叠时
        # 数十条会被压成一张卡;展示名用上游线路标识,不出现聚合源名称
        names = [line.source_name for line in lines]
        self.assertEqual(len(set(names)), len(names), f"sourceName 有重复: {names}")
        self.assertFalse(
            any("anich" in name.lower() for name in names),
            f"展示名不应暴露聚合源名称: {names}",
        )
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

    async def test_delivery_class_ordering_follows_measured_latency(self):
        subject = _scraper(_Handler())
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        hosts = [line.url.split("/")[2] for line in lines]
        # 实测延迟序:大厂对象存储 < 采集站 HLS < 自建 CDN/代取流
        self.assertIn("adkwai", hosts[0])
        self.assertTrue(
            any("playxf" in h or "m3u8" in h for h in hosts[1:3]),
            f"采集站 HLS 应排在自建 CDN 之前: {hosts}",
        )

    async def test_display_names_use_upstream_line_tags(self):
        subject = _scraper(_Handler())
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        names = [line.source_name for line in lines]
        # 展示名应是 hb-10 / jk-18 这类线路标识
        self.assertTrue(
            all(name in _VOD_TAGS or name.rsplit("-", 1)[0] in _VOD_TAGS
                for name in names),
            f"展示名未使用上游线路标识: {names}",
        )

    async def test_all_lines_are_returned_and_ranked(self):
        """线路全量返回(不截断),排序把预期延迟最低的放最前。"""
        subject = _scraper(self.handler)
        try:
            lines = await subject.get_video_urls(str(BANGUMI_ID), 1)
        finally:
            await subject.aclose()
        # fixture 六条原始行:一条同址重复、一条脚本端点被拒 → 全量 4 条
        self.assertEqual(len(lines), 4)
        # 头名是大厂对象存储(实测 ~400ms),而非最慢的自建 CDN 二压
        self.assertIn("adkwai", lines[0].url)
        # 官方二压仍在列表里,只是不再默认排第一
        self.assertTrue(any("vod-cdn" in line.url for line in lines))
        self.assertTrue(
            any(line.quality == "官方简中·1080P" for line in lines)
        )

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

    async def test_episodes_are_cached_across_calls(self):
        """剧集表约 1s 且占一次串行节流额度,重复取流不应重复拉取。"""
        now = [1000.0]
        subject = _scraper(
            self.handler, episodes_cache_seconds=600.0, clock=lambda: now[0]
        )
        try:
            await subject.get_video_urls(str(BANGUMI_ID), 1)
            first = self.handler.calls.count(f"/bangumi/episodes/{BANGUMI_ID}")
            await subject.get_video_urls(str(BANGUMI_ID), 1)
            cached = self.handler.calls.count(f"/bangumi/episodes/{BANGUMI_ID}")
            self.assertEqual(first, 1)
            self.assertEqual(cached, 1, "缓存内不应重复拉取剧集表")
            now[0] += 601  # TTL 过期
            await subject.get_video_urls(str(BANGUMI_ID), 1)
            expired = self.handler.calls.count(f"/bangumi/episodes/{BANGUMI_ID}")
            self.assertEqual(expired, 2, "TTL 过期后应重新拉取")
        finally:
            await subject.aclose()

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
