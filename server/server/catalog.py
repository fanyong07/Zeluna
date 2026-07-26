"""Bangumi + TMDB 统一元数据目录。

客户端只接触 ``bangumi:{id}``、``tmdb:tv:{id}`` 和
``tmdb:movie:{id}`` 三种稳定 ID。个人 API Token 只存在服务端环境变量中。
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

import httpx
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import (
    BANGUMI_ACCESS_TOKEN,
    CATALOG_CACHE_HOURS,
    TMDB_READ_ACCESS_TOKEN,
)
from .database import CatalogSubject

logger = logging.getLogger(__name__)

_BANGUMI_API = "https://api.bgm.tv"
_TMDB_API = "https://api.themoviedb.org/3"
_TMDB_IMAGE = "https://image.tmdb.org/t/p"
_USER_AGENT = "Zeluna/1.0 (metadata aggregator)"
_HOME_CACHE_TARGET = 180
_HOME_MAX_ITEMS = 300


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


def _is_complete_detail(item: Any) -> bool:
    return isinstance(item, dict) and item.get("detail_complete") is True


def _image(path: Any, size: str) -> str:
    value = _clean_text(path)
    return f"{_TMDB_IMAGE}/{size}{value}" if value.startswith("/") else value


class CatalogService:
    def __init__(self, *, transport: httpx.AsyncBaseTransport | None = None):
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(12, connect=6),
            follow_redirects=True,
            transport=transport,
            headers={"User-Agent": _USER_AGENT, "Accept": "application/json"},
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    @property
    def provider_status(self) -> dict[str, bool]:
        return {
            "bangumi": True,
            "bangumi_authenticated": bool(BANGUMI_ACCESS_TOKEN),
            "tmdb": bool(TMDB_READ_ACCESS_TOKEN),
        }

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
        fresh_after = time.time() - CATALOG_CACHE_HOURS * 3600
        cached_rows = (
            await session.scalars(
                select(CatalogSubject)
                .where(
                    CatalogSubject.updated_at >= fresh_after,
                    or_(
                        CatalogSubject.title.contains(query),
                        CatalogSubject.original_title.contains(query),
                    ),
                )
                .order_by(CatalogSubject.popularity.desc())
                .limit(max(1, min(limit, 100)))
            )
        ).all()
        cached = []
        for row in cached_rows:
            try:
                item = json.loads(row.metadata_json)
            except (json.JSONDecodeError, TypeError):
                continue
            if isinstance(item, dict):
                cached.append(item)
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
        await self._persist_many(session, result)
        return result

    async def home(
        self,
        media_type: str,
        session: AsyncSession,
        *,
        limit: int = 60,
    ) -> list[dict]:
        fresh_after = time.time() - CATALOG_CACHE_HOURS * 3600
        cached_rows = (
            await session.scalars(
                select(CatalogSubject)
                .where(
                    CatalogSubject.media_type == media_type,
                    CatalogSubject.updated_at >= fresh_after,
                )
                .order_by(CatalogSubject.popularity.desc())
                .limit(max(1, min(limit, _HOME_MAX_ITEMS)))
            )
        ).all()
        cached = []
        for row in cached_rows:
            try:
                item = json.loads(row.metadata_json)
            except (json.JSONDecodeError, TypeError):
                continue
            if isinstance(item, dict):
                cached.append(item)
        requested_limit = max(1, min(limit, _HOME_MAX_ITEMS))
        cache_target = min(requested_limit, _HOME_CACHE_TARGET)
        if len(cached) >= cache_target:
            return cached
        if media_type == "anime":
            calendar, ranked = await asyncio.gather(
                self._bangumi_calendar(),
                self._bangumi_ranked(requested_limit),
            )
            items = _interleave_unique([calendar, ranked])
        elif media_type in {"tv", "movie"} and TMDB_READ_ACCESS_TOKEN:
            items = await self._tmdb_home(media_type, requested_limit)
        else:
            items = []
        items = items[:requested_limit]
        await self._persist_many(session, items)
        return items or cached

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
        row = await session.scalar(
            select(CatalogSubject).where(CatalogSubject.stable_id == stable_id)
        )
        fresh_after = time.time() - CATALOG_CACHE_HOURS * 3600
        cached_item: dict | None = None
        if row is not None:
            try:
                parsed = json.loads(row.metadata_json)
                if isinstance(parsed, dict):
                    cached_item = parsed
            except (json.JSONDecodeError, TypeError):
                pass
        if (
            cached_item is not None
            and not refresh
            and row is not None
            and row.updated_at >= fresh_after
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
            await self._persist_many(session, [item])
            return item
        return cached_item

    async def _persist_many(self, session: AsyncSession, items: list[dict]) -> None:
        if not items:
            return
        now = time.time()
        for item in items:
            stable_id = _clean_text(item.get("stable_id"))
            identity = parse_stable_id(stable_id)
            if identity is None:
                continue
            row = await session.scalar(
                select(CatalogSubject).where(CatalogSubject.stable_id == stable_id)
            )
            if row is None:
                row = CatalogSubject(
                    stable_id=stable_id,
                    provider=identity[0],
                    provider_id=identity[2],
                    media_type=identity[1],
                    title=_clean_text(item.get("title")),
                )
                session.add(row)
            row.title = _clean_text(item.get("title"))
            row.original_title = _clean_text(item.get("original_title"))
            row.aliases_json = json.dumps(item.get("aliases", []), ensure_ascii=False)
            row.metadata_json = json.dumps(item, ensure_ascii=False)
            row.popularity = float(item.get("popularity") or 0)
            row.updated_at = now
        await session.commit()

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
        response = await self._client.post(
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
        response = await self._client.get(
            f"{_BANGUMI_API}/calendar", headers=self._bangumi_headers()
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

    async def _bangumi_ranked(self, limit: int) -> list[dict]:
        page_size = 100
        requests = [
            self._client.get(
                f"{_BANGUMI_API}/v0/subjects",
                headers=self._bangumi_headers(),
                params={
                    "type": 2,
                    "sort": "rank",
                    "limit": min(page_size, limit - offset),
                    "offset": offset,
                },
            )
            for offset in range(0, limit, page_size)
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
            self._client.get(
                f"{_BANGUMI_API}/v0/subjects/{provider_id}",
                headers=self._bangumi_headers(),
            ),
            self._client.get(
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

    async def _tmdb_home(self, media_type: str, limit: int) -> list[dict]:
        current_path = "/on_the_air" if media_type == "tv" else "/now_playing"
        paths = [
            f"/trending/{media_type}/week",
            f"/{media_type}/popular",
            f"/{media_type}/top_rated",
            f"/{media_type}{current_path}",
        ]
        groups: list[list[dict]] = [[] for _ in paths]
        for page in range(1, 7):
            responses = await asyncio.gather(
                *(self._tmdb_get(path, page=page) for path in paths),
                return_exceptions=True,
            )
            for index, response in enumerate(responses):
                if isinstance(response, Exception) or response.status_code != 200:
                    continue
                for raw in response.json().get("results", []):
                    if not isinstance(raw, dict) or raw.get("adult") is True:
                        continue
                    item = self._subject_from_tmdb(raw, media_type)
                    if item is not None:
                        groups[index].append(item)
            merged = _interleave_unique(groups)
            if len(merged) >= limit:
                return merged[:limit]
        return _interleave_unique(groups)[:limit]

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
        return await self._client.get(
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
            genres = [{"name": str(value)} for value in raw["genre_ids"]]
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
