import re

from fastapi.testclient import TestClient

from server.app import create_app
from server.observability import ObservabilityMetrics, current_request_id


def test_request_id_is_generated_and_exposed_without_query_data():
    app = create_app()
    client = TestClient(app)

    response = client.get("/api/v3/status?email=secret@example.com&token=secret")

    assert response.status_code == 200
    request_id = response.headers["x-request-id"]
    assert re.fullmatch(r"req-[0-9a-f]{24}", request_id)
    assert response.json()["observability"]["requests_total"] == 0
    assert current_request_id() is None

    second = client.get("/api/v3/status")
    metrics = second.json()["observability"]
    assert metrics["requests_total"] >= 1
    assert metrics["errors_total"] == 0
    assert metrics["requests_by_method"]["get"] >= 1
    assert "route" not in metrics
    assert "email" not in metrics
    assert "token" not in metrics


def test_request_id_context_reaches_handlers_and_error_responses():
    app = create_app()

    @app.get("/test/request-id")
    async def request_id_probe():
        return {"request_id": current_request_id()}

    client = TestClient(app)
    response = client.get("/test/request-id")
    assert response.status_code == 200
    assert response.json()["request_id"] == response.headers["x-request-id"]

    missing = client.get("/test/missing?password=secret")
    assert missing.status_code == 404
    assert re.fullmatch(r"req-[0-9a-f]{24}", missing.headers["x-request-id"])
    snapshot = app.state.observability.snapshot()
    assert snapshot["errors_total"] >= 1
    assert snapshot["responses"]["4xx"] >= 1


def test_metrics_use_fixed_buckets_and_bound_duration_values():
    metrics = ObservabilityMetrics()
    metrics.record_request(method="made-up", status_code=503, duration_ms=99_999_999)

    snapshot = metrics.snapshot()
    assert snapshot["requests_total"] == 1
    assert snapshot["errors_total"] == 1
    assert snapshot["requests_by_method"] == {"other": 1}
    assert snapshot["latency_ms"]["sum"] == 86_400_000
    assert snapshot["latency_ms"]["buckets"] == {"gt_1000ms": 1}
