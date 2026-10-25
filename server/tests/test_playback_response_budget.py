import asyncio
import json
import time
import unittest
from unittest.mock import patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.database import Base
from server.dependencies import get_session
from server.main import create_app
from server.playback import PlaybackService


def route(label):
    return {"source": "maccms:iKun", "url": f"https://cdn.example/{label}.m3u8",
            "status": "server_verified", "available": True, "expires_at": 0}


class PlaybackResponseBudgetTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        self.service = PlaybackService(session_factory=self.sessions, managed_lines_enabled=False)
        self.release = asyncio.Event()
        self.entered = asyncio.Event()
        self.cancelled = False
        self.refresh_calls = 0

        async def refresh(stable_id, episode, session, **kwargs):
            self.refresh_calls += 1
            self.entered.set()
            try:
                await self.release.wait()
            except asyncio.CancelledError:
                self.cancelled = True
                raise
            result = [route("full")]
            await self.service._store_cache(session, stable_id, episode, "fixture", result, scan_scope="full")
            return result

        self.service._refresh = refresh
        async with self.sessions() as session:
            await self.service._store_cache(session, "bangumi:400602", 1, "fixture", [route("quick")], scan_scope="quick")

    async def asyncTearDown(self):
        self.release.set()
        await self.service.aclose()
        await self.engine.dispose()

    async def test_budget_returns_quick_routes_without_cancelling_or_full_caching(self):
        async with self.sessions() as session:
            started = time.monotonic()
            with patch("server.playback.PLAYBACK_FULL_RESPONSE_TIMEOUT_SECONDS", 0.02, create=True):
                partial = await asyncio.wait_for(self.service.lines("bangumi:400602", 1, session), 0.5)
            self.assertLess(time.monotonic() - started, 0.4)
            self.assertEqual(partial[0]["url"], route("quick")["url"])
            self.assertTrue(partial[0]["discovery_pending"])
            self.assertFalse(self.cancelled)
            row = await self.service._repository_factory(session).get_cache("bangumi:400602", 1)
            self.assertEqual(row.scan_scope, "quick")
            self.assertEqual(json.loads(row.lines_json)[0]["url"], route("quick")["url"])
            self.release.set()
            await asyncio.gather(*self.service._refresh_tasks.values())
        async with self.sessions() as session:
            complete = await self.service.lines("bangumi:400602", 1, session)
            self.assertEqual(complete[0]["url"], route("full")["url"])
            self.assertFalse(complete[0].get("discovery_pending", False))
            self.assertEqual(self.refresh_calls, 1)

    async def test_http_partial_inventory_is_explicit_and_keeps_all_sources(self):
        app = create_app()
        async def override_session():
            async with self.sessions() as session:
                yield session
        app.dependency_overrides[get_session] = override_session
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            with patch("server.routers.playback.playback_service", self.service), patch("server.playback.PLAYBACK_FULL_RESPONSE_TIMEOUT_SECONDS", 0.02, create=True):
                response = await asyncio.wait_for(client.get("/api/v3/playback/bangumi:400602"), 0.5)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["X-Zeluna-Discovery"], "pending")
        items = response.json()
        self.assertGreaterEqual(len(items), 118)
        self.assertTrue(all(item["discovery_pending"] for item in items))
        self.assertTrue(any(item["url"] for item in items))

    async def test_peer_cancellation_does_not_cancel_shared_refresh(self):
        async with self.sessions() as one, self.sessions() as two:
            first = asyncio.create_task(self.service.lines("bangumi:400602", 1, one))
            await self.entered.wait()
            second = asyncio.create_task(self.service.lines("bangumi:400602", 1, two))
            await asyncio.sleep(0.01)
            first.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await first
            self.assertFalse(self.cancelled)
            self.release.set()
            result = await second
        self.assertEqual(result[0]["url"], route("full")["url"])
        self.assertEqual(self.refresh_calls, 1)
