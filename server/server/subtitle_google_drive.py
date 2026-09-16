"""Opt-in private Google Drive blob adapter (drive.file only).

This module never starts OAuth, publishes a share link or visits arbitrary URLs.
An operator must first authorize an app-owned private folder. Credentials stay
in an external owner-readable OAuth file, never in API responses or subtitles.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
import uuid
from pathlib import Path

import httpx

DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
_ID = re.compile(r"^[A-Za-z0-9_-]{10,200}$")
_SHA = re.compile(r"^[a-f0-9]{64}$")
_API = "https://www.googleapis.com/drive/v3"
_UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
_OAUTH = "https://oauth2.googleapis.com/token"
_LIMIT = 5 * 1024 * 1024


class GoogleDriveError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class GoogleDriveBlobs:
    def __init__(
        self,
        credential_file: Path | None,
        folder_id: str,
        *,
        transport: httpx.BaseTransport | None = None,
        clock=time.monotonic,
    ):
        self.credential_file = credential_file
        self.folder_id = folder_id
        self._transport = transport
        self._clock = clock
        self._token = ""
        self._expires_at = 0.0
        self._auth_lock = threading.Lock()
        self._write_lock = threading.Lock()

    def _client(self):
        return httpx.Client(
            timeout=15,
            follow_redirects=False,
            trust_env=False,
            transport=self._transport,
        )

    def _access_token(self) -> str:
        with self._auth_lock:
            if self._token and self._clock() < self._expires_at:
                return self._token
            try:
                path = self.credential_file
                if path is None or path.stat().st_size > 64 * 1024:
                    raise GoogleDriveError("drive_authorization_required")
                if os.name != "nt" and path.stat().st_mode & 0o077:
                    raise GoogleDriveError("drive_credentials_must_be_private")
                data = json.loads(path.read_text(encoding="utf-8-sig"))
                scopes = data.get("scopes", [])
                scopes = scopes.split() if isinstance(scopes, str) else scopes
                if set(scopes) != {DRIVE_SCOPE}:
                    raise GoogleDriveError("drive_file_scope_required")
                if data.get("type", "authorized_user") != "authorized_user" or not all(
                    isinstance(data.get(key), str) and data[key].strip()
                    for key in ("client_id", "client_secret", "refresh_token")
                ):
                    raise GoogleDriveError("drive_authorization_required")
            except (OSError, ValueError, TypeError, AttributeError):
                raise GoogleDriveError("drive_authorization_required") from None
            try:
                with self._client() as client:
                    response = client.post(
                        _OAUTH,
                        data={
                            "grant_type": "refresh_token",
                            "client_id": data["client_id"],
                            "client_secret": data["client_secret"],
                            "refresh_token": data["refresh_token"],
                        },
                    )
                    self._check_status(response, auth=True)
                    token_data = self._json(response)
                    granted = token_data.get("scope")
                    if granted is not None and set(str(granted).split()) != {
                        DRIVE_SCOPE
                    }:
                        raise GoogleDriveError("drive_file_scope_required")
                    token = token_data.get("access_token")
                    if (
                        not isinstance(token, str)
                        or not token
                        or re.search(r"\s", token)
                    ):
                        raise GoogleDriveError("drive_authorization_required")
                    expires = max(1, min(3600, int(token_data.get("expires_in", 3600))))
                    self._token = token
                    self._expires_at = self._clock() + max(0, expires - 60)
            except (httpx.HTTPError, ValueError, TypeError):
                raise GoogleDriveError("drive_authorization_unavailable") from None
            return self._token

    @staticmethod
    def _check_status(response: httpx.Response, *, auth=False):
        if response.status_code in (403, 429):
            raise GoogleDriveError("drive_permission_or_quota_limit")
        if not 200 <= response.status_code < 300:
            # Do not echo remote bodies: OAuth failures may contain sensitive context.
            raise GoogleDriveError(
                "drive_authorization_required"
                if auth or response.status_code == 401
                else "drive_unavailable"
            )

    @staticmethod
    def _json(response: httpx.Response) -> dict:
        if len(response.content) > 256 * 1024:
            raise GoogleDriveError("drive_invalid_response")
        try:
            value = response.json()
            if not isinstance(value, dict):
                raise ValueError()
            return value
        except ValueError:
            raise GoogleDriveError("drive_invalid_response") from None

    def _request(self, method: str, url: str, **kwargs) -> dict:
        headers = {
            "Authorization": f"Bearer {self._access_token()}",
            **kwargs.pop("headers", {}),
        }
        try:
            with self._client() as client:
                response = client.request(method, url, headers=headers, **kwargs)
                self._check_status(response)
                return self._json(response)
        except httpx.HTTPError:
            raise GoogleDriveError("drive_unavailable") from None

    def check_folder(self) -> dict:
        if not _ID.fullmatch(self.folder_id):
            raise GoogleDriveError("drive_private_folder_required")
        folder = self._request(
            "GET",
            f"{_API}/files/{self.folder_id}",
            params={
                "fields": "id,mimeType,trashed,shared,capabilities(canAddChildren)",
            },
        )
        if (
            folder.get("id") != self.folder_id
            or folder.get("trashed") is True
            or folder.get("mimeType") != "application/vnd.google-apps.folder"
            or folder.get("shared") is not False
            or not folder.get("capabilities", {}).get("canAddChildren")
        ):
            raise GoogleDriveError("drive_private_folder_required")
        return {"folder_accessible": True, "folder_private": True}

    def capacity(self) -> dict:
        self.check_folder()
        quota = self._request(
            "GET", f"{_API}/about", params={"fields": "storageQuota"}
        ).get("storageQuota", {})
        return {
            key: int(value)
            for key, value in quota.items()
            if key in {"limit", "usage", "usageInDrive", "usageInDriveTrash"}
            and str(value).isdigit()
        }

    def _validate_file(self, remote_id: str, digest: str) -> None:
        if not _ID.fullmatch(remote_id) or not _SHA.fullmatch(digest):
            raise GoogleDriveError("drive_invalid_reference")
        metadata = self._request(
            "GET",
            f"{_API}/files/{remote_id}",
            params={
                "fields": "id,parents,appProperties,size,trashed,shared",
            },
        )
        if (
            metadata.get("id") != remote_id
            or self.folder_id not in metadata.get("parents", [])
            or metadata.get("appProperties", {}).get("zeluna_sha256") != digest
            or metadata.get("trashed") is True
            or metadata.get("shared") is not False
            or not str(metadata.get("size", "")).isdigit()
            or not 0 < int(metadata["size"]) <= _LIMIT
        ):
            raise GoogleDriveError("drive_invalid_reference")

    def put(self, digest: str, data: bytes) -> str:
        if (
            not 0 < len(data) <= _LIMIT
            or not _SHA.fullmatch(digest)
            or hashlib.sha256(data).hexdigest() != digest
        ):
            raise GoogleDriveError("drive_invalid_content")
        with self._write_lock:
            self.check_folder()
            found = self._request(
                "GET",
                f"{_API}/files",
                params={
                    "q": f"'{self.folder_id}' in parents and trashed = false and appProperties has {{ key='zeluna_sha256' and value='{digest}' }}",
                    "fields": "files(id),nextPageToken",
                    "pageSize": 2,
                    "spaces": "drive",
                },
            )
            files = found.get("files", [])
            if (
                not isinstance(files, list)
                or len(files) > 1
                or found.get("nextPageToken")
            ):
                raise GoogleDriveError("drive_ambiguous_blob")
            if files:
                remote_id = str(files[0].get("id", ""))
                if self.get(remote_id, digest) != data:
                    raise GoogleDriveError("drive_integrity_error")
                return remote_id
            # No permissions/shared link APIs are called. New files inherit only
            # this checked, private app-owned folder's permissions.
            boundary = "zeluna_" + uuid.uuid4().hex
            metadata = json.dumps(
                {
                    "name": digest + ".subtitle",
                    "parents": [self.folder_id],
                    "mimeType": "application/octet-stream",
                    "appProperties": {"zeluna_sha256": digest},
                }
            ).encode()
            content = (
                f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".encode()
                + metadata
                + f"\r\n--{boundary}\r\nContent-Type: application/octet-stream\r\n\r\n".encode()
                + data
                + f"\r\n--{boundary}--\r\n".encode()
            )
            result = self._request(
                "POST",
                _UPLOAD,
                params={"uploadType": "multipart", "fields": "id"},
                content=content,
                headers={"Content-Type": f"multipart/related; boundary={boundary}"},
            )
            remote_id = result.get("id", "")
            if not isinstance(remote_id, str) or not _ID.fullmatch(remote_id):
                raise GoogleDriveError("drive_invalid_response")
            self._validate_file(remote_id, digest)
            return remote_id

    def get(self, remote_id: str, digest: str) -> bytes:
        self.check_folder()
        self._validate_file(remote_id, digest)
        try:
            with self._client() as client:
                with client.stream(
                    "GET",
                    f"{_API}/files/{remote_id}",
                    params={"alt": "media"},
                    headers={"Authorization": f"Bearer {self._access_token()}"},
                ) as response:
                    self._check_status(response)
                    chunks = bytearray()
                    for chunk in response.iter_bytes():
                        if len(chunks) + len(chunk) > _LIMIT:
                            raise GoogleDriveError("drive_invalid_content")
                        chunks.extend(chunk)
        except httpx.HTTPError:
            raise GoogleDriveError("drive_unavailable") from None
        data = bytes(chunks)
        if not data or hashlib.sha256(data).hexdigest() != digest:
            raise GoogleDriveError("drive_integrity_error")
        return data
