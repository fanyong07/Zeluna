"""
电影天堂 (dytt8.net / dytt89.com) 爬虫

电影天堂是国内最大的电影资源下载/在线站之一，
提供大量电影的磁力链接和在线播放地址。
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


class DyttScraper(BaseScraper):
    """电影天堂爬虫"""

    BASE = "https://www.dytt89.com"

    def __init__(self, base_url: str = None):
        super().__init__()
        self._name = "dytt"
        self._base_url = base_url or self.BASE
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=15,
            follow_redirects=True,
        )

    @property
    def content_types(self) -> list[str]:
        return ["movie"]

    @property
    def base_url(self) -> str:
        return self._base_url

    async def search(self, keyword: str) -> list[SubjectResult]:
        """搜索电影"""
        results = []
        try:
            # 电影天堂使用 GBK 编码
            resp = await self._client.get(
                f"{self._base_url}/search.php",
                params={"searchword": keyword.encode("gbk", errors="replace")},
            )
            if resp.status_code != 200:
                # 尝试 POST
                resp = await self._client.post(
                    f"{self._base_url}/search.php",
                    data={"searchword": keyword},
                )
            if resp.status_code != 200:
                return results

            # 尝试多种编码
            text = resp.text
            try:
                text = resp.content.decode("gbk", errors="replace")
            except Exception:
                pass

            soup = BeautifulSoup(text, "lxml")

            for item in soup.select(
                ".co_content8 ul table, .tbspan, "
                ".search-result li, .movie-list li, "
                "table[width] a[href*='html']"
            ):
                link = item.select_one("a") if item.name != "a" else item
                if not link:
                    continue

                href = link.get("href", "")
                title = link.get_text(strip=True)

                # 过滤非电影链接
                if not href or not title or "html" not in href:
                    continue
                if any(skip in title for skip in ["下载", "字幕", "预告"]):
                    continue

                # 提取年份和类型
                year = 2024
                year_match = re.search(r'(20\d{2}|19\d{2})', title)
                if year_match:
                    year = int(year_match.group(1))

                results.append(SubjectResult(
                    source_id=href.strip("/"),
                    title=title,
                    type="movie",
                    lang="zh",
                    year=year,
                ))

        except Exception as e:
            logger.error(f"电影天堂 search error: {e}")

        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """获取电影详情"""
        url = source_id if source_id.startswith("http") else f"{self._base_url}/{source_id}"

        try:
            resp = await self._client.get(url)
            if resp.status_code != 200:
                return None

            text = resp.text
            try:
                text = resp.content.decode("gbk", errors="replace")
            except Exception:
                pass

            soup = BeautifulSoup(text, "lxml")

            # 标题
            title = ""
            for sel in [".title_all h1", "h1", ".title", "title"]:
                el = soup.select_one(sel)
                if el:
                    title = el.get_text(strip=True)
                    break

            # 电影详情 (在 Zoom 区域)
            content = ""
            zoom = soup.select_one("#Zoom, .co_content8, .article-content")
            if zoom:
                content = zoom.get_text()

            # 提取下载链接
            links = []
            if zoom:
                for a in zoom.select("a"):
                    href = a.get("href", "")
                    text_link = a.get_text(strip=True)
                    if any(ext in href.lower() for ext in ["ftp://", "magnet:", "ed2k://", ".mp4", ".mkv"]):
                        links.append({"title": text_link, "url": href})

            # 电影通常只有一集
            episodes = [EpisodeInfo(
                number=1,
                title=title or "正片",
                source_episode_id=source_id,
            )]

            return SubjectDetail(
                source_id=source_id,
                title=title,
                summary=content[:2000],
                type="movie",
                lang="zh",
                episodes=episodes,
                extra={
                    "url": url,
                    "download_links": links,
                },
            )

        except Exception as e:
            logger.error(f"电影天堂 detail error: {e}")
            return None

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        """获取电影播放/下载地址"""
        detail = await self.get_detail(source_id)
        if not detail:
            return []

        lines = []
        for link in detail.extra.get("download_links", []):
            url = link.get("url", "")
            title = link.get("title", "")
            if url:
                fmt = "magnet" if url.startswith("magnet:") else (
                    "hls" if "m3u8" in url else "mp4"
                )
                lines.append(VideoLine(
                    url=url,
                    title=title or f"电影天堂 线路{len(lines)+1}",
                    format=fmt,
                    source_name=self.name,
                ))

        return lines

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        """获取电影天堂最新电影"""
        results = []
        try:
            resp = await self._client.get(
                f"{self._base_url}/html/gndy/dyzz/list_23_{page}.html",
            )
            if resp.status_code != 200:
                return results

            text = resp.text
            try:
                text = resp.content.decode("gbk", errors="replace")
            except Exception:
                pass

            soup = BeautifulSoup(text, "lxml")

            for item in soup.select(
                ".co_content8 ul table a, .tbspan a, "
                "a.ulink, table a[href*='html']"
            ):
                href = item.get("href", "")
                title = item.get_text(strip=True)
                if href and title and "html" in href:
                    results.append(SubjectResult(
                        source_id=href.strip("/"),
                        title=title,
                        type="movie",
                        lang="zh",
                    ))

        except Exception as e:
            logger.error(f"电影天堂 latest error: {e}")

        return results
