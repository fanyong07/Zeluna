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

import re
import statistics
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlparse

import httpx

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
    if not base_url or uri.startswith(("http://", "https://")):
        return uri
    return urljoin(base_url, uri)


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
    """→ (header_lines, groups, has_endlist);group = [entry]。"""
    header: list[str] = []
    groups: list[list[dict]] = []
    current_entry: dict | None = None
    current_group: list[dict] | None = None
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

    for raw in (text or "").splitlines():
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
            duration = None
            try:
                duration = float(stripped.split(":", 1)[1].split(",")[0])
            except (IndexError, ValueError):
                pass
            current_entry = {
                "extinf": raw,
                "duration": duration,
                "uris": [],
                "tags": [],
            }
        elif stripped.startswith("#"):
            if current_entry is not None:
                current_entry["tags"].append(raw)
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


def clean_playlist(text: str, base_url: str = "") -> tuple[str, CutReport]:
    """剪裁媒体清单。→ (重写后的清单文本, 报告)"""
    header, groups, has_endlist = _parse(text)
    report = CutReport()
    if not groups:
        return text or "", report

    durations = [
        entry["duration"]
        for group in groups
        for entry in group
        if entry["duration"]
    ]
    global_median = statistics.median(durations) if durations else 0.0
    threshold = (
        max(_MIN_SHORT_THRESHOLD_SECONDS, global_median / 3.0)
        if global_median
        else 0.0
    )

    host_count: dict[str, int] = {}
    for group in groups:
        for entry in group:
            for uri in entry["uris"]:
                host = _host_of(base_url, uri)
                if host:
                    host_count[host] = host_count.get(host, 0) + 1
    dominant_host = max(host_count, key=host_count.get) if host_count else ""
    total_segments = sum(host_count.values())
    odd_host_limit = max(
        _ODD_HOST_MIN_COUNT, int(total_segments * _ODD_HOST_MAX_SHARE)
    )

    # A. 组级
    kept_groups: list[list[dict]] = []
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
        reasons: list[str] = []
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
        if reasons:
            report.groups_cut += 1
            report.segments_cut += len(group)
            report.seconds_cut += total
            report.reasons.append("; ".join(reasons))
        else:
            kept_groups.append(group)

    # B. 组内条目级:连续 ≥2 条短分片才剪(孤立短分片保护)
    flat = [entry for group in kept_groups for entry in group]
    is_short = [
        bool(
            global_median
            and entry["duration"] is not None
            and entry["duration"] <= threshold
        )
        for entry in flat
    ]

    def in_streak(i: int) -> bool:
        if not is_short[i]:
            return False
        prev_short = i > 0 and is_short[i - 1]
        next_short = i + 1 < len(is_short) and is_short[i + 1]
        return prev_short or next_short

    body: list[str] = []
    for i, entry in enumerate(flat):
        if in_streak(i):
            report.micro_cut += 1
            report.seconds_cut += entry["duration"] or 0.0
            continue
        body.append(entry["extinf"])
        for tag in entry["tags"]:
            body.append(_rewrite_uri_attr(tag, base_url))
        for uri in entry["uris"]:
            body.append(_absolute(base_url, uri) if base_url else uri)
        report.segments_kept += 1

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


async def clean_url(
    url: str,
    *,
    client: httpx.AsyncClient,
    headers: dict | None = None,
    max_bytes: int = 4 * 1024 * 1024,
) -> CleanResult | None:
    """拉取清单并剪裁。失败返回 None,由调用方回退原直链。

    主清单会先选一路 variant 再剪。不写磁盘、不下载媒体分片。
    """
    request_headers = dict(headers or {})
    try:
        response = await client.get(url, headers=request_headers)
        if response.status_code != 200:
            return None
        text = response.text
        if len(response.content) > max_bytes:
            return None
    except httpx.HTTPError:
        return None

    variant_url: str | None = None
    if is_master_playlist(text):
        variant_url = pick_variant(text, url)
        if not variant_url:
            return None
        try:
            child = await client.get(variant_url, headers=request_headers)
            if child.status_code != 200:
                return None
            text = child.text
        except httpx.HTTPError:
            return None

    base = variant_url or url
    playlist, report = clean_playlist(text, base)
    return CleanResult(playlist=playlist, report=report, variant_url=variant_url)
