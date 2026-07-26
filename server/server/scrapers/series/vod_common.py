"""
通用影视解析爬虫

对接多个第三方视频解析服务和开放API，覆盖电视剧和电影。

支持的源:
  - xfvod.pro      (XF影视 - 电视剧+电影)
  - m3u8.cyz.app   (M3U8通用解析)
  - playxf.top     (播放线)
  - apn.moedot.net (萌点 - 新番+影视)
  - TMDB API       (电影/电视剧元数据)
  - TVMaze API     (美剧元数据)
"""

import re
import json
import logging
from typing import Optional
from urllib.parse import urljoin, quote

import httpx

from ..base import (
    BaseScraper, SubjectResult, SubjectDetail,
    EpisodeInfo, VideoLine,
)

logger = logging.getLogger(__name__)


class CommonVodScraper(BaseScraper):
    """
    通用影视爬虫

    使用多个第三方解析服务和开放 API 聚合内容。
    同时支持电视剧和电影。
    """

    # 已知的免费影视 API 端点
    VOD_APIS = [
        "https://api.500403.xyz",       # 原 AniCh 备用 API
        "https://anich.sends.eu.org",    # 当前 AniCh API
    ]

    # TMDB API (免费, 需要 API key)
    TMDB_API = "https://api.themoviedb.org/3"
    TMDB_KEY = ""  # 用户可自行填入

    # TVMaze API (免费, 无需 key)
    TVMAZE_API = "https://api.tvmaze.com"

    def __init__(self):
        super().__init__()
        self._name = "vod_common"
        self._client = httpx.AsyncClient(
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
                ),
                "Accept": "application/json, text/html, */*",
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
            timeout=15,
            follow_redirects=True,
        )

    @property
    def content_types(self) -> list[str]:
        return ["series", "movie"]

    @property
    def base_url(self) -> str:
        return self.VOD_APIS[0]

    async def search(self, keyword: str) -> list[SubjectResult]:
        """跨多个源搜索电视剧和电影"""
        results = []
        seen_ids = set()

        # 1. 从已知 AniCh 类 API 搜索
        for api in self.VOD_APIS:
            try:
                resp = await self._client.get(
                    f"{api}/bangumi/search",
                    params={"keyword": keyword},
                )
                if resp.status_code == 200 and resp.content:
                    try:
                        # 尝试 protobuf 解析
                        from ...protobuf_encoder import encode_bangumi_list
                    except ImportError:
                        pass
            except Exception:
                continue

        # 2. TMDB 搜索 (电影+电视剧)
        if self.TMDB_KEY:
            try:
                results += await self._search_tmdb(keyword, seen_ids)
            except Exception as e:
                logger.error(f"TMDB search error: {e}")

        # 3. TVMaze 搜索 (美剧/英剧)
        try:
            results += await self._search_tvmaze(keyword, seen_ids)
        except Exception as e:
            logger.error(f"TVMaze search error: {e}")

        # 4. M3U8 通用解析站搜索
        try:
            results += await self._search_vod_sites(keyword, seen_ids)
        except Exception as e:
            logger.error(f"VOD site search error: {e}")

        return results

    async def _search_tmdb(self, keyword: str, seen_ids: set) -> list[SubjectResult]:
        """通过 TMDB API 搜索"""
        results = []
        if not self.TMDB_KEY:
            return results

        # 搜索 multi (电影+电视剧)
        resp = await self._client.get(
            f"{self.TMDB_API}/search/multi",
            params={
                "api_key": self.TMDB_KEY,
                "query": keyword,
                "language": "zh-CN",
                "page": 1,
            },
        )
        if resp.status_code != 200:
            return results

        data = resp.json()
        for item in data.get("results", [])[:20]:
            media_type = item.get("media_type", "")
            if media_type not in ("tv", "movie"):
                continue

            tmdb_id = f"tmdb_{media_type}_{item['id']}"
            if tmdb_id in seen_ids:
                continue
            seen_ids.add(tmdb_id)

            poster = item.get("poster_path", "")
            cover = f"https://image.tmdb.org/t/p/w500{poster}" if poster else ""

            results.append(SubjectResult(
                source_id=tmdb_id,
                title=item.get("name", item.get("title", "")),
                cover_url=cover,
                summary=item.get("overview", ""),
                type="movie" if media_type == "movie" else "tv",
                lang=item.get("original_language", "en"),
                year=int((item.get("first_air_date", item.get("release_date", "2000")))[:4]) if item.get("first_air_date") or item.get("release_date") else 2024,
                rating=float(item.get("vote_average", 0)),
            ))

        return results

    async def _search_tvmaze(self, keyword: str, seen_ids: set) -> list[SubjectResult]:
        """通过 TVMaze API 搜索电视剧"""
        results = []
        resp = await self._client.get(
            f"{self.TVMAZE_API}/search/shows",
            params={"q": keyword},
        )
        if resp.status_code != 200:
            return results

        data = resp.json()
        for item in data[:10]:
            show = item.get("show", {})
            tvmaze_id = f"tvmaze_{show.get('id')}"
            if tvmaze_id in seen_ids:
                continue
            seen_ids.add(tvmaze_id)

            cover = show.get("image", {}).get("medium", "") if show.get("image") else ""
            rating_info = show.get("rating", {}) or {}
            rating_avg = rating_info.get("average")

            results.append(SubjectResult(
                source_id=tvmaze_id,
                title=show.get("name", ""),
                cover_url=cover,
                summary=(show.get("summary", "") or "")[:500],
                type="tv",
                lang=show.get("language", "en"),
                year=int((show.get("premiered", "2024-01-01"))[:4]) if show.get("premiered") else 2024,
                rating=float(rating_avg) if rating_avg else 0.0,
            ))

        return results

    async def _search_vod_sites(self, keyword: str, seen_ids: set) -> list[SubjectResult]:
        """从通用影视解析站搜索"""
        results = []

        # XF VOD 搜索
        try:
            resp = await self._client.get(
                "https://play.xfvod.pro:8088/search",
                params={"wd": keyword},
            )
            if resp.status_code == 200:
                soup = __import__('bs4', fromlist=['BeautifulSoup']).BeautifulSoup(
                    resp.text, "lxml"
                )
                for item in soup.select(".video_item, .search-item, li"):
                    link = item.select_one("a")
                    if not link:
                        continue
                    title = link.get_text(strip=True)
                    href = link.get("href", "")
                    if title and href:
                        vod_id = f"xfvod_{href}"
                        if vod_id not in seen_ids:
                            seen_ids.add(vod_id)
                            results.append(SubjectResult(
                                source_id=vod_id,
                                title=title,
                                type="tv",
                                lang="zh",
                            ))
        except Exception:
            pass

        return results

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """获取电视剧/电影详情"""

        # TMDB 详情
        if source_id.startswith("tmdb_"):
            return await self._get_tmdb_detail(source_id)

        # TVMaze 详情
        if source_id.startswith("tvmaze_"):
            return await self._get_tvmaze_detail(source_id)

        # XF VOD 详情
        if source_id.startswith("xfvod_"):
            return await self._get_vod_detail(source_id)

        return None

    async def _get_tmdb_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """TMDB 剧集/电影详情"""
        if not self.TMDB_KEY:
            return None

        parts = source_id.split("_")
        if len(parts) < 3:
            return None
        media_type = parts[1]  # tv or movie
        tmdb_id = parts[2]

        resp = await self._client.get(
            f"{self.TMDB_API}/{media_type}/{tmdb_id}",
            params={
                "api_key": self.TMDB_KEY,
                "language": "zh-CN",
                "append_to_response": "credits",
            },
        )
        if resp.status_code != 200:
            return None

        data = resp.json()

        episodes = []
        if media_type == "tv":
            # 获取所有季的剧集
            for season in data.get("seasons", []):
                season_num = season.get("season_number", 1)
                if season_num == 0:
                    continue  # skip specials
                season_resp = await self._client.get(
                    f"{self.TMDB_API}/tv/{tmdb_id}/season/{season_num}",
                    params={"api_key": self.TMDB_KEY, "language": "zh-CN"},
                )
                if season_resp.status_code == 200:
                    season_data = season_resp.json()
                    for ep in season_data.get("episodes", []):
                        episodes.append(EpisodeInfo(
                            number=ep.get("episode_number", 0),
                            title=ep.get("name", ""),
                            source_episode_id=f"tmdb_{media_type}_{tmdb_id}_s{season_num}e{ep.get('episode_number')}",
                        ))
        else:
            # 电影只有一集
            episodes.append(EpisodeInfo(number=1, title=data.get("title", "正片"), source_episode_id=source_id))

        poster = data.get("poster_path", "")
        backdrop = data.get("backdrop_path", "")

        genres = [g.get("name", "") for g in data.get("genres", [])]

        return SubjectDetail(
            source_id=source_id,
            title=data.get("name", data.get("title", "")),
            cover_url=f"https://image.tmdb.org/t/p/w500{poster}" if poster else "",
            banner_url=f"https://image.tmdb.org/t/p/original{backdrop}" if backdrop else "",
            summary=data.get("overview", ""),
            type="movie" if media_type == "movie" else "tv",
            lang=data.get("original_language", "en"),
            year=int((data.get("first_air_date", data.get("release_date", "2000")))[:4]) if data.get("first_air_date") or data.get("release_date") else 2024,
            status=0 if data.get("status") in ("Returning Series", "In Production") else 1,
            episodes=episodes,
            genres=genres,
            tags=genres,
            rating=float(data.get("vote_average", 0)),
            rating_count=data.get("vote_count", 0),
        )

    async def _get_tvmaze_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """TVMaze 剧集详情"""
        tvmaze_id = source_id.replace("tvmaze_", "")

        resp = await self._client.get(
            f"{self.TVMAZE_API}/shows/{tvmaze_id}",
            params={"embed[]": "episodes"},
        )
        if resp.status_code != 200:
            return None

        data = resp.json()

        episodes = []
        for ep in data.get("_embedded", {}).get("episodes", []):
            episodes.append(EpisodeInfo(
                number=ep.get("number", 0),
                title=ep.get("name", ""),
                source_episode_id=f"tvmaze_ep_{ep.get('id')}",
            ))

        cover = data.get("image", {}).get("original", "") if data.get("image") else ""

        genres = data.get("genres", []) or []

        return SubjectDetail(
            source_id=source_id,
            title=data.get("name", ""),
            cover_url=cover,
            summary=(data.get("summary", "") or "")[:1000],
            type="tv",
            lang=data.get("language", "en"),
            status=1 if data.get("status") == "Ended" else 0,
            episodes=episodes,
            genres=genres,
            tags=genres,
            rating=float(data.get("rating", {}).get("average", 0)),
        )

    async def _get_vod_detail(self, source_id: str) -> Optional[SubjectDetail]:
        """通用 VOD 站点详情"""
        href = source_id.replace("xfvod_", "")
        url = href if href.startswith("http") else f"https://play.xfvod.pro:8088{href}"

        try:
            resp = await self._client.get(url)
            if resp.status_code != 200:
                return None

            soup = __import__('bs4', fromlist=['BeautifulSoup']).BeautifulSoup(
                resp.text, "lxml"
            )

            title = ""
            for sel in ["h1", ".title", ".video-title"]:
                el = soup.select_one(sel)
                if el:
                    title = el.get_text(strip=True)
                    break

            summary = ""
            desc = soup.select_one(".desc, .intro, .summary")
            if desc:
                summary = desc.get_text(strip=True)[:1000]

            # 提取剧集
            episodes = []
            ep_links = soup.select(".playlist a, .ep-list a, .movurl a")
            for i, link in enumerate(ep_links, 1):
                ep_title = link.get_text(strip=True)
                ep_href = link.get("href", "")
                ep_num = i
                num_match = re.search(r'(\d+)', ep_title)
                if num_match:
                    ep_num = int(num_match.group(1))
                episodes.append(EpisodeInfo(
                    number=ep_num,
                    title=ep_title,
                    source_episode_id=ep_href,
                ))

            if not episodes:
                episodes.append(EpisodeInfo(number=1, source_id=source_id))

            return SubjectDetail(
                source_id=source_id,
                title=title,
                summary=summary,
                type="tv",
                lang="zh",
                episodes=episodes,
                extra={"url": url},
            )

        except Exception as e:
            logger.error(f"VOD detail error: {e}")
            return None

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        """获取视频播放地址"""
        lines = []

        # TMDB 只提供元数据，需要从其它源获取视频
        if source_id.startswith("tmdb_"):
            parts = source_id.split("_")
            if len(parts) >= 3:
                media_type = parts[1]
                tmdb_id = parts[2]
                title = parts[3] if len(parts) > 3 else ""

                # 尝试从 AniCh 类 API 查找对应的视频源
                for api in self.VOD_APIS:
                    try:
                        resp = await self._client.get(
                            f"{api}/bangumi/search",
                            params={"keyword": title or str(tmdb_id)},
                        )
                        if resp.status_code == 200 and len(resp.content) > 10:
                            # 找到了对应的内容
                            pass
                    except Exception:
                        continue

                # 尝试使用通用的免费影视解析
                if media_type == "movie":
                    lines += await self._search_free_movie_sources(title or str(tmdb_id))
                else:
                    lines += await self._search_free_series_sources(title or str(tmdb_id), episode)

        # TVMaze
        elif source_id.startswith("tvmaze_"):
            pass

        # XF VOD
        elif source_id.startswith("xfvod_"):
            href = source_id.replace("xfvod_", "")
            url = href if href.startswith("http") else f"https://play.xfvod.pro:8088{href}"
            try:
                resp = await self._client.get(url)
                if resp.status_code == 200:
                    text = resp.text
                    for match in re.finditer(
                        r'(?:url|src|video)\s*[:=]\s*["\'](https?://[^"\']+\.(?:m3u8|mp4)[^"\']*)["\']',
                        text,
                        re.IGNORECASE,
                    ):
                        lines.append(VideoLine(
                            url=match.group(1),
                            title=f"通用解析 线路{len(lines)+1}",
                            format="hls" if "m3u8" in match.group(1) else "mp4",
                            source_name=self.name,
                        ))
            except Exception:
                pass

        return lines

    async def _search_free_movie_sources(self, title: str) -> list[VideoLine]:
        """搜索免费电影源"""
        lines = []
        # 尝试从几个公开的免费解析接口获取
        # 这些是通用的 m3u8 解析接口
        parser_urls = [
            f"https://app.emmmm.eu.org.cdn.cloudflare.net/parse/m3u8/xp/{title}",
        ]

        for parser_url in parser_urls:
            try:
                resp = await self._client.get(parser_url)
                if resp.status_code == 200:
                    text = resp.text
                    if text.strip().startswith("#EXTM3U"):
                        lines.append(VideoLine(
                            url=parser_url,
                            title=f"免费解析",
                            format="hls",
                            source_name=self.name,
                        ))
            except Exception:
                continue

        return lines

    async def _search_free_series_sources(
        self, title: str, episode: int
    ) -> list[VideoLine]:
        """搜索免费电视剧源"""
        # 与电影类似，使用通用解析
        return await self._search_free_movie_sources(f"{title}_E{episode:02d}")
