import asyncio
from unittest.mock import patch

from fastapi.testclient import TestClient

from server import account_api, dependencies, main
from server.app import create_app
from server.routers import admin_router, catalog_router, health_router, playback_router


def test_shared_session_dependency_is_used_by_all_account_routes():
    assert main.get_session is dependencies.get_session
    assert account_api.get_session is dependencies.get_session


def test_application_factory_owns_metadata_cors_and_account_router():
    app = create_app()

    assert app.title == "Zeluna API"
    assert app.version == "3.0.0"
    assert TestClient(app).post("/api/v1/auth/login", json={}).status_code == 422
    assert any(
        middleware.cls.__name__ == "CORSMiddleware"
        for middleware in app.user_middleware
    )

    endpoint_modules = {
        route.path: route.endpoint.__module__
        for router in (
            health_router,
            catalog_router,
            playback_router,
            admin_router,
        )
        for route in router.routes
    }
    assert endpoint_modules["/api/v3/status"] == "server.routers.health"
    assert endpoint_modules["/api/v3/catalog/search"] == "server.routers.catalog"
    assert (
        endpoint_modules["/api/v3/quick-playback/{stable_id:path}"]
        == "server.routers.playback"
    )
    assert endpoint_modules["/admin/v3/playback/refresh"] == "server.routers.admin"
    openapi_paths = app.openapi()["paths"].keys()
    assert {path.replace(":path}", "}") for path in endpoint_modules} <= openapi_paths


def test_modern_admin_route_is_inaccessible_without_configuration():
    with patch.object(dependencies, "ADMIN_TOKEN", ""):
        response = TestClient(create_app()).post("/admin/v3/playback/refresh")

    assert response.status_code == 404
    assert response.json() == {"detail": "Not found"}


def test_legacy_account_route_is_inaccessible_when_disabled():
    with patch.object(dependencies, "LEGACY_ACCOUNT_API_ENABLED", False):
        response = TestClient(main.app).post(
            "/login",
            content=b"",
            headers={"content-type": "application/octet-stream"},
        )

    assert response.status_code == 404
    assert response.json() == {"detail": "Not found"}


def test_lifespan_starts_and_closes_resources_in_order():
    calls: list[str] = []

    def recorder(name: str):
        async def record():
            calls.append(name)

        return record

    with (
        patch.object(main, "init_db", side_effect=recorder("init_db")),
        patch.object(main.scheduler, "start", side_effect=recorder("scheduler.start")),
        patch.object(main, "_seed_data", side_effect=recorder("seed")),
        patch.object(main.scheduler, "stop", side_effect=recorder("scheduler.stop")),
        patch.object(
            main.playback_service, "aclose", side_effect=recorder("playback.close")
        ),
        patch.object(
            main.aggregator, "aclose", side_effect=recorder("aggregator.close")
        ),
        patch.object(
            main.catalog_service, "aclose", side_effect=recorder("catalog.close")
        ),
        patch.object(main.m3u8_resolver, "aclose", side_effect=recorder("m3u8.close")),
    ):

        async def exercise_lifespan():
            async with main.lifespan(main.app):
                calls.append("running")

        asyncio.run(exercise_lifespan())

    assert calls == [
        "init_db",
        "scheduler.start",
        "seed",
        "running",
        "scheduler.stop",
        "playback.close",
        "aggregator.close",
        "catalog.close",
        "m3u8.close",
    ]
