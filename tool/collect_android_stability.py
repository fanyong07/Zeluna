"""Collect app-scoped Android diagnostics without installing or clearing data.

Run after reproducing a crash: python tool/collect_android_stability.py --serial SERIAL
No bugreport, screenshots, user files, tokens or other apps' logcat are collected.
Review the redacted output before sharing: free-form messages can contain titles.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
from pathlib import Path

PACKAGE = "app.anime.anime"


def redact(text: str) -> str:
    text = re.sub(r"(?i)https?://[^\s\"'<>]+", "[URL]", text)
    text = re.sub(r"(?i)\b(?:bearer|basic)\s+[a-z0-9._~+/=-]+", "[AUTH]", text)
    text = re.sub(
        r"(?im)(authorization|cookie|set-cookie|token|password|secret)\s*[:=].*$",
        r"\1=[REDACTED]",
        text,
    )
    return text


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Exact adb device serial")
    parser.add_argument("--adb", default="adb", help="Path to adb executable")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = args.output or Path(".codex_tmp") / f"android-diagnostics-{timestamp}"
    output.mkdir(parents=True, exist_ok=False)

    def adb(*command: str) -> tuple[int, str]:
        done = subprocess.run(
            [args.adb, "-s", args.serial, *command],
            capture_output=True,
            timeout=40,
            check=False,
        )
        text = (done.stdout + done.stderr).decode("utf-8", errors="replace")
        return done.returncode, text

    code, package = adb("shell", "dumpsys", "package", PACKAGE)
    uid = re.search(r"\buserId=(\d+)", package)
    if code or uid is None:
        raise SystemExit("App package not found on the specified device; no logs collected.")
    metadata = {
        "utc": timestamp,
        "package": PACKAGE,
        "package_metadata": [
            line.strip()
            for line in package.splitlines()
            if any(key in line for key in ("versionCode=", "versionName=", "firstInstallTime="))
        ],
        "properties": {},
        "commands": [],
    }
    for prop in ("ro.product.model", "ro.product.manufacturer", "ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abilist"):
        status, value = adb("shell", "getprop", prop)
        metadata["properties"][prop] = value.strip() if status == 0 else "unavailable"
    for name, command in (
        ("exit-info", ("shell", "dumpsys", "activity", "exit-info", PACKAGE)),
        ("memory", ("shell", "dumpsys", "meminfo", PACKAGE)),
        ("frames", ("shell", "dumpsys", "gfxinfo", PACKAGE)),
        ("logcat", ("logcat", "-d", "-b", "main", "-b", "system", "-b", "crash", "--uid=" + uid.group(1), "-t", "2500", "-v", "threadtime")),
    ):
        status, text = adb(*command)
        # If UID filtering is unsupported, preserve that error. Never fall back
        # to capturing every app's logcat or a whole-device bugreport.
        (output / f"{name}.txt").write_text(redact(text), encoding="utf-8")
        metadata["commands"].append({"name": name, "exit_code": status})
    (output / "summary.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"App-scoped diagnostics saved to {output.resolve()}")
    print("Review free-form messages before sharing. No install/uninstall/data-clear commands ran.")


if __name__ == "__main__":
    main()
