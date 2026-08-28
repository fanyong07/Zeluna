"""yhdmm 站点适配器(樱花动漫系)。

2026-08-28 实测:详情 ``/show/{sid}.html``、播放 ``/v/{sid}-{线}-{集}.html``、
``player_aaaa`` 明文(encrypt=0),单集 4 条线路全部 Range 206 可播。

⚠️ **站内搜索不可用**:``/search.html?wd=`` 与 ``/search/---.../?wd=`` 都被
边缘缓存按路径缓存、彻底忽略 query string —— 两个不同关键词返回长度恒为
67850B 的同一页面。请求到不了服务端搜索逻辑,加 no-cache 头无效。
因此本站 ``site_search_usable = False``,由上层用列表页建本地索引后
在本地做关键词匹配(``site_index`` 模块)。

早期把这类"假成功"当搜索可用是有害的:第一次搜的词恰好命中缓存内容时
看起来正常。所以 ``search()`` 会校验结果与关键词的相关性,宁可返回空,
也不把无关作品当匹配结果喂给上层。
"""

from __future__ import annotations

import re
from typing import Optional
from urllib.parse import urljoin

import httpx

from ..base import EpisodeInfo, SubjectDetail, SubjectResult, VideoLine
from ..site_index import SiteIndex, normalize_title
from .site_base import (
    SITE_STATUS_OK,
    EpisodeCandidate,
    SiteAnimeScraper,
    decode_play_url,
    safe_request_url,
    select_episode_candidates,
)

_PLAY_PATH_RE = re.compile(r"^/v/(\d+)-(\d+)-(\d+)\.html$")
#: 相关性门禁:本地索引命中分低于此值不返回(防"假成功")
_MIN_LOCAL_MATCH_SCORE = 0.5
#: 空窗期惰性建索引的页数。发现路径有超时预算,只抓首页级别的量。
_LAZY_INDEX_PAGES = 1


class YhdmmScraper(SiteAnimeScraper):
    """``www.yhdmm.com`` 直连适配器。"""

    site = "yhdmm"
    family = "yinghua"
    default_base_url = "https://www.yhdmm.com"
    status = SITE_STATUS_OK
    detail_template = "/show/{sid}.html"
    play_link_patterns = (
        r'href="(/v/\d+-\d+-\d+\.html)"',
    )
    detail_link_pattern = r"/show/(\d+)\.html"
    list_paths = ("/", "/list/1.html", "/list/2.html", "/list/3.html")
    site_search_usable = False        # 搜索被边缘缓存冻结,见模块 docstring

    def __init__(
        self,
        base_url: str | None = None,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        index: SiteIndex | None = None,
    ) -> None:
        super().__init__(base_url)
        self._index = index
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/126.0.0.0 Safari/537.36"
                ),
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=15,
            follow_redirects=True,
            transport=transport,
        )

    @property
    def index(self) -> SiteIndex | None:
        return self._index

    def attach_index(self, index: SiteIndex) -> None:
        """由上层(定期任务)构建好索引后注入。"""
        self._index = index

    async def _get(self, url: str, *, referer: str = "") -> str:
        try:
            response = await self._client.get(
                safe_request_url(url), headers=self.request_headers(referer=referer)
            )
        except httpx.HTTPError:
            return ""
        return response.text if response.status_code == 200 else ""

    async def search(self, keyword: str) -> list[SubjectResult]:
        """只走本地索引;不去撞被边缘缓存冻结的站内搜索。

        索引尚未建好时(进程刚起、后台首轮重建未完成)当场惰性建一次,
        否则该源在空窗期等于没接上。失败就返回空,不阻断上层发现流程。
        """
        keyword = (keyword or "").strip()
        if not keyword:
            return []
        if self._index is None:
            try:
                await self.build_local_index(pages=_LAZY_INDEX_PAGES)
            except Exception:  # noqa: BLE001 - 建索引失败不应影响其它源
                return []
        if self._index is None:
            return []
        results: list[SubjectResult] = []
        for sid, title, score in self._index.search(keyword, limit=10):
            if score < _MIN_LOCAL_MATCH_SCORE:
                continue
            results.append(
                SubjectResult(
                    source_id=sid,
                    title=title,
                    type="anime",
                    lang="ja",
                    extra={"match_score": score},
                )
            )
        return results

    async def _episode_candidates(self, sid: str) -> list[EpisodeCandidate]:
        html = await self._get(self.detail_url(sid))
        if not html:
            return []
        candidates: list[EpisodeCandidate] = []
        per_line: dict[str, int] = {}
        for path in self.extract_play_links(html):
            match = _PLAY_PATH_RE.match(path)
            if not match or match.group(1) != str(sid):
                continue
            line_key = match.group(2)
            label = self._label_for(html, path) or f"第{match.group(3)}集"
            index = per_line.get(line_key, 0)
            per_line[line_key] = index + 1
            candidates.append(
                EpisodeCandidate(
                    line_key=line_key, label=label, page_path=path, index=index
                )
            )
        return candidates

    @staticmethod
    def _label_for(html: str, path: str) -> str:
        """取该播放页链接的锚文本作为集标签。"""
        match = re.search(
            re.escape(path) + r'"[^>]*>\s*(?:<[^>]+>\s*)*([^<]{1,24})', html
        )
        return match.group(1).strip() if match else ""

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        sid = str(source_id).strip()
        if not sid.isdigit():
            return None
        html = await self._get(self.detail_url(sid))
        if not html:
            return None
        title_match = (
            re.search(r'<h1[^>]*>\s*([^<]{2,60})', html)
            or re.search(r'"vod_name"\s*:\s*"([^"]{2,60})"', html)
            or re.search(r"<title>\s*([^<|-]{2,60})", html)
        )
        title = title_match.group(1).strip() if title_match else ""
        cover_match = re.search(
            r'<meta property="og:image" content="([^"]+)"', html
        )
        cover = urljoin(self.base_url + "/", cover_match.group(1)) if cover_match else ""

        episodes: dict[int, EpisodeInfo] = {}
        for candidate in await self._episode_candidates(sid):
            number_match = re.search(r"(\d+)", candidate.label)
            number = int(number_match.group(1)) if number_match else candidate.index + 1
            episodes.setdefault(
                number,
                EpisodeInfo(
                    number=number,
                    title=candidate.label or f"第{number}集",
                    source_episode_id=candidate.page_path,
                ),
            )
        return SubjectDetail(
            source_id=sid,
            title=title,
            cover_url=cover,
            type="anime",
            lang="ja",
            episodes=[episodes[key] for key in sorted(episodes)],
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        sid = str(source_id).strip()
        if not sid.isdigit():
            return []
        candidates = await self._episode_candidates(sid)
        # 冗余最大化:每条线路各出一个候选,首条死链可自动换下一条
        selected = select_episode_candidates(candidates, int(episode))
        detail_url = self.detail_url(sid)
        lines: list[VideoLine] = []
        seen: set[str] = set()
        for candidate in selected:
            play_url = urljoin(self.base_url + "/", candidate.page_path.lstrip("/"))
            html = await self._get(play_url, referer=detail_url)
            if not html:
                continue
            config = self.parse_player_config(html)
            media = decode_play_url(
                str(config.get("url") or ""), config.get("encrypt", 0)
            )
            if not media.lower().startswith(("http://", "https://")):
                continue
            key = media.lower()
            if key in seen:
                continue
            seen.add(key)
            lines.append(
                VideoLine(
                    url=media,
                    title=f"{candidate.label} · 线路{candidate.line_key}",
                    format="hls" if ".m3u8" in key else "",
                    headers={"Referer": play_url} if self.send_referer else {},
                    source_name=self.name,
                )
            )
        return lines

    async def build_local_index(self, *, pages: int = 3) -> SiteIndex:
        """抓列表页建本地索引(该站站内搜索不可用时的唯一入口)。"""
        from ..site_index import build_index

        index = await build_index(
            site=self.site,
            base_url=self.base_url,
            list_paths=self.list_paths,
            detail_pattern=self.detail_link_pattern,
            client=self._client,
            pages=pages,
            headers=self.request_headers(),
        )
        self._index = index
        return index

    async def aclose(self) -> None:
        await self._client.aclose()


def relevance_ok(keyword: str, title: str) -> bool:
    """给上层用的相关性校验:防止把缓存里的无关作品当成搜索结果。"""
    left, right = normalize_title(keyword), normalize_title(title)
    if not left or not right:
        return False
    return left in right or right in left
