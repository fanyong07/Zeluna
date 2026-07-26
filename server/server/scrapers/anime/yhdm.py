"""
樱花动漫 (yhdmp.cc / m3u8132.yhdmm3u8.top) 爬虫

樱花动漫是国内老牌动漫在线站，提供 m3u8 流媒体。
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


class YhdmScraper(BaseScraper):
    """樱花动漫爬虫"""

    BASE = "https://www.yhdmp.cc"

    def __init__(self, base_url: str = None):
        super().__init__()
        self._name = "yhdm"
        self._base_url = base_url or self.BASE
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
                ),
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
        results = []
        try:
            # 樱花动漫搜索
            resp = await self._client.get(
                f"{self._base_url}/s/{keyword}.html",
            )
            if resp.status_code != 200:
                resp = await self._client.get(
                    f"{self._base_url}/search.html",
                    params={"kw": keyword},
                )
            if resp.status_code != 200:
                return results

            soup = BeautifulSoup(resp.text, "lxml")
            for item in soup.select(
                ".lpic ul li, .img-list li, .search-list li, "
                ".video_item, .anime_item, .res_list li"
            ):
                link = item.select_one("a")
                img = item.select_one("img")
                title_el = item.select_one("h2, .title, .name, a")

                if not link:
                    continue
                href = link.get("href", "")
                title = title_el.get_text(strip=True) if title_el else link.get("title", "")
                cover = img.get("src", "") or img.get("data-src", "") if img else ""

                if href and title:
                    ep_match = re.search(r'(\d+)\s*集', item.get_text())
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
            logger.error(f"樱花动漫 search error: {e}")

        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        url = source_id if source_id.startswith("http") else f"{self._base_url}/{source_id}"
        try:
            resp = await self._client.get(url)
            if resp.status_code != 200:
                return None

            soup = BeautifulSoup(resp.text, "lxml")

            title = ""
            for sel in ["h1", ".title", ".anime-title", ".video-name"]:
                el = soup.select_one(sel)
                if el:
                    title = el.get_text(strip=True)
                    break

            summary = ""
            desc = soup.select_one(".desc, .info, .summary, .intro")
            if desc:
                summary = desc.get_text(strip=True)

            cover = ""
            img = soup.select_one(".pic img, .cover img, img.poster")
            if img:
                cover = img.get("src", "") or img.get("data-src", "")

            # 剧集列表
            episodes = []
            ep_links = soup.select(
                ".play_list a, .episode-list a, .movurl a, "
                ".vodlist a, .urlli a"
            )
            seen = set()
            for i, link in enumerate(ep_links, 1):
                href = link.get("href", "")
                ep_title = link.get_text(strip=True)
                ep_num = i
                num_match = re.search(r'(\d+)', ep_title)
                if num_match:
                    ep_num = int(num_match.group(1))
                if ep_num in seen:
                    continue
                seen.add(ep_num)
                episodes.append(EpisodeInfo(
                    number=ep_num,
                    title=ep_title or f"第{ep_num}集",
                    source_episode_id=href.strip("/"),
                ))

            tags = []
            for el in soup.select(".tag, .type, .genre a, .cate a"):
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
            logger.error(f"樱花动漫 detail error: {e}")
            return None

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        lines = []
        try:
            detail = await self.get_detail(source_id)
            if not detail or not detail.episodes:
                return lines

            target_ep = None
            for ep in detail.episodes:
                if ep.number == episode:
                    target_ep = ep
                    break
            if not target_ep and detail.episodes:
                idx = min(episode - 1, len(detail.episodes) - 1)
                target_ep = detail.episodes[idx]

            if not target_ep:
                return lines

            ep_url = (
                target_ep.source_episode_id
                if target_ep.source_episode_id.startswith("http")
                else f"{self._base_url}/{target_ep.source_episode_id}"
            )
            resp = await self._client.get(ep_url)
            if resp.status_code != 200:
                return lines

            text = resp.text

            # 提取 m3u8/mp4 链接
            url_patterns = [
                r'(?:url|src|video)\s*[:=]\s*["\'](https?://[^"\']+\.(?:m3u8|mp4)[^"\']*)["\']',
                r'["\'](https?://[^"\']*\.m3u8[^"\']*)["\']',
                r'["\'](https?://[^"\']*\.mp4[^"\']*)["\']',
            ]
            seen_urls = set()
            for pattern in url_patterns:
                for match in re.finditer(pattern, text, re.IGNORECASE):
                    url = match.group(1)
                    if url not in seen_urls:
                        seen_urls.add(url)
                        lines.append(VideoLine(
                            url=url,
                            title=f"樱花动漫 线路{len(lines)+1}",
                            format="hls" if "m3u8" in url else "mp4",
                            source_name=self.name,
                        ))

            # 也检查 iframe
            soup = BeautifulSoup(text, "lxml")
            for iframe in soup.select("iframe"):
                src = iframe.get("src", "")
                if src and ("m3u8" in src or "player" in src):
                    try:
                        iframe_resp = await self._client.get(
                            src if src.startswith("http") else urljoin(ep_url, src)
                        )
                        for pattern in url_patterns:
                            for match in re.finditer(pattern, iframe_resp.text, re.IGNORECASE):
                                url = match.group(1)
                                if url not in seen_urls:
                                    seen_urls.add(url)
                                    lines.append(VideoLine(
                                        url=url,
                                        title=f"樱花动漫 线路{len(lines)+1}",
                                        format="hls" if "m3u8" in url else "mp4",
                                        source_name=self.name,
                                    ))
                    except Exception:
                        pass

        except Exception as e:
            logger.error(f"樱花动漫 video_urls error: {e}")

        return lines

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        results = []
        try:
            resp = await self._client.get(
                f"{self._base_url}/list/{page}.html",
            )
            if resp.status_code != 200:
                return results

            soup = BeautifulSoup(resp.text, "lxml")
            for item in soup.select(".lpic ul li, .img-list li, .video_item"):
                link = item.select_one("a")
                img = item.select_one("img")
                title = link.get_text(strip=True) if link else ""
                href = link.get("href", "") if link else ""
                cover = img.get("src", "") or img.get("data-src", "") if img else ""

                if href and title:
                    results.append(SubjectResult(
                        source_id=href.strip("/"),
                        title=title,
                        cover_url=cover if cover.startswith("http") else urljoin(self._base_url, cover),
                        type="tv",
                        lang="ja",
                    ))

        except Exception as e:
            logger.error(f"樱花动漫 latest error: {e}")

        return results
