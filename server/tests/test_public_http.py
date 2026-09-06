"""No-network tests for the DNS-pinned playlist connection boundary."""

import asyncio
import socket
import unittest
from unittest.mock import AsyncMock, patch

import httpx

from server.public_http import (
    PublicHttpTransport,
    UnsafeDestination,
    is_public_http_url,
    is_public_ip,
    resolve_public_http_url,
)


def _answer(address):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    return (family, socket.SOCK_STREAM, 6, "", (address, 443))


class PublicDestinationTests(unittest.IsolatedAsyncioTestCase):
    async def test_private_and_ambiguous_literals_are_refused_without_dns(self):
        urls = [
            "http://127.0.0.1/a",
            "http://10.0.0.1/a",
            "http://169.254.169.254/a",
            "http://[::1]/a",
            "http://[::ffff:127.0.0.1]/a",
            "http://224.0.0.1/a",
            "http://localhost/a",
            "http://localhost./a",
            "http://x.local/a",
            "https://user:pass@cdn.example/a",
            "https://@cdn.example/a",
            "file:///etc/passwd",
            "https://cdn.example:bad/a",
            "http://[fe80::1%25eth0]/a",
            "http://[64:ff9b::7f00:1]/a",
            "http://[2002:7f00:0001::]/a",
            " http://cdn.example/a",
            "https://cdn.example/\nignored",
            "https://cdn.example\\x/a",
        ]
        with patch.object(
            asyncio.get_running_loop(), "getaddrinfo", new=AsyncMock()
        ) as dns:
            for url in urls:
                with self.subTest(url=url):
                    self.assertFalse(await is_public_http_url(url))
            dns.assert_not_awaited()

    async def test_all_dns_answers_must_be_public(self):
        for answers in (
            [],
            [_answer("127.0.0.1")],
            [_answer("1.1.1.1"), _answer("::1")],
        ):
            with (
                self.subTest(answers=answers),
                patch.object(
                    asyncio.get_running_loop(),
                    "getaddrinfo",
                    new=AsyncMock(return_value=answers),
                ),
            ):
                self.assertFalse(await is_public_http_url("https://cdn.example/a"))

    async def test_public_answers_are_preserved_and_deduplicated(self):
        with patch.object(
            asyncio.get_running_loop(),
            "getaddrinfo",
            new=AsyncMock(
                return_value=[
                    _answer("1.1.1.1"),
                    _answer("2606:4700:4700::1111"),
                    _answer("1.1.1.1"),
                ],
            ),
        ) as dns:
            self.assertEqual(
                await resolve_public_http_url("https://cdn.example:8443/a"),
                ("1.1.1.1", "2606:4700:4700::1111"),
            )
            self.assertEqual(dns.await_args.args, ("cdn.example", 8443))

    async def test_dns_errors_fail_closed(self):
        with patch.object(
            asyncio.get_running_loop(),
            "getaddrinfo",
            new=AsyncMock(
                side_effect=socket.gaierror("test DNS error"),
            ),
        ):
            self.assertFalse(await is_public_http_url("https://cdn.example/a"))

    def test_public_ip_requires_unicast_global_address(self):
        for address in [
            "127.0.0.1",
            "0.0.0.0",
            "100.64.0.1",
            "224.0.0.1",
            "ff02::1",
            "fec0::1",
        ]:
            with self.subTest(address=address):
                self.assertFalse(is_public_ip(address))
        self.assertTrue(is_public_ip("1.1.1.1"))
        self.assertTrue(is_public_ip("2606:4700:4700::1111"))


class PinnedTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_checked_ip_is_connected_without_second_hostname_resolution(self):
        seen = []

        def handler(request):
            seen.append(request)
            return httpx.Response(200, text="ok")

        # A hypothetical next answer is private. There must not be a second
        # resolution between checking the public answer and opening a connection.
        with patch.object(
            asyncio.get_running_loop(),
            "getaddrinfo",
            new=AsyncMock(
                side_effect=[[_answer("1.1.1.1")], [_answer("127.0.0.1")]],
            ),
        ) as dns:
            transport = PublicHttpTransport(transport=httpx.MockTransport(handler))
            async with httpx.AsyncClient(
                transport=transport, trust_env=False
            ) as client:
                response = await client.get("https://cdn.example:8443/a?part=1")
        self.assertEqual(dns.await_count, 1)
        self.assertEqual(str(seen[0].url), "https://1.1.1.1:8443/a?part=1")
        self.assertEqual(seen[0].headers["Host"], "cdn.example:8443")
        self.assertEqual(seen[0].extensions["sni_hostname"], "cdn.example")
        self.assertEqual(str(response.url), "https://cdn.example:8443/a?part=1")

    async def test_ipv6_pin_preserves_origin_host_and_tls_identity(self):
        seen = []
        transport = PublicHttpTransport(
            transport=httpx.MockTransport(
                lambda r: seen.append(r) or httpx.Response(200)
            ),
            resolve=AsyncMock(return_value=("2606:4700:4700::1111",)),
        )
        async with httpx.AsyncClient(transport=transport) as client:
            await client.get("https://cdn.example/a")
        self.assertEqual(seen[0].url.host, "2606:4700:4700::1111")
        self.assertEqual(seen[0].headers["Host"], "cdn.example")
        self.assertEqual(seen[0].extensions["sni_hostname"], "cdn.example")

    async def test_private_rebinding_answer_never_reaches_transport(self):
        seen = []
        with patch.object(
            asyncio.get_running_loop(),
            "getaddrinfo",
            new=AsyncMock(
                return_value=[_answer("127.0.0.1")],
            ),
        ):
            transport = PublicHttpTransport(
                transport=httpx.MockTransport(
                    lambda r: seen.append(r) or httpx.Response(200),
                )
            )
            async with httpx.AsyncClient(transport=transport) as client:
                with self.assertRaises(UnsafeDestination):
                    await client.get("https://cdn.example/a")
        self.assertEqual(seen, [])

    async def test_next_public_address_can_be_used_if_first_is_unreachable(self):
        seen = []

        def handler(request):
            seen.append(request.url.host)
            if len(seen) == 1:
                raise httpx.ConnectError("test unavailable address")
            return httpx.Response(200)

        transport = PublicHttpTransport(
            transport=httpx.MockTransport(handler),
            resolve=AsyncMock(return_value=("1.1.1.1", "8.8.8.8")),
        )
        async with httpx.AsyncClient(transport=transport) as client:
            self.assertEqual(
                (await client.get("https://cdn.example/a")).status_code, 200
            )
        self.assertEqual(seen, ["1.1.1.1", "8.8.8.8"])

    async def test_default_transport_disables_proxy_and_cross_origin_pool_reuse(self):
        inner = AsyncMock(spec=httpx.AsyncBaseTransport)
        with patch(
            "server.public_http.httpx.AsyncHTTPTransport", return_value=inner
        ) as factory:
            transport = PublicHttpTransport()
        options = factory.call_args.kwargs
        self.assertFalse(options["trust_env"])
        self.assertEqual(options["limits"].max_keepalive_connections, 0)
        await transport.aclose()
        inner.aclose.assert_awaited_once()
