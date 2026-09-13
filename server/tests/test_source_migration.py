"""Incremental direct-source migration must not shrink the fallback inventory."""

import asyncio
from unittest.mock import AsyncMock

import httpx
import pytest

from server.aggregator import (
    CLIENT_PROBE_REQUIRED,
    SERVER_VERIFIED,
    UNAVAILABLE,
    ContentAggregator,
    LineVerificationResult,
    SourceMatch,
)
from server.playback import PlaybackService
from server.scrapers.base import VideoLine


@pytest.mark.parametrize("direct_timeout", [False, True])
def test_direct_addition_preserves_all_58_fallback_lines_even_when_checks_fail(
    direct_timeout,
):
    async def exercise():
        aggregator = ContentAggregator(
            enabled_provider_ids=frozenset({"crawler.anich", "crawler.xifan"}),
            resolver_search_enabled=False,
        )
        fallback = [
            VideoLine(
                url=f"https://media.example/fallback/{index}/ep1.m3u8",
                source_name=f"retained-{index}",
                format="hls",
            )
            for index in range(58)
        ]
        direct = [
            VideoLine(
                url=f"https://media.example/direct/{index}/ep1.m3u8",
                source_name=f"xifan:xifan-{index}",
                format="hls",
            )
            for index in (1, 2)
        ]
        anich = aggregator.active_crawler_scrapers["anich"]
        xifan = aggregator.active_crawler_scrapers["xifan"]
        anich.get_video_urls = AsyncMock(return_value=fallback)
        xifan.get_video_urls = AsyncMock(return_value=direct)
        if direct_timeout:
            xifan.get_video_urls.side_effect = httpx.ReadTimeout(
                "temporary origin failure"
            )

        async def verification(line, **kwargs):
            if "/fallback/" in line.url:
                index = int(line.url.split("/")[-2])
                if index % 3 == 0:
                    raise httpx.ReadTimeout("temporary verification failure")
                if index % 3 == 1:
                    return LineVerificationResult(status=CLIENT_PROBE_REQUIRED)
            return LineVerificationResult(status=SERVER_VERIFIED)

        aggregator._line_verification_status = verification
        matches = [
            SourceMatch(
                source_id=f"crawler:{site}:44",
                source_name=site,
                title="Frieren",
                content_type="anime",
                year=2023,
            )
            for site in ("anich", "xifan")
        ]
        try:
            outcomes = [
                result
                async for result in aggregator.resolve_source_matches_progressively(
                    matches,
                    episode=1,
                    verify=True,
                )
            ]
            lines = [line for result in outcomes for line in result.lines]
            retained = [
                line for line in lines if line.source.startswith("crawler:anich:")
            ]
            assert len(retained) == 58
            assert {line.url for line in retained} == {line.url for line in fallback}
            assert any(line.verification_status == UNAVAILABLE for line in retained)
            assert len(lines) == (58 if direct_timeout else 60)
            payloads = [PlaybackService()._line_dict(line) for line in lines]
            assert {f"retained-{index}" for index in range(58)} <= {
                row["provider_id"] for row in payloads
            }
            assert len({row["provider_id"] for row in payloads}) == len(lines)
            assert set(aggregator.active_crawler_scrapers) == {"anich", "xifan"}
            # A failure must not delete/disable the provider; a later retry can recover.
            xifan.get_video_urls.side_effect = None
            recovered = await aggregator.get_video_urls("crawler:xifan:44", 1)
            assert len(recovered) == 2
            anich.get_video_urls.assert_awaited_once_with("44", 1)
        finally:
            await aggregator.aclose()

    asyncio.run(exercise())


def test_registering_direct_source_does_not_change_existing_explicit_allowlist():
    async def exercise():
        aggregator = ContentAggregator(
            enabled_provider_ids=frozenset({"crawler.anich"}),
            resolver_search_enabled=False,
        )
        try:
            assert set(aggregator.active_crawler_scrapers) == {"anich"}
            assert await aggregator.get_video_urls("crawler:xifan:44", 1) == []
            assert {
                "age",
                "dm706",
                "girigiri",
                "anich",
                "xgcartoon",
                "yhdmm",
                "jibi",
                "yinghua2",
                "wedm",
                "nivod",
                "ppnix",
                "dbku",
                "xifan",
            } <= set(aggregator._crawler_scrapers)
        finally:
            await aggregator.aclose()

    asyncio.run(exercise())
