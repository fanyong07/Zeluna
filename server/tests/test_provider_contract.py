import json
import unittest

from server.aggregator import ContentAggregator
from server.providers import ProviderRegistry
from server.scrapers.base import SubjectDetail, SubjectResult, VideoLine


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
            {"id", "family", "display_name", "content_types", "capabilities"},
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
            serialized = json.dumps(
                [item.as_public_dict() for item in metadata]
            ).casefold()
            for marker in ("http://", "https://", "header", "cookie", "token"):
                self.assertNotIn(marker, serialized)
        finally:
            await aggregator.aclose()


if __name__ == "__main__":
    unittest.main()
