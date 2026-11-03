import asyncio
import unittest
from unittest.mock import patch

import httpx
from fastapi import FastAPI

from server.catalog_artwork import CatalogArtworkCache, ArtworkUnavailable, public_artwork_url
from server.catalog import CatalogService
from server.routers.catalog import router

URL = "https://lain.bgm.tv/r/400/pic/cover/l/27/ff/377130_wDU1x.jpg"
JPEG = b"\xff\xd8\xff" + b"image fixture"


class ArtworkTests(unittest.IsolatedAsyncioTestCase):
    async def test_rejects_arbitrary_hosts_credentials_paths_and_queries(self):
        for url in ["http://lain.bgm.tv/pic/cover/l/a.jpg", "https://127.0.0.1/x.jpg",
                    "https://lain.bgm.tv.evil.test/pic/cover/l/a.jpg",
                    "https://user:secret@lain.bgm.tv/pic/cover/l/a.jpg",
                    URL + "?token=secret", URL + "#x", URL.replace('/r/400/', '/%2e%2e/'),
                    "https://api.bgm.tv/v0/me", "https://lain.bgm.tv:8443/pic/cover/l/a.jpg"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                public_artwork_url(url)
        self.assertEqual(public_artwork_url(URL), URL)

    async def test_deduplicates_concurrent_downloads_and_caches(self):
        calls = []
        async def wire(request):
            calls.append(request)
            await asyncio.sleep(0.02)
            return httpx.Response(200, content=JPEG, headers={"Content-Type": "image/jpeg"})
        cache = CatalogArtworkCache(transport=httpx.MockTransport(wire))
        self.addAsyncCleanup(cache.aclose)
        values = await asyncio.gather(*(cache.get(URL) for _ in range(10)))
        self.assertEqual(len(calls), 1)
        self.assertEqual((await cache.get(URL)).body, JPEG)
        self.assertEqual(len(calls), 1)
        self.assertTrue(all(value.etag == values[0].etag for value in values))
        self.assertNotIn("authorization", calls[0].headers)
        self.assertNotIn("cookie", calls[0].headers)

    async def test_redirects_are_rechecked_and_html_not_cached(self):
        for response in [httpx.Response(302, headers={"location": "http://127.0.0.1/private"}),
                         httpx.Response(200, content=b"<html>blocked</html>", headers={"content-type": "image/jpeg"}),
                         httpx.Response(200, content=b"x", headers={"content-type": "text/html"}),
                         httpx.Response(200, content=JPEG, headers={"content-type": "image/jpeg", "content-length": str(3*1024*1024)})]:
            calls = []
            def wire(request):
                calls.append(request)
                return response
            cache = CatalogArtworkCache(transport=httpx.MockTransport(wire))
            with self.assertRaises(ArtworkUnavailable):
                await cache.get(URL)
            with self.assertRaises(ArtworkUnavailable):
                await cache.get(URL)
            self.assertEqual(len(calls), 1)
            self.assertEqual(cache._bytes, 0)
            await cache.aclose()

    async def test_cancelled_waiter_does_not_cancel_other_image_readers(self):
        started, finish = asyncio.Event(), asyncio.Event()
        async def wire(_):
            started.set()
            await finish.wait()
            return httpx.Response(200, content=JPEG, headers={"content-type": "image/jpeg"})
        cache = CatalogArtworkCache(transport=httpx.MockTransport(wire))
        self.addAsyncCleanup(cache.aclose)
        first = asyncio.create_task(cache.get(URL))
        await started.wait()
        second = asyncio.create_task(cache.get(URL))
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await first
        finish.set()
        self.assertEqual((await second).body, JPEG)

    async def test_route_caches_public_image_and_supports_conditional_get(self):
        app = FastAPI(); app.include_router(router)
        cache = CatalogArtworkCache(transport=httpx.MockTransport(lambda _: httpx.Response(
            200, content=JPEG, headers={"content-type": "image/jpeg"})))
        self.addAsyncCleanup(cache.aclose)
        with patch("server.routers.catalog.catalog_artwork", cache):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url="https://test") as client:
                image = await client.get("/api/v3/catalog/image", params={"url": URL}, headers={"Authorization": "Bearer private"})
                self.assertEqual(image.status_code, 200)
                self.assertEqual(image.content, JPEG)
                self.assertIn("public", image.headers["cache-control"])
                unchanged = await client.get("/api/v3/catalog/image", params={"url": URL}, headers={"If-None-Match": image.headers["etag"]})
                self.assertEqual(unchanged.status_code, 304)
                self.assertEqual(unchanged.content, b"")
                denied = await client.get("/api/v3/catalog/image", params={"url": "https://evil.test/a.mp4"})
                self.assertEqual(denied.status_code, 400)

    async def test_extras_use_fixed_public_api_without_auth(self):
        seen = []
        def wire(request):
            seen.append(request)
            return httpx.Response(200, json=[])
        service = CatalogService(transport=httpx.MockTransport(wire))
        self.addAsyncCleanup(service.aclose)
        for section in ("characters", "persons", "subjects"):
            self.assertEqual(await service.public_bangumi_catalog(section, subject_id=464376), [])
        self.assertEqual(seen[0].url.path, "/v0/subjects/464376/characters")
        self.assertTrue(all("authorization" not in req.headers for req in seen))
        with self.assertRaises(ValueError):
            await service.public_bangumi_catalog("characters", subject_id=-1)

    async def test_public_catalog_cache_coalesces_and_expires(self):
        now = [1000.0]
        calls = []
        async def wire(request):
            calls.append(request)
            await asyncio.sleep(0.01)
            return httpx.Response(200, json=[{"id": 1}])
        service = CatalogService(transport=httpx.MockTransport(wire), clock=lambda: now[0])
        self.addAsyncCleanup(service.aclose)
        await asyncio.gather(*(service.public_bangumi_catalog("calendar") for _ in range(6)))
        self.assertEqual(len(calls), 1)
        result = await service.public_bangumi_catalog("calendar")
        result.clear()
        self.assertEqual(await service.public_bangumi_catalog("calendar"), [{"id": 1}])
        now[0] += 301
        await service.public_bangumi_catalog("calendar")
        self.assertEqual(len(calls), 2)

    async def test_relay_preserves_rate_limit_instead_of_triggering_direct_retry(self):
        app = FastAPI(); app.include_router(router)
        service = CatalogService(transport=httpx.MockTransport(lambda _: httpx.Response(
            429, headers={"retry-after": "45"})))
        self.addAsyncCleanup(service.aclose)
        with patch("server.routers.catalog.catalog_service", service):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url="https://test") as client:
                response = await client.get("/api/v3/catalog/bangumi/calendar")
                self.assertEqual(response.status_code, 429)
                self.assertEqual(response.headers["retry-after"], "45")
