"""Private, operator-managed subtitle library; independent of account/cloud sync.

No user upload route, automatic scraper, or public filesystem URL. Only a local
operator command can ingest a file with explicit identity and provenance.
Ordinary API reads do not create or migrate any database.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import tempfile
import threading
import weakref
import time
from contextlib import contextmanager, closing
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .stable_identity import stable_episode_key
from .subtitle_google_drive import GoogleDriveBlobs, GoogleDriveError

MAX_BYTES = 5 * 1024 * 1024
_IDENTIFIER = re.compile(r"^[a-f0-9]{32}$")
_DIGEST = re.compile(r"^[a-f0-9]{64}$")


class LibraryError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class LibraryEntry(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    subject_key: str = Field(
        min_length=3, max_length=300, pattern=r"^[A-Za-z0-9._:-]+$"
    )
    episode_number: int = Field(ge=0, le=100000)
    episode_key: str = Field(
        default="", max_length=600, pattern=r"^[A-Za-z0-9._:|+-]*$"
    )
    language: Literal["ja", "en", "zh-Hans"]
    file_name: str = Field(min_length=5, max_length=200)
    title: str = Field(default="", max_length=500)
    release: str = Field(default="", max_length=200)
    season_number: int | None = Field(default=None, ge=0, le=1000)
    season_episode_number: int | None = Field(default=None, ge=0, le=100000)
    source: str = Field(min_length=1, max_length=200)
    # An operator's reference, not an automatic download URL.
    rights_reference: str = Field(min_length=8, max_length=2000)
    rights_basis: Literal["permission", "licensed", "public_domain", "own_work"]
    identity_reviewed: bool = False
    redistribution_allowed: bool = False

    @model_validator(mode="after")
    def validate_entry(self):
        if (
            "/" in self.file_name
            or "\\" in self.file_name
            or any(ord(c) < 32 for c in self.file_name)
            or self.file_name.rsplit(".", 1)[-1].lower()
            not in {"srt", "ass", "ssa", "vtt"}
        ):
            raise ValueError("invalid_subtitle_filename")
        if not self.redistribution_allowed:
            raise ValueError("redistribution_permission_required")
        if not self.episode_key:
            self.episode_key = stable_episode_key(self.subject_key, self.episode_number)
        return self


def validate_subtitle_bytes(data: bytes, file_name: str) -> None:
    if not data or len(data) > MAX_BYTES:
        raise LibraryError("invalid_subtitle_size")
    try:
        text = data.decode(
            "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
        )
    except UnicodeError:
        raise LibraryError("unsupported_subtitle_encoding") from None
    if "\0" in text or text.lstrip().lower().startswith(("<!doctype", "<html")):
        raise LibraryError("invalid_subtitle_content")
    if max(map(len, text.splitlines()), default=0) > 10000:
        raise LibraryError("subtitle_line_too_long")

    def millis(raw: str) -> int | None:
        match = re.fullmatch(
            r"(?:(\d{1,3}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})", raw.strip()
        )
        if match is None:
            return None
        hours, minutes, seconds, fraction = match.groups()
        if int(minutes) > 59 or int(seconds) > 59:
            return None
        return ((int(hours or 0) * 60 + int(minutes)) * 60 + int(seconds)) * 1000 + int(
            fraction.ljust(3, "0")
        )

    valid_cues = 0

    def accept(start: str, end: str, body: str):
        nonlocal valid_cues
        start_ms, end_ms = millis(start), millis(end)
        if start_ms is None or end_ms is None or start_ms >= end_ms or not body.strip():
            return
        if len(body) > 10000:
            raise LibraryError("subtitle_line_too_long")
        valid_cues += 1
        if valid_cues > 50000:
            raise LibraryError("subtitle_too_many_cues")

    if file_name.rsplit(".", 1)[-1].lower() in {"ass", "ssa"}:
        fields, in_events = [], False
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("["):
                in_events = line.lower() == "[events]"
            elif in_events and line.lower().startswith("format:"):
                fields = [part.strip().lower() for part in line[7:].split(",")]
            elif in_events and line.lower().startswith("dialogue:") and fields:
                if fields[-1] != "text" or "start" not in fields or "end" not in fields:
                    continue
                parts = line[9:].split(",", len(fields) - 1)
                if len(parts) != len(fields) or re.search(r"\\p[1-9]", parts[-1]):
                    continue
                body = re.sub(r"\{[^}]*\}", "", parts[-1]).strip()
                accept(parts[fields.index("start")], parts[fields.index("end")], body)
    else:
        for block in re.split(
            r"\n[ \t]*\n", text.replace("\r\n", "\n").replace("\r", "\n")
        ):
            lines = block.splitlines()
            if (
                not lines
                or lines[0].strip().startswith("NOTE")
                or lines[0].strip() in {"STYLE", "REGION"}
            ):
                continue
            for index, line in enumerate(lines):
                if "-->" not in line:
                    continue
                parts = line.split("-->")
                if len(parts) == 2 and parts[1].strip():
                    body = re.sub(r"<[^>]*>", "", "\n".join(lines[index + 1 :]))
                    accept(parts[0], parts[1].strip().split()[0], body)
                break
    if not valid_cues:
        raise LibraryError("invalid_subtitle_timeline")


class SubtitleLibrary:
    """SHA-addressed private blobs and an indexed SQLite catalogue.

    Set root to a server persistent volume. A private cloud mirror may back up
    that volume; never mount an entire personal drive or expose it as static web.
    """

    def __init__(
        self,
        root: Path,
        *,
        remote: GoogleDriveBlobs | None = None,
        cache_bytes: int = 256 * 1024 * 1024,
    ):
        self.root = Path(root).resolve()
        self.index = self.root / "index.sqlite3"
        self.remote = remote
        self.cache_bytes = max(0, cache_bytes)
        self._blob_locks = weakref.WeakValueDictionary()
        self._blob_locks_guard = threading.Lock()

    def _path(self, *parts: str) -> Path:
        path = self.root.joinpath(*parts)
        if not path.resolve().is_relative_to(self.root):
            raise LibraryError("library_path_outside_root")
        return path

    @contextmanager
    def _read(self):
        index = self._path("index.sqlite3")
        connection = sqlite3.connect(index.as_uri() + "?mode=ro", uri=True, timeout=5)
        connection.row_factory = sqlite3.Row
        try:
            yield connection
        finally:
            connection.close()

    def _initialize(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        index = self._path("index.sqlite3")
        with closing(sqlite3.connect(index, timeout=10)) as connection, connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.executescript("""
                CREATE TABLE IF NOT EXISTS subtitles (
                    id TEXT PRIMARY KEY, subject_key TEXT NOT NULL,
                    episode_key TEXT NOT NULL, language TEXT NOT NULL,
                    digest TEXT NOT NULL, size INTEGER NOT NULL,
                    reviewed INTEGER NOT NULL, metadata TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS remote_blobs (
                    digest TEXT PRIMARY KEY, provider TEXT NOT NULL, remote_id TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS subtitles_lookup
                    ON subtitles(subject_key, episode_key, language);
            """)

    def ingest(self, entry: LibraryEntry, data: bytes) -> dict:
        validate_subtitle_bytes(data, entry.file_name)
        digest = hashlib.sha256(data).hexdigest()
        metadata = json.dumps(entry.model_dump(), sort_keys=True, ensure_ascii=False)
        identifier = hashlib.sha256((metadata + ":" + digest).encode()).hexdigest()[:32]
        self._initialize()
        remote_id = None
        if self.remote is not None:
            try:
                remote_id = self.remote.put(digest, data)
            except GoogleDriveError as error:
                raise LibraryError(error.code) from None
        else:
            target = self._path("objects", digest[:2], digest)
            if target.exists():
                if self._read_blob(digest) != data:
                    raise LibraryError("library_integrity_error")
            else:
                self._atomic_blob(target, data)
        with (
            closing(
                sqlite3.connect(self._path("index.sqlite3"), timeout=10)
            ) as connection,
            connection,
        ):
            connection.execute(
                """INSERT OR IGNORE INTO subtitles
                (id,subject_key,episode_key,language,digest,size,reviewed,metadata,created_at)
                VALUES (?,?,?,?,?,?,?,?,?)""",
                (
                    identifier,
                    entry.subject_key,
                    entry.episode_key,
                    entry.language,
                    digest,
                    len(data),
                    int(entry.identity_reviewed),
                    metadata,
                    time.time(),
                ),
            )
            if remote_id is not None:
                connection.execute(
                    "INSERT OR REPLACE INTO remote_blobs(digest,provider,remote_id) VALUES (?,?,?)",
                    (digest, "google_drive", remote_id),
                )
        if remote_id is not None:
            self._cache_blob(digest, data)
        return {
            "id": identifier,
            "size": len(data),
            "subject_key": entry.subject_key,
            "episode_key": entry.episode_key,
            "language": entry.language,
        }

    def find(self, subject: str, episode: str, language: str) -> list[dict]:
        if not self.index.exists():
            return []
        with self._read() as connection:
            rows = connection.execute(
                """SELECT id,metadata,digest,size,reviewed FROM subtitles
                WHERE subject_key=? AND episode_key=? AND language=?
                ORDER BY reviewed DESC,created_at DESC LIMIT 40""",
                (subject, episode, language),
            ).fetchall()
        result = []
        for row in rows:
            path = self._path("objects", row["digest"][:2], row["digest"])
            if not path.is_file() or path.stat().st_size != row["size"]:
                if self.remote is None or self._remote_id(row["digest"]) is None:
                    raise LibraryError("library_file_unavailable")
            meta = self._metadata(row["metadata"])
            # Storage paths and provenance are admin-only, never downloadable URLs.
            result.append(
                {
                    "id": row["id"],
                    "provider": "library",
                    "entry_id": subject,
                    "file_name": meta["file_name"],
                    "language": language,
                    "auto_match": bool(row["reviewed"]),
                    "timing_verified": False,
                    "reasons": [
                        "服务器内置字幕",
                        "作品与分集已核对" if row["reviewed"] else "待人工核对分集",
                        meta["release"] or "片源版本未注明",
                        "时间轴仍需检查",
                    ],
                }
            )
        return result

    @staticmethod
    def _metadata(raw: str) -> dict:
        try:
            return LibraryEntry.model_validate(json.loads(raw)).model_dump()
        except (ValueError, TypeError):
            raise LibraryError("library_integrity_error") from None

    def _remote_id(self, digest: str) -> str | None:
        with self._read() as connection:
            if (
                connection.execute(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='remote_blobs'"
                ).fetchone()
                is None
            ):
                return None
            row = connection.execute(
                "SELECT provider,remote_id FROM remote_blobs WHERE digest=?", (digest,)
            ).fetchone()
        if row is None:
            return None
        if row["provider"] != "google_drive":
            raise LibraryError("unsupported_blob_storage")
        return row["remote_id"]

    @staticmethod
    def _atomic_blob(target: Path, data: bytes):
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".subtitle-", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def _cache_blob(self, digest: str, data: bytes):
        # This directory is disposable. Permanent local objects are never evicted.
        if len(data) > self.cache_bytes:
            return
        try:
            target = self._path("cache", digest)
            self._atomic_blob(target, data)
            cache_root = self._path("cache")
            entries = [
                path
                for path in cache_root.iterdir()
                if _DIGEST.fullmatch(path.name)
                and not path.is_symlink()
                and path.is_file()
            ]
            entries.sort(key=lambda path: path.stat().st_mtime)
            total = sum(path.stat().st_size for path in entries)
            for path in entries:
                if total <= self.cache_bytes:
                    break
                if path == target:
                    continue
                total -= path.stat().st_size
                path.unlink()
        except OSError:
            # Disk pressure must not turn a successful private Drive fetch into a failure.
            pass

    def _read_blob(self, digest: str) -> bytes:
        # Coalesce simultaneous cache misses for the same file; weak references
        # avoid retaining a lock for every title ever requested.
        with self._blob_locks_guard:
            lock = self._blob_locks.setdefault(digest, threading.Lock())
        with lock:
            return self._read_blob_unlocked(digest)

    def _read_blob_unlocked(self, digest: str) -> bytes:
        if not _DIGEST.fullmatch(digest):
            raise LibraryError("library_integrity_error")
        path = self._path("objects", digest[:2], digest)
        if path.is_file():
            with path.open("rb") as stream:
                data = stream.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES or hashlib.sha256(data).hexdigest() != digest:
                raise LibraryError("library_integrity_error")
            return data
        cached = self._path("cache", digest)
        if cached.is_file():
            with cached.open("rb") as stream:
                data = stream.read(MAX_BYTES + 1)
            if len(data) <= MAX_BYTES and hashlib.sha256(data).hexdigest() == digest:
                try:
                    os.utime(cached, None)
                except OSError:
                    pass
                return data
        remote_id = self._remote_id(digest)
        if self.remote is None or remote_id is None:
            raise LibraryError("library_file_unavailable")
        try:
            data = self.remote.get(remote_id, digest)
        except GoogleDriveError as error:
            raise LibraryError(error.code) from None
        self._cache_blob(digest, data)
        return data

    def content(self, identifier: str) -> tuple[bytes, str] | None:
        if not _IDENTIFIER.fullmatch(identifier) or not self.index.exists():
            return None
        with self._read() as connection:
            row = connection.execute(
                "SELECT digest,metadata FROM subtitles WHERE id=?", (identifier,)
            ).fetchone()
        if row is None:
            return None
        return self._read_blob(row["digest"]), self._metadata(row["metadata"])[
            "file_name"
        ]

    def inventory(self) -> dict:
        if not self.index.exists():
            return {
                "files": 0,
                "subjects": 0,
                "episode_languages": 0,
                "bytes": 0,
                "reviewed_episode_languages": 0,
                "languages": {},
            }
        with self._read() as connection:
            counts = connection.execute(
                "SELECT COUNT(*) files,COUNT(DISTINCT subject_key) subjects FROM subtitles"
            ).fetchone()
            episode_languages = connection.execute(
                "SELECT COUNT(*) FROM (SELECT DISTINCT episode_key,language FROM subtitles)"
            ).fetchone()[0]
            reviewed = connection.execute(
                "SELECT COUNT(*) FROM (SELECT DISTINCT episode_key,language FROM subtitles WHERE reviewed=1)"
            ).fetchone()[0]
            size = connection.execute(
                "SELECT COALESCE(SUM(size),0) FROM (SELECT digest,MAX(size) size FROM subtitles GROUP BY digest)"
            ).fetchone()[0]
            languages = dict(
                connection.execute(
                    "SELECT language,COUNT(*) FROM subtitles GROUP BY language"
                ).fetchall()
            )
        return {
            **dict(counts),
            "episode_languages": episode_languages,
            "bytes": size,
            "reviewed_episode_languages": reviewed,
            "languages": languages,
        }

    def covered_episodes(self) -> dict[str, dict[str, set[str]]]:
        result: dict[str, dict[str, set[str]]] = {}
        if not self.index.exists():
            return result
        with self._read() as connection:
            rows = connection.execute(
                "SELECT DISTINCT subject_key,episode_key,language FROM subtitles WHERE reviewed=1"
            )
            for subject, episode, language in rows:
                result.setdefault(subject, {}).setdefault(language, set()).add(episode)
        return result


def configured_subtitle_library() -> SubtitleLibrary:
    from .config import (
        SUBTITLE_LIBRARY_DIR,
        SUBTITLE_BLOB_STORAGE,
        SUBTITLE_GOOGLE_CREDENTIALS_FILE,
        SUBTITLE_GOOGLE_FOLDER_ID,
        SUBTITLE_CACHE_MAX_BYTES,
    )

    remote = None
    if SUBTITLE_BLOB_STORAGE == "google_drive":
        remote = GoogleDriveBlobs(
            SUBTITLE_GOOGLE_CREDENTIALS_FILE, SUBTITLE_GOOGLE_FOLDER_ID
        )
    return SubtitleLibrary(
        SUBTITLE_LIBRARY_DIR, remote=remote, cache_bytes=SUBTITLE_CACHE_MAX_BYTES
    )
