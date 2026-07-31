"""Independently maintained adapters for VPS-verified direct stream sites.

These adapters query each public content site directly.  They do not execute
remote rules, call a third-party aggregator, or proxy media through Zeluna.
Only metadata and the site's literal HLS URLs are returned to the player.
"""

from __future__ import annotations

import base64
import html
import json
import re
from typing import Optional
from urllib.parse import quote, unquote, urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from .base import BaseScraper, EpisodeInfo, SubjectDetail, SubjectResult, VideoLine


_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
)
_PLAYER_RE = re.compile(
    r"(?:player_[A-Za-z0-9_]+|player_data)\s*=\s*(\{.*?\})\s*</script>",
    re.IGNORECASE | re.DOTALL,
)
_YEAR_RE = re.compile(r"\b((?:19|20)\d{2})\b")


def _meta_content(soup: BeautifulSoup, name: str) -> str:
    element = soup.select_one(f'meta[property="{name}"], meta[name="{name}"]')
    return str(element.get("content", "")).strip() if element else ""


def _year(value: str) -> int:
    match = _YEAR_RE.search(value)
    return int(match.group(1)) if match else 0


def _episode_count(value: str) -> int:
    match = re.search(r"(\d+)\s*集", value)
    return int(match.group(1)) if match else 0


def _media_format(value: str) -> str:
    lowered = value.lower()
    if ".m3u8" in lowered:
        return "hls"
    if ".mkv" in lowered:
        return "mkv"
    if ".flv" in lowered:
        return "flv"
    return "mp4"


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


def _decode_player_url(value: str, encrypt: int) -> str:
    value = html.unescape(value).strip()
    if encrypt == 1:
        return unquote(value)
    if encrypt == 2:
        try:
            padded = value + "=" * (-len(value) % 4)
            return unquote(base64.b64decode(padded).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return ""
    return value


def _player_media_url(text: str) -> str:
    match = _PLAYER_RE.search(text)
    if not match:
        return ""
    try:
        player = json.loads(match.group(1))
        value = _decode_player_url(
            str(player.get("url", "")), int(player.get("encrypt", 0) or 0)
        )
    except (json.JSONDecodeError, TypeError, ValueError):
        return ""
    return value if _is_direct_media_url(value) else ""


class NivodScraper(BaseScraper):
    """Direct adapter for ``nivod.vip`` (series, movies, and anime)."""

    _SOURCE_RE = re.compile(r"^(tv|movie|anime):(\d+)$")
    _DETAIL_PATH_RE = re.compile(r"^/nivod/(\d+)/$")
    _PLAY_PATH_RE = re.compile(r"^/niplay/(\d+)-(\d+)-(\d+)/$")

    def __init__(
        self,
        *,
        base_url: str = "https://www.nivod.vip",
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "nivod"
        self._base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": _USER_AGENT,
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=15,
            follow_redirects=True,
            transport=transport,
        )

    @property
    def content_types(self) -> list[str]:
        return ["series", "movie", "anime"]

    @property
    def base_url(self) -> str:
        return self._base_url

    async def search(self, keyword: str) -> list[SubjectResult]:
        keyword = keyword.strip()
        if not keyword:
            return []
        response = await self._client.get(
            f"{self.base_url}/s/{quote(keyword)}-------------/"
        )
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.content, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for card in soup.select(".module-card-item"):
            link = card.select_one('a[href^="/nivod/"]')
            if link is None:
                continue
            detail_id = self._detail_id(str(link.get("href", "")))
            kind = self._content_type(
                card.select_one(".module-card-item-class").get_text(" ", strip=True)
                if card.select_one(".module-card-item-class")
                else ""
            )
            source_id = f"{kind}:{detail_id}" if detail_id and kind else ""
            if not source_id or source_id in seen:
                continue
            title_element = card.select_one(".module-card-item-title")
            image = card.select_one("img")
            title = (
                title_element.get_text(" ", strip=True)
                if title_element
                else str(image.get("alt", "")).strip() if image else ""
            )
            if not title:
                continue
            seen.add(source_id)
            note_element = card.select_one(".module-item-note")
            note = note_element.get_text(" ", strip=True) if note_element else ""
            info_element = card.select_one(".module-info-item-content")
            info = info_element.get_text(" ", strip=True) if info_element else ""
            cover = ""
            if image:
                cover = str(
                    image.get("data-original", "")
                    or image.get("data-src", "")
                    or image.get("src", "")
                )
            count = _episode_count(note)
            results.append(
                SubjectResult(
                    source_id=source_id,
                    title=title,
                    cover_url=urljoin(str(response.url), cover),
                    type=kind,
                    lang="ja" if kind == "anime" else "zh",
                    year=_year(info),
                    status=1 if "全" in note or kind == "movie" else 0,
                    episode_count=count or (1 if kind == "movie" else 0),
                    latest_episode=count,
                )
            )
        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        source = self._source_parts(source_id)
        if source is None:
            return None
        kind, detail_id = source
        response = await self._client.get(f"{self.base_url}/nivod/{detail_id}/")
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.content, "lxml")
        title_element = soup.select_one("h1")
        title = title_element.get_text(" ", strip=True) if title_element else ""
        if not title:
            title = _meta_content(soup, "og:title").split("-")[0].strip()
        cover = _meta_content(soup, "og:image")
        if not cover:
            image = soup.select_one(".module-info-poster img")
            if image:
                cover = str(
                    image.get("data-original", "")
                    or image.get("data-src", "")
                    or image.get("src", "")
                )
        summary_element = soup.select_one(".module-info-introduction")
        summary = (
            summary_element.get_text(" ", strip=True)
            if summary_element
            else _meta_content(soup, "description")
        )
        episodes = self._episodes(soup, detail_id)
        heading = soup.select_one(".module-info-heading")
        heading_text = heading.get_text(" ", strip=True) if heading else ""
        return SubjectDetail(
            source_id=source_id,
            title=title,
            cover_url=urljoin(str(response.url), cover),
            summary=summary,
            type=kind,
            lang="ja" if kind == "anime" else "zh",
            year=_year(heading_text),
            status=1 if kind == "movie" else 0,
            episodes=episodes,
            extra={"url": str(response.url)},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        source = self._source_parts(source_id)
        if source is None:
            return []
        _kind, detail_id = source
        detail_url = f"{self.base_url}/nivod/{detail_id}/"
        response = await self._client.get(detail_url)
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.content, "lxml")
        labels = self._line_labels(soup)
        selected_episode = max(1, episode)
        play_urls: list[tuple[int, str]] = []
        for link in soup.select(f'a[href^="/niplay/{detail_id}-"]'):
            match = self._PLAY_PATH_RE.fullmatch(
                urlparse(str(link.get("href", ""))).path
            )
            if not match or int(match.group(3)) != selected_episode:
                continue
            play_urls.append(
                (int(match.group(2)), urljoin(str(response.url), str(link.get("href"))))
            )

        lines: list[VideoLine] = []
        seen: set[str] = set()
        for line_number, play_url in sorted(dict.fromkeys(play_urls)):
            play_response = await self._client.get(play_url)
            if play_response.status_code != 200:
                continue
            media_url = _player_media_url(play_response.text)
            if not media_url or media_url in seen:
                continue
            seen.add(media_url)
            label = labels.get(line_number, f"线路{line_number}")
            quality = "4K" if "4K" in label.upper() else (
                "1080p" if "1080" in label else ""
            )
            lines.append(
                VideoLine(
                    url=media_url,
                    title=f"泥视频 · {label}",
                    quality=quality,
                    format=_media_format(media_url),
                    headers={"Referer": f"{self.base_url}/", "Origin": self.base_url},
                    source_name=self.name,
                )
            )
        return lines

    def _source_parts(self, source_id: str) -> tuple[str, str] | None:
        match = self._SOURCE_RE.fullmatch(source_id.strip())
        return (match.group(1), match.group(2)) if match else None

    def _detail_id(self, value: str) -> str:
        parsed = urlparse(urljoin(self.base_url + "/", value))
        base_host = (urlparse(self.base_url).hostname or "").removeprefix("www.")
        host = (parsed.hostname or "").removeprefix("www.")
        if parsed.scheme not in {"http", "https"} or host != base_host:
            return ""
        match = self._DETAIL_PATH_RE.fullmatch(parsed.path)
        return match.group(1) if match else ""

    @classmethod
    def _episodes(cls, soup: BeautifulSoup, detail_id: str) -> list[EpisodeInfo]:
        episodes: dict[int, EpisodeInfo] = {}
        for link in soup.select(f'a[href^="/niplay/{detail_id}-"]'):
            match = cls._PLAY_PATH_RE.fullmatch(
                urlparse(str(link.get("href", ""))).path
            )
            if not match:
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
        return [episodes[number] for number in sorted(episodes)]

    @staticmethod
    def _content_type(value: str) -> str:
        if "动漫" in value or "动画" in value:
            return "anime"
        if "电影" in value:
            return "movie"
        if "剧" in value:
            return "tv"
        return ""

    @staticmethod
    def _line_labels(soup: BeautifulSoup) -> dict[int, str]:
        labels: dict[int, str] = {}
        for index, element in enumerate(soup.select(".module-tab-item"), 1):
            text = element.get_text(" ", strip=True)
            text = re.sub(r"\s+\d+\s*$", "", text).strip()
            labels[index] = text or f"线路{index}"
        return labels


class DbkuScraper(BaseScraper):
    """Direct adapter for DBKU's public movie and series catalog.

    DBKU pages include Google advertising scripts.  Zeluna never renders those
    pages in the client: the adapter reads metadata server-side and returns only
    the literal media URL.  HLS advertisements are still detected by the normal
    playback verifier and are not treated as a successful line on HTTP status
    alone.
    """

    _SOURCE_RE = re.compile(r"^(tv|movie):(\d+)$")
    _DETAIL_PATH_RE = re.compile(r"^/voddetail/(\d+)\.html$")
    _PLAY_PATH_RE = re.compile(r"^/vodplay/(\d+)-(\d+)-(\d+)\.html$")

    def __init__(
        self,
        *,
        base_url: str = "https://www.dbku.tv",
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "dbku"
        self._base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": _USER_AGENT,
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=15,
            follow_redirects=True,
            transport=transport,
        )

    @property
    def content_types(self) -> list[str]:
        return ["series", "movie"]

    @property
    def base_url(self) -> str:
        return self._base_url

    async def search(self, keyword: str) -> list[SubjectResult]:
        keyword = keyword.strip()
        if not keyword:
            return []
        response = await self._client.get(
            f"{self.base_url}/vodsearch/-------------.html",
            params={"wd": keyword},
        )
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.content, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for item in soup.select("li.clearfix"):
            link = item.select_one('a[href^="/voddetail/"]')
            if link is None:
                continue
            detail_id = self._detail_id(str(link.get("href", "")))
            if not detail_id:
                continue
            text = item.get_text(" ", strip=True)
            kind = "movie" if "电影" in text else "tv"
            source_id = f"{kind}:{detail_id}"
            if source_id in seen:
                continue
            title = str(link.get("title", "")).strip()
            if not title:
                heading = item.select_one("h4.title, .title")
                title = heading.get_text(" ", strip=True) if heading else ""
            if not title:
                continue
            seen.add(source_id)
            cover = str(
                link.get("data-original", "")
                or link.get("data-src", "")
                or link.get("style", "")
            )
            if cover.startswith("background-image"):
                cover_match = re.search(r"url\(['\"]?([^'\")]+)", cover)
                cover = cover_match.group(1) if cover_match else ""
            note_element = item.select_one(".pic-text")
            note = note_element.get_text(" ", strip=True) if note_element else ""
            count_match = re.search(r"(\d+)\s*集", note)
            count = int(count_match.group(1)) if count_match else 0
            results.append(
                SubjectResult(
                    source_id=source_id,
                    title=title,
                    cover_url=urljoin(str(response.url), cover),
                    type=kind,
                    lang="zh",
                    year=_year(text),
                    status=1 if kind == "movie" or "全" in note else 0,
                    episode_count=count or (1 if kind == "movie" else 0),
                    latest_episode=count,
                )
            )
        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        source = self._source_parts(source_id)
        if source is None:
            return None
        kind, detail_id = source
        response = await self._client.get(
            f"{self.base_url}/voddetail/{detail_id}.html"
        )
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.content, "lxml")
        heading = soup.select_one("h1")
        title = heading.get_text(" ", strip=True) if heading else ""
        if not title:
            return None
        image = soup.select_one(".myui-content__thumb img, .myui-vodlist__thumb")
        cover = ""
        if image:
            cover = str(
                image.get("data-original", "")
                or image.get("data-src", "")
                or image.get("src", "")
            )
        detail = soup.select_one(".myui-content__detail")
        detail_text = detail.get_text(" ", strip=True) if detail else ""
        summary = _meta_content(soup, "description")
        episodes = self._episodes(soup, detail_id)
        return SubjectDetail(
            source_id=source_id,
            title=title,
            cover_url=urljoin(str(response.url), cover),
            summary=summary,
            type=kind,
            lang="zh",
            year=_year(detail_text),
            status=1 if kind == "movie" else 0,
            episodes=episodes,
            extra={"url": str(response.url)},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        source = self._source_parts(source_id)
        if source is None:
            return []
        _kind, detail_id = source
        response = await self._client.get(
            f"{self.base_url}/voddetail/{detail_id}.html"
        )
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.content, "lxml")
        selected = max(1, episode)
        play_urls: list[tuple[int, str]] = []
        for link in soup.select(f'a[href^="/vodplay/{detail_id}-"]'):
            match = self._PLAY_PATH_RE.fullmatch(
                urlparse(str(link.get("href", ""))).path
            )
            if not match or int(match.group(3)) != selected:
                continue
            play_urls.append(
                (int(match.group(2)), urljoin(str(response.url), str(link.get("href"))))
            )

        lines: list[VideoLine] = []
        seen: set[str] = set()
        for line_number, play_url in sorted(dict.fromkeys(play_urls)):
            play_response = await self._client.get(play_url)
            if play_response.status_code != 200:
                continue
            media_url = _player_media_url(play_response.text)
            if not media_url or media_url in seen:
                continue
            seen.add(media_url)
            lines.append(
                VideoLine(
                    url=media_url,
                    title=f"独播库 · 线路{line_number}",
                    format=_media_format(media_url),
                    headers={"Referer": play_url, "Origin": self.base_url},
                    source_name=self.name,
                )
            )
        return lines

    def _source_parts(self, source_id: str) -> tuple[str, str] | None:
        match = self._SOURCE_RE.fullmatch(source_id.strip())
        return (match.group(1), match.group(2)) if match else None

    def _detail_id(self, value: str) -> str:
        parsed = urlparse(urljoin(self.base_url + "/", value))
        base_host = (urlparse(self.base_url).hostname or "").removeprefix("www.")
        host = (parsed.hostname or "").removeprefix("www.")
        if parsed.scheme not in {"http", "https"} or host != base_host:
            return ""
        match = self._DETAIL_PATH_RE.fullmatch(parsed.path)
        return match.group(1) if match else ""

    @classmethod
    def _episodes(cls, soup: BeautifulSoup, detail_id: str) -> list[EpisodeInfo]:
        episodes: dict[int, EpisodeInfo] = {}
        for link in soup.select(f'a[href^="/vodplay/{detail_id}-"]'):
            match = cls._PLAY_PATH_RE.fullmatch(
                urlparse(str(link.get("href", ""))).path
            )
            if not match:
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
        return [episodes[number] for number in sorted(episodes)]


class PpnixScraper(BaseScraper):
    """Direct adapter for PPnix's first-party IPFS-backed HLS catalog."""

    _SOURCE_RE = re.compile(r"^(tv|movie):(\d+)$")
    _DETAIL_PATH_RE = re.compile(r"^/cn/(tv|movie)/(\d+)\.html$")

    def __init__(
        self,
        *,
        base_url: str = "https://www.ppnix.com",
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        super().__init__()
        self._name = "ppnix"
        self._base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": _USER_AGENT,
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=15,
            follow_redirects=True,
            transport=transport,
        )

    @property
    def content_types(self) -> list[str]:
        return ["series", "movie"]

    @property
    def base_url(self) -> str:
        return self._base_url

    async def search(self, keyword: str) -> list[SubjectResult]:
        keyword = keyword.strip()
        if not keyword:
            return []
        response = await self._client.get(
            f"{self.base_url}/cn/search/{quote(keyword)}--.html"
        )
        if response.status_code != 200:
            return []
        soup = BeautifulSoup(response.content, "lxml")
        results: list[SubjectResult] = []
        seen: set[str] = set()
        for item in soup.select("li"):
            link = item.select_one('a[href^="/cn/tv/"], a[href^="/cn/movie/"]')
            if link is None:
                continue
            source = self._source_from_url(str(link.get("href", "")))
            if source is None:
                continue
            kind, detail_id = source
            source_id = f"{kind}:{detail_id}"
            if source_id in seen:
                continue
            image = item.select_one("img")
            heading = item.select_one("h2")
            title = (
                heading.get_text(" ", strip=True)
                if heading
                else str(image.get("alt", "")).strip() if image else ""
            )
            if not title:
                continue
            seen.add(source_id)
            text = item.get_text(" ", strip=True)
            cover = str(image.get("src", "")).strip() if image else ""
            rating_element = item.select_one(".rate, .rating")
            try:
                rating = float(rating_element.get_text(strip=True)) if rating_element else 0.0
            except ValueError:
                rating = 0.0
            results.append(
                SubjectResult(
                    source_id=source_id,
                    title=title,
                    cover_url=urljoin(str(response.url), cover),
                    type="tv" if kind == "tv" else "movie",
                    lang="zh",
                    year=_year(text),
                    rating=rating,
                )
            )
        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        source = self._source_parts(source_id)
        if source is None:
            return None
        kind, detail_id = source
        detail_url = f"{self.base_url}/cn/{kind}/{detail_id}.html"
        response = await self._client.get(detail_url)
        if response.status_code != 200:
            return None
        soup = BeautifulSoup(response.content, "lxml")
        heading = soup.select_one("h1")
        if heading is None:
            return None
        title = " ".join(
            text.strip() for text in heading.find_all(string=True, recursive=False) if text.strip()
        ).strip() or heading.get_text(" ", strip=True)
        title = re.sub(r"\s*\(?(?:19|20)\d{2}\)?.*$", "", title).strip()
        # PPnix pages also contain a logo with ``alt``. Prefer the actual
        # poster so detail cards never inherit the site logo as their cover.
        image = soup.select_one("img.thumb, .product-image img, .poster img")
        if image is None:
            image = soup.select_one('img[alt]')
        cover = str(image.get("src", "")).strip() if image else ""
        summary = _meta_content(soup, "description")
        labels = self._playlist_labels(response.text)
        episodes = [
            EpisodeInfo(
                number=index,
                title=("正片" if kind == "movie" else f"第{index}集"),
                source_episode_id=value,
            )
            for index, value in enumerate(labels, 1)
        ]
        rating_element = heading.select_one(".rate")
        try:
            rating = float(rating_element.get_text(strip=True)) if rating_element else 0.0
        except ValueError:
            rating = 0.0
        return SubjectDetail(
            source_id=source_id,
            title=title,
            cover_url=urljoin(str(response.url), cover),
            summary=summary,
            type="tv" if kind == "tv" else "movie",
            lang="zh",
            year=_year(heading.get_text(" ", strip=True)),
            status=1 if kind == "movie" else 0,
            rating=rating,
            episodes=episodes,
            extra={"url": str(response.url)},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        source = self._source_parts(source_id)
        if source is None:
            return []
        kind, detail_id = source
        detail_url = f"{self.base_url}/cn/{kind}/{detail_id}.html"
        response = await self._client.get(detail_url)
        if response.status_code != 200:
            return []
        labels = self._playlist_labels(response.text)
        index = max(1, episode) - 1
        if index >= len(labels):
            return []
        label = labels[index]
        media_url = f"{self.base_url}/info/m3u8/{detail_id}/{quote(label)}.m3u8"
        return [
            VideoLine(
                url=media_url,
                title=f"PPnix · {label if kind == 'movie' else f'第{episode}集'}",
                quality="1080p" if "1080" in label else "",
                format="hls",
                headers={"Referer": detail_url, "Origin": self.base_url},
                source_name=self.name,
            )
        ]

    def _source_parts(self, source_id: str) -> tuple[str, str] | None:
        match = self._SOURCE_RE.fullmatch(source_id.strip())
        return (match.group(1), match.group(2)) if match else None

    def _source_from_url(self, value: str) -> tuple[str, str] | None:
        parsed = urlparse(urljoin(self.base_url + "/", value))
        base_host = (urlparse(self.base_url).hostname or "").removeprefix("www.")
        host = (parsed.hostname or "").removeprefix("www.")
        if parsed.scheme not in {"http", "https"} or host != base_host:
            return None
        match = self._DETAIL_PATH_RE.fullmatch(parsed.path)
        return (match.group(1), match.group(2)) if match else None

    @staticmethod
    def _playlist_labels(text: str) -> list[str]:
        match = re.search(r"\bm3u8\s*=\s*\[([^]]*)\]", text, re.IGNORECASE)
        if not match:
            return []
        return re.findall(r"['\"]([^'\"]+)['\"]", match.group(1))
