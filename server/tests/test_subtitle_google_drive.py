import hashlib
import json
from pathlib import Path

import httpx
import pytest

from server.subtitle_google_drive import DRIVE_SCOPE, GoogleDriveBlobs, GoogleDriveError
from server.subtitle_library import LibraryEntry, SubtitleLibrary, LibraryError

DATA = b"1\n00:00:01,000 --> 00:00:03,000\nFixture\n"
SHA = hashlib.sha256(DATA).hexdigest()
FOLDER = "test_private_folder_01"
FILE_ID = "test_subtitle_blob_01"


def credentials(tmp_path):
    path = tmp_path / "oauth-test.json"
    path.write_text(
        json.dumps(
            {
                "type": "authorized_user",
                "scopes": [DRIVE_SCOPE],
                "client_id": "test-client",
                "client_secret": "test-client-secret",
                "refresh_token": "test-refresh",
            }
        ),
        encoding="utf-8",
    )
    path.chmod(0o600)
    return path


class DriveFixture:
    def __init__(self):
        self.requests = []
        self.uploaded = False
        self.shared_folder = False
        self.wrong_parent = False
        self.download_data = DATA
        self.token_scope = DRIVE_SCOPE
        self.download_status = 200

    def __call__(self, request):
        self.requests.append(request)
        assert request.url.scheme == "https"
        assert request.url.host in {"oauth2.googleapis.com", "www.googleapis.com"}
        assert "cookie" not in request.headers
        if request.url.host == "oauth2.googleapis.com":
            assert "authorization" not in request.headers
            assert request.url.path == "/token"
            return httpx.Response(
                200,
                json={
                    "access_token": "test-access",
                    "expires_in": 3600,
                    "scope": self.token_scope,
                },
            )
        assert request.headers["authorization"] == "Bearer test-access"
        assert "permissions" not in request.url.path
        if request.url.path == "/drive/v3/files/" + FOLDER:
            return httpx.Response(
                200,
                json={
                    "id": FOLDER,
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": False,
                    "shared": self.shared_folder,
                    "capabilities": {"canAddChildren": True},
                },
            )
        if request.url.path == "/drive/v3/about":
            assert request.url.params["fields"] == "storageQuota"
            return httpx.Response(
                200, json={"storageQuota": {"limit": "5000000000000", "usage": "10"}}
            )
        if request.url.path == "/drive/v3/files":
            assert FOLDER in request.url.params["q"] and SHA in request.url.params["q"]
            return httpx.Response(
                200, json={"files": [{"id": FILE_ID}] if self.uploaded else []}
            )
        if request.url.path == "/upload/drive/v3/files":
            assert request.method == "POST"
            assert request.url.params["uploadType"] == "multipart"
            assert DATA in request.content
            assert "multipart/related" in request.headers["content-type"]
            self.uploaded = True
            return httpx.Response(200, json={"id": FILE_ID})
        assert request.url.path == "/drive/v3/files/" + FILE_ID
        if request.url.params.get("alt") == "media":
            return httpx.Response(
                self.download_status,
                content=self.download_data,
                headers={"Location": "https://evil.example/steal"},
            )
        return httpx.Response(
            200,
            json={
                "id": FILE_ID,
                "parents": ["other_folder"] if self.wrong_parent else [FOLDER],
                "appProperties": {"zeluna_sha256": SHA},
                "size": str(len(DATA)),
                "shared": False,
                "trashed": False,
            },
        )


def adapter(tmp_path, fixture=None):
    fixture = fixture or DriveFixture()
    return GoogleDriveBlobs(
        credentials(tmp_path), FOLDER, transport=httpx.MockTransport(fixture)
    ), fixture


def test_private_upload_dedup_download_quota_and_token_cache(tmp_path):
    drive, fake = adapter(tmp_path)
    assert drive.put(SHA, DATA) == FILE_ID
    assert drive.put(SHA, DATA) == FILE_ID
    assert drive.get(FILE_ID, SHA) == DATA
    assert drive.capacity() == {"limit": 5000000000000, "usage": 10}
    assert sum(req.url.path.startswith("/upload/") for req in fake.requests) == 1
    assert sum(req.url.host == "oauth2.googleapis.com" for req in fake.requests) == 1
    assert not any("test-refresh" in str(req.url) for req in fake.requests)


def test_missing_authorization_makes_no_network_request(tmp_path):
    fake = DriveFixture()
    drive = GoogleDriveBlobs(None, FOLDER, transport=httpx.MockTransport(fake))
    with pytest.raises(GoogleDriveError, match="drive_authorization_required"):
        drive.check_folder()
    assert not fake.requests


@pytest.mark.parametrize(
    "case",
    ["broad_local_scope", "broad_granted_scope", "shared_folder", "other_folder"],
)
def test_scope_and_folder_boundary(tmp_path, case):
    fake = DriveFixture()
    path = credentials(tmp_path)
    if case == "broad_local_scope":
        data = json.loads(path.read_text())
        data["scopes"] = ["https://www.googleapis.com/auth/drive"]
        path.write_text(json.dumps(data))
    if case == "broad_granted_scope":
        fake.token_scope = "https://www.googleapis.com/auth/drive"
    if case == "shared_folder":
        fake.shared_folder = True
    if case == "other_folder":
        fake.wrong_parent = True
    drive = GoogleDriveBlobs(path, FOLDER, transport=httpx.MockTransport(fake))
    with pytest.raises(GoogleDriveError):
        drive.get(FILE_ID, SHA)
    assert not any(req.url.params.get("alt") == "media" for req in fake.requests)


@pytest.mark.parametrize(
    "case", ["redirect", "forbidden", "quota", "too_large", "hash_mismatch"]
)
def test_download_errors_never_follow_redirect_or_publish_bytes(tmp_path, case):
    drive, fake = adapter(tmp_path)
    if case == "redirect":
        fake.download_status = 302
    if case == "forbidden":
        fake.download_status = 403
    if case == "quota":
        fake.download_status = 429
    if case == "too_large":
        fake.download_data = b"x" * (5 * 1024 * 1024 + 1)
    if case == "hash_mismatch":
        fake.download_data = b"different bytes"
    with pytest.raises(GoogleDriveError):
        drive.get(FILE_ID, SHA)
    assert all(req.url.host != "evil.example" for req in fake.requests)


def test_upstream_oauth_error_body_is_not_exposed(tmp_path):
    def handler(request):
        return httpx.Response(
            400, json={"error": "test-refresh and test-client-secret must not leak"}
        )

    drive = GoogleDriveBlobs(
        credentials(tmp_path), FOLDER, transport=httpx.MockTransport(handler)
    )
    with pytest.raises(GoogleDriveError) as error:
        drive.check_folder()
    assert str(error.value) == "drive_authorization_required"


def entry():
    return LibraryEntry(
        subject_key="bangumi:10",
        episode_number=1,
        language="en",
        file_name="fixture.srt",
        source="generated test",
        rights_basis="own_work",
        rights_reference="Generated in this test",
        identity_reviewed=True,
        redistribution_allowed=True,
    )


def test_remote_library_restart_and_cache_works_when_drive_is_offline(tmp_path):
    drive, fake = adapter(tmp_path)
    library_root = tmp_path / "library"
    library = SubtitleLibrary(library_root, remote=drive)
    result = library.ingest(entry(), DATA)
    assert not (library_root / "objects").exists()
    # Index+cache persisted: restart and an unavailable cloud does not break cached playback.
    fake.download_status = 503
    restarted = SubtitleLibrary(library_root, remote=drive)
    count = len(fake.requests)
    assert restarted.content(result["id"]) == (DATA, "fixture.srt")
    assert len(fake.requests) == count
    assert (
        restarted.find("bangumi:10", "v1|bangumi:10|episode:1", "en")[0]["provider"]
        == "library"
    )


def test_remote_library_with_zero_cache_reads_from_drive_and_fails_closed(tmp_path):
    drive, fake = adapter(tmp_path)
    library = SubtitleLibrary(tmp_path / "library", remote=drive, cache_bytes=0)
    saved = library.ingest(entry(), DATA)
    assert not (library.root / "cache").exists()
    assert library.content(saved["id"]) == (DATA, "fixture.srt")
    fake.download_status = 503
    with pytest.raises(LibraryError, match="drive_unavailable"):
        library.content(saved["id"])


def test_cache_eviction_never_removes_permanent_local_objects(tmp_path):
    class MemoryDrive:
        def __init__(self):
            self.blobs = {}
            self.gets = 0

        def put(self, digest, data):
            self.blobs[digest] = data
            return digest

        def get(self, remote_id, digest):
            self.gets += 1
            return self.blobs[digest]

    root = tmp_path / "library"
    local = SubtitleLibrary(root)
    saved_local = local.ingest(entry(), DATA)
    remote = MemoryDrive()
    cloud = SubtitleLibrary(root, remote=remote, cache_bytes=len(DATA) + 4)
    one = cloud.ingest(
        entry().model_copy(update={"episode_number": 2, "episode_key": "ep2"}),
        DATA + b"a",
    )
    two = cloud.ingest(
        entry().model_copy(update={"episode_number": 3, "episode_key": "ep3"}),
        DATA + b"b",
    )
    assert (
        sum(p.stat().st_size for p in (root / "cache").iterdir()) <= cloud.cache_bytes
    )
    assert local.content(saved_local["id"])[0] == DATA
    assert cloud.content(one["id"])[0] == DATA + b"a"
    assert cloud.content(two["id"])[0] == DATA + b"b"
    assert remote.gets == 2


def test_simultaneous_cold_reads_share_one_cloud_download(tmp_path):
    import concurrent.futures
    import time

    class SlowDrive:
        def __init__(self):
            self.gets = 0

        def put(self, digest, data):
            return FILE_ID

        def get(self, remote_id, digest):
            self.gets += 1
            time.sleep(0.1)
            return DATA

    drive = SlowDrive()
    root = tmp_path / "library"
    writer = SubtitleLibrary(root, remote=drive, cache_bytes=0)
    saved = writer.ingest(entry(), DATA)
    reader = SubtitleLibrary(root, remote=drive)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: reader.content(saved["id"]), range(8)))
    assert all(result == (DATA, "fixture.srt") for result in results)
    assert drive.gets == 1
