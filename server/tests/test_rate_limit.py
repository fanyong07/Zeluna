import asyncio

import pytest

from server.rate_limit import (
    InMemoryRateLimiter,
    RateLimitExceeded,
    RateLimiterUnavailable,
    RedisRateLimiter,
    UnavailableRateLimiter,
)


def test_in_memory_budget_is_bounded_and_ttl_resets():
    clock = [0.0]
    limiter = InMemoryRateLimiter(2, clock=lambda: clock[0])
    limiter.check("same", limit=2, window_seconds=10)
    limiter.check("same", limit=2, window_seconds=10)
    with pytest.raises(RateLimitExceeded) as limited:
        limiter.check("same", limit=2, window_seconds=10)
    assert limited.value.retry_after == 10

    clock[0] = 11
    limiter.check("same", limit=2, window_seconds=10)
    limiter.check("other", limit=1, window_seconds=10)
    with pytest.raises(RateLimitExceeded):
        limiter.check("third", limit=1, window_seconds=10)


class _FakeRedis:
    def __init__(self):
        self.values: dict[str, tuple[int, int]] = {}
        self.keys: list[str] = []

    async def eval(self, _script, _key_count, key, limit, window_seconds):
        self.keys.append(key)
        current, ttl = self.values.get(key, (0, 0))
        if ttl <= 0:
            current, ttl = 0, int(window_seconds)
        current += 1
        self.values[key] = (current, ttl)
        return [1 if current <= int(limit) else 0, ttl]


def test_redis_instances_share_budget_and_hash_keys():
    redis = _FakeRedis()
    first = RedisRateLimiter(redis, key_secret="s" * 32)
    second = RedisRateLimiter(redis, key_secret="s" * 32)

    async def exercise():
        await first.check("email:user@example.com", limit=2, window_seconds=30)
        await second.check("email:user@example.com", limit=2, window_seconds=30)
        with pytest.raises(RateLimitExceeded) as limited:
            await first.check("email:user@example.com", limit=2, window_seconds=30)
        return limited.value.retry_after

    assert asyncio.run(exercise()) == 30
    assert redis.keys
    assert all("user@example.com" not in key for key in redis.keys)


def test_redis_failure_is_not_silently_downgraded():
    class BrokenRedis:
        async def eval(self, *_args):
            raise OSError("offline")

    limiter = RedisRateLimiter(BrokenRedis(), key_secret="s" * 32)
    with pytest.raises(RateLimiterUnavailable):
        asyncio.run(limiter.check("login:ip:127.0.0.1", limit=1, window_seconds=10))

    with pytest.raises(RateLimiterUnavailable):
        UnavailableRateLimiter().check("key", limit=1, window_seconds=10)
