"""Reject sensitive or generated artifacts from the tracked repository."""

from __future__ import annotations

import argparse
import re
import subprocess
from collections.abc import Iterable
from pathlib import Path, PurePosixPath


_FORBIDDEN_SUFFIXES = {
    ".aab",
    ".apk",
    ".appx",
    ".backup",
    ".bak",
    ".db",
    ".dump",
    ".ipa",
    ".jks",
    ".key",
    ".keystore",
    ".mobileprovision",
    ".msix",
    ".p12",
    ".pfx",
    ".sqlite",
    ".sqlite3",
}
_FORBIDDEN_NAMES = {
    "android/key.properties",
    "android/keystore-password.txt",
}
_PACKAGE_SUFFIXES = {".aab", ".apk", ".appx", ".ipa", ".msix"}
_STRONG_SECRET_PATTERNS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"sk-(?:proj|ant)-[A-Za-z0-9_-]{16,}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"AIza[0-9A-Za-z_-]{20,}"),
)


def _normalized(path: Path) -> str:
    value = PurePosixPath(path.as_posix()).as_posix()
    return value[2:] if value.startswith("./") else value


def _is_example_environment(path: PurePosixPath) -> bool:
    return path.name.endswith(".example") or path.name.endswith(".sample")


def path_violation(relative_path: str) -> str | None:
    path = PurePosixPath(relative_path)
    normalized = path.as_posix()
    if normalized.startswith("./"):
        normalized = normalized[2:]
    lower = normalized.lower()
    name = path.name.lower()
    suffix = path.suffix.lower()
    if lower in _FORBIDDEN_NAMES:
        return "private signing configuration"
    if (name == ".env" or name.startswith(".env.")) and not _is_example_environment(
        path
    ):
        return "real environment file"
    if suffix in _PACKAGE_SUFFIXES:
        return "built application package"
    if suffix in _FORBIDDEN_SUFFIXES:
        return "credential, signing, or database artifact"
    if name.endswith(".pre-migration.db"):
        return "database backup"
    return None


def scan_files(root: Path, relative_paths: Iterable[str]) -> list[str]:
    violations: list[str] = []
    for raw_path in relative_paths:
        relative = _normalized(Path(raw_path))
        reason = path_violation(relative)
        if reason is not None:
            violations.append(f"{reason}: {relative}")
            continue
        file_path = root / Path(relative)
        if not file_path.is_file():
            continue
        try:
            content = file_path.read_bytes()
        except OSError as error:
            violations.append(f"unreadable tracked file: {relative} ({error})")
            continue
        if any(pattern.search(content) for pattern in _STRONG_SECRET_PATTERNS):
            violations.append(f"strong secret marker: {relative}")
    return sorted(set(violations))


def tracked_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return [
        item.decode("utf-8", errors="surrogateescape")
        for item in result.stdout.split(b"\0")
        if item
    ]


def scan_repository(root: Path) -> list[str]:
    return scan_files(root, tracked_files(root))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    violations = scan_repository(root)
    if violations:
        print("Repository security gate failed:")
        for violation in violations:
            print(f"- {violation}")
        return 1
    print("Repository security gate passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
