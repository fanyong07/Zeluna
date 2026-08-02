from unittest.mock import patch

from fastapi.testclient import TestClient

from server import dependencies
from server.app import create_app


def test_legacy_config_route_is_disabled_by_default():
    with patch.object(dependencies, "LEGACY_CONFIG_API_ENABLED", False):
        response = TestClient(create_app()).get("/check/api")

    assert response.status_code == 404
    assert response.json() == {"detail": "Not found"}


def test_enabled_legacy_config_has_no_fixed_third_party_routes():
    with (
        patch.object(dependencies, "LEGACY_CONFIG_API_ENABLED", True),
        patch(
            "server.routers.legacy_config.PUBLIC_BASE_URL",
            "https://api.example.test",
        ),
    ):
        response = TestClient(create_app()).get("/check/api")

    assert response.status_code == 200
    assert response.json() == {
        "baseUrl": "https://api.example.test",
        "bilibiliApiUrl": "",
        "qqVideoApiUrl": "",
        "dandanApiUrl": "",
        "updateUrl": "",
        "githubProxyUrl": "",
        "apis": ["https://api.example.test"],
        "ghproxy": [],
    }
