from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from server.app import create_app


def test_v2_resolver_empty_request_does_not_call_external_resolver():
    parse = AsyncMock()
    search = AsyncMock()

    with (
        patch(
            "server.routers.compat_v2.m3u8_resolver.resolve_via_parse_services",
            new=parse,
        ),
        patch(
            "server.routers.compat_v2.m3u8_resolver.search_and_resolve",
            new=search,
        ),
    ):
        response = TestClient(create_app()).get("/api/v2/resolve")

    assert response.status_code == 200
    assert response.json() == []
    parse.assert_not_awaited()
    search.assert_not_awaited()


def test_v2_home_uses_shared_aggregator_singleton():
    home = AsyncMock(return_value={"anime": []})

    with patch("server.main.aggregator.get_home_feed", new=home):
        response = TestClient(create_app()).get("/api/v2/home")

    assert response.status_code == 200
    assert response.json() == {"anime": []}
    home.assert_awaited_once_with()
