"""Read-only APK footprint accounting. No extraction, repacking, or estimates.

Run: python tool/apk_size_report.py PATH.apk [--output report.json]
Byte totals use ZIP compressed_size, with signing/alignment/ZIP overhead separate.
This report is not a release receipt or evidence of installed size/launch speed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path
from zipfile import ZipFile


def _category(name: str) -> str:
    parts = name.split("/")
    if len(parts) >= 3 and parts[0] == "lib":
        return "native/" + parts[1]
    if name.endswith((".ttf", ".otf", ".woff", ".woff2")):
        return "fonts"
    if "/assets/brand/" in name:
        return "brand"
    if name.endswith(".dex"):
        return "dex"
    if name.startswith("assets/flutter_assets/"):
        return "flutter_other"
    return "android_other"


def inspect_apk(path: Path) -> dict:
    totals: dict[str, dict[str, int]] = defaultdict(
        lambda: {"entries": 0, "compressed_bytes": 0, "uncompressed_bytes": 0}
    )
    with ZipFile(path) as archive:
        names: set[str] = set()
        for entry in archive.infolist():
            if entry.filename in names:
                raise ValueError("Duplicate APK entry; accounting would be ambiguous")
            names.add(entry.filename)
            if entry.is_dir():
                continue
            group = totals[_category(entry.filename)]
            group["entries"] += 1
            group["compressed_bytes"] += entry.compress_size
            group["uncompressed_bytes"] += entry.file_size
        if "AndroidManifest.xml" not in names:
            raise ValueError("Not an APK: AndroidManifest.xml is missing")
    file_bytes = path.stat().st_size
    payload_bytes = sum(row["compressed_bytes"] for row in totals.values())
    if payload_bytes > file_bytes:
        raise ValueError("Invalid APK: declared compressed payload exceeds file size")
    with path.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "schema": "zeluna.apk-size.v1",
        "artifact": path.name,
        "sha256": sha256,
        "bytes": file_bytes,
        "compressed_payload_bytes": payload_bytes,
        "archive_overhead_bytes": file_bytes - payload_bytes,
        "native_abis": sorted(key[7:] for key in totals if key.startswith("native/")),
        "categories": dict(sorted(totals.items())),
        "startup_artwork_present": any(
            name.endswith(("zeluna_android_splash.png", "zeluna_launch_background.png"))
            for name in names
        ),
        "note": "Actual APK bytes only; not installed size, performance, or release attestation.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = inspect_apk(args.apk)
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        # A previous baseline is evidence; never silently overwrite it.
        with args.output.open("x", encoding="utf-8") as stream:
            stream.write(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
