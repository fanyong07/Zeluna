import unittest
from unittest.mock import patch

from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server import dependencies
from server.app import create_app
from server.database import Base
from server.dependencies import get_session
from server.managed_lines.service import ManagedLineService
from server.managed_lines.validation import ManagedLineVerification


def _payload(**changes):
    value = {
        "stable_id": "bangumi:400602",
        "episode": 1,
        "label": "主线路",
        "canonical_url": "https://93.184.216.34/video.m3u8",
        "format_hint": "hls",
        "quality": "1080p",
        "headers": {"Referer": "https://player.example/"},
        "priority": 800,
        "provenance_kind": "licensed",
        "rights_reference": "INTERNAL-2026-001",
    }
    value.update(changes)
    return value


class ManagedLineAdminTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with self.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

        async def override_session():
            async with self.sessions() as session:
                yield session

        self.app = create_app()
        self.app.dependency_overrides[get_session] = override_session
        self.admin_patch = patch.object(
            dependencies,
            "ADMIN_TOKEN",
            "test-admin-token",
        )
        self.admin_patch.start()
        self.headers = {"X-Zeluna-Admin": "test-admin-token"}
        self.client = AsyncClient(
            transport=ASGITransport(app=self.app),
            base_url="http://test",
        )

    async def asyncTearDown(self):
        self.admin_patch.stop()
        self.app.dependency_overrides.clear()
        await self.client.aclose()
        await self.engine.dispose()

    async def test_admin_create_starts_as_disabled_pending_draft(self):
        rejected = await self.client.post("/admin/managed-lines", json=_payload())
        created = await self.client.post(
            "/admin/managed-lines",
            json=_payload(),
            headers=self.headers,
        )
        body = created.json()
        loaded = await self.client.get(
            f"/admin/managed-lines/{body.get('id', 'missing')}",
            headers=self.headers,
        )

        self.assertEqual(rejected.status_code, 404)
        self.assertEqual(created.status_code, 201)
        self.assertTrue(body["id"].startswith("mpl_"))
        self.assertEqual(body["stable_id"], "bangumi:400602")
        self.assertEqual(body["status"], "draft")
        self.assertEqual(body["review_status"], "pending")
        self.assertFalse(body["enabled"])
        self.assertEqual(loaded.status_code, 200)
        self.assertEqual(loaded.json(), body)

    async def test_movie_managed_line_accepts_only_episode_one(self):
        response = await self.client.post(
            "/admin/managed-lines",
            json=_payload(stable_id="tmdb:movie:535167", episode=2),
            headers=self.headers,
        )

        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["detail"]["code"], "movie_episode")

    async def test_admin_url_update_keeps_line_id_and_resets_publication_state(self):
        created = await self.client.post(
            "/admin/managed-lines",
            json=_payload(),
            headers=self.headers,
        )
        line_id = created.json()["id"]

        changed = await self.client.patch(
            f"/admin/managed-lines/{line_id}",
            json={
                "canonical_url": "https://93.184.216.34/replaced.m3u8",
                "label": "替换线路",
            },
            headers=self.headers,
        )

        self.assertEqual(changed.status_code, 200)
        body = changed.json()
        self.assertEqual(body["id"], line_id)
        self.assertEqual(
            body["canonical_url"],
            "https://93.184.216.34/replaced.m3u8",
        )
        self.assertEqual(body["status"], "draft")
        self.assertEqual(body["review_status"], "pending")
        self.assertFalse(body["enabled"])

    async def test_verify_approve_enable_disable_and_revoke_state_machine(self):
        class SuccessfulVerifier:
            async def verify(self, _url, *, format_hint, headers):
                self.assertEqual(format_hint, "hls")
                self.assertEqual(
                    headers,
                    {"Referer": "https://player.example/"},
                )
                return ManagedLineVerification(
                    status="server_verified",
                    error_category="",
                    latency_ms=42,
                    startup_profile="hls",
                )

        verifier = SuccessfulVerifier()
        verifier.assertEqual = self.assertEqual
        service = ManagedLineService(verifier=verifier)
        with patch(
            "server.routers.admin_managed_lines.managed_line_service",
            service,
        ):
            created = await self.client.post(
                "/admin/managed-lines",
                json=_payload(),
                headers=self.headers,
            )
            line_id = created.json()["id"]
            verified = await self.client.post(
                f"/admin/managed-lines/{line_id}/verify",
                headers=self.headers,
            )
            premature = await self.client.post(
                f"/admin/managed-lines/{line_id}/enable",
                headers=self.headers,
            )
            approved = await self.client.post(
                f"/admin/managed-lines/{line_id}/approve",
                headers=self.headers,
            )
            enabled = await self.client.post(
                f"/admin/managed-lines/{line_id}/enable",
                headers=self.headers,
            )
            disabled = await self.client.post(
                f"/admin/managed-lines/{line_id}/disable",
                headers=self.headers,
            )
            revoked = await self.client.post(
                f"/admin/managed-lines/{line_id}/revoke",
                headers=self.headers,
            )
            revoked_again = await self.client.post(
                f"/admin/managed-lines/{line_id}/revoke",
                headers=self.headers,
            )
            reenabled = await self.client.post(
                f"/admin/managed-lines/{line_id}/enable",
                headers=self.headers,
            )
            replaced_after_revoke = await self.client.patch(
                f"/admin/managed-lines/{line_id}",
                json={"canonical_url": "https://93.184.216.34/new.m3u8"},
                headers=self.headers,
            )

        self.assertEqual(verified.status_code, 200)
        self.assertEqual(verified.json()["last_verified_status"], "server_verified")
        self.assertEqual(verified.json()["last_latency_ms"], 42)
        self.assertEqual(premature.status_code, 409)
        self.assertEqual(approved.json()["review_status"], "approved")
        self.assertEqual(approved.json()["status"], "active")
        self.assertTrue(enabled.json()["enabled"])
        self.assertFalse(disabled.json()["enabled"])
        self.assertEqual(revoked.json()["status"], "revoked")
        self.assertFalse(revoked.json()["enabled"])
        self.assertEqual(
            revoked_again.json()["revoked_at"],
            revoked.json()["revoked_at"],
        )
        self.assertEqual(reenabled.status_code, 409)
        self.assertEqual(replaced_after_revoke.status_code, 409)

    async def test_optional_approval_mode_auto_approves_only_after_verification(self):
        class SuccessfulVerifier:
            async def verify(self, _url, *, format_hint, headers):
                return ManagedLineVerification(
                    status="server_verified",
                    error_category="",
                    latency_ms=20,
                    startup_profile="hls",
                )

        service = ManagedLineService(
            verifier=SuccessfulVerifier(),
            require_approval=False,
        )
        with patch(
            "server.routers.admin_managed_lines.managed_line_service",
            service,
        ):
            created = await self.client.post(
                "/admin/managed-lines",
                json=_payload(),
                headers=self.headers,
            )
            line_id = created.json()["id"]
            verified = await self.client.post(
                f"/admin/managed-lines/{line_id}/verify",
                headers=self.headers,
            )

        self.assertEqual(created.json()["review_status"], "pending")
        self.assertEqual(verified.json()["review_status"], "approved")
        self.assertEqual(verified.json()["status"], "active")
        self.assertFalse(verified.json()["enabled"])

    async def test_json_import_creates_only_drafts_and_list_filters_episode(self):
        imported = await self.client.post(
            "/admin/managed-lines/import",
            json={
                "items": [
                    {
                        "stable_id": "bangumi:400602",
                        "episode": 1,
                        "url": "https://93.184.216.34/episode-1.m3u8",
                        "label": "主线路",
                        "format": "hls",
                        "priority": 900,
                        "provenance": "licensed",
                        "rights_reference": "INTERNAL-2026-001",
                    },
                    {
                        "stable_id": "bangumi:400602",
                        "episode": 2,
                        "url": "https://93.184.216.34/episode-2.mpd",
                        "label": "第二集",
                        "format": "dash",
                        "priority": 700,
                        "provenance": "licensed",
                        "rights_reference": "INTERNAL-2026-002",
                    },
                ]
            },
            headers=self.headers,
        )
        listed = await self.client.get(
            "/admin/managed-lines",
            params={"stable_id": "bangumi:400602", "episode": 2},
            headers=self.headers,
        )

        self.assertEqual(imported.status_code, 201)
        self.assertEqual(len(imported.json()), 2)
        self.assertTrue(
            all(
                item["status"] == "draft"
                and item["review_status"] == "pending"
                and item["enabled"] is False
                for item in imported.json()
            )
        )
        self.assertEqual(listed.status_code, 200)
        self.assertEqual([item["label"] for item in listed.json()], ["第二集"])


if __name__ == "__main__":
    unittest.main()
