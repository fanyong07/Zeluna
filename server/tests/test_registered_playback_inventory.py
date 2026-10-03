"""Registered sources must remain visible without admitting new providers."""
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from server.app import create_app
from server.dependencies import get_session


@pytest.mark.parametrize("route,method", [("quick-playback", "quick_lines"), ("playback", "lines")])
@pytest.mark.parametrize("content_type", ["anime", "tv", "movie"])
def test_empty_work_results_still_show_every_registered_source(route, method, content_type):
    app = create_app()
    async def session():
        yield object()
    app.dependency_overrides[get_session] = session
    lookup = AsyncMock(return_value=[])
    with patch(f"server.routers.playback.playback_service.{method}", lookup):
        response = TestClient(app).get(f"/api/v3/{route}/bangumi:123", params={"content_type": content_type})
    assert response.status_code == 200
    items = response.json()
    assert len(items) == 118
    assert len({item["inventory_source_id"] for item in items}) == 118
    assert sum(item["diagnostic_status"] == "candidate_unadmitted" for item in items) == 80
    assert all(item["url"] == "" and item["available"] is False for item in items)
    assert all(item["queried"] is False for item in items)
    lookup.assert_awaited_once()
    assert lookup.await_args.kwargs["content_type"] == content_type


def test_real_routes_remain_intact_and_one_adapter_is_counted_once():
    from server.playback_inventory import (
        RegisteredPlaybackSource, complete_registered_playback_inventory,
    )
    source = RegisteredPlaybackSource("crawler", "anich", "crawler", "not_queried", "未查询")
    candidate = RegisteredPlaybackSource("candidate", "候选", "candidate", "candidate_unadmitted", "未接入")
    routes = [{
        "source": f"route-{i}", "catalog_source": "聚合线路",
        "url": f"https://cdn.example/route-{i}.m3u8", "available": i == 0,
        "status": "server_verified" if i == 0 else "unavailable",
        "diagnostic_status": "server_verified" if i == 0 else "route_unavailable",
        "queried": True, "matched": True,
    } for i in range(58)]
    original = [dict(item) for item in routes]
    result = complete_registered_playback_inventory(routes, sources=(source, candidate))
    assert len(result) == 59
    assert len({item["inventory_source_id"] for item in result}) == 2
    assert sum(bool(item["url"]) for item in result) == 58
    assert sum(item["available"] for item in result) == 1
    assert routes == original
    for before, after in zip(routes, result):
        assert all(after[key] == value for key, value in before.items())
    assert complete_registered_playback_inventory(result, sources=(source, candidate)) == result


def test_same_display_name_does_not_merge_separately_registered_sources():
    from server.playback_inventory import (
        RegisteredPlaybackSource, complete_registered_playback_inventory,
    )
    sources = (
        RegisteredPlaybackSource("maccms", "同名", "configured", "not_queried", "未查询"),
        RegisteredPlaybackSource("candidate", "同名", "candidate", "candidate_unadmitted", "未接入"),
    )
    result = complete_registered_playback_inventory([], sources=sources)
    assert len(result) == 2
    assert len({item["inventory_source_id"] for item in result}) == 2
    assert len(complete_registered_playback_inventory(result, sources=sources)) == 2


def test_visibility_completion_never_changes_provider_admission_or_queries():
    from server.aggregator import aggregator
    from server.playback_inventory import complete_registered_playback_inventory
    before = tuple(aggregator.provider_metadata)
    inventory = tuple(aggregator.source_inventory)
    with patch.object(aggregator, "discover_source_matches", new=AsyncMock()) as discovery:
        result = complete_registered_playback_inventory([])
    discovery.assert_not_awaited()
    assert tuple(aggregator.provider_metadata) == before
    assert tuple(aggregator.source_inventory) == inventory
    assert len(result) == 118
    assert all(item["headers"] == {} and item["url"] == "" for item in result)
    assert all("api" not in item and "source_address" not in item for item in result)


def test_malformed_visibility_marker_cannot_promote_media():
    from server.playback_inventory import (
        RegisteredPlaybackSource, complete_registered_playback_inventory,
    )
    source = RegisteredPlaybackSource("candidate", "候选", "candidate", "candidate_unadmitted", "未接入")
    result = complete_registered_playback_inventory([{
        "inventory_source_id": source.inventory_id, "source_inventory_entry": True,
        "source": "candidate:候选", "url": "http://127.0.0.1/media.mp4",
        "headers": {"Authorization": "fixture-not-a-credential"},
        "available": True, "status": "server_verified", "queried": True,
    }], sources=(source,))
    expected = source.placeholder() | {"client_query_supported": False, "query_location": "vps"}
    assert result == [expected]


def test_unknown_marker_is_not_admitted_as_a_new_source():
    from server.playback_inventory import (
        RegisteredPlaybackSource, complete_registered_playback_inventory,
    )
    source = RegisteredPlaybackSource("candidate", "已登记", "candidate", "candidate_unadmitted", "未接入")
    result = complete_registered_playback_inventory([{
        "inventory_source_id": ["invalid"], "source_inventory_entry": True,
        "source": "candidate:未登记", "url": "https://cdn.example/new.mp4",
        "available": True, "queried": True,
    }], sources=(source,))
    expected = source.placeholder() | {"client_query_supported": False, "query_location": "vps"}
    assert result == [expected]


def test_local_descriptors_only_expose_active_admitted_https_metadata(active_maccms_inventory):
    from server.playback_inventory import registered_playback_sources, local_query_descriptor
    sources = registered_playback_sources()
    descriptors = [local_query_descriptor(source.inventory_id) for source in sources]
    supported = [item for item in descriptors if item]
    assert supported
    for source, descriptor in zip(sources, descriptors):
        if descriptor is None:
            continue
        assert source.family == "maccms" and source.status == "not_queried"
        assert set(descriptor) == {"inventory_source_id", "name", "protocol", "endpoint"}
        assert descriptor["protocol"] == "maccms-json"
        assert descriptor["endpoint"].startswith("https://")
    assert all(descriptor is None for source, descriptor in zip(sources, descriptors)
               if source.family != "maccms" or source.status != "not_queried")


@pytest.mark.parametrize("endpoint", [
    "http://source.example/api", "https://127.0.0.1/api", "https://10.0.0.1/api",
    "https://user:fixture@source.example/api", "https://source.example:8443/api",
    "https://source.example/api?token=fixture", "https://source.example/api#x",
    "https://test.local/api", "https://test.localhost./api",
])
def test_local_descriptor_rejects_unsafe_endpoint(endpoint):
    from server.playback_inventory import RegisteredPlaybackSource, local_query_descriptor
    source = RegisteredPlaybackSource("maccms", "fixture", "configured", "not_queried", "")
    with patch("server.playback_inventory.MACCMS_SITES", [{"name": "fixture", "api": endpoint}]):
        assert local_query_descriptor(source.inventory_id, sources=(source,)) is None


def test_descriptor_route_is_metadata_only_and_unsupported_returns_404(active_maccms_inventory):
    from server.playback_inventory import registered_playback_sources, local_query_descriptor
    sources = registered_playback_sources()
    supported = next(s for s in sources if local_query_descriptor(s.inventory_id))
    candidate = next(s for s in sources if s.family == "candidate")
    with patch("server.routers.playback.playback_service.lines", new=AsyncMock()) as lookup:
        client = TestClient(create_app())
        response = client.get(f"/api/v3/playback-source/{supported.inventory_id}")
        assert response.status_code == 200
        assert response.json() == local_query_descriptor(supported.inventory_id)
        assert client.get(f"/api/v3/playback-source/{candidate.inventory_id}").status_code == 404
        assert client.get("/api/v3/playback-source/unregistered").status_code == 404
    lookup.assert_not_awaited()


def test_inventory_builds_source_registry_once_per_completion():
    from server.playback_inventory import complete_registered_playback_inventory, registered_playback_sources
    sources = registered_playback_sources()
    with patch("server.playback_inventory.registered_playback_sources", return_value=sources) as registry:
        complete_registered_playback_inventory([])
    registry.assert_called_once()


@pytest.fixture
def active_maccms_inventory():
    from dataclasses import replace
    from types import SimpleNamespace
    from server.aggregator import aggregator
    metadata = tuple(replace(item, enabled=True) if item.provider_id == "aggregate.maccms"
                     else item for item in aggregator.provider_metadata)
    # A test-only registry, not a production policy mutation.
    with patch("server.playback_inventory.aggregator", SimpleNamespace(provider_metadata=metadata)):
        yield


def test_disabled_aggregator_never_offers_local_query():
    from dataclasses import replace
    from types import SimpleNamespace
    from server.aggregator import aggregator
    from server.playback_inventory import complete_registered_playback_inventory
    metadata = tuple(replace(item, enabled=False) if item.provider_id == "aggregate.maccms"
                     else item for item in aggregator.provider_metadata)
    with patch("server.playback_inventory.aggregator", SimpleNamespace(provider_metadata=metadata)):
        result = complete_registered_playback_inventory([])
    assert not any(item["client_query_supported"] for item in result)
