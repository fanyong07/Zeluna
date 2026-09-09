"""Server-only client for the dandanplay open danmaku network."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import ipaddress
import json
import math
import re
import socket
import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

import httpx

from . import config
from .title_matching import analyze_source_match


_API_ORIGIN = "https://api.dandanplay.net"
_SEARCH_PATH = "/api/v2/search/episodes"
_USER_AGENT = "Zeluna-Server/1.0"
_EPISODE_PATTERN = re.compile(
    r"(?:^|[^a-z0-9])(?:第\s*|ep(?:isode)?[.\s_-]*|e[.\s_-]*)?"
    r"(\d+)(?:\s*[集话話]|\b)",
    re.IGNORECASE,
)


class DandanplayError(RuntimeError):
    """A safe upstream failure that must not fail Zeluna community danmaku."""

    def __init__(self, message: str, *, code: str = "upstream_error") -> None:
        super().__init__(message)
        self.code = code
        self.retryable = code in {"timeout", "transport", "upstream_unavailable"}


def _http_failure(status: int) -> DandanplayError:
    if status in {401, 403}:
        code = "authorization"
    elif status == 429:
        code = "rate_limited"
    elif status in {408, 504}:
        code = "timeout"
    elif status in {502, 503}:
        code = "upstream_unavailable"
    else:
        code = "upstream_error"
    return DandanplayError(f"dandanplay returned HTTP {status}", code=code)


@dataclass(frozen=True)
class DandanplayResult:
    source: Mapping[str, object]
    comments: tuple[Mapping[str, object], ...] = ()


@dataclass(frozen=True)
class _EpisodeMatch:
    anime_title: str
    episode_title: str
    episode_id: int


@dataclass(frozen=True)
class _CachedResult:
    value: DandanplayResult
    expires_at: float


@dataclass(frozen=True)
class _HttpResult:
    status_code: int
    headers: httpx.Headers
    body: bytes


ResolveHost = Callable[[str], Awaitable[list[str]]]
BeforeUpstream = Callable[[], Awaitable[None]]


class DandanplayClient:
    """Authenticated dandanplay search/comment client with bounded caching."""

    def __init__(
        self,
        *,
        enabled: bool | None = None,
        app_id: str | None = None,
        app_secret: str | None = None,
        timeout_seconds: float | None = None,
        cache_seconds: int | None = None,
        empty_cache_seconds: int | None = None,
        cache_max_entries: int | None = None,
        max_response_bytes: int | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        resolve_host: ResolveHost | None = None,
        clock: Callable[[], float] = time.monotonic,
        unix_time: Callable[[], float] = time.time,
    ) -> None:
        self._enabled = config.DANDANPLAY_ENABLED if enabled is None else enabled
        self._app_id = (config.DANDANPLAY_APP_ID if app_id is None else app_id).strip()
        self._app_secret = (
            config.DANDANPLAY_APP_SECRET if app_secret is None else app_secret
        ).strip()
        self._timeout_seconds = (
            config.DANDANPLAY_REQUEST_TIMEOUT_SECONDS
            if timeout_seconds is None
            else timeout_seconds
        )
        self._cache_seconds = (
            config.DANDANPLAY_CACHE_SECONDS if cache_seconds is None else cache_seconds
        )
        self._empty_cache_seconds = (
            config.DANDANPLAY_EMPTY_CACHE_SECONDS
            if empty_cache_seconds is None
            else empty_cache_seconds
        )
        self._cache_max_entries = max(
            1,
            config.DANDANPLAY_CACHE_MAX_ENTRIES
            if cache_max_entries is None
            else cache_max_entries,
        )
        self._max_response_bytes = (
            config.DANDANPLAY_MAX_RESPONSE_BYTES
            if max_response_bytes is None
            else max_response_bytes
        )
        self._transport = transport
        self._resolve_host = resolve_host or _resolve_public_addresses
        self._clock = clock
        self._unix_time = unix_time
        self._cache: dict[str, _CachedResult] = {}
        self._in_flight: dict[str, asyncio.Task[DandanplayResult]] = {}

    @staticmethod
    def signature(app_id: str, timestamp: int, path: str, app_secret: str) -> str:
        """Return Base64(SHA256(AppId + Timestamp + Path + AppSecret))."""

        digest = hashlib.sha256(
            f"{app_id}{timestamp}{path}{app_secret}".encode()
        ).digest()
        return base64.b64encode(digest).decode("ascii")

    async def comments_for_episode(
        self,
        *,
        title: str,
        original_title: str,
        episode_number: int,
        media_type: str,
        before_upstream: BeforeUpstream | None = None,
    ) -> DandanplayResult:
        normalized_title = " ".join(title.split())
        normalized_original = " ".join(original_title.split())
        normalized_type = media_type.strip().lower() or "anime"
        key = "|".join(
            (
                normalized_title.casefold(),
                normalized_original.casefold(),
                str(episode_number),
                normalized_type,
            )
        )
        now = self._clock()
        cached = self._cache.get(key)
        if cached is not None:
            if cached.expires_at > now:
                return cached.value
            self._cache.pop(key, None)

        task = self._in_flight.get(key)
        if task is None:
            task = asyncio.create_task(
                self._load_and_cache(
                    key=key,
                    title=normalized_title,
                    original_title=normalized_original,
                    episode_number=episode_number,
                    media_type=normalized_type,
                    before_upstream=before_upstream,
                )
            )
            self._in_flight[key] = task
            task.add_done_callback(
                lambda completed, cache_key=key: self._finish_in_flight(
                    cache_key, completed
                )
            )
        return await asyncio.shield(task)

    async def _load_and_cache(
        self,
        *,
        key: str,
        title: str,
        original_title: str,
        episode_number: int,
        media_type: str,
        before_upstream: BeforeUpstream | None,
    ) -> DandanplayResult:
        if before_upstream is not None:
            await before_upstream()
        result = await self._load(
            title=title,
            original_title=original_title,
            episode_number=episode_number,
            media_type=media_type,
        )
        ttl = self._cache_seconds if result.comments else self._empty_cache_seconds
        self._store_cache(key, result, ttl=ttl)
        return result

    def _finish_in_flight(
        self,
        key: str,
        task: asyncio.Task[DandanplayResult],
    ) -> None:
        if self._in_flight.get(key) is task:
            self._in_flight.pop(key, None)
        if task.cancelled():
            return
        try:
            task.exception()
        except Exception:
            # The awaiting caller still receives the exception. Reading it here only
            # prevents an orphaned shared task from producing an unhandled warning.
            pass

    def _store_cache(
        self,
        key: str,
        result: DandanplayResult,
        *,
        ttl: int,
    ) -> None:
        now = self._clock()
        expired_keys = [
            cached_key
            for cached_key, cached in self._cache.items()
            if cached.expires_at <= now
        ]
        for expired_key in expired_keys:
            self._cache.pop(expired_key, None)

        self._cache.pop(key, None)
        while len(self._cache) >= self._cache_max_entries:
            oldest_key = next(iter(self._cache))
            self._cache.pop(oldest_key, None)
        self._cache[key] = _CachedResult(
            value=result,
            expires_at=now + ttl,
        )

    async def _load(
        self,
        *,
        title: str,
        original_title: str,
        episode_number: int,
        media_type: str,
    ) -> DandanplayResult:
        if not self._enabled:
            return self._unavailable(
                title=title,
                episode_number=episode_number,
                message="Zeluna 服务端尚未启用弹弹play弹幕",
                code="disabled",
            )
        if not self._app_id or not self._app_secret:
            return self._unavailable(
                title=title,
                episode_number=episode_number,
                message="Zeluna 服务端尚未配置弹弹play开放平台凭据",
                code="not_configured",
            )
        if episode_number < 1:
            return self._unavailable(
                title=title,
                episode_number=episode_number,
                message="当前集数无法用于匹配弹弹play弹幕库",
                code="invalid_input",
            )

        aliases = _unique_texts((title, original_title))
        keywords = [item for item in aliases if len(item) >= 2]
        if not keywords:
            return self._unavailable(
                title=title,
                episode_number=episode_number,
                message="作品标题过短，无法匹配弹弹play弹幕库",
                code="invalid_input",
            )

        async with httpx.AsyncClient(
            transport=self._transport,
            follow_redirects=False,
            timeout=self._timeout_seconds,
        ) as client:
            selected: _EpisodeMatch | None = None
            for keyword in keywords:
                payload = await self._search(
                    client,
                    keyword=keyword,
                    episode_number=episode_number,
                    media_type=media_type,
                )
                selected = self._select_episode(
                    payload,
                    aliases=aliases,
                    episode_number=episode_number,
                    media_type=media_type,
                )
                if selected is not None:
                    break

            if selected is None:
                return self._unavailable(
                    title=title,
                    episode_number=episode_number,
                    message="弹弹play 没有可靠匹配到当前作品与集数",
                    code="no_match",
                )

            comments = await self._comments(client, selected.episode_id)

        source = {
            "provider": "弹弹play",
            "title": selected.anime_title,
            "episode_title": selected.episode_title,
            "episode_id": str(selected.episode_id),
            "comment_count": len(comments),
            "available": bool(comments),
            "message": None if comments else "已匹配弹幕库，但没有返回弹幕内容",
            "error_code": None,
            "retryable": False,
        }
        return DandanplayResult(source=source, comments=tuple(comments))

    async def _search(
        self,
        client: httpx.AsyncClient,
        *,
        keyword: str,
        episode_number: int,
        media_type: str,
    ) -> Mapping[str, Any]:
        params: dict[str, str] = {"anime": keyword, "v2": "true"}
        if media_type != "movie":
            params["episode"] = str(episode_number)
        response = await self._authenticated_request(
            client,
            path=_SEARCH_PATH,
            params=params,
        )
        if response.status_code in {401, 403}:
            raise _http_failure(response.status_code)
        if response.status_code != 200:
            raise _http_failure(response.status_code)
        payload = _decode_json_object(response.body)
        error_code = _as_int(payload.get("errorCode"))
        if payload.get("success") is False or error_code not in {None, 0}:
            raise DandanplayError("dandanplay search returned a business error")
        return payload

    async def _comments(
        self,
        client: httpx.AsyncClient,
        episode_id: int,
    ) -> list[Mapping[str, object]]:
        path = f"/api/v2/comment/{episode_id}"
        response = await self._authenticated_request(
            client,
            path=path,
            params={"from": "0", "withRelated": "true", "chConvert": "1"},
            read_redirect_body=False,
        )
        if response.status_code in {401, 403}:
            raise _http_failure(response.status_code)
        if response.status_code == 302:
            location = response.headers.get("location", "").strip()
            await self._ensure_safe_redirect(location)
            response = await self._request(
                client,
                location,
                headers={"Accept": "application/json", "User-Agent": _USER_AGENT},
            )
        if response.status_code != 200:
            raise _http_failure(response.status_code)
        payload = _decode_json_object(response.body)
        error_code = _as_int(payload.get("errorCode"))
        if payload.get("success") is False or error_code not in {None, 0}:
            raise DandanplayError("dandanplay comments returned a business error")
        raw_comments = payload.get("comments")
        if not isinstance(raw_comments, list):
            return []
        comments: list[Mapping[str, object]] = []
        for raw in raw_comments:
            parsed = _parse_comment(raw, episode_id=episode_id)
            if parsed is not None:
                comments.append(parsed)
        comments.sort(key=lambda item: (float(item["time_seconds"]), str(item["id"])))
        return comments

    async def _authenticated_request(
        self,
        client: httpx.AsyncClient,
        *,
        path: str,
        params: Mapping[str, str],
        read_redirect_body: bool = True,
    ) -> _HttpResult:
        timestamp = int(self._unix_time())
        headers = {
            "Accept": "application/json",
            "User-Agent": _USER_AGENT,
            "X-AppId": self._app_id,
            "X-Timestamp": str(timestamp),
            "X-Signature": self.signature(
                self._app_id,
                timestamp,
                path,
                self._app_secret,
            ),
        }
        return await self._request(
            client,
            f"{_API_ORIGIN}{path}",
            headers=headers,
            params=params,
            read_redirect_body=read_redirect_body,
        )

    async def _request(
        self,
        client: httpx.AsyncClient,
        url: str,
        *,
        headers: Mapping[str, str],
        params: Mapping[str, str] | None = None,
        read_redirect_body: bool = True,
    ) -> _HttpResult:
        try:
            async with client.stream(
                "GET",
                url,
                headers=headers,
                params=params,
            ) as response:
                if response.status_code == 302 and not read_redirect_body:
                    return _HttpResult(response.status_code, response.headers, b"")
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) > self._max_response_bytes:
                        raise DandanplayError("dandanplay response exceeded size limit")
                return _HttpResult(response.status_code, response.headers, bytes(body))
        except DandanplayError:
            raise
        except (httpx.TimeoutException, TimeoutError) as error:
            raise DandanplayError(
                "dandanplay request timed out", code="timeout"
            ) from error
        except httpx.NetworkError as error:
            raise DandanplayError(
                "dandanplay transport failed", code="transport"
            ) from error
        except httpx.HTTPError as error:
            raise DandanplayError("dandanplay request failed") from error

    async def _ensure_safe_redirect(self, url: str) -> None:
        try:
            parsed = urlsplit(url)
            port = parsed.port
        except ValueError as error:
            raise DandanplayError("invalid dandanplay redirect URL") from error
        host = (parsed.hostname or "").rstrip(".").casefold()
        if (
            parsed.scheme.casefold() != "https"
            or not host
            or parsed.username is not None
            or parsed.password is not None
            or port not in {None, 443}
            or host == "localhost"
            or host.endswith(".localhost")
            or host.endswith(".local")
        ):
            raise DandanplayError("unsafe dandanplay redirect URL")
        addresses = await self._resolve_host(host)
        if not addresses:
            raise DandanplayError("dandanplay redirect host did not resolve")
        for value in addresses:
            try:
                address = ipaddress.ip_address(value)
            except ValueError as error:
                raise DandanplayError("invalid dandanplay redirect address") from error
            if not address.is_global:
                raise DandanplayError("unsafe dandanplay redirect address")

    @staticmethod
    def _select_episode(
        payload: Mapping[str, Any],
        *,
        aliases: list[str],
        episode_number: int,
        media_type: str,
    ) -> _EpisodeMatch | None:
        raw_animes = payload.get("animes")
        if not isinstance(raw_animes, list):
            return None
        best: tuple[int, _EpisodeMatch] | None = None
        for raw_anime in raw_animes:
            if not isinstance(raw_anime, Mapping):
                continue
            anime_title = _text(raw_anime.get("animeTitle"))
            if not anime_title:
                continue
            candidate_type = _candidate_media_type(
                _text(raw_anime.get("type")),
                expected_type=media_type,
            )
            analysis = analyze_source_match(
                anime_title,
                aliases,
                candidate_type=candidate_type,
                expected_type=media_type,
                candidate_year=0,
                expected_year=0,
            )
            if not analysis.playback_eligible:
                continue
            raw_episodes = raw_anime.get("episodes")
            if not isinstance(raw_episodes, list):
                continue
            for raw_episode in raw_episodes:
                if not isinstance(raw_episode, Mapping):
                    continue
                episode_id = _as_int(raw_episode.get("episodeId")) or 0
                episode_title = _text(raw_episode.get("episodeTitle"))
                if episode_id <= 0:
                    continue
                if (
                    media_type != "movie"
                    and _episode_number(episode_title) != episode_number
                ):
                    continue
                match = _EpisodeMatch(
                    anime_title=anime_title,
                    episode_title=episode_title
                    or ("电影" if media_type == "movie" else f"第 {episode_number} 集"),
                    episode_id=episode_id,
                )
                score = analysis.ranking_score
                if best is None or score > best[0]:
                    best = (score, match)
        return None if best is None else best[1]

    @staticmethod
    def _unavailable(
        *,
        title: str,
        episode_number: int,
        message: str,
        code: str,
    ) -> DandanplayResult:
        return DandanplayResult(
            source={
                "provider": "弹弹play",
                "title": title or "弹弹play 弹幕源",
                "episode_title": f"第 {episode_number} 集",
                "episode_id": "",
                "comment_count": 0,
                "available": False,
                "message": message,
                "error_code": code,
                "retryable": False,
            }
        )


async def _resolve_public_addresses(host: str) -> list[str]:
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None:
        return [str(literal)]
    loop = asyncio.get_running_loop()
    try:
        records = await loop.getaddrinfo(
            host,
            443,
            family=socket.AF_UNSPEC,
            type=socket.SOCK_STREAM,
        )
    except OSError as error:
        raise DandanplayError("dandanplay redirect DNS lookup failed") from error
    return list({record[4][0] for record in records})


def _decode_json_object(body: bytes) -> Mapping[str, Any]:
    try:
        payload = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DandanplayError("dandanplay returned invalid JSON") from error
    if not isinstance(payload, Mapping):
        raise DandanplayError("dandanplay returned an invalid JSON object")
    return payload


def _parse_comment(
    value: object,
    *,
    episode_id: int,
) -> Mapping[str, object] | None:
    if not isinstance(value, Mapping):
        return None
    cid = _as_int(value.get("cid")) or 0
    text = _text(value.get("m"))
    packed = _text(value.get("p"))
    parts = packed.split(",")
    if cid <= 0 or not text or len(parts) < 3:
        return None
    try:
        seconds = float(parts[0])
    except ValueError:
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    mode = {4: "bottom", 5: "top"}.get(_as_int(parts[1]) or 1, "scroll")
    color = _as_int(parts[2])
    if color is None or color < 0 or color > 0xFFFFFF:
        return None
    author = parts[3].strip() if len(parts) >= 4 else ""
    return {
        "id": f"dandanplay:{episode_id}:{cid}",
        "provider": "弹弹play",
        "time_seconds": seconds,
        "mode": mode,
        "color": color,
        "text": text,
        "author": {"display_name": author, "is_mine": False},
    }


def _episode_number(value: str) -> int | None:
    cleaned = value.strip()
    direct = float(cleaned) if re.fullmatch(r"\d+(?:\.0+)?", cleaned) else None
    if direct is not None and direct.is_integer():
        return int(direct)
    match = _EPISODE_PATTERN.search(cleaned)
    return int(match.group(1)) if match is not None else None


def _candidate_media_type(value: str, *, expected_type: str) -> str:
    normalized = value.casefold()
    if normalized in {"movie", "jpmovie", "tmdbmovie"}:
        return "movie"
    if normalized in {"jpdrama", "tmdbtv"}:
        return "tv"
    if normalized == "tvseries" and expected_type in {"series", "tv"}:
        return "tv"
    return "anime"


def _unique_texts(values: tuple[str, ...]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        normalized = " ".join(value.split())
        key = normalized.casefold()
        if normalized and key not in seen:
            seen.add(key)
            result.append(normalized)
    return result


def _text(value: object) -> str:
    return " ".join(str(value or "").split())


def _as_int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


_default_client: DandanplayClient | None = None


def get_dandanplay_client() -> DandanplayClient:
    global _default_client
    if _default_client is None:
        _default_client = DandanplayClient()
    return _default_client
