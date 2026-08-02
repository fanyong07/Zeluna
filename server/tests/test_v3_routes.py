from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from server import dependencies
from server.app import create_app
from server.dependencies import get_session


def _app_with_session(session: object):
    app = create_app()

    async def override_session():
        yield session

    app.dependency_overrides[get_session] = override_session
    return app


def test_catalog_search_normalizes_supported_content_types():
    session = object()
    search = AsyncMock(return_value=[{"stable_id": "bangumi:123"}])
    app = _app_with_session(session)

    with patch("server.routers.catalog.catalog_service.search", new=search):
        response = TestClient(app).get(
            "/api/v3/catalog/search",
            params={"query": "测试", "content_type": "anime,bad,movie", "limit": 12},
        )

    assert response.status_code == 200
    assert response.json() == [{"stable_id": "bangumi:123"}]
    search.assert_awaited_once_with(
        "测试",
        ["anime", "movie"],
        session,
        limit=12,
    )


def test_catalog_home_rejects_unknown_content_type_before_service_call():
    home = AsyncMock()
    app = _app_with_session(object())

    with patch("server.routers.catalog.catalog_service.home", new=home):
        response = TestClient(app).get("/api/v3/catalog/home/unknown")

    assert response.status_code == 400
    home.assert_not_awaited()


def test_modern_admin_route_accepts_only_configured_token():
    refresh = AsyncMock(return_value={"refreshed": 2})
    app = create_app()

    with (
        patch.object(dependencies, "ADMIN_TOKEN", "test-admin-token"),
        patch("server.routers.admin.playback_service.refresh_due", new=refresh),
    ):
        client = TestClient(app)
        rejected = client.post(
            "/admin/v3/playback/refresh",
            headers={"X-Zeluna-Admin": "wrong-token"},
        )
        response = client.post(
            "/admin/v3/playback/refresh",
            params={"limit": 2},
            headers={"X-Zeluna-Admin": "test-admin-token"},
        )

    assert rejected.status_code == 404
    assert response.status_code == 200
    assert response.json() == {"refreshed": 2}
    refresh.assert_awaited_once_with(limit=2)


def test_retained_admin_scan_uses_the_same_fail_closed_router():
    scan = AsyncMock()
    app = create_app()

    with (
        patch.object(dependencies, "ADMIN_TOKEN", "test-admin-token"),
        patch("server.routers.admin.scheduler.scan_new_content", new=scan),
    ):
        client = TestClient(app)
        rejected = client.post(
            "/admin/scan",
            headers={"X-Zeluna-Admin": "wrong-token"},
        )
        response = client.post(
            "/admin/scan",
            params={"content_types": "anime,movie"},
            headers={"X-Zeluna-Admin": "test-admin-token"},
        )

    assert rejected.status_code == 404
    assert response.status_code == 200
    assert response.json() == {
        "message": "Scan triggered",
        "types": ["anime", "movie"],
    }
    scan.assert_awaited_once_with(["anime", "movie"])


def test_legacy_account_router_runs_only_when_explicitly_enabled():
    session = object()
    app = _app_with_session(session)

    with patch.object(dependencies, "LEGACY_ACCOUNT_API_ENABLED", True):
        response = TestClient(app).post("/user/check", json={})

    assert response.status_code == 200
    assert response.json() == {"error": False, "message": "可用"}
