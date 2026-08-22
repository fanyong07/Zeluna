"""
通用 MacCMS / 苹果CMS provide/vod 多站聚合爬虫

绝大多数公开影视资源站都暴露标准的 MacCMS JSON API:
  搜索:  {base}?ac=detail&wd={keyword}&pg={page}
  详情:  {base}?ac=detail&ids={vod_id}
  最新:  {base}?ac=detail&pg={page}&h={hours}

返回结构中的 vod_play_url 采用固定分隔符:
  播放源之间用   "$$$"   分隔  (如 m3u8线路$$$mp4线路)
  剧集之间用     "#"     分隔
  单集内用       "$"     分隔  ->  "名称$地址"

一个站点 = 一路源。加站点即加源,覆盖国内外电影/电视剧/动漫/综艺。
仅返回可播放 URL,不下载任何视频文件。
"""

import asyncio
import logging
from collections.abc import AsyncIterator
from typing import Optional
from urllib.parse import quote

import httpx

from .base import (
    BaseScraper, SubjectResult, SubjectDetail,
    DIRECT_MEDIA_URL, INVALID_MEDIA_URL, PLAYER_PAGE_URL, UNKNOWN_MEDIA_URL,
    EpisodeInfo, VideoLine, classify_media_url, media_format_from_url,
)
from .maccms_sites import MACCMS_SITES, precache_sites

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def parse_vod_play_url(raw: str) -> list[list[dict]]:
    """
    解析 MacCMS 的 vod_play_url 字段。

    分隔符: 播放源用 "$$$", 剧集用 "#", 单集 "名称$地址"。
    返回: 每个播放源一个列表 -> [[{"name","url"}, ...], ...]
    只保留 http(s) 媒体候选；明显 HTML/embed 播放页直接丢弃。
    无扩展地址保留给完整内容验线，但不会被预先标成 mp4。
    """
    sources: list[list[dict]] = []
    if not raw:
        return sources
    for group in raw.split("$$$"):
        episodes: list[dict] = []
        for seg in group.split("#"):
            seg = seg.strip()
            if not seg:
                continue
            if "$" in seg:
                name, _, url = seg.partition("$")
            else:
                name, url = "", seg
            url = url.strip()
            classification = classify_media_url(url)
            if classification in {INVALID_MEDIA_URL, PLAYER_PAGE_URL}:
                continue
            episodes.append({"name": name.strip(), "url": url})
        if episodes:
            sources.append(episodes)
    return sources


class MacCmsScraper(BaseScraper):
    """MacCMS/苹果CMS 多站聚合。一个站 = 一路源。"""

    def __init__(self):
        super().__init__()
        self._name = "maccms"
        self._sites = MACCMS_SITES
        self._client = httpx.AsyncClient(
            headers={"User-Agent": _UA, "Accept": "application/json, */*"},
            timeout=12,
            follow_redirects=True,
        )
        # 记录站点健康度, 连续失败的降优先级
        self._failures: dict[str, int] = {}
        # 来源增多后仍限制一次最多 10 个站点同时发起搜索，避免小型 VPS
        # 因稳定 ID 的多别名绑定出现瞬时连接洪峰。
        self._search_semaphore = asyncio.Semaphore(10)

    @property
    def content_types(self) -> list[str]:
        return ["anime", "series", "movie"]

    @property
    def base_url(self) -> str:
        return self._sites[0]["api"] if self._sites else ""

    async def aclose(self):
        await self._client.aclose()

    def _guess_type(self, type_name: str) -> str:
        t = (type_name or "").lower()
        if any(k in type_name for k in ("动漫", "动画", "番")) or "anime" in t:
            return "anime"
        if any(k in type_name for k in ("电影", "影片")) or "movie" in t:
            return "movie"
        return "tv"

    async def _site_search(self, site: dict, keyword: str) -> list[SubjectResult]:
        try:
            async with self._search_semaphore:
                resp = await self._client.get(
                    site["api"],
                    params={"ac": "detail", "wd": keyword},
                    timeout=httpx.Timeout(4, connect=3),
                )
            if resp.status_code != 200:
                self._failures[site["name"]] = self._failures.get(site["name"], 0) + 1
                return []
            data = resp.json()
        except Exception as e:
            self._failures[site["name"]] = self._failures.get(site["name"], 0) + 1
            logger.debug(f"MacCMS search fail [{site['name']}]: {e}")
            return []

        self._failures[site["name"]] = 0
        items = data.get("list", []) if isinstance(data, dict) else []
        out: list[SubjectResult] = []
        for it in items[:15]:
            vid = str(it.get("vod_id", ""))
            title = (it.get("vod_name", "") or "").strip()
            if not vid or not title:
                continue
            out.append(SubjectResult(
                source_id=f"maccms:{site['name']}:{vid}",
                title=title,
                cover_url=it.get("vod_pic", "") or "",
                summary=(it.get("vod_blurb", "") or it.get("vod_content", "") or "")[:500],
                type=self._guess_type(it.get("type_name", "")),
                lang="zh",
                year=int(str(it.get("vod_year", "") or "0")[:4] or 0) or 2024,
                extra={"site": site["name"], "vod_id": vid,
                       "remarks": it.get("vod_remarks", "")},
            ))
        return out

    async def search(self, keyword: str) -> list[SubjectResult]:
        """并发搜索所有站点，并按站点优先级轮转结果。"""
        tasks = [self._site_search(s, keyword) for s in self._sites]
        groups = await asyncio.gather(*tasks, return_exceptions=True)
        results: list[SubjectResult] = []
        seen: set[str] = set()
        ranked_groups = sorted(
            (
                (site, group)
                for site, group in zip(self._sites, groups)
                if not isinstance(group, Exception) and group
            ),
            key=lambda pair: (
                int(pair[0].get("weight", 0))
                - 15 * self._failures.get(pair[0]["name"], 0)
            ),
            reverse=True,
        )
        max_group_size = max((len(group) for _, group in ranked_groups), default=0)
        for index in range(max_group_size):
            for _, group in ranked_groups:
                if index >= len(group):
                    continue
                r = group[index]
                key = f"{r.extra.get('site')}:{r.title}:{r.year}"
                if key in seen:
                    continue
                seen.add(key)
                results.append(r)
        return results

    async def search_progressively(
        self,
        keyword: str,
        *,
        preferred_only: bool = False,
    ) -> AsyncIterator[list[SubjectResult]]:
        """Yield each site's results as soon as that site responds.

        Full catalog searches still use :meth:`search` so their ranking and
        breadth remain unchanged. Foreground playback discovery uses this
        iterator to avoid waiting for the slowest MacCMS endpoint before it
        can resolve the first usable route.
        """
        sites = precache_sites() if preferred_only else self._sites
        tasks = [
            asyncio.create_task(self._site_search(site, keyword))
            for site in sites
        ]
        try:
            for completed in asyncio.as_completed(tasks):
                try:
                    results = await completed
                except asyncio.CancelledError:
                    raise
                except Exception:
                    continue
                if results:
                    yield results
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _site_detail(self, site_name: str, vod_id: str) -> Optional[SubjectDetail]:
        site = next((s for s in self._sites if s["name"] == site_name), None)
        if not site:
            return None
        try:
            resp = await self._client.get(
                site["api"],
                params={"ac": "detail", "ids": vod_id},
            )
            if resp.status_code != 200:
                return None
            data = resp.json()
        except Exception:
            return None

        items = data.get("list", []) if isinstance(data, dict) else []
        if not items:
            return None
        it = items[0]

        # 解析剧集列表 (从 vod_play_url 第一个播放源取集数)
        episodes: list[EpisodeInfo] = []
        raw_url = it.get("vod_play_url", "") or ""
        sources = parse_vod_play_url(raw_url)
        if sources:
            for i, ep in enumerate(sources[0], 1):
                num_match = __import__("re").search(r"(\d+)", ep["name"])
                ep_num = int(num_match.group(1)) if num_match else i
                episodes.append(EpisodeInfo(
                    number=ep_num,
                    title=ep["name"],
                    source_episode_id=str(i - 1),
                ))

        return SubjectDetail(
            source_id=f"maccms:{site_name}:{vod_id}",
            title=(it.get("vod_name", "") or "").strip(),
            cover_url=it.get("vod_pic", "") or "",
            summary=(it.get("vod_blurb", "") or it.get("vod_content", "") or "")[:500],
            type=self._guess_type(it.get("type_name", "")),
            lang="zh",
            year=int(str(it.get("vod_year", "") or "0")[:4] or 0) or 2024,
            status=1 if "完结" in (it.get("vod_remarks", "") or "") else 0,
            episodes=episodes,
            extra={"site": site_name, "vod_id": vod_id,
                   "vod_play_url": raw_url},
        )

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        parts = source_id.split(":", 2)
        if len(parts) != 3 or parts[0] != "maccms":
            return None
        return await self._site_detail(parts[1], parts[2])

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        parts = source_id.split(":", 2)
        if len(parts) != 3 or parts[0] != "maccms":
            return []
        site_name, vod_id = parts[1], parts[2]

        site = next((s for s in self._sites if s["name"] == site_name), None)
        if not site:
            return []
        try:
            resp = await self._client.get(
                site["api"],
                params={"ac": "detail", "ids": vod_id},
            )
            if resp.status_code != 200:
                return []
            data = resp.json()
        except Exception:
            return []

        items = data.get("list", []) if isinstance(data, dict) else []
        if not items:
            return []

        raw_url = items[0].get("vod_play_url", "") or ""
        sources = parse_vod_play_url(raw_url)

        configured_headers = {
            str(name).strip(): str(value).strip()
            for name, value in (site.get("headers") or {}).items()
            if str(name).strip().lower() in {"referer", "origin"}
            and str(value).strip()
        }
        lines: list[VideoLine] = []
        ep_idx = episode - 1  # 0-based
        for src_idx, source_eps in enumerate(sources):
            if ep_idx >= len(source_eps):
                continue
            ep = source_eps[ep_idx]
            url = ep["url"]
            if not url:
                continue
            classification = classify_media_url(url)
            if classification not in {DIRECT_MEDIA_URL, UNKNOWN_MEDIA_URL}:
                continue
            fmt = media_format_from_url(url)
            lines.append(VideoLine(
                url=url,
                title=ep["name"] or f"线路{src_idx + 1}",
                format=fmt,
                headers=dict(configured_headers),
                source_name=f"maccms:{site_name}",
            ))
        return lines

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        """仅从显式启用的稳定站点取最新内容。"""
        top_sites = precache_sites()
        tasks = []
        for site in top_sites:
            tasks.append(self._site_latest(site, page))
        groups = await asyncio.gather(*tasks, return_exceptions=True)
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for g in groups:
            if isinstance(g, Exception) or not g:
                continue
            for r in g:
                key = f"{r.title}:{r.year}"
                if key not in seen:
                    seen.add(key)
                    results.append(r)
        return results

    async def _site_latest(self, site: dict, page: int) -> list[SubjectResult]:
        try:
            resp = await self._client.get(
                site["api"],
                params={"ac": "detail", "pg": page, "h": 24},
            )
            if resp.status_code != 200:
                return []
            data = resp.json()
        except Exception:
            return []
        items = data.get("list", []) if isinstance(data, dict) else []
        out: list[SubjectResult] = []
        for it in items[:20]:
            vid = str(it.get("vod_id", ""))
            title = (it.get("vod_name", "") or "").strip()
            if not vid or not title:
                continue
            out.append(SubjectResult(
                source_id=f"maccms:{site['name']}:{vid}",
                title=title,
                cover_url=it.get("vod_pic", "") or "",
                type=self._guess_type(it.get("type_name", "")),
                lang="zh",
                year=int(str(it.get("vod_year", "") or "0")[:4] or 0) or 2024,
                extra={"site": site["name"], "vod_id": vid},
            ))
        return out
