import unittest

import httpx

from server.scrapers.domain_watch import (
    DOMAIN_KIND_CONTENT,
    DOMAIN_KIND_DEAD,
    DOMAIN_KIND_EMPTY,
    DOMAIN_KIND_JS_GATE,
    DOMAIN_KIND_LANDING,
    DomainWatch,
    classify_page,
    extract_sibling_hosts,
)

# 判定素材尺寸取自 2026-08-28 实测:js-gate 约 4.7KB、落地页数十 KB、
# 内容站十万字节量级。
_FILLER = "内容占位" * 900  # > 1500 字节
_CONTENT_HTML = _FILLER + '<a href="/vod/1234.html">第01集</a> player_aaaa = {}'
_LANDING_HTML = _FILLER + '<a href="https://apps.apple.com/x">下载 App</a>'
_JS_GATE_HTML = "<html><body>Redirecting…<script>window.location='/x'</script></body></html>" + "x" * 4500


class ClassifyPageTests(unittest.TestCase):
    def test_content_marks_promote_page_to_content(self):
        kind, marks = classify_page(200, _CONTENT_HTML)
        self.assertEqual(kind, DOMAIN_KIND_CONTENT)
        self.assertTrue(marks)

    def test_large_page_without_marks_is_landing(self):
        kind, marks = classify_page(200, _LANDING_HTML)
        self.assertEqual(kind, DOMAIN_KIND_LANDING)
        self.assertEqual(marks, ())

    def test_small_redirect_page_is_js_gate(self):
        kind, _ = classify_page(200, _JS_GATE_HTML)
        self.assertEqual(kind, DOMAIN_KIND_JS_GATE)

    def test_tiny_or_error_pages_are_empty(self):
        self.assertEqual(classify_page(200, "hi")[0], DOMAIN_KIND_EMPTY)
        self.assertEqual(classify_page(404, _FILLER)[0], DOMAIN_KIND_EMPTY)

    def test_transport_failure_is_dead(self):
        self.assertEqual(classify_page(None, "")[0], DOMAIN_KIND_DEAD)

    def test_js_gate_needs_both_small_size_and_redirect_marker(self):
        # 体量大的页面即便含 window.location 也不算告别页
        big = _FILLER * 4 + "window.location='/x'"
        self.assertNotEqual(classify_page(200, big)[0], DOMAIN_KIND_JS_GATE)


class SiblingExtractionTests(unittest.TestCase):
    def test_extracts_same_root_subdomains(self):
        html = (
            '<a href="https://anime.example-brand.com/x">内容站</a>'
            '<a href="https://cdn.other.net/y">无关</a>'
        )
        hosts = extract_sibling_hosts("https://www.example-brand.com", html)
        self.assertIn("anime.example-brand.com", hosts)
        self.assertNotIn("cdn.other.net", hosts)

    def test_skips_origin_host_itself(self):
        html = '<a href="https://www.example-brand.com/self">self</a>'
        self.assertEqual(
            extract_sibling_hosts("https://www.example-brand.com", html), ()
        )


def _watch(handler, families, **kwargs) -> DomainWatch:
    return DomainWatch(
        families,
        transport=httpx.MockTransport(handler),
        request_gap_seconds=0.0,
        **kwargs,
    )


class DomainWatchTests(unittest.IsolatedAsyncioTestCase):
    async def test_resolve_picks_first_content_domain(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.host == "dead.example":
                raise httpx.ConnectError("boom", request=request)
            return httpx.Response(200, text=_CONTENT_HTML)

        watch = _watch(
            handler,
            {"brand": ("https://dead.example", "https://live.example")},
        )
        try:
            self.assertEqual(await watch.resolve("brand"), "https://live.example")
        finally:
            await watch.aclose()

    async def test_landing_page_sibling_is_promoted_into_family(self):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.host == "www.brandsite.com":
                return httpx.Response(
                    200,
                    text=_LANDING_HTML
                    + '<a href="https://anime.brandsite.com/">内容</a>',
                )
            if request.url.host == "anime.brandsite.com":
                return httpx.Response(200, text=_CONTENT_HTML)
            return httpx.Response(404, text="")

        watch = _watch(handler, {"brand": ("https://www.brandsite.com",)})
        try:
            resolved = await watch.resolve("brand")
            self.assertEqual(resolved, "https://anime.brandsite.com")
            # 新址被插到族首,后续解析优先命中
            self.assertEqual(watch.families["brand"][0], "https://anime.brandsite.com")
        finally:
            await watch.aclose()

    async def test_resolve_caches_within_ttl_and_refetches_on_force(self):
        calls = []
        now = [1000.0]

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append(str(request.url))
            return httpx.Response(200, text=_CONTENT_HTML)

        watch = _watch(
            handler,
            {"brand": ("https://live.example",)},
            ttl_seconds=600,
            clock=lambda: now[0],
        )
        try:
            await watch.resolve("brand")
            self.assertEqual(len(calls), 1)
            await watch.resolve("brand")           # TTL 内不重探
            self.assertEqual(len(calls), 1)
            await watch.resolve("brand", force=True)
            self.assertEqual(len(calls), 2)
            now[0] += 601                           # TTL 过期
            await watch.resolve("brand")
            self.assertEqual(len(calls), 3)
        finally:
            await watch.aclose()

    async def test_resolve_returns_none_when_family_has_no_content(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, text=_JS_GATE_HTML)

        watch = _watch(handler, {"brand": ("https://gate.example",)})
        try:
            self.assertIsNone(await watch.resolve("brand"))
        finally:
            await watch.aclose()

    async def test_audit_reports_every_domain_kind(self):
        def handler(request: httpx.Request) -> httpx.Response:
            host = request.url.host
            if host == "content.example":
                return httpx.Response(200, text=_CONTENT_HTML)
            if host == "landing.example":
                return httpx.Response(200, text=_LANDING_HTML)
            if host == "gate.example":
                return httpx.Response(200, text=_JS_GATE_HTML)
            raise httpx.ConnectError("boom", request=request)

        watch = _watch(
            handler,
            {
                "brand": (
                    "https://content.example",
                    "https://landing.example",
                    "https://gate.example",
                    "https://dead.example",
                )
            },
        )
        try:
            report = await watch.audit()
        finally:
            await watch.aclose()
        kinds = [row.kind for row in report["brand"]]
        self.assertEqual(
            kinds,
            [
                DOMAIN_KIND_CONTENT,
                DOMAIN_KIND_LANDING,
                DOMAIN_KIND_JS_GATE,
                DOMAIN_KIND_DEAD,
            ],
        )

    async def test_verdict_public_dict_excludes_page_body(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, text=_CONTENT_HTML)

        watch = _watch(handler, {"brand": ("https://live.example",)})
        try:
            verdict = await watch.check("https://live.example")
        finally:
            await watch.aclose()
        public = verdict.as_public_dict()
        self.assertEqual(
            set(public), {"base", "kind", "size", "status", "mark_count"}
        )
        self.assertNotIn("内容占位", str(public))


if __name__ == "__main__":
    unittest.main()
