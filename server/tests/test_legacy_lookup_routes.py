import unittest

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.app import create_app
from server.database import Bangumi, Base, Character, Person
from server.dependencies import get_session


class LegacyLookupRouteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.sessions() as session:
            bangumi = Bangumi(title="可搜索番剧")
            session.add(bangumi)
            await session.flush()
            character = Character(bangumi_id=bangumi.id, name="角色")
            person = Person(bangumi_id=bangumi.id, name="人物")
            session.add_all([character, person])
            await session.commit()
            self.character_id = character.id
            self.person_id = person.id

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

    async def test_character_detail_and_missing_person_keep_json_contracts(self):
        character = await self.client.get(f"/bangumi/character/{self.character_id}")
        missing = await self.client.get("/bangumi/person/999999")

        self.assertEqual(character.status_code, 200)
        self.assertEqual(character.json()["name"], "角色")
        self.assertEqual(missing.status_code, 404)

    async def test_bangumi_search_keeps_binary_contract(self):
        response = await self.client.get(
            "/bangumi/search",
            params={"keyword": "可搜索"},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["content-type"], "application/octet-stream")
        self.assertTrue(response.content)


if __name__ == "__main__":
    unittest.main()
