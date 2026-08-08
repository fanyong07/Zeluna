"""Privacy-safe request observability shared by the FastAPI application."""

from __future__ import annotations

import contextvars
import logging
import secrets
import time
from collections import Counter
from typing import Any

from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send


logger = logging.getLogger(__name__)

_request_id: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "zeluna_request_id", default=None
)
_LATENCY_BUCKETS = (50, 250, 1_000)
_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD")


def current_request_id() -> str | None:
    """Return the request ID for the current task, if one is active."""

    return _request_id.get()


def _new_request_id() -> str:
    return f"req-{secrets.token_hex(12)}"


class ObservabilityMetrics:
    """Bounded aggregate counters that never contain route or user values."""

    def __init__(self) -> None:
        self._started_at = time.monotonic()
        self._counters: Counter[str] = Counter()
        self._latency_count = 0
        self._latency_sum_ms = 0
        self._latency_buckets = Counter[str]()

    def record_request(self, *, method: str, status_code: int, duration_ms: int) -> None:
        normalized_method = method.upper()
        if normalized_method not in _METHODS:
            normalized_method = "OTHER"
        status_class = f"{status_code // 100}xx"
        self._counters["requests_total"] += 1
        self._counters[f"requests_method_{normalized_method.lower()}"] += 1
        self._counters[f"responses_{status_class}"] += 1
        if status_code >= 400:
            self._counters["errors_total"] += 1

        bounded_duration = max(0, min(duration_ms, 86_400_000))
        self._latency_count += 1
        self._latency_sum_ms += bounded_duration
        for bucket in _LATENCY_BUCKETS:
            if bounded_duration <= bucket:
                self._latency_buckets[f"le_{bucket}ms"] += 1
                break
        else:
            self._latency_buckets["gt_1000ms"] += 1

    def snapshot(self) -> dict[str, Any]:
        counters = dict(self._counters)
        return {
            "requests_total": counters.get("requests_total", 0),
            "errors_total": counters.get("errors_total", 0),
            "responses": {
                key.removeprefix("responses_"): value
                for key, value in counters.items()
                if key.startswith("responses_")
            },
            "requests_by_method": {
                key.removeprefix("requests_method_"): value
                for key, value in counters.items()
                if key.startswith("requests_method_")
            },
            "latency_ms": {
                "count": self._latency_count,
                "sum": self._latency_sum_ms,
                "buckets": dict(self._latency_buckets),
            },
            "uptime_seconds": max(0, int(time.monotonic() - self._started_at)),
        }


class ObservabilityMiddleware:
    """Attach a request ID and record only aggregate, redacted request data."""

    def __init__(self, app: ASGIApp, *, metrics: ObservabilityMetrics) -> None:
        self.app = app
        self.metrics = metrics

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = _new_request_id()
        token = _request_id.set(request_id)
        state = scope.setdefault("state", {})
        state["zeluna_request_id"] = request_id
        status_code = 500
        started_at = time.perf_counter()

        async def send_with_request_id(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = int(message["status"])
                headers = MutableHeaders(scope=message)
                headers["x-request-id"] = request_id
            await send(message)

        try:
            await self.app(scope, receive, send_with_request_id)
        finally:
            duration_ms = int((time.perf_counter() - started_at) * 1000)
            self.metrics.record_request(
                method=str(scope.get("method", "")),
                status_code=status_code,
                duration_ms=duration_ms,
            )
            route = scope.get("route")
            route_name = getattr(route, "path", "unmatched")
            logger.info(
                "http_request_complete",
                extra={
                    "zeluna": {
                        "request_id": request_id,
                        "route": route_name,
                        "status": status_code,
                        "duration_ms": duration_ms,
                    }
                },
            )
            _request_id.reset(token)
