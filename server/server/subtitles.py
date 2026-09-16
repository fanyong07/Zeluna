"""On-demand, policy-gated subtitle providers. Never a public URL proxy.

Jimaku is deliberately disabled: its public robots rules disallow ordinary
clients (verified 2026-09-16). No environment switch bypasses that decision.
New providers must have reviewed access rules and an explicit host allowlist.
"""

import asyncio
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass
from typing import Protocol, Literal, Annotated
from urllib.parse import unquote, urljoin, urlsplit

import httpx
from pydantic import BaseModel, ConfigDict, Field

from .public_http import PublicHttpTransport
from .subtitle_library import SubtitleLibrary, LibraryError, configured_subtitle_library
import sqlite3
from .title_matching import analyze_source_match

MAX_FILE_BYTES = 5 * 1024 * 1024
ALLOWED_EXTENSIONS = {"srt", "ass", "ssa", "vtt"}


class SubtitleSearchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    subject_key: str = Field(
        min_length=3, max_length=300, pattern=r"^[A-Za-z0-9._:-]+$"
    )
    episode_key: str = Field(
        min_length=3, max_length=600, pattern=r"^[A-Za-z0-9._:|+-]+$"
    )
    language: str = Field(pattern=r"^(ja|en|zh-Hans)$")
    title: str = Field(default="", max_length=500)
    original_title: str = Field(default="", max_length=500)
    aliases: list[Annotated[str, Field(max_length=500)]] = Field(
        default_factory=list, max_length=20
    )
    media_type: Literal["anime", "series", "movie", "unknown"] = "unknown"
    year: int | None = Field(default=None, ge=1888, le=2200)
    episode_number: int = Field(ge=0, le=100000)
    season_number: int | None = Field(default=None, ge=0, le=1000)
    season_episode_number: int | None = Field(default=None, ge=0, le=100000)
    confirmed_entry_id: str | None = Field(default=None, max_length=200)


@dataclass(frozen=True)
class ProviderCandidate:
    entry_id: str
    file_name: str
    language: str
    download_url: str
    reasons: tuple[str, ...] = ()
    identity_verified: bool = False
    episode_verified: bool = False
    subject_key: str = ""
    title: str = ""
    year: int | None = None
    media_type: str = "unknown"
    season_number: int | None = None
    episode_number: int | None = None
    special: bool = False


def candidate_match(
    request: SubtitleSearchRequest, item: ProviderCandidate
) -> tuple[bool, tuple[str, ...]]:
    """Identity evidence is separate from timing, and missing season stays unknown."""
    reasons = list(item.reasons)
    analysis = analyze_source_match(
        item.title,
        [request.title, request.original_title, *request.aliases],
        candidate_type=item.media_type,
        expected_type=request.media_type,
        candidate_year=item.year or 0,
        expected_year=request.year or 0,
    )
    evidence = analysis.evidence
    if (
        item.special
        or evidence.has_explicit_identity_conflict
        or (item.subject_key and item.subject_key != request.subject_key)
        or (item.year and request.year and item.year != request.year)
    ):
        return False, (*reasons, "作品、年份、类型或特别篇存在冲突，请手动核对")
    same_identity = bool(
        item.subject_key == request.subject_key
        or (
            item.identity_verified
            and evidence.exact_title
            and item.year
            and item.year == request.year
            and evidence.media_type_known
        )
    )
    if not same_identity:
        reasons.append("作品身份尚未充分确认")
    if item.season_number is not None:
        same_episode = (
            request.season_number is not None
            and item.season_number == request.season_number
            and request.season_episode_number is not None
            and item.episode_number == request.season_episode_number
        )
    elif request.season_number is not None:
        same_episode = False
    else:
        same_episode = (
            item.episode_verified and item.episode_number == request.episode_number
        )
    if request.media_type == "movie":
        same_episode = not item.special and same_identity
    if not same_episode:
        reasons.append("集号或季号不明确，不自动绑定")
    reasons.append("时间轴未验证，请核对片源版本")
    return bool(same_identity and same_episode), tuple(reasons)


class SubtitleProvider(Protocol):
    id: str
    allowed_hosts: frozenset[str]
    policy_approved: bool

    async def search(
        self, request: SubtitleSearchRequest
    ) -> list[ProviderCandidate]: ...


class SubtitleServiceError(Exception):
    def __init__(self, code: str, status: int = 503):
        self.code = code
        self.status = status
        super().__init__(code)


@dataclass
class _CachedCandidate:
    provider: SubtitleProvider
    candidate: ProviderCandidate
    expires_at: float
    content: bytes | None = None


class SubtitleService:
    def __init__(
        self,
        providers: tuple[SubtitleProvider, ...] = (),
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        clock=time.monotonic,
        library: SubtitleLibrary | None = None,
    ):
        self.providers = providers
        self.library = library
        self._transport = transport
        self._clock = clock
        self._candidates: OrderedDict[str, _CachedCandidate] = OrderedDict()
        self._locks: dict[str, asyncio.Lock] = {}

    def _prune(self):
        for key, value in list(self._candidates.items()):
            if value.expires_at <= self._clock():
                self._candidates.pop(key, None)
                self._locks.pop(key, None)
        while len(self._candidates) > 100:
            key, _ = self._candidates.popitem(last=False)
            self._locks.pop(key, None)
        # No central subtitle mirror: a small, ten-minute memory cache only.
        cached = [value for value in self._candidates.values() if value.content]
        total = sum(len(value.content or b"") for value in cached)
        for value in cached:
            if total <= 20 * 1024 * 1024:
                break
            total -= len(value.content or b"")
            value.content = None

    async def search(self, request: SubtitleSearchRequest) -> dict:
        self._prune()
        candidates = []
        sources = []
        if self.library is not None:
            try:
                local = await asyncio.to_thread(
                    self.library.find,
                    request.subject_key,
                    request.episode_key,
                    request.language,
                )
                sources.append(
                    {"provider": "library", "status": "found" if local else "not_found"}
                )
                if local:
                    return {
                        "status": "found",
                        "message": "已找到服务器内置字幕；多个版本请核对后选择",
                        "candidates": local,
                        "sources": sources,
                    }
            except (LibraryError, OSError, sqlite3.Error, ValueError):
                sources.append(
                    {"provider": "library", "status": "provider_unavailable"}
                )
        for provider in self.providers:
            if not provider.policy_approved:
                sources.append(
                    {
                        "provider": provider.id,
                        "status": "provider_unavailable",
                        "reason": "policy_blocked",
                    }
                )
                continue
            try:
                async with asyncio.timeout(6):
                    found = await provider.search(request)
                accepted = 0
                for item in found[:40]:
                    if item.language != request.language:
                        continue
                    self._validate_url(item.download_url, provider.allowed_hosts)
                    if (
                        item.file_name.rsplit(".", 1)[-1].lower()
                        not in ALLOWED_EXTENSIONS
                    ):
                        continue
                    auto_match, reasons = candidate_match(request, item)
                    identifier = uuid.uuid4().hex
                    self._candidates[identifier] = _CachedCandidate(
                        provider, item, self._clock() + 600
                    )
                    candidates.append(
                        {
                            "id": identifier,
                            "provider": provider.id,
                            "entry_id": item.entry_id,
                            "file_name": item.file_name,
                            "language": item.language,
                            "reasons": list(reasons),
                            "auto_match": auto_match,
                            "timing_verified": False,
                        }
                    )
                    accepted += 1
                sources.append(
                    {
                        "provider": provider.id,
                        "status": "found" if accepted else "not_found",
                    }
                )
            except (httpx.HTTPError, TimeoutError, SubtitleServiceError):
                sources.append(
                    {"provider": provider.id, "status": "provider_unavailable"}
                )
        # Jimaku's website being readable anonymously is not permission to crawl.
        if request.language == "ja" and not any(
            s["provider"] == "jimaku" for s in sources
        ):
            sources.append(
                {
                    "provider": "jimaku",
                    "status": "provider_unavailable",
                    "reason": "policy_blocked",
                }
            )
        self._prune()
        status = (
            "found"
            if candidates
            else (
                "provider_unavailable"
                if any(s["status"] == "provider_unavailable" for s in sources)
                else "not_found"
                if sources
                else "manual_required"
            )
        )
        messages = {
            "found": "找到候选字幕，时间轴仍需检查",
            "provider_unavailable": "字幕来源暂不支持自动获取，请手动导入；现有字幕不受影响",
            "not_found": "服务器暂未收录本集原文字幕，现有中文字幕和播放不受影响",
            "manual_required": "当前语言暂未接入免账号在线来源，请导入原文字幕",
        }
        return {
            "status": status,
            "message": messages[status],
            "candidates": candidates,
            "sources": sources,
        }

    @staticmethod
    def _validate_url(url: str, allowed_hosts: frozenset[str]):
        try:
            parsed = urlsplit(url)
            port = parsed.port
        except ValueError:
            raise SubtitleServiceError("unsafe_destination", 400) from None
        if (
            parsed.scheme != "https"
            or parsed.hostname not in allowed_hosts
            or parsed.username is not None
            or parsed.password is not None
            or port not in (None, 443)
            or "\\" in url
            or any(ord(char) <= 32 for char in url)
            or ".." in unquote(parsed.path).split("/")
        ):
            raise SubtitleServiceError("unsafe_destination", 400)

    async def content(self, identifier: str) -> tuple[bytes, str]:
        self._prune()
        if self.library is not None:
            try:
                stored = await asyncio.to_thread(self.library.content, identifier)
                if stored is not None:
                    return stored
            except (LibraryError, OSError, sqlite3.Error, ValueError):
                raise SubtitleServiceError("library_unavailable") from None
        cached = self._candidates.get(identifier)
        if cached is None:
            raise SubtitleServiceError("candidate_expired", 404)
        if not cached.provider.policy_approved:
            raise SubtitleServiceError("policy_blocked", 403)
        lock = self._locks.setdefault(identifier, asyncio.Lock())
        async with lock:
            if cached.content is not None:
                return cached.content, cached.candidate.file_name
            url = cached.candidate.download_url
            async with httpx.AsyncClient(
                transport=self._transport or PublicHttpTransport(),
                trust_env=False,
                timeout=8,
                follow_redirects=False,
                headers={"User-Agent": "Zeluna-Subtitles/1.0"},
            ) as client:
                async with asyncio.timeout(12):
                    for _ in range(4):
                        self._validate_url(url, cached.provider.allowed_hosts)
                        # Never carry a cookie set by an upstream response.
                        client.cookies.clear()
                        async with client.stream("GET", url) as response:
                            if response.is_redirect:
                                url = urljoin(url, response.headers.get("location", ""))
                                continue
                            if response.status_code != 200:
                                raise SubtitleServiceError("provider_unavailable")
                            mime = response.headers.get("content-type", "").lower()
                            if "html" in mime or "json" in mime:
                                raise SubtitleServiceError("invalid_subtitle", 422)
                            chunks = bytearray()
                            async for chunk in response.aiter_bytes():
                                chunks.extend(chunk)
                                if len(chunks) > MAX_FILE_BYTES:
                                    raise SubtitleServiceError("file_too_large", 413)
                            if not chunks or bytes(
                                chunks[:1024]
                            ).lstrip().lower().startswith((b"<!doctype", b"<html")):
                                raise SubtitleServiceError("invalid_subtitle", 422)
                            cached.content = bytes(chunks)
                            self._prune()
                            return bytes(chunks), cached.candidate.file_name
            raise SubtitleServiceError("too_many_redirects")


subtitle_service = SubtitleService(library=configured_subtitle_library())


def get_subtitle_service() -> SubtitleService:
    return subtitle_service
