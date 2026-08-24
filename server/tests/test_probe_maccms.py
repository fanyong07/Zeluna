import json
import re
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlparse
from unittest.mock import AsyncMock, patch

import httpx

from server.aggregator import ContentAggregator
from tools.maccms_coverage import DEFAULT_CANDIDATE_REGISTRY_PATH
from tools.probe_maccms import (
    CANDIDATE_ORIGIN,
    CONFIGURED_SITES,
    _redacted_url,
    build_report,
    load_candidate_sites,
    main,
    parse_first_media_urls,
    verify_media_url,
    write_json_report,
)


class MacCmsProbeTests(unittest.IsolatedAsyncioTestCase):
    def test_report_url_redaction_removes_query_fragment_and_userinfo(self):
        self.assertEqual(
            _redacted_url(
                "https://user:password@[2001:db8::1]:8443/video.m3u8"
                "?token=secret#fragment"
            ),
            "https://[2001:db8::1]:8443/video.m3u8",
        )

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

    def _candidate_site(
        self,
        *,
        name: str = "候选源",
        api: str = "https://new.example/api.php/provide/vod",
        **overrides: object,
    ) -> dict[str, object]:
        site: dict[str, object] = {
            "name": name,
            "api": api,
            "discovered_from": (
                "https://github.com/example/repo/blob/"
                "0123456789abcdef0123456789abcdef01234567/candidates.json"
            ),
            "review_status": "candidate",
            "notes": "fixture candidate",
        }
        site.update(overrides)
        return site

    def _candidate_registry(
        self,
        sites: list[dict[str, object]],
        **policy_overrides: object,
    ) -> dict[str, object]:
        policy: dict[str, object] = {
            "logical_candidate_count": len(sites),
            "excluded_mirror_alias_count": 0,
            "production_table_separate": True,
            "automatic_promotion": False,
        }
        policy.update(policy_overrides)
        return {
            "schema": "zeluna.maccms-candidates.v1",
            "generated_on": "2026-08-24",
            "source_document": "docs/research/candidates.md",
            "policy": policy,
            "source_references": {},
            "sites": sites,
        }

    def test_candidate_sites_load_tagged_for_review(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write_candidates(
                directory,
                self._candidate_registry([
                    self._candidate_site(
                        name="新浪",
                        api="https://new.example/api.php/provide/vod",
                    ),
                ]),
            )
            sites = load_candidate_sites(path)

        self.assertEqual(
            sites,
            [{
                "name": "新浪",
                "api": "https://new.example/api.php/provide/vod",
                "headers": {},
                "origin": CANDIDATE_ORIGIN,
                "discovered_from": (
                    "https://github.com/example/repo/blob/"
                    "0123456789abcdef0123456789abcdef01234567/"
                    "candidates.json"
                ),
                "review_status": "candidate",
                "notes": "fixture candidate",
            }],
        )

    def test_default_candidate_registry_has_independent_review_only_leads(self):
        payload = json.loads(
            DEFAULT_CANDIDATE_REGISTRY_PATH.read_text(encoding="utf-8")
        )
        sites = load_candidate_sites(DEFAULT_CANDIDATE_REGISTRY_PATH)

        self.assertGreaterEqual(len(sites), 80)
        self.assertLessEqual(len(sites), 150)
        self.assertEqual(payload["policy"]["logical_candidate_count"], len(sites))
        self.assertEqual(payload["policy"]["excluded_mirror_alias_count"], 20)
        self.assertIs(payload["policy"]["automatic_promotion"], False)
        self.assertIs(payload["policy"]["production_table_separate"], True)
        self.assertEqual(len({site["name"].casefold() for site in sites}), len(sites))
        self.assertEqual(
            len({site["api"].rstrip("/").casefold() for site in sites}),
            len(sites),
        )
        hosts = {urlparse(site["api"]).hostname.casefold() for site in sites}
        configured_hosts = {
            urlparse(site["api"]).hostname.casefold()
            for site in CONFIGURED_SITES
        }
        self.assertEqual(len(hosts), len(sites))
        self.assertTrue(hosts.isdisjoint(configured_hosts))
        for site in sites:
            parsed = urlparse(site["api"])
            self.assertEqual(parsed.scheme, "https")
            self.assertFalse(parsed.query)
            self.assertFalse(parsed.fragment)
            self.assertEqual(site["review_status"], "candidate")
            self.assertTrue(site["notes"])
            self.assertRegex(
                site["discovered_from"],
                re.compile(r"^https://github\.com/.+/blob/[0-9a-f]{40}/"),
            )

        forbidden_keys = {"authorization", "cookie", "token", "password", "secret"}

        def visit(value: object) -> None:
            if isinstance(value, dict):
                for key, nested in value.items():
                    self.assertNotIn(str(key).casefold(), forbidden_keys)
                    visit(nested)
            elif isinstance(value, list):
                for nested in value:
                    visit(nested)

        visit(payload)

    def test_candidate_loader_rejects_unusable_and_duplicate_entries(self):
        already_configured = CONFIGURED_SITES[0]["api"]
        rejected = [
            [self._candidate_site()],
            self._candidate_registry([], logical_candidate_count=0),
            {
                **self._candidate_registry([self._candidate_site()]),
                "schema": "unsupported",
            },
            self._candidate_registry(
                [self._candidate_site()],
                logical_candidate_count=2,
            ),
            self._candidate_registry(
                [self._candidate_site()],
                automatic_promotion=True,
            ),
            self._candidate_registry([self._candidate_site(name="无接口", api="")]),
            self._candidate_registry([
                self._candidate_site(
                    name="非HTTP",
                    api="ftp://new.example/api.php/provide/vod",
                ),
            ]),
            self._candidate_registry([
                self._candidate_site(
                    name="带查询",
                    api="https://query.example/api.php?token=secret",
                ),
            ]),
            self._candidate_registry([
                self._candidate_site(
                    name="来源查询凭据",
                    api="https://provenance.example/api.php/provide/vod",
                    discovered_from=(
                        "https://github.com/example/repo/blob/"
                        "0123456789abcdef0123456789abcdef01234567/"
                        "candidates.json?token=secret"
                    ),
                ),
            ]),
            self._candidate_registry([
                self._candidate_site(
                    name="未固定来源提交",
                    api="https://branch.example/api.php/provide/vod",
                    discovered_from=(
                        "https://github.com/example/repo/blob/main/"
                        "candidates.json"
                    ),
                ),
            ]),
            {
                **self._candidate_registry([self._candidate_site()]),
                "source_references": {
                    "G1": "https://github.com/example/repo?token=secret",
                },
            },
            {
                **self._candidate_registry([self._candidate_site()]),
                "source_references": {
                    "G1": (
                        "https://github.com/example/repo/blob/main/"
                        "candidates.json"
                    ),
                },
            },
            self._candidate_registry([
                self._candidate_site(
                    name="IP地址",
                    api="https://203.0.113.10/api.php/provide/vod",
                ),
            ]),
            self._candidate_registry([
                self._candidate_site(name="", api="https://empty.example/api"),
            ]),
            self._candidate_registry([
                self._candidate_site(
                    name="带凭据",
                    api="https://u:p@credentials.example/api.php/provide/vod",
                ),
            ]),
            self._candidate_registry([{
                **self._candidate_site(
                    name="带授权头",
                    api="https://auth.example/api.php/provide/vod",
                ),
                "headers": {"Authorization": "must-not-load"},
            }]),
            self._candidate_registry([{
                **self._candidate_site(
                    name="未知敏感字段",
                    api="https://secret.example/api.php/provide/vod",
                ),
                "token": "must-not-load",
            }]),
            self._candidate_registry([
                self._candidate_site(name="重复", api=already_configured),
            ]),
            self._candidate_registry([
                self._candidate_site(
                    name="自重复A",
                    api="https://dup.example/api.php/provide/vod",
                ),
                self._candidate_site(
                    name="自重复B",
                    api="https://dup.example/alternate/api.php/provide/vod",
                ),
            ]),
            self._candidate_registry([{
                key: value
                for key, value in self._candidate_site().items()
                if key != "discovered_from"
            }]),
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
        report = build_report(
            [],
            candidate_count=2,
            registered_candidate_count=80,
        )

        self.assertEqual(report["candidate_count"], 2)
        self.assertEqual(report["selected_source_count"], 2)
        self.assertEqual(report["source_inventory"]["candidate_source_count"], 80)
        self.assertEqual(
            report["source_inventory"]["smoke_completed_source_count"],
            0,
        )

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
