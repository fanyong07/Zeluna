"""Bounded public Bangumi artwork cache; never an arbitrary media proxy."""
from __future__ import annotations

import asyncio
import hashlib
import re
import time
from collections import OrderedDict
from dataclasses import dataclass
from urllib.parse import parse_qsl, urlsplit

import httpx

from .public_http import PublicHttpTransport, UnsafeDestination

_COVER_PATH = re.compile(r"/(?:r/(?:100|200|400|600|800)/)?pic/(?:cover|crt|person)/(?:[a-z]+)/[A-Za-z0-9/_-]+\.(?:jpg|jpeg|png|webp)$")
_API_PATH = re.compile(r"/v0/subjects/[1-9][0-9]{0,8}/image$")


def public_artwork_url(value: str) -> str:
    """Only unsigned, credential-free artwork URLs on the fixed metadata CDN."""
    try:
        uri = urlsplit(value)
        if (len(value) > 1024 or any(ord(c) <= 32 for c in value)
                or "\\" in value or "%" in uri.path or "/../" in uri.path
                or uri.scheme != "https" or uri.username is not None
                or uri.password is not None or uri.port not in (None, 443)
                or uri.fragment):
            raise ValueError("unsupported artwork URL")
        if uri.hostname == "lain.bgm.tv" and not uri.query and _COVER_PATH.fullmatch(uri.path):
            return value
        if uri.hostname == "api.bgm.tv" and _API_PATH.fullmatch(uri.path):
            query = parse_qsl(uri.query, keep_blank_values=True)
            if query in ([], [("type", "small")], [("type", "grid")],
                         [("type", "medium")], [("type", "large")], [("type", "common")]):
                return value
    except (ValueError, TypeError):
        pass
    raise ValueError("unsupported artwork URL")


class ArtworkUnavailable(Exception):
    pass


@dataclass(frozen=True)
class Artwork:
    body: bytes
    content_type: str
    etag: str


class CatalogArtworkCache:
    max_image_bytes = 2 * 1024 * 1024
    max_cache_bytes = 32 * 1024 * 1024
    max_entries = 256
    max_pending = 32
    ttl = 24 * 3600

    def __init__(self, *, transport=None, clock=time.monotonic):
        self._transport = transport
        self._clock = clock
        self._cache: OrderedDict[str, tuple[float, Artwork]] = OrderedDict()
        self._failed: OrderedDict[str, float] = OrderedDict()
        self._pending: dict[str, asyncio.Task] = {}
        self._gate = asyncio.Semaphore(6)
        self._bytes = 0

    async def get(self, raw_url: str) -> Artwork:
        url = public_artwork_url(raw_url)
        cached = self._cache.get(url)
        if cached:
            if cached[0] > self._clock():
                self._cache.move_to_end(url)
                return cached[1]
            self._bytes -= len(self._cache.pop(url)[1].body)
        if self._failed.get(url, 0) > self._clock():
            raise ArtworkUnavailable("artwork temporarily unavailable")
        task = self._pending.get(url)
        if task is None:
            if len(self._pending) >= self.max_pending:
                raise ArtworkUnavailable("artwork queue is full")
            task = asyncio.create_task(self._load(url))
            self._pending[url] = task
            # Retrieve exceptions even if every waiting HTTP request disconnects.
            task.add_done_callback(lambda done: None if done.cancelled() else done.exception())
        return await asyncio.shield(task)

    async def _load(self, url: str) -> Artwork:
        try:
            async with asyncio.timeout(10), self._gate:
                result = await self._fetch(url)
            self._cache[url] = (self._clock() + self.ttl, result)
            self._bytes += len(result.body)
            while len(self._cache) > self.max_entries or self._bytes > self.max_cache_bytes:
                _, (_, old) = self._cache.popitem(last=False)
                self._bytes -= len(old.body)
            return result
        except (httpx.HTTPError, TimeoutError, ValueError, UnsafeDestination, ArtworkUnavailable) as error:
            self._failed[url] = self._clock() + 30
            self._failed.move_to_end(url)
            while len(self._failed) > self.max_entries:
                self._failed.popitem(last=False)
            raise ArtworkUnavailable("artwork temporarily unavailable") from error
        finally:
            self._pending.pop(url, None)

    async def _fetch(self, url: str) -> Artwork:
        async with httpx.AsyncClient(
            transport=self._transport or PublicHttpTransport(), trust_env=False,
            follow_redirects=False, timeout=httpx.Timeout(7, connect=4),
            headers={"User-Agent": "Zeluna/1.0 (public artwork cache)", "Accept": "image/jpeg,image/png,image/webp"},
        ) as client:
            for _ in range(3):
                async with client.stream("GET", url) as response:
                    if response.status_code in (301, 302, 303, 307, 308):
                        url = public_artwork_url(str(response.url.join(response.headers.get("location", ""))))
                        # No Set-Cookie or any caller credentials are forwarded.
                        client.cookies.clear()
                        continue
                    response.raise_for_status()
                    mime = response.headers.get("content-type", "").split(";", 1)[0].lower()
                    if mime not in {"image/jpeg", "image/png", "image/webp"}:
                        raise ArtworkUnavailable("not an artwork response")
                    declared = response.headers.get("content-length", "")
                    if declared.isdigit() and int(declared) > self.max_image_bytes:
                        raise ArtworkUnavailable("artwork exceeds size limit")
                    chunks = bytearray()
                    async for chunk in response.aiter_bytes(chunk_size=64 * 1024):
                        chunks.extend(chunk)
                        if len(chunks) > self.max_image_bytes:
                            raise ArtworkUnavailable("artwork exceeds size limit")
                    data = bytes(chunks)
                    valid = ((mime == "image/jpeg" and data.startswith(b"\xff\xd8\xff"))
                             or (mime == "image/png" and data.startswith(b"\x89PNG\r\n\x1a\n"))
                             or (mime == "image/webp" and data[:4] == b"RIFF" and data[8:12] == b"WEBP"))
                    if not valid:
                        raise ArtworkUnavailable("invalid artwork bytes")
                    return Artwork(data, mime, '"' + hashlib.sha256(data).hexdigest() + '"')
        raise ArtworkUnavailable("too many artwork redirects")

    async def aclose(self):
        tasks = list(self._pending.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._pending.clear()
        self._cache.clear()
        self._failed.clear()
        self._bytes = 0


catalog_artwork = CatalogArtworkCache()
