"""
AGE动漫 (agefans.la) 爬虫

AGE动漫是国内最大的动漫资源聚合站之一，
提供大量番剧的 m3u8/mp4 直链。
"""

import re
import json
import logging
from typing import Optional
from urllib.parse import urljoin, quote

import httpx
from bs4 import BeautifulSoup

from ..base import (
    BaseScraper, SubjectResult, SubjectDetail,
    EpisodeInfo, VideoLine,
)

logger = logging.getLogger(__name__)


class AgeFansScraper(BaseScraper):
    """AGE动漫爬虫"""

    BASE = "https://www.agemys.vip"

    def __init__(self, base_url: str = None):
        super().__init__()
        self._name = "agefans"
        self._base_url = base_url or self.BASE
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Language": "zh-CN,zh;q=0.9",
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
        """在AGE动漫搜索"""
        results = []
        try:
            resp = await self._client.get(
                f"{self._base_url}/search",
                params={"query": keyword, "page": 1},
            )
            if resp.status_code != 200:
                return results

            soup = BeautifulSoup(resp.text, "lxml")
            # AGE动漫搜索结果在 div.blockcontent 中的 div.item 卡片
            for card in soup.select(".blockcontent .video_card, .cell, .item"):
                link = card.select_one("a")
                img = card.select_one("img")
                title_el = card.select_one(".video_title, .title, h3, a")

                if not link:
                    continue

                href = link.get("href", "")
                if not href:
                    continue

                title = ""
                if title_el:
                    title = title_el.get_text(strip=True)
                if not title and img:
                    title = img.get("alt", "")

                cover = img.get("src", "") if img else ""

                # 提取集数信息
                episode_text = card.get_text()
                ep_match = re.search(r'(\d+)\s*集', episode_text)
                ep_total = int(ep_match.group(1)) if ep_match else 0

                results.append(SubjectResult(
                    source_id=href.strip("/"),
                    title=title,
                    cover_url=cover if cover.startswith("http") else urljoin(self._base_url, cover),
                    type="tv",
                    lang="ja",
                    episode_count=ep_total,
                    latest_episode=ep_total,
                ))

        except Exception as e:
            logger.error(f"AGE动漫 search error: {e}")

        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """获取AGE动漫番剧详情"""
        url = source_id if source_id.startswith("http") else f"{self._base_url}/{source_id}"
        try:
            resp = await self._client.get(url)
            if resp.status_code != 200:
                return None

            soup = BeautifulSoup(resp.text, "lxml")

            title = ""
            title_el = soup.select_one("h1, .video_title, .detail-title")
            if title_el:
                title = title_el.get_text(strip=True)

            summary = ""
            desc_el = soup.select_one(".desc, .detail-desc, .summary")
            if desc_el:
                summary = desc_el.get_text(strip=True)

            cover = ""
            img_el = soup.select_one(".detail-img img, .video_img img, img.poster")
            if img_el:
                cover = img_el.get("src", "")

            # 提取剧集列表
            episodes = []
            ep_links = soup.select(
                ".episode-list a, .play_list a, .video_playlist a, "
                ".blockcontent a[href*='play']"
            )
            seen_numbers = set()
            for i, link in enumerate(ep_links, 1):
                href = link.get("href", "")
                ep_title = link.get_text(strip=True)
                ep_num = i
                # 尝试从文本提取集数
                num_match = re.search(r'(\d+)', ep_title)
                if num_match:
                    ep_num = int(num_match.group(1))
                if ep_num in seen_numbers:
                    continue
                seen_numbers.add(ep_num)
                episodes.append(EpisodeInfo(
                    number=ep_num,
                    title=ep_title or f"第{ep_num}集",
                    source_episode_id=href.strip("/"),
                ))

            # 提取标签
            tags = []
            genre_els = soup.select(".tag, .genre, .type a")
            for el in genre_els:
                t = el.get_text(strip=True)
                if t and t not in tags:
                    tags.append(t)

            return SubjectDetail(
                source_id=source_id,
                title=title,
                cover_url=cover if cover.startswith("http") else urljoin(self._base_url, cover),
                summary=summary,
                type="tv",
                lang="ja",
                episodes=episodes,
                tags=tags,
                genres=tags,
                extra={"url": url},
            )

        except Exception as e:
            logger.error(f"AGE动漫 detail error for {source_id}: {e}")
            return None

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        """获取AGE动漫视频播放地址"""
        lines = []
        try:
            # 先获取详情页
            detail = await self.get_detail(source_id)
            if not detail or not detail.episodes:
                return lines

            # 找到对应剧集
            target_ep = None
            for ep in detail.episodes:
                if ep.number == episode:
                    target_ep = ep
                    break
            if not target_ep and detail.episodes:
                target_ep = detail.episodes[min(episode - 1, len(detail.episodes) - 1)]

            if not target_ep:
                return lines

            # 访问播放页
            ep_url = (
                target_ep.source_episode_id if target_ep.source_episode_id.startswith("http")
                else f"{self._base_url}/{target_ep.source_episode_id}"
            )
            resp = await self._client.get(ep_url)
            if resp.status_code != 200:
                return lines

            # 提取播放地址
            # AGE动漫通常在 JS 中或 data-url 属性中有播放地址
            text = resp.text

            # 方法1: 查找 m3u8/mp4 直链
            for match in re.finditer(
                r'(?:url|src|video|source)\s*[:=]\s*["\'](https?://[^"\']+\.(?:m3u8|mp4)[^"\']*)["\']',
                text,
                re.IGNORECASE,
            ):
                lines.append(VideoLine(
                    url=match.group(1),
                    title=f"AGE动漫 线路{len(lines)+1}",
                    format="hls" if ".m3u8" in match.group(1) else "mp4",
                    source_name=self.name,
                ))

            # 方法2: 查找 JSON 中的播放地址
            for match in re.finditer(
                r'["\'](https?://[^"\']+\.m3u8[^"\']*)["\']',
                text,
            ):
                url = match.group(1)
                if url not in {l.url for l in lines}:
                    lines.append(VideoLine(
                        url=url,
                        title=f"AGE动漫 HLS线路{len(lines)+1}",
                        format="hls",
                        source_name=self.name,
                    ))

            # 方法3: 查找 data-url
            soup = BeautifulSoup(text, "lxml")
            for el in soup.select("[data-url], [data-video], [data-src]"):
                for attr in ["data-url", "data-video", "data-src", "src"]:
                    val = el.get(attr, "")
                    if val and ("m3u8" in val or "mp4" in val):
                        if val.startswith("http") and val not in {l.url for l in lines}:
                            lines.append(VideoLine(
                                url=val,
                                title=f"AGE动漫 线路{len(lines)+1}",
                                format="hls" if "m3u8" in val else "mp4",
                                source_name=self.name,
                            ))

        except Exception as e:
            logger.error(f"AGE动漫 video_urls error: {e}")

        return lines

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        """获取AGE动漫最新更新"""
        results = []
        try:
            resp = await self._client.get(
                f"{self._base_url}/update",
                params={"page": page},
            )
            if resp.status_code != 200:
                return results

            soup = BeautifulSoup(resp.text, "lxml")
            for card in soup.select(".video_card, .cell, .update-item, .item"):
                link = card.select_one("a")
                if not link:
                    continue
                href = link.get("href", "")
                title = link.get_text(strip=True) or link.get("title", "")
                img = card.select_one("img")
                cover = img.get("src", "") if img else ""

                if href and title:
                    results.append(SubjectResult(
                        source_id=href.strip("/"),
                        title=title,
                        cover_url=cover if cover.startswith("http") else urljoin(self._base_url, cover),
                        type="tv",
                        lang="ja",
                    ))

        except Exception as e:
            logger.error(f"AGE动漫 latest error: {e}")

        return results
