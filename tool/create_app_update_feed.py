#!/usr/bin/env python3
"""Derive an offline Android update feed from an existing release-v2 manifest.

This is a format/provenance validation tool, not an APK verifier, signer, release
publisher, or replacement for Quality Gates. Artifact ``path`` values are never
read or used. Only a new output outside release directories may be created.
"""

from __future__ import annotations

import argparse
from datetime import datetime
import ipaddress
import json
from pathlib import Path
import re
import sys
from urllib.parse import quote, unquote, urlsplit, urlunsplit


REPOSITORY_URL = "https://github.com/fanyong07/Zeluna"
PROJECT_ROOT = Path(__file__).resolve().parents[1]
MAX_APK_BYTES = 512 * 1024 * 1024
MAX_JSON_BYTES = 512 * 1024
MAX_NOTES_LENGTH = 20000  # Dart String.length counts UTF-16 code units.
MAX_INT = 0x7FFFFFFF
VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([1-9][0-9]*)")
HASH_RE = re.compile(r"[a-fA-F0-9]{64}")
ABI_RE = re.compile(r"[a-zA-Z0-9_-]{1,64}")


class FeedError(ValueError):
    """The input or output does not satisfy the update publishing contract."""


def _integer(value: object, label: str, maximum: int = MAX_INT) -> int:
    if type(value) is not int or not 0 < value <= maximum:
        raise FeedError(f"{label} must be a positive integer <= {maximum}.")
    return value


def _hash(value: object, label: str) -> str:
    if not isinstance(value, str) or not HASH_RE.fullmatch(value):
        raise FeedError(f"{label} must be a 64-character hexadecimal SHA-256.")
    return value.lower()


def _notes(value: object) -> str:
    if not isinstance(value, str):
        raise FeedError("notes must be release text.")
    try:
        length = len(value.encode("utf-16-le")) // 2
    except UnicodeEncodeError as error:
        raise FeedError("notes must contain valid Unicode text.") from error
    if length > MAX_NOTES_LENGTH:
        raise FeedError(f"notes exceeds {MAX_NOTES_LENGTH} UTF-16 code units.")
    return value


def _provenance(manifest: dict) -> None:
    git_sha = manifest.get("git_sha")
    if not isinstance(git_sha, str) or not re.fullmatch(r"[a-fA-F0-9]{40}", git_sha):
        raise FeedError("manifest.git_sha must be a full 40-character Git SHA.")
    run_id = manifest.get("ci_run_id")
    if type(run_id) is int:
        run_id = str(run_id)
    if not isinstance(run_id, str) or not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise FeedError("manifest.ci_run_id must be a positive decimal run ID.")
    if manifest.get("ci_run_url") != f"{REPOSITORY_URL}/actions/runs/{run_id}":
        raise FeedError("manifest.ci_run_url must match this repository and ci_run_id.")
    if manifest.get("quality_workflow") != "Quality Gates":
        raise FeedError("manifest.quality_workflow must be Quality Gates.")
    timestamp = manifest.get("generated_utc")
    if not isinstance(timestamp, str) or not re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?Z",
        timestamp,
    ):
        raise FeedError("manifest.generated_utc must be an ISO-8601 UTC timestamp ending in Z.")
    try:
        datetime.fromisoformat(timestamp[:-1] + "+00:00")
    except ValueError as error:
        raise FeedError("manifest.generated_utc is not a valid timestamp.") from error


def _public_host(host: str) -> str:
    """Check literals/names syntactically; deliberately never perform DNS I/O."""
    host = host.lower().removesuffix(".")
    if not host or "%" in host:
        raise FeedError("download base host must be a public DNS name or IPv4 literal.")
    if host == "localhost" or host.endswith((".localhost", ".local")):
        raise FeedError("download base must not use a local-network host.")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        # Browsers/OS resolvers may treat these noncanonical names as IPv4.
        if re.fullmatch(r"(?:0x[0-9a-f]+|[0-9]+)(?:\.(?:0x[0-9a-f]+|[0-9]+))*", host):
            raise FeedError("download base has a noncanonical numeric host.")
        labels = host.split(".")
        if len(host) > 253 or len(labels) < 2 or any(
            not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in labels
        ) or labels[-1].isdigit():
            raise FeedError("download base host must be a fully qualified ASCII DNS name.")
        return host
    if address.version != 4:
        # The current Dart network policy rejects ordinary IPv6 literals.
        # A DNS name allows the client transport to choose IPv4/IPv6 normally.
        raise FeedError("Use a public DNS name instead of an IPv6 literal for client compatibility.")
    if not address.is_global or address.is_multicast or address.is_reserved:
        raise FeedError("download base must not use a private or special-purpose IP address.")
    return str(address)


def _download_url(base: str, apk_name: str) -> str:
    if not isinstance(base, str) or not base or len(base) > 8192:
        raise FeedError("download base URL must be a nonempty HTTPS URL <= 8192 characters.")
    if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in base):
        raise FeedError("download base URL contains whitespace or control characters.")
    if "\\" in base or "?" in base or "#" in base:
        raise FeedError("download base URL must have no backslash, query, or fragment.")
    try:
        parts = urlsplit(base)
        port = parts.port
        host = parts.hostname
        if parts.scheme.lower() != "https" or not parts.netloc or not host:
            raise FeedError("download base URL must use HTTPS with a host.")
        if parts.username is not None or parts.password is not None or "@" in parts.netloc:
            raise FeedError("download base URL must have no user information.")
        if port is not None and not 1 <= port <= 65535:
            raise FeedError("download base URL has an invalid port.")
        if parts.netloc.endswith(":"):
            raise FeedError("download base URL has an empty port.")
        host = _public_host(host)
    except ValueError as error:
        if isinstance(error, FeedError):
            raise
        raise FeedError("download base URL is malformed.") from error
    segments = []
    for segment in parts.path.split("/"):
        if not segment:
            continue
        if re.search(r"%(?![a-fA-F0-9]{2})", segment):
            raise FeedError("download base path has invalid percent encoding.")
        try:
            decoded = unquote(segment, errors="strict")
            if decoded in (".", "..") or any(character in decoded for character in "/\\%?#"):
                raise FeedError("download base path contains traversal, encoded separators, or nested encoding.")
            if any(ord(character) < 32 or ord(character) == 127 for character in decoded):
                raise FeedError("download base path contains control characters.")
            segments.append(quote(decoded, safe="-._~"))
        except UnicodeError as error:
            raise FeedError("download base path must contain valid UTF-8 text.") from error
    authority = host if port is None or port == 443 else f"{host}:{port}"
    # Never resolve an artifact path/URL with urljoin: only append the fixed,
    # version-derived basename to a normalized directory path on this authority.
    path = "/" + "/".join([*segments, apk_name])
    result = urlunsplit(("https", authority, path, "", ""))
    if len(result) > 8192:
        raise FeedError("resulting APK URL exceeds the client's 8192-character limit.")
    return result


def build_update_feed(
    manifest: object,
    *,
    notes: str = "",
    download_base_url: str | None = None,
    min_sdk: int = 24,
) -> dict:
    """Validate release claims and derive a client-compatible feed in memory."""
    if not isinstance(manifest, dict) or manifest.get("schema") != "zeluna-release-manifest-v2":
        raise FeedError("manifest.schema must be zeluna-release-manifest-v2.")
    version = manifest.get("version")
    match = VERSION_RE.fullmatch(version) if isinstance(version, str) and len(version) <= 139 else None
    if match is None:
        raise FeedError("manifest.version must be X.Y.Z+build without leading zeros.")
    display_version, build_text = version.split("+")
    if len(display_version) > 128:
        raise FeedError("manifest version exceeds the client's 128-character limit.")
    build = _integer(int(build_text), "manifest build number")
    _provenance(manifest)
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or any(not isinstance(artifact, dict) for artifact in artifacts):
        raise FeedError("manifest.artifacts must be a list of objects.")
    apk_name = f"Zeluna-v{display_version}-Android.apk"
    matches = [artifact for artifact in artifacts if artifact.get("name") == apk_name]
    if len(matches) != 1:
        raise FeedError(f"manifest must contain exactly one artifact named {apk_name}.")
    apk = matches[0]
    apk_bytes = _integer(apk.get("bytes"), "APK bytes", MAX_APK_BYTES)
    sha256 = _hash(apk.get("sha256"), "APK sha256")
    abis = apk.get("native_abis")
    if not isinstance(abis, list) or not 1 <= len(abis) <= 16 or any(
        not isinstance(abi, str) or not ABI_RE.fullmatch(abi) for abi in abis
    ) or len(set(abis)) != len(abis):
        raise FeedError("APK native_abis must have 1..16 distinct valid ABI names (1..64 characters each).")
    _hash(apk.get("build_receipt_sha256"), "APK build_receipt_sha256")
    if type(apk.get("legacy_debug_signing")) is not bool:
        raise FeedError("APK legacy_debug_signing must be an explicit boolean provenance field.")
    base = download_base_url if download_base_url is not None else f"{REPOSITORY_URL}/releases/download/v{display_version}"
    return {
        "schema": "zeluna-app-update-v1",
        "platform": "android",
        "package_name": "app.anime.anime",
        "version": display_version,
        "build_number": build,
        "apk": {
            "url": _download_url(base, apk_name),
            "sha256": sha256,
            "bytes": apk_bytes,
            "abis": list(abis),
            "min_sdk": _integer(min_sdk, "min_sdk"),
        },
        "notes": _notes(notes),
        "release_page": f"{REPOSITORY_URL}/releases/tag/v{display_version}",
    }


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise FeedError(f"JSON contains a duplicate key: {key}")
        result[key] = value
    return result


def _invalid_constant(value: str) -> object:
    raise FeedError(f"JSON contains a nonstandard numeric constant: {value}")


def _read_utf8(path: Path, maximum: int, label: str) -> str:
    with path.open("rb") as source:
        raw = source.read(maximum + 1)
    if len(raw) > maximum:
        raise FeedError(f"{label} exceeds {maximum} bytes.")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise FeedError(f"{label} must be UTF-8 text.") from error


def _output_path(path: Path) -> Path:
    # Check both lexical and resolved paths: symlink/junction aliases of a
    # release directory are protected too. Existing files are also protected by
    # exclusive creation, including dangling symlinks and hard-link aliases.
    absolute = path.absolute()
    resolved = path.resolve()
    release_root = (PROJECT_ROOT / "release").resolve()
    for candidate in (absolute, resolved):
        if any(part.casefold() == "release" for part in candidate.parts):
            raise FeedError("output must stay outside release directories.")
        if candidate == release_root or release_root in candidate.parents:
            raise FeedError("output must stay outside the immutable release tree.")
        if sys.platform == "win32" and any(
            part.endswith((".", " ")) or ":" in part
            for part in candidate.parts[1:]
        ):
            # Win32 trims trailing dots/spaces; ADS paths can address streams of
            # an existing immutable file without its default stream existing.
            raise FeedError("output must not use Windows path aliases or alternate data streams.")
    if path.exists() or path.is_symlink():
        raise FeedError(f"output already exists; choose a new path: {path}")
    return resolved


def create_update_feed(
    manifest_path: Path,
    output_path: Path,
    *,
    notes_file: Path | None = None,
    notes: str | None = None,
    download_base_url: str | None = None,
    min_sdk: int = 24,
) -> dict:
    """Read only the manifest/notes and create a new output, with no network I/O."""
    if notes_file is not None and notes is not None:
        raise FeedError("Use either notes_file or notes, not both.")
    output = _output_path(Path(output_path))
    try:
        manifest = json.loads(
            _read_utf8(Path(manifest_path), MAX_JSON_BYTES, "manifest"),
            object_pairs_hook=_unique_object,
            parse_constant=_invalid_constant,
        )
    except (json.JSONDecodeError, RecursionError) as error:
        raise FeedError("manifest must be valid JSON with an object root.") from error
    release_notes = _read_utf8(Path(notes_file), MAX_NOTES_LENGTH * 4 + 3, "notes file") if notes_file is not None else notes or ""
    feed = build_update_feed(manifest, notes=release_notes, download_base_url=download_base_url, min_sdk=min_sdk)
    encoded = (json.dumps(feed, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
    if len(encoded) > MAX_JSON_BYTES:
        raise FeedError("generated feed exceeds the client's 512 KiB JSON limit.")
    output.parent.mkdir(parents=True, exist_ok=True)
    # 'xb' uses exclusive creation; no check-then-truncate overwrite window.
    with output.open("xb") as destination:
        destination.write(encoded)
    return feed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path, help="Existing published release-v2 manifest (read-only).")
    parser.add_argument("--output", required=True, type=Path, help="New JSON file outside release directories; existing paths fail.")
    notes_group = parser.add_mutually_exclusive_group()
    notes_group.add_argument("--notes-file", type=Path, help="Optional UTF-8 user-facing release notes (max 20000 UTF-16 code units).")
    notes_group.add_argument("--notes", help="Optional user-facing release notes as text; default is an empty string.")
    parser.add_argument("--download-base-url", help="Public HTTPS directory holding the unchanged APK; defaults to GitHub release downloads.")
    parser.add_argument("--min-sdk", type=int, default=24, help="Published APK's required Android API level (default: 24).")
    args = parser.parse_args(argv)
    try:
        create_update_feed(args.manifest, args.output, notes_file=args.notes_file, notes=args.notes, download_base_url=args.download_base_url, min_sdk=args.min_sdk)
    except (FeedError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"App update feed: {args.output}")
    print("Derived from manifest claims only; APK bytes/signature and CI results were not re-verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
