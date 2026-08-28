import unittest

import httpx

from server.scrapers.anime.anich_transport import (
    AniChTransport,
    AniChUpstreamError,
    anich_latest_path,
    anich_search_path,
)

_BODY = b"\x0a\x10" + b"x" * 16  # 任意 >16B 合法体
_TINY = dict(interval=0.0, timeout=5.0, backoff_max=0.01, base_cooldown_seconds=60.0)


def _transport(handler, **overrides) -> AniChTransport:
    merged = {**_TINY, **overrides}
    return AniChTransport(
        bases=("https://unit-a.example", "https://unit-b.example"),
        transport=httpx.MockTransport(handler),
        **merged,
    )


class AniChTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_enforces_min_interval_between_dispatches(self):
        import time as _time

        dispatched_at: list[float] = []

        def handler(request: httpx.Request) -> httpx.Response:
            dispatched_at.append(_time.monotonic())
            return httpx.Response(200, content=_BODY)

        subject = _transport(
            handler,
            interval=0.06,
            clock=_time.monotonic,
        )
        try:
            await subject.request("/bangumi/detail/1")
            await subject.request("/bangumi/detail/2")
        finally:
            await subject.aclose()
        self.assertEqual(len(dispatched_at), 2)
        gap = dispatched_at[1] - dispatched_at[0]
        # 留出 Windows 计时器抖动的余量,但必须能看出间隔被强制执行
        self.assertGreaterEqual(gap, 0.045)

    async def test_rate_limited_base_backs_off_once_then_next_base_serves(self):
        calls: list[str] = []

        def handler(request: httpx.Request) -> httpx.Response:
            host = request.url.host
            calls.append((host, request.url.path))
            if host == "unit-a.example":
                return httpx.Response(429)
            return httpx.Response(200, content=_BODY)

        queries: list[str] = []

        def handler(request: httpx.Request) -> httpx.Response:
            host = request.url.host
            calls.append((host, request.url.path))
            if host == "unit-a.example":
                return httpx.Response(429)
            queries.append(str(request.url.params))
            return httpx.Response(200, content=_BODY)

        subject = _transport(handler)
        try:
            body = await subject.request(anich_search_path("咒术回战"))
        finally:
            await subject.aclose()
        self.assertEqual(body, _BODY)
        a_calls = [c for c in calls if c[0] == "unit-a.example"]
        b_calls = [c for c in calls if c[0] == "unit-b.example"]
        # 同一候选:直试 + 退避重试一次;随后顺延到 B
        self.assertEqual(len(a_calls), 2)
        self.assertEqual(len(b_calls), 1)
        self.assertEqual(b_calls[0][1], "/bangumi/search")

    async def test_connection_error_rotates_to_next_base(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.host == "unit-a.example":
                raise httpx.ConnectError("boom", request=request)
            return httpx.Response(200, content=_BODY)

        subject = _transport(handler)
        try:
            body = await subject.request(anich_latest_path())
        finally:
            await subject.aclose()
        self.assertEqual(body, _BODY)

    async def test_all_candidates_exhausted_raises_upstream_error(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.host == "unit-a.example":
                raise httpx.ConnectError("boom", request=request)
            return httpx.Response(500)

        subject = _transport(handler)
        try:
            with self.assertRaises(AniChUpstreamError) as ctx:
                await subject.request(anich_latest_path())
        finally:
            await subject.aclose()
        self.assertIn("last_status=500", str(ctx.exception))

    async def test_failed_base_enters_cooldown_and_working_base_sticks(self):
        hits: list[str] = []

        def handler(request: httpx.Request) -> httpx.Response:
            host = request.url.host
            hits.append(host)
            if host == "unit-a.example":
                raise httpx.ConnectError("boom", request=request)
            return httpx.Response(200, content=_BODY)

        subject = _transport(handler)
        try:
            await subject.request(anich_latest_path())
            hits.clear()
            for _ in range(3):
                await subject.request(anich_latest_path())
        finally:
            await subject.aclose()
        # 第一次调用后 A 进冷却、B 成为工作主域;后续只打 B。
        self.assertEqual(hits, ["unit-b.example"] * 3)

    async def test_success_stamps_working_base_used_first(self):
        order: list[str] = []

        def handler(request: httpx.Request) -> httpx.Response:
            order.append(request.url.host)
            return httpx.Response(200, content=_BODY)

        subject = _transport(handler)
        try:
            await subject.request(anich_latest_path())  # 落在首选 A
            order.clear()
            await subject.request(anich_latest_path())
            self.assertEqual(subject.base, "https://unit-a.example")
        finally:
            await subject.aclose()
        self.assertEqual(order, ["unit-a.example"])

    async def test_gzip_encoded_body_is_decoded_transparently(self):
        import gzip as _gzip

        raw = _gzip.compress(_BODY)

        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                200,
                content=raw,
                headers={"Content-Encoding": "gzip"},
            )

        subject = _transport(handler)
        try:
            body = await subject.request(anich_latest_path())
        finally:
            await subject.aclose()
        self.assertEqual(body, _BODY)


if __name__ == "__main__":
    unittest.main()
