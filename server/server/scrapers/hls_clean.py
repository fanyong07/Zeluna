"""HLS 清单广告剪裁(纯文本重写,不落盘、不代理媒体字节)。

采集站的 m3u8 里常插贴片广告分片。广告分片的可观察特征:
  * 时长明显短于正片(典型正片 6~10s,广告 1~3s),且成簇出现;
  * 常被 ``#EXT-X-DISCONTINUITY`` 与正片隔开;
  * 有时来自与正片不同的 CDN 主机。

两级剪裁:
  A. 组级——以 DISCONTINUITY 切组,整组符合"短分片簇/首尾小簇/异域分片"即丢;
  B. 组内条目级——仅当**连续 ≥2 条**短分片成簇才丢。孤立短分片多为正常
     收尾或换轨,宁可漏剪也不误删正片。

必守约束(顺序或标签写错会导致完全无法播放):
  * ``#EXT-X-KEY`` 必须保留,且其 ``URI=`` 要转成绝对地址(含段间 KEY 轮换);
  * ``#EXT-X-ENDLIST`` 只能出现在所有媒体段之后;
  * 主清单(master)先选一路 variant,再对其媒体清单剪裁;
  * mp4 等非清单源无法按分片剪,只能换线。
"""

from __future__ import annotations

import asyncio
import re
from collections.abc import Awaitable, Callable
import statistics
from dataclasses import dataclass, field
from typing import TYPE_CHECKING
from urllib.parse import urljoin, urlparse

from .anime.anich_transport import to_fetch_url

import httpx

from ..public_http import is_public_http_url
from .ad_signals import AdSignals, analyze_manifest

#: 组级判据:短分片簇的时长上限 = max(此值, 全局中位数/3)
_MIN_SHORT_THRESHOLD_SECONDS = 2.0
#: 首尾小簇判据:总时长上限,且中位数须低于全局中位数的此比例
_EDGE_CLUSTER_MAX_SECONDS = 60.0
_EDGE_CLUSTER_MEDIAN_RATIO = 0.7
#: 异域分片判据:占比低于此值的主机视为可疑
_ODD_HOST_MAX_SHARE = 0.05
_ODD_HOST_MIN_COUNT = 2

_URI_ATTR_RE = re.compile(r'URI="([^"]+)"')


@dataclass
class CutReport:
    """剪裁报告(只含统计,不含媒体地址)。"""

    groups_cut: int = 0
    segments_cut: int = 0
    seconds_cut: float = 0.0
    segments_kept: int = 0
    micro_cut: int = 0
    reasons: list[str] = field(default_factory=list)

    @property
    def changed(self) -> bool:
        return bool(self.segments_cut or self.micro_cut)

    def as_public_dict(self) -> dict:
        return {
            "groups_cut": self.groups_cut,
            "segments_cut": self.segments_cut,
            "seconds_cut": round(self.seconds_cut, 1),
            "segments_kept": self.segments_kept,
            "micro_cut": self.micro_cut,
            "reasons": list(self.reasons[:8]),
        }


def _absolute(base_url: str, uri: str) -> str:
    """把清单里的 URI 解析成面向客户端的公网绝对地址。

    注意：绝不可调用 ``to_fetch_url`` 把输出清单里的分片改写为本机回环地址，
    否则手机/桌面客户端拿到清单后无法访问服务端 127.0.0.1。
    """
    return uri if (not base_url or uri.startswith(("http://", "https://"))) \
        else urljoin(base_url, uri)


def _rewrite_uri_attr(tag: str, base_url: str) -> str:
    """把标签里的 ``URI="..."`` 转绝对(KEY/MAP 都需要)。"""
    if not base_url or 'URI="' not in tag:
        return tag
    return _URI_ATTR_RE.sub(
        lambda m: 'URI="%s"' % _absolute(base_url, m.group(1)), tag
    )


def is_master_playlist(text: str) -> bool:
    return "#EXT-X-STREAM-INF" in (text or "")


def pick_variant(master_text: str, master_url: str) -> str | None:
    """从主清单里挑一路 variant(取带宽最高者)。"""
    best_bandwidth, best_uri = -1, None
    lines = [line.strip() for line in (master_text or "").splitlines()]
    for index, line in enumerate(lines):
        if not line.upper().startswith("#EXT-X-STREAM-INF"):
            continue
        match = re.search(r"BANDWIDTH=(\d+)", line, re.I)
        bandwidth = int(match.group(1)) if match else 0
        for candidate in lines[index + 1:]:
            if candidate and not candidate.startswith("#"):
                if bandwidth > best_bandwidth:
                    best_bandwidth, best_uri = bandwidth, candidate
                break
    return _absolute(master_url, best_uri) if best_uri else None


def _parse(text: str) -> tuple[list[str], list[list[dict]], bool]:
    """→ (header_lines, groups, has_endlist);group = [entry]。

    每条 entry 额外带 ``line``(其媒体引用的清单行号),供语义级广告标记
    (``CUE-OUT``/``CUE-IN`` 区间)按行号定位要剪的条目。
    """
    header: list[str] = []
    groups: list[list[dict]] = []
    current_entry: dict | None = None
    current_group: list[dict] | None = None
    pending_tags: list[str] = []
    seen_media = False
    has_endlist = False

    def flush_entry() -> None:
        nonlocal current_entry, current_group
        if current_entry is not None:
            if current_group is None:
                current_group = []
            current_group.append(current_entry)
            current_entry = None

    def flush_group() -> None:
        nonlocal current_group
        flush_entry()
        if current_group:
            groups.append(current_group)
        current_group = None

    for index, raw in enumerate((text or "").splitlines()):
        stripped = raw.strip()
        if not stripped:
            continue
        upper = stripped.upper()
        if upper == "#EXT-X-DISCONTINUITY":
            flush_group()
            continue
        if upper == "#EXT-X-ENDLIST":
            has_endlist = True
            continue
        if upper.startswith("#EXTINF"):
            flush_entry()
            seen_media = True
            duration = None
            try:
                duration = float(stripped.split(":", 1)[1].split(",")[0])
            except (IndexError, ValueError):
                pass
            current_entry = {
                "extinf": raw,
                "duration": duration,
                "uris": [],
                "pre_tags": pending_tags,
                "tags": [],
                "line": index,
            }
            pending_tags = []
        elif stripped.startswith("#"):
            if current_entry is not None:
                if upper.startswith(("#EXT-X-KEY", "#EXT-X-MAP")):
                    pending_tags.append(raw)
                else:
                    current_entry["tags"].append(raw)
            elif seen_media:
                pending_tags.append(raw)
            else:
                header.append(raw)
        else:
            if current_entry is not None:
                current_entry["uris"].append(raw)
            else:
                header.append(raw)
    flush_group()
    return header, groups, has_endlist


def _host_of(base_url: str, uri: str) -> str:
    try:
        return (urlparse(_absolute(base_url, uri)).hostname or "").lower()
    except ValueError:
        return ""


_HEX_TOKEN_RE = re.compile(r"[0-9a-f]{12,}", re.IGNORECASE)
_DIGITS_RE = re.compile(r"\d+")


def _dir_prefix_of(base_url: str, uri: str) -> str:
    try:
        path = urlparse(_absolute(base_url, uri)).path or ""
    except ValueError:
        return ""
    if "/" not in path:
        return ""
    return path.rsplit("/", 1)[0]


def _filename_skeleton_of(base_url: str, uri: str) -> str:
    try:
        path = urlparse(_absolute(base_url, uri)).path or ""
    except ValueError:
        return ""
    name = path.rsplit("/", 1)[-1]
    if not name:
        return ""
    skeleton = _HEX_TOKEN_RE.sub("H", name)
    return _DIGITS_RE.sub("#", skeleton)


def _extract_key_signature(tags: list[str], base_url: str) -> str | None:
    key_sig: str | None = None
    for tag in tags:
        upper = tag.strip().upper()
        if not upper.startswith("#EXT-X-KEY:"):
            continue
        if "METHOD=NONE" in upper.replace(" ", ""):
            key_sig = "NONE"
            continue
        match = _URI_ATTR_RE.search(tag)
        if match:
            key_sig = _absolute(base_url, match.group(1))
        else:
            key_sig = tag.strip()
    return key_sig


def _dominant_value(counts: dict[str, int], total: int) -> str:
    if not counts or total <= 0:
        return ""
    best = max(counts, key=counts.get)
    return best if (counts[best] / total) >= 0.6 else ""


def clean_playlist(
    text: str,
    base_url: str = "",
    *,
    ad_signals: "AdSignals | None" = None,
) -> tuple[str, CutReport]:
    """剪裁媒体清单。→ (重写后的清单文本, 报告)

    ``ad_signals`` 为可选的语义级分析结论(``scrapers.ad_signals``)。给了它就
    多一条**确定性**判据:被 ``#EXT-X-CUE-OUT`` / ``#EXT-X-CUE-IN`` 成对标记
    包住的媒体条目直接剪掉,不再依赖时长启发式。不给则行为与原先一致。
    """
    header, groups, has_endlist = _parse(text)
    report = CutReport()
    if not groups:
        return text or "", report

    # 语义级:CUE-OUT/CUE-IN 区间内的媒体引用(按清单行号定位)
    semantic_lines: set[int] = set()
    if ad_signals is not None and ad_signals.has_ad_break:
        for ad_break in ad_signals.breaks:
            semantic_lines.update(range(ad_break.start_line + 1, ad_break.end_line))
        if semantic_lines:
            report.reasons.append(
                f"广告标记区间({len(ad_signals.breaks)}段)"
            )

    durations = [
        entry["duration"]
        for group in groups
        for entry in group
        if entry["duration"]
    ]
    total_duration = sum(durations)
    global_median = statistics.median(durations) if durations else 0.0
    threshold = (
        max(_MIN_SHORT_THRESHOLD_SECONDS, global_median / 3.0)
        if global_median
        else 0.0
    )

    host_count: dict[str, int] = {}
    dir_count: dict[str, int] = {}
    skeleton_count: dict[str, int] = {}
    key_count: dict[str, int] = {}
    header_key = _extract_key_signature(header, base_url) or "NONE"
    active_key = header_key
    group_meta: list[dict[str, object]] = []
    total_entries = sum(len(group) for group in groups)

    for group in groups:
        g_dirs: set[str] = set()
        g_skeletons: set[str] = set()
        g_keys: set[str] = set()
        for entry in group:
            entry_key = _extract_key_signature(
                [*entry.get("pre_tags", ()), *entry["tags"]], base_url
            )
            if entry_key is not None:
                active_key = entry_key
            g_keys.add(active_key)
            key_count[active_key] = key_count.get(active_key, 0) + 1
            for uri in entry["uris"]:
                host = _host_of(base_url, uri)
                if host:
                    host_count[host] = host_count.get(host, 0) + 1
                dir_prefix = _dir_prefix_of(base_url, uri)
                if dir_prefix:
                    g_dirs.add(dir_prefix)
                    dir_count[dir_prefix] = dir_count.get(dir_prefix, 0) + 1
                skeleton = _filename_skeleton_of(base_url, uri)
                if skeleton:
                    g_skeletons.add(skeleton)
                    skeleton_count[skeleton] = skeleton_count.get(skeleton, 0) + 1
        group_meta.append({
            "dirs": g_dirs,
            "skeletons": g_skeletons,
            "keys": g_keys,
        })

    dominant_host = max(host_count, key=host_count.get) if host_count else ""
    total_segments = sum(host_count.values())
    odd_host_limit = max(
        _ODD_HOST_MIN_COUNT, int(total_segments * _ODD_HOST_MAX_SHARE)
    )
    dominant_dir = _dominant_value(dir_count, total_entries)
    dominant_skeleton = _dominant_value(skeleton_count, total_entries)
    dominant_key = _dominant_value(key_count, total_entries)
    island_max_segments = max(2, int(total_entries * 0.15))

    # A. 组级
    kept_groups: list[tuple[int, list[dict]]] = []
    for index, group in enumerate(groups):
        group_durations = [e["duration"] for e in group if e["duration"]]
        median = statistics.median(group_durations) if group_durations else None
        total = sum(group_durations)
        hosts = {
            host
            for entry in group
            for uri in entry["uris"]
            for host in (_host_of(base_url, uri),)
            if host
        }
        meta = group_meta[index]
        g_dirs: set[str] = meta["dirs"]  # type: ignore[assignment]
        g_skeletons: set[str] = meta["skeletons"]  # type: ignore[assignment]
        g_keys: set[str] = meta["keys"]  # type: ignore[assignment]
        reasons: list[str] = []
        # 语义判据优先:整组都落在广告标记区间内才按组剪
        if group and all(e.get("line") in semantic_lines for e in group):
            reasons.append("广告标记区间整组")
        if (
            global_median
            and median is not None
            and len(group) >= 2
            and median <= threshold
        ):
            reasons.append(f"短分片簇(median={median:.1f}s≤{threshold:.1f}s)")
        if (
            global_median
            and len(groups) > 1
            and index in (0, len(groups) - 1)
            and total < _EDGE_CLUSTER_MAX_SECONDS
            and median
            and median < global_median * _EDGE_CLUSTER_MEDIAN_RATIO
        ):
            reasons.append(f"首尾小簇({total:.0f}s)")
        odd_hosts = {
            host
            for host in hosts
            if host != dominant_host and host_count.get(host, 0) <= odd_host_limit
        }
        if dominant_host and odd_hosts:
            reasons.append(f"异域分片({len(odd_hosts)}个)")
        # 国内采集站片头/片中/片尾 DISCONTINUITY 广告孤岛判据
        if (
            len(groups) >= 2
            and 2.0 <= total <= 50.0
            and len(group) <= island_max_segments
        ):
            if dominant_dir and g_dirs and dominant_dir not in g_dirs:
                reasons.append(f"异路径广告孤岛({total:.0f}s)")
            elif (
                dominant_skeleton
                and g_skeletons
                and dominant_skeleton not in g_skeletons
            ):
                reasons.append(f"异文件名广告孤岛({total:.0f}s)")
            elif dominant_key and g_keys and dominant_key not in g_keys:
                reasons.append(f"异密钥广告孤岛({total:.0f}s)")

        if reasons:
            report.groups_cut += 1
            report.segments_cut += len(group)
            report.seconds_cut += total
            report.reasons.append("; ".join(reasons))
        else:
            kept_groups.append((index, group))

    # B. 组内条目级:语义标记命中即剪;否则退回"连续 ≥2 条短分片才剪"
    flat_items: list[tuple[int, dict]] = [
        (group_idx, entry)
        for group_idx, group in kept_groups
        for entry in group
    ]
    is_short = [
        bool(
            global_median
            and entry["duration"] is not None
            and entry["duration"] <= threshold
        )
        for _, entry in flat_items
    ]

    def in_streak(i: int) -> bool:
        if not is_short[i]:
            return False
        prev_short = i > 0 and is_short[i - 1]
        next_short = i + 1 < len(is_short) and is_short[i + 1]
        return prev_short or next_short

    body: list[str] = []
    last_kept_group_idx: int | None = None
    kept_duration = 0.0
    for i, (group_idx, entry) in enumerate(flat_items):
        if entry.get("line") in semantic_lines:
            report.micro_cut += 1
            report.seconds_cut += entry["duration"] or 0.0
            continue
        if in_streak(i):
            report.micro_cut += 1
            report.seconds_cut += entry["duration"] or 0.0
            continue
        # 仅保留非广告切除边界的原始 DISCONTINUITY,避免正片换轨花屏
        if (
            last_kept_group_idx is not None
            and group_idx == last_kept_group_idx + 1
        ):
            body.append("#EXT-X-DISCONTINUITY")
        last_kept_group_idx = group_idx
        for tag in entry.get("pre_tags", ()):
            body.append(_rewrite_uri_attr(tag, base_url))
        body.append(entry["extinf"])
        for tag in entry["tags"]:
            body.append(_rewrite_uri_attr(tag, base_url))
        for uri in entry["uris"]:
            body.append(_absolute(base_url, uri) if base_url else uri)
        report.segments_kept += 1
        kept_duration += entry["duration"] or 0.0

    # 保守防误剪护栏:长片如果误删超过一半内容或剩余不足 30s,回退原清单
    if (
        report.changed
        and total_entries > 0
        and (
            report.segments_kept < total_entries * 0.5
            or (total_duration > 60.0 and kept_duration < 30.0)
        )
    ):
        return text or "", CutReport(segments_kept=total_entries)

    out_header = [_rewrite_uri_attr(line, base_url) for line in header]
    lines = [*out_header, *body]
    if has_endlist or report.changed:
        lines.append("#EXT-X-ENDLIST")   # 必须在所有媒体段之后
    return "\n".join(lines) + "\n", report


@dataclass(frozen=True)
class CleanResult:
    playlist: str
    report: CutReport
    variant_url: str | None = None


def needs_clean(url: str, declared_format: str = "") -> bool:
    """mp4 等整包源无法按分片剪,只有 HLS 清单可剪。"""
    lowered = (url or "").lower()
    if ".m3u8" in lowered:
        return True
    return (declared_format or "").strip().lower() in {"hls", "m3u8"}


async def _fetch_playlist(
    url: str,
    *,
    client: httpx.AsyncClient,
    headers: dict[str, str],
    max_bytes: int,
    validate_url: Callable[[str], Awaitable[bool]],
    max_redirects: int,
) -> tuple[str, str] | None:
    # Explicit redirects keep every hop inside the same validation/size budget.
    # Track public_url separately from the optional local relay fetch_url so
    # rewritten client playlists always keep public segment URLs.
    public_url = url
    for hop in range(max_redirects + 1):
        fetch_url = to_fetch_url(public_url)
        if not await validate_url(fetch_url):
            return None
        async with client.stream(
            "GET", fetch_url, headers=headers, follow_redirects=False,
        ) as response:
            if response.status_code in (301, 302, 303, 307, 308):
                location = response.headers.get("location")
                if not location or hop == max_redirects:
                    return None
                public_url = urljoin(public_url, location)
                continue
            if response.status_code != 200:
                return None
            length = response.headers.get("content-length")
            if length is not None:
                try:
                    if int(length) < 0 or int(length) > max_bytes:
                        return None
                except ValueError:
                    return None
            body = bytearray()
            # Stream-decompress with a strict decompressed ceiling to protect
            # against decompression bombs without breaking gzip-enforcing CDNs.
            async for chunk in response.aiter_bytes():
                if len(body) + len(chunk) > max_bytes:
                    return None
                body.extend(chunk)
            text = body.decode("utf-8-sig")
            if not text.lstrip().startswith("#EXTM3U"):
                return None
            return text, public_url
    return None


async def validate_fetch_url(url: str) -> bool:
    """清单抓取的地址校验:公网地址,或本机自建中继的媒体入口。

    ``clean_url`` 默认只接受公网地址(防 SSRF)。但自建中继就在本机,后端
    取它的清单纯属内部调用 —— 若一并按公网校验,``127.0.0.1`` 会被判为
    非公网,``clean_url`` 直接返回 None,剪广告功能**静默失效**(表现是
    客户端每次都被退回原始直链,看不出原因)。

    实际判据与连接钉定共用 ``public_http.is_relay_media_url``,避免两处规则
    漂移;放行的范围也因此严格限定在中继的 ``/media/`` 入口。
    """
    from .. import config
    from ..public_http import is_relay_media_url

    if is_relay_media_url(url, config.ANICH_RELAY_FETCH_BASE):
        return True
    if is_relay_media_url(url, config.ANICH_RELAY_PUBLIC_BASE):
        return True
    return await is_public_http_url(url)


async def clean_url(
    url: str,
    *,
    client: httpx.AsyncClient,
    headers: dict[str, str] | None = None,
    max_bytes: int = 4 * 1024 * 1024,
    validate_url: Callable[[str], Awaitable[bool]] = is_public_http_url,
    max_redirects: int = 5,
    timeout_seconds: float = 12.0,
) -> CleanResult | None:
    """Fetch bounded public playlists, or return None for original-line fallback.

    The production client uses PublicHttpTransport to pin validated DNS answers.
    No media segments or encryption keys are fetched by this function.
    """
    request_headers = dict(headers or {})
    try:
        async with asyncio.timeout(timeout_seconds):
            fetched = await _fetch_playlist(
                url, client=client, headers=request_headers, max_bytes=max_bytes,
                validate_url=validate_url, max_redirects=max_redirects,
            )
            if fetched is None:
                return None
            text, base = fetched
            variant_url = None
            if is_master_playlist(text):
                variant_url = pick_variant(text, base)
                if not variant_url:
                    return None
                fetched = await _fetch_playlist(
                    variant_url, client=client, headers=request_headers,
                    max_bytes=max_bytes, validate_url=validate_url,
                    max_redirects=max_redirects,
                )
                if fetched is None:
                    return None
                text, base = fetched
                variant_url = base
                if is_master_playlist(text):
                    return None
            # 语义级判据:这里已经把清单读进来了,顺手解析出 CUE-OUT/CUE-IN
            # 区间,交给 clean_playlist 作为确定性剪裁依据(比时长启发式可靠)。
            playlist, report = clean_playlist(
                text, base, ad_signals=analyze_manifest(text)
            )
            return CleanResult(playlist=playlist, report=report, variant_url=variant_url)
    except (httpx.HTTPError, httpx.InvalidURL, TimeoutError, ValueError):
        return None
