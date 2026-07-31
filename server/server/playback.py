"""稳定作品 ID 到已验证播放线路的服务层。"""

from __future__ import annotations

import asyncio
import json
import time
from urllib.parse import parse_qs, urlparse

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .aggregator import (
    CLIENT_PROBE_REQUIRED,
    SERVER_VERIFIED,
    UNAVAILABLE,
    AggregatedVideoLine,
    SourceMatch,
    aggregator,
)
from .catalog import catalog_service, parse_stable_id
from .config import (
    PLAYBACK_CACHE_HOURS,
    PLAYBACK_NEGATIVE_CACHE_MINUTES,
    PLAYBACK_PARTIAL_CACHE_MINUTES,
    PLAYBACK_STABLE_LINE_COUNT,
    SOURCE_BINDING_HOURS,
    SOURCE_MAX_CONCURRENCY,
)
from .database import (
    PlaybackCache,
    SourceBinding,
    SourceHealth,
    async_session,
    upsert_playback_cache,
)
class PlaybackService:
    def __init__(self):
        self._locks: dict[tuple[str, int], asyncio.Lock] = {}
        self._refresh_semaphore = asyncio.Semaphore(SOURCE_MAX_CONCURRENCY)

    async def lines(
        self,
        stable_id: str,
        episode: int,
        session: AsyncSession,
        *,
        title: str = "",
        original_title: str = "",
        content_type: str = "",
        year: int = 0,
        force: bool = False,
    ) -> list[dict]:
        if parse_stable_id(stable_id) is None:
            return []
        episode = max(1, episode)
        cached = await self._cached_lines(session, stable_id, episode, force=force)
        if cached is not None:
            return cached

        key = (stable_id, episode)
        lock = self._locks.setdefault(key, asyncio.Lock())
        try:
            async with lock:
                cached = await self._cached_lines(
                    session, stable_id, episode, force=force
                )
                if cached is not None:
                    return cached
                async with self._refresh_semaphore:
                    return await self._refresh(
                        stable_id,
                        episode,
                        session,
                        title=title,
                        original_title=original_title,
                        content_type=content_type,
                        year=year,
                    )
        finally:
            if not lock.locked():
                self._locks.pop(key, None)

    async def _cached_lines(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
        *,
        force: bool,
    ) -> list[dict] | None:
        if force:
            return None
        row = await session.scalar(
            select(PlaybackCache).where(
                PlaybackCache.subject_id == stable_id,
                PlaybackCache.episode == episode,
            )
        )
        if row is None:
            return None
        if row.line_count <= 0:
            ttl = PLAYBACK_NEGATIVE_CACHE_MINUTES * 60
        elif row.line_count < PLAYBACK_STABLE_LINE_COUNT:
            # Slower sites may still be absent from an early positive result.
            ttl = PLAYBACK_PARTIAL_CACHE_MINUTES * 60
        else:
            ttl = PLAYBACK_CACHE_HOURS * 3600
        if time.time() - row.verified_at >= ttl:
            return None
        try:
            items = json.loads(row.lines_json)
        except (json.JSONDecodeError, TypeError):
            return None
        if not isinstance(items, list):
            return None
        now = time.time()
        fresh_items: list[dict] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            try:
                expires_at = float(item.get("expires_at") or 0)
            except (TypeError, ValueError):
                expires_at = 0
            if expires_at <= 0 or expires_at > now + 15:
                fresh_items.append(item)
        return [
            {**item, "cached": True}
            for item in self._complete_site_inventory(fresh_items)
        ]

    async def _refresh(
        self,
        stable_id: str,
        episode: int,
        session: AsyncSession,
        *,
        title: str,
        original_title: str,
        content_type: str,
        year: int,
    ) -> list[dict]:
        metadata = await catalog_service.get_subject(stable_id, session)
        if metadata:
            title = str(metadata.get("title") or title).strip()
            original_title = str(
                metadata.get("original_title") or original_title
            ).strip()
            content_type = str(metadata.get("media_type") or content_type).strip()
            date = str(metadata.get("date") or "")
            if not year and len(date) >= 4 and date[:4].isdigit():
                year = int(date[:4])
            aliases = [
                title,
                original_title,
                *(metadata.get("aliases") or []),
            ]
        else:
            aliases = [title, original_title]
            identity = parse_stable_id(stable_id)
            content_type = content_type or (identity[1] if identity else "")
        aliases = [str(value).strip() for value in aliases if str(value).strip()]
        if not aliases:
            await self._store_cache(session, stable_id, episode, title, [])
            return []

        matches = await self._load_bindings(session, stable_id)
        configured_sites = aggregator.configured_source_names
        matched_sites = {
            match.source_name
            for match in matches
            if match.source_name in configured_sites
        }
        if len(matched_sites) < len(configured_sites):
            discovered = await aggregator.discover_source_matches(
                aliases,
                content_type=content_type,
                year=year,
                max_matches=len(aggregator.source_inventory) + 8,
            )
            matches = self._merge_matches(matches, discovered)
            await self._store_bindings(session, stable_id, matches)

        lines, health = await aggregator.resolve_source_matches(
            matches,
            episode=episode,
            verify=True,
        )
        await self._record_health(session, stable_id, health)
        data = self._complete_site_inventory(
            [self._line_dict(line) for line in lines],
            matches=matches,
            health=health,
        )
        await self._store_cache(session, stable_id, episode, title, data)
        return [{**item, "cached": False} for item in data]

    async def _load_bindings(
        self, session: AsyncSession, stable_id: str
    ) -> list[SourceMatch]:
        cutoff = time.time() - SOURCE_BINDING_HOURS * 3600
        rows = (
            await session.scalars(
                select(SourceBinding)
                .where(
                    SourceBinding.stable_id == stable_id,
                    SourceBinding.enabled.is_(True),
                    SourceBinding.updated_at >= cutoff,
                )
                .order_by(
                    SourceBinding.success_count.desc(),
                    SourceBinding.score.desc(),
                    SourceBinding.failure_count.asc(),
                )
                .limit(len(aggregator.source_inventory) + 8)
            )
        ).all()
        return [
            SourceMatch(
                source_id=row.source_id,
                source_name=row.source_name,
                title=row.matched_title,
                content_type=row.media_type,
                year=row.year,
                episode_count=row.episode_count,
                score=row.score,
            )
            for row in rows
        ]

    async def _store_bindings(
        self,
        session: AsyncSession,
        stable_id: str,
        matches: list[SourceMatch],
    ) -> None:
        now = time.time()
        for match in matches:
            row = await session.scalar(
                select(SourceBinding).where(
                    SourceBinding.stable_id == stable_id,
                    SourceBinding.source_id == match.source_id,
                )
            )
            if row is None:
                row = SourceBinding(
                    stable_id=stable_id,
                    source_id=match.source_id,
                    source_name=match.source_name,
                )
                session.add(row)
            row.matched_title = match.title
            row.media_type = match.content_type
            row.year = match.year
            row.score = match.score
            row.episode_count = match.episode_count
            row.enabled = True
            row.updated_at = now
        await session.commit()

    async def _record_health(
        self,
        session: AsyncSession,
        stable_id: str,
        health: dict[str, str | bool],
    ) -> None:
        now = time.time()
        for source_name, raw_status in health.items():
            status = (
                SERVER_VERIFIED if raw_status is True
                else UNAVAILABLE if raw_status is False
                else str(raw_status)
            )
            binding_rows = (
                await session.scalars(
                    select(SourceBinding).where(
                        SourceBinding.stable_id == stable_id,
                        SourceBinding.source_name == source_name,
                    )
                )
            ).all()
            for row in binding_rows:
                if status == SERVER_VERIFIED:
                    row.success_count += 1
                    row.last_success_at = now
                elif status == UNAVAILABLE:
                    row.failure_count += 1
                    row.last_failure_at = now
                # 连续多次失败后暂停到下次重新发现，避免每次拖慢首播。
                row.enabled = (
                    status == CLIENT_PROBE_REQUIRED
                    or row.failure_count - row.success_count < 5
                )
            source = await session.scalar(
                select(SourceHealth).where(SourceHealth.source_name == source_name)
            )
            if source is None:
                source = SourceHealth(
                    source_name=source_name,
                    success_count=0,
                    failure_count=0,
                    consecutive_failures=0,
                    last_status="unknown",
                    last_checked_at=0.0,
                    latency_ms=0,
                )
                session.add(source)
            source.last_checked_at = now
            if status == SERVER_VERIFIED:
                source.success_count += 1
                source.consecutive_failures = 0
                source.last_status = "healthy"
            elif status == CLIENT_PROBE_REQUIRED:
                source.last_status = CLIENT_PROBE_REQUIRED
            else:
                source.failure_count += 1
                source.consecutive_failures += 1
                source.last_status = "unhealthy"
        await session.commit()

    async def _store_cache(
        self,
        session: AsyncSession,
        stable_id: str,
        episode: int,
        title: str,
        lines: list[dict],
    ) -> None:
        await upsert_playback_cache(
            session,
            subject_id=stable_id,
            episode=episode,
            title=title,
            lines_json=json.dumps(lines, ensure_ascii=False),
            line_count=sum(1 for line in lines if line.get("available") is True),
            verified_at=time.time(),
        )

    def _line_dict(self, line: AggregatedVideoLine) -> dict:
        server_verified = line.verification_status == SERVER_VERIFIED
        client_probe_required = (
            line.verification_status == CLIENT_PROBE_REQUIRED
        )
        return {
            "url": line.url,
            "title": line.title,
            "quality": line.quality,
            "format": line.format,
            "source": line.source,
            "headers": line.headers,
            "available": server_verified,
            "status": (
                SERVER_VERIFIED
                if server_verified
                else CLIENT_PROBE_REQUIRED
                if client_probe_required
                else UNAVAILABLE
            ),
            "message": (
                "服务器已验证清单和首个媒体分片"
                if server_verified
                else "服务器出口受限，等待客户端完成清单和首段验证"
                if client_probe_required
                else "当前线路验证失败"
            ),
            "expires_at": self._line_expiry(line.url),
        }

    def _merge_matches(
        self,
        current: list[SourceMatch],
        discovered: list[SourceMatch],
    ) -> list[SourceMatch]:
        merged = {match.source_id: match for match in current}
        for match in discovered:
            previous = merged.get(match.source_id)
            if previous is None or match.score > previous.score:
                merged[match.source_id] = match
        return sorted(merged.values(), key=lambda item: item.score, reverse=True)

    def _complete_site_inventory(
        self,
        items: list[dict],
        *,
        matches: list[SourceMatch] | None = None,
        health: dict[str, str | bool] | None = None,
    ) -> list[dict]:
        result = [dict(item) for item in items if isinstance(item, dict)]
        represented_sites = {
            self._site_name(item.get("source"))
            for item in result
            if self._site_name(item.get("source"))
        }
        source_inventory = aggregator.source_inventory
        configured_sites = {name for _, name in source_inventory}
        matched_sites = {
            match.source_name
            for match in (matches or [])
            if match.source_name in configured_sites
        }
        health = health or {}
        for provider, name in source_inventory:
            if name in represented_sites:
                continue
            matched = name in matched_sites or name in health
            status = "unavailable" if matched else "not_found"
            message = (
                "已匹配作品，但本集线路验证失败或暂时超时"
                if matched
                else "当前站点没有匹配到这部作品"
            )
            result.append({
                "url": "",
                "title": name,
                "quality": "",
                "format": "",
                "source": f"{provider}:{name}",
                "headers": {},
                "available": False,
                "status": status,
                "message": message,
                "expires_at": 0,
            })
        return result

    @staticmethod
    def _line_expiry(url: str) -> int:
        """Extract common signed-URL expiry values without guessing short IDs."""
        try:
            query = parse_qs(urlparse(url).query)
        except ValueError:
            return 0
        lowered = {str(key).lower(): values for key, values in query.items()}
        now = int(time.time())
        for key in ("expires", "expire", "exp", "deadline", "wsTime"):
            values = lowered.get(key.lower()) or []
            for raw in values:
                value = str(raw).strip()
                try:
                    timestamp = int(value, 16) if key == "wsTime" else int(value)
                except ValueError:
                    continue
                if timestamp > 10_000_000_000:
                    timestamp //= 1000
                if now - 7 * 86400 <= timestamp <= now + 366 * 86400:
                    return timestamp
        return 0

    @staticmethod
    def _site_name(source: object) -> str:
        parts = str(source or "").split(":", 2)
        return parts[1].strip() if len(parts) >= 2 else ""

    async def refresh_due(self, *, limit: int = 12) -> dict[str, int]:
        refreshed = 0
        playable = 0
        async with async_session() as session:
            rows = (
                await session.scalars(
                    select(PlaybackCache)
                    .order_by(PlaybackCache.verified_at.asc())
                    .limit(max(1, limit))
                )
            ).all()
        for row in rows:
            async with async_session() as session:
                result = await self.lines(
                    row.subject_id,
                    row.episode,
                    session,
                    title=row.title,
                    force=True,
                )
            refreshed += 1
            if result:
                playable += 1
        return {"refreshed": refreshed, "playable": playable}


playback_service = PlaybackService()
