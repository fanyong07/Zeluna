"""MiFun 独立站点适配器。

直接访问站点公开搜索页、详情页和播放页，从播放页提取媒体地址；
不调用任何外部聚合或通用解析服务。
"""

from __future__ import annotations

import html
import re
from typing import Optional
from urllib.parse import unquote, urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from ..base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine


class MiFunScraper(BaseScraper):
    BASE = "https://ios.mifun.org"

    def __init__(
        self,
        base_url: str | None = None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "mifun"
        self._base_url = (base_url or self.BASE).rstrip("/")
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
        response = await self._client.get(
            f"{self._base_url}/vodsearch/",
            params={"wd": keyword},
        )
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for link in soup.select(".hl-item-content > .hl-item-title > a"):
            source_id = self._source_id(str(link.get("href", "")))
            title = str(link.get("title", "")).strip() or link.get_text(
                " ", strip=True
            )
            if not source_id or not title or source_id in seen:
                continue
            seen.add(source_id)
            parent = link.find_parent(class_=re.compile(r"hl-item"))
            image = parent.select_one("img") if parent else None
            cover = ""
            if image:
                cover = str(
                    image.get("data-original", "")
                    or image.get("data-src", "")
                    or image.get("src", "")
                )
            results.append(
                SubjectResult(
                    source_id=source_id,
                    title=title,
                    cover_url=urljoin(str(response.url), cover),
                    type="anime",
                    lang="ja",
                )
            )
        return results

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        response = await self._client.get(
            f"{self._base_url}/vodshow/1--------{max(1, page)}---.html"
        )
        if response.status_code != 200:
            return []
        return self._parse_listing(response)

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        detail_url = self._detail_url(source_id)
        if not detail_url:
            return None
        response = await self._client.get(detail_url)
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.text, "lxml")
        title_element = soup.select_one("h1, .hl-dc-title, .hl-item-title")
        title = title_element.get_text(" ", strip=True) if title_element else ""
        if not title:
            title = self._meta_content(soup, "og:title").split("-")[0].strip()
        image = soup.select_one(".hl-dc-pic img, .hl-item-thumb img, img.lazy")
        cover = ""
        if image:
            cover = str(
                image.get("data-original", "")
                or image.get("data-src", "")
                or image.get("src", "")
            )
        summary_element = soup.select_one(".hl-content-text, .hl-dc-content, .summary")
        summary = (
            summary_element.get_text(" ", strip=True) if summary_element else ""
        )

        episodes: list[EpisodeInfo] = []
        seen: set[int] = set()
        for index, link in enumerate(self._episode_links(soup), 1):
            number = self._episode_number(link.get_text(" ", strip=True), index)
            if number in seen:
                continue
            seen.add(number)
            episodes.append(
                EpisodeInfo(
                    number=number,
                    title=link.get_text(" ", strip=True) or f"第{number}集",
                    source_episode_id=str(link.get("href", "")),
                )
            )
        episodes.sort(key=lambda item: item.number)
        return SubjectDetail(
            source_id=self._source_id(source_id),
            title=title,
            cover_url=urljoin(str(response.url), cover),
            summary=summary,
            type="anime",
            lang="ja",
            episodes=episodes,
            extra={"url": str(response.url)},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        detail_url = self._detail_url(source_id)
        if not detail_url:
            return []
        response = await self._client.get(detail_url)
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        candidates = []
        for index, link in enumerate(self._episode_links(soup), 1):
            number = self._episode_number(link.get_text(" ", strip=True), index)
            href = str(link.get("href", "")).strip()
            if number == max(1, episode) and href:
                candidates.append(urljoin(str(response.url), href))

        lines: list[VideoLine] = []
        seen_urls: set[str] = set()
        for play_index, play_url in enumerate(dict.fromkeys(candidates).keys(), 1):
            play_response = await self._client.get(play_url)
            if play_response.status_code != 200:
                continue
            for media_url in self._extract_media_urls(play_response.text):
                if media_url in seen_urls:
                    continue
                seen_urls.add(media_url)
                lines.append(
                    VideoLine(
                        url=media_url,
                        title=f"MiFun · 线路{play_index}",
                        format="hls" if ".m3u8" in media_url.lower() else "mp4",
                        headers={"Referer": str(play_response.url)},
                        source_name=self.name,
                    )
                )
        return lines

    def _parse_listing(self, response: httpx.Response) -> list[SubjectResult]:
        soup = BeautifulSoup(response.text, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for link in soup.select(".hl-item-title > a, .hl-item-thumb"):
            source_id = self._source_id(str(link.get("href", "")))
            title = str(link.get("title", "")).strip() or link.get_text(
                " ", strip=True
            )
            if source_id and title and source_id not in seen:
                seen.add(source_id)
                results.append(
                    SubjectResult(
                        source_id=source_id,
                        title=title,
                        type="anime",
                        lang="ja",
                    )
                )
        return results

    @staticmethod
    def _episode_links(soup: BeautifulSoup) -> list:
        links = soup.select(".hl-tabs-box .hl-list-wrap a[href]")
        return links or soup.select(".hl-plays-list a[href]")

    @staticmethod
    def _episode_number(value: str, fallback: int) -> int:
        match = re.search(r"(?:第\s*)?(\d+)(?:\s*[话集])?", value)
        return int(match.group(1)) if match else fallback

    def _detail_url(self, source_id: str) -> str:
        clean = self._source_id(source_id)
        return urljoin(self._base_url + "/", clean) if clean else ""

    @staticmethod
    def _source_id(value: str) -> str:
        parsed = urlparse(value)
        path = parsed.path if parsed.scheme else value.split("?", 1)[0]
        path = path.strip()
        if not path or ".." in path:
            return ""
        return path.lstrip("/")

    @staticmethod
    def _meta_content(soup: BeautifulSoup, property_name: str) -> str:
        element = soup.select_one(f'meta[property="{property_name}"]')
        return str(element.get("content", "")).strip() if element else ""

    @staticmethod
    def _extract_media_urls(text: str) -> list[str]:
        decoded = html.unescape(text).replace(r"\/", "/")
        matches = re.findall(
            r'''https?://[^"'\\\s<>]+''',
            decoded,
            flags=re.IGNORECASE,
        )
        result: list[str] = []
        seen: set[str] = set()
        for value in matches:
            value = value.rstrip(")],.;}")
            parsed = urlparse(value)
            media_part = f"{parsed.path}?{unquote(parsed.query)}".lower()
            is_media = any(suffix in media_part for suffix in (".m3u8", ".mp4"))
            if (
                parsed.scheme in {"http", "https"}
                and parsed.hostname
                and is_media
                and value not in seen
            ):
                seen.add(value)
                result.append(value)
        return result
