"""GiriGiri 独立动漫站适配器。

搜索、详情、剧集和播放页均直接访问 GiriGiri 内容站。播放地址只从
``player_aaaa`` 页面数据中解析，不调用 AniCh 或其它聚合解析服务。
"""

from __future__ import annotations

import re
from typing import Optional
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

from ..base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine
from .html_direct import HtmlDirectAnimeScraper


_DETAIL_ID_RE = re.compile(r"^(?:GV)?(\d+)$", re.IGNORECASE)
_DETAIL_PATH_RE = re.compile(r"^/GV(\d+)/?$", re.IGNORECASE)
_PLAY_PATH_RE = re.compile(r"^/playGV(\d+)-(\d+)-(\d+)/?$", re.IGNORECASE)


class GiriGiriScraper(BaseScraper):
    """Direct adapter for ``ani.girigirilove.com``."""

    BASE_URL = "https://ani.girigirilove.com"

    def __init__(
        self,
        base_url: str | None = None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "girigiri"
        self._base_url = (base_url or self.BASE_URL).rstrip("/")
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
            f"{self.base_url}/ajax/suggest",
            params={"mid": 1, "wd": keyword},
            headers={"X-Requested-With": "XMLHttpRequest"},
        )
        if response.status_code != 200:
            return []
        try:
            payload = response.json()
        except ValueError:
            return []
        items = payload.get("list", []) if isinstance(payload, dict) else []
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for item in items[:30]:
            if not isinstance(item, dict):
                continue
            source_id = self._source_number(str(item.get("id", "")))
            title = str(item.get("name", "")).strip()
            if not source_id or not title or source_id in seen:
                continue
            seen.add(source_id)
            results.append(
                SubjectResult(
                    source_id=source_id,
                    title=title,
                    cover_url=urljoin(
                        self.base_url + "/", str(item.get("pic", ""))
                    ),
                    type="anime",
                    lang="ja",
                )
            )
        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        source_number = self._source_number(source_id)
        if not source_number:
            return None
        response = await self._client.get(
            f"{self.base_url}/GV{source_number}/"
        )
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.text, "lxml")
        title_element = soup.select_one(".slide-info-title, h1")
        title = title_element.get_text(" ", strip=True) if title_element else ""
        if not title:
            title = self._meta_content(soup, "og:title").split("-")[0].strip()

        cover = self._meta_content(soup, "og:image")
        if not cover:
            image = soup.select_one(
                ".slide-pic img, .detail-pic img, .vod-pic img, img.lazy"
            )
            if image:
                cover = str(
                    image.get("data-original", "")
                    or image.get("data-src", "")
                    or image.get("src", "")
                )

        episodes: dict[int, EpisodeInfo] = {}
        for link in soup.select('.anthology-list-box a[href], a[href*="playGV"]'):
            match = _PLAY_PATH_RE.match(str(link.get("href", "")))
            if not match or match.group(1) != source_number:
                continue
            number = int(match.group(3))
            episodes.setdefault(
                number,
                EpisodeInfo(
                    number=number,
                    title=link.get_text(" ", strip=True) or f"第{number}集",
                    source_episode_id=str(link.get("href", "")),
                ),
            )

        summary = self._meta_name_content(soup, "description")
        return SubjectDetail(
            source_id=source_number,
            title=title,
            cover_url=urljoin(str(response.url), cover),
            summary=summary,
            type="anime",
            lang="ja",
            episodes=list(episodes.values()),
            extra={"url": str(response.url)},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        source_number = self._source_number(source_id)
        if not source_number:
            return []
        detail_response = await self._client.get(
            f"{self.base_url}/GV{source_number}/"
        )
        if detail_response.status_code != 200:
            return []
        soup = BeautifulSoup(detail_response.text, "lxml")
        play_paths: list[tuple[int, str]] = []
        seen_paths: set[str] = set()
        for link in soup.select('a[href*="playGV"]'):
            path = str(link.get("href", ""))
            match = _PLAY_PATH_RE.match(path)
            if (
                not match
                or match.group(1) != source_number
                or int(match.group(3)) != max(1, episode)
                or path in seen_paths
            ):
                continue
            seen_paths.add(path)
            play_paths.append((int(match.group(2)), path))

        lines: list[VideoLine] = []
        seen_urls: set[str] = set()
        for source_index, path in play_paths:
            play_url = urljoin(str(detail_response.url), path)
            response = await self._client.get(play_url)
            if response.status_code != 200:
                continue
            for media_url in HtmlDirectAnimeScraper._player_urls(response.text):
                if media_url in seen_urls:
                    continue
                seen_urls.add(media_url)
                lines.append(
                    VideoLine(
                        url=media_url,
                        title=f"GiriGiri 线路{source_index}",
                        format=HtmlDirectAnimeScraper._media_format(media_url),
                        headers={
                            "Referer": str(response.url),
                            "Origin": self.base_url,
                        },
                        source_name=self.name,
                    )
                )
        return lines

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        if page != 1:
            return []
        response = await self._client.get(f"{self.base_url}/")
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for link in soup.select("a[href]"):
            match = _DETAIL_PATH_RE.match(str(link.get("href", "")))
            if not match or match.group(1) in seen:
                continue
            image = link.select_one("img")
            title = str(link.get("title", "")).strip()
            if not title and image:
                title = str(image.get("alt", "")).strip()
            if not title:
                title = link.get_text(" ", strip=True)
            if not title:
                continue
            seen.add(match.group(1))
            cover = ""
            if image:
                cover = str(
                    image.get("data-original", "")
                    or image.get("data-src", "")
                    or image.get("src", "")
                )
            results.append(
                SubjectResult(
                    source_id=match.group(1),
                    title=title,
                    cover_url=urljoin(str(response.url), cover),
                    type="anime",
                    lang="ja",
                )
            )
            if len(results) >= 30:
                break
        return results

    @staticmethod
    def _source_number(source_id: str) -> str:
        match = _DETAIL_ID_RE.fullmatch(source_id.strip())
        return match.group(1) if match else ""

    @staticmethod
    def _meta_content(soup: BeautifulSoup, property_name: str) -> str:
        element = soup.select_one(f'meta[property="{property_name}"]')
        return str(element.get("content", "")).strip() if element else ""

    @staticmethod
    def _meta_name_content(soup: BeautifulSoup, name: str) -> str:
        element = soup.select_one(f'meta[name="{name}"]')
        return str(element.get("content", "")).strip() if element else ""
