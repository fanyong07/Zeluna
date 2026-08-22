import asyncio
import json
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

import httpx

from server.catalog import (
    CatalogService,
    _BANGUMI_RANKING_WEIGHTS,
    _weighted_rrf,
)


def _subject(stable_id: str, *, media_type: str = "anime") -> dict:
    provider_id = int(stable_id.rsplit(":", 1)[-1])
    return {
        "stable_id": stable_id,
        "provider": "bangumi" if stable_id.startswith("bangumi:") else "tmdb",
        "provider_id": provider_id,
        "media_type": media_type,
        "title": f"Subject {provider_id}",
        "original_title": f"Subject {provider_id}",
        "popularity": float(provider_id),
    }


class CatalogRankingTests(unittest.IsolatedAsyncioTestCase):
    def test_bangumi_heat_weight_exceeds_calendar_freshness(self):
        self.assertGreater(
            _BANGUMI_RANKING_WEIGHTS["heat"],
            _BANGUMI_RANKING_WEIGHTS["calendar"],
        )

    def test_weighted_rrf_exposes_the_public_ranking_contract(self):
        shared = _subject("bangumi:1")
        ranked = _weighted_rrf(
            "bangumi",
            [
                ("calendar", 1.25, [shared, _subject("bangumi:2")]),
                ("rank", 1.1, [shared, _subject("bangumi:3")]),
            ],
            ranked_at=1234.5,
            batch_id="bangumi:anime:1234500",
        )

        self.assertEqual(ranked[0]["stable_id"], "bangumi:1")
        ranking = ranked[0]["ranking"]
        self.assertEqual(
            set(ranking),
            {"batchId", "rankedAt", "globalScore", "lists"},
        )
        self.assertEqual(ranking["batchId"], "bangumi:anime:1234500")
        self.assertEqual(ranking["rankedAt"], 1234.5)
        self.assertEqual(ranking["globalScore"], 1.0)
        self.assertGreater(ranking["globalScore"], ranked[1]["ranking"]["globalScore"])
        self.assertEqual(ranked[-1]["ranking"]["globalScore"], 0.0)
        self.assertEqual(
            ranking["lists"],
            [
                {"provider": "bangumi", "kind": "calendar", "rank": 1},
                {"provider": "bangumi", "kind": "rank", "rank": 1},
            ],
        )

    def test_weighted_rrf_normalizes_single_and_tied_candidates(self):
        single = _weighted_rrf(
            "tmdb",
            [("popular", 1.1, [_subject("tmdb:movie:1", media_type="movie")])],
            ranked_at=10.0,
            batch_id="tmdb:movie:10000",
        )
        self.assertEqual(single[0]["ranking"]["globalScore"], 1.0)

        tied = _weighted_rrf(
            "tmdb",
            [
                ("popular", 1.0, [_subject("tmdb:movie:1", media_type="movie")]),
                ("top_rated", 1.0, [_subject("tmdb:movie:2", media_type="movie")]),
            ],
            ranked_at=20.0,
            batch_id="tmdb:movie:20000",
        )
        self.assertEqual(
            [item["ranking"]["globalScore"] for item in tied],
            [1.0, 1.0],
        )
        self.assertEqual(
            [entry["kind"] for item in tied for entry in item["ranking"]["lists"]],
            ["top_rated", "popular"],
        )

    async def test_bangumi_home_fuses_calendar_heat_score_and_rank(self):
        seen_sorts: set[str] = set()

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/calendar":
                return httpx.Response(200, json=[{"items": [{"id": 1, "name": "One"}]}])
            if request.url.path == "/v0/search/subjects":
                payload = json.loads(request.content)
                sort = payload["sort"]
                seen_sorts.add(sort)
                extra_id = 2 if sort == "heat" else 3
                return httpx.Response(
                    200,
                    json={
                        "data": [
                            {"id": 1, "name": "One"},
                            {"id": extra_id, "name": f"Extra {extra_id}"},
                        ]
                    },
                )
            if request.url.path == "/v0/subjects":
                self.assertEqual(request.url.params["sort"], "rank")
                return httpx.Response(
                    200,
                    json={
                        "data": [
                            {"id": 1, "name": "One"},
                            {"id": 4, "name": "Four"},
                        ]
                    },
                )
            return httpx.Response(404)

        service = CatalogService(transport=httpx.MockTransport(handler))
        try:
            items = await service._bangumi_home(4, ranked_at=100.0)
        finally:
            await service.aclose()

        self.assertEqual(seen_sorts, {"heat", "score"})
        self.assertEqual(items[0]["stable_id"], "bangumi:1")
        self.assertEqual(
            {entry["kind"] for entry in items[0]["ranking"]["lists"]},
            {"calendar", "heat", "score", "rank"},
        )

    async def test_bangumi_home_never_fetches_more_than_two_pages_per_list(self):
        search_offsets: list[tuple[str, int]] = []
        rank_offsets: list[int] = []

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/calendar":
                return httpx.Response(200, json=[])
            if request.url.path == "/v0/search/subjects":
                payload = json.loads(request.content)
                search_offsets.append((payload["sort"], int(request.url.params["offset"])))
                return httpx.Response(200, json={"data": []})
            if request.url.path == "/v0/subjects":
                rank_offsets.append(int(request.url.params["offset"]))
                return httpx.Response(200, json={"data": []})
            return httpx.Response(404)

        service = CatalogService(transport=httpx.MockTransport(handler))
        try:
            await service._bangumi_home(120, ranked_at=100.0)
        finally:
            await service.aclose()

        self.assertEqual(
            sorted(search_offsets),
            [("heat", 0), ("heat", 20), ("score", 0), ("score", 20)],
        )
        self.assertEqual(rank_offsets, [0, 100])

    async def test_tmdb_home_never_fetches_more_than_two_pages_per_list(self):
        requests: list[tuple[str, int]] = []

        def handler(request: httpx.Request) -> httpx.Response:
            page = int(request.url.params["page"])
            requests.append((request.url.path, page))
            base = {
                "/3/trending/movie/week": 100,
                "/3/movie/popular": 200,
                "/3/movie/top_rated": 300,
                "/3/movie/now_playing": 400,
            }[request.url.path]
            return httpx.Response(
                200,
                json={"results": [{"id": base + page, "title": f"Movie {base + page}"}]},
            )

        service = CatalogService(transport=httpx.MockTransport(handler))
        try:
            items = await service._tmdb_home("movie", 120, ranked_at=200.0)
        finally:
            await service.aclose()

        self.assertEqual(len(requests), 8)
        self.assertEqual({page for _, page in requests}, {1, 2})
        self.assertTrue(all(item["ranking"]["batchId"] == "tmdb:movie:200000" for item in items))
        self.assertEqual(
            {entry["kind"] for item in items for entry in item["ranking"]["lists"]},
            {"trending_week", "popular", "top_rated", "now_playing"},
        )

    async def test_tmdb_home_keeps_healthy_lists_when_one_returns_bad_json(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/3/trending/movie/week":
                return httpx.Response(
                    200,
                    content=b"{",
                    headers={"content-type": "application/json"},
                )
            base = {
                "/3/movie/popular": 200,
                "/3/movie/top_rated": 300,
                "/3/movie/now_playing": 400,
            }[request.url.path]
            page = int(request.url.params["page"])
            return httpx.Response(
                200,
                json={"results": [{"id": base + page, "title": f"Movie {base + page}"}]},
            )

        service = CatalogService(transport=httpx.MockTransport(handler))
        try:
            items = await service._tmdb_home("movie", 120, ranked_at=200.0)
        finally:
            await service.aclose()

        self.assertEqual(len(items), 6)
        self.assertEqual(
            {entry["kind"] for item in items for entry in item["ranking"]["lists"]},
            {"popular", "top_rated", "now_playing"},
        )

    async def test_tmdb_list_genre_ids_use_the_same_names_as_details(self):
        service = CatalogService(
            transport=httpx.MockTransport(lambda _: httpx.Response(500))
        )
        try:
            movie = service._subject_from_tmdb(
                {"id": 1, "title": "Movie", "genre_ids": [18, 10749]},
                "movie",
            )
            series = service._subject_from_tmdb(
                {"id": 2, "name": "Series", "genre_ids": [10765, 16]},
                "tv",
            )
        finally:
            await service.aclose()

        self.assertEqual(movie["genres"], ["剧情", "爱情"])
        self.assertEqual(series["genres"], ["科幻奇幻", "动画"])

    async def test_home_refresh_normalizes_limit_and_persists_once(self):
        class Repository:
            def __init__(self):
                self.persist_calls = 0
                self.persisted = []

            async def home_cached(self, **_kwargs):
                return []

            async def persist_many(self, entries):
                self.persist_calls += 1
                self.persisted.extend(entries)

        repository = Repository()
        service = CatalogService(
            transport=httpx.MockTransport(lambda _: httpx.Response(500)),
            repository_factory=lambda _session: repository,
        )
        entered = asyncio.Event()
        release = asyncio.Event()
        calls = 0
        candidates = [_subject(f"bangumi:{index}") for index in range(1, 121)]

        async def load(media_type: str, limit: int) -> list[dict]:
            nonlocal calls
            calls += 1
            self.assertEqual((media_type, limit), ("anime", 120))
            entered.set()
            await release.wait()
            return candidates

        service._load_home_candidates = load
        first = asyncio.create_task(service.home("anime", object(), limit=60))
        await entered.wait()
        second = asyncio.create_task(service.home("anime", object(), limit=240))
        release.set()
        try:
            first_result, second_result = await asyncio.gather(first, second)
        finally:
            await service.aclose()

        self.assertEqual(calls, 1)
        self.assertEqual(len(first_result), 60)
        self.assertEqual(len(second_result), 120)
        self.assertEqual(repository.persist_calls, 1)
        self.assertEqual(len(repository.persisted), 120)

    async def test_provider_requests_limit_concurrency_to_two(self):
        active = 0
        maximum = 0

        async def handler(_request: httpx.Request) -> httpx.Response:
            nonlocal active, maximum
            active += 1
            maximum = max(maximum, active)
            await asyncio.sleep(0.01)
            active -= 1
            return httpx.Response(200, json={})

        service = CatalogService(transport=httpx.MockTransport(handler))
        try:
            await asyncio.gather(
                *(
                    service._provider_request("tmdb", "GET", f"https://example.com/{index}")
                    for index in range(6)
                )
            )
        finally:
            await service.aclose()

        self.assertEqual(maximum, 2)

    async def test_retry_after_starts_provider_cooldown(self):
        now = [100.0]
        sleeps: list[float] = []
        responses = 0

        async def sleep(delay: float) -> None:
            sleeps.append(delay)
            now[0] += delay

        def handler(_request: httpx.Request) -> httpx.Response:
            nonlocal responses
            responses += 1
            if responses == 1:
                return httpx.Response(429, headers={"Retry-After": "7"})
            return httpx.Response(200)

        service = CatalogService(
            transport=httpx.MockTransport(handler),
            clock=lambda: now[0],
            sleep=sleep,
        )
        try:
            first = await service._provider_request("bangumi", "GET", "https://example.com/1")
            second = await service._provider_request("bangumi", "GET", "https://example.com/2")
        finally:
            await service.aclose()

        self.assertEqual((first.status_code, second.status_code), (429, 200))
        self.assertEqual(sleeps, [7.0])

    async def test_stale_home_returns_immediately_and_refreshes_in_own_session(self):
        fresh = [_subject("bangumi:10")]
        stale = [*fresh, _subject("bangumi:11"), _subject("bangumi:12")]
        request_session = object()
        background_session = object()

        class RequestRepository:
            def __init__(self):
                self.home_calls = 0

            async def home_cached(self, **_kwargs):
                self.home_calls += 1
                return fresh if self.home_calls == 1 else stale

            async def persist_many(self, _entries):
                raise AssertionError("request-scoped repository must not refresh")

        class BackgroundRepository:
            def __init__(self):
                self.persisted = []

            async def persist_many(self, entries):
                self.persisted.extend(entries)

        request_repository = RequestRepository()
        background_repository = BackgroundRepository()

        def repository_factory(session):
            if session is request_session:
                return request_repository
            self.assertIs(session, background_session)
            return background_repository

        @asynccontextmanager
        async def session_factory():
            yield background_session

        service = CatalogService(
            transport=httpx.MockTransport(lambda _: httpx.Response(500)),
            repository_factory=repository_factory,
            session_factory=session_factory,
            clock=lambda: 1000.0,
        )
        refreshed = _subject("bangumi:20")
        refreshed["ranking"] = {
            "batchId": "bangumi:anime:new",
            "rankedAt": 1000.0,
            "globalScore": 1.0,
            "lists": [{"provider": "bangumi", "kind": "heat", "rank": 1}],
        }
        refresh_started = asyncio.Event()
        release_refresh = asyncio.Event()

        async def load(_media_type: str, _limit: int) -> list[dict]:
            refresh_started.set()
            await release_refresh.wait()
            return [refreshed]

        service._load_home_candidates = AsyncMock(side_effect=load)
        try:
            result = await asyncio.wait_for(
                service.home("anime", request_session, limit=3),
                timeout=0.2,
            )
            await asyncio.wait_for(refresh_started.wait(), timeout=0.2)
            self.assertEqual(
                [item["stable_id"] for item in result],
                ["bangumi:10", "bangumi:11", "bangumi:12"],
            )
            self.assertEqual(background_repository.persisted, [])

            release_refresh.set()
            await asyncio.gather(*service._home_refreshes.values())
        finally:
            await service.aclose()

        self.assertEqual(len(background_repository.persisted), 1)
        service._load_home_candidates.assert_awaited_once_with("anime", 120)


if __name__ == "__main__":
    unittest.main()
