import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx

from server.aggregator import ContentAggregator
from tools.probe_maccms import (
    CANDIDATE_ORIGIN,
    CONFIGURED_SITES,
    build_report,
    load_candidate_sites,
    main,
    parse_first_media_urls,
    verify_media_url,
    write_json_report,
)


class MacCmsProbeTests(unittest.IsolatedAsyncioTestCase):
    def test_candidate_parser_rejects_player_pages_and_keeps_real_media(self):
        candidates = parse_first_media_urls(
            "播放页$https://source.example/player.html?url=video"
            "$$$HLS$https://cdn.example/master.m3u8?token=secret"
            "$$$MP4$https://cdn.example/video.mp4"
            "$$$未知$https://cdn.example/media/opaque-token"
        )

        self.assertEqual(
            [candidate["format"] for candidate in candidates],
            ["hls", "mp4", "auto"],
        )

    async def test_encrypted_hls_checks_child_manifest_key_and_segment(self):
        requested_paths = []

        def handler(request: httpx.Request) -> httpx.Response:
            requested_paths.append(request.url.path)
            if request.url.path == "/master.m3u8":
                return httpx.Response(
                    200,
                    text="#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia.m3u8\n",
                    headers={"content-type": "application/vnd.apple.mpegurl"},
                )
            if request.url.path == "/media.m3u8":
                return httpx.Response(
                    200,
                    text=(
                        "#EXTM3U\n"
                        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
                        "#EXTINF:4,\nsegment.ts\n"
                    ),
                    headers={"content-type": "application/vnd.apple.mpegurl"},
                )
            if request.url.path == "/key.bin":
                return httpx.Response(200, content=b"k" * 16)
            if request.url.path == "/segment.ts":
                return httpx.Response(
                    206,
                    content=b"x" * 188,
                    headers={"content-type": "video/mp2t"},
                )
            return httpx.Response(404)

        verifier = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler),
            crawler_scrapers={},
            enabled_provider_ids=frozenset(),
        )
        try:
            with patch(
                "server.aggregator._is_public_http_url",
                new=AsyncMock(return_value=True),
            ):
                evidence = await verify_media_url(
                    verifier,
                    "https://cdn.example/master.m3u8?token=secret",
                    declared_format="hls",
                )
        finally:
            await verifier.aclose()

        self.assertTrue(evidence["ok"])
        self.assertEqual(evidence["status"], "server_verified")
        self.assertEqual(evidence["startup_profile"], "hls")
        self.assertNotIn("token", evidence["url"])
        self.assertEqual(
            requested_paths,
            ["/master.m3u8", "/media.m3u8", "/key.bin", "/segment.ts"],
        )

    async def test_extensionless_mp4_is_verified_by_content(self):
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(
                206,
                content=b"\x00\x00\x00\x18ftyp" + b"x" * 32,
                headers={"content-type": "video/mp4"},
            )

        verifier = ContentAggregator(
            line_http_transport=httpx.MockTransport(handler),
            crawler_scrapers={},
            enabled_provider_ids=frozenset(),
        )
        try:
            with patch(
                "server.aggregator._is_public_http_url",
                new=AsyncMock(return_value=True),
            ):
                evidence = await verify_media_url(
                    verifier,
                    "https://cdn.example/media/opaque-token",
                )
        finally:
            await verifier.aclose()

        self.assertTrue(evidence["ok"])
        self.assertEqual(evidence["status"], "server_verified")

    def _write_candidates(self, directory: str, payload: object) -> Path:
        path = Path(directory) / "candidates.json"
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        return path

    def test_candidate_sites_load_tagged_for_review(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write_candidates(directory, {
                "sites": [
                    {"name": "新浪", "api": "https://new.example/api.php/provide/vod"},
                ],
            })
            sites = load_candidate_sites(path)

        self.assertEqual(
            sites,
            [{
                "name": "新浪",
                "api": "https://new.example/api.php/provide/vod",
                "headers": {},
                "origin": CANDIDATE_ORIGIN,
            }],
        )

    def test_candidate_loader_rejects_unusable_and_duplicate_entries(self):
        already_configured = CONFIGURED_SITES[0]["api"]
        rejected = [
            [{"name": "无接口", "api": ""}],
            [{"name": "非HTTP", "api": "ftp://new.example/api.php/provide/vod"}],
            [{"name": "", "api": "https://new.example/api.php/provide/vod"}],
            [{"name": "带凭据", "api": "https://u:p@new.example/api.php/provide/vod"}],
            [{"name": "重复", "api": already_configured}],
            [
                {"name": "自重复A", "api": "https://dup.example/api.php/provide/vod"},
                {"name": "自重复B", "api": "https://dup.example/api.php/provide/vod/"},
            ],
            [],
        ]
        with tempfile.TemporaryDirectory() as directory:
            for payload in rejected:
                path = self._write_candidates(directory, payload)
                with self.subTest(payload=payload):
                    with self.assertRaises(ValueError):
                        load_candidate_sites(path)

    async def test_cli_refuses_to_probe_before_reading_candidates(self):
        with self.assertRaises(SystemExit):
            await main(["--include-configured"])
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "absent.json"
            with self.assertRaises(SystemExit):
                await main(["--candidates", str(missing)])

    def test_report_counts_the_probed_set_not_the_configured_table(self):
        report = build_report([], candidate_count=2)

        self.assertEqual(report["candidate_count"], 2)

    def test_structured_report_is_json_and_contains_no_signed_query(self):
        report = build_report([
            {
                "name": "测试站",
                "api": "https://source.example/api.php/provide/vod",
                "search": True,
                "detail": True,
                "playable": ["番剧"],
                "checks": {
                    "番剧": [{
                        "url": "https://cdn.example/master.m3u8",
                        "ok": True,
                        "format": "hls",
                        "note": "verified_hls",
                    }],
                },
                "latency_seconds": 1.2,
                "note": "",
            },
        ])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "probe.json"
            write_json_report(path, report)
            decoded = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(decoded["schema"], "zeluna.maccms-probe.v1")
        self.assertEqual(decoded["results"][0]["playable"], ["番剧"])


if __name__ == "__main__":
    unittest.main()
