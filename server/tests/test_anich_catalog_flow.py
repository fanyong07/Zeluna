"""AniCh stable-catalog discovery regression (all upstream responses are fixtures)."""

import asyncio
import base64
import json
from unittest.mock import patch

import httpx
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import ContentAggregator
from server.catalog import CatalogService
from server.database import Base
from server.protobuf_encoder import _field_bytes, _field_double, _field_varint, _string_field
from server.scrapers.anime.anich import AniChScraper
from server.scrapers.anime.anich_transport import AniChTransport


def _card(ident, title, date):
    return _field_bytes(1, _field_varint(1, ident) + _string_field(2, title)
                        + _field_varint(4, 28) + _field_double(6, date))


def test_standard_2023_catalog_reaches_anich_episode_one_after_failed_english_alias():
    calls = []
    media_url = "https://media.example/episode-1.m3u8"

    def handler(request):
        path = request.url.path
        calls.append((request.url.host, path, request.url.params.get("keyword")))
        assert "Authorization" not in request.headers
        if path == "/v0/subjects/400602":
            return httpx.Response(200, json={
                "id": 400602, "name_cn": "葬送的芙莉莲", "name": "葬送のフリーレン",
                "type": 2, "date": "2023-09-29", "eps": 28,
                "infobox": [{"key": "别名", "value": [
                    {"v": "Frieren: Beyond Journey's End"}, {"v": "Sousou no Frieren"},
                ]}],
            })
        if path == "/v0/episodes":
            return httpx.Response(200, json={"data": [{"sort": 1, "name_cn": "冒险结束"}]})
        if path == "/bangumi/search":
            keyword = request.url.params.get("keyword")
            if keyword == "Frieren: Beyond Journey's End":
                return httpx.Response(500, json={"error": "query failed"})
            assert keyword == "葬送的芙莉莲"
            return httpx.Response(200, content=(
                _card(37654, "葬送的芙莉莲 第二季", 1768492800000.0)
                + _card(32339, "葬送的芙莉莲", 1711116000000.0)
            ))
        if path == "/bangumi/detail/32339":
            return httpx.Response(200, json={
                "title": "葬送的芙莉莲", "titles": ["葬送のフリーレン"],
                "airdate": 1695945600000,
            })
        if path == "/bangumi/episodes/32339":
            return httpx.Response(200, content=_field_bytes(1,
                _field_varint(1, 1) + _field_varint(2, 1)
                + _field_varint(4, 1440) + _string_field(8, "冒险结束"),
            ))
        if path == "/vod/32339/1":
            encoded = base64.b64encode(media_url.encode()).decode()
            variant = encoded[:3] + "0" + encoded[3:]
            vod = _field_bytes(1, _string_field(1, variant) + _field_varint(2, 1)
                               + _string_field(4, "第01集") + _string_field(5, "dm-6"))
            return httpx.Response(200, content=json.dumps(list(vod)).encode())
        raise AssertionError(f"unexpected fixture path {path}")

    async def run():
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        fixture_transport = httpx.MockTransport(handler)
        with patch("server.catalog.BANGUMI_ACCESS_TOKEN", ""), patch(
            "server.catalog.TMDB_READ_ACCESS_TOKEN", ""
        ), patch("server.scrapers.anime.anich_transport.config.ANICH_RELAY_BASE", ""):
            catalog = CatalogService(transport=fixture_transport, session_factory=sessions)
            scraper = AniChScraper(transport=AniChTransport(
                bases=("https://anich-fixture.example",), transport=fixture_transport,
                interval=0, base_cooldown_seconds=60,
            ))
            aggregator = ContentAggregator(
                crawler_scrapers={"anich": scraper},
                enabled_provider_ids=frozenset({"crawler.anich"}),
                resolver_search_enabled=False,
            )
        try:
            async with sessions() as session:
                metadata = await catalog.get_subject("bangumi:400602", session)
            assert metadata["date"] == "2023-09-29"
            aliases = await catalog.playback_aliases(metadata)
            matches, diagnostics = await aggregator.discover_source_matches(
                aliases, content_type="anime", year=2023, include_diagnostics=True,
            )
            assert [match.source_id for match in matches] == ["crawler:anich:32339"]
            assert matches[0].year == 2023
            assert matches[0].evidence.exact_title
            assert diagnostics["anich"].matched
            assert diagnostics["anich"].aliases_attempted == 2
            assert not diagnostics["anich"].error_category
            detail = await scraper.get_detail("32339")
            assert detail.year == 2023
            assert detail.episodes[0].source_episode_id == "1"
            with patch("server.scrapers.anime.anich._schedule_resolve"):
                lines = await aggregator.get_video_urls(matches[0].source_id, 1)
            assert [line.url for line in lines] == [media_url]
            assert lines[0].format == "hls"
            paths = [path for _, path, _ in calls]
            assert paths.count("/bangumi/detail/32339") == 1
            assert "/bangumi/detail/37654" not in paths
            assert paths[-1] == "/vod/32339/1"
            assert not scraper._transport._base_cooldown_until
        finally:
            await aggregator.aclose()
            await catalog.aclose()
            await engine.dispose()

    asyncio.run(run())
