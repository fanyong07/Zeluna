import json
import time
import unittest

import httpx
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.catalog import CatalogService
from server.database import Base, CatalogSubject
from server.repositories.catalog import (
    CatalogCacheEntry,
    CatalogWrite,
    SqlCatalogRepository,
)


def _write(
    *,
    title: str,
    popularity: float = 1,
    ranked_at: float | None = None,
) -> CatalogWrite:
    metadata = {
        "stable_id": "bangumi:1",
        "title": title,
        "media_type": "anime",
        "detail_complete": True,
    }
    return CatalogWrite(
        stable_id="bangumi:1",
        provider="bangumi",
        provider_id="1",
        media_type="anime",
        title=title,
        original_title="Original",
        aliases_json="[]",
        metadata_json=json.dumps(metadata),
        popularity=popularity,
        updated_at=time.time(),
        ranking_json=(
            json.dumps(
                {
                    "batchId": "bangumi:anime:test",
                    "rankedAt": ranked_at,
                    "globalScore": 0.5,
                    "lists": [
                        {"provider": "bangumi", "kind": "rank", "rank": 1}
                    ],
                }
            )
            if ranked_at is not None
            else None
        ),
        ranking_score=0.5 if ranked_at is not None else None,
        ranked_at=ranked_at,
    )


class CatalogRepositoryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def test_sql_repository_round_trip_updates_one_stable_row(self):
        async with self.sessions() as session:
            repository = SqlCatalogRepository(session)
            await repository.persist_many([_write(title="First")])
            await repository.persist_many([_write(title="Updated", popularity=9)])

            cached = await repository.get_cached("bangumi:1")
            search = await repository.search_cached(
                query="Updated",
                fresh_after=0,
                limit=10,
            )
            home = await repository.home_cached(
                media_type="anime",
                fresh_after=0,
                limit=10,
            )

        self.assertIsNotNone(cached)
        self.assertEqual(cached.metadata["title"], "Updated")
        self.assertEqual([item["title"] for item in search], ["Updated"])
        self.assertEqual([item["title"] for item in home], ["Updated"])

    async def test_sql_repository_skips_malformed_cached_metadata(self):
        async with self.sessions() as session:
            session.add(
                CatalogSubject(
                    stable_id="bangumi:2",
                    provider="bangumi",
                    provider_id="2",
                    media_type="anime",
                    title="Broken",
                    metadata_json="not-json",
                    updated_at=time.time(),
                )
            )
            await session.commit()
            repository = SqlCatalogRepository(session)

            self.assertIsNone(await repository.get_cached("bangumi:2"))
            self.assertEqual(
                await repository.search_cached(
                    query="Broken",
                    fresh_after=0,
                    limit=10,
                ),
                [],
            )

    async def test_metadata_refresh_preserves_home_ranking_evidence(self):
        ranked_at = time.time()
        async with self.sessions() as session:
            repository = SqlCatalogRepository(session)
            await repository.persist_many(
                [_write(title="Ranked", popularity=5, ranked_at=ranked_at)]
            )
            await repository.persist_many(
                [_write(title="Detail refreshed", popularity=9)]
            )

            home = await repository.home_cached(
                media_type="anime",
                fresh_after=ranked_at - 1,
                limit=10,
            )
            row = await session.get(CatalogSubject, 1)

        self.assertEqual(home[0]["title"], "Detail refreshed")
        self.assertEqual(home[0]["ranking"]["batchId"], "bangumi:anime:test")
        self.assertEqual(row.ranked_at, ranked_at)
        self.assertEqual(row.ranking_score, 0.5)

    async def test_home_cache_uses_ranked_at_instead_of_metadata_updated_at(self):
        now = time.time()
        old_ranked_at = now - 7 * 3600
        async with self.sessions() as session:
            repository = SqlCatalogRepository(session)
            await repository.persist_many(
                [_write(title="Stale ranking", ranked_at=old_ranked_at)]
            )

            fresh = await repository.home_cached(
                media_type="anime",
                fresh_after=now - 6 * 3600,
                limit=10,
            )
            stale = await repository.home_cached(
                media_type="anime",
                fresh_after=now - 72 * 3600,
                limit=10,
            )

        self.assertEqual(fresh, [])
        self.assertEqual([item["title"] for item in stale], ["Stale ranking"])

    async def test_catalog_service_uses_injected_repository_before_network(self):
        cached = [
            {"stable_id": f"bangumi:{index}", "title": f"Cached {index}"}
            for index in range(1, 6)
        ]

        class FakeRepository:
            async def search_cached(self, **kwargs):
                self.search_kwargs = kwargs
                return cached

            async def home_cached(self, **kwargs):
                raise AssertionError("home repository should not be called")

            async def get_cached(self, stable_id: str):
                return CatalogCacheEntry(metadata=cached[0], updated_at=time.time())

            async def persist_many(self, entries):
                raise AssertionError("cache hit must not persist")

        repository = FakeRepository()

        def network_handler(_request: httpx.Request) -> httpx.Response:
            raise AssertionError("cache hit must not call a metadata provider")

        service = CatalogService(
            transport=httpx.MockTransport(network_handler),
            repository_factory=lambda _session: repository,
        )
        try:
            result = await service.search("Cached", ["anime"], object(), limit=5)
        finally:
            await service.aclose()

        self.assertEqual(result, cached)
        self.assertEqual(repository.search_kwargs["query"], "Cached")
        self.assertEqual(repository.search_kwargs["limit"], 5)


if __name__ == "__main__":
    unittest.main()
