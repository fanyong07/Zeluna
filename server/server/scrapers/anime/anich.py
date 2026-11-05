"""AniCh 聚合源独立适配器(按需代取,不镜像、不缓存直链)。

职责:把 AniCh 后端的「标题搜索 → 剧集 → 全局集号取流」链路
适配成 Zeluna 的 ``BaseScraper`` 形态。注意两条领域规则:

* 上游 ``episodes[].sort`` 是跨季全局集号(S2 页面里季内第 1 集
  可能是 sort=29);``get_video_urls`` 的 ``episode`` 参数是季内序号,
  用 ``resolve_global_sort`` 做两级对齐;
* 列表元数据不可全信(实测见过 ep 59/12 与大量空值),凡参与回退
  映射的行都必须通过 ``_plausible_episode`` 校验。

线路纯净度参考(排序依据):自建 CDN 官方二压 > 代取流 > 对象存储
转存 > 采集站原始 m3u8。单集可达 58 条线,全量返回;验证预算不应变成展示上限。
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from datetime import datetime, timezone
from typing import Optional
from urllib.parse import urlparse

from ... import config
from ...title_matching import analyze_source_match
from ..base import (
    INVALID_MEDIA_URL,
    PLAYER_PAGE_URL,
    BaseScraper,
    EpisodeInfo,
    SubjectDetail,
    SubjectResult,
    VideoLine,
    classify_media_url,
    media_format_from_url,
)
from . import anich_proto
from . import anich_hosts
from ... import anich_direct
from .anich_proto import decode_variant_base64
from .anich_transport import (
    AniChTransport,
    ANICH_FALLBACK_BASES,
    ANICH_OWN_CDN_HOST_TOKENS,
    anich_detail_path,
    anich_episodes_path,
    anich_latest_path,
    anich_search_path,
    anich_vod_path,
    to_fetch_url,
)

# 画质词按优先级排列(与逆向套件 pick() 同序);label 同时是 quality 字段文本。
_QUALITY_RULES: tuple[tuple[str, str], ...] = (
    (r"官方简中.*?(?:1080P|全高清)", "官方简中·1080P"),
    (r"官方简中", "官方简中"),
    (r"简中", "简中"),
    (r"国语|中文配音", "国语"),
    (r"4K|超清", "4K"),
    (r"1080P|全高清|蓝光", "1080P"),
    (r"720P|高清", "720P"),
)
_QUALITY_REWARD: dict[str, float] = {
    label: float(reward)
    for reward, label in enumerate(
        (label for _, label in reversed(_QUALITY_RULES)), start=1
    )
}
_EPISODE_PREFIX_RE = re.compile(r"^\s*(?:第\s*\d+\s*[话集]|EP?\s*\d+)\s*")
_PAREN_SPLIT_RE = re.compile(r"[()()【】\[\]]")
_LEADING_NUMBER_RE = re.compile(r"^\d+\s*·\s*")
_SEARCH_PAGE_LIMIT = 20
_SEARCH_METADATA_TIMEOUT_SECONDS = 1.8
_OWN_CDN_TOKENS = ANICH_OWN_CDN_HOST_TOKENS

logger = logging.getLogger(__name__)

#: 已在解析队列里的包装地址。同一地址会在多集、多次请求里反复出现,
#: 不去重就会把同一条地址重复排队,出口只有一台小机器,扛不住雪崩。
_RESOLVE_PENDING: set[str] = set()

#: 持有后台任务引用。事件循环对任务只持弱引用,不自己留一份的话任务可能
#: 在执行前就被 GC 掉 —— 表现就是"排了队却什么都没发生"。
_RESOLVE_TASKS: set[asyncio.Task] = set()
_RESOLVE_RETRY_AFTER: dict[str, float] = {}
_RESOLVE_QUEUE_LIMIT = 128
_RESOLVE_RETRY_SECONDS = 300.0
_RESOLVE_BATCH_GATE = asyncio.Semaphore(1)


def _schedule_resolve(wrap_urls: list[str]) -> None:
    """对未解析的自建域地址发起**后台**解析。

    刻意 fire-and-forget:解析要过一次外部出口,慢且可能失败,绝不能挂在
    播放链路上。本次仍交付包装地址兜底(国内网络能直连解出来),解析完成
    后下一次请求就能拿到真实地址。
    """
    now = time.monotonic()
    for url, deadline in list(_RESOLVE_RETRY_AFTER.items()):
        if deadline <= now:
            _RESOLVE_RETRY_AFTER.pop(url, None)
    remaining = max(0, _RESOLVE_QUEUE_LIMIT - len(_RESOLVE_PENDING))
    fresh = [
        url for url in dict.fromkeys(wrap_urls)
        if url not in _RESOLVE_PENDING and url not in _RESOLVE_RETRY_AFTER
    ][:remaining]
    if not fresh:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    _RESOLVE_PENDING.update(fresh)
    task = loop.create_task(_resolve_in_background(fresh))
    _RESOLVE_TASKS.add(task)
    task.add_done_callback(_RESOLVE_TASKS.discard)


async def _resolve_in_background(wrap_urls: list[str]) -> None:
    """后台解析并在完成后让缓存立即生效。"""
    from ... import anich_refresh
    from ...database import async_session

    try:
        async with _RESOLVE_BATCH_GATE:
            async with async_session() as session:
                await anich_refresh.resolve_and_store(session, wrap_urls)
    except Exception as error:  # noqa: BLE001 - 后台补解失败不得影响播放
        logger.debug(
            "后台解析自建地址失败(%d 条): %s", len(wrap_urls), type(error).__name__
        )
    finally:
        _RESOLVE_PENDING.difference_update(wrap_urls)
        deadline = time.monotonic() + _RESOLVE_RETRY_SECONDS
        for url in wrap_urls:
            _RESOLVE_RETRY_AFTER[url] = deadline


async def close_resolver_tasks() -> None:
    tasks = list(_RESOLVE_TASKS)
    for task in tasks:
        task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    _RESOLVE_TASKS.clear()
    _RESOLVE_PENDING.clear()


#: 剧集表缓存时长。实测该请求约 1s,叠加串行节流后每次取流要多等两秒以上;
#  而集数表在一集的生命周期内几乎不变,短期缓存是安全的。
ANICH_EPISODES_CACHE_SECONDS = 900.0


def resolve_global_sort(episodes: list[dict], episode: int) -> Optional[int]:
    """把季内序号映射成上游全局集号。

    1) 精确命中:存在 ``sort == episode`` 且 status=True 的行直接用;
    2) 回退:在可信行里按下标取季内第 N 集(cli 层的历史行为);
    3) 两级都无解返回 None,由调用方产出空线路并交给负缓存兜底。
    """
    target = int(episode)
    if not episodes or target <= 0:
        return None
    for entry in episodes:
        if entry.get("sort") == target and entry.get("status"):
            return target
    valid = [entry for entry in episodes if _plausible_episode(entry)]
    if 1 <= target <= len(valid):
        return int(valid[target - 1].get("sort") or 0) or None
    return None


def _plausible_episode(entry: dict) -> bool:
    """剔除脏元数据行(status=False 或 duration 明显离谱)。"""
    if not entry.get("status"):
        return False
    duration = int(entry.get("duration") or 0)
    return duration == 0 or 60 <= duration <= 7200


def caption_quality(caption: str) -> str:
    text = caption or ""
    for pattern, label in _QUALITY_RULES:
        if re.search(pattern, text):
            return label
    return ""


def line_display_title(caption: str) -> str:
    """「第10集(官方简中-全高清-1080P)」→「官方简中·全高清·1080P」。

    线上多数 caption 是裸集号(``第01集``/``第01话``),这类返回空串,
    由 ``AniChScraper`` 回退成按线路序号命名,避免 UI 出现整排无名线路。
    """
    text = _EPISODE_PREFIX_RE.sub("", (caption or "").strip())
    parts = [part.strip() for part in _PAREN_SPLIT_RE.split(text) if part.strip()]
    merged = "·".join(part.replace("-", "·").replace("×", "·") for part in parts)
    return _LEADING_NUMBER_RE.sub("", merged).strip()


def _is_own_cdn(url: str) -> bool:
    return anich_direct.family_of(url) != anich_direct.AddressFamily.UNKNOWN


def _fetch_url(url: str) -> str:
    """取流前把中转的对外域名换成本机地址。

    实现放在 ``anich_transport.to_fetch_url`` —— 清单**内部**的分片地址由
    ``hls_clean._absolute`` 解析,那里也必须用同一套替换规则,否则线路池里
    的清单地址换了、清单里嵌的分片地址还是公网域名,整条线路照样取不到。
    """
    return to_fetch_url(url)


# 交付形态权重 —— **按实测延迟排序,不按画质**。
#
# 2026-08-28 实测(客户端侧首字节):
#   大厂对象存储(快手/字节)   396~407ms   ← 最快
#   采集站原始 HLS            478ms
#   边缘代取流                1783~3000ms
#   自建 CDN 官方二压         2029~2915ms ← 画质最好但最慢
#
# 大厂 CDN 的边缘节点远强于个人运营的自建 CDN,差距 5~7 倍。画质档
# (官方简中/4K)因此降为**同类内的次级加分**:先让用户快速起播,
# 想要更高画质可以手动切到二压线路(它们仍在列表里)。
_OBJECT_STORE_REWARD = 60.0
_SITE_HLS_REWARD = 45.0
#: 二压与代取流实测延迟接近(2029~2915ms vs 1783~3000ms),给二压略高的
#  底分,使"慢但画质好"的线路不会掉到"同样慢且画质未知"的代取流之后。
_DELIVERY_REWARD = 25.0
_PROXY_REWARD = 20.0
#: 贴片素材的底分。它比自建 CDN 还快,但它是**正片之外的视频**:
#  用户在播放时看到的是广告。给低于任何正片形态的分数,靠前端换线策略
#  兜底;真正的问题在上游数据,这里只保证它不会占据首播位。
_AD_CREATIVE_REWARD = 5.0

#: 大厂对象存储主机族。原表是手写短名单,现由 ``anich_hosts`` 的实测清单
#  统一供数(新增 bytecdn / vzcdn / myqcloud / yximgs 等 8 个族),
#  并保留原表以防清单回退时判据整体失效。
_OBJECT_STORE_TOKENS = (
    "adkwai.com",
    "kwai.net",
    "ibyteimg.com",
    "xiaohongshu.com",
    "scsusercontent.cn",
    "myqcloud.com",
    *anich_hosts.OBJECT_STORE_HOSTS,
)
# 线上混入的转发/过滤入口:脚本端点带 query 参数,不是媒体本体。
# 例:player.91ju.cc/wgart/api.php?action=ad_filter_proxy&video_url=...
_SCRIPT_ENDPOINT_SUFFIXES = (".php", ".asp", ".aspx", ".jsp", ".cgi")


def _is_script_endpoint(url: str) -> bool:
    try:
        parsed = urlparse(url)
    except ValueError:
        return True
    return parsed.path.lower().endswith(_SCRIPT_ENDPOINT_SUFFIXES)


def line_rank(url: str, caption: str) -> float:
    """服务端排序分;分数越高越优先。**主信号是预期延迟,不是画质。**

    判据顺序:先按 ``anich_hosts`` 的实测主机族定性(它对"贴片目录"这类
    路径形状有独立判据,域名级正则区分不了),再退回到本模块的历史
    子串名单,最后才对画质破平。
    """
    host = (urlparse(url).hostname or "").lower()
    lowered = url.lower()
    # 贴片素材优先定性:它与大厂对象存储同域同 CDN,只有路径形状能区分
    if anich_hosts.is_ad_creative(url):
        return _AD_CREATIVE_REWARD
    if any(token in host for token in _OBJECT_STORE_TOKENS):
        score = _OBJECT_STORE_REWARD          # 大厂 CDN,实测最快
    elif any(token in host for token in ANICH_OWN_CDN_HOST_TOKENS):
        # 自建 CDN 的两种形态都偏慢:官方二压目录 vs 边缘代取流
        score = _DELIVERY_REWARD if "vod-cdn" in host else _PROXY_REWARD
    elif anich_hosts.classify(url) is anich_hosts.HostRole.SITE_HLS:
        score = _SITE_HLS_REWARD              # 采集站原始 HLS,实测次快
    elif ".m3u8" in lowered:
        score = _SITE_HLS_REWARD
    else:
        score = _PROXY_REWARD
    # 画质只在同类内破平(想要二压画质仍可手动切,线路都在列表里)
    score += _QUALITY_REWARD.get(caption_quality(caption), 0.0) * 0.5
    if ".m3u8" in lowered:
        score += 2.0
    return score


class AniChScraper(BaseScraper):
    """AniCh 聚合后端 anime-only 只读适配器。"""

    def __init__(
        self,
        *,
        transport=None,
        max_lines: int | None = None,
        episodes_cache_seconds: float | None = None,
        clock=time.monotonic,
    ) -> None:
        super().__init__()
        self._name = "anich"
        self._transport = transport or AniChTransport()
        self._max_lines = max_lines
        self._clock = clock
        self._episodes_ttl = (
            ANICH_EPISODES_CACHE_SECONDS
            if episodes_cache_seconds is None
            else episodes_cache_seconds
        )
        #: bangumi_id → (取回时刻, 剧集表)。集数表在一集的生命周期内几乎不变,
        #  而每次取流都要先拿它:实测该请求本身约 1s,加上串行节流的最小间隔,
        #  不缓存等于给每次播放白加两秒多。
        self._episodes_cache: dict[int, tuple[float, list[dict]]] = {}
        self._details_cache: dict[int, tuple[float, dict]] = {}

    @property
    def content_types(self) -> list[str]:
        return ["anime"]

    @property
    def base_url(self) -> str:
        """诊断用途:当前工作主域或首选候选。"""
        return self._transport.base or ANICH_FALLBACK_BASES[0]

    async def search(self, keyword: str) -> list[SubjectResult]:
        keyword = (keyword or "").strip()
        if not keyword:
            return []
        payload = await self._transport.request(anich_search_path(keyword))
        results = self._list_results(anich_proto.decode_bangumi_list(payload))
        # Search cards may contain only a localized title. Consult a bounded
        # number of detail records for upstream aliases, never loosen identity
        # matching or fetch episode/media payloads just to resolve a title.
        def precise_match(title: str) -> bool:
            analysis = analyze_source_match(
                title, [keyword], candidate_type="anime", expected_type="anime",
                candidate_year=0, expected_year=0,
            )
            return analysis.playback_eligible and (
                analysis.evidence.exact_title or analysis.evidence.safe_title_variant
            )

        # Search ``date`` can be an update/end date (Frieren's card says
        # 2024, while detail.airdate says 2023). Refine ONE precise candidate
        # with authoritative metadata; an exact card beats another season's
        # safe-title variant regardless of upstream ordering. No episodes or
        # media are fetched here, and details share the normal metadata cache.
        precise = [row for row in results if precise_match(row.title)]
        if precise:
            exact = next((row for row in precise if analyze_source_match(
                row.title, [keyword], candidate_type="anime", expected_type="anime",
                candidate_year=0, expected_year=0,
            ).evidence.exact_title), precise[0])
            await self._refine_search_metadata(exact)
            return results
        if results:
            await self._refine_search_metadata(results[0])
        return results

    async def _refine_search_metadata(self, row: SubjectResult) -> bool:
        try:
            # Optional enrichment must not hold already completed search cards
            # until the whole provider deadline expires. The outer search
            # cancellation still propagates; only this small sub-budget falls
            # back to unmodified cards, without launching background requests.
            meta = await asyncio.wait_for(
                self._detail_metadata(int(row.source_id)),
                timeout=_SEARCH_METADATA_TIMEOUT_SECONDS,
            )
        except Exception:
            return False
        identity = analyze_source_match(
            meta["title"], [row.title], candidate_type="anime", expected_type="anime",
            candidate_year=0, expected_year=0,
        )
        if not identity.evidence.allows_circuit_recovery:
            return False
        row.extra["aliases"] = meta["aliases"]
        row.year = meta["year"] or row.year
        return True

    async def get_latest(self, page: int = 1) -> list[SubjectResult]:
        # 只取首页:precache 场景足够,深翻页对该源没有增量价值。
        # 注意 latest 与 search 的 wire 布局不同,必须用专用解码器。
        if page > 1:
            return []
        payload = await self._transport.request(anich_latest_path())
        return self._list_results(anich_proto.decode_latest_list(payload))

    async def get_home(self) -> list[SubjectResult]:
        return []

    async def get_detail(self, source_id: str) -> Optional[SubjectDetail]:
        bangumi_id = _parse_bangumi_id(source_id)
        if bangumi_id is None:
            return None
        meta = await self._detail_metadata(bangumi_id)
        episodes = [
            EpisodeInfo(
                number=index + 1,
                title=(entry.get("title") or f"第{index + 1}集"),
                source_episode_id=str(entry.get("sort") or index + 1),
            )
            for index, entry in enumerate(await self._episodes(bangumi_id))
        ]
        return SubjectDetail(
            source_id=str(bangumi_id),
            title=meta["title"],
            cover_url=meta["cover"],
            summary=meta["summary"],
            type="anime",
            year=meta["year"],
            rating=meta["rating"],
            genres=meta["genres"],
            episodes=episodes,
            extra={"aliases": meta["aliases"]},
        )

    async def get_video_urls(
        self, source_id: str, episode: int = 1
    ) -> list[VideoLine]:
        bangumi_id = _parse_bangumi_id(source_id)
        if bangumi_id is None:
            return []
        global_sort = resolve_global_sort(
            await self._episodes(bangumi_id), int(episode)
        )
        if global_sort is None:
            return []
        vod_payload = await self._transport.request(
            anich_vod_path(bangumi_id, global_sort)
        )
        body = anich_proto.unwrap_vod_body(vod_payload)
        raw_items = anich_proto.decode_vod(body)

        scored: list[tuple[float, int, VideoLine]] = []
        seen_urls: set[tuple[str, str]] = set()
        #: 本轮遇到、但缓存里还没有的自建域地址。函数末尾统一丢给后台补解。
        unresolved_wraps: list[str] = []
        for index, item in enumerate(raw_items):
            try:
                url = decode_variant_base64(item.get("url_raw") or "")
            except ValueError:
                continue
            key = url.lower()
            tag = (item.get("source") or "").strip()
            identity = (tag, url)
            if not key.startswith(("http://", "https://")) or identity in seen_urls:
                continue
            caption = item.get("caption") or ""
            declared_format = "hls" if ".m3u8" in key else ""
            # 拒绝明确的非媒体入口:embed/player 页与脚本转发端点。
            # 自建 CDN 的无扩展名直链保持 unknown,交由服务端内容嗅探,
            # 不在此提前否决(实测头部线路全部是这种形态)。
            if _is_script_endpoint(url) or classify_media_url(
                url, declared_format
            ) in {INVALID_MEDIA_URL, PLAYER_PAGE_URL}:
                continue
            seen_urls.add(identity)
            # 每条线路必须有独立身份:客户端按 providerId|sourceName 折叠卡片,
            # 共用一个名字会把数十条压成一张卡。直接用上游的线路标识
            # (hb-10/jk-18/xk-12…)作展示名:天然唯一,且不暴露聚合源名称。
            # 上游给的线路标识(hb-10 / jk-18 / xk-12…)。直接作为该线路的
            # 来源名:它天然唯一,且不暴露聚合服务本身的名字。
            # 自建域地址是 302 包装层,而本部署出口被它按 IP 封禁
            # (Cloudflare Error 1006),原样交给客户端只会得到 403。
            # 已解析且首字节探活通过时优先交付真实地址;不同客户端网络
            # 仍可能得到不同结果,缓存命中不代表整片已验证。
            delivery_url = url
            if _is_own_cdn(url):
                resolved = anich_direct.lookup(url)
                if resolved:
                    delivery_url = resolved
                else:
                    unresolved_wraps.append(url)
            scored.append(
                (
                    line_rank(delivery_url, caption),
                    index,
                    VideoLine(
                        url=_fetch_url(delivery_url),
                        title=line_display_title(caption),
                        quality=caption_quality(caption),
                        format=(media_format_from_url(delivery_url) if delivery_url != url else declared_format),
                        headers={},
                        source_name=tag or f"line-{index + 1}",
                    ),
                )
            )
        scored.sort(key=lambda entry: (-entry[0], entry[1]))
        lines = [line for _, _, line in scored]
        seen_names: dict[str, int] = {}
        for position, line in enumerate(lines, 1):
            if not line.title:
                line.title = f"线路{position}"
            # 同一线路标识可能出现多次(不同画质档),补序号保证展示身份唯一
            count = seen_names.get(line.source_name, 0) + 1
            seen_names[line.source_name] = count
            if count > 1:
                line.source_name = f"{line.source_name}-{count}"
        # 先返回、后补解:播放不被解析拖慢,缓存在下一次请求生效。
        _schedule_resolve(unresolved_wraps)
        return lines

    async def _episodes(self, bangumi_id: int) -> list[dict]:
        """取剧集表,带短期缓存。

        取流必须先拿这张表,而它本身约 1s、还要占一次串行节流额度。
        集数表在一集的生命周期内几乎不变,因此短期缓存不会导致集号错位。
        """
        cached = self._episodes_cache.get(bangumi_id)
        if cached is not None and (self._clock() - cached[0]) < self._episodes_ttl:
            return cached[1]
        payload = await self._transport.request(anich_episodes_path(bangumi_id))
        episodes = anich_proto.decode_episodes(payload)
        if episodes:
            self._episodes_cache[bangumi_id] = (self._clock(), episodes)
        return episodes

    async def _detail_metadata(self, bangumi_id: int) -> dict:
        cached = self._details_cache.get(bangumi_id)
        if cached is not None and self._clock() - cached[0] < self._episodes_ttl:
            return cached[1]
        payload = await self._transport.request(anich_detail_path(bangumi_id))
        meta = _detail_meta(payload, bangumi_id)
        if len(self._details_cache) >= 256:
            self._details_cache.pop(next(iter(self._details_cache)))
        self._details_cache[bangumi_id] = (self._clock(), meta)
        return meta

    async def aclose(self) -> None:
        close = getattr(self._transport, "aclose", None)
        if callable(close):
            await close()

    # ── 内部 ────────────────────────────────────────────────
    def _effective_max_lines(self) -> int:
        """保留给测试与诊断:线路本身全量返回,此值只表达"建议优先验证的条数"。"""
        if self._max_lines is not None:
            return max(1, int(self._max_lines))
        from ... import config

        return max(1, int(config.ANICH_MAX_LINES_PER_EPISODE))

    @staticmethod
    def _list_results(entries: list[dict]) -> list[SubjectResult]:
        results: list[SubjectResult] = []
        seen_ids: set[int] = set()
        for entry in entries:
            bangumi_id = entry.get("id")
            title = (entry.get("title") or "").strip()
            if not bangumi_id or not title or bangumi_id in seen_ids:
                continue
            seen_ids.add(int(bangumi_id))
            if len(results) >= _SEARCH_PAGE_LIMIT:
                break
            year = _year_from_epoch(entry.get("date"))
            status_text = (entry.get("status") or "").lower()
            results.append(
                SubjectResult(
                    source_id=str(int(bangumi_id)),
                    title=title,
                    cover_url=entry.get("image") or "",
                    summary=(entry.get("tagline") or "")[:160],
                    type="anime",
                    year=year,
                    episode_count=int(entry.get("episodes_total") or 0),
                    latest_episode=int(entry.get("episode") or 0),
                    status=1 if status_text in {"finale", "released"} else 0,
                )
            )
        return results


# ── 模块级工具 ────────────────────────────────────────────────
def _title_aliases(titles: object) -> list[str]:
    values = titles.values() if isinstance(titles, dict) else titles
    if not isinstance(values, (list, tuple)) and not isinstance(titles, dict):
        return []
    return list(dict.fromkeys(
        value.strip() for value in values
        if isinstance(value, str) and 0 < len(value.strip()) <= 300
    ))[:20]


def _first_alias(titles: object) -> str:
    """``titles`` 线上是数组(历史资料里出现过 dict 形态,两者都兼容)。"""
    if isinstance(titles, list):
        candidates = titles
    elif isinstance(titles, dict):
        candidates = list(titles.values())
    else:
        return ""
    for candidate in candidates:
        text = str(candidate or "").strip()
        if text:
            return text
    return ""


def _year_from_epoch(value: object) -> int:
    """上游 ``date`` 是毫秒级 double(线上实测 1774540800000.0)。

    量纲自适应而非硬除 1000:秒级与毫秒级都能解析,越界值一律退化为 0
    (年份只作匹配加分用,拿不到不影响播放)。
    """
    try:
        raw = float(value or 0.0)
    except (TypeError, ValueError):
        return 0
    if raw <= 0:
        return 0
    # 按量级判定而不是逐个试除:任何现代日期的毫秒时间戳都 > 1e11,
    # 而秒级时间戳要到公元 5138 年才会达到该量级。这样秒级输入不会
    # 被误除成 1970,毫秒级也不会被当成公元 58202 年。
    seconds = raw / 1000.0 if raw > 1e11 else raw
    try:
        year = datetime.fromtimestamp(seconds, tz=timezone.utc).year
    except (ValueError, OSError, OverflowError):
        return 0
    return year if 1900 <= year <= 2200 else 0


def _parse_bangumi_id(source_id: str) -> Optional[int]:
    try:
        value = int(str(source_id).strip())
    except ValueError:
        return None
    return value if value > 0 else None


def _detail_meta(payload: bytes, fallback_title_hint: int) -> dict:
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    title = str(data.get("title") or "").strip()
    if not title:
        title = _first_alias(data.get("titles"))
    # 线上实测 airdate 同样是毫秒时间戳(1768492800000),不是 "2024-01" 文本
    year = _year_from_epoch(data.get("airdate"))
    scores = data.get("rating")
    values = []
    if isinstance(scores, list):
        values = [
            float(site.get("score"))
            for site in scores
            if isinstance(site, dict) and isinstance(site.get("score"), (int, float))
        ]
    genres = [str(genre) for genre in (data.get("genres") or []) if genre]
    return {
        "title": title or f"bangumi-{fallback_title_hint}",
        "aliases": _title_aliases(data.get("titles")),
        "cover": str(data.get("image") or ""),
        "summary": str(data.get("overview") or "")[:400],
        "year": year,
        "rating": round(sum(values) / len(values), 2) if values else 0.0,
        "genres": genres,
    }
