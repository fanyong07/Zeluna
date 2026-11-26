from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from tool.apk_size_report import inspect_apk


class ApkSizeTests(unittest.TestCase):
    def test_accounts_for_all_bytes_without_guessing_split_size(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.apk"
            with ZipFile(path, "w", ZIP_DEFLATED) as archive:
                archive.writestr("AndroidManifest.xml", "manifest")
                archive.writestr("lib/arm64-v8a/libapp.so", b"A" * 4000)
                archive.writestr("lib/x86_64/libapp.so", b"B" * 2000)
                archive.writestr("assets/flutter_assets/assets/fonts/cjk.ttf", b"F" * 1000)
                archive.writestr("assets/flutter_assets/assets/brand/logo.png", b"PNG")
            report = inspect_apk(path)
        self.assertEqual(report["native_abis"], ["arm64-v8a", "x86_64"])
        self.assertEqual(report["categories"]["fonts"]["uncompressed_bytes"], 1000)
        self.assertLess(report["categories"]["fonts"]["compressed_bytes"], 1000)
        self.assertEqual(report["bytes"], report["compressed_payload_bytes"] + report["archive_overhead_bytes"])
        self.assertGreater(report["archive_overhead_bytes"], 0)
        self.assertFalse(report["startup_artwork_present"])
        self.assertEqual(len(report["sha256"]), 64)

    def test_detects_old_startup_artwork(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.apk"
            with ZipFile(path, "w") as archive:
                archive.writestr("AndroidManifest.xml", "manifest")
                archive.writestr("res/drawable-nodpi-v4/zeluna_launch_background.png", "image")
            self.assertTrue(inspect_apk(path)["startup_artwork_present"])

    def test_rejects_non_apk_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "not-an-apk.zip"
            with ZipFile(path, "w") as archive:
                archive.writestr("readme.txt", "not an APK")
            with self.assertRaisesRegex(ValueError, "Not an APK"):
                inspect_apk(path)


if __name__ == "__main__":
    unittest.main()
