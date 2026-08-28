import json
import os
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

import httpx

from server.aggregator import ContentAggregator
from server.config import _env_csv
from server.providers import ProviderRegistry
from server.scrapers.base import SubjectDetail, SubjectResult, VideoLine
from server.scrapers.anime.anich import AniChScraper
from server.scrapers.anime.anich_transport import AniChTransport


class _ContractProvider:
    def __init__(self) -> None:
        self.content_types = ["anime", "movie"]
        self.closed = False

    async def search(self, keyword: str) -> list[SubjectResult]:
        return []

    async def get_detail(self, source_id: str) -> SubjectDetail | None:
        return None

    async def get_video_urls(
        self,
        source_id: str,
        episode: int = 1,
    ) -> list[VideoLine]:
        return []

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        return []

    async def get_home(self) -> list[SubjectResult]:
        return []

    async def aclose(self) -> None:
        self.closed = True


class ProviderContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_registry_exposes_only_safe_metadata_and_owns_close(self):
        provider = _ContractProvider()
        registry = ProviderRegistry()

        registration = registry.register(
            provider_id="crawler.example",
            family="crawler",
            display_name="Example",
            adapter=provider,
        )

        public = registration.metadata.as_public_dict()
        self.assertEqual(
            set(public),
            {
                "id",
                "family",
                "display_name",
                "content_types",
                "capabilities",
                "enabled",
            },
        )
        serialized = json.dumps(public).casefold()
        for marker in ("http://", "https://", "header", "cookie", "token"):
            self.assertNotIn(marker, serialized)

        await registry.aclose()
        self.assertTrue(provider.closed)

    async def test_registry_rejects_private_metadata_and_incomplete_contracts(self):
        provider = _ContractProvider()
        registry = ProviderRegistry()

        with self.assertRaises(ValueError):
            registry.register(
                provider_id="bad id",
                family="crawler",
                display_name="Example",
                adapter=provider,
            )
        with self.assertRaises(ValueError):
            registry.register(
                provider_id="crawler.private",
                family="crawler",
                display_name="https://private.example",
                adapter=provider,
            )

        provider.get_video_urls = None
        with self.assertRaises(TypeError):
            registry.register(
                provider_id="crawler.incomplete",
                family="crawler",
                display_name="Incomplete",
                adapter=provider,
            )

    async def test_aggregator_registers_unique_contract_metadata_without_network(self):
        aggregator = ContentAggregator(crawler_scrapers={})
        try:
            metadata = aggregator.provider_metadata
            self.assertEqual(
                [item.provider_id for item in metadata],
                ["aggregate.maccms", "aggregate.tvbox", "aggregate.vod"],
            )
            self.assertEqual(
                len(metadata), len({item.provider_id for item in metadata})
            )
            self.assertTrue(all(item.enabled for item in metadata))
            serialized = json.dumps(
                [item.as_public_dict() for item in metadata]
            ).casefold()
            for marker in ("http://", "https://", "header", "cookie", "token"):
                self.assertNotIn(marker, serialized)
        finally:
            await aggregator.aclose()

    async def test_empty_allowlist_prevents_every_provider_operation(self):
        provider = _ContractProvider()
        aggregator = ContentAggregator(
            crawler_scrapers={"blocked": provider},
            enabled_provider_ids=frozenset(),
            resolver_search_enabled=False,
        )
        try:
            forbidden_calls = []
            for adapter in (aggregator._maccms, aggregator._tvbox, aggregator._vod):
                for method_name in (
                    "search",
                    "get_detail",
                    "get_video_urls",
                    "get_latest",
                ):
                    method = AsyncMock(
                        side_effect=AssertionError(
                            f"disabled provider method called: {method_name}"
                        )
                    )
                    setattr(adapter, method_name, method)
                    forbidden_calls.append(method)
            progressive = MagicMock(
                side_effect=AssertionError("disabled progressive search called")
            )
            aggregator._maccms.search_progressively = progressive
            provider.search = AsyncMock(
                side_effect=AssertionError("disabled provider searched")
            )
            provider.get_detail = AsyncMock(
                side_effect=AssertionError("disabled provider detailed")
            )
            provider.get_video_urls = AsyncMock(
                side_effect=AssertionError("disabled provider resolved")
            )
            provider.get_latest = AsyncMock(
                side_effect=AssertionError("disabled provider listed")
            )

            self.assertEqual(aggregator.source_inventory, ())
            self.assertFalse(any(item.enabled for item in aggregator.provider_metadata))
            self.assertEqual(await aggregator.search("example", ["anime"]), [])
            self.assertEqual(
                await aggregator.discover_source_matches(["example"]),
                [],
            )
            self.assertEqual(await aggregator.get_episodes("crawler:blocked:1"), [])
            resolver = AsyncMock(
                side_effect=AssertionError("disabled resolver search called")
            )
            with patch(
                "server.aggregator.m3u8_resolver.search_and_resolve",
                new=resolver,
            ):
                self.assertEqual(
                    await aggregator.get_video_urls(
                        "crawler:blocked:1",
                        title_hint="example",
                    ),
                    [],
                )
            self.assertEqual(
                await aggregator.get_home_feed(),
                {
                    "anime_trending": [],
                    "series_trending": [],
                    "movies_trending": [],
                },
            )
            for method in forbidden_calls:
                method.assert_not_awaited()
            progressive.assert_not_called()
            resolver.assert_not_awaited()
        finally:
            await aggregator.aclose()

    async def test_unknown_allowlist_id_is_rejected_before_runtime_use(self):
        with self.assertRaises(ValueError):
            ContentAggregator(
                crawler_scrapers={},
                enabled_provider_ids=frozenset({"crawler.unknown"}),
            )

    def test_provider_allowlist_parser_normalizes_and_deduplicates(self):
        with patch.dict(
            os.environ,
            {
                "PLAYBACK_PROVIDER_IDS": (
                    " crawler.Example,aggregate.TVBOX,crawler.example "
                )
            },
        ):
            self.assertEqual(
                _env_csv("PLAYBACK_PROVIDER_IDS"),
                frozenset({"crawler.example", "aggregate.tvbox"}),
            )


class AniChScraperContractTests(unittest.IsolatedAsyncioTestCase):
    """真实 AniChScraper 过注册合同(能力齐全、脱敏、关闭链路)。"""

    async def test_real_anich_scraper_satisfies_registry_contract(self):
        def deny(request: httpx.Request) -> httpx.Response:
            raise AssertionError("contract test must not issue network requests")

        scraper = AniChScraper(
            transport=AniChTransport(
                bases=("https://anich.example",),
                transport=httpx.MockTransport(deny),
            )
        )
        registry = ProviderRegistry()
        try:
            registration = registry.register(
                provider_id="crawler.anich",
                family="crawler",
                display_name="AniCh 聚合源",
                adapter=scraper,
                enabled=True,
            )
            public = registration.metadata.as_public_dict()
            self.assertEqual(public["id"], "crawler.anich")
            self.assertIn("anime", public["content_types"])
            serialized = json.dumps(public).casefold()
            for marker in ("http://", "https://", "header", "cookie", "token"):
                self.assertNotIn(marker, serialized)
        finally:
            await registry.aclose()
        # 关闭链路经 aclose 传导到传输层底层 httpx 客户端
        self.assertTrue(scraper._transport._client.is_closed)

    async def test_default_aggregator_registers_anich_as_disabled_by_allowlist(self):
        from server.scrapers.anime.anich import AniChScraper

        aggregator = ContentAggregator(
            crawler_scrapers=None,
            enabled_provider_ids=frozenset(),
        )
        try:
            ids = {item.provider_id for item in aggregator.provider_metadata}
            self.assertIn("crawler.anich", ids)
            metadata = {
                item.provider_id: item
                for item in aggregator.provider_metadata
            }["crawler.anich"]
            self.assertFalse(metadata.enabled)
            self.assertIsInstance(
                aggregator._crawler_scrapers["anich"], AniChScraper
            )
        finally:
            await aggregator.aclose()


if __name__ == "__main__":
    unittest.main()
