"""AGE 动漫独立站点适配器。

搜索、详情、剧集和播放页均直接访问 AGE。播放地址从 AGE 播放页内嵌的
站内播放器页面提取；不调用 AniCh、镜像或通用聚合接口，也不需要浏览器。
"""

from __future__ import annotations

import asyncio
import html
import re
from typing import Optional
from urllib.parse import urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from ..base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine
from .html_direct import HtmlDirectAnimeScraper


_DETAIL_ID_RE = re.compile(r"^(?:/detail/)?(\d+)$")
_DETAIL_PATH_RE = re.compile(r"^/detail/(\d+)/?$")
_PLAY_PATH_RE = re.compile(r"^/play/(\d+)/(\d+)/(\d+)/?$")
_VURL_RE = re.compile(
    r"\bvar\s+Vurl\s*=\s*(['\"])(https?://.+?)\1\s*;?",
    re.IGNORECASE,
)


class AgeScraper(BaseScraper):
    """Direct adapter for ``www.agedm.io``."""

    BASE_URL = "https://www.agedm.io"
    PLAYER_HOSTS = frozenset({"jx.wuzhoupai.com"})

    def __init__(
        self,
        base_url: str | None = None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "age"
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
            f"{self.base_url}/search", params={"query": keyword}
        )
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for link in soup.select('a[href*="/detail/"]'):
            match = _DETAIL_PATH_RE.match(urlparse(str(link.get("href", ""))).path)
            title = str(link.get("title", "")).strip() or link.get_text(
                " ", strip=True
            )
            if not match or not title or match.group(1) in seen:
                continue
            source_id = match.group(1)
            seen.add(source_id)
            parent = link.find_parent(["article", "li", "div"])
            image = parent.select_one("img") if parent else link.select_one("img")
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
                    cover_url=urljoin(str(response.url), html.unescape(cover)),
                    type="anime",
                    lang="ja",
                )
            )
            if len(results) >= 30:
                break
        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        source_number = self._source_number(source_id)
        if not source_number:
            return None
        response = await self._client.get(f"{self.base_url}/detail/{source_number}")
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.text, "lxml")
        title_element = soup.select_one(".video_detail_title")
        title = title_element.get_text(" ", strip=True) if title_element else ""
        if not title:
            title = self._meta_content(soup, "og:title").split("-")[0].strip()
        cover = html.unescape(self._meta_content(soup, "og:image"))
        summary = self._meta_name_content(soup, "description")
        episodes: dict[int, EpisodeInfo] = {}
        for link in soup.select(f'a[href^="/play/{source_number}/"]'):
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
        response = await self._client.get(f"{self.base_url}/detail/{source_number}")
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.text, "lxml")
        line_names = self._line_names(soup)
        play_paths: list[tuple[int, str]] = []
        seen_paths: set[str] = set()
        for link in soup.select(f'a[href^="/play/{source_number}/"]'):
            path = str(link.get("href", ""))
            match = _PLAY_PATH_RE.match(path)
            if (
                not match
                or int(match.group(3)) != max(1, episode)
                or path in seen_paths
            ):
                continue
            seen_paths.add(path)
            play_paths.append((int(match.group(2)), path))

        resolved = await asyncio.gather(
            *(
                self._resolve_play_path(
                    source_index,
                    path,
                    line_names.get(source_index, f"线路{source_index}"),
                    str(response.url),
                )
                for source_index, path in play_paths
            ),
            return_exceptions=True,
        )
        lines: list[VideoLine] = []
        seen_urls: set[str] = set()
        for result in resolved:
            if not isinstance(result, VideoLine) or result.url in seen_urls:
                continue
            seen_urls.add(result.url)
            lines.append(result)
        return lines

    async def _resolve_play_path(
        self,
        source_index: int,
        path: str,
        line_name: str,
        detail_url: str,
    ) -> VideoLine | None:
        play_url = urljoin(detail_url, path)
        response = await self._client.get(play_url)
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.text, "lxml")
        iframe = soup.select_one("iframe[src]")
        if not iframe:
            return None
        player_url = urljoin(str(response.url), html.unescape(str(iframe["src"])))
        if not self._is_allowed_player_url(player_url):
            return None
        player_response = await self._client.get(
            player_url, headers={"Referer": str(response.url)}
        )
        if player_response.status_code != 200:
            return None
        match = _VURL_RE.search(html.unescape(player_response.text))
        if not match:
            return None
        media_url = match.group(2).replace(r"\/", "/").strip()
        return VideoLine(
            url=media_url,
            title=f"AGE · {line_name or f'线路{source_index}'}",
            format=HtmlDirectAnimeScraper._media_format(media_url),
            headers={
                "Referer": str(player_response.url),
                "Origin": f"{player_response.url.scheme}://{player_response.url.netloc}",
            },
            source_name=self.name,
        )

    @staticmethod
    def _line_names(soup: BeautifulSoup) -> dict[int, str]:
        pane_to_name: dict[str, str] = {}
        for button in soup.select('[data-bs-target^="#playlist-source-"]'):
            target = str(button.get("data-bs-target", "")).lstrip("#")
            name = button.get_text(" ", strip=True)
            if target and name:
                pane_to_name[target] = name
        result: dict[int, str] = {}
        for pane in soup.select('div[id^="playlist-source-"]'):
            link = pane.select_one('a[href^="/play/"]')
            match = _PLAY_PATH_RE.match(str(link.get("href", ""))) if link else None
            if match:
                result[int(match.group(2))] = pane_to_name.get(
                    str(pane.get("id", "")), f"线路{match.group(2)}"
                )
        return result

    def _is_allowed_player_url(self, value: str) -> bool:
        parsed = urlparse(value)
        if parsed.scheme != "https" or not parsed.hostname:
            return False
        if self.base_url != self.BASE_URL:
            base_host = urlparse(self.base_url).hostname
            return parsed.hostname == base_host
        return parsed.hostname.lower() in self.PLAYER_HOSTS

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
