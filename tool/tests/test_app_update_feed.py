"""Offline stdlib tests: synthetic manifests only, all writes in tempfile trees."""

from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


TOOL_PATH = Path(__file__).resolve().parents[1] / "create_app_update_feed.py"
SPEC = importlib.util.spec_from_file_location("create_app_update_feed", TOOL_PATH)
feed_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed_tool)


def release_manifest():
    return {
        "schema": "zeluna-release-manifest-v2",
        "version": "1.3.2+88",
        "git_sha": "a" * 40,
        "generated_utc": "2026-11-05T22:13:48.0484678Z",
        "ci_run_id": "123456789",
        "ci_run_url": "https://github.com/fanyong07/Zeluna/actions/runs/123456789",
        "quality_workflow": "Quality Gates",
        "artifacts": [
            {
                "name": "Zeluna-v1.3.2-Android.apk",
                "path": "release/old-machine/missing.apk",
                "bytes": 133140679,
                "sha256": "AB" * 32,
                "native_abis": ["arm64-v8a", "armeabi-v7a", "x86_64"],
                "legacy_debug_signing": True,
                "build_receipt_sha256": "c" * 64,
            },
            {"name": "Zeluna-v1.3.2-Windows.zip", "path": "unused.zip"},
        ],
    }


class FeedTestCase(unittest.TestCase):
    def setUp(self):
        # A future accidental network dependency must fail, even in happy paths.
        for target in ("socket.socket", "socket.create_connection", "socket.getaddrinfo"):
            patcher = patch(target, side_effect=AssertionError("Network I/O in an offline tool"))
            patcher.start()
            self.addCleanup(patcher.stop)


class BuildUpdateFeedTests(FeedTestCase):
    def test_exact_output_schema_and_github_defaults(self):
        manifest = release_manifest()
        original = deepcopy(manifest)
        result = feed_tool.build_update_feed(manifest, notes="Release notes / 更新说明")
        self.assertEqual(result, {
            "schema": "zeluna-app-update-v1",
            "platform": "android",
            "package_name": "app.anime.anime",
            "version": "1.3.2",
            "build_number": 88,
            "apk": {
                "url": "https://github.com/fanyong07/Zeluna/releases/download/v1.3.2/Zeluna-v1.3.2-Android.apk",
                "sha256": "ab" * 32,
                "bytes": 133140679,
                "abis": ["arm64-v8a", "armeabi-v7a", "x86_64"],
                "min_sdk": 24,
            },
            "notes": "Release notes / 更新说明",
            "release_page": "https://github.com/fanyong07/Zeluna/releases/tag/v1.3.2",
        })
        self.assertEqual(manifest, original)
        self.assertIsNot(result["apk"]["abis"], manifest["artifacts"][0]["native_abis"])

    def test_schema_and_object_root_are_required(self):
        for value in (None, [], "manifest", {}, {"schema": "zeluna-release-manifest-v1"}):
            with self.subTest(value=value), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(value)

    def test_version_requires_canonical_xyz_and_positive_int32_build(self):
        for version in (None, 123, "1.3.2", "v1.3.2+88", "1.3+88", "01.3.2+88",
                        "1.03.2+88", "1.3.02+88", "1.3.2+088", "1.3.2+0",
                        "1.3.2+-1", "1.3.2+2147483648", "1.3.2+88\n",
                        "1.3.2-beta+88", "1.3.2+8+8", "１.3.2+88",
                        "1" * 125 + ".0.0+1"):
            manifest = release_manifest()
            manifest["version"] = version
            with self.subTest(version=version), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(manifest)
        manifest = release_manifest()
        manifest["version"] = "1.3.2+2147483647"
        self.assertEqual(feed_tool.build_update_feed(manifest)["build_number"], 2147483647)

    def test_provenance_fields_are_required(self):
        for name in ("git_sha", "generated_utc", "ci_run_id", "ci_run_url", "quality_workflow"):
            manifest = release_manifest()
            del manifest[name]
            with self.subTest(field=name), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(manifest)

    def test_invalid_provenance_is_rejected(self):
        values = {
            "git_sha": ["a" * 39, "a" * 41, "g" * 40, 123, None],
            "ci_run_id": ["", "0", "0123", "123x", True, -1, 1.0, None],
            "ci_run_url": ["http://github.com/fanyong07/Zeluna/actions/runs/123456789",
                           "https://github.com/other/repo/actions/runs/123456789",
                           "https://github.com/fanyong07/Zeluna/actions/runs/123456788",
                           "https://github.com/fanyong07/Zeluna/actions/runs/123456789#x", None],
            "quality_workflow": ["Other", "quality gates", "Quality Gates ", None],
            "generated_utc": ["", "2026-02-30T00:00:00Z", "2026-11-05", "2026-11-05T00:00:00",
                              "2026-11-05T00:00:00+08:00", None],
        }
        for field, invalid_values in values.items():
            for value in invalid_values:
                manifest = release_manifest()
                manifest[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(feed_tool.FeedError):
                    feed_tool.build_update_feed(manifest)

    def test_numeric_run_id_is_supported_and_boolean_is_not(self):
        manifest = release_manifest()
        manifest["ci_run_id"] = 123456789
        self.assertEqual(feed_tool.build_update_feed(manifest)["version"], "1.3.2")

    def test_exact_case_sensitive_apk_name_is_required(self):
        for name in ("other.apk", "Zeluna-v1.3.1-Android.apk", "Zeluna-v1.3.2-Android.apk.bak",
                     "zeluna-v1.3.2-android.apk", "../Zeluna-v1.3.2-Android.apk",
                     "Zeluna-v1.3.2+88-Android.apk", None):
            manifest = release_manifest()
            manifest["artifacts"][0]["name"] = name
            with self.subTest(name=name), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(manifest)

    def test_duplicate_exact_apk_is_rejected(self):
        manifest = release_manifest()
        manifest["artifacts"].append(deepcopy(manifest["artifacts"][0]))
        with self.assertRaisesRegex(feed_tool.FeedError, "exactly one"):
            feed_tool.build_update_feed(manifest)

    def test_artifact_collection_shape_is_checked(self):
        for artifacts in (None, {}, [], [None], [release_manifest()["artifacts"][0], "malformed"]):
            manifest = release_manifest()
            manifest["artifacts"] = artifacts
            with self.subTest(artifacts=artifacts), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(manifest)

    def test_artifact_path_and_unrelated_entries_are_not_used(self):
        manifest = release_manifest()
        manifest["artifacts"][0]["path"] = "https://127.0.0.1/../../unrelated/private.apk"
        manifest["artifacts"].append({"name": "../../evil.apk", "path": "secret", "bytes": -1})
        first = feed_tool.build_update_feed(manifest)
        del manifest["artifacts"][0]["path"]
        self.assertEqual(first, feed_tool.build_update_feed(manifest))
        self.assertNotIn("path", first["apk"])
        self.assertIn("github.com", first["apk"]["url"])

    def test_apk_bytes_and_hash_limits(self):
        for field, values in {
            "bytes": [0, -1, True, 1.5, "12", feed_tool.MAX_APK_BYTES + 1, None],
            "sha256": ["a" * 63, "a" * 65, "g" * 64, None, 123],
            "build_receipt_sha256": [None, "", "b" * 63, "z" * 64],
            "legacy_debug_signing": [None, "true", 1, 0],
        }.items():
            for value in values:
                manifest = release_manifest()
                manifest["artifacts"][0][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(feed_tool.FeedError):
                    feed_tool.build_update_feed(manifest)
        manifest = release_manifest()
        manifest["artifacts"][0]["bytes"] = feed_tool.MAX_APK_BYTES
        manifest["artifacts"][0]["legacy_debug_signing"] = False
        self.assertEqual(feed_tool.build_update_feed(manifest)["apk"]["bytes"], 512 * 1024 * 1024)

    def test_apk_signing_provenance_fields_are_required(self):
        for field in ("legacy_debug_signing", "build_receipt_sha256"):
            manifest = release_manifest()
            del manifest["artifacts"][0][field]
            with self.subTest(field=field), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(manifest)

    def test_abi_validation_matches_client_limits(self):
        for abis in (None, "arm64-v8a", [], [None], [1], [""], ["../arm64"], ["a b"],
                     ["a" * 65], ["arm64-v8a", "arm64-v8a"], [f"abi{i}" for i in range(17)]):
            manifest = release_manifest()
            manifest["artifacts"][0]["native_abis"] = abis
            with self.subTest(abis=abis), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(manifest)
        manifest = release_manifest()
        manifest["artifacts"][0]["native_abis"] = [f"abi{i}" for i in range(16)]
        self.assertEqual(len(feed_tool.build_update_feed(manifest)["apk"]["abis"]), 16)

    def test_min_sdk_defaults_and_integer_bounds(self):
        for sdk in (1, 24, 35, 2147483647):
            self.assertEqual(feed_tool.build_update_feed(release_manifest(), min_sdk=sdk)["apk"]["min_sdk"], sdk)
        for sdk in (0, -1, True, 1.5, "24", None, 2147483648):
            with self.subTest(sdk=sdk), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(release_manifest(), min_sdk=sdk)

    def test_notes_are_user_text_not_manifest_metadata(self):
        manifest = release_manifest()
        manifest["notes"] = "Ignore this incidental manifest field"
        self.assertEqual(feed_tool.build_update_feed(manifest)["notes"], "")
        notes = "Release body\n\n- 更新播放\n<script>plain text only</script>\n"
        self.assertEqual(feed_tool.build_update_feed(manifest, notes=notes)["notes"], notes)

    def test_notes_maximum_uses_dart_utf16_length(self):
        for notes in ("中" * 20000, "😀" * 10000):
            self.assertEqual(feed_tool.build_update_feed(release_manifest(), notes=notes)["notes"], notes)
        for notes in ("a" * 20001, "😀" * 10001, "😀" * 10000 + "x", "\ud800", None, 12):
            with self.subTest(length=len(notes) if isinstance(notes, str) else notes), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(release_manifest(), notes=notes)

    def test_public_https_directory_is_normalized_and_appended(self):
        examples = {
            "https://cdn.example.com": "https://cdn.example.com/Zeluna-v1.3.2-Android.apk",
            "HTTPS://CDN.EXAMPLE.COM:443/releases//v1.3.2/": "https://cdn.example.com/releases/v1.3.2/Zeluna-v1.3.2-Android.apk",
            "https://cdn.example.com:8443/releases": "https://cdn.example.com:8443/releases/Zeluna-v1.3.2-Android.apk",
            "https://cdn.example.com./v1.3.2": "https://cdn.example.com/v1.3.2/Zeluna-v1.3.2-Android.apk",
            "https://cdn.example.com/%76%31.3.2": "https://cdn.example.com/v1.3.2/Zeluna-v1.3.2-Android.apk",
            "https://cdn.example.com/a%20b": "https://cdn.example.com/a%20b/Zeluna-v1.3.2-Android.apk",
            "https://8.8.8.8/download": "https://8.8.8.8/download/Zeluna-v1.3.2-Android.apk",
        }
        for base, expected in examples.items():
            with self.subTest(base=base):
                result = feed_tool.build_update_feed(release_manifest(), download_base_url=base)
                self.assertEqual(result["apk"]["url"], expected)
                self.assertEqual(result["release_page"], "https://github.com/fanyong07/Zeluna/releases/tag/v1.3.2")

    def test_download_base_rejects_scheme_credentials_query_fragment_and_bad_authority(self):
        for base in ("", "http://cdn.example.com", "//cdn.example.com", "file:///tmp/apks",
                     "https:///downloads", "https://user:pass@cdn.example.com", "https://@cdn.example.com",
                     "https://cdn.example.com/a?x=1", "https://cdn.example.com/a?", "https://cdn.example.com/#",
                     "https://cdn.example.com/#notes", "https://cdn.example.com:99999", "https://cdn.example.com:0",
                     "https://cdn.example.com:", "https://cdn.example.com:bad", "https://[bad", " https://cdn.example.com",
                     "https://cdn.example.com\n/path", "https://cdn.example.com\\@evil.example", "https://cdn.example.com/a b",
                     "https://cdn.example.com/" + "a" * 8192):
            with self.subTest(base=base[:100]), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(release_manifest(), download_base_url=base)

    def test_download_base_rejects_private_special_and_noncanonical_hosts(self):
        hosts = ("localhost", "LOCALHOST.", "sub.localhost", "server.local", "printer",
                 "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.0.1", "169.254.1.1", "0.0.0.0",
                 "100.64.0.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1",
                 "224.0.0.1", "240.0.0.1", "[::1]", "[fc00::1]", "[fe80::1]", "[::ffff:127.0.0.1]",
                 "[2001:4860:4860::8888]", "[fe80::1%25eth0]", "127.1", "2130706433", "0177.0.0.1",
                 "0x7f000001", "0x7f.0.0.1", "%31%32%37.0.0.1", "bad_host.example", "bad..example")
        for host in hosts:
            with self.subTest(host=host), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(release_manifest(), download_base_url=f"https://{host}/apk")

    def test_download_base_rejects_traversal_and_encoded_delimiters(self):
        for path in ("/../apk", "/a/./b", "/%2e%2e/apk", "/a/%2E/b", "/a%2fb", "/a%5cb",
                     "/%252e%252e/apk", "/%25252f/apk", "/a%00b", "/a%0Ab", "/a%7fb",
                     "/a%3fb", "/a%23b", "/a%", "/a%xx", "/a%ff"):
            with self.subTest(path=path), self.assertRaises(feed_tool.FeedError):
                feed_tool.build_update_feed(release_manifest(), download_base_url="https://cdn.example.com" + path)


class FileAndCliTests(FeedTestCase):
    def setUp(self):
        super().setUp()
        temporary = tempfile.TemporaryDirectory(prefix="zeluna-update-feed-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source-manifest.json"
        self.source.write_text(json.dumps(release_manifest()), encoding="utf-8")
        self.output = self.root / "generated" / "update.json"

    def test_create_reads_only_source_manifest_and_notes(self):
        source_before = self.source.read_bytes()
        notes_file = self.root / "release-notes.md"
        notes_file.write_bytes("\ufeff更新说明\r\n- 保留原文\n".encode("utf-8"))
        notes_before = notes_file.read_bytes()
        result = feed_tool.create_update_feed(self.source, self.output, notes_file=notes_file)
        self.assertEqual(json.loads(self.output.read_text(encoding="utf-8")), result)
        self.assertEqual(result["notes"], "更新说明\r\n- 保留原文\n")
        self.assertEqual(self.source.read_bytes(), source_before)
        self.assertEqual(notes_file.read_bytes(), notes_before)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["generated", "release-notes.md", "source-manifest.json"])

    def test_utf8_bom_manifest_is_accepted(self):
        self.source.write_text("\ufeff" + json.dumps(release_manifest()), encoding="utf-8")
        self.assertEqual(feed_tool.create_update_feed(self.source, self.output)["version"], "1.3.2")

    def test_new_output_outside_repository_is_allowed(self):
        self.assertNotIn(feed_tool.PROJECT_ROOT, self.root.parents)
        feed_tool.create_update_feed(self.source, self.output)
        self.assertTrue(self.output.is_file())

    def test_existing_output_is_never_overwritten(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"immutable previous feed")
        with self.assertRaisesRegex(feed_tool.FeedError, "already exists"):
            feed_tool.create_update_feed(self.source, self.output)
        self.assertEqual(self.output.read_bytes(), b"immutable previous feed")

    def test_output_may_not_replace_input_manifest_or_notes(self):
        before = self.source.read_bytes()
        with self.assertRaises(feed_tool.FeedError):
            feed_tool.create_update_feed(self.source, self.source)
        self.assertEqual(self.source.read_bytes(), before)
        notes = self.root / "notes.txt"
        notes.write_text("release text", encoding="utf-8")
        with self.assertRaises(feed_tool.FeedError):
            feed_tool.create_update_feed(self.source, notes, notes_file=notes)
        self.assertEqual(notes.read_text(encoding="utf-8"), "release text")

    def test_output_in_release_directory_fails_before_creating_directories(self):
        for name in ("release", "Release", "RELEASE"):
            output = self.root / name / "v1.3.2" / "update.json"
            with self.subTest(name=name), self.assertRaisesRegex(feed_tool.FeedError, "release"):
                feed_tool.create_update_feed(self.source, output)
            self.assertFalse((self.root / name).exists())

    def test_release_manifest_is_readable_but_remains_immutable(self):
        release_dir = self.root / "release" / "v1.3.2"
        release_dir.mkdir(parents=True)
        manifest = release_dir / "Zeluna-v1.3.2-manifest.json"
        manifest.write_bytes(self.source.read_bytes())
        before = manifest.read_bytes()
        feed_tool.create_update_feed(manifest, self.output)
        self.assertEqual(manifest.read_bytes(), before)
        self.assertEqual(list(release_dir.iterdir()), [manifest])

    def test_exclusive_creation_is_used_even_after_preflight(self):
        real_open = Path.open
        output = self.output
        def racing_open(path, mode="r", *args, **kwargs):
            if path == output and mode == "xb":
                with real_open(path, "wb") as competitor:
                    competitor.write(b"concurrent writer")
            return real_open(path, mode, *args, **kwargs)
        with patch.object(Path, "open", racing_open), self.assertRaises(FileExistsError):
            feed_tool.create_update_feed(self.source, self.output)
        self.assertEqual(self.output.read_bytes(), b"concurrent writer")

    def test_resolved_release_alias_is_protected(self):
        alias = self.root / "alias.json"
        release_target = self.root / "release" / "new.json"
        real_resolve = Path.resolve
        def aliased_resolve(path, *args, **kwargs):
            if path == alias:
                return release_target
            return real_resolve(path, *args, **kwargs)
        # Model junction/symlink resolution without requiring Windows privileges.
        with patch.object(Path, "resolve", aliased_resolve), self.assertRaises(feed_tool.FeedError):
            feed_tool.create_update_feed(self.source, alias)
        self.assertFalse(alias.exists())

    def test_invalid_inputs_leave_no_output_directory(self):
        for raw in (b"[]", b"{", b"\xff", b'{"schema":NaN}', b'{"schema":"a","schema":"b"}',
                    json.dumps({**release_manifest(), "schema": "bad"}).encode("utf-8")):
            self.source.write_bytes(raw)
            with self.subTest(raw=raw[:60]), self.assertRaises(feed_tool.FeedError):
                feed_tool.create_update_feed(self.source, self.output)
            self.assertFalse(self.output.parent.exists())

    def test_duplicate_nested_json_key_is_rejected(self):
        raw = json.dumps(release_manifest()).replace('"bytes": 133140679', '"bytes": 1, "bytes": 133140679')
        self.source.write_text(raw, encoding="utf-8")
        with self.assertRaisesRegex(feed_tool.FeedError, "duplicate"):
            feed_tool.create_update_feed(self.source, self.output)

    def test_manifest_size_limit_prevents_unbounded_read(self):
        self.source.write_bytes(b" " * (feed_tool.MAX_JSON_BYTES + 1))
        with self.assertRaisesRegex(feed_tool.FeedError, "exceeds"):
            feed_tool.create_update_feed(self.source, self.output)
        self.assertFalse(self.output.parent.exists())

    def test_notes_invalid_utf8_overlong_or_mutually_exclusive_fail(self):
        notes = self.root / "notes.txt"
        for raw in (b"\xff", b"x" * 20001, b"x" * 80004):
            notes.write_bytes(raw)
            with self.subTest(length=len(raw)), self.assertRaises(feed_tool.FeedError):
                feed_tool.create_update_feed(self.source, self.output, notes_file=notes)
            self.assertFalse(self.output.parent.exists())
        with self.assertRaises(feed_tool.FeedError):
            feed_tool.create_update_feed(self.source, self.output, notes_file=notes, notes="other")

    def test_cli_success_with_inline_notes_and_custom_parameters(self):
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            status = feed_tool.main(["--manifest", str(self.source), "--output", str(self.output),
                                     "--notes", "用户发布说明", "--min-sdk", "26",
                                     "--download-base-url", "https://cdn.example.com/apks"])
        self.assertEqual(status, 0)
        result = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(result["notes"], "用户发布说明")
        self.assertEqual(result["apk"]["min_sdk"], 26)
        self.assertIn("https://cdn.example.com/apks/", result["apk"]["url"])
        self.assertIn("not re-verified", stdout.getvalue())

    def test_cli_success_with_notes_file_and_defaults(self):
        notes = self.root / "notes.txt"
        notes.write_text("发布说明", encoding="utf-8")
        with redirect_stdout(io.StringIO()):
            status = feed_tool.main(["--manifest", str(self.source), "--output", str(self.output), "--notes-file", str(notes)])
        self.assertEqual(status, 0)
        result = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(result["notes"], "发布说明")
        self.assertEqual(result["apk"]["min_sdk"], 24)

    def test_cli_errors_are_nonzero_and_do_not_create_output(self):
        for extra in (["--min-sdk", "0"], ["--download-base-url", "http://cdn.example.com"],
                      ["--notes-file", str(self.root / "missing.txt")]):
            stderr = io.StringIO()
            with self.subTest(extra=extra), redirect_stderr(stderr), redirect_stdout(io.StringIO()):
                self.assertEqual(feed_tool.main(["--manifest", str(self.source), "--output", str(self.output), *extra]), 1)
            self.assertIn("error:", stderr.getvalue())
            self.assertFalse(self.output.parent.exists())

    def test_cli_existing_output_is_reported_without_overwrite(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"keep")
        with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
            self.assertEqual(feed_tool.main(["--manifest", str(self.source), "--output", str(self.output)]), 1)
        self.assertEqual(self.output.read_bytes(), b"keep")

    def test_cli_missing_manifest_is_reported_without_creating_output(self):
        with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
            self.assertEqual(feed_tool.main(["--manifest", str(self.root / "missing.json"), "--output", str(self.output)]), 1)
        self.assertFalse(self.output.parent.exists())

    def test_cli_notes_arguments_are_mutually_exclusive(self):
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            feed_tool.main(["--manifest", str(self.source), "--output", str(self.output), "--notes", "text", "--notes-file", "notes.txt"])
        self.assertEqual(caught.exception.code, 2)
        self.assertFalse(self.output.parent.exists())


if __name__ == "__main__":
    unittest.main()
