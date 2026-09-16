import asyncio
import json
import sqlite3
from pathlib import Path

import httpx
import pytest

from server.app import create_app
from server.stable_identity import stable_episode_key
from server.subtitle_library import LibraryEntry, LibraryError, SubtitleLibrary
from server.subtitles import (
    SubtitleSearchRequest,
    SubtitleService,
    get_subtitle_service,
)
from tools.subtitle_library import catalogue_coverage, import_manifest

SRT = "1\n00:00:01,000 --> 00:00:03,000\nOriginal fixture\n".encode()


def entry(**changes):
    return LibraryEntry(
        subject_key="bangumi:100",
        episode_number=1,
        language="ja",
        file_name="episode.srt",
        source="generated-test",
        rights_reference="Generated in test suite",
        rights_basis="own_work",
        redistribution_allowed=True,
        identity_reviewed=True,
        **changes,
    )


def request(**changes):
    data = dict(
        subject_key="bangumi:100",
        episode_key=stable_episode_key("bangumi:100", 1),
        episode_number=1,
        language="ja",
        title="Test",
        media_type="anime",
    )
    return SubtitleSearchRequest(**(data | changes))


def test_empty_library_read_does_not_create_data(tmp_path):
    root = tmp_path / "private"
    library = SubtitleLibrary(root)
    assert library.find("bangumi:100", "ep", "ja") == []
    assert library.content("a" * 32) is None
    assert library.inventory()["files"] == 0
    assert not root.exists()


def test_library_persists_and_deduplicates_without_losing_metadata(tmp_path):
    library = SubtitleLibrary(tmp_path)
    one = library.ingest(entry(), SRT)
    assert library.ingest(entry(), SRT) == one
    other = entry().model_copy(update={"language": "en", "file_name": "English.srt"})
    two = library.ingest(other, SRT)
    restarted = SubtitleLibrary(tmp_path)
    assert restarted.content(one["id"]) == (SRT, "episode.srt")
    assert restarted.content(two["id"]) == (SRT, "English.srt")
    assert restarted.inventory() == dict(
        files=2,
        subjects=1,
        episode_languages=2,
        bytes=len(SRT),
        reviewed_episode_languages=2,
        languages={"en": 1, "ja": 1},
    )


def test_library_exact_identity_not_title_or_episode_alone(tmp_path):
    library = SubtitleLibrary(tmp_path)
    library.ingest(entry(), SRT)
    assert not library.find("bangumi:999", stable_episode_key("bangumi:100", 1), "ja")
    assert not library.find("bangumi:100", stable_episode_key("bangumi:100", 2), "ja")
    found = library.find("bangumi:100", stable_episode_key("bangumi:100", 1), "ja")
    assert len(found) == 1 and found[0]["auto_match"]
    assert all(
        key not in found[0] for key in ("path", "download_url", "rights_reference")
    )


def test_unreviewed_and_multiple_releases_stay_candidates(tmp_path):
    library = SubtitleLibrary(tmp_path)
    library.ingest(entry().model_copy(update={"identity_reviewed": False}), SRT)
    library.ingest(entry(release="TV edit"), SRT)
    result = library.find("bangumi:100", stable_episode_key("bangumi:100", 1), "ja")
    assert len(result) == 2
    assert sum(row["auto_match"] for row in result) == 1
    assert all(not row["timing_verified"] for row in result)


@pytest.mark.parametrize(
    "name,data",
    [
        ("show.srt", b"<html>login</html>"),
        ("show.srt", b"not a subtitle"),
        ("show.srt", b"x" * (5 * 1024 * 1024 + 1)),
        ("show.ass", b"Dialogue: not parsed"),
        ("show.srt", b"\xffbad"),
    ],
    ids=["html", "plain-text", "oversized", "malformed-ass", "invalid-utf8"],
)
def test_invalid_file_never_published(tmp_path, name, data):
    library = SubtitleLibrary(tmp_path)
    with pytest.raises(LibraryError):
        library.ingest(entry().model_copy(update={"file_name": name}), data)
    assert library.inventory()["files"] == 0


def test_permission_and_path_validation():
    data = entry().model_dump()
    for change in [
        {"redistribution_allowed": False},
        {"file_name": "../x.srt"},
        {"file_name": "x\\x.srt"},
        {"file_name": "a.zip"},
    ]:
        with pytest.raises(ValueError):
            LibraryEntry.model_validate(data | change)


def test_corrupt_blob_is_not_served(tmp_path):
    library = SubtitleLibrary(tmp_path)
    saved = library.ingest(entry(), SRT)
    blob = next((tmp_path / "objects").glob("*/*"))
    blob.write_bytes(b"x" * len(SRT))
    with pytest.raises(LibraryError, match="library_integrity_error"):
        library.content(saved["id"])
    assert library.content("../index.sqlite3") is None


def test_service_prefers_builtin_and_content_survives_restart(tmp_path):
    class MustNotCall:
        id = "upstream"
        policy_approved = True
        allowed_hosts = frozenset()

        async def search(self, request):
            raise AssertionError("cached built-in subtitles must not scrape")

    async def exercise():
        library = SubtitleLibrary(tmp_path)
        library.ingest(entry(), SRT)
        service = SubtitleService((MustNotCall(),), library=library)
        result = await service.search(request())
        assert result["status"] == "found"
        assert result["candidates"][0]["provider"] == "library"
        identifier = result["candidates"][0]["id"]
        new_service = SubtitleService(library=SubtitleLibrary(tmp_path))
        assert (await new_service.content(identifier))[0] == SRT
        app = create_app()
        app.dependency_overrides[get_subtitle_service] = lambda: new_service
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app), base_url="http://test"
        ) as client:
            response = await client.get(f"/api/v3/subtitles/{identifier}/content")
            assert response.status_code == 200 and response.content == SRT
            assert str(tmp_path) not in response.text
            assert (
                await client.get("/api/v3/subtitles/index.sqlite3/content")
            ).status_code == 404

    asyncio.run(exercise())


def test_missing_and_broken_library_are_distinct(tmp_path):
    async def exercise():
        library = SubtitleLibrary(tmp_path)
        empty = await SubtitleService(library=library).search(request(language="en"))
        assert empty["status"] == "not_found"
        library.index.write_bytes(b"not a database")
        broken = await SubtitleService(library=library).search(request(language="en"))
        assert broken["status"] == "provider_unavailable"

    asyncio.run(exercise())


def test_operator_batch_dry_run_apply_and_path_escape(tmp_path):
    files = tmp_path / "incoming"
    files.mkdir()
    (files / "a.srt").write_bytes(SRT)
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "items": [
                    {"file": "a.srt", **entry().model_dump()},
                    {"file": "../outside.srt", **entry().model_dump()},
                ],
            }
        ),
        encoding="utf-8",
    )
    (tmp_path / "outside.srt").write_bytes(SRT)
    root = tmp_path / "library"
    library = SubtitleLibrary(root)
    preview = import_manifest(library, manifest, files)
    assert preview["succeeded"] == 1 and preview["failed"] == 1
    assert not root.exists()
    result = import_manifest(library, manifest, files, apply=True)
    assert result["succeeded"] == 1 and result["failed"] == 1
    assert library.inventory()["files"] == 1
    assert str(tmp_path) not in json.dumps(result)


def test_coverage_counts_known_catalogue_only_and_ignores_versions(tmp_path):
    database = tmp_path / "catalogue.sqlite"
    with sqlite3.connect(database) as connection:
        connection.execute(
            "CREATE TABLE catalog_subjects(stable_id,title,media_type,metadata_json)"
        )
        for subject, language, total in [
            ("bangumi:100", "ja", 2),
            ("tmdb:movie:1", "en", 1),
            ("bangumi:200", "zh", 12),
            ("bangumi:300", "", 0),
        ]:
            connection.execute(
                "INSERT INTO catalog_subjects VALUES (?,?,?,?)",
                (
                    subject,
                    "Fixture",
                    "anime",
                    json.dumps({"language": language, "total_episodes": total}),
                ),
            )
    library = SubtitleLibrary(tmp_path / "library")
    library.ingest(entry(), SRT)
    library.ingest(entry(release="another edition"), SRT)
    result = catalogue_coverage(library, database)
    assert result["scope"] == "all_locally_indexed_catalogue_subjects"
    assert result["catalogue_subjects"] == 4
    assert result["counts"] == {
        "partial": 1,
        "not_needed": 1,
        "language_unknown": 1,
        "missing": 1,
    }
    assert result["subjects"][0]["covered_episodes"] == 1


@pytest.mark.parametrize(
    "body",
    [
        b"1\n00:99:01,000 --> 00:99:02,000\ninvalid",
        b"1\n00:00:03,000 --> 00:00:02,000\nbackward",
        b"1\n00:00:01,000 --> 00:00:02,000\n<b></b>",
        b"1\n00:00:01,000 --> 00:00:02,000\n",
    ],
)
def test_invalid_timestamps_or_empty_dialogue_are_not_indexed(tmp_path, body):
    library = SubtitleLibrary(tmp_path)
    with pytest.raises(LibraryError, match="invalid_subtitle_timeline"):
        library.ingest(entry(), body)
    assert library.inventory()["files"] == 0


def test_ass_vtt_and_utf16_validate_before_ingest(tmp_path):
    library = SubtitleLibrary(tmp_path)
    ass = b"[Events]\nFormat: Layer, Start, End, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Hello, world"
    library.ingest(entry().model_copy(update={"file_name": "fixture.ass"}), ass)
    vtt = "WEBVTT\n\n00:01.000 --> 00:03.000 align:start\nEnglish".encode("utf-16")
    library.ingest(entry().model_copy(update={"file_name": "fixture.vtt"}), vtt)
    assert library.inventory()["files"] == 2
