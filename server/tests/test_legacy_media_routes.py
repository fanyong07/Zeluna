import unittest

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.app import create_app
from server.database import Bangumi, BangumiEpisode, Base
from server.dependencies import get_session
from server.routers import legacy_media_router


class LegacyMediaRouteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.sessions() as session:
            bangumi = Bangumi(title="测试番剧")
            session.add(bangumi)
            await session.flush()
            session.add(
                BangumiEpisode(
                    bangumi_id=bangumi.id,
                    number=1,
                    title="第一集",
                    vod_url='[{"url":"https://media.example.test/one.m3u8"}]',
                )
            )
            await session.commit()
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

    async def test_vod_path_keeps_the_previously_reachable_database_contract(self):
        response = await self.client.get(f"/vod/{self.bangumi_id}/1")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["title"], "第一集")
        self.assertEqual(
            response.json()["vod"],
            [{"url": "https://media.example.test/one.m3u8"}],
        )

    def test_vod_get_route_is_registered_exactly_once(self):
        routes = [
            route
            for route in legacy_media_router.routes
            if route.path == "/vod/{id}/{episode}" and "GET" in route.methods
        ]

        self.assertEqual(len(routes), 1)


if __name__ == "__main__":
    unittest.main()
