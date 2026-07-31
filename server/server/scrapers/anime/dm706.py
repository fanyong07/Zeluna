"""706动漫独立站点适配器。

直接访问站点公开的搜索、详情和播放页，不经过任何第三方聚合 API。
"""

from __future__ import annotations

import base64
import html
import json
import re
from typing import Optional
from urllib.parse import unquote, urljoin

import httpx
from bs4 import BeautifulSoup

from ..base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine


class Dm706Scraper(BaseScraper):
    BASE = "https://www.706dm.com"

    def __init__(
        self,
        base_url: str | None = None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "dm706"
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
            f"{self._base_url}/search/-------------.html",
            params={"wd": keyword},
        )
        if response.status_code != 200:
            return []
        return self._parse_cards(response.text)

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        path = "/" if page <= 1 else f"/type/1-{page}/"
        response = await self._client.get(f"{self._base_url}{path}")
        if response.status_code != 200:
            return []
        return self._parse_cards(response.text)

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        detail_id = self._detail_id(source_id)
        if not detail_id:
            return None
        url = f"{self._base_url}/detail/{detail_id}/"
        response = await self._client.get(url)
        if response.status_code != 200:
            return None

        soup = BeautifulSoup(response.text, "lxml")
        title = self._page_title(soup)
        cover = self._meta_content(soup, "og:image")
        if not cover:
            image = soup.select_one(".detail-pic img, .vod-pic img, .lazyload")
            if image:
                cover = image.get("data-original", "") or image.get("data-src", "") or image.get("src", "")
        description = self._meta_name_content(soup, "description")

        episodes: list[EpisodeInfo] = []
        seen: set[int] = set()
        for link in soup.select(f'a[href*="/play/{detail_id}-"]'):
            href = str(link.get("href", "")).strip()
            match = re.search(rf"/play/{re.escape(detail_id)}-\d+-(\d+)/?", href)
            if not match:
                continue
            number = int(match.group(1))
            if number in seen:
                continue
            seen.add(number)
            episodes.append(
                EpisodeInfo(
                    number=number,
                    title=link.get_text(" ", strip=True) or f"第{number}集",
                    source_episode_id=href,
                )
            )
        episodes.sort(key=lambda item: item.number)

        return SubjectDetail(
            source_id=detail_id,
            title=title,
            cover_url=urljoin(self._base_url, cover),
            summary=description,
            type="anime",
            lang="ja",
            episodes=episodes,
            extra={"url": url},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        detail = await self.get_detail(source_id)
        if detail is None or not detail.episodes:
            return []
        target = next(
            (item for item in detail.episodes if item.number == episode),
            detail.episodes[min(max(episode - 1, 0), len(detail.episodes) - 1)],
        )
        play_url = urljoin(self._base_url, target.source_episode_id)
        response = await self._client.get(play_url)
        if response.status_code != 200:
            return []

        match = re.search(
            r"var\s+player_aaaa\s*=\s*(\{.*?\})\s*</script>",
            response.text,
            re.DOTALL,
        )
        if not match:
            return []
        try:
            player = json.loads(match.group(1))
        except json.JSONDecodeError:
            return []
        media_url = self._decode_player_url(
            str(player.get("url", "")), int(player.get("encrypt", 0) or 0)
        )
        parsed = httpx.URL(media_url)
        if parsed.scheme not in {"http", "https"} or not parsed.host:
            return []
        source_label = str(player.get("from", "")).strip() or "默认线路"
        return [
            VideoLine(
                url=media_url,
                title=f"706动漫 · {source_label}",
                format="hls" if ".m3u8" in media_url.lower() else "mp4",
                headers={"Referer": play_url},
                source_name=self.name,
            )
        ]

    def _parse_cards(self, text: str) -> list[SubjectResult]:
        soup = BeautifulSoup(text, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for link in soup.select('a[href*="/detail/"]'):
            detail_id = self._detail_id(str(link.get("href", "")))
            if not detail_id or detail_id in seen:
                continue
            title = self._clean_title(
                str(link.get("title", "")) or link.get_text(" ", strip=True)
            )
            if not title:
                continue
            seen.add(detail_id)
            parent = link.find_parent(["li", "article", "div"])
            image = parent.select_one("img") if parent else link.select_one("img")
            cover = ""
            if image:
                cover = image.get("data-original", "") or image.get("data-src", "") or image.get("src", "")
            results.append(
                SubjectResult(
                    source_id=detail_id,
                    title=title,
                    cover_url=urljoin(self._base_url, cover),
                    type="anime",
                    lang="ja",
                )
            )
        return results

    @staticmethod
    def _detail_id(value: str) -> str:
        match = re.search(r"(?:^|/)detail/(\d+)(?:/|$)", value)
        if match:
            return match.group(1)
        return value if value.isdigit() else ""

    @staticmethod
    def _clean_title(value: str) -> str:
        return re.sub(r"(?:在线观看|免费在线观看|高清无修全集)$", "", value).strip()

    @classmethod
    def _page_title(cls, soup: BeautifulSoup) -> str:
        heading = soup.select_one("h1")
        if heading:
            return cls._clean_title(heading.get_text(" ", strip=True).strip("《》"))
        value = cls._meta_content(soup, "og:title")
        return cls._clean_title(value.split("-")[0].strip("《》 "))

    @staticmethod
    def _meta_content(soup: BeautifulSoup, property_name: str) -> str:
        element = soup.select_one(f'meta[property="{property_name}"]')
        return str(element.get("content", "")).strip() if element else ""

    @staticmethod
    def _meta_name_content(soup: BeautifulSoup, name: str) -> str:
        element = soup.select_one(f'meta[name="{name}"]')
        return str(element.get("content", "")).strip() if element else ""

    @staticmethod
    def _decode_player_url(value: str, encrypt: int) -> str:
        value = html.unescape(value).strip()
        if encrypt == 1:
            return unquote(value)
        if encrypt == 2:
            try:
                return unquote(base64.b64decode(value).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return ""
        return value
