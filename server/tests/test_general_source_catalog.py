"""All sections support independent origins without dropping or auto-enabling sites."""

import asyncio
from urllib.parse import urlsplit

import httpx
import pytest

from server.aggregator import ContentAggregator
from server.playback import PlaybackService
from server.scrapers.maccms_sites import MACCMS_SITES, enabled_sites
from tools.maccms_coverage import DEFAULT_CANDIDATE_REGISTRY_PATH
from tools.probe_maccms import load_candidate_sites

BASELINE_SITES = {
    "iKun",
    "光速",
    "如意",
    "豪华",
    "极速",
    "猫眼",
    "魔都2",
    "速博",
    "魔都",
    "红牛",
    "风车",
    "爱奇艺",
    "量子",
    "电影天堂",
    "暴风",
    "百度",
    "无尽",
    "最大",
    "360",
    "虎牙",
}
BASELINE_ACTIVE = BASELINE_SITES - {"极速", "暴风", "风车"}
CURRENT_ORIGIN_APIS = {
    "非凡资源": "http://api.ffzyapi.com/api.php/provide/vod/",
    "新浪资源": "https://api.xinlangapi.com/xinlangapi.php/provide/vod/josn",
    "U酷资源": "https://api.ukuapi88.com/api.php/provide/vod/",
}


def origin_candidates():
    return [
        site
        for site in load_candidate_sites(DEFAULT_CANDIDATE_REGISTRY_PATH)
        if site["name"] in CURRENT_ORIGIN_APIS
    ]


def test_comprehensive_origins_preserve_existing_sites_and_candidate_review_gate():
    registered = {site["name"]: site for site in MACCMS_SITES}
    active = {site["name"] for site in enabled_sites()}
    assert BASELINE_SITES <= registered.keys()
    assert BASELINE_ACTIVE <= active
    candidates = origin_candidates()
    assert {site["name"]: site["api"] for site in candidates} == CURRENT_ORIGIN_APIS
    assert all(site["review_status"] == "candidate" for site in candidates)
    pending_hosts = {urlsplit(site["api"]).hostname for site in candidates}
    assert pending_hosts.isdisjoint(
        urlsplit(site["api"]).hostname for site in MACCMS_SITES
    )
    # The existing source count is unchanged, including older isolated records.
    for name in BASELINE_SITES - BASELINE_ACTIVE:
        assert registered[name]["enabled"] is False


@pytest.mark.parametrize(
    "kind,title,category,year,episode",
    [
        ("movie", "流浪地球2", "科幻片", 2023, 1),
        ("series", "庆余年第一季", "国产剧", 2019, 10),
        ("anime", "葬送的芙莉莲", "日本动漫", 2023, 2),
    ],
)
def test_origin_search_detail_episode_and_api_identity_in_all_sections(
    kind, title, category, year, episode
):
    async def exercise():
        aggregator = ContentAggregator(
            crawler_scrapers={},
            enabled_provider_ids=frozenset({"aggregate.maccms"}),
            resolver_search_enabled=False,
        )
        # Candidates are injected only in this isolated audit, never by enabling
        # aggregate.maccms in the runtime. Formal promotion remains a separate gate.
        assert set(CURRENT_ORIGIN_APIS).isdisjoint(
            source.name for source in aggregator._maccms.discovery_sources
        )
        sites = origin_candidates()
        aggregator._maccms._sites = sites
        host_sites = {urlsplit(site["api"]).hostname: site["name"] for site in sites}
        calls = []
        item = {
            "vod_id": "44",
            "vod_name": title,
            "type_name": category,
            "vod_year": str(year),
            "vod_play_url": (
                "正片$https://media.example/film.m3u8"
                if kind == "movie"
                else "#".join(
                    f"第{n}集$https://media.example/ep{n}.m3u8" for n in range(1, 11)
                )
            ),
        }

        def handler(request):
            # An AniCh/third-party relay request or a guessed API path fails here.
            assert request.url.host in host_sites
            site = next(s for s in sites if s["name"] == host_sites[request.url.host])
            assert request.url.path == urlsplit(site["api"]).path
            assert request.url.params.get("ac") == "detail"
            assert (
                request.url.params.get("wd") == title
                or request.url.params.get("ids") == "44"
            )
            calls.append(request)
            return httpx.Response(200, json={"code": 1, "list": [item]})

        await aggregator._maccms._client.aclose()
        aggregator._maccms._client = httpx.AsyncClient(
            transport=httpx.MockTransport(handler)
        )
        try:
            matches = await aggregator.discover_source_matches(
                [title], content_type=kind, year=year
            )
            assert {m.source_name for m in matches} == set(CURRENT_ORIGIN_APIS)
            assert {m.content_type for m in matches} == {
                "tv" if kind == "series" else kind
            }
            for match in matches:
                detail = await aggregator._maccms.get_detail(match.source_id)
                assert any(ep.number == episode for ep in detail.episodes)
                lines = await aggregator.get_video_urls(match.source_id, episode)
                assert len(lines) == 1
                assert lines[0].url.endswith(
                    "film.m3u8" if kind == "movie" else f"ep{episode}.m3u8"
                )
                payload = PlaybackService()._line_dict(lines[0])
                assert payload["provider_id"] == match.source_name
            assert {request.url.host for request in calls} == set(host_sites)
        finally:
            await aggregator.aclose()

    asyncio.run(exercise())
