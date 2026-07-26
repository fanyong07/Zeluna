"""
TVBox 社区源适配器

将 TVBox JSON/XML API 适配为爬虫接口。
自动检测可用源，过滤掉失效的。
"""

import re
import json
import logging
import asyncio
import time
from typing import Optional
from urllib.parse import urljoin, quote

import httpx

from .base import (
    BaseScraper, SubjectResult, SubjectDetail,
    EpisodeInfo, VideoLine,
)

logger = logging.getLogger(__name__)


# 已知可用的 TVBox API 端点
KNOWN_TVBOX_APIS = [
    {
        "name": "暴风",
        "base": "https://bfzyapi.com/api.php/provide/vod",
        "content_types": ["series", "movie", "anime"],
    },
    {
        "name": "量子",
        "base": "https://cj.lziapi.com/api.php/provide/vod",
        "content_types": ["series", "movie", "anime"],
    },
    {
        "name": "非凡",
        "base": "http://cj.ffzyapi.com/api.php/provide/vod",
        "content_types": ["series", "movie"],
    },
    {
        "name": "索尼",
        "base": "https://suoniapi.com/api.php/provide/vod",
        "content_types": ["series", "movie", "anime"],
    },
    {
        "name": "海外看",
        "base": "https://haiwaikan.com/api.php/provide/vod",
        "content_types": ["series", "movie", "anime"],
    },
]


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
        for cfg in KNOWN_TVBOX_APIS:
            try:
                resp = await self._client.get(
                    cfg["base"],
                    params={"ac": "detail", "t": "1"},
                )
                if resp.status_code == 200 and len(resp.content) > 50:
                    data = resp.json()
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
        sources = self._healthy_sources or [s["name"] for s in KNOWN_TVBOX_APIS]

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
                data = resp.json()
                items = data.get("list", []) if isinstance(data, dict) else data
                if not isinstance(items, list):
                    return
                for item in items:
                    title = item.get("vod_name", "")
                    if not title or title in seen:
                        continue
                    seen.add(title)
                    vid = str(item.get("vod_id", ""))
                    type_name = item.get("type_name", "")
                    content_type = "movie" if "电影" in (type_name or "") else "tv"

                    all_results.append(SubjectResult(
                        source_id=f"tvbox:{name}:{vid}",
                        title=title,
                        cover_url=item.get("vod_pic", ""),
                        summary=(item.get("vod_content", "") or "")[:500],
                        type=content_type,
                        lang="zh",
                        year=int(item["vod_year"]) if item.get("vod_year", "").isdigit() else 2024,
                        extra={"tvbox_source": name, "vod_id": vid},
                    ))
            except Exception as e:
                logger.warning(f"TVBox search [{name}]: {e}")

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

            data = resp.json()
            items = data.get("list", []) if isinstance(data, dict) else data
            if not items:
                return None

            item = items[0]
            title = item.get("vod_name", "")
            play_url = item.get("vod_play_url", "")
            play_from = item.get("vod_play_from", "")
            type_name = item.get("type_name", "")

            # Parse episodes
            episodes = []
            if play_url:
                sources = play_from.split("$$$") if play_from else ["默认"]
                groups = play_url.split("$$$")
                for gi, group in enumerate(groups):
                    src_label = sources[gi] if gi < len(sources) else f"线路{gi+1}"
                    for ei, ep_str in enumerate(group.split("#")):
                        ep_str = ep_str.strip()
                        if not ep_str:
                            continue
                        sep = ep_str.find("$")
                        if sep > 0:
                            ep_title = ep_str[:sep].strip()
                            ep_url = ep_str[sep + 1:].strip()
                        else:
                            ep_title = f"第{ei+1}集"
                            ep_url = ep_str

                        ep_num = ei + 1
                        m = re.search(r'(\d+)', ep_title)
                        if m:
                            ep_num = int(m.group(1))

                        episodes.append(EpisodeInfo(
                            number=ep_num,
                            title=f"[{src_label}] {ep_title}",
                            source_episode_id=f"{source_id}/ep/{gi}/{ei}",
                        ))

            return SubjectDetail(
                source_id=source_id,
                title=title,
                cover_url=item.get("vod_pic", ""),
                summary=(item.get("vod_content", "") or "")[:2000],
                type="movie" if "电影" in (type_name or "") else "tv",
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
            logger.error(f"TVBox detail [{source_name}/{vod_id}]: {e}")
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
            for ei, ep_str in enumerate(group.split("#")):
                sep = ep_str.find("$")
                if sep <= 0:
                    continue
                ep_title = ep_str[:sep].strip()
                ep_url = ep_str[sep + 1:].strip()
                if not ep_url:
                    continue

                m = re.search(r'(\d+)', ep_title)
                this_ep = int(m.group(1)) if m else (ei + 1)

                if this_ep == episode:
                    lines.append(VideoLine(
                        url=ep_url,
                        title=f"[{src_label}] {ep_title}",
                        format="hls" if "m3u8" in ep_url.lower() else "mp4",
                        source_name=f"tvbox_{detail.extra.get('tvbox_source', '')}",
                    ))

        return lines
