import unittest
from datetime import datetime, timezone
from unittest.mock import AsyncMock, patch

import httpx

from server.catalog import CatalogService


class CatalogDiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_bangumi_calendar_dates_and_language_are_not_fabricated(self):
        service = CatalogService()
        self.addAsyncCleanup(service.aclose)
        item = service._subject_from_bangumi({"id": 9, "name": "Test", "air_date": "2026-10-06", "tags": [{"name": "国产"}]})
        self.assertEqual(item["date"], "2026-10-06")
        self.assertEqual(item["language"], "zh")
        self.assertEqual(item["region"], "中国")
        unknown = service._subject_from_bangumi({"id": 10, "name": "Unknown"})
        self.assertEqual(unknown["language"], "")

    async def test_series_query_filters_upstream_and_keeps_real_pagination(self):
        seen = []

        def handler(request):
            seen.append(request)
            return httpx.Response(200, json={"total_pages": 8, "results": [
                {"id": 1, "name": "Drama", "genre_ids": [18], "first_air_date": "2026-10-01"},
                {"id": 2, "name": "Animation", "genre_ids": [16, 18], "first_air_date": "2026-10-01"},
            ]})

        service = CatalogService(transport=httpx.MockTransport(handler),
                                 clock=lambda: datetime(2026, 10, 6, tzinfo=timezone.utc).timestamp())
        self.addAsyncCleanup(service.aclose)
        with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"), \
             patch.object(service, "_persist_many", new=AsyncMock()):
            page = await service.discover("tv", None, sort="latest", year=2026,
                                          genre="剧情", language="日语", page=3)
        query = seen[0].url.params
        self.assertEqual(query["without_genres"], "16")
        self.assertEqual(query["with_genres"], "18")
        self.assertEqual(query["with_original_language"], "ja")
        self.assertEqual(query["first_air_date.gte"], "2026-01-01")
        self.assertEqual(query["first_air_date.lte"], "2026-10-06")
        self.assertEqual(query["sort_by"], "first_air_date.desc")
        self.assertEqual(query["page"], "3")
        self.assertEqual([item["stable_id"] for item in page["subjects"]], ["tmdb:tv:1"])
        self.assertEqual(page["next_cursor"], "4")

    async def test_latest_movie_never_includes_future_or_undated_items(self):
        def handler(request):
            self.assertEqual(request.url.params["primary_release_date.lte"], "2026-10-06")
            return httpx.Response(200, json={"total_pages": 1, "results": [
                {"id": 1, "title": "Released", "release_date": "2026-10-05"},
                {"id": 2, "title": "Future", "release_date": "2027-01-01"},
                {"id": 3, "title": "Unknown", "release_date": ""},
            ]})
        service = CatalogService(transport=httpx.MockTransport(handler),
                                 clock=lambda: datetime(2026, 10, 6, tzinfo=timezone.utc).timestamp())
        self.addAsyncCleanup(service.aclose)
        with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"), \
             patch.object(service, "_persist_many", new=AsyncMock()):
            result = await service.discover("movie", None, sort="latest")
        self.assertEqual([item["stable_id"] for item in result["subjects"]], ["tmdb:movie:1"])
        self.assertIsNone(result["next_cursor"])

    async def test_provider_failure_is_not_an_empty_catalog(self):
        service = CatalogService(transport=httpx.MockTransport(lambda _: httpx.Response(503)))
        self.addAsyncCleanup(service.aclose)
        with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"):
            with self.assertRaises(httpx.HTTPStatusError):
                await service.discover("tv", None, year=2026)

    async def test_animation_never_enters_live_action_home(self):
        def handler(request):
            return httpx.Response(200, json={"results": [
                {"id": 1, "name": "Anime", "genre_ids": [16, 18]},
                {"id": 2, "name": "Series", "genre_ids": [18]},
            ]})
        service = CatalogService(transport=httpx.MockTransport(handler))
        self.addAsyncCleanup(service.aclose)
        with patch("server.catalog.TMDB_READ_ACCESS_TOKEN", "test-token"):
            result = await service._tmdb_home("tv", 5)
        self.assertEqual([item["stable_id"] for item in result], ["tmdb:tv:2"])


class CatalogDiscoveryRouteTests(unittest.IsolatedAsyncioTestCase):
    async def test_route_preserves_query_and_cursor_contract(self):
        from fastapi import FastAPI
        from server.dependencies import get_session
        from server.routers.catalog import router
        app = FastAPI()
        app.include_router(router)

        async def session():
            yield None
        app.dependency_overrides[get_session] = session
        loader = AsyncMock(return_value={"subjects": [], "next_cursor": "3"})
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            with patch("server.routers.catalog.catalog_service.discover", loader):
                response = await client.get("/api/v3/catalog/discover/tv", params={
                    "sort": "latest", "year": 2026, "genre": "日剧", "language": "日语", "page": 2})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["next_cursor"], "3")
        loader.assert_awaited_once_with("tv", None, sort="latest", genre="日剧",
                                       language="日语", year=2026, page=2)

    async def test_invalid_pagination_and_sort_never_reach_provider(self):
        from fastapi import FastAPI
        from server.dependencies import get_session
        from server.routers.catalog import router
        app = FastAPI()
        app.include_router(router)
        async def session():
            yield None
        app.dependency_overrides[get_session] = session
        loader = AsyncMock()
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            with patch("server.routers.catalog.catalog_service.discover", loader):
                for query in [{"page": 0}, {"page": 501}, {"year": 1800}, {"sort": "not-a-sort"}]:
                    response = await client.get("/api/v3/catalog/discover/tv", params=query)
                    self.assertEqual(response.status_code, 422)
        loader.assert_not_awaited()

    async def test_provider_errors_have_a_safe_retry_response(self):
        from fastapi import FastAPI
        from server.dependencies import get_session
        from server.routers.catalog import router
        app = FastAPI()
        app.include_router(router)
        async def session():
            yield None
        app.dependency_overrides[get_session] = session
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            with patch("server.routers.catalog.catalog_service.discover", AsyncMock(side_effect=RuntimeError("private provider diagnostics"))):
                response = await client.get("/api/v3/catalog/discover/tv")
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("private provider", response.text)


class PublicBangumiCatalogTests(unittest.IsolatedAsyncioTestCase):
    async def test_public_catalog_relay_uses_fixed_upstream_without_credentials(self):
        requests = []
        def handler(request):
            requests.append(request)
            return httpx.Response(200, json=[{"weekday": {"id": 1}, "items": []}])
        service = CatalogService(transport=httpx.MockTransport(handler))
        self.addAsyncCleanup(service.aclose)
        with patch("server.catalog.BANGUMI_ACCESS_TOKEN", "must-not-be-forwarded"):
            result = await service.public_bangumi_catalog("calendar")
        self.assertEqual(result[0]["weekday"]["id"], 1)
        self.assertEqual(str(requests[0].url), "https://api.bgm.tv/calendar")
        self.assertNotIn("Authorization", requests[0].headers)
        self.assertNotIn("Cookie", requests[0].headers)
        with self.assertRaises(ValueError):
            await service.public_bangumi_catalog("https://example.com/private")

    async def test_public_routes_bound_inputs_and_never_forward_client_auth(self):
        from fastapi import FastAPI
        from server.routers.catalog import router
        app = FastAPI()
        app.include_router(router)
        loader = AsyncMock(return_value={"data": [], "total": 0})
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            with patch("server.routers.catalog.catalog_service.public_bangumi_catalog", loader):
                response = await client.get("/api/v3/catalog/bangumi/v0/subjects", params={
                    "type": 2, "sort": "date", "year": 2026, "limit": 100, "offset": 100},
                    headers={"Authorization": "Bearer private-client-token", "Cookie": "private-cookie"})
                self.assertEqual(response.status_code, 200)
                loader.assert_awaited_once_with("subjects", params={
                    "type": 2, "sort": "date", "year": 2026, "limit": 100, "offset": 100})
                loader.reset_mock()
                for params in [{"type": 1}, {"limit": 101}, {"offset": -1}, {"year": 1800}, {"sort": "other"}]:
                    self.assertEqual((await client.get("/api/v3/catalog/bangumi/v0/subjects", params=params)).status_code, 422)
                for body in [{"keyword": "private search"}, {"filter": {"nsfw": True}}, {"filter": {"tag": ["x" * 100]}}]:
                    self.assertEqual((await client.post("/api/v3/catalog/bangumi/v0/search/subjects", json=body)).status_code, 422)
                loader.assert_not_awaited()
                body = {"keyword": "", "sort": "heat", "filter": {"type": [2], "nsfw": False, "tag": ["国产"], "air_date": [">=2026-01-01", "<2027-01-01"]}}
                response = await client.post("/api/v3/catalog/bangumi/v0/search/subjects", params={"limit": 20, "offset": 0}, json=body)
                self.assertEqual(response.status_code, 200)
                loader.assert_awaited_once_with("search", params={"limit": 20, "offset": 0}, body=body)

    async def test_calendar_provider_failure_is_retryable_not_empty(self):
        from fastapi import FastAPI
        from server.routers.catalog import router
        app = FastAPI()
        app.include_router(router)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            with patch("server.routers.catalog.catalog_service.public_bangumi_catalog", AsyncMock(side_effect=ValueError("private diagnostics"))):
                response = await client.get("/api/v3/catalog/bangumi/calendar")
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("private diagnostics", response.text)
