"""Audit dependency advisories/licenses and emit a Flutter CycloneDX SBOM."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import shutil
import subprocess
import tomllib
import urllib.parse
import urllib.request
import uuid
from collections.abc import Iterable
from pathlib import Path
from typing import Any


_DENIED_LICENSE_MARKERS = (
    "GNU AFFERO GENERAL PUBLIC LICENSE",
    "GNU GENERAL PUBLIC LICENSE",
    "GNU LESSER GENERAL PUBLIC LICENSE",
    "SERVER SIDE PUBLIC LICENSE",
)
_LICENSE_NAMES = (
    ("Apache-2.0", "APACHE LICENSE", "VERSION 2.0"),
    ("MIT", "PERMISSION IS HEREBY GRANTED, FREE OF CHARGE"),
    ("BSD", "REDISTRIBUTION AND USE IN SOURCE AND BINARY FORMS"),
    ("MPL-2.0", "MOZILLA PUBLIC LICENSE"),
    ("ISC", "PERMISSION TO USE, COPY, MODIFY, AND/OR DISTRIBUTE"),
    ("BSL-1.0", "BOOST SOFTWARE LICENSE"),
    ("Zlib", "THIS SOFTWARE IS PROVIDED 'AS-IS'"),
    ("OFL-1.1", "SIL OPEN FONT LICENSE"),
    ("Unicode-DFS-2016", "UNICODE, INC. LICENSE AGREEMENT"),
)


def _resolved_command(command: list[str]) -> list[str]:
    executable = shutil.which(command[0])
    if executable is None:
        raise RuntimeError(f"Required command is not available: {command[0]}")
    if os.name == "nt" and Path(executable).suffix.lower() in {".bat", ".cmd"}:
        return ["cmd.exe", "/d", "/s", "/c", executable, *command[1:]]
    return [executable, *command[1:]]


def _run_json(command: list[str], cwd: Path) -> dict[str, Any]:
    result = subprocess.run(
        _resolved_command(command),
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return json.loads(result.stdout)


def pub_advisory_violations(payload: dict[str, Any]) -> list[str]:
    violations: list[str] = []
    for package in payload.get("packages", []):
        name = str(package.get("package", "unknown"))
        if package.get("isCurrentRetracted") is True:
            violations.append(f"retracted current Dart package: {name}")
        if package.get("isCurrentAffectedByAdvisory") is True:
            violations.append(f"advisory affects current Dart package: {name}")
    return violations


def audit_pub_advisories(root: Path) -> list[str]:
    return pub_advisory_violations(
        _run_json(["dart", "pub", "outdated", "--json"], root)
    )


def classify_license(text: str) -> str:
    upper = text.upper()
    for license_name, *markers in _LICENSE_NAMES:
        if all(marker in upper for marker in markers):
            return license_name
    return "Other"


def denied_license(text: str) -> str | None:
    upper = text.upper()
    return next((marker for marker in _DENIED_LICENSE_MARKERS if marker in upper), None)


def _file_uri_path(value: str, base: Path) -> Path:
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme == "file":
        decoded = urllib.request.url2pathname(parsed.path)
        if parsed.netloc:
            decoded = f"//{parsed.netloc}{decoded}"
        if len(decoded) >= 3 and decoded[0] == "/" and decoded[2] == ":":
            decoded = decoded[1:]
        return Path(decoded).resolve()
    return (base / urllib.parse.unquote(value)).resolve()


def _license_files(package_root: Path) -> list[Path]:
    candidates: list[Path] = []
    for pattern in ("LICENSE*", "COPYING*"):
        candidates.extend(path for path in package_root.glob(pattern) if path.is_file())
    return sorted(set(candidates))


def audit_flutter_licenses(root: Path) -> tuple[list[str], list[dict[str, str]]]:
    dependencies = _run_json(["dart", "pub", "deps", "--json"], root)
    package_config_path = root / ".dart_tool" / "package_config.json"
    package_config = json.loads(package_config_path.read_text(encoding="utf-8"))
    roots = {
        item["name"]: _file_uri_path(item["rootUri"], package_config_path.parent)
        for item in package_config.get("packages", [])
    }
    violations: list[str] = []
    report: list[dict[str, str]] = []
    for package in dependencies.get("packages", []):
        name = str(package.get("name", ""))
        source = str(package.get("source", ""))
        if source in {"root", "sdk"}:
            continue
        package_root = roots.get(name)
        if package_root is None:
            violations.append(f"Dart package root is missing: {name}")
            continue
        license_files = _license_files(package_root)
        if not license_files:
            violations.append(f"Dart package license is missing: {name}")
            continue
        text = "\n".join(
            path.read_text(encoding="utf-8", errors="ignore") for path in license_files
        )
        classification = classify_license(text)
        denied = denied_license(text) if classification == "Other" else None
        if denied is not None:
            violations.append(f"denied Dart package license ({denied}): {name}")
        report.append(
            {
                "name": name,
                "version": str(package.get("version", "unknown")),
                "license": classification,
                "source": source,
            }
        )
    return violations, sorted(report, key=lambda item: item["name"].lower())


def _normalized_name(value: str) -> str:
    return value.lower().replace("_", "-").replace(".", "-")


def _python_license_text(distribution: importlib.metadata.Distribution) -> str:
    metadata = distribution.metadata
    values = [metadata.get("License-Expression", ""), metadata.get("License", "")]
    values.extend(metadata.get_all("Classifier") or [])
    return "\n".join(value for value in values if value)


def audit_python_licenses(
    server_root: Path,
) -> tuple[list[str], list[dict[str, str]]]:
    lock = tomllib.loads((server_root / "uv.lock").read_text(encoding="utf-8"))
    names = {
        _normalized_name(str(package["name"]))
        for package in lock.get("package", [])
        if package.get("source", {}).get("virtual") is None
    }
    installed = {
        _normalized_name(distribution.metadata["Name"]): distribution
        for distribution in importlib.metadata.distributions()
        if distribution.metadata.get("Name")
    }
    violations: list[str] = []
    report: list[dict[str, str]] = []
    for name in sorted(names):
        distribution = installed.get(name)
        if distribution is None:
            # uv.lock is universal; platform-specific packages are intentionally
            # absent from the current environment and checked on their runner.
            continue
        license_text = _python_license_text(distribution)
        if not license_text.strip():
            violations.append(f"Python package license metadata is missing: {name}")
            continue
        denied = denied_license(license_text)
        if denied is not None:
            violations.append(f"denied Python package license ({denied}): {name}")
        report.append(
            {
                "name": distribution.metadata["Name"],
                "version": distribution.version,
                "license": classify_license(license_text),
            }
        )
    return violations, report


def _component_ref(name: str, version: str, source: str) -> str:
    ecosystem = "pub" if source == "hosted" else "generic"
    return f"pkg:{ecosystem}/{name}@{version}"


def flutter_sbom(payload: dict[str, Any]) -> dict[str, Any]:
    components: list[dict[str, Any]] = []
    dependencies: list[dict[str, Any]] = []
    refs: dict[str, str] = {}
    packages = payload.get("packages", [])
    for package in packages:
        name = str(package.get("name", "unknown"))
        version = str(package.get("version", "unknown"))
        source = str(package.get("source", "unknown"))
        ref = _component_ref(name, version, source)
        refs[name] = ref
        component: dict[str, Any] = {
            "type": "application" if source == "root" else "library",
            "bom-ref": ref,
            "name": name,
            "version": version,
            "properties": [{"name": "dart:source", "value": source}],
        }
        if source == "hosted":
            component["purl"] = ref
        components.append(component)
    for package in packages:
        name = str(package.get("name", "unknown"))
        ref = refs.get(name)
        if ref is None:
            continue
        dependencies.append(
            {
                "ref": ref,
                "dependsOn": sorted(
                    refs[item]
                    for item in package.get("dependencies", [])
                    if item in refs
                ),
            }
        )
    seed = "\n".join(sorted(refs.values()))
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, seed)}",
        "version": 1,
        "components": sorted(components, key=lambda item: item["bom-ref"]),
        "dependencies": sorted(dependencies, key=lambda item: item["ref"]),
    }


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _print_violations(violations: Iterable[str]) -> int:
    items = sorted(set(violations))
    if not items:
        return 0
    print("Dependency policy gate failed:")
    for item in items:
        print(f"- {item}")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--server-root", type=Path)
    parser.add_argument("--report-dir", type=Path, default=Path("build/reports"))
    parser.add_argument(
        "--sbom", type=Path, default=Path("build/sbom/flutter.cdx.json")
    )
    args = parser.parse_args()
    root = args.root.resolve()
    server_root = (args.server_root or root / "server").resolve()
    report_dir = (root / args.report_dir).resolve()
    sbom_path = (root / args.sbom).resolve()

    violations = audit_pub_advisories(root)
    dart_violations, dart_report = audit_flutter_licenses(root)
    python_violations, python_report = audit_python_licenses(server_root)
    violations.extend(dart_violations)
    violations.extend(python_violations)
    write_json(report_dir / "flutter-licenses.json", dart_report)
    write_json(report_dir / "python-licenses.json", python_report)
    write_json(
        sbom_path, flutter_sbom(_run_json(["dart", "pub", "deps", "--json"], root))
    )
    if _print_violations(violations):
        return 1
    print(
        "Dependency policy gate passed "
        f"({len(dart_report)} Dart, {len(python_report)} Python packages)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
