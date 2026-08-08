"""Shared account rate-limiting primitives.

The application keeps an in-process implementation for tests and explicitly
single-process deployments. Multi-instance deployments can inject a Redis
client into :class:`RedisRateLimiter`; Redis failures are surfaced rather than
silently falling back to a local budget.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import inspect
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Any, Protocol


class RateLimitExceeded(RuntimeError):
    def __init__(self, retry_after: int):
        self.retry_after = max(1, int(retry_after))
        super().__init__("rate limit exceeded")


class RateLimiterUnavailable(RuntimeError):
    """The configured shared limiter cannot make a safe decision."""


class RateLimiter(Protocol):
    def check(self, key: str, *, limit: int, window_seconds: int) -> Any:
        """Consume one attempt or raise :class:`RateLimitExceeded`."""


@dataclass
class _Bucket:
    events: deque[float]
    window_seconds: int


class InMemoryRateLimiter:
    """Bounded process-local limiter for tests and local development."""

    def __init__(self, max_keys: int, *, clock=time.monotonic):
        self._max_keys = max(1, int(max_keys))
        self._clock = clock
        self._buckets: dict[str, _Bucket] = {}
        self._lock = threading.Lock()

    def clear(self) -> None:
        with self._lock:
            self._buckets.clear()

    def __len__(self) -> int:
        with self._lock:
            return len(self._buckets)

    def _purge_expired(self, now: float) -> None:
        expired: list[str] = []
        for key, bucket in self._buckets.items():
            cutoff = now - bucket.window_seconds
            while bucket.events and bucket.events[0] <= cutoff:
                bucket.events.popleft()
            if not bucket.events:
                expired.append(key)
        for key in expired:
            self._buckets.pop(key, None)

    def check(
        self,
        key: str,
        *,
        limit: int,
        window_seconds: int,
        now: float | None = None,
    ) -> None:
        if limit <= 0 or window_seconds <= 0:
            raise ValueError("rate limit capacity and window must be positive")
        current = self._clock() if now is None else now
        with self._lock:
            bucket = self._buckets.get(key)
            if bucket is None:
                if len(self._buckets) >= self._max_keys:
                    self._purge_expired(current)
                if len(self._buckets) >= self._max_keys:
                    raise RateLimitExceeded(window_seconds)
                bucket = _Bucket(deque(), window_seconds)
                self._buckets[key] = bucket
            else:
                bucket.window_seconds = window_seconds

            cutoff = current - window_seconds
            while bucket.events and bucket.events[0] <= cutoff:
                bucket.events.popleft()
            if len(bucket.events) >= limit:
                retry_after = max(
                    1, int(window_seconds - (current - bucket.events[0]))
                )
                raise RateLimitExceeded(retry_after)
            bucket.events.append(current)


_REDIS_SCRIPT = """
local current = redis.call('INCR', KEYS[1])
if current == 1 then
  redis.call('EXPIRE', KEYS[1], ARGV[2])
end
local ttl = redis.call('TTL', KEYS[1])
if current > tonumber(ARGV[1]) then
  return {0, ttl}
end
return {1, ttl}
"""


class RedisRateLimiter:
    """Atomic Redis-backed limiter with privacy-safe bounded keys.

    The client is deliberately injected so the server does not require a
    Redis connection for tests. It may be a synchronous or asynchronous Redis
    client exposing ``eval``.
    """

    def __init__(
        self,
        client: Any,
        *,
        namespace: str = "zeluna:rate:v1",
        key_secret: str | bytes,
    ):
        if client is None:
            raise ValueError("a Redis client is required")
        secret = key_secret.encode() if isinstance(key_secret, str) else key_secret
        if len(secret) < 16:
            raise ValueError("rate-limit key secret is too short")
        self._client = client
        self._namespace = namespace.strip(":") or "zeluna:rate:v1"
        self._secret = secret

    def _key(self, raw_key: str) -> str:
        digest = hmac.new(self._secret, raw_key.encode(), hashlib.sha256).hexdigest()
        return f"{self._namespace}:{digest}"

    async def check(
        self,
        key: str,
        *,
        limit: int,
        window_seconds: int,
    ) -> None:
        if limit <= 0 or window_seconds <= 0:
            raise ValueError("rate limit capacity and window must be positive")
        try:
            result = self._client.eval(
                _REDIS_SCRIPT,
                1,
                self._key(key),
                int(limit),
                int(window_seconds),
            )
            if inspect.isawaitable(result):
                result = await result
            allowed, retry_after = self._parse_result(result)
            if not allowed:
                raise RateLimitExceeded(retry_after)
        except RateLimitExceeded:
            raise
        except Exception as error:
            raise RateLimiterUnavailable("shared rate limiter unavailable") from error

    @staticmethod
    def _parse_result(result: Any) -> tuple[bool, int]:
        if not isinstance(result, (list, tuple)) or len(result) < 2:
            raise RateLimiterUnavailable("invalid shared limiter response")
        allowed = int(result[0]) == 1
        try:
            retry_after = max(1, int(result[1]))
        except (TypeError, ValueError) as error:
            raise RateLimiterUnavailable("invalid shared limiter ttl") from error
        return allowed, retry_after


class UnavailableRateLimiter:
    """Explicit fail-closed backend used until a Redis client is wired."""

    def check(self, *_args: Any, **_kwargs: Any) -> None:
        raise RateLimiterUnavailable("configured shared rate limiter unavailable")


def maybe_await(value: Any) -> Any:
    """Return an awaitable result for callers handling both limiter types."""

    if inspect.isawaitable(value):
        return value
    async def _done() -> Any:
        return value
    return _done()


__all__ = [
    "InMemoryRateLimiter",
    "RateLimiter",
    "RateLimitExceeded",
    "RateLimiterUnavailable",
    "RedisRateLimiter",
    "UnavailableRateLimiter",
    "maybe_await",
]
