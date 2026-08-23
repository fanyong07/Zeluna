import unittest

from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.database import Base
from server.managed_lines.repository import (
    ManagedLineRecord,
    SqlManagedLineRepository,
)


def _record(*, url: str) -> ManagedLineRecord:
    return ManagedLineRecord(
        id="mpl_stable_test_id",
        stable_id="bangumi:400602",
        episode=1,
        provider_key="managed.main",
        label="主线路",
        quality="1080p",
        format_hint="hls",
        canonical_url=url,
        url_kind="static_direct",
        expires_at=0.0,
        headers={"Referer": "https://media.example/"},
        priority=800,
        status="draft",
        review_status="pending",
        enabled=False,
        provenance_kind="licensed",
        rights_reference="INTERNAL-2026-001",
        operator_note="",
        last_verified_status="unverified",
        last_verified_at=0.0,
        last_error_category="",
        last_latency_ms=0,
        created_at=100.0,
        updated_at=100.0,
        published_at=0.0,
        revoked_at=0.0,
    )


class ManagedLineRepositoryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def asyncTearDown(self):
        await self.engine.dispose()

    async def test_url_update_preserves_stable_line_id(self):
        original = _record(url="https://media.example/original.m3u8")
        changed = _record(url="https://media.example/refreshed.m3u8")

        async with self.sessions() as session:
            repository = SqlManagedLineRepository(session)
            await repository.add(original)
            await repository.save(changed)
            loaded = await repository.get(original.id)

        self.assertIsNotNone(loaded)
        self.assertEqual(loaded.id, "mpl_stable_test_id")
        self.assertEqual(
            loaded.canonical_url,
            "https://media.example/refreshed.m3u8",
        )
        self.assertEqual(loaded.headers, {"Referer": "https://media.example/"})


if __name__ == "__main__":
    unittest.main()
