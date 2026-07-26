"""
GiriGiriLove (girigirilove.net) 爬虫

提供大量番剧的 m3u8 直链，支持多语言字幕。
"""

import re
import logging
from typing import Optional
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

from ..base import (
    BaseScraper, SubjectResult, SubjectDetail,
    EpisodeInfo, VideoLine,
)

logger = logging.getLogger(__name__)


class GiriGiriScraper(BaseScraper):
    """GiriGiriLove 爬虫"""

    BASE = "https://ai.girigirilove.net"

    def __init__(self, base_url: str = None):
        super().__init__()
        self._name = "girigiri"
        self._base_url = base_url or self.BASE
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
                ),
                "Accept-Language": "zh-CN,zh;q=0.9",
                "Accept": "application/json, text/plain, */*",
            },
            timeout=15,
            follow_redirects=True,
        )

    @property
    def content_types(self) -> list[str]:
        return ["anime"]

    @property
    def base_url(self) -> str:
        return self._base_url

    async def search(self, keyword: str) -> list[SubjectResult]:
        results = []
        try:
            # GiriGiriLove 使用 API
            resp = await self._client.get(
                f"{self._base_url}/zijian/anime",
                params={"keyword": keyword},
            )
            if resp.status_code != 200:
                # 尝试另一个 API 端点
                resp = await self._client.get(
                    f"{self._base_url}/api/search",
                    params={"q": keyword},
                )
            if resp.status_code != 200:
                return results

            try:
                data = resp.json()
                if isinstance(data, list):
                    items = data
                elif isinstance(data, dict):
                    items = data.get("data", data.get("results", []))
                else:
                    return results

                for item in items[:30]:
                    item_id = str(item.get("id", item.get("anime_id", "")))
                    title = item.get("title", item.get("name", ""))
                    cover = item.get("cover", item.get("image", item.get("poster", "")))
                    summary = item.get("description", item.get("summary", ""))
                    ep_count = item.get("episodes", item.get("total_episodes", 0))

                    results.append(SubjectResult(
                        source_id=item_id,
                        title=title,
                        cover_url=cover,
                        summary=summary,
                        type="tv",
                        lang="ja",
                        episode_count=int(ep_count) if ep_count else 0,
                        tags=item.get("tags", []) or [],
                        genres=item.get("genres", []) or [],
                    ))

            except (ValueError, KeyError):
                pass

        except Exception as e:
            logger.error(f"GiriGiri search error: {e}")

        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        try:
            resp = await self._client.get(
                f"{self._base_url}/zijian/anime/{source_id}",
            )
            if resp.status_code != 200:
                resp = await self._client.get(
                    f"{self._base_url}/api/anime/{source_id}",
                )
            if resp.status_code != 200:
                return None

            data = resp.json()

            episodes = []
            ep_list = data.get("episodes", data.get("eps", []))
            if isinstance(ep_list, list):
                for ep in ep_list:
                    if isinstance(ep, dict):
                        episodes.append(EpisodeInfo(
                            number=int(ep.get("ep", ep.get("number", 0))),
                            title=ep.get("title", ep.get("name", "")),
                            source_episode_id=str(ep.get("id", ep.get("play_id", ""))),
                        ))
                    elif isinstance(ep, (int, str)):
                        episodes.append(EpisodeInfo(
                            number=int(ep) if isinstance(ep, (int, str)) and str(ep).isdigit() else len(episodes) + 1,
                            source_episode_id=source_id,
                        ))

            # 如果没有剧集列表，创建一个默认的
            if not episodes:
                ep_count = data.get("episodes", data.get("total_episodes", 12))
                for i in range(1, int(ep_count) + 1):
                    episodes.append(EpisodeInfo(
                        number=i,
                        source_episode_id=source_id,
                    ))

            return SubjectDetail(
                source_id=source_id,
                title=data.get("title", data.get("name", "")),
                cover_url=data.get("cover", data.get("image", "")),
                summary=data.get("description", data.get("summary", "")),
                type="tv",
                lang="ja",
                episodes=episodes,
                tags=data.get("tags", []) or [],
                genres=data.get("genres", []) or [],
                rating=float(data.get("rating", data.get("score", 0))),
            )

        except Exception as e:
            logger.error(f"GiriGiri detail error: {e}")
            return None

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        lines = []
        try:
            # GiriGiriLove 的 m3u8 路径模式
            # /zijian/anime/{year}/{month}/{day}/{title}/{ep}/playlist.m3u8
            # 或者 /zijian/oldanime/{year}/{month}/{title}/{ep}/playlist.m3u8

            detail = await self.get_detail(source_id)
            if not detail:
                return lines

            # 尝试常见的路径模式
            paths_to_try = [
                f"{self._base_url}/api/anime/{source_id}/episode/{episode}/playlist",
                f"{self._base_url}/api/anime/{source_id}/ep/{episode}/stream",
            ]

            for path in paths_to_try:
                try:
                    resp = await self._client.get(path)
                    if resp.status_code == 200:
                        try:
                            data = resp.json()
                            url = data.get("url", data.get("playlist", data.get("stream", "")))
                            if url and ("m3u8" in url or "mp4" in url or "/video/" in url):
                                lines.append(VideoLine(
                                    url=url,
                                    title=f"GiriGiri 线路{len(lines)+1}",
                                    format="hls" if "m3u8" in url else "mp4",
                                    source_name=self.name,
                                ))
                        except ValueError:
                            # 可能是直接的 m3u8 文本
                            if resp.text.strip().startswith("#EXTM3U"):
                                lines.append(VideoLine(
                                    url=path.replace("/playlist", ".m3u8"),
                                    title=f"GiriGiri 线路{len(lines)+1}",
                                    format="hls",
                                    source_name=self.name,
                                ))
                except Exception:
                    continue

        except Exception as e:
            logger.error(f"GiriGiri video_urls error: {e}")

        return lines
