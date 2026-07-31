"""配置化 HTML 动漫站适配器。

每个站点拥有独立的搜索地址和 DOM 选择器，共用经过测试的详情、剧集与
``player_aaaa`` 直链解析引擎。站点之间不互相代理，也不调用外部聚合服务。
"""

from __future__ import annotations

import base64
import html
import json
import re
from dataclasses import dataclass
from typing import Optional
from urllib.parse import quote, unquote, urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from ..base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine


@dataclass(frozen=True)
class HtmlDirectSite:
    key: str
    display_name: str
    search_url: str
    search_link_selector: str
    episode_list_selector: str
    episode_link_selector: str = "a"
    production_enabled: bool = True

    @property
    def base_url(self) -> str:
        parsed = urlparse(self.search_url)
        return f"{parsed.scheme}://{parsed.netloc}"


HTML_DIRECT_ANIME_SITES: tuple[HtmlDirectSite, ...] = (
    HtmlDirectSite(
        key="zhuiju",
        display_name="追剧影院",
        search_url="https://pzlyw.com/vodsearch/{keyword}----------1---.html",
        search_link_selector=".title > a",
        episode_list_selector=".videolist",
        production_enabled=False,
    ),
    HtmlDirectSite(
        key="jibi",
        display_name="叽哔动漫",
        search_url="https://www.jibi.cc/index.php/vod/search.html?wd={keyword}",
        search_link_selector=".module-card-item-title > a",
        episode_list_selector=".module-play-list-content",
    ),
    HtmlDirectSite(
        key="yingshisenlin",
        display_name="影视森林",
        search_url="http://www.hc34567.com/hcvodsearch/{keyword}----------1---.html",
        search_link_selector=".title > a",
        episode_list_selector=".myui-content__list.sort-list",
        production_enabled=False,
    ),
    HtmlDirectSite(
        key="fantuan",
        display_name="饭团动漫",
        search_url="https://acgpost.com/search.html?wd={keyword}",
        search_link_selector=(
            "body > main > div > div.mt-2-5 > div > div > div > a"
        ),
        episode_list_selector=".anime-episode",
        production_enabled=False,
    ),
    HtmlDirectSite(
        key="yinghua2",
        display_name="樱花动漫",
        search_url=(
            "https://www.yinghua2.com/index.php/vod/search.html?wd={keyword}"
        ),
        search_link_selector=".title > a",
        episode_list_selector=".stui-content__playlist",
    ),
    HtmlDirectSite(
        key="wedm",
        display_name="wedm",
        search_url="https://www.vdm5.com/search_-------------.html?wd={keyword}",
        search_link_selector="div.detail > h3 > a",
        episode_list_selector=".stui-content__playlist",
    ),
)


class HtmlDirectAnimeScraper(BaseScraper):
    def __init__(
        self,
        site: HtmlDirectSite,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._site = site
        self._name = site.key
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
        return self._site.base_url

    async def search(self, keyword: str) -> list[SubjectResult]:
        url = self._site.search_url.replace("{keyword}", quote(keyword))
        response = await self._client.get(url)
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for link in soup.select(self._site.search_link_selector):
            source_id = self._source_id(str(link.get("href", "")), response.url)
            title = str(link.get("title", "")).strip() or link.get_text(
                " ", strip=True
            )
            if not source_id or not title or source_id in seen:
                continue
            seen.add(source_id)
            parent = link.find_parent(["li", "article", "div"])
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
        return []

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        response = await self._get_detail_response(source_id)
        if response is None:
            return None
        soup = BeautifulSoup(response.text, "lxml")
        title = self._page_title(soup)
        cover = self._meta_content(soup, "og:image")
        if not cover:
            image = soup.select_one(
                ".module-item-pic img, .detail-pic img, .vod-pic img, img.lazy"
            )
            if image:
                cover = str(
                    image.get("data-original", "")
                    or image.get("data-src", "")
                    or image.get("src", "")
                )
        description = self._meta_name_content(soup, "description")
        episodes: list[EpisodeInfo] = []
        seen: set[int] = set()
        for number, link in self._numbered_episode_links(soup):
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
            source_id=self._source_id(source_id, response.url),
            title=title,
            cover_url=urljoin(str(response.url), cover),
            summary=description,
            type="anime",
            lang="ja",
            episodes=episodes,
            extra={"url": str(response.url)},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        response = await self._get_detail_response(source_id)
        if response is None:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        play_urls = [
            urljoin(str(response.url), str(link.get("href", "")))
            for number, link in self._numbered_episode_links(soup)
            if number == max(1, episode) and str(link.get("href", "")).strip()
        ]
        lines: list[VideoLine] = []
        seen: set[str] = set()
        for index, play_url in enumerate(dict.fromkeys(play_urls), 1):
            play_response = await self._client.get(play_url)
            if play_response.status_code != 200:
                continue
            media_urls = self._player_urls(play_response.text)
            for media_url in media_urls:
                if media_url in seen:
                    continue
                seen.add(media_url)
                lines.append(
                    VideoLine(
                        url=media_url,
                        title=f"{self._site.display_name} · 线路{index}",
                        format=self._media_format(media_url),
                        headers={"Referer": str(play_response.url)},
                        source_name=self.name,
                    )
                )
        return lines

    async def _get_detail_response(self, source_id: str) -> httpx.Response | None:
        url = self._source_url(source_id)
        if not url:
            return None
        response = await self._client.get(url)
        return response if response.status_code == 200 else None

    def _numbered_episode_links(self, soup: BeautifulSoup) -> list[tuple[int, object]]:
        result: list[tuple[int, object]] = []
        for box in soup.select(self._site.episode_list_selector):
            links = box.select(self._site.episode_link_selector)
            for position, link in enumerate(links, 1):
                if not str(link.get("href", "")).strip():
                    continue
                result.append(
                    (self._episode_number(link.get_text(" ", strip=True), position), link)
                )
        return result

    def _source_url(self, source_id: str) -> str:
        clean = self._source_id(source_id, None)
        return urljoin(self.base_url + "/", clean) if clean else ""

    def _source_id(self, value: str, base: object | None) -> str:
        absolute = urljoin(str(base or self.base_url), value)
        parsed = urlparse(absolute)
        base_host = urlparse(self.base_url).hostname
        response_host = urlparse(str(base)).hostname if base else None
        normalized_host = (parsed.hostname or "").removeprefix("www.")
        normalized_base_host = (base_host or "").removeprefix("www.")
        normalized_response_host = (response_host or "").removeprefix("www.")
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or normalized_host
            not in {normalized_base_host, normalized_response_host}
            or ".." in parsed.path
        ):
            return ""
        return parsed.path.lstrip("/") + (
            f"?{parsed.query}" if parsed.query else ""
        )

    @staticmethod
    def _episode_number(value: str, fallback: int) -> int:
        match = re.search(r"(?:第\s*)?(\d+)(?:\s*[话集])?", value)
        return int(match.group(1)) if match else fallback

    @staticmethod
    def _page_title(soup: BeautifulSoup) -> str:
        element = soup.select_one("h1, .module-info-heading h1, .page-title")
        if element:
            return element.get_text(" ", strip=True).strip("《》 ")
        return HtmlDirectAnimeScraper._meta_content(soup, "og:title").split("-")[
            0
        ].strip("《》 ")

    @staticmethod
    def _meta_content(soup: BeautifulSoup, property_name: str) -> str:
        element = soup.select_one(f'meta[property="{property_name}"]')
        return str(element.get("content", "")).strip() if element else ""

    @staticmethod
    def _meta_name_content(soup: BeautifulSoup, name: str) -> str:
        element = soup.select_one(f'meta[name="{name}"]')
        return str(element.get("content", "")).strip() if element else ""

    @classmethod
    def _player_urls(cls, text: str) -> list[str]:
        results: list[str] = []
        match = re.search(
            r"player_aaaa\s*=\s*(\{.*?\})\s*</script>",
            text,
            re.DOTALL,
        )
        if match:
            try:
                player = json.loads(match.group(1))
                value = cls._decode_player_url(
                    str(player.get("url", "")), int(player.get("encrypt", 0) or 0)
                )
                if cls._is_direct_media_url(value):
                    results.append(value)
            except (json.JSONDecodeError, TypeError, ValueError):
                pass
        decoded = html.unescape(text).replace(r"\/", "/")
        for value in re.findall(r'''https?://[^"'\\\s<>]+''', decoded):
            value = value.rstrip(")],.;}")
            if cls._is_direct_media_url(value) and value not in results:
                results.append(value)
        return results

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

    @staticmethod
    def _is_direct_media_url(value: str) -> bool:
        parsed = urlparse(value)
        media_part = f"{parsed.path}?{unquote(parsed.query)}".lower()
        return (
            parsed.scheme in {"http", "https"}
            and bool(parsed.hostname)
            and any(
                marker in media_part
                for marker in (".m3u8", ".mp4", ".mkv", ".flv", "mime_type=video")
            )
        )

    @staticmethod
    def _media_format(value: str) -> str:
        lowered = value.lower()
        if ".m3u8" in lowered:
            return "hls"
        if ".mkv" in lowered:
            return "mkv"
        if ".flv" in lowered:
            return "flv"
        return "mp4"


def create_html_direct_anime_scrapers() -> dict[str, HtmlDirectAnimeScraper]:
    return {
        site.key: HtmlDirectAnimeScraper(site)
        for site in HTML_DIRECT_ANIME_SITES
        if site.production_enabled
    }
