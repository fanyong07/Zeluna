"""
统一聚合层

整合所有视频源（AniCh API + TVBox + TVMaze + TMDB + M3U8解析），
提供统一的搜索、详情和视频源获取接口。

所有内容仅存储元数据和 URL，不存储视频文件。
"""

import json
import time
import logging
import asyncio
import ipaddress
import socket
from typing import Optional
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlparse

import httpx

from .m3u8_resolver import resolver as m3u8_resolver
from .scrapers.maccms import MacCmsScraper
from .scrapers.maccms_sites import site_priority
from .scrapers.tvbox_adapter import TvBoxAdapterScraper
from .scrapers.series.vod_common import CommonVodScraper
from .config import SOURCE_MAX_CONCURRENCY

logger = logging.getLogger(__name__)


def _normalized_match_title(value: str) -> str:
    import re

    cleaned = (value or "").casefold()
    cleaned = re.sub(r"第\s*\d+\s*[季部期]", "", cleaned)
    cleaned = re.sub(r"\bseason\s*\d+\b", "", cleaned)
    return "".join(char for char in cleaned if char.isalnum())


def _source_match_score(
    candidate: str,
    aliases: list[str],
    *,
    candidate_type: str,
    expected_type: str,
    candidate_year: int,
    expected_year: int,
) -> int:
    normalized = _normalized_match_title(candidate)
    targets = [_normalized_match_title(alias) for alias in aliases]
    score = 0
    for target in targets:
        if not target:
            continue
        if normalized == target:
            score = max(score, 100)
        elif min(len(normalized), len(target)) >= 4 and (
            normalized in target or target in normalized
        ):
            score = max(score, 72)
    if expected_type and candidate_type:
        normalized_expected = "tv" if expected_type == "series" else expected_type
        score += 8 if candidate_type == normalized_expected else -25
    if expected_year and candidate_year:
        distance = abs(expected_year - candidate_year)
        score += 10 if distance == 0 else (4 if distance == 1 else -12)
    return score


def _is_public_ip(value: str) -> bool:
    try:
        return ipaddress.ip_address(value).is_global
    except ValueError:
        return False


async def _is_public_http_url(url: str) -> bool:
    """Reject local/private destinations before the backend probes a line."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return False
    host = parsed.hostname.strip().lower()
    if host == "localhost" or host.endswith(".localhost"):
        return False
    try:
        ipaddress.ip_address(host)
    except ValueError:
        loop = asyncio.get_running_loop()
        try:
            addresses = await loop.run_in_executor(
                None,
                lambda: socket.getaddrinfo(
                    host,
                    parsed.port or (443 if parsed.scheme == "https" else 80),
                    type=socket.SOCK_STREAM,
                ),
            )
        except OSError:
            return False
        resolved = {item[4][0] for item in addresses if item[4]}
        return bool(resolved) and all(_is_public_ip(item) for item in resolved)
    return _is_public_ip(host)


@dataclass
class AggregatedSubject:
    """聚合后的条目"""
    id: str                    # 前端展示用 ID
    title: str
    original_title: str = ""
    cover_url: str = ""
    banner_url: str = ""
    summary: str = ""
    content_type: str = "tv"
    language: str = ""
    year: int = 2024
    regions: list[str] = field(default_factory=list)
    genres: list[str] = field(default_factory=list)
    rating: float = 0.0
    rating_count: int = 0
    total_episodes: int = 0
    status: str = ""
    sources: list[str] = field(default_factory=list)
    # 内部使用：保存原始 source_id 以便后续获取视频
    _source_refs: dict = field(default_factory=dict)


@dataclass
class AggregatedEpisode:
    """聚合后的剧集"""
    number: int
    title: str = ""
    thumbnail: str = ""
    duration: str = ""


@dataclass
class AggregatedVideoLine:
    """聚合后的视频线路"""
    url: str
    title: str = ""
    quality: str = ""
    format: str = ""           # hls, mp4
    source: str = ""           # 来源标识
    headers: dict = field(default_factory=dict)


@dataclass
class SourceMatch:
    source_id: str
    source_name: str
    title: str
    content_type: str
    year: int
    episode_count: int = 0
    score: int = 0


class ContentAggregator:
    """
    内容聚合器

    统一搜索入口，自动从多个源聚合结果:
      - anime:  AniCh API + TVBox + M3U8解析
      - series: TVMaze + TVBox + M3U8解析
      - movie:  TMDB + TVBox + M3U8解析
    """

    def __init__(self, *, line_http_transport: httpx.AsyncBaseTransport | None = None):
        self._maccms = MacCmsScraper()
        self._tvbox = TvBoxAdapterScraper()
        self._vod = CommonVodScraper()
        self._anich_client = None  # lazy init (可选外部 AniCh 客户端)
        self._line_http_transport = line_http_transport

    async def _get_anich_client(self):
        """
        延迟加载可选的 AniCh 外部客户端。

        通过环境变量 ANICH_PIPELINE_PATH 指定 extracted_pipeline 目录。
        未配置或加载失败时返回 None (优雅降级) —— 动漫源改走 MacCMS。
        VPS 部署通常不配置此项。
        """
        if self._anich_client is None:
            import os
            pipeline_path = os.environ.get("ANICH_PIPELINE_PATH", "").strip()
            if not pipeline_path:
                self._anich_client = False
                return None
            try:
                import sys
                if pipeline_path not in sys.path:
                    sys.path.insert(0, pipeline_path)
                from anich_client import AniChConfig, AniChClient
                config = AniChConfig.discover()
                self._anich_client = AniChClient(config)
            except Exception as e:
                logger.warning(f"AniCh client init failed: {e}")
                self._anich_client = False
        return self._anich_client if self._anich_client is not False else None

    async def aclose(self) -> None:
        await asyncio.gather(
            self._maccms.aclose(),
            self._tvbox.aclose(),
            self._vod.aclose(),
            return_exceptions=True,
        )

    async def discover_source_matches(
        self,
        aliases: list[str],
        *,
        content_type: str = "",
        year: int = 0,
        max_matches: int = 12,
    ) -> list[SourceMatch]:
        """把稳定元数据条目绑定到各采集站，不把采集站 ID 暴露给客户端。"""
        clean_aliases = []
        seen_aliases = set()
        for value in aliases:
            value = (value or "").strip()
            key = _normalized_match_title(value)
            if value and key and key not in seen_aliases:
                seen_aliases.add(key)
                clean_aliases.append(value)
        if not clean_aliases:
            return []

        matches: dict[str, SourceMatch] = {}
        # 中文标题、原名、常见别名最多取三个；逐个查询可控制 1C2G VPS 峰值。
        for alias in clean_aliases[:3]:
            try:
                results = await self._maccms.search(alias)
            except Exception as error:
                logger.warning("Source discovery failed: %s", type(error).__name__)
                continue
            for result in results:
                score = _source_match_score(
                    result.title,
                    clean_aliases,
                    candidate_type=result.type,
                    expected_type=content_type,
                    candidate_year=result.year,
                    expected_year=year,
                )
                if score < 65:
                    continue
                parts = result.source_id.split(":", 2)
                source_name = parts[1] if len(parts) == 3 else "maccms"
                candidate = SourceMatch(
                    source_id=result.source_id,
                    source_name=source_name,
                    title=result.title,
                    content_type=result.type,
                    year=result.year,
                    score=score + site_priority(source_name) // 10,
                )
                previous = matches.get(result.source_id)
                if previous is None or candidate.score > previous.score:
                    matches[result.source_id] = candidate

        # 同一站点只保留匹配度最高的一项，避免错季或同名版本刷屏。
        by_site: dict[str, SourceMatch] = {}
        for match in matches.values():
            previous = by_site.get(match.source_name)
            if previous is None or match.score > previous.score:
                by_site[match.source_name] = match
        return sorted(
            by_site.values(),
            key=lambda item: item.score,
            reverse=True,
        )[:max_matches]

    async def resolve_source_matches(
        self,
        matches: list[SourceMatch],
        *,
        episode: int,
        verify: bool = True,
    ) -> tuple[list[AggregatedVideoLine], dict[str, bool]]:
        """低并发解析多站线路，并返回每个站点本轮健康结果。"""
        semaphore = asyncio.Semaphore(SOURCE_MAX_CONCURRENCY)

        async def resolve_one(match: SourceMatch):
            async with semaphore:
                lines = await self.get_video_urls(match.source_id, episode)
                if verify and lines:
                    checks = await asyncio.gather(
                        *(self._line_reachable(line) for line in lines),
                        return_exceptions=True,
                    )
                    lines = [
                        line for line, ok in zip(lines, checks) if ok is True
                    ]
                return match, lines

        groups = await asyncio.gather(
            *(resolve_one(match) for match in matches),
            return_exceptions=True,
        )
        health: dict[str, bool] = {}
        unique: dict[str, AggregatedVideoLine] = {}
        for group in groups:
            if isinstance(group, Exception):
                continue
            match, lines = group
            health[match.source_name] = bool(lines)
            for line in lines:
                unique.setdefault(line.url, line)
        return list(unique.values()), health

    async def search(
        self,
        keyword: str,
        content_types: list[str] = None,
        max_results: int = 30,
    ) -> list[AggregatedSubject]:
        """
        统一搜索。

        Args:
            keyword: 搜索关键词
            content_types: 内容类型过滤，如 ["anime", "tv", "movie"]
            max_results: 最大结果数
        """
        if content_types is None:
            content_types = ["anime", "tv", "movie"]

        all_results: list[AggregatedSubject] = []
        seen_titles: set[str] = set()

        async def add_results(source_label: str, subjects: list, type_override: str = None,
                              orig_ids: list = None):
            for idx, s in enumerate(subjects):
                title = s.get("title", "") if isinstance(s, dict) else (
                    s.title if hasattr(s, 'title') else str(s)
                )
                # 保存原始 source_id
                orig_id = ""
                if orig_ids and idx < len(orig_ids):
                    orig_id = orig_ids[idx]
                elif isinstance(s, dict):
                    orig_id = s.get("source_id", s.get("id", ""))
                else:
                    orig_id = getattr(s, 'source_id', '')

                title_lower = title.strip().lower()
                # MacCMS 同一标题的不同站点代表不同播放线路，不能在排序前
                # 以统一的 "maccms:标题" 去重，否则后返回的稳定站会消失。
                dedup_key = (
                    orig_id.strip().lower()
                    if orig_id and orig_id.startswith("maccms:")
                    else f"{source_label}:{title_lower}"
                )
                if dedup_key in seen_titles:
                    continue
                seen_titles.add(dedup_key)

                ct = type_override or (
                    s.get("type", "tv") if isinstance(s, dict)
                    else getattr(s, 'type', 'tv')
                )

                # 若 orig_id 已是带源前缀的完整可反查 ID (maccms:/tvbox:/intl:),
                # 直接用它作为对外 id, 使 /api/v2/vod 能据此反查线路。
                # 否则退回 display hash (仅用于展示)。
                if orig_id and orig_id.split(":", 1)[0] in ("maccms", "tvbox", "intl", "anich"):
                    display_id = orig_id
                else:
                    display_id = f"{source_label}:{abs(hash(title_lower)) % 10**10}"

                all_results.append(AggregatedSubject(
                    id=display_id,
                    title=title,
                    cover_url=s.get("cover_url", "") if isinstance(s, dict) else getattr(s, 'cover_url', ''),
                    summary=s.get("summary", "") if isinstance(s, dict) else getattr(s, 'summary', ''),
                    content_type=ct,
                    language=s.get("lang", "") if isinstance(s, dict) else getattr(s, 'lang', ''),
                    year=s.get("year", 2024) if isinstance(s, dict) else getattr(s, 'year', 2024),
                    sources=[source_label],
                    _source_refs={source_label: orig_id},
                ))

        # 并行搜索所有源
        tasks = []

        # 0. MacCMS 多站聚合 (主力源: 国内外电影/剧/番/综艺)
        async def search_maccms():
            try:
                results = await self._maccms.search(keyword)
                limit = max(60, max_results * 6)
                selected = results[:limit]
                await add_results("maccms", [
                    {"title": r.title, "cover_url": r.cover_url,
                     "type": r.type, "lang": r.lang,
                     "year": r.year, "summary": r.summary}
                    for r in selected
                ],
                orig_ids=[r.source_id for r in selected])
            except Exception as e:
                logger.warning(f"MacCMS search failed: {e}")
        tasks.append(search_maccms())

        # 1. AniCh (动漫, 可选外部客户端)
        if "anime" in content_types:
            async def search_anich():
                client = await self._get_anich_client()
                if not client:
                    return
                try:
                    results = client.search(keyword)
                    await add_results("anich", [
                        {"title": r["title"], "cover_url": r.get("image", ""),
                         "type": "anime", "lang": "ja",
                         "year": 2024, "summary": r.get("tagline", "")}
                        for r in results[:10]
                    ], "anime",
                    orig_ids=[str(r["id"]) for r in results[:10]])
                except Exception as e:
                    logger.warning(f"AniCh search failed: {e}")
            tasks.append(search_anich())

        # 2. TVBox (国产剧+电影+动漫)
        if any(ct in content_types for ct in ["tv", "movie", "anime"]):
            async def search_tvbox():
                try:
                    results = await self._tvbox.search(keyword)
                    await add_results("tvbox", [
                        {"title": r.title, "cover_url": r.cover_url,
                         "type": r.type, "lang": r.lang,
                         "year": r.year, "summary": r.summary}
                        for r in results[:10]
                    ],
                    orig_ids=[r.source_id for r in results[:10]])
                except Exception as e:
                    logger.warning(f"TVBox search failed: {e}")
            tasks.append(search_tvbox())

        # 3. TVMaze + TMDB (美剧/英剧/电影)
        if any(ct in content_types for ct in ["tv", "movie"]):
            async def search_intl():
                try:
                    results = await self._vod.search(keyword)
                    await add_results("intl", [
                        {"title": r.title, "cover_url": r.cover_url,
                         "type": r.type, "lang": r.lang,
                         "year": r.year, "summary": r.summary}
                        for r in results[:10]
                    ],
                    orig_ids=[r.source_id for r in results[:10]])
                except Exception as e:
                    logger.warning(f"International search failed: {e}")
            tasks.append(search_intl())

        # 等待所有搜索完成
        await asyncio.gather(*tasks, return_exceptions=True)

        # 排序: 活源站优先 (经验上 CDN 稳定的站排前), 再按评分
        # MacCMS 各站可靠度差异大, 把已知自带新鲜 CDN 的站顶到前面,
        # 死链率高的聚合站沉底, 这样客户端优先命中能播的线路。
        def _site_of(x):
            xid = getattr(x, "id", "") or ""
            if xid.startswith("maccms:"):
                p = xid.split(":")
                if len(p) >= 2:
                    return p[1]
            return xid.split(":", 1)[0] if ":" in xid else "other"

        def _rank(x):
            return (site_priority(_site_of(x)), x.rating)

        all_results.sort(key=_rank, reverse=True)

        # 每站限额轮转: 避免单个站(如暴风)刷屏, 保证活源站(iKun/魔都)也进结果。
        from collections import defaultdict
        per_site = defaultdict(list)
        for r in all_results:
            per_site[_site_of(r)].append(r)
        # 按站权重高→低轮流取, 每轮每站取一个
        ordered_sites = sorted(per_site.keys(),
                               key=site_priority, reverse=True)
        interleaved = []
        idx = 0
        while len(interleaved) < max_results:
            added = False
            for s in ordered_sites:
                if idx < len(per_site[s]):
                    interleaved.append(per_site[s][idx])
                    added = True
                    if len(interleaved) >= max_results:
                        break
            if not added:
                break
            idx += 1
        return interleaved

    async def get_episodes(self, subject_id: str) -> list[AggregatedEpisode]:
        """获取剧集列表。subject_id 支持两种格式：源ID 或 搜索结果的 display ID"""
        # 如果是搜索结果返回的 display ID，从缓存中查找
        # 否则直接解析 source:original_id 格式
        source, sid = subject_id.split(":", 1) if ":" in subject_id else ("unknown", subject_id)

        if source == "maccms":
            # subject_id 形如 maccms:站名:vod_id
            detail = await self._maccms.get_detail(subject_id)
            if detail:
                return [
                    AggregatedEpisode(number=ep.number, title=ep.title)
                    for ep in detail.episodes
                ]
            return []

        if source == "anich":
            client = await self._get_anich_client()
            if client:
                try:
                    eps = client.get_episodes(int(sid))
                    return [
                        AggregatedEpisode(
                            number=ep.get("sort", i + 1),
                            title=ep.get("title", f"第{i+1}集"),
                        )
                        for i, ep in enumerate(eps)
                    ]
                except Exception:
                    pass

        elif source == "tvbox":
            # sid 可能是 display hash, 也可能是 tvbox:源名:vod_id 格式
            # 尝试直接作为 source_id 使用
            lookup_id = subject_id
            if not subject_id.startswith("tvbox:"):
                # display ID - 无法精确获取，返回空
                return []
            detail = await self._tvbox.get_detail(lookup_id)
            if detail:
                return [
                    AggregatedEpisode(number=ep.number, title=ep.title)
                    for ep in detail.episodes
                ]

        elif source == "intl":
            if not subject_id.startswith("intl:"):
                return []
            detail = await self._vod.get_detail(subject_id.replace("intl:", "", 1))
            if detail:
                return [
                    AggregatedEpisode(number=ep.number, title=ep.title)
                    for ep in detail.episodes
                ]

        return []

    async def get_video_urls(
        self, subject_id: str, episode: int = 1, title_hint: str = ""
    ) -> list[AggregatedVideoLine]:
        """
        获取视频播放地址（多条线路）。

        subject_id 格式:
          - anich:12345 → AniCh API
          - tvbox:暴风:47131 → TVBox 源
          - intl:tvmaze_123 → 国际源
        """
        all_lines: list[AggregatedVideoLine] = []

        if subject_id.startswith("maccms:"):
            lines = await self._maccms.get_video_urls(subject_id, episode)
            for l in lines:
                all_lines.append(AggregatedVideoLine(
                    url=l.url, title=l.title,
                    format=l.format, source=l.source_name,
                ))

        elif subject_id.startswith("anich:"):
            sid = subject_id.split(":", 1)[1]
            try:
                bid = int(sid) if sid.isdigit() else int(sid) if sid.lstrip('-').isdigit() else None
            except ValueError:
                bid = None

            if bid:
                client = await self._get_anich_client()
                if client:
                    try:
                        sources = client.get_video_sources(bid, episode)
                        for s in sources:
                            url = s.get("decoded_url", "")
                            if url:
                                all_lines.append(AggregatedVideoLine(
                                    url=url,
                                    title=s.get("caption", ""),
                                    format=s.get("type", "auto"),
                                    source="anich",
                                ))
                    except Exception as e:
                        logger.error(f"AniCh VOD error: {e}")

        elif subject_id.startswith("tvbox:"):
            lines = await self._tvbox.get_video_urls(subject_id, episode)
            for l in lines:
                all_lines.append(AggregatedVideoLine(
                    url=l.url, title=l.title,
                    format=l.format, source=f"tvbox:{l.source_name}",
                ))

        elif subject_id.startswith("intl:"):
            real_id = subject_id.replace("intl:", "", 1)
            lines = await self._vod.get_video_urls(real_id, episode)
            for l in lines:
                all_lines.append(AggregatedVideoLine(
                    url=l.url, title=l.title,
                    format=l.format, source=f"intl:{l.source_name}",
                ))

        # M3U8 fallback for under-served results
        if len(all_lines) < 3 and title_hint:
            try:
                extra_urls = await m3u8_resolver.search_and_resolve(title_hint)
                for u in extra_urls[:10]:
                    all_lines.append(AggregatedVideoLine(
                        url=u["url"],
                        title=f"M3U8:{u.get('source', 'unknown')}",
                        format=u.get("format", "hls"),
                        source=f"m3u8:{u.get('source', 'unknown')}",
                    ))
            except Exception as e:
                logger.warning(f"M3U8 fallback error: {e}")

        # 去重
        seen = set()
        unique = []
        for line in all_lines:
            if line.url not in seen:
                seen.add(line.url)
                unique.append(line)
        return unique

    async def _line_reachable(self, line: "AggregatedVideoLine") -> bool:
        """
        校验一条线路是否真能播:
          - m3u8: GET 前若干字节, 必须是 #EXTM3U 或 mpegurl content-type
          - mp4/其它: HEAD 或 GET, 状态码 < 400 且非 HTML
        """
        url = line.url
        if not url.lower().startswith(("http://", "https://")):
            return False
        headers = {"User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"
        ), "Accept": "application/vnd.apple.mpegurl,video/*,*/*;q=0.8",
           "Range": "bytes=0-65535"}
        try:
            async with httpx.AsyncClient(
                follow_redirects=False,
                timeout=httpx.Timeout(8, connect=5),
                headers=headers,
                transport=self._line_http_transport,
            ) as c:
                current = url
                for _ in range(6):
                    if not await _is_public_http_url(current):
                        return False
                    async with c.stream("GET", current) as resp:
                        if resp.status_code in (301, 302, 303, 307, 308):
                            location = resp.headers.get("location", "").strip()
                            if not location:
                                return False
                            current = urljoin(str(resp.url), location)
                            continue
                        if resp.status_code >= 400:
                            return False
                        ct = resp.headers.get("content-type", "").lower()
                        body = bytearray()
                        async for chunk in resp.aiter_bytes():
                            remaining = 65536 - len(body)
                            if remaining <= 0:
                                break
                            body.extend(chunk[:remaining])
                            if len(body) >= 65536:
                                break
                        body_head = bytes(body[:512]).decode(
                            "utf-8", errors="ignore"
                        ).lstrip()
                        is_hls = "m3u8" in current.lower() or line.format == "hls"
                        if is_hls:
                            if body_head.startswith("#EXTM3U"):
                                return True
                            if "text/html" in ct or body_head.lower().startswith("<html"):
                                return False
                            return "mpegurl" in ct or "octet-stream" in ct
                        if "text/html" in ct or body_head.lower().startswith("<html"):
                            return False
                        return resp.status_code in (200, 206)
                return False
        except Exception:
            return False

    async def resolve_verified_lines(
        self, subject_id: str, episode: int = 1, title_hint: str = "",
        verify: bool = True,
    ) -> list["AggregatedVideoLine"]:
        """
        解析播放线路, 并(可选)只保留通过可达性验证的。
        预爬缓存和 /api/v2/vod 都调用它。
        """
        lines = await self.get_video_urls(subject_id, episode, title_hint)
        if not verify or not lines:
            return lines
        checks = await asyncio.gather(
            *[self._line_reachable(l) for l in lines],
            return_exceptions=True,
        )
        alive = [
            l for l, ok in zip(lines, checks)
            if ok is True
        ]
        return alive

    async def get_home_feed(self) -> dict:
        """获取首页推荐 (各类型混合)"""
        result = {
            "anime_trending": [],
            "series_trending": [],
            "movies_trending": [],
        }

        # 从 AniCh 获取动漫推荐
        client = await self._get_anich_client()
        if client:
            try:
                resp = client._request("GET", "/bangumi/recommend")
                if resp.status_code == 200:
                    data = resp.json()
                    carousel = data.get("carousel", [])
                    for item in carousel[:10]:
                        result["anime_trending"].append({
                            "id": f"anich:{item['id']}",
                            "title": item.get("title", ""),
                            "cover_url": item.get("image", ""),
                            "type": "anime",
                            "summary": item.get("overview", ""),
                        })
            except Exception:
                pass

        # 从 TVBox 获取最新
        try:
            latest = await self._tvbox.get_latest(page=1)
            for item in latest[:20]:
                entry = {
                    "id": item.source_id,
                    "title": item.title,
                    "cover_url": item.cover_url,
                    "type": item.type,
                }
                if item.type == "movie":
                    result["movies_trending"].append(entry)
                else:
                    result["series_trending"].append(entry)
        except Exception:
            pass

        return result


# 全局聚合器实例
aggregator = ContentAggregator()
