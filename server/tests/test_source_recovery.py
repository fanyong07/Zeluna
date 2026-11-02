"""Regressions from the inactive-source audit: actual adapter call paths."""

import asyncio
import time
from unittest.mock import AsyncMock

import httpx
import pytest

from server.scrapers.maccms import MacCmsScraper
from server.scrapers.tvbox_adapter import TvBoxAdapterScraper

XML = """<?xml version="1.0" encoding="UTF-8"?>
<rss><list><video><id>7</id><name>败犬女主太多了！</name>
<type>日韩动漫</type><year>2024</year><pic>https://image.example/7.jpg</pic>
<note>全12集</note><des>简介</des><dl>
<dd flag="a"><![CDATA[第01集$https://media.example/a1.m3u8#第03集$https://media.example/a3.m3u8]]></dd>
<dd flag="b"><![CDATA[EP01$https://media.example/b1.m3u8]]></dd>
</dl></video></list></rss>"""


def response(body):
    request = httpx.Request("GET", "https://source.example/api")
    return httpx.Response(200, content=body.encode(), request=request)


def test_xml_search_detail_episode_resolution_use_real_adapter():
    async def run():
        scraper = MacCmsScraper()
        scraper._sites = [
            {"name": "XML", "api": "https://source.example/api", "api_format": "xml"}
        ]
        scraper._client.get = AsyncMock(return_value=response(XML))
        try:
            outcome = await scraper.search_source("XML", "败犬女主太多了")
            assert outcome.succeeded and len(outcome.results) == 1
            assert (outcome.results[0].type, outcome.results[0].year) == ("anime", 2024)
            detail = await scraper.get_detail("maccms:XML:7")
            assert [e.number for e in detail.episodes] == [1, 3]
            assert scraper._client.get.call_args.kwargs["params"]["ac"] == "videolist"
            lines = await scraper.get_video_urls("maccms:XML:7", 1)
            assert len(lines) == 2
            assert [l.source_name for l in lines] == ["maccms:XML", "maccms:XML:XML-2"]
            assert not await scraper.get_video_urls("maccms:XML:7", 2)
        finally:
            await scraper.aclose()

    asyncio.run(run())


@pytest.mark.parametrize(
    "kind,year,expected",
    [("日韩动漫", 2024, "anime"), ("科幻片", "2019", "movie"), ("国产剧", None, "tv")],
)
def test_tvbox_preserves_real_kind_and_unknown_year(kind, year, expected):
    async def run():
        scraper = TvBoxAdapterScraper()
        scraper._source_configs = {
            "fixture": {"name": "fixture", "base": "https://source.example/api"}
        }
        scraper._healthy_sources = ["fixture"]
        scraper._last_health_check = time.time()
        item = {
            "vod_id": "1",
            "vod_name": "目标作品",
            "type_name": kind,
            "vod_year": year,
            "vod_play_url": "EP01$https://media.example/1.m3u8#SP$https://media.example/sp.m3u8#EP03$https://media.example/3.m3u8",
        }
        scraper._client.get = AsyncMock(
            return_value=httpx.Response(
                200,
                json={"list": [item]},
                request=httpx.Request("GET", "https://source.example/api"),
            )
        )
        try:
            found = await scraper.search("目标作品")
            assert len(found) == 1
            assert (found[0].type, found[0].year) == (expected, int(year or 0))
            detail = await scraper.get_detail(found[0].source_id)
            assert (detail.type, detail.year) == (expected, int(year or 0))
            assert [e.number for e in detail.episodes] == [1, 3]
            assert not await scraper.get_video_urls(found[0].source_id, 2)
        finally:
            await scraper.aclose()

    asyncio.run(run())


def test_catalog_parser_rejects_html_errors_and_xml_entities():
    from server.scrapers.maccms_payload import parse_catalog_response

    for text in (
        "<html>验证页面</html>",
        '{"code":0,"msg":"denied"}',
        '<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss><list>&x;</list></rss>',
    ):
        with pytest.raises(ValueError):
            parse_catalog_response(response(text))
    assert parse_catalog_response(response('{"list":[]}'))["list"] == []


@pytest.mark.parametrize(
    "body",
    ["暂不支持搜索", '{"code":1002,"msg":"Current API forbids keyword search."}'],
)
def test_disabled_keyword_search_is_not_misreported_as_empty_or_bad_json(body):
    async def run():
        scraper = MacCmsScraper()
        scraper._sites = [{"name": "fixture", "api": "https://source.example/api"}]
        scraper._client.get = AsyncMock(return_value=response(body))
        try:
            result = await scraper.search_source("fixture", "目标")
            assert not result.succeeded
            assert result.error_category == "search_unsupported"
        finally:
            await scraper.aclose()

    asyncio.run(run())


def test_catalog_parser_rejects_encoded_dtd_and_oversized_input():
    from server.scrapers.maccms_payload import parse_catalog_response, MAX_CATALOG_BYTES

    for body in (
        '<!DOCTYPE rss [<!ENTITY x "secret">]><rss><list>&x;</list></rss>'.encode(
            "utf-16"
        ),
        b" " * (MAX_CATALOG_BYTES + 1),
    ):
        with pytest.raises(ValueError):
            parse_catalog_response(httpx.Response(200, content=body))


def test_dns_and_certificate_failures_remain_distinguishable():
    import socket
    import ssl
    from server.scrapers.maccms_payload import catalog_error_category

    for cause, category in (
        (socket.gaierror("name missing"), "dns_failure"),
        (ssl.SSLCertVerificationError("untrusted"), "tls_error"),
    ):
        error = httpx.ConnectError("upstream unavailable")
        error.__cause__ = cause
        assert catalog_error_category(error) == category


def test_admission_transfers_candidates_without_duplicates_or_precache():
    import json
    from pathlib import Path
    from server.scrapers.maccms_sites import MACCMS_SITES
    from server.playback_inventory import (
        RegisteredPlaybackSource,
        local_query_descriptor,
    )

    sites = {x["name"]: x for x in MACCMS_SITES}
    candidates = json.loads(
        (Path(__file__).resolve().parents[1] / "data/maccms_candidates.json").read_text(
            encoding="utf-8"
        )
    )
    admitted = {
        "金鹰资源",
        "新浪资源",
        "HG资源",
        "U酷资源",
        "非凡资源",
        "1080zyk优质资源库",
    }
    assert not admitted.intersection(x["name"] for x in candidates["sites"])
    assert all(
        sites[name]["enabled"] and not sites[name]["precache"]
        for name in admitted | {"极速"}
    )
    assert sites["极速"]["quick"] and sites["金鹰资源"]["quick"]
    for name in {"U酷资源", "非凡资源", "1080zyk优质资源库"}:
        assert sites[name]["tier"] == "client_probe" and not sites[name]["quick"]
    source = RegisteredPlaybackSource(
        "maccms", "1080zyk优质资源库", "configured", "not_queried", ""
    )
    assert local_query_descriptor(source.inventory_id, sources=(source,)) is None


def test_tvbox_does_not_collapse_same_title_across_independent_sources():
    async def run():
        scraper = TvBoxAdapterScraper()
        scraper._source_configs = {
            name: {"name": name, "base": f"https://{name}.example/api"}
            for name in ("a", "b")
        }
        scraper._healthy_sources = ["a", "b"]
        scraper._last_health_check = time.time()
        scraper._client.get = AsyncMock(
            return_value=httpx.Response(
                200,
                json={
                    "list": [
                        {
                            "vod_id": "1",
                            "vod_name": "目标",
                            "type_name": "日韩动漫",
                            "vod_year": 2024,
                        }
                    ]
                },
                request=httpx.Request("GET", "https://source.example/api"),
            )
        )
        try:
            found = await scraper.search("目标")
            assert {x.source_id for x in found} == {"tvbox:a:1", "tvbox:b:1"}
        finally:
            await scraper.aclose()

    asyncio.run(run())


def test_unsupported_provider_does_not_invalidate_anime_full_cache():
    from unittest.mock import patch
    from server.aggregator import ContentAggregator, AggregatedVideoLine
    from server.playback import PlaybackService
    from server.scrapers.direct_stream import PpnixScraper
    from server.playback_discovery.models import SourceDiscoveryStatus

    async def run():
        movies = PpnixScraper()
        movies.search = AsyncMock(side_effect=AssertionError("unsupported search"))
        aggregator = ContentAggregator(
            crawler_scrapers={"ppnix": movies},
            enabled_provider_ids=frozenset({"aggregate.maccms", "crawler.ppnix"}),
            resolver_search_enabled=False,
        )
        aggregator._maccms._sites = [
            {"name": "fixture", "api": "https://catalog.example/api"},
            {
                "name": "movie_catalog",
                "api": "https://movies.example/api",
                "content_types": ["movie"],
            },
        ]
        aggregator._maccms._client.get = AsyncMock(
            return_value=httpx.Response(
                200,
                json={
                    "list": [
                        {
                            "vod_id": "1",
                            "vod_name": "目标",
                            "type_name": "日韩动漫",
                            "vod_year": 2024,
                        }
                    ]
                },
            )
        )
        try:
            matches, diagnostics = await aggregator.discover_source_matches(
                ["目标"],
                content_type="anime",
                year=2024,
                include_diagnostics=True,
            )
            assert len(matches) == 1
            assert diagnostics["ppnix"].status.value == "unsupported_content_type"
            assert not diagnostics["ppnix"].queried
            assert (
                diagnostics["movie_catalog"].status.value == "unsupported_content_type"
            )
            assert not diagnostics["movie_catalog"].queried
            aggregator._maccms._client.get.assert_awaited_once()
            movies.search.assert_not_awaited()
            service = PlaybackService()
            line = AggregatedVideoLine(
                url="https://media.example/1.m3u8",
                source="maccms:fixture",
                verification_status="server_verified",
            )
            with patch("server.playback.aggregator", aggregator):
                items = service._complete_site_inventory(
                    [service._line_dict(line)], discovery_diagnostics=diagnostics
                )
                assert service._should_store_full_result(items)
                assert any(
                    x.get("diagnostic_status") == "unsupported_content_type"
                    for x in items
                )
                # A genuinely unqueried compatible source must still block full caching.
                diagnostics["ppnix"].status = SourceDiscoveryStatus.NOT_QUERIED
                items = service._complete_site_inventory(
                    [service._line_dict(line)], discovery_diagnostics=diagnostics
                )
                assert not service._should_store_full_result(items)
        finally:
            await aggregator.aclose()

    asyncio.run(run())
