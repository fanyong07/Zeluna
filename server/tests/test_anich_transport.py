import socket
import unittest
from unittest.mock import patch

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
        self.assertEqual(ctx.exception.reason, "upstream_http_error")
        self.assertEqual(ctx.exception.status, 500)
        self.assertGreater(ctx.exception.retry_after_seconds, 59.0)
        self.assertLessEqual(ctx.exception.retry_after_seconds, 60.0)
        self.assertIsInstance(ctx.exception.__cause__, AniChUpstreamError)
        self.assertIsInstance(ctx.exception.__cause__.__cause__, httpx.HTTPStatusError)

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

class AniChSearchIsolationTests(unittest.IsolatedAsyncioTestCase):
    async def test_bad_search_query_does_not_quarantine_working_origin(self):
        calls = []
        def handler(request):
            calls.append((request.url.host, request.url.params.get('keyword')))
            if request.url.host != 'unit-a.example':
                raise httpx.ConnectError('offline mirror', request=request)
            if request.url.params.get('keyword') == 'no-match':
                return httpx.Response(500, json={'error': 'search failed'})
            return httpx.Response(200, content=_BODY)
        subject = _transport(handler)
        try:
            with self.assertRaises(AniChUpstreamError) as caught:
                await subject.request(anich_search_path('no-match'))
            self.assertEqual(caught.exception.reason, 'search_query_failed')
            self.assertEqual(caught.exception.status, 500)
            self.assertEqual(caught.exception.retry_after_seconds, 0)
            self.assertIsInstance(caught.exception.__cause__, httpx.HTTPStatusError)
            self.assertEqual(subject._base_cooldown_until, {})
            self.assertEqual(await subject.request(anich_search_path('known-title')), _BODY)
            self.assertEqual(await subject.request('/vod/33339/1'), _BODY)
            self.assertEqual([host for host, _ in calls], ['unit-a.example'] * 3)
        finally:
            await subject.aclose()

    async def test_empty_protobuf_search_is_a_miss_not_an_origin_failure(self):
        calls = []
        def handler(request):
            calls.append(request.url.host)
            return httpx.Response(200, content=b'')
        subject = _transport(handler)
        try:
            self.assertEqual(await subject.request(anich_search_path('missing')), b'')
            self.assertEqual(await subject.request(anich_search_path('other')), b'')
            self.assertEqual(calls, ['unit-a.example', 'unit-a.example'])
        finally:
            await subject.aclose()


class AniChStructuredFailureTests(unittest.IsolatedAsyncioTestCase):
    async def test_missing_optional_detail_does_not_quarantine_other_endpoints(self):
        calls = []

        def handler(request):
            calls.append(request.url.path)
            if request.url.path.startswith("/bangumi/detail/"):
                return httpx.Response(404 if request.url.path.endswith("/1") else 410)
            return httpx.Response(200, content=_BODY)

        subject = _transport(handler)
        try:
            for ident in (1, 2):
                with self.assertRaises(AniChUpstreamError) as caught:
                    await subject.request(f"/bangumi/detail/{ident}")
                self.assertEqual(caught.exception.reason, "stale_route")
                self.assertEqual(caught.exception.retry_after_seconds, 0)
                self.assertIsInstance(caught.exception.__cause__, httpx.HTTPStatusError)
            self.assertEqual(subject._base_cooldown_until, {})
            self.assertEqual(await subject.request(anich_search_path("title")), _BODY)
            self.assertEqual(await subject.request("/vod/1/1"), _BODY)
            self.assertEqual(len(calls), 4)
        finally:
            await subject.aclose()

    async def test_cooldown_preserves_failure_and_recovers_at_retry_after(self):
        now = [100.0]
        calls = []

        def handler(request):
            calls.append(request.url.host)
            return httpx.Response(503 if now[0] < 160 else 200, content=_BODY)

        subject = _transport(handler, clock=lambda: now[0])
        try:
            with self.assertRaises(AniChUpstreamError) as first:
                await subject.request(anich_latest_path())
            self.assertEqual(first.exception.reason, "upstream_http_error")
            self.assertEqual(first.exception.status, 503)
            self.assertEqual(first.exception.retry_after_seconds, 60)
            now[0] = 120
            with self.assertRaises(AniChUpstreamError) as cooled:
                await subject.request(anich_latest_path())
            self.assertEqual(len(calls), 2, "cooldown must not dispatch probes")
            self.assertEqual(cooled.exception.reason, "upstream_cooldown")
            self.assertEqual(cooled.exception.cause_reason, "upstream_http_error")
            self.assertEqual(cooled.exception.status, 503)
            self.assertEqual(cooled.exception.retry_after_seconds, 40)
            self.assertIsInstance(cooled.exception.__cause__, AniChUpstreamError)
            self.assertIsInstance(
                cooled.exception.__cause__.__cause__, httpx.HTTPStatusError
            )
            now[0] += cooled.exception.retry_after_seconds
            self.assertEqual(await subject.request(anich_latest_path()), _BODY)
            self.assertEqual(len(calls), 3)
            self.assertNotIn(subject.base, subject._base_failures)
        finally:
            await subject.aclose()

    async def test_transport_failures_keep_typed_cause_without_url_in_message(self):
        cases = (
            (httpx.ConnectTimeout, "connect_timeout"),
            (httpx.ReadTimeout, "read_timeout"),
            (httpx.WriteTimeout, "read_timeout"),
            (httpx.PoolTimeout, "read_timeout"),
            (httpx.ConnectError, "connect_error"),
            (httpx.RemoteProtocolError, "transport_error"),
        )
        for error_type, reason in cases:
            with self.subTest(reason=reason, error_type=error_type):
                original = []

                def handler(request):
                    error = error_type(
                        "sensitive endpoint https://private.example/?token=fixture",
                        request=request,
                    )
                    original.append(error)
                    raise error

                subject = _transport(handler)
                try:
                    with self.assertRaises(AniChUpstreamError) as caught:
                        await subject.request(anich_latest_path())
                    self.assertEqual(caught.exception.reason, reason)
                    self.assertIsNone(caught.exception.status)
                    self.assertIs(caught.exception.__cause__.__cause__, original[-1])
                    self.assertNotIn("private.example", str(caught.exception))
                    self.assertNotIn("token=", str(caught.exception.__cause__))
                    with self.assertRaises(AniChUpstreamError) as cooled:
                        await subject.request(anich_latest_path())
                    self.assertEqual(cooled.exception.reason, "upstream_cooldown")
                    self.assertEqual(cooled.exception.cause_reason, reason)
                finally:
                    await subject.aclose()

    async def test_dns_failure_is_preserved_through_nested_causes(self):
        def handler(request):
            try:
                raise socket.gaierror(11001, "lookup failed")
            except socket.gaierror as cause:
                raise httpx.ConnectError("connect failed", request=request) from cause

        subject = _transport(handler)
        try:
            with self.assertRaises(AniChUpstreamError) as caught:
                await subject.request(anich_latest_path())
            self.assertEqual(caught.exception.reason, "dns_failure")
            self.assertIsInstance(
                caught.exception.__cause__.__cause__.__cause__, socket.gaierror
            )
        finally:
            await subject.aclose()

    async def test_status_failures_expose_http_status_and_cooldown(self):
        for status, reason in ((403, "restricted"), (429, "rate_limited"),
                               (404, "stale_route"), (503, "upstream_http_error"),
                               (200, "empty_response")):
            with self.subTest(status=status):
                subject = _transport(lambda request: httpx.Response(status))
                try:
                    with self.assertRaises(AniChUpstreamError) as caught:
                        await subject.request(anich_latest_path())
                    self.assertEqual(caught.exception.reason, reason)
                    self.assertEqual(caught.exception.status, status)
                    self.assertGreater(caught.exception.retry_after_seconds, 0)
                    self.assertEqual(
                        caught.exception.__cause__.__cause__.response.status_code, status
                    )
                finally:
                    await subject.aclose()

    async def test_cooldown_uses_first_recoverable_origin_failure(self):
        now = [100.0]
        calls = []
        recovered = [False]

        def handler(request):
            calls.append(request.url.host)
            if recovered[0]:
                return httpx.Response(200, content=_BODY)
            if request.url.host == "unit-a.example":
                return httpx.Response(503)
            now[0] = 110.0
            raise httpx.ReadTimeout("read stalled", request=request)

        subject = _transport(handler, clock=lambda: now[0])
        try:
            with self.assertRaises(AniChUpstreamError) as first:
                await subject.request(anich_latest_path())
            self.assertEqual(first.exception.reason, "read_timeout")
            self.assertIsNone(first.exception.status, "no stale status from prior origin")
            self.assertEqual(first.exception.retry_after_seconds, 50)
            with self.assertRaises(AniChUpstreamError) as cooled:
                await subject.request(anich_latest_path())
            self.assertEqual(cooled.exception.reason, "upstream_cooldown")
            self.assertEqual(cooled.exception.cause_reason, "upstream_http_error")
            self.assertEqual(cooled.exception.status, 503)
            self.assertEqual(cooled.exception.retry_after_seconds, 50)
            self.assertEqual(len(calls), 2)
            now[0] += cooled.exception.retry_after_seconds
            recovered[0] = True
            self.assertEqual(await subject.request(anich_latest_path()), _BODY)
            self.assertEqual(calls[-1], "unit-a.example")
        finally:
            await subject.aclose()

    async def test_relay_fetch_base_only_changes_media_not_metadata_origins(self):
        from server import config
        from server.scrapers.anime.anich_transport import to_fetch_url

        calls = []

        def handler(request):
            calls.append(request)
            return httpx.Response(200, content=_BODY)

        with patch.object(config, "ANICH_RELAY_BASE", ""), patch.object(
            config, "ANICH_RELAY_KEY", "fixture-key"
        ), patch.object(config, "ANICH_RELAY_PUBLIC_BASE", "https://media-public.example"), patch.object(
            config, "ANICH_RELAY_FETCH_BASE", "http://127.0.0.1:4321"
        ):
            subject = _transport(handler)
            try:
                self.assertFalse(subject.via_relay)
                self.assertEqual(await subject.request(anich_search_path("title")), _BODY)
                self.assertEqual(calls[0].url.host, "unit-a.example")
                self.assertNotIn("X-Relay-Key", calls[0].headers)
                self.assertEqual(to_fetch_url("https://media-public.example/a.m3u8?x=1"),
                                 "http://127.0.0.1:4321/a.m3u8?x=1")
            finally:
                await subject.aclose()

    async def test_multiple_relays_rotate_without_sending_key_to_direct_origins(self):
        from server import config

        calls = []

        def handler(request):
            calls.append(request)
            self.assertEqual(request.headers.get("X-Relay-Key"), "fixture-key")
            if request.url.host == "relay-a.example":
                raise httpx.ConnectError("offline", request=request)
            return httpx.Response(200, content=_BODY)

        with patch.object(config, "ANICH_RELAY_BASE", (
            " https://relay-a.example/prefix/, https://relay-b.example/, "
            "https://relay-b.example/ "
        )), patch.object(config, "ANICH_RELAY_KEY", "fixture-key"):
            subject = _transport(handler)
        try:
            self.assertTrue(subject.via_relay)
            self.assertEqual(len(subject._bases), 2)
            self.assertEqual(await subject.request(anich_latest_path()), _BODY)
            self.assertEqual(await subject.request(anich_latest_path()), _BODY)
            self.assertEqual([r.url.host for r in calls], [
                "relay-a.example", "relay-b.example", "relay-b.example"
            ])
            self.assertEqual(calls[0].url.path, "/prefix/bangumi/latest")
        finally:
            await subject.aclose()
