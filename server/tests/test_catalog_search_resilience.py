import asyncio
import unittest
from unittest.mock import AsyncMock, patch

from server.catalog import CatalogService


class _Repository:
    def __init__(self, cached):
        self.cached = cached
        self.persisted = []

    async def search_cached(self, **kwargs):
        return list(self.cached)

    async def persist_many(self, entries):
        self.persisted.extend(entries)


class CatalogSearchResilienceTests(unittest.IsolatedAsyncioTestCase):
    def service(self, cached):
        repository = _Repository(cached)
        service = CatalogService(repository_factory=lambda _: repository)
        self.addAsyncCleanup(service.aclose)
        return service, repository

    async def test_small_cache_survives_provider_failure_without_becoming_fresh(self):
        cached = {"stable_id": "bangumi:464376", "title": "败犬女主太多了！"}
        service, repository = self.service([cached])
        with patch.object(service, "_bangumi_search", new=AsyncMock(side_effect=TimeoutError)):
            result = await service.search("败犬女主太多了", ["anime"], None)
        self.assertEqual(result, [cached])
        self.assertEqual(repository.persisted, [])

    async def test_slow_provider_is_cancelled_without_losing_other_results(self):
        cached = {"stable_id": "bangumi:464376", "title": "败犬女主太多了！"}
        fresh = {"stable_id": "tmdb:tv:241535", "title": "败犬女主太多了！"}
        service, repository = self.service([cached])
        cancelled = asyncio.Event()

        async def slow(*args):
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        with patch("server.catalog._SEARCH_PROVIDER_TIMEOUT_SECONDS", 0.02, create=True), \
             patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"), \
             patch.object(service, "_bangumi_search", side_effect=slow), \
             patch.object(service, "_tmdb_search", new=AsyncMock(return_value=[fresh])):
            result = await asyncio.wait_for(
                service.search("败犬女主太多了", ["anime", "tv"], None), 0.5
            )
        self.assertEqual(result, [cached, fresh])
        self.assertTrue(cancelled.is_set())
        self.assertEqual([row.stable_id for row in repository.persisted], [fresh["stable_id"]])

    async def test_fresh_results_replace_matching_cache_but_keep_other_identities(self):
        cached = {"stable_id": "bangumi:464376", "title": "old title"}
        other = {"stable_id": "tmdb:tv:241535", "title": "败犬女主太多了！"}
        fresh = {**cached, "title": "败犬女主太多了！"}
        service, repository = self.service([cached, other])
        with patch.object(service, "_bangumi_search", new=AsyncMock(return_value=[fresh])):
            result = await service.search("败犬女主太多了", ["anime"], None)
        self.assertEqual(result, [fresh, other])
        self.assertEqual([row.stable_id for row in repository.persisted], [fresh["stable_id"]])

    async def test_small_cache_survives_empty_provider_response(self):
        cached = {"stable_id": "bangumi:464376", "title": "败犬女主太多了！"}
        service, repository = self.service([cached])
        with patch.object(service, "_bangumi_search", new=AsyncMock(return_value=[])):
            result = await service.search("败犬女主太多了", ["anime"], None)
        self.assertEqual(result, [cached])
        self.assertEqual(repository.persisted, [])
