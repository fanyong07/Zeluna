import asyncio
import json
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from server.database import PlaybackCache, create_database_engine, upsert_playback_cache
from server.playback import PlaybackService
from server.repositories.playback import SqlPlaybackRepository


def _lines(label, count=1):
    return [
        {
            "url": f"https://cdn.example/{label}-{index}.m3u8",
            "source": f"maccms:fixture-{index}",
            "available": True,
            "status": "server_verified",
            "expires_at": 0,
            "headers": {"Referer": "https://player.example/"},
        }
        for index in range(count)
    ]


class _BarrierSession(AsyncSession):
    """Pause after a real SQL read, not a mocked repository response."""

    async def execute(self, statement, *args, **kwargs):
        result = await super().execute(statement, *args, **kwargs)
        barriers = self.info.get("cache_read_barriers")
        barrier = barriers[0] if barriers else self.info.get("cache_read_barrier")
        if (
            barrier is not None
            and getattr(statement, "is_select", False)
            and any(
                item.get("entity") is PlaybackCache
                for item in getattr(statement, "column_descriptions", [])
            )
        ):
            if barriers:
                barriers.pop(0)
            else:
                self.info.pop("cache_read_barrier")
            observed, release = barrier
            observed.set()
            await asyncio.wait_for(release.wait(), timeout=3)
        update_barrier = self.info.get("cache_update_barrier")
        if update_barrier is not None and getattr(statement, "is_update", False):
            self.info.pop("cache_update_barrier")
            observed, release = update_barrier
            observed.set()
            await asyncio.wait_for(release.wait(), timeout=3)
        return result


class PlaybackCacheRaceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="zeluna-cache-race-")
        url = f"sqlite+aiosqlite:///{Path(self.directory.name) / 'cache.sqlite'}"
        self.engine = create_database_engine(url)
        self.peer_engine = create_database_engine(url)
        async with self.engine.begin() as connection:
            await connection.run_sync(PlaybackCache.__table__.create)
        self.sessions = async_sessionmaker(
            self.engine,
            class_=_BarrierSession,
            expire_on_commit=False,
        )
        self.peer_sessions = async_sessionmaker(
            self.peer_engine,
            class_=_BarrierSession,
            expire_on_commit=False,
        )
        self.service = PlaybackService(managed_lines_enabled=False)
        self.integrity_conflicts = 0

        @event.listens_for(self.engine.sync_engine, "handle_error")
        def record_integrity_error(context):
            if isinstance(context.original_exception, sqlite3.IntegrityError):
                self.integrity_conflicts += 1

    async def asyncTearDown(self):
        await self.service.aclose()
        await self.engine.dispose()
        await self.peer_engine.dispose()
        self.directory.cleanup()

    async def store(self, sessions, scope, *, key="bangumi:7001", lines=None):
        async with sessions() as session:
            await self.service._store_cache(
                session,
                key,
                1,
                scope,
                lines or _lines(scope, 2 if scope == "full" else 1),
                scan_scope=scope,
            )

    async def cached(self, key="bangumi:7001"):
        async with self.peer_sessions() as session:
            return await SqlPlaybackRepository(session).get_cache(key, 1)

    async def test_separate_session_quick_read_then_full_commit_cannot_downgrade(self):
        for seed in ("absent", "expired"):
            with self.subTest(seed=seed):
                key = f"bangumi:race-{seed}"
                if seed == "expired":
                    async with self.peer_sessions() as session:
                        await SqlPlaybackRepository(session).upsert_cache(
                            subject_id=key,
                            episode=1,
                            title="expired",
                            lines_json=json.dumps(_lines("expired")),
                            line_count=1,
                            verified_at=1,
                            scan_scope="full",
                        )
                observed, release = asyncio.Event(), asyncio.Event()
                async with self.sessions() as quick_session:
                    quick_session.info["cache_read_barrier"] = (observed, release)
                    quick = asyncio.create_task(
                        self.service._store_cache(
                            quick_session,
                            key,
                            1,
                            "quick",
                            _lines("quick"),
                            scan_scope="quick",
                        )
                    )
                    try:
                        await asyncio.wait_for(observed.wait(), timeout=3)
                        await self.store(self.peer_sessions, "full", key=key)
                        release.set()
                        await asyncio.wait_for(quick, timeout=3)
                    finally:
                        release.set()
                        if not quick.done():
                            quick.cancel()
                        await asyncio.gather(quick, return_exceptions=True)
                row = await self.cached(key)
                self.assertEqual(row.scan_scope, "full")
                self.assertEqual(row.title, "full")
                self.assertEqual(json.loads(row.lines_json), _lines("full", 2))
                self.assertEqual(row.line_count, 2)
        # Cold inserts really collided in SQLite and used IntegrityError recovery.
        self.assertEqual(self.integrity_conflicts, 1)

    async def test_sequential_quick_full_controls(self):
        await self.store(self.sessions, "full")
        await self.store(self.peer_sessions, "quick")
        self.assertEqual((await self.cached()).scan_scope, "full")
        await self.store(self.sessions, "quick", key="bangumi:7002")
        self.assertEqual((await self.cached("bangumi:7002")).scan_scope, "quick")
        await self.store(self.peer_sessions, "full", key="bangumi:7002")
        self.assertEqual((await self.cached("bangumi:7002")).scan_scope, "full")

    async def test_reverse_and_same_scope_cold_insert_controls(self):
        for late_scope, early_scope in (
            ("full", "quick"),
            ("full", "full"),
            ("quick", "quick"),
        ):
            with self.subTest(late_scope=late_scope, early_scope=early_scope):
                key = f"bangumi:{late_scope}-{early_scope}"
                observed, release = asyncio.Event(), asyncio.Event()
                async with self.sessions() as late_session:
                    late_session.info["cache_read_barrier"] = (observed, release)
                    late = asyncio.create_task(
                        self.service._store_cache(
                            late_session,
                            key,
                            1,
                            "late",
                            _lines("late"),
                            scan_scope=late_scope,
                        )
                    )
                    try:
                        await asyncio.wait_for(observed.wait(), timeout=3)
                        # A separate key can also complete while this read is paused.
                        await self.store(self.peer_sessions, "full", key=key + "-other")
                        await self.store(self.peer_sessions, early_scope, key=key)
                        release.set()
                        await asyncio.wait_for(late, timeout=3)
                    finally:
                        release.set()
                        if not late.done():
                            late.cancel()
                        await asyncio.gather(late, return_exceptions=True)
                row = await self.cached(key)
                self.assertEqual(row.scan_scope, late_scope)
                self.assertEqual(row.title, "late")
                self.assertEqual(json.loads(row.lines_json), _lines("late"))
                self.assertEqual((await self.cached(key + "-other")).scan_scope, "full")
        self.assertEqual(self.integrity_conflicts, 3)

    async def test_qualification_preserves_expiry_negative_route_and_scope_policy(self):
        now = 2_000_000_000
        positive = _lines("seed")
        expired_signed = [{**positive[0], "expires_at": now + 14}]
        client_candidate = [
            {**positive[0], "available": False, "status": "client_probe_required"}
        ]
        legacy = [{"url": positive[0]["url"], "headers": positive[0]["headers"]}]
        cases = [
            ("fresh", "full", positive * 4, 4, 0, False),
            ("stale", "full", positive * 4, 4, 601, False),
            ("expired", "full", positive, 1, 3601, True),
            ("partial_stale", "full", positive, 1, 121, False),
            ("fresh_negative", "full", [], 0, 0, False),
            ("expired_negative", "full", [], 0, 61, True),
            ("quick", "quick", positive, 1, 0, True),
            ("invalid_json", "full", "{", 1, 0, True),
            ("not_list", "full", {}, 1, 0, True),
            ("signed_expired", "full", expired_signed, 1, 0, True),
            (
                "signed_valid",
                "full",
                [{**positive[0], "expires_at": now + 60}],
                1,
                0,
                False,
            ),
            ("mixed_signed", "full", expired_signed + positive, 2, 0, False),
            (
                "unsafe",
                "full",
                [{**positive[0], "url": "https://player.example/watch.html"}],
                1,
                0,
                True,
            ),
            (
                "unavailable",
                "full",
                [{**positive[0], "available": False, "status": "unavailable"}],
                1,
                0,
                True,
            ),
            ("client_candidate", "full", client_candidate, 1, 0, False),
            ("legacy_payload", "full", legacy, 1, 0, True),
            ("unknown_scope", "legacy", positive, 1, 0, False),
        ]
        with (
            patch.multiple(
                "server.playback",
                PLAYBACK_CACHE_HOURS=1 / 6,
                PLAYBACK_PARTIAL_CACHE_MINUTES=2,
                PLAYBACK_NEGATIVE_CACHE_MINUTES=1,
                PLAYBACK_STALE_HOURS=1,
                PLAYBACK_STABLE_LINE_COUNT=4,
            ),
            patch("server.playback.time.time", return_value=now),
        ):
            for name, scope, items, count, age, replaces in cases:
                with self.subTest(case=name):
                    key = f"bangumi:policy-{name}"
                    encoded = items if isinstance(items, str) else json.dumps(items)
                    async with self.sessions() as session:
                        await SqlPlaybackRepository(session).upsert_cache(
                            subject_id=key,
                            episode=1,
                            title="seed",
                            lines_json=encoded,
                            line_count=count,
                            verified_at=now - age,
                            scan_scope=scope,
                        )
                    await self.store(self.peer_sessions, "quick", key=key)
                    row = await self.cached(key)
                    self.assertEqual(row.scan_scope, "quick" if replaces else scope)
                    self.assertEqual(row.title, "quick" if replaces else "seed")
                    self.assertEqual(
                        row.lines_json,
                        json.dumps(_lines("quick"), ensure_ascii=False)
                        if replaces
                        else encoded,
                    )
                    self.assertEqual(row.verified_at, now if replaces else now - age)

    async def test_same_timestamp_changed_routes_are_requalified(self):
        now = time.time()
        async with self.peer_sessions() as session:
            await SqlPlaybackRepository(session).upsert_cache(
                subject_id="bangumi:7001",
                episode=1,
                title="full",
                lines_json=json.dumps(
                    [{**_lines("expired")[0], "expires_at": now - 1}]
                ),
                line_count=1,
                verified_at=now,
            )
        observed, release = asyncio.Event(), asyncio.Event()
        async with self.sessions() as session:
            session.info["cache_read_barrier"] = (observed, release)
            quick = asyncio.create_task(
                self.service._store_cache(
                    session,
                    "bangumi:7001",
                    1,
                    "quick",
                    _lines("quick"),
                    scan_scope="quick",
                )
            )
            try:
                await asyncio.wait_for(observed.wait(), timeout=3)
                async with self.peer_sessions() as peer:
                    await SqlPlaybackRepository(peer).upsert_cache(
                        subject_id="bangumi:7001",
                        episode=1,
                        title="full",
                        lines_json=json.dumps(_lines("restored")),
                        line_count=1,
                        verified_at=now,
                    )
                release.set()
                await asyncio.wait_for(quick, timeout=3)
            finally:
                release.set()
                if not quick.done():
                    quick.cancel()
                await asyncio.gather(quick, return_exceptions=True)
        row = await self.cached()
        self.assertEqual(row.scan_scope, "full")
        self.assertEqual(json.loads(row.lines_json), _lines("restored"))
        self.assertEqual(row.verified_at, now)

    async def test_compat_default_writer_remains_unconditional_and_preserves_headers(
        self,
    ):
        for previous_scope in ("full", "quick"):
            with self.subTest(previous_scope=previous_scope):
                await self.store(self.sessions, previous_scope)
                legacy = [
                    {
                        "url": "https://cdn.example/compat.m3u8",
                        "title": "Compat",
                        "format": "hls",
                        "quality": "HD",
                        "source": "maccms:fixture",
                        "headers": {"Referer": "https://player.example/"},
                    }
                ]
                async with self.peer_sessions() as session:
                    row = await upsert_playback_cache(
                        session,
                        subject_id="bangumi:7001",
                        episode=1,
                        title="Compat",
                        lines_json=json.dumps(legacy),
                        line_count=1,
                        verified_at=1,
                    )
                    self.assertEqual(row.scan_scope, "full")
                cached = await self.cached()
                self.assertEqual(cached.title, "Compat")
                self.assertEqual(json.loads(cached.lines_json), legacy)
                self.assertEqual(cached.verified_at, 1)

    async def test_cancellation_releases_session_and_does_not_block_other_writers(self):
        observed, release = asyncio.Event(), asyncio.Event()
        async with self.sessions() as session:
            session.info["cache_read_barrier"] = (observed, release)
            quick = asyncio.create_task(
                self.service._store_cache(
                    session,
                    "bangumi:7001",
                    1,
                    "cancelled",
                    _lines("quick"),
                    scan_scope="quick",
                )
            )
            try:
                await asyncio.wait_for(observed.wait(), timeout=3)
                quick.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await quick
            finally:
                release.set()
                if not quick.done():
                    quick.cancel()
                await asyncio.gather(quick, return_exceptions=True)
        await asyncio.wait_for(self.store(self.peer_sessions, "full"), timeout=3)
        await asyncio.wait_for(
            self.store(self.sessions, "quick", key="bangumi:7002"), timeout=3
        )
        self.assertEqual((await self.cached()).scan_scope, "full")
        self.assertEqual((await self.cached("bangumi:7002")).scan_scope, "quick")

    async def test_repeated_contention_is_bounded_and_retains_last_writer(self):
        await self.store(self.peer_sessions, "quick")
        barriers = [(asyncio.Event(), asyncio.Event()) for _ in range(3)]
        async with self.sessions() as session:
            session.info["cache_read_barriers"] = list(barriers)
            quick = asyncio.create_task(
                self.service._store_cache(
                    session,
                    "bangumi:7001",
                    1,
                    "contended",
                    _lines("contended"),
                    scan_scope="quick",
                )
            )
            try:
                for index, (observed, release) in enumerate(barriers):
                    await asyncio.wait_for(observed.wait(), timeout=3)
                    await self.store(
                        self.peer_sessions, "quick", lines=_lines(f"peer-{index}")
                    )
                    release.set()
                await asyncio.wait_for(quick, timeout=3)
            finally:
                for _, release in barriers:
                    release.set()
                if not quick.done():
                    quick.cancel()
                await asyncio.gather(quick, return_exceptions=True)
        self.assertEqual(json.loads((await self.cached()).lines_json), _lines("peer-2"))

    async def test_full_and_compat_writes_restore_scope_after_interleaved_quick(self):
        for compat in (False, True):
            with self.subTest(compat=compat):
                key = f"bangumi:late-full-{compat}"
                async with self.peer_sessions() as session:
                    await SqlPlaybackRepository(session).upsert_cache(
                        subject_id=key,
                        episode=1,
                        title="full",
                        lines_json=json.dumps(_lines("expired", 2)),
                        line_count=2,
                        verified_at=1,
                        scan_scope="full",
                    )
                observed, release = asyncio.Event(), asyncio.Event()
                async with self.sessions() as session:
                    session.info["cache_read_barrier"] = (observed, release)
                    write = (
                        upsert_playback_cache(
                            session,
                            subject_id=key,
                            episode=1,
                            title="full",
                            lines_json=json.dumps(_lines("restored", 2)),
                            line_count=2,
                            verified_at=time.time(),
                        )
                        if compat
                        else self.service._store_cache(
                            session,
                            key,
                            1,
                            "full",
                            _lines("restored", 2),
                        )
                    )
                    full = asyncio.create_task(write)
                    try:
                        await asyncio.wait_for(observed.wait(), timeout=3)
                        await self.store(self.peer_sessions, "quick", key=key)
                        self.assertEqual((await self.cached(key)).scan_scope, "quick")
                        release.set()
                        await asyncio.wait_for(full, timeout=3)
                    finally:
                        release.set()
                        if not full.done():
                            full.cancel()
                        await asyncio.gather(full, return_exceptions=True)
                row = await self.cached(key)
                self.assertEqual(row.scan_scope, "full")
                self.assertEqual(row.title, "full")
                self.assertEqual(row.line_count, 2)
                self.assertEqual(json.loads(row.lines_json), _lines("restored", 2))

    async def test_cancellation_after_sql_update_rolls_back_and_releases_write_lock(
        self,
    ):
        await self.store(self.peer_sessions, "quick", lines=_lines("before"))
        observed, release = asyncio.Event(), asyncio.Event()

        async def write_then_cancel():
            async with self.sessions() as session:
                session.info["cache_update_barrier"] = (observed, release)
                await self.service._store_cache(
                    session,
                    "bangumi:7001",
                    1,
                    "cancelled",
                    _lines("cancelled"),
                    scan_scope="quick",
                )

        quick = asyncio.create_task(write_then_cancel())
        try:
            await asyncio.wait_for(observed.wait(), timeout=3)
            quick.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await quick
        finally:
            release.set()
            if not quick.done():
                quick.cancel()
            await asyncio.gather(quick, return_exceptions=True)
        self.assertEqual(json.loads((await self.cached()).lines_json), _lines("before"))
        await asyncio.wait_for(self.store(self.peer_sessions, "full"), timeout=3)
        self.assertEqual((await self.cached()).scan_scope, "full")

    async def test_concurrent_full_negative_and_expired_winners_are_requalified(self):
        now = time.time()
        cases = (
            ("fresh-negative", [], 0, now, "full"),
            ("expired-negative", [], 0, 1, "quick"),
            (
                "expired-signed",
                [{**_lines("expired")[0], "expires_at": now - 1}],
                1,
                now,
                "quick",
            ),
        )
        for name, items, count, verified_at, expected_scope in cases:
            with self.subTest(case=name):
                key = f"bangumi:concurrent-{name}"
                observed, release = asyncio.Event(), asyncio.Event()
                async with self.sessions() as session:
                    session.info["cache_read_barrier"] = (observed, release)
                    quick = asyncio.create_task(
                        self.service._store_cache(
                            session,
                            key,
                            1,
                            "quick",
                            _lines("quick"),
                            scan_scope="quick",
                        )
                    )
                    try:
                        await asyncio.wait_for(observed.wait(), timeout=3)
                        async with self.peer_sessions() as peer:
                            await upsert_playback_cache(
                                peer,
                                subject_id=key,
                                episode=1,
                                title="winner",
                                lines_json=json.dumps(items),
                                line_count=count,
                                verified_at=verified_at,
                            )
                        release.set()
                        await asyncio.wait_for(quick, timeout=3)
                    finally:
                        release.set()
                        if not quick.done():
                            quick.cancel()
                        await asyncio.gather(quick, return_exceptions=True)
                row = await self.cached(key)
                self.assertEqual(row.scan_scope, expected_scope)
                self.assertEqual(
                    json.loads(row.lines_json),
                    items if expected_scope == "full" else _lines("quick"),
                )
        self.assertEqual(self.integrity_conflicts, len(cases))
