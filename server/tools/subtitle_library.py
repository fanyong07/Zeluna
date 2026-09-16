"""Operator-only ingest and whole-known-catalogue coverage; never a crawler.

python -m tools.subtitle_library import --manifest /private/manifest.json --files /private/files
Add --apply only after checking the dry-run. Normal playback has no upload API.
python -m tools.subtitle_library coverage --catalog-db /var/lib/zeluna/data.db
"""

from __future__ import annotations

from contextlib import closing
import argparse
import json
import sqlite3
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from server.subtitle_google_drive import GoogleDriveError  # noqa: E402
from server.stable_identity import stable_episode_key  # noqa: E402
from server.subtitle_library import (
    LibraryEntry,
    LibraryError,
    SubtitleLibrary,
    MAX_BYTES,
    validate_subtitle_bytes,
    configured_subtitle_library,
)  # noqa: E402


def import_manifest(
    library: SubtitleLibrary, manifest: Path, files: Path, *, apply=False
) -> dict:
    if manifest.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("manifest_too_large")
    manifest_data = json.loads(manifest.read_text(encoding="utf-8-sig"))
    if not isinstance(manifest_data, dict) or manifest_data.get("schema_version") != 1:
        raise ValueError("invalid_manifest_schema")
    items = manifest_data.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= 500:
        raise ValueError("batch_requires_1_to_500_items")
    files = files.resolve(strict=True)
    results = []
    for index, item in enumerate(items):
        try:
            if not isinstance(item, dict):
                raise ValueError("invalid_manifest_item")
            raw = dict(item)
            relative = raw.pop("file")
            if not isinstance(relative, str) or Path(relative).is_absolute():
                raise ValueError("file_must_be_relative")
            source_file = (files / relative).resolve(strict=True)
            if not source_file.is_relative_to(files) or not source_file.is_file():
                raise ValueError("file_outside_import_directory")
            entry = LibraryEntry.model_validate(raw)
            with source_file.open("rb") as stream:
                content = stream.read(MAX_BYTES + 1)
            validate_subtitle_bytes(content, entry.file_name)
            result = (
                library.ingest(entry, content)
                if apply
                else {
                    "subject_key": entry.subject_key,
                    "episode_key": entry.episode_key,
                    "language": entry.language,
                    "size": len(content),
                }
            )
            results.append(
                {
                    "row": index + 1,
                    "status": "stored" if apply else "validated",
                    **result,
                }
            )
        except (ValueError, KeyError, OSError, LibraryError, sqlite3.Error) as error:
            # Do not echo operator paths, full manifest, or possible private provenance.
            code = (
                error.code
                if isinstance(error, LibraryError)
                else "invalid_entry_or_file"
            )
            results.append({"row": index + 1, "status": "failed", "error": code})
    failed = sum(row["status"] == "failed" for row in results)
    return {
        "mode": "apply" if apply else "dry_run",
        "succeeded": len(results) - failed,
        "failed": failed,
        "items": results,
    }


def target_language(metadata: dict) -> str | None:
    language = str(
        metadata.get("language") or metadata.get("original_language") or ""
    ).lower()
    if language in {"ja", "jpn", "日语", "日本語", "japanese"}:
        return "ja"
    if language in {"en", "eng", "英语", "英文", "english"}:
        return "en"
    if language in {
        "zh",
        "zh-cn",
        "zh-hans",
        "国语",
        "普通话",
        "汉语",
        "中文",
        "chinese",
    }:
        return "zh"
    return None


def catalogue_coverage(library: SubtitleLibrary, database: Path) -> dict:
    """Read only public catalogue columns, never account, cookies or playback URLs."""
    database = database.resolve(strict=True)
    covered = library.covered_episodes()
    with closing(
        sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    ) as connection:
        rows = connection.execute(
            "SELECT stable_id,title,media_type,metadata_json FROM catalog_subjects ORDER BY stable_id"
        ).fetchall()
    result = []
    for stable_id, title, media_type, raw in rows:
        try:
            metadata = json.loads(raw)
            if not isinstance(metadata, dict):
                metadata = {}
        except (ValueError, TypeError):
            metadata = {}
        language = target_language(metadata)
        try:
            total = (
                1 if media_type == "movie" else int(metadata.get("total_episodes") or 0)
            )
        except (ValueError, TypeError):
            total = 0
        total = max(0, min(total, 100000))
        known_episodes = covered.get(stable_id, {}).get(language or "", set())
        expected = {stable_episode_key(stable_id, n) for n in range(1, total + 1)}
        matching = len(known_episodes & expected) if total else len(known_episodes)
        if language == "zh":
            status = "not_needed"
        elif language is None:
            status = "language_unknown"
        elif not total:
            status = "episode_count_unknown"
        elif matching == total:
            status = "complete_for_known_episodes"
        elif matching:
            status = "partial"
        else:
            status = "missing"
        result.append(
            {
                "subject_key": stable_id,
                "title": title,
                "language": language,
                "known_episode_count": total or None,
                "covered_episodes": matching,
                "status": status,
            }
        )
    counts = {}
    for row in result:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    return {
        "scope": "all_locally_indexed_catalogue_subjects",
        "verification": "indexed_bindings_only_not_live_download_or_timing_verified",
        "catalogue_subjects": len(rows),
        "inventory": library.inventory(),
        "counts": counts,
        "subjects": result,
    }


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Private subtitle library administration (no network scraping)"
    )
    parser.add_argument(
        "--root",
        type=Path,
        help="Override private index/cache directory, not remote credentials",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    ingest = sub.add_parser("import")
    ingest.add_argument("--manifest", type=Path, required=True)
    ingest.add_argument("--files", type=Path, required=True)
    ingest.add_argument("--apply", action="store_true")
    sub.add_parser("inventory")
    sub.add_parser("storage-check")
    sub.add_parser("drive-check")
    coverage = sub.add_parser("coverage")
    coverage.add_argument("--catalog-db", type=Path, required=True)
    args = parser.parse_args()
    library = configured_subtitle_library()
    if args.root is not None:
        library = SubtitleLibrary(
            args.root, remote=library.remote, cache_bytes=library.cache_bytes
        )
    try:
        if args.command == "import":
            result = import_manifest(
                library, args.manifest, args.files, apply=args.apply
            )
        elif args.command == "storage-check":
            path = library.root
            while not path.exists():
                path = path.parent
            disk = shutil.disk_usage(path)
            result = {
                "storage_backend": "google_drive"
                if library.remote is not None
                else "local",
                "disk_total_bytes": disk.total,
                "disk_free_bytes": disk.free,
                "cache_limit_bytes": library.cache_bytes,
                "inventory": library.inventory(),
                "drive_connected": "not_checked",
                "scope": "this_host_only",
            }
        elif args.command == "drive-check":
            if library.remote is None:
                raise LibraryError("google_drive_not_enabled")
            result = {
                "storage_quota": library.remote.capacity(),
                "folder_private": True,
            }
        elif args.command == "coverage":
            result = catalogue_coverage(library, args.catalog_db)
        else:
            result = library.inventory()
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1 if result.get("failed") else 0
    except (
        OSError,
        ValueError,
        sqlite3.Error,
        LibraryError,
        GoogleDriveError,
    ) as error:
        print(
            json.dumps(
                {
                    "error": error.code
                    if isinstance(error, (LibraryError, GoogleDriveError))
                    else "library_or_manifest_unavailable"
                }
            )
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
