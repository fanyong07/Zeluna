"""西瓜卡通独立站点适配器。

直接访问西瓜卡通的搜索、详情与视频页，并从站内播放器参数构造其公开 HLS
地址。该适配器不调用 AniCh 或通用聚合接口。
"""

from __future__ import annotations

import html
import re
from typing import Optional
from urllib.parse import parse_qs, urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from ..base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine


_SOURCE_ID_RE = re.compile(r"^([a-zA-Z0-9-]+)(?:@(\d+))?$")
_DETAIL_PATH_RE = re.compile(r"^/detail/([a-zA-Z0-9-]+)/?$")
_CHINESE_NUMBERS = {
    "一": 1,
    "二": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
    "十": 10,
}


class XgCartoonScraper(BaseScraper):
    BASE_URL = "https://cn.xgcartoon.com"
    VIDEO_BASE_URL = "https://www.twxgct.com"
    PLAYER_HOST = "pframe.xgcartoon.com"
    MEDIA_BASE_URL = "https://xgct-video.vzcdn.net"

    def __init__(
        self,
        base_url: str | None = None,
        *,
        video_base_url: str | None = None,
        player_host: str | None = None,
        media_base_url: str | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "xgcartoon"
        self._base_url = (base_url or self.BASE_URL).rstrip("/")
        self._video_base_url = (
            video_base_url or self.VIDEO_BASE_URL
        ).rstrip("/")
        self._player_host = (player_host or self.PLAYER_HOST).lower()
        self._media_base_url = (
            media_base_url or self.MEDIA_BASE_URL
        ).rstrip("/")
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
            transport=transport,
        )

    @property
    def content_types(self) -> list[str]:
        return ["anime"]

    @property
    def base_url(self) -> str:
        return self._base_url

    async def search(self, keyword: str) -> list[SubjectResult]:
        keyword = keyword.strip()
        if not keyword:
            return []
        response = await self._client.get(
            f"{self.base_url}/search", params={"q": keyword}
        )
        if response.status_code != 200:
            return []
        requested_season = self._requested_season(keyword)
        soup = BeautifulSoup(response.text, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for box in soup.select(".topic-list-box"):
            link = box.select_one('a[href*="/detail/"]')
            match = (
                _DETAIL_PATH_RE.match(urlparse(str(link.get("href", ""))).path)
                if link
                else None
            )
            title_element = box.select_one(".topic-list-item__info .h3")
            title = (
                title_element.get_text(" ", strip=True)
                if title_element
                else link.get_text(" ", strip=True) if link else ""
            )
            if not match or not title:
                continue
            source_id = f"{match.group(1)}@{requested_season}"
            if source_id in seen:
                continue
            seen.add(source_id)
            image = box.select_one("amp-img[src], img[src]")
            cover = str(image.get("src", "")) if image else ""
            results.append(
                SubjectResult(
                    source_id=source_id,
                    title=title,
                    cover_url=urljoin(str(response.url), html.unescape(cover)),
                    type="anime",
                    lang="zh",
                )
            )
            if len(results) >= 30:
                break
        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        parsed = self._parse_source_id(source_id)
        if parsed is None:
            return None
        slug, season = parsed
        response = await self._client.get(f"{self.base_url}/detail/{slug}")
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.text, "lxml")
        title_element = soup.select_one(".detail-right__title h1, h1.h1")
        title = title_element.get_text(" ", strip=True) if title_element else ""
        description = soup.select_one(".detail-right__desc")
        episodes = self._volume_episodes(soup, season)
        cover = f"https://static-a.xgcartoon.com/cover/{slug}.jpg"
        return SubjectDetail(
            source_id=f"{slug}@{season}",
            title=title,
            cover_url=cover,
            summary=description.get_text(" ", strip=True) if description else "",
            type="anime",
            lang="zh",
            episodes=[
                EpisodeInfo(
                    number=number,
                    title=label,
                    source_episode_id=chapter_id,
                )
                for number, label, chapter_id in episodes
            ],
            extra={"url": str(response.url), "season": season},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        parsed = self._parse_source_id(source_id)
        if parsed is None:
            return []
        slug, season = parsed
        response = await self._client.get(f"{self.base_url}/detail/{slug}")
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        target = next(
            (
                item
                for item in self._volume_episodes(soup, season)
                if item[0] == max(1, episode)
            ),
            None,
        )
        if target is None:
            return []
        chapter_id = target[2]
        video_url = f"{self._video_base_url}/video/{slug}/{chapter_id}.html"
        video_response = await self._client.get(video_url)
        if video_response.status_code != 200:
            return []
        video_soup = BeautifulSoup(video_response.text, "lxml")
        iframe = video_soup.select_one("#video_content iframe[src], iframe[src]")
        if not iframe:
            return []
        iframe_url = urljoin(
            str(video_response.url), html.unescape(str(iframe.get("src", "")))
        )
        parsed_iframe = urlparse(iframe_url)
        if (
            parsed_iframe.scheme != "https"
            or (parsed_iframe.hostname or "").lower() != self._player_host
        ):
            return []
        video_id = parse_qs(parsed_iframe.query).get("vid", [""])[0].strip()
        if not re.fullmatch(r"[a-zA-Z0-9-]+", video_id):
            return []
        media_url = f"{self._media_base_url}/{video_id}/playlist.m3u8"
        return [
            VideoLine(
                url=media_url,
                title=f"西瓜卡通 · 第{season}季",
                format="hls",
                headers={
                    "Referer": str(video_response.url),
                    "Origin": (
                        f"{video_response.url.scheme}://{video_response.url.netloc}"
                    ),
                },
                source_name=self.name,
            )
        ]

    @classmethod
    def _volume_episodes(
        cls, soup: BeautifulSoup, season: int
    ) -> list[tuple[int, str, str]]:
        container = soup.select_one(".detail-right__volumes")
        if container is None:
            return []
        current_volume = 0
        result: list[tuple[int, str, str]] = []
        for element in container.select(".volume-title, div:has(> a.goto-chapter)"):
            classes = set(element.get("class", []))
            if "volume-title" in classes:
                current_volume += 1
                continue
            if current_volume != season:
                continue
            link = element.select_one("a.goto-chapter[href]")
            if not link:
                continue
            query = parse_qs(urlparse(html.unescape(str(link["href"]))).query)
            chapter_id = query.get("chapter_id", [""])[0].strip()
            if not re.fullmatch(r"[a-zA-Z0-9-]+", chapter_id):
                continue
            label = link.get_text(" ", strip=True) or str(link.get("title", ""))
            number = cls._episode_number(label, len(result) + 1)
            result.append((number, label or f"第{number}话", chapter_id))
        return result

    @staticmethod
    def _episode_number(value: str, fallback: int) -> int:
        match = re.search(r"第\s*(\d+)\s*[话集]", value)
        return int(match.group(1)) if match else fallback

    @staticmethod
    def _requested_season(keyword: str) -> int:
        match = re.search(r"第\s*([一二三四五六七八九十\d]+)\s*季", keyword)
        if not match:
            match = re.search(r"(?:season|s)\s*(\d+)", keyword, re.IGNORECASE)
        if not match:
            return 1
        value = match.group(1)
        if value.isdigit():
            return max(1, min(20, int(value)))
        return _CHINESE_NUMBERS.get(value, 1)

    @staticmethod
    def _parse_source_id(source_id: str) -> tuple[str, int] | None:
        match = _SOURCE_ID_RE.fullmatch(source_id.strip())
        if not match:
            return None
        return match.group(1), max(1, min(20, int(match.group(2) or 1)))
