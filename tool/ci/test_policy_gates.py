from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tool.ci.dependency_gate import (
    classify_license,
    denied_license,
    flutter_sbom,
    pub_advisory_violations,
)
from tool.ci.repository_gate import path_violation, scan_files


class RepositoryGateTests(unittest.TestCase):
    def test_rejects_private_artifacts_but_allows_examples(self) -> None:
        self.assertIsNotNone(path_violation("server/.env"))
        self.assertIsNotNone(path_violation(".env"))
        self.assertIsNotNone(path_violation("android/release.jks"))
        self.assertIsNotNone(path_violation("backups/users.sqlite"))
        self.assertIsNone(path_violation("server/.env.example"))
        self.assertIsNone(path_violation("android/key.properties.example"))

    def test_reports_secret_file_without_echoing_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = "-----BEGIN " + "PRIVATE KEY-----"
            (root / "tracked.txt").write_text(marker, encoding="utf-8")
            violations = scan_files(root, ["tracked.txt"])
        self.assertEqual(violations, ["strong secret marker: tracked.txt"])
        self.assertNotIn(marker, violations[0])


class DependencyGateTests(unittest.TestCase):
    def test_advisory_and_retraction_are_failures(self) -> None:
        payload = {
            "packages": [
                {
                    "package": "unsafe",
                    "isCurrentAffectedByAdvisory": True,
                    "isCurrentRetracted": False,
                },
                {
                    "package": "retracted",
                    "isCurrentAffectedByAdvisory": False,
                    "isCurrentRetracted": True,
                },
            ]
        }
        self.assertEqual(len(pub_advisory_violations(payload)), 2)

    def test_license_classification_and_denial(self) -> None:
        self.assertEqual(
            classify_license("Permission is hereby granted, free of charge"),
            "MIT",
        )
        marker = "GNU " + "GENERAL PUBLIC LICENSE"
        self.assertEqual(denied_license(marker), marker)

    def test_flutter_sbom_is_deterministic_and_has_dependencies(self) -> None:
        payload = {
            "packages": [
                {
                    "name": "app",
                    "version": "1.0.0",
                    "source": "root",
                    "dependencies": ["http"],
                },
                {
                    "name": "http",
                    "version": "1.0.0",
                    "source": "hosted",
                    "dependencies": [],
                },
            ]
        }
        first = flutter_sbom(payload)
        second = flutter_sbom(payload)
        self.assertEqual(first, second)
        self.assertEqual(first["bomFormat"], "CycloneDX")
        self.assertEqual(first["dependencies"][0]["dependsOn"], ["pkg:pub/http@1.0.0"])


if __name__ == "__main__":
    unittest.main()
