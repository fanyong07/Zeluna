import asyncio
from collections import Counter
from types import SimpleNamespace
from unittest.mock import patch

from fastapi.testclient import TestClient

from server import account_api, dependencies, main
from server.app import create_app
from server.routers import legacy_account as legacy_account_module
from server.routers import (
    admin_router,
    catalog_router,
    compat_v2_router,
    health_router,
    legacy_account_router,
    legacy_config_router,
    legacy_community_router,
    legacy_comments_router,
    legacy_media_router,
    legacy_library_router,
    legacy_lookup_router,
    playback_router,
)


def test_shared_session_dependency_is_used_by_all_account_routes():
    assert account_api.get_session is dependencies.get_session
    assert legacy_account_module.get_session is dependencies.get_session


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
            compat_v2_router,
            playback_router,
            admin_router,
            legacy_account_router,
            legacy_config_router,
            legacy_community_router,
            legacy_comments_router,
            legacy_media_router,
            legacy_library_router,
            legacy_lookup_router,
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
    assert endpoint_modules["/admin/scan"] == "server.routers.admin"
    assert endpoint_modules["/login"] == "server.routers.legacy_account"
    assert endpoint_modules["/check/api"] == "server.routers.legacy_config"
    assert (
        endpoint_modules["/api/v2/vod/{subject_id:path}"] == "server.routers.compat_v2"
    )
    assert endpoint_modules["/vod/{id}/{episode}"] == "server.routers.legacy_media"
    assert endpoint_modules["/latest"] == "server.routers.legacy_community"
    assert endpoint_modules["/comment"] == "server.routers.legacy_comments"
    assert endpoint_modules["/danmaku"] == "server.routers.legacy_library"
    assert endpoint_modules["/bangumi/search"] == "server.routers.legacy_lookup"
    openapi_paths = app.openapi()["paths"].keys()
    assert {path.replace(":path}", "}") for path in endpoint_modules} <= openapi_paths


def test_status_exposes_only_actually_enabled_playback_provider_ids():
    provider_metadata = (
        SimpleNamespace(provider_id="aggregate.maccms", enabled=True),
        SimpleNamespace(provider_id="crawler.nivod", enabled=False),
    )
    fake_aggregator = SimpleNamespace(
        provider_metadata=provider_metadata,
    )
    with patch("server.routers.health.aggregator", fake_aggregator):
        response = TestClient(create_app()).get("/api/v3/status")

    assert response.status_code == 200
    assert response.json()["playback_providers"] == {
        "enabled_ids": ["aggregate.maccms"],
    }
    public_payload = response.text
    for private_field in (
        "canonical_url",
        "headers_json",
        "rights_reference",
        "operator_note",
    ):
        assert private_field not in public_payload


def test_route_table_has_no_duplicate_method_path_pairs():
    flattened = []
    for route in main.app.routes:
        included = getattr(route, "original_router", None)
        flattened.extend(included.routes if included is not None else [route])

    keys = [
        (route.path, tuple(sorted(route.methods)))
        for route in flattened
        if hasattr(route, "path") and getattr(route, "methods", None)
    ]
    duplicates = [key for key, count in Counter(keys).items() if count > 1]

    assert duplicates == []


def test_main_module_owns_no_route_implementation():
    direct_business_paths = [
        route.path
        for route in main.app.routes
        if hasattr(route, "path")
        and route.path
        not in {"/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"}
    ]

    assert direct_business_paths == []


def test_modern_admin_route_is_inaccessible_without_configuration():
    with patch.object(dependencies, "ADMIN_TOKEN", ""):
        response = TestClient(create_app()).post("/admin/v3/playback/refresh")

    assert response.status_code == 404
    assert response.json() == {"detail": "Not found"}


def test_all_legacy_account_routes_are_inaccessible_when_disabled():
    with patch.object(dependencies, "LEGACY_ACCOUNT_API_ENABLED", False):
        client = TestClient(main.app)
        responses = [
            client.request(method, path, content=b"")
            for method, path in (
                ("POST", "/login"),
                ("POST", "/code"),
                ("POST", "/register"),
                ("POST", "/user/check"),
                ("POST", "/change_password"),
                ("GET", "/init"),
            )
        ]

    assert {response.status_code for response in responses} == {404}
    assert {response.json()["detail"] for response in responses} == {"Not found"}


def test_lifespan_starts_and_closes_resources_in_order():
    calls: list[str] = []

    def recorder(name: str):
        async def record():
            calls.append(name)

        return record

    with (
        patch.object(main, "init_db", side_effect=recorder("init_db")),
        patch.object(main.scheduler, "start", side_effect=recorder("scheduler.start")),
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
        "running",
        "scheduler.stop",
        "playback.close",
        "aggregator.close",
        "catalog.close",
        "m3u8.close",
    ]


def test_application_startup_has_no_demo_seed_or_account_deletion_hook():
    assert not hasattr(main, "_seed_data")
