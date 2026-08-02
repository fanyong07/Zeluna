import unittest

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.app import create_app
from server.database import Base, Thread
from server.dependencies import get_session


class LegacyCommunityRouteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.sessions() as session:
            thread = Thread(title="测试帖子", body="内容", tags='["artwork"]')
            session.add(thread)
            await session.commit()
            self.thread_id = thread.id

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

    async def test_public_thread_feed_keeps_binary_contract(self):
        response = await self.client.get("/latest")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["content-type"], "application/octet-stream")
        self.assertTrue(response.content)

    async def test_unauthenticated_thread_status_is_false_and_write_is_rejected(self):
        status = await self.client.get(f"/r/{self.thread_id}/collect/status")
        write = await self.client.get(f"/r/{self.thread_id}/collect")

        self.assertEqual(status.status_code, 200)
        self.assertEqual(status.json(), {"collected": False})
        self.assertEqual(write.status_code, 401)


if __name__ == "__main__":
    unittest.main()
