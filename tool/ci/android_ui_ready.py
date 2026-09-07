"""Require a rendered Zeluna home before accepting Android CI screenshots."""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

PACKAGE = "app.anime.anime"
REMOTE_XML = "/sdcard/zeluna-ci-window.xml"


def is_home_visible(xml: str) -> bool:
    """Check actual app navigation, not the launcher or startup semantics."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return False
    labels = set()
    for node in root.iter("node"):
        if node.get("package") != PACKAGE or node.get("visible-to-user") == "false":
            continue
        for attribute in ("text", "content-desc"):
            labels.update(part.strip() for part in node.get(attribute, "").splitlines())
    if "Zeluna 正在启动" in labels:
        return False
    # Shared navigation also appears on search/error pages. The home toolbar's
    # calendar action is rendered only after the startup data gate has opened.
    return {"首页", "新番时间表"} <= labels and bool(labels & {"我的", "我的内容"})


def wait_for_home(output: Path, timeout: float, adb: str = "adb") -> None:
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout must be finite and positive")
    deadline = time.monotonic() + timeout
    last_error = "home navigation has not appeared"

    def run(*args: str) -> str:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Android home readiness deadline exceeded")
        result = subprocess.run(
            [adb, *args],
            check=True,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=min(15.0, remaining),
        )
        return result.stdout

    while time.monotonic() < deadline:
        try:
            # A failed dump must never reuse a previous orientation's UI tree.
            run("shell", "rm", "-f", REMOTE_XML)
            run("shell", "uiautomator", "dump", REMOTE_XML)
            xml = run("exec-out", "cat", REMOTE_XML)
            output.write_text(xml, encoding="utf-8")
            if is_home_visible(xml) and time.monotonic() < deadline:
                return
            last_error = "home navigation has not appeared"
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            # Retry slow emulator/accessibility startup, without logging adb output.
            last_error = "adb UI dump was not available before the attempt deadline"
        except TimeoutError:
            break
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(1.0, remaining))
    raise TimeoutError(f"Zeluna home not ready within {timeout:g}s: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    try:
        wait_for_home(args.output, args.timeout)
    except (TimeoutError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f"Zeluna home navigation is visible; UI evidence: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
