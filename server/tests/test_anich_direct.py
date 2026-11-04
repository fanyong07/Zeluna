"""Resolver persistence, expiry, bounded health probes and periodic maintenance."""
import time
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import anich_direct as direct, anich_refresh as refresh
from server.database import AniChResolvedAddress

WRAP = "https://v-cdn.emmmm.eu.org/video/fixture"
REAL = "https://media.test/fixture.mp4"


class ProbeStream(httpx.AsyncByteStream):
    def __init__(self):
        self.chunks_read = 0
        self.closed = False

    async def __aiter__(self):
        for _ in range(10000):
            self.chunks_read += 1
            yield b"x" * 1024

    async def aclose(self):
        self.closed = True


class ResolverUnitTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        scheduling = patch("server.scrapers.anime.anich._schedule_resolve")
        scheduling.start()
        self.addCleanup(scheduling.stop)

    async def asyncTearDown(self):
        direct.replace_cache({})

    async def test_range_probe_stops_after_small_sample_even_when_range_ignored(self):
        stream = ProbeStream()

        def handler(request):
            assert request.headers["Range"] == "bytes=0-1023"
            return httpx.Response(200, headers={"content-type": "video/mp4"}, stream=stream)

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            ok, _, error = await direct.probe_real_url(REAL, client=client)
        assert ok and not error
        assert stream.chunks_read == 1 and stream.closed

    async def test_html_response_is_not_healthy_media(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, headers={"content-type": "text/html"}, text="<html>login</html>")
        )) as client:
            ok, _, error = await direct.probe_real_url(REAL, client=client)
        assert not ok and error == "non-media response"

    async def test_resolver_reads_location_without_fetching_media(self):
        seen = []

        def handler(request):
            seen.append(str(request.url))
            return httpx.Response(302, headers={"Location": REAL + "?x-expires=2000000000"})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            result = await direct.resolve_wrapper(WRAP, client=client)
        assert result.real_url == REAL + "?x-expires=2000000000"
        assert result.expires_at == 2000000000 and seen == [WRAP]

    async def test_expired_signature_does_not_become_unsigned(self):
        assert direct.parse_expiry(REAL + "?x-expires=100", 200) == 100
        assert direct.parse_expiry(REAL, 200) == 0
        direct.replace_cache({WRAP: (REAL, 100)})
        assert direct.lookup(WRAP, now=200) is None

    async def test_family_matches_hostname_boundaries(self):
        assert direct.family_of(WRAP) == direct.AddressFamily.CLOUDFLARE
        assert direct.family_of("https://notemmmm.eu.org/1") == direct.AddressFamily.UNKNOWN
        assert direct.family_of("https://emmmm.eu.org.attacker.test/1") == direct.AddressFamily.UNKNOWN
        assert direct.family_of("https://vod-cdn.sends.eu.org.cdn.cloudflare.net/1") == direct.AddressFamily.EDGEONE
        assert direct.family_of("https://v-cdn.emmmm.eu.org.cdn.cloudflare.net/1") == direct.AddressFamily.CLOUDFLARE
        assert direct.family_of("https://vod-cdn.sends.eu.org.cdn.cloudflare.net.evil.test/1") == direct.AddressFamily.UNKNOWN

    async def test_v3_cached_and_fresh_playback_use_current_mapping(self):
        import json
        from types import SimpleNamespace
        from server.aggregator import AggregatedVideoLine
        from server.playback import PlaybackService, public_playback_item
        direct.replace_cache({WRAP: (REAL, 0)})
        item = {"url": WRAP, "source": "crawler:anich:hb-10", "available": True}
        projected = public_playback_item(item)
        assert projected["url"] == REAL and projected["source"] == "hb-10"
        assert item["url"] == WRAP  # do not mutate stored cache records
        row = SimpleNamespace(line_count=1, verified_at=time.time(), lines_json=json.dumps([item]))
        state, lines = PlaybackService._cache_state_and_items(row)
        assert state == "fresh" and lines[0]["url"] == REAL
        service = PlaybackService.__new__(PlaybackService)
        assert service._playable_url(AggregatedVideoLine(url=WRAP)) == REAL
        direct.replace_cache({})
        assert public_playback_item(item)["url"] == WRAP  # original fallback remains

    async def test_cached_direct_url_renews_and_degrades_via_private_origin_key(self):
        from server.playback import public_playback_item
        direct.replace_cache({WRAP: (REAL, 0)})
        stored = public_playback_item({"url": REAL, "expires_at": 0,
            "source": "crawler:anich:hb-10", "available": True, "status": "server_verified"},
            keep_internal=True)
        assert stored["_resolved_wrap_url"] == WRAP
        renewed = REAL + "?x-expires=2000000000"
        direct.replace_cache({WRAP: (renewed, 2000000000)})
        response = public_playback_item(stored)
        assert response["url"] == renewed and response["expires_at"] == 2000000000
        assert "_resolved_wrap_url" not in response
        direct.replace_cache({})
        with patch("server.scrapers.anime.anich._schedule_resolve") as schedule:
            response = public_playback_item(stored)
        assert response["url"] == WRAP and response["available"] is False
        assert response["status"] == "client_probe_required"
        schedule.assert_called_once_with([WRAP])

    async def test_headerless_error_body_is_not_healthy_media(self):
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, content=b"  <!DOCTYPE html><html>error</html>")
        )) as client:
            ok, _, error = await direct.probe_real_url(REAL, client=client)
        assert not ok and error == "non-media response"

    async def test_wrapper_body_is_never_downloaded(self):
        stream = ProbeStream()
        async with httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, stream=stream)
        )) as client:
            assert await direct.resolve_wrapper(WRAP, client=client) is None
        assert stream.chunks_read == 0 and stream.closed

    async def test_metadata_only_placeholder_does_not_require_url(self):
        from server.playback import public_playback_item
        assert public_playback_item({"available": False}, keep_internal=True) == {"available": False}

    async def test_cache_expiry_and_unsigned_behavior(self):
        direct.replace_cache({WRAP: (REAL, 0), "signed": (REAL, 100000)})
        assert direct.lookup(WRAP, now=1000000000) == REAL
        assert direct.lookup("signed", now=100000 - direct.EXPIRY_SAFETY_SECONDS) is None
        assert direct.lookup("missing") is None


class ResolverDatabaseTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(AniChResolvedAddress.__table__.create)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def asyncTearDown(self):
        direct.replace_cache({})
        await self.engine.dispose()

    async def test_atomic_upsert_repeated_requests_and_failure_recovery(self):
        async with self.sessions() as session:
            for _ in range(3):
                await refresh._upsert(session, wrap_url=WRAP, real_url=REAL,
                    host_family="cloudflare", expires_at=0, verify_ok=True,
                    latency_ms=10, error="", now=time.time())
            await session.commit()
            assert len((await session.scalars(select(AniChResolvedAddress))).all()) == 1
            for _ in range(3):
                await refresh._upsert(session, wrap_url=WRAP, real_url="",
                    host_family="cloudflare", expires_at=0, verify_ok=False,
                    latency_ms=100, error="timeout", now=time.time())
            await session.commit()
            session.expire_all()
            row = (await session.scalars(select(AniChResolvedAddress))).one()
            assert row.real_url == REAL and row.fail_count == 3 and not row.verify_ok
            assert await direct.load_cache_from_session(session) == 0
            await refresh._upsert(session, wrap_url=WRAP, real_url=REAL,
                host_family="cloudflare", expires_at=0, verify_ok=True,
                latency_ms=10, error="", now=time.time())
            await session.commit()
            assert await direct.load_cache_from_session(session) == 1
            assert direct.lookup(WRAP) == REAL

    async def test_periodic_refresh_includes_unsigned_stale_and_failed(self):
        now = time.time()
        async with self.sessions() as session:
            for name, expiry, verified, ok in [
                ("unsigned-old", 0, now - 90000, True),
                ("unsigned-fresh", 0, now, True),
                ("expiring", now + 100, now, True),
                ("failed", 0, now, False),
            ]:
                session.add(AniChResolvedAddress(wrap_url=name, real_url=REAL,
                    host_family="edgeone", expires_at=expiry, verified_at=verified,
                    verify_ok=ok, resolved_at=now))
            await session.commit()
            with patch.object(refresh, "resolve_and_store", new=AsyncMock(return_value={"ok": True})) as work:
                await refresh.refresh_expiring(session)
                assert set(work.await_args.args[1]) == {"unsigned-old", "expiring", "failed"}

    async def test_failed_wrapper_refresh_updates_health_instead_of_silently_skipping(self):
        async with self.sessions() as session:
            await refresh._upsert(session, wrap_url=WRAP, real_url=REAL,
                host_family="cloudflare", expires_at=0, verify_ok=True,
                latency_ms=10, error="", now=time.time())
            await session.commit()
            with patch.object(direct, "resolve_many", new=AsyncMock(return_value=[])):
                for _ in range(3):
                    outcome = await refresh.resolve_and_store(session, [WRAP])
            session.expire_all()
            row = (await session.scalars(select(AniChResolvedAddress))).one()
            assert row.fail_count == 3 and not row.verify_ok
            assert row.real_url == REAL and row.last_error == "wrapper resolution failed"
            assert outcome["resolved"] == 0 and outcome["failures"]
            assert direct.lookup(WRAP) is None and direct.origin_for(REAL) == WRAP

    async def test_resolution_commit_warms_same_process_cache(self):
        result = direct.ResolvedAddress(WRAP, REAL, "cloudflare", 0, 12)
        with patch.object(direct, "resolve_many", new=AsyncMock(return_value=[result])), patch.object(
            direct, "probe_real_url", new=AsyncMock(return_value=(True, 10, ""))
        ):
            async with self.sessions() as session:
                outcome = await refresh.resolve_and_store(session, [WRAP, WRAP])
                assert outcome["requested"] == 1 and outcome["usable"] == 1
                assert direct.lookup(WRAP) == REAL
