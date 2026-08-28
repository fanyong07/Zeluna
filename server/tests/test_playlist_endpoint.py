import unittest
from unittest.mock import AsyncMock, patch

import httpx
from fastapi.testclient import TestClient

from server.app import create_app
from server.playlist_tokens import (
    PlaylistTokenError,
    issue_playlist_token,
    parse_playlist_token,
)

_STRONG_KEY = "z3luna-playlist-test-key-0123456789abcdef"
_HEAD = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n"


def _playlist_with_ads() -> str:
    parts = [_HEAD]
    parts += [f"#EXTINF:10.000,\nmain{i}.ts\n" for i in range(8)]
    parts.append("#EXT-X-DISCONTINUITY\n")
    parts += [f"#EXTINF:2.000,\nad{i}.ts\n" for i in range(4)]
    parts.append("#EXT-X-DISCONTINUITY\n")
    parts += [f"#EXTINF:10.000,\ntail{i}.ts\n" for i in range(8)]
    parts.append("#EXT-X-ENDLIST\n")
    return "".join(parts)


class PlaylistTokenTests(unittest.TestCase):
    def setUp(self):
        self._patcher = patch("server.playlist_tokens.signing_key",
                              return_value=_STRONG_KEY)
        self._patcher.start()
        self.addCleanup(self._patcher.stop)

    def test_roundtrip_preserves_url_and_referer(self):
        token = issue_playlist_token(
            "https://cdn.example/v/index.m3u8",
            referer="https://site.example/play",
        )
        target = parse_playlist_token(token)
        self.assertEqual(target.url, "https://cdn.example/v/index.m3u8")
        self.assertEqual(target.referer, "https://site.example/play")

    def test_tampered_payload_is_rejected(self):
        token = issue_playlist_token("https://cdn.example/v/index.m3u8")
        payload, signature = token.split(".", 1)
        forged = issue_playlist_token("https://evil.example/x.m3u8")
        with self.assertRaises(PlaylistTokenError):
            parse_playlist_token(forged.split(".", 1)[0] + "." + signature)
        with self.assertRaises(PlaylistTokenError):
            parse_playlist_token(payload + ".AAAA")

    def test_expired_token_is_rejected(self):
        token = issue_playlist_token(
            "https://cdn.example/v/index.m3u8", ttl_seconds=60, now=1000.0
        )
        with self.assertRaises(PlaylistTokenError):
            parse_playlist_token(token, now=1000.0 + 61 + 60)

    def test_non_http_targets_cannot_be_issued(self):
        for bad in ("file:///etc/passwd", "ftp://x/y", "", "javascript:alert(1)"):
            with self.assertRaises(PlaylistTokenError):
                issue_playlist_token(bad)

    def test_malformed_tokens_are_rejected(self):
        for bad in ("", "nodot", "a.b.c", "!!!.???"):
            with self.assertRaises(PlaylistTokenError):
                parse_playlist_token(bad)


class PlaylistEndpointTests(unittest.TestCase):
    def setUp(self):
        self._patchers = [
            patch("server.playlist_tokens.signing_key", return_value=_STRONG_KEY),
            patch(
                "server.routers.playback._is_public_http_url",
                new=AsyncMock(return_value=True),
            ),
        ]
        for p in self._patchers:
            p.start()
            self.addCleanup(p.stop)
        self.client = TestClient(create_app())

    def _token(self, url="https://cdn.example/v/index.m3u8", **kwargs):
        return issue_playlist_token(url, **kwargs)

    def test_cleaned_playlist_is_returned_as_text(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, text=_playlist_with_ads())

        with patch(
            "server.routers.playback.playlist_transport",
            httpx.MockTransport(handler),
        ):
            response = self.client.get(f"/api/v3/playlist/{self._token()}")

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.text.startswith("#EXTM3U"))
        self.assertNotIn("ad0.ts", response.text)
        self.assertIn("main0.ts", response.text)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertIn("mpegurl", response.headers["content-type"])

    def test_bare_url_is_not_accepted(self):
        # 直接把 URL 当 token 传 → 必须拒绝(否则就是开放代理)
        response = self.client.get(
            "/api/v3/playlist/https://evil.example/x.m3u8"
        )
        self.assertEqual(response.status_code, 400)

    def test_upstream_failure_maps_to_502(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(404, text="")

        with patch(
            "server.routers.playback.playlist_transport",
            httpx.MockTransport(handler),
        ):
            response = self.client.get(f"/api/v3/playlist/{self._token()}")
        self.assertEqual(response.status_code, 502)

    def test_referer_from_token_is_forwarded_upstream(self):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["referer"] = request.headers.get("Referer")
            return httpx.Response(200, text=_playlist_with_ads())

        token = self._token(referer="https://site.example/play")
        with patch(
            "server.routers.playback.playlist_transport",
            httpx.MockTransport(handler),
        ):
            self.client.get(f"/api/v3/playlist/{token}")
        self.assertEqual(seen["referer"], "https://site.example/play")

    def test_private_target_is_refused(self):
        with patch(
            "server.routers.playback._is_public_http_url",
            new=AsyncMock(return_value=False),
        ):
            response = self.client.get(f"/api/v3/playlist/{self._token()}")
        self.assertEqual(response.status_code, 400)


if __name__ == "__main__":
    unittest.main()
