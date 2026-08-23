import unittest

import httpx

from server.aggregator import (
    NON_PUBLIC_TARGET,
    SERVER_VERIFIED,
    UNAVAILABLE,
    ContentAggregator,
    LineVerificationResult,
)
from server.managed_lines.validation import (
    ManagedLineVerifier,
    ManagedLineValidationError,
    PublicMediaUrlPolicy,
    validate_managed_headers,
)


class ManagedLineValidationTests(unittest.IsolatedAsyncioTestCase):
    async def test_redirect_with_userinfo_is_rejected_before_following_it(self):
        requests = 0

        def handler(_request: httpx.Request) -> httpx.Response:
            nonlocal requests
            requests += 1
            if requests > 1:
                raise AssertionError("userinfo redirect must never be requested")
            return httpx.Response(
                302,
                headers={
                    "location": "https://user:pass@93.184.216.34/video.mp4"
                },
            )

        aggregator = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler),
            enabled_provider_ids=frozenset(),
            resolver_search_enabled=False,
        )

        async def probe(line):
            result = await aggregator._line_verification_status(
                line,
                detailed=True,
            )
            self.assertIsInstance(result, LineVerificationResult)
            return result

        verifier = ManagedLineVerifier(probe=probe, timeout_seconds=1)
        try:
            result = await verifier.verify(
                "https://93.184.216.34/index.m3u8",
                format_hint="hls",
                headers={},
            )
        finally:
            await aggregator.aclose()

        self.assertEqual(result.status, UNAVAILABLE)
        self.assertEqual(result.error_category, NON_PUBLIC_TARGET)
        self.assertEqual(requests, 1)

    async def test_extensionless_url_is_sent_to_the_bounded_media_probe(self):
        async def resolve(_host: str, _port: int) -> set[str]:
            return {"93.184.216.34"}

        seen_url = ""

        async def probe(line):
            nonlocal seen_url
            seen_url = line.url
            return LineVerificationResult(
                status=SERVER_VERIFIED,
                latency_ms=25,
                startup_profile="hls",
            )

        verifier = ManagedLineVerifier(
            url_policy=PublicMediaUrlPolicy(resolve=resolve),
            probe=probe,
            timeout_seconds=1,
        )

        result = await verifier.verify(
            "https://media.example/opaque/asset-123",
            format_hint="auto",
            headers={},
        )

        self.assertEqual(result.status, SERVER_VERIFIED)
        self.assertEqual(seen_url, "https://media.example/opaque/asset-123")

    async def test_referer_and_origin_headers_are_normalized_for_playback(self):
        headers = validate_managed_headers(
            {
                "referer": "https://player.example/watch/",
                "ORIGIN": "https://player.example",
            }
        )

        self.assertEqual(
            headers,
            {
                "Referer": "https://player.example/watch/",
                "Origin": "https://player.example",
            },
        )

    async def test_sensitive_request_headers_are_rejected(self):
        for name in ("Cookie", "Authorization", "X-Api-Key"):
            with self.subTest(name=name):
                with self.assertRaises(ManagedLineValidationError) as raised:
                    validate_managed_headers({name: "must-not-be-stored"})
                self.assertEqual(raised.exception.code, "forbidden_header")

    async def test_allowed_header_values_cannot_inject_additional_headers(self):
        with self.assertRaises(ManagedLineValidationError) as raised:
            validate_managed_headers(
                {"Referer": "https://player.example/\r\nCookie: secret"}
            )

        self.assertEqual(raised.exception.code, "invalid_header_value")

    async def test_non_http_urls_are_rejected(self):
        async def resolve(_host: str, _port: int) -> set[str]:
            raise AssertionError("invalid schemes must not reach DNS")

        policy = PublicMediaUrlPolicy(resolve=resolve)

        with self.assertRaises(ManagedLineValidationError) as raised:
            await policy.validate("file:///tmp/video.mp4")

        self.assertEqual(raised.exception.code, "unsupported_scheme")

    async def test_hostname_resolving_to_private_address_is_rejected(self):
        async def resolve(host: str, port: int) -> set[str]:
            self.assertEqual((host, port), ("media.example", 443))
            return {"10.0.0.8"}

        policy = PublicMediaUrlPolicy(resolve=resolve)

        with self.assertRaises(ManagedLineValidationError) as raised:
            await policy.validate("https://media.example/video.m3u8")

        self.assertEqual(raised.exception.code, "non_public_target")

    async def test_obvious_player_page_is_rejected_even_with_media_format(self):
        async def resolve(_host: str, _port: int) -> set[str]:
            return {"93.184.216.34"}

        policy = PublicMediaUrlPolicy(resolve=resolve)

        for path in (
            "player.html?url=video",
            "embed/episode-1",
            "iframe/episode-1",
            "player/episode-1",
        ):
            with self.subTest(path=path):
                with self.assertRaises(ManagedLineValidationError) as raised:
                    await policy.validate(
                        f"https://media.example/{path}",
                        format_hint="hls",
                    )
                self.assertEqual(raised.exception.code, "player_page")

    async def test_url_userinfo_is_rejected_before_dns_lookup(self):
        dns_called = False

        async def resolve(_host: str, _port: int) -> set[str]:
            nonlocal dns_called
            dns_called = True
            return {"93.184.216.34"}

        policy = PublicMediaUrlPolicy(resolve=resolve)

        with self.assertRaises(ManagedLineValidationError) as raised:
            await policy.validate("https://user:pass@example.com/video.m3u8")

        self.assertEqual(raised.exception.code, "url_userinfo")
        self.assertFalse(dns_called)


if __name__ == "__main__":
    unittest.main()
