import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.app import create_app
from server.database import Bangumi, BangumiCollection, Base, User
from server.dependencies import get_session


class LegacyLibraryRouteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.sessions() as session:
            user = User(
                email="library@example.test", name="library", password_hash="unused"
            )
            bangumi = Bangumi(title="测试番剧")
            session.add_all([user, bangumi])
            await session.commit()
            self.user_id = user.id
            self.bangumi_id = bangumi.id

        self.app = create_app()

        async def override_session():
            async with self.sessions() as session:
                yield session

        self.app.dependency_overrides[get_session] = override_session
        self.client = AsyncClient(
            transport=ASGITransport(app=self.app),
            base_url="http://test",
        )

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.engine.dispose()

    async def test_anonymous_danmaku_read_is_allowed_but_write_is_rejected(self):
        read = await self.client.get("/danmaku")
        write = await self.client.post("/danmaku", json={"text": "hello"})

        self.assertEqual(read.status_code, 200)
        self.assertEqual(read.headers["content-type"], "application/octet-stream")
        self.assertEqual(write.status_code, 401)

    async def test_collection_update_is_idempotent_for_one_user_and_subject(self):
        user = SimpleNamespace(id=self.user_id)
        with patch(
            "server.routers.legacy_library.get_current_user",
            new=AsyncMock(return_value=user),
        ):
            first = await self.client.get(f"/bangumi/{self.bangumi_id}/collect/wish")
            second = await self.client.get(f"/bangumi/{self.bangumi_id}/collect/watch")

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        async with self.sessions() as session:
            count = await session.scalar(select(func.count(BangumiCollection.id)))
            collection = await session.scalar(select(BangumiCollection))
        self.assertEqual(count, 1)
        self.assertEqual(collection.type, "watch")


if __name__ == "__main__":
    unittest.main()
