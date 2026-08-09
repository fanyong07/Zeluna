"""Bangumi + TMDB 统一元数据目录。

客户端只接触 ``bangumi:{id}``、``tmdb:tv:{id}`` 和
``tmdb:movie:{id}`` 三种稳定 ID。个人 API Token 只存在服务端环境变量中。
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Awaitable, Callable
from email.utils import parsedate_to_datetime
from typing import Any

import httpx
from sqlalchemy.ext.asyncio import AsyncSession

from .config import (
    BANGUMI_ACCESS_TOKEN,
    CATALOG_CACHE_HOURS,
    TMDB_READ_ACCESS_TOKEN,
)
from .repositories.catalog import (
    CatalogRepository,
    CatalogWrite,
    SqlCatalogRepository,
)

logger = logging.getLogger(__name__)

_BANGUMI_API = "https://api.bgm.tv"
_TMDB_API = "https://api.themoviedb.org/3"
_TMDB_IMAGE = "https://image.tmdb.org/t/p"
_USER_AGENT = "Zeluna/1.0 (metadata aggregator)"
_HOME_MAX_ITEMS = 300
_HOME_REFRESH_TARGET = 120
_HOME_FRESH_MIN_ITEMS = 80
_HOME_RANKING_FRESH_SECONDS = 6 * 3600
_HOME_RANKING_STALE_SECONDS = 72 * 3600
_RRF_K = 60.0
_PROVIDER_MAX_CONCURRENCY = 2
_PROVIDER_DEFAULT_COOLDOWN_SECONDS = 30.0
_PROVIDER_MAX_COOLDOWN_SECONDS = 5 * 60.0
_BANGUMI_HOME_MAX_PAGES = 2
_TMDB_HOME_MAX_PAGES = 2

_BANGUMI_RANKING_WEIGHTS = {
    "calendar": 1.15,
    "heat": 1.25,
    "score": 1.0,
    "rank": 1.1,
}
_TMDB_RANKING_WEIGHTS = {
    "trending_week": 1.25,
    "popular": 1.1,
    "top_rated": 1.0,
    "current": 1.15,
}

_TMDB_GENRE_NAMES = {
    "movie": {
        12: "冒险",
        14: "奇幻",
        16: "动画",
        18: "剧情",
        27: "恐怖",
        28: "动作",
        35: "喜剧",
        36: "历史",
        37: "西部",
        53: "惊悚",
        80: "犯罪",
        99: "纪录",
        878: "科幻",
        9648: "悬疑",
        10402: "音乐",
        10749: "爱情",
        10751: "家庭",
        10752: "战争",
        10770: "电视电影",
    },
    "tv": {
        16: "动画",
        18: "剧情",
        35: "喜剧",
        37: "西部",
        80: "犯罪",
        99: "纪录",
        9648: "悬疑",
        10751: "家庭",
        10759: "动作冒险",
        10762: "儿童",
        10763: "新闻",
        10764: "真人秀",
        10765: "科幻奇幻",
        10766: "肥皂剧",
        10767: "脱口秀",
        10768: "战争政治",
    },
}


def parse_stable_id(value: str) -> tuple[str, str, str] | None:
    parts = value.strip().lower().split(":")
    if len(parts) == 2 and parts[0] == "bangumi" and parts[1].isdigit():
        return "bangumi", "anime", parts[1]
    if (
        len(parts) == 3
        and parts[0] == "tmdb"
        and parts[1] in {"tv", "movie"}
        and parts[2].isdigit()
    ):
        return "tmdb", parts[1], parts[2]
    return None


def _clean_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _unique_text(values) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for raw in values:
        value = _clean_text(raw)
        key = value.casefold()
        if value and key not in seen:
            seen.add(key)
            result.append(value)
    return result


def _interleave_unique(groups: list[list[dict]]) -> list[dict]:
    """Mix provider lists so one ranking does not crowd out every other one."""
    result: list[dict] = []
    seen: set[str] = set()
    max_length = max((len(group) for group in groups), default=0)
    for index in range(max_length):
        for group in groups:
            if index >= len(group):
                continue
            item = group[index]
            stable_id = _clean_text(item.get("stable_id"))
            if not stable_id or stable_id in seen:
                continue
            seen.add(stable_id)
            result.append(item)
    return result


def _merge_ranked_candidates(
    *groups: list[dict],
    limit: int,
) -> list[dict]:
    result: list[dict] = []
    seen: set[str] = set()
    for group in groups:
        for item in group:
            stable_id = _clean_text(item.get("stable_id"))
            if not stable_id or stable_id in seen:
                continue
            seen.add(stable_id)
            result.append(item)
            if len(result) >= limit:
                return result
    return result


def _catalog_item_quality(item: dict) -> tuple[int, int]:
    populated = sum(
        bool(item.get(key))
        for key in (
            "summary",
            "cover_url",
            "banner_url",
            "date",
            "genres",
            "rating",
            "rating_count",
            "total_episodes",
        )
    )
    return populated, len(_clean_text(item.get("summary")))


def _weighted_rrf(
    provider: str,
    groups: list[tuple[str, float, list[dict]]],
    *,
    ranked_at: float,
    batch_id: str,
) -> list[dict]:
    candidates: dict[str, dict[str, Any]] = {}
    for kind, weight, items in groups:
        seen_in_list: set[str] = set()
        for rank, item in enumerate(items, 1):
            stable_id = _clean_text(item.get("stable_id"))
            if not stable_id or stable_id in seen_in_list:
                continue
            seen_in_list.add(stable_id)
            record = candidates.setdefault(
                stable_id,
                {
                    "item": item,
                    "score": 0.0,
                    "lists": [],
                },
            )
            if _catalog_item_quality(item) > _catalog_item_quality(record["item"]):
                record["item"] = item
            record["score"] += weight / (_RRF_K + rank)
            record["lists"].append(
                {
                    "provider": provider,
                    "kind": kind,
                    "rank": rank,
                }
            )

    result: list[dict] = []
    for record in candidates.values():
        item = dict(record["item"])
        score = round(float(record["score"]), 12)
        item["ranking"] = {
            "batchId": batch_id,
            "rankedAt": ranked_at,
            "globalScore": score,
            "lists": record["lists"],
        }
        result.append(item)
    result.sort(
        key=lambda item: (
            -float(item["ranking"]["globalScore"]),
            -float(item.get("popularity") or 0),
            _clean_text(item.get("stable_id")),
        )
    )
    if not result:
        return result
    raw_scores = [float(item["ranking"]["globalScore"]) for item in result]
    minimum = min(raw_scores)
    maximum = max(raw_scores)
    spread = maximum - minimum
    for item, raw_score in zip(result, raw_scores):
        normalized = 1.0 if spread <= 0 else (raw_score - minimum) / spread
        item["ranking"]["globalScore"] = round(
            max(0.0, min(1.0, normalized)),
            12,
        )
    return result


def _is_complete_detail(item: Any) -> bool:
    return isinstance(item, dict) and item.get("detail_complete") is True


def _image(path: Any, size: str) -> str:
    value = _clean_text(path)
    return f"{_TMDB_IMAGE}/{size}{value}" if value.startswith("/") else value


class CatalogService:
    def __init__(
        self,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        repository_factory: Callable[[AsyncSession], CatalogRepository] = (
            SqlCatalogRepository
        ),
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ):
        self._repository_factory = repository_factory
        self._clock = clock
        self._sleep = sleep
        self._provider_semaphores: dict[str, asyncio.Semaphore] = {}
        self._provider_cooldown_until: dict[str, float] = {}
        self._home_refreshes: dict[str, asyncio.Task[list[dict]]] = {}
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(12, connect=6),
            follow_redirects=True,
            transport=transport,
            headers={"User-Agent": _USER_AGENT, "Accept": "application/json"},
        )

    async def aclose(self) -> None:
        refreshes = list(self._home_refreshes.values())
        self._home_refreshes.clear()
        for task in refreshes:
            if not task.done():
                task.cancel()
        if refreshes:
            await asyncio.gather(*refreshes, return_exceptions=True)
        await self._client.aclose()

    @property
    def provider_status(self) -> dict[str, bool]:
        return {
            "bangumi": True,
            "bangumi_authenticated": bool(BANGUMI_ACCESS_TOKEN),
            "tmdb": bool(TMDB_READ_ACCESS_TOKEN),
        }

    async def _home_candidates_singleflight(
        self,
        media_type: str,
        repository: CatalogRepository,
    ) -> list[dict]:
        task = self._home_refreshes.get(media_type)
        if task is None:
            task = asyncio.create_task(
                self._refresh_home_candidates(media_type, repository)
            )
            self._home_refreshes[media_type] = task

            def remove(completed: asyncio.Task[list[dict]]) -> None:
                if self._home_refreshes.get(media_type) is completed:
                    self._home_refreshes.pop(media_type, None)

            task.add_done_callback(remove)
        return await asyncio.shield(task)

    async def _refresh_home_candidates(
        self,
        media_type: str,
        repository: CatalogRepository,
    ) -> list[dict]:
        items = (
            await self._load_home_candidates(media_type, _HOME_REFRESH_TARGET)
        )[:_HOME_REFRESH_TARGET]
        if items:
            await self._persist_many(repository, items)
        return items

    async def _load_home_candidates(
        self,
        media_type: str,
        limit: int,
    ) -> list[dict]:
        ranked_at = self._clock()
        if media_type == "anime":
            return await self._bangumi_home(limit, ranked_at=ranked_at)
        if media_type in {"tv", "movie"} and TMDB_READ_ACCESS_TOKEN:
            return await self._tmdb_home(
                media_type,
                limit,
                ranked_at=ranked_at,
            )
        return []

    def _provider_semaphore(self, provider: str) -> asyncio.Semaphore:
        semaphore = self._provider_semaphores.get(provider)
        if semaphore is None:
            semaphore = asyncio.Semaphore(_PROVIDER_MAX_CONCURRENCY)
            self._provider_semaphores[provider] = semaphore
        return semaphore

    async def _wait_for_provider_cooldown(self, provider: str) -> None:
        until = self._provider_cooldown_until.get(provider, 0.0)
        delay = until - self._clock()
        if delay > 0:
            await self._sleep(delay)

    async def _provider_request(
        self,
        provider: str,
        method: str,
        url: str,
        **kwargs: Any,
    ) -> httpx.Response:
        await self._wait_for_provider_cooldown(provider)
        async with self._provider_semaphore(provider):
            # A queued request may have observed the old cooldown before a
            # preceding request received 429, so check again inside the gate.
            await self._wait_for_provider_cooldown(provider)
            response = await self._client.request(method, url, **kwargs)
            if response.status_code == 429:
                cooldown = self._retry_after_seconds(response)
                candidate = self._clock() + cooldown
                self._provider_cooldown_until[provider] = max(
                    self._provider_cooldown_until.get(provider, 0.0),
                    candidate,
                )
            return response

    def _retry_after_seconds(self, response: httpx.Response) -> float:
        raw = response.headers.get("retry-after", "").strip()
        try:
            seconds = float(raw)
        except ValueError:
            try:
                retry_at = parsedate_to_datetime(raw).timestamp()
            except (TypeError, ValueError, OverflowError):
                seconds = _PROVIDER_DEFAULT_COOLDOWN_SECONDS
            else:
                seconds = retry_at - self._clock()
        return max(1.0, min(_PROVIDER_MAX_COOLDOWN_SECONDS, seconds))

    async def search(
        self,
        keyword: str,
        media_types: list[str] | None,
        session: AsyncSession,
        *,
        limit: int = 40,
    ) -> list[dict]:
        query = keyword.strip()
        if not query:
            return []
        fresh_after = self._clock() - CATALOG_CACHE_HOURS * 3600
        repository = self._repository_factory(session)
        cached = await repository.search_cached(
            query=query,
            fresh_after=fresh_after,
            limit=max(1, min(limit, 100)),
        )
        if len(cached) >= min(5, limit):
            return cached
        requested = set(media_types or ("anime", "tv", "movie"))
        tasks = []
        if "anime" in requested:
            tasks.append(self._bangumi_search(query, min(limit, 30)))
        if TMDB_READ_ACCESS_TOKEN and requested.intersection({"tv", "movie"}):
            tasks.append(self._tmdb_search(query, requested, min(limit, 40)))
        groups = await asyncio.gather(*tasks, return_exceptions=True)
        items: list[dict] = []
        for group in groups:
            if isinstance(group, Exception):
                logger.warning("Metadata search provider failed: %s", type(group).__name__)
                continue
            items.extend(group)
        unique: dict[str, dict] = {}
        for item in items:
            unique[item["stable_id"]] = item
        result = list(unique.values())[: max(1, min(limit, 100))]
        await self._persist_many(repository, result)
        return result

    async def home(
        self,
        media_type: str,
        session: AsyncSession,
        *,
        limit: int = 60,
    ) -> list[dict]:
        now = self._clock()
        repository = self._repository_factory(session)
        requested_limit = max(1, min(limit, _HOME_MAX_ITEMS))
        fresh = await repository.home_cached(
            media_type=media_type,
            fresh_after=now - _HOME_RANKING_FRESH_SECONDS,
            limit=requested_limit,
        )
        fresh_threshold = min(requested_limit, _HOME_FRESH_MIN_ITEMS)
        if len(fresh) >= fresh_threshold:
            return fresh
        stale = await repository.home_cached(
            media_type=media_type,
            fresh_after=now - _HOME_RANKING_STALE_SECONDS,
            limit=requested_limit,
        )
        try:
            items = await self._home_candidates_singleflight(
                media_type,
                repository,
            )
        except Exception as error:
            logger.warning(
                "Metadata home refresh failed for %s: %s",
                media_type,
                type(error).__name__,
            )
            items = []
        items = items[: min(requested_limit, _HOME_REFRESH_TARGET)]
        return _merge_ranked_candidates(
            items,
            fresh,
            stale,
            limit=requested_limit,
        )

    async def get_subject(
        self,
        stable_id: str,
        session: AsyncSession,
        *,
        refresh: bool = False,
    ) -> dict | None:
        identity = parse_stable_id(stable_id)
        if identity is None:
            return None
        repository = self._repository_factory(session)
        cached = await repository.get_cached(stable_id)
        fresh_after = self._clock() - CATALOG_CACHE_HOURS * 3600
        cached_item = cached.metadata if cached is not None else None
        if (
            cached_item is not None
            and not refresh
            and cached is not None
            and cached.updated_at >= fresh_after
            and _is_complete_detail(cached_item)
        ):
            return cached_item
        provider, media_type, provider_id = identity
        if provider == "bangumi":
            item = await self._bangumi_detail(provider_id)
        elif TMDB_READ_ACCESS_TOKEN:
            item = await self._tmdb_detail(media_type, provider_id)
        else:
            item = None
        if item is not None:
            await self._persist_many(repository, [item])
            return item
        return cached_item

    async def _persist_many(
        self,
        repository: CatalogRepository,
        items: list[dict],
    ) -> None:
        if not items:
            return
        now = self._clock()
        entries: list[CatalogWrite] = []
        for item in items:
            stable_id = _clean_text(item.get("stable_id"))
            identity = parse_stable_id(stable_id)
            if identity is None:
                continue
            ranking = item.get("ranking")
            ranking = ranking if isinstance(ranking, dict) else None
            metadata = dict(item)
            metadata.pop("ranking", None)
            ranked_at = (
                float(ranking.get("rankedAt") or 0) if ranking is not None else None
            )
            if ranked_at is not None and ranked_at <= 0:
                ranked_at = None
            entries.append(
                CatalogWrite(
                    stable_id=stable_id,
                    provider=identity[0],
                    provider_id=identity[2],
                    media_type=identity[1],
                    title=_clean_text(item.get("title")),
                    original_title=_clean_text(item.get("original_title")),
                    aliases_json=json.dumps(
                        item.get("aliases", []),
                        ensure_ascii=False,
                    ),
                    metadata_json=json.dumps(metadata, ensure_ascii=False),
                    popularity=float(item.get("popularity") or 0),
                    updated_at=now,
                    ranking_json=(
                        json.dumps(ranking, ensure_ascii=False)
                        if ranked_at is not None
                        else None
                    ),
                    ranking_score=(
                        float(ranking.get("globalScore") or 0)
                        if ranked_at is not None and ranking is not None
                        else None
                    ),
                    ranked_at=ranked_at,
                )
            )
        await repository.persist_many(entries)

    def _bangumi_headers(self) -> dict[str, str]:
        headers = {"User-Agent": _USER_AGENT, "Accept": "application/json"}
        if BANGUMI_ACCESS_TOKEN:
            headers["Authorization"] = f"Bearer {BANGUMI_ACCESS_TOKEN}"
        return headers

    def _tmdb_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {TMDB_READ_ACCESS_TOKEN}",
            "Accept": "application/json",
            "User-Agent": _USER_AGENT,
        }

    async def _bangumi_search(self, keyword: str, limit: int) -> list[dict]:
        response = await self._provider_request(
            "bangumi",
            "POST",
            f"{_BANGUMI_API}/v0/search/subjects",
            headers=self._bangumi_headers(),
            params={"limit": limit, "offset": 0},
            json={
                "keyword": keyword,
                "sort": "match",
                "filter": {"type": [2]},
            },
        )
        if response.status_code != 200:
            return []
        payload = response.json()
        return [
            item
            for raw in payload.get("data", [])
            if isinstance(raw, dict)
            for item in [self._subject_from_bangumi(raw)]
            if item is not None
        ]

    async def _bangumi_calendar(self) -> list[dict]:
        response = await self._provider_request(
            "bangumi",
            "GET",
            f"{_BANGUMI_API}/calendar",
            headers=self._bangumi_headers(),
        )
        if response.status_code != 200:
            return []
        items: list[dict] = []
        for day in response.json() if isinstance(response.json(), list) else []:
            for raw in day.get("items", []) if isinstance(day, dict) else []:
                if not isinstance(raw, dict):
                    continue
                item = self._subject_from_bangumi(raw)
                if item is not None:
                    items.append(item)
        return items

    async def _bangumi_home(
        self,
        limit: int,
        *,
        ranked_at: float,
    ) -> list[dict]:
        groups = await asyncio.gather(
            self._bangumi_calendar(),
            self._bangumi_search_sorted("heat", limit),
            self._bangumi_search_sorted("score", limit),
            self._bangumi_ranked(limit),
            return_exceptions=True,
        )
        names = ("calendar", "heat", "score", "rank")
        ranked_groups = [
            (
                name,
                _BANGUMI_RANKING_WEIGHTS[name],
                group if isinstance(group, list) else [],
            )
            for name, group in zip(names, groups)
        ]
        return _weighted_rrf(
            "bangumi",
            ranked_groups,
            ranked_at=ranked_at,
            batch_id=f"bangumi:anime:{int(ranked_at * 1000)}",
        )[:limit]

    async def _bangumi_search_sorted(self, sort: str, limit: int) -> list[dict]:
        page_size = 20
        fetch_limit = min(limit, page_size * _BANGUMI_HOME_MAX_PAGES)
        requests = [
            self._provider_request(
                "bangumi",
                "POST",
                f"{_BANGUMI_API}/v0/search/subjects",
                headers={**self._bangumi_headers(), "Content-Type": "application/json"},
                params={
                    "limit": min(page_size, limit - offset),
                    "offset": offset,
                },
                json={
                    "keyword": "",
                    "sort": sort,
                    "filter": {"type": [2]},
                },
            )
            for offset in range(0, fetch_limit, page_size)
        ]
        responses = await asyncio.gather(*requests, return_exceptions=True)
        items: list[dict] = []
        for response in responses:
            if isinstance(response, Exception) or response.status_code != 200:
                continue
            payload = response.json()
            for raw in payload.get("data", []) if isinstance(payload, dict) else []:
                if not isinstance(raw, dict) or raw.get("nsfw") is True:
                    continue
                item = self._subject_from_bangumi(raw)
                if item is not None:
                    items.append(item)
        return items

    async def _bangumi_ranked(self, limit: int) -> list[dict]:
        page_size = 100
        fetch_limit = min(limit, page_size * _BANGUMI_HOME_MAX_PAGES)
        requests = [
            self._provider_request(
                "bangumi",
                "GET",
                f"{_BANGUMI_API}/v0/subjects",
                headers=self._bangumi_headers(),
                params={
                    "type": 2,
                    "sort": "rank",
                    "limit": min(page_size, limit - offset),
                    "offset": offset,
                },
            )
            for offset in range(0, fetch_limit, page_size)
        ]
        responses = await asyncio.gather(*requests, return_exceptions=True)
        items: list[dict] = []
        for response in responses:
            if isinstance(response, Exception) or response.status_code != 200:
                continue
            payload = response.json()
            for raw in payload.get("data", []) if isinstance(payload, dict) else []:
                if not isinstance(raw, dict) or raw.get("nsfw") is True:
                    continue
                item = self._subject_from_bangumi(raw)
                if item is not None:
                    items.append(item)
        return items

    async def _bangumi_detail(self, provider_id: str) -> dict | None:
        subject_response, episodes_response = await asyncio.gather(
            self._provider_request(
                "bangumi",
                "GET",
                f"{_BANGUMI_API}/v0/subjects/{provider_id}",
                headers=self._bangumi_headers(),
            ),
            self._provider_request(
                "bangumi",
                "GET",
                f"{_BANGUMI_API}/v0/episodes",
                headers=self._bangumi_headers(),
                params={"subject_id": provider_id, "type": 0, "limit": 100, "offset": 0},
            ),
        )
        if subject_response.status_code != 200:
            return None
        item = self._subject_from_bangumi(subject_response.json())
        if item is None:
            return None
        episodes: list[dict] = []
        if episodes_response.status_code == 200:
            for index, raw in enumerate(episodes_response.json().get("data", []), 1):
                if not isinstance(raw, dict):
                    continue
                number = int(raw.get("sort") or index)
                episodes.append({
                    "number": number,
                    "title": _clean_text(raw.get("name_cn") or raw.get("name")),
                    "airdate": _clean_text(raw.get("airdate")),
                    "duration": _clean_text(raw.get("duration")),
                    "summary": _clean_text(raw.get("desc")),
                })
        item["episodes"] = episodes
        if episodes:
            item["total_episodes"] = max(ep["number"] for ep in episodes)
        item["detail_complete"] = True
        return item

    def _subject_from_bangumi(self, raw: dict) -> dict | None:
        provider_id = str(raw.get("id") or "").strip()
        if not provider_id.isdigit():
            return None
        title = _clean_text(raw.get("name_cn") or raw.get("name"))
        original = _clean_text(raw.get("name"))
        if not title:
            return None
        images = raw.get("images") if isinstance(raw.get("images"), dict) else {}
        rating = raw.get("rating") if isinstance(raw.get("rating"), dict) else {}
        tags = raw.get("tags") if isinstance(raw.get("tags"), list) else []
        aliases = [title, original]
        for info in raw.get("infobox", []) if isinstance(raw.get("infobox"), list) else []:
            if not isinstance(info, dict) or _clean_text(info.get("key")) not in {"别名", "Alias"}:
                continue
            value = info.get("value")
            if isinstance(value, list):
                aliases.extend(
                    entry.get("v") if isinstance(entry, dict) else entry for entry in value
                )
            else:
                aliases.append(value)
        return {
            "stable_id": f"bangumi:{provider_id}",
            "provider": "bangumi",
            "provider_id": int(provider_id),
            "media_type": "anime",
            "title": title,
            "original_title": original,
            "aliases": _unique_text(aliases),
            "summary": _clean_text(raw.get("summary")),
            "cover_url": _clean_text(images.get("large") or images.get("common")),
            "banner_url": _clean_text(images.get("large")),
            "date": _clean_text(raw.get("date")),
            "language": "ja",
            "region": "日本",
            "status": "aired" if raw.get("air_date") else "",
            "genres": [_clean_text(tag.get("name")) for tag in tags[:12] if isinstance(tag, dict)],
            "rating": float(rating.get("score") or 0),
            "rating_count": int(rating.get("total") or 0),
            "total_episodes": int(raw.get("eps") or raw.get("total_episodes") or 0),
            "popularity": float(raw.get("collection", {}).get("doing") or 0)
            if isinstance(raw.get("collection"), dict)
            else 0.0,
            "episodes": [],
        }

    async def _tmdb_search(
        self, keyword: str, requested: set[str], limit: int
    ) -> list[dict]:
        tasks = []
        if "tv" in requested:
            tasks.append(self._tmdb_get("/search/tv", query=keyword))
        if "movie" in requested:
            tasks.append(self._tmdb_get("/search/movie", query=keyword))
        responses = await asyncio.gather(*tasks, return_exceptions=True)
        items: list[dict] = []
        for response in responses:
            if isinstance(response, Exception) or response.status_code != 200:
                continue
            for raw in response.json().get("results", []):
                if not isinstance(raw, dict):
                    continue
                media_type = "tv" if "name" in raw else "movie"
                item = self._subject_from_tmdb(raw, media_type)
                if item is not None:
                    items.append(item)
        items.sort(key=lambda item: item.get("popularity", 0), reverse=True)
        return items[:limit]

    async def _tmdb_home(
        self,
        media_type: str,
        limit: int,
        *,
        ranked_at: float | None = None,
    ) -> list[dict]:
        ranked_at = self._clock() if ranked_at is None else ranked_at
        current_path = "/on_the_air" if media_type == "tv" else "/now_playing"
        definitions = [
            ("trending_week", f"/trending/{media_type}/week"),
            ("popular", f"/{media_type}/popular"),
            ("top_rated", f"/{media_type}/top_rated"),
            (current_path.removeprefix("/"), f"/{media_type}{current_path}"),
        ]
        groups: list[list[dict]] = [[] for _ in definitions]
        for page in range(1, _TMDB_HOME_MAX_PAGES + 1):
            responses = await asyncio.gather(
                *(self._tmdb_get(path, page=page) for _, path in definitions),
                return_exceptions=True,
            )
            for index, response in enumerate(responses):
                if isinstance(response, Exception) or response.status_code != 200:
                    continue
                try:
                    payload = response.json()
                except (UnicodeDecodeError, ValueError):
                    logger.warning(
                        "TMDB home list returned malformed JSON: %s page %s",
                        definitions[index][0],
                        page,
                    )
                    continue
                results = (
                    payload.get("results", []) if isinstance(payload, dict) else []
                )
                for raw in results:
                    if not isinstance(raw, dict) or raw.get("adult") is True:
                        continue
                    item = self._subject_from_tmdb(raw, media_type)
                    if item is not None:
                        groups[index].append(item)
            merged = _interleave_unique(groups)
            if len(merged) >= limit:
                break
        ranked_groups = []
        for (kind, _), group in zip(definitions, groups):
            weight_key = "current" if kind in {"on_the_air", "now_playing"} else kind
            ranked_groups.append((kind, _TMDB_RANKING_WEIGHTS[weight_key], group))
        return _weighted_rrf(
            "tmdb",
            ranked_groups,
            ranked_at=ranked_at,
            batch_id=f"tmdb:{media_type}:{int(ranked_at * 1000)}",
        )[:limit]

    async def _tmdb_detail(self, media_type: str, provider_id: str) -> dict | None:
        response = await self._tmdb_get(
            f"/{media_type}/{provider_id}", append_to_response="alternative_titles"
        )
        if response.status_code != 200:
            return None
        item = self._subject_from_tmdb(response.json(), media_type)
        if item is None:
            return None
        total = max(1, int(item.get("total_episodes") or 1))
        item["episodes"] = [
            {"number": number, "title": "", "airdate": "", "duration": "", "summary": ""}
            for number in range(1, total + 1)
        ]
        item["detail_complete"] = True
        return item

    async def _tmdb_get(self, path: str, **params) -> httpx.Response:
        return await self._provider_request(
            "tmdb",
            "GET",
            f"{_TMDB_API}{path}",
            headers=self._tmdb_headers(),
            params={"language": "zh-CN", "include_adult": "false", **params},
        )

    def _subject_from_tmdb(self, raw: dict, media_type: str) -> dict | None:
        provider_id = str(raw.get("id") or "").strip()
        if not provider_id.isdigit():
            return None
        title = _clean_text(raw.get("title") or raw.get("name"))
        original = _clean_text(raw.get("original_title") or raw.get("original_name"))
        if not title:
            return None
        alternative = raw.get("alternative_titles")
        alternative = alternative if isinstance(alternative, dict) else {}
        alias_items = alternative.get("titles") or alternative.get("results") or []
        aliases = [title, original]
        aliases.extend(
            entry.get("title")
            for entry in alias_items
            if isinstance(entry, dict)
        )
        genres = raw.get("genres") if isinstance(raw.get("genres"), list) else []
        if not genres and isinstance(raw.get("genre_ids"), list):
            names = _TMDB_GENRE_NAMES.get(media_type, {})
            genres = [
                {"name": names.get(value, "")}
                for value in raw["genre_ids"]
                if isinstance(value, int) and value in names
            ]
        countries = raw.get("origin_country") or raw.get("production_countries") or []
        region = " / ".join(
            _clean_text(item.get("iso_3166_1") if isinstance(item, dict) else item)
            for item in countries
        )
        return {
            "stable_id": f"tmdb:{media_type}:{provider_id}",
            "provider": "tmdb",
            "provider_id": int(provider_id),
            "media_type": media_type,
            "title": title,
            "original_title": original,
            "aliases": _unique_text(aliases),
            "summary": _clean_text(raw.get("overview")),
            "cover_url": _image(raw.get("poster_path"), "w500"),
            "banner_url": _image(raw.get("backdrop_path"), "w1280"),
            "date": _clean_text(raw.get("release_date") or raw.get("first_air_date")),
            "language": _clean_text(raw.get("original_language")),
            "region": region,
            "status": _clean_text(raw.get("status")),
            "genres": [_clean_text(item.get("name")) for item in genres if isinstance(item, dict)],
            "rating": float(raw.get("vote_average") or 0),
            "rating_count": int(raw.get("vote_count") or 0),
            "total_episodes": 1 if media_type == "movie" else int(raw.get("number_of_episodes") or 0),
            "popularity": float(raw.get("popularity") or 0),
            "episodes": [],
        }


catalog_service = CatalogService()
