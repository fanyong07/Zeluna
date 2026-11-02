"""
TVBox 社区源适配器

将 TVBox JSON/XML API 适配为爬虫接口。
自动检测可用源，过滤掉失效的。
"""

import logging
import asyncio
import time
from typing import Optional

import httpx

from .base import (
    BaseScraper, SubjectResult, SubjectDetail,
    EpisodeInfo, VideoLine,
)

from .maccms import (media_type_from_name, year_from_value, parse_vod_play_url,
                     episode_from_group, episode_number_from_label,
                     _is_special_episode_label)
from .maccms_payload import parse_catalog_response
from .base import media_format_from_url

logger = logging.getLogger(__name__)


# Legacy duplicate/failed endpoints were removed at the user's request.
# Keep the adapter for explicitly supplied sources, not a second source list.
KNOWN_TVBOX_APIS: list[dict] = []


class TvBoxAdapterScraper(BaseScraper):
    """TVBox 适配器 - 自动检测可用源并聚合结果"""

    def __init__(self):
        super().__init__()
        self._name = "tvbox"
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": "okhttp/4.12.0",
                "Accept": "application/json, text/plain, */*",
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=12,
            follow_redirects=True,
        )
        self._healthy_sources: list[str] = []
        self._source_configs = {s["name"]: s for s in KNOWN_TVBOX_APIS}
        self._last_health_check: float = 0

    @property
    def content_types(self) -> list[str]:
        return ["series", "movie", "anime"]

    @property
    def base_url(self) -> str:
        return "tvbox://community"

    async def _check_health(self):
        now = time.time()
        if now - self._last_health_check < 120:
            return
        self._last_health_check = now
        healthy = []
        for cfg in self._source_configs.values():
            try:
                resp = await self._client.get(
                    cfg["base"],
                    params={"ac": "detail", "t": "1"},
                )
                if resp.status_code == 200 and len(resp.content) > 50:
                    data = parse_catalog_response(resp)
                    if data:
                        healthy.append(cfg["name"])
            except Exception:
                pass
        self._healthy_sources = healthy
        logger.info(
            f"TVBox health: {len(healthy)}/{len(KNOWN_TVBOX_APIS)} alive"
        )

    async def search(self, keyword: str) -> list[SubjectResult]:
        await self._check_health()
        sources = self._healthy_sources or list(self._source_configs)

        all_results: list[SubjectResult] = []
        seen = set()

        async def _search(name: str):
            cfg = self._source_configs.get(name)
            if not cfg:
                return
            try:
                resp = await self._client.get(
                    cfg["base"],
                    params={"ac": "detail", "wd": keyword},
                )
                if resp.status_code != 200:
                    return
                data = parse_catalog_response(resp)
                items = data.get("list", []) if isinstance(data, dict) else data
                if not isinstance(items, list):
                    return
                for item in items:
                    title = item.get("vod_name", "")
                    vid = str(item.get("vod_id", ""))
                    identity = (name, vid)
                    if not title or not vid or identity in seen:
                        continue
                    seen.add(identity)
                    type_name = item.get("type_name", "")
                    content_type = media_type_from_name(type_name)

                    all_results.append(SubjectResult(
                        source_id=f"tvbox:{name}:{vid}",
                        title=title,
                        cover_url=item.get("vod_pic", ""),
                        summary=(item.get("vod_content", "") or "")[:500],
                        type=content_type,
                        lang="zh",
                        year=year_from_value(item.get("vod_year")),
                        extra={"tvbox_source": name, "vod_id": vid},
                    ))
            except Exception as e:
                logger.warning("TVBox search [%s]: %s", name, type(e).__name__)

        await asyncio.gather(*[_search(n) for n in sources])
        return all_results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        parts = source_id.split(":", 2)
        if len(parts) < 3 or parts[0] != "tvbox":
            return None
        source_name, vod_id = parts[1], parts[2]
        cfg = self._source_configs.get(source_name)
        if not cfg:
            return None

        try:
            # Try videolist endpoint first
            resp = await self._client.get(
                cfg["base"],
                params={"ac": "videolist", "ids": vod_id},
            )
            if resp.status_code != 200:
                resp = await self._client.get(
                    cfg["base"],
                    params={"ac": "detail", "ids": vod_id},
                )
            if resp.status_code != 200:
                return None

            data = parse_catalog_response(resp)
            items = data.get("list", []) if isinstance(data, dict) else data
            if not items:
                return None

            item = items[0]
            title = item.get("vod_name", "")
            play_url = item.get("vod_play_url", "")
            play_from = item.get("vod_play_from", "")
            type_name = item.get("type_name", "")

            # Share normal episode semantics with MacCMS: specials are not
            # missing numbered episodes, and every playback group contributes.
            episodes_by_number = {}
            for gi, group in enumerate(play_url.split("$$$")):
                parsed = next(iter(parse_vod_play_url(group)), [])
                numbered = [episode_number_from_label(ep["name"]) for ep in parsed]
                explicit = any(number is not None for number in numbered)
                fallback = 0
                for ei, (ep, number) in enumerate(zip(parsed, numbered)):
                    if number is None:
                        if explicit or _is_special_episode_label(ep["name"]):
                            continue
                        fallback += 1
                        number = fallback
                    episodes_by_number.setdefault(number, EpisodeInfo(
                        number=number, title=ep["name"],
                        source_episode_id=f"{source_id}/ep/{gi}/{ei}",
                    ))
            episodes = [episodes_by_number[n] for n in sorted(episodes_by_number)]

            return SubjectDetail(
                source_id=source_id,
                title=title,
                cover_url=item.get("vod_pic", ""),
                summary=(item.get("vod_content", "") or "")[:2000],
                type=media_type_from_name(type_name),
                year=year_from_value(item.get("vod_year")),
                lang="zh",
                episodes=episodes,
                extra={
                    "tvbox_source": source_name,
                    "vod_id": vod_id,
                    "play_url_raw": play_url,
                    "play_from_raw": play_from,
                },
            )
        except Exception as e:
            logger.warning("TVBox detail [%s]: %s", source_name, type(e).__name__)
            return None

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        detail = await self.get_detail(source_id)
        if not detail:
            return []

        play_url = detail.extra.get("play_url_raw", "")
        play_from = detail.extra.get("play_from_raw", "")
        if not play_url:
            return []

        lines = []
        sources = play_from.split("$$$") if play_from else []
        groups = play_url.split("$$$")

        for gi, group in enumerate(groups):
            src_label = sources[gi] if gi < len(sources) else f"线路{gi+1}"
            parsed = next(iter(parse_vod_play_url(group)), [])
            ep = episode_from_group(parsed, episode)
            if ep is None:
                continue
            lines.append(VideoLine(
                url=ep["url"], title=f"[{src_label}] {ep['name']}",
                format=media_format_from_url(ep["url"]),
                source_name=f"tvbox_{detail.extra.get('tvbox_source', '')}",
            ))

        return lines
