"""Structured AniCh failures retain their transport category in aggregation."""
import asyncio
import socket
import unittest
from unittest.mock import AsyncMock

import httpx

from server.aggregator import (
    CONNECT_TIMEOUT, DNS_FAILURE, EMPTY_MEDIA, PARSER_MISMATCH,
    RATE_LIMITED, READ_TIMEOUT, RESTRICTED, STALE_ROUTE, UNKNOWN_EXCEPTION,
    ContentAggregator, _classify_resolution_exception,
)
from server.playback_discovery import SourceDiscoveryStatus
from server.scrapers.anime.anich_transport import AniChUpstreamError


class AniChErrorClassifierTests(unittest.TestCase):
    def test_reason_and_cooldown_cause_reason_allowlist(self):
        cases = {
            "dns_failure": DNS_FAILURE, "connect_timeout": CONNECT_TIMEOUT,
            "read_timeout": READ_TIMEOUT, "rate_limited": RATE_LIMITED,
            "restricted": RESTRICTED, "stale_route": STALE_ROUTE,
            "empty_response": EMPTY_MEDIA, "parser_mismatch": PARSER_MISMATCH,
            "connect_error": CONNECT_TIMEOUT,
        }
        for reason, category in cases.items():
            with self.subTest(reason=reason):
                direct = AniChUpstreamError("redacted", reason=reason)
                cooldown = AniChUpstreamError("redacted", reason="upstream_cooldown", cause_reason=reason, retry_after_seconds=20)
                self.assertEqual(_classify_resolution_exception(direct), category)
                self.assertEqual(_classify_resolution_exception(cooldown), category)

    def test_status_fallback_and_original_cause(self):
        for status, category in ((429, RATE_LIMITED), (403, RESTRICTED), (404, STALE_ROUTE)):
            with self.subTest(status=status):
                error = AniChUpstreamError("redacted", reason="upstream_http_error", status=status)
                self.assertEqual(_classify_resolution_exception(error), category)
        transport = httpx.ConnectError("redacted")
        transport.__cause__ = socket.gaierror("redacted")
        error = AniChUpstreamError("redacted", reason="transport_error")
        error.__cause__ = transport
        self.assertEqual(_classify_resolution_exception(error), DNS_FAILURE)
        timeout = AniChUpstreamError("redacted", reason="upstream_cooldown")
        timeout.__cause__ = httpx.ReadTimeout("redacted")
        self.assertEqual(_classify_resolution_exception(timeout), READ_TIMEOUT)
        parse = AniChUpstreamError("redacted", reason="transport_error")
        parse.__cause__ = ValueError("redacted")
        self.assertEqual(_classify_resolution_exception(parse), PARSER_MISMATCH)

    def test_generic_runtime_errors_and_cycles_are_not_guessed_as_network(self):
        error = RuntimeError("dns_failure connect_timeout HTTP 500")
        self.assertEqual(_classify_resolution_exception(error), UNKNOWN_EXCEPTION)
        structured = AniChUpstreamError("redacted", reason="upstream_http_error", status=500)
        self.assertEqual(_classify_resolution_exception(structured), UNKNOWN_EXCEPTION)
        structured.__cause__ = structured
        self.assertEqual(_classify_resolution_exception(structured), UNKNOWN_EXCEPTION)


class AniChDiscoveryDiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    async def test_all_aliases_cooling_down_keep_root_category_not_unknown(self):
        scraper = AsyncMock()
        scraper.content_types = ["anime"]
        scraper.search.side_effect = AniChUpstreamError(
            "redacted", reason="upstream_cooldown", cause_reason="rate_limited",
            status=429, retry_after_seconds=30,
        )
        aggregator = ContentAggregator(
            crawler_scrapers={"anich": scraper},
            enabled_provider_ids=frozenset({"crawler.anich"}),
            resolver_search_enabled=False,
        )
        try:
            matches, diagnostics = await aggregator.discover_source_matches(
                ["本篇", "Original Title"], content_type="anime", include_diagnostics=True,
            )
            self.assertEqual(matches, [])
            diagnostic = diagnostics["anich"]
            self.assertEqual(diagnostic.status, SourceDiscoveryStatus.SEARCH_ERROR)
            self.assertEqual(diagnostic.error_category, RATE_LIMITED)
            self.assertEqual(diagnostic.aliases_attempted, 2)
            self.assertTrue(diagnostic.queried)
            self.assertFalse(diagnostic.matched)
            self.assertEqual(scraper.search.await_count, 2)
            self.assertEqual(scraper.search.await_args_list[0].args, ("Original Title",))
        finally:
            await aggregator.aclose()
