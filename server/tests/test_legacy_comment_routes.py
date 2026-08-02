import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.app import create_app
from server.database import Base, Comment, User
from server.dependencies import get_session


class LegacyCommentRouteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)
        async with self.sessions() as session:
            user = User(
                email="reader@example.test", name="reader", password_hash="unused"
            )
            session.add(user)
            await session.flush()
            comment = Comment(
                type="thread",
                target_id="1",
                user_id=user.id,
                contents='["hello"]',
                like_count=0,
            )
            session.add(comment)
            await session.commit()
            self.user_id = user.id
            self.comment_id = comment.id

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

    async def test_anonymous_comment_read_is_allowed_but_write_is_rejected(self):
        read = await self.client.get("/comment", params={"id": "1"})
        write = await self.client.post(
            "/comment",
            json={"id": "1", "contents": ["new"]},
        )

        self.assertEqual(read.status_code, 200)
        self.assertEqual(read.json()[0]["contents"], ["hello"])
        self.assertFalse(read.json()[0]["user_liked"])
        self.assertEqual(write.status_code, 401)

    async def test_cancel_like_never_decrements_below_zero(self):
        with patch(
            "server.routers.legacy_comments.get_current_user",
            new=AsyncMock(return_value=SimpleNamespace(id=self.user_id)),
        ):
            response = await self.client.delete(
                "/comment/like",
                params={"id": str(self.comment_id)},
            )

        self.assertEqual(response.status_code, 200)
        async with self.sessions() as session:
            comment = await session.scalar(
                select(Comment).where(Comment.id == self.comment_id)
            )
        self.assertEqual(comment.like_count, 0)


if __name__ == "__main__":
    unittest.main()
