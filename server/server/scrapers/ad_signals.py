"""HLS 广告标记的语义级识别(纯函数,不取数据、不改清单)。

为什么需要这一层
----------------
``hls_clean`` 原先只有**时长/主机启发式**判据:短分片簇、首尾小簇、异域分片。
那套判据对付"采集站随手插一段短分片"够用,但漏掉了一类更好认的东西 ——
**上游自己留下的广告标记**。这些标记是广告插入系统的标准产物,命中即确定:

    #EXT-X-CUE-OUT:30            广告插播开始,后跟时长
    #EXT-X-CUE-OUT-CONT          SCTE-35 分段连续
    #EXT-X-CUE-IN                广告结束
    #EXT-X-SCTE35:...            SCTE-35 二进制负载
    #EXT-X-ASSET:CAID=...        ​Adobe 广告资源描述
    #EXT-X-DATERANGE:...SCTE35...  以 DATERANGE 携带的 SCTE-35

判定整体是**保守**的:标记只用来"认出广告区间",区间内没有可剪条目时
不改清单 —— 漏剪比误剪安全(误剪会把正片切掉,整条线路直接不可播)。

本模块的职责边界:
  * 它**只报告**发现了什么(marker / span / 行号);
  * 真正决定"丢哪些行"的仍是 ``hls_clean.clean_playlist``;
  * 不联网、不碰文件、不依赖 httpx。
"""

from __future__ import annotations

import re
from collections import OrderedDict
from dataclasses import dataclass, field

__all__ = [
    "AdMarker",
    "AdBreak",
    "AdSignals",
    "analyze_manifest",
    "has_ad_markers",
    "AdCarrierCache",
    "AD_CARRIER_CACHE",
]

#: 广告插播开始的标记(带时长或不带)。
_CUE_OUT_RE = re.compile(r"^#EXT-X-CUE-OUT(?::(.*))?$", re.IGNORECASE)
#: SCTE-35 分段连续标记。
_CUE_OUT_CONT_RE = re.compile(r"^#EXT-X-CUE-OUT-CONT(?::(.*))?$", re.IGNORECASE)
#: 广告结束标记。
_CUE_IN_RE = re.compile(r"^#EXT-X-CUE-IN(?::(.*))?$", re.IGNORECASE)
#: SCTE-35 负载标签。
_SCTE35_RE = re.compile(r"^#EXT-X-SCTE35(?::(.*))?$", re.IGNORECASE)
#: Adobe 广告资源描述。
_ASSET_RE = re.compile(r"^#EXT-X-ASSET(?::(.*))?$", re.IGNORECASE)
#: 以 DATERANGE 携带 SCTE-35 的形态。
_DATERANGE_RE = re.compile(r"^#EXT-X-DATERANGE:(.*)$", re.IGNORECASE)
_SCTE_IN_DATERANGE_RE = re.compile(r"SCTE[-_]?35", re.IGNORECASE)

#: ``#EXTINF:`` 的时长解析(与 hls_clean 保持一致,不引入第二套解析器)。
_EXTINF_RE = re.compile(r"^#EXTINF:\s*([0-9.]+)", re.IGNORECASE)


@dataclass(frozen=True)
class AdMarker:
    """一条命中的广告标记。"""

    kind: str
    """标记类型:``cue_out`` / ``cue_out_cont`` / ``cue_in`` /
    ``scte35`` / ``asset`` / ``daterange_scte35``。"""

    tag: str
    """原始标签文本(已 strip),便于排障。"""

    line_index: int
    """在清单里的 0 基行号。"""

    payload: str = ""
    """冒号后的负载(时长或 SCTE 参数)。"""

    @property
    def is_break_start(self) -> bool:
        return self.kind in {"cue_out", "cue_out_cont"}

    @property
    def is_break_end(self) -> bool:
        return self.kind == "cue_in"


@dataclass(frozen=True)
class AdBreak:
    """一个广告区间:由一个 ``CUE-OUT`` 起、到 ``CUE-IN`` 或清单末尾止。"""

    start_line: int
    end_line: int
    declared_seconds: float = 0.0
    media_references: tuple[str, ...] = ()

    @property
    def media_count(self) -> int:
        return len(self.media_references)


@dataclass
class AdSignals:
    """一次清单分析的完整结论。"""

    markers: list[AdMarker] = field(default_factory=list)
    breaks: list[AdBreak] = field(default_factory=list)

    @property
    def has_any_signal(self) -> bool:
        return bool(self.markers)

    @property
    def has_ad_break(self) -> bool:
        """是否存在**成对可界定**的广告区间(有起点)。"""
        return bool(self.breaks)

    @property
    def media_reference_count(self) -> int:
        return sum(len(b.media_references) for b in self.breaks)

    def as_public_dict(self) -> dict:
        """给日志用的摘要,不含媒体地址。"""
        return {
            "markers": [m.kind for m in self.markers][:12],
            "breaks": len(self.breaks),
            "break_media": self.media_reference_count,
            "declared_seconds": round(
                sum(b.declared_seconds for b in self.breaks), 1
            ),
        }


def _parse_declared_seconds(payload: str) -> float:
    """从 ``#EXT-X-CUE-OUT:30`` / ``:30.000`` / ``:DURATION=30`` 里取秒数。"""
    if not payload:
        return 0.0
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)", payload)
    if not match:
        return 0.0
    try:
        value = float(match.group(1))
    except ValueError:
        return 0.0
    # 明显不是秒数的量级(如 SCTE 里的十六进制负载)一律忽略
    return value if 0 < value <= 3600 else 0.0


def _is_media_line(text: str) -> bool:
    stripped = (text or "").strip()
    return bool(stripped) and not stripped.startswith("#")


def analyze_manifest(text: str) -> AdSignals:
    """分析清单文本,返回广告标记与可界定的广告区间。

    任何输入都不抛异常:非清单文本返回空结论。
    """
    signals = AdSignals()
    if not text or "#EXTM3U" not in text:
        return signals

    lines = text.splitlines()

    # ── 第一遍:收集标记 ──────────────────────────────────────
    for index, raw in enumerate(lines):
        stripped = raw.strip()
        if not stripped.upper().startswith("#EXT-X-"):
            continue
        upper = stripped.upper()

        match = _CUE_OUT_RE.match(stripped)
        if match:
            signals.markers.append(AdMarker(
                kind="cue_out", tag=stripped, line_index=index,
                payload=(match.group(1) or "").strip(),
            ))
            continue
        match = _CUE_OUT_CONT_RE.match(stripped)
        if match:
            signals.markers.append(AdMarker(
                kind="cue_out_cont", tag=stripped, line_index=index,
                payload=(match.group(1) or "").strip(),
            ))
            continue
        match = _CUE_IN_RE.match(stripped)
        if match:
            signals.markers.append(AdMarker(
                kind="cue_in", tag=stripped, line_index=index,
                payload=(match.group(1) or "").strip(),
            ))
            continue
        if upper.startswith("#EXT-X-SCTE35"):
            match = _SCTE35_RE.match(stripped)
            signals.markers.append(AdMarker(
                kind="scte35", tag=stripped, line_index=index,
                payload=(match.group(1) or "").strip() if match else "",
            ))
            continue
        if upper.startswith("#EXT-X-ASSET"):
            match = _ASSET_RE.match(stripped)
            signals.markers.append(AdMarker(
                kind="asset", tag=stripped, line_index=index,
                payload=(match.group(1) or "").strip() if match else "",
            ))
            continue
        match = _DATERANGE_RE.match(stripped)
        if match and _SCTE_IN_DATERANGE_RE.search(match.group(1) or ""):
            signals.markers.append(AdMarker(
                kind="daterange_scte35", tag=stripped, line_index=index,
                payload="",
            ))

    # ── 第二遍:把起止标记配成区间,并收集区间内的媒体引用 ──────
    open_start: AdMarker | None = None
    open_declared = 0.0
    for line_index, raw in enumerate(lines):
        marker = next(
            (m for m in signals.markers if m.line_index == line_index), None
        )
        if marker is not None and marker.is_break_start:
            # 嵌套的 CUE-OUT 以前一个未闭合区间为准,不丢已有区间
            if open_start is not None:
                signals.breaks.append(_close_break(
                    signals, lines, open_start, line_index, open_declared,
                ))
            open_start = marker
            open_declared = _parse_declared_seconds(marker.payload)
            continue
        if marker is not None and marker.is_break_end and open_start is not None:
            signals.breaks.append(_close_break(
                signals, lines, open_start, line_index, open_declared,
            ))
            open_start = None
            open_declared = 0.0

    if open_start is not None:
        # 未闭合:广告区间一直延续到清单末尾
        signals.breaks.append(_close_break(
            signals, lines, open_start, len(lines), open_declared,
        ))
    return signals


def _close_break(
    signals: AdSignals,
    lines: list[str],
    start: AdMarker,
    end_line: int,
    declared: float,
) -> AdBreak:
    refs = tuple(
        line.strip()
        for line in lines[start.line_index + 1: end_line]
        if _is_media_line(line)
    )
    return AdBreak(
        start_line=start.line_index,
        end_line=end_line,
        declared_seconds=declared,
        media_references=refs,
    )


def has_ad_markers(text: str) -> bool:
    """快速判定:清单里是否出现任何广告标记。"""
    return bool(analyze_manifest(text).markers)


class AdCarrierCache:
    """有界 LRU:记录"这条清单地址是否携带广告标记"。

    为什么需要缓存:验线时会读一次清单(HLS 起播探测本来就要读),
    而对外给出播放地址是在**另一个请求**里 。把验线读到的结论按地址记下来,
    播放请求就不必为了判断"要不要走剪裁"再读一次清单 —— 省掉一次
    上游往返,也避免给本就没有广告的线路平白加一跳。

    只存地址与布尔值,不存清单内容、不存媒体分片。
    """

    def __init__(self, max_entries: int = 2048):
        self._max = max(1, int(max_entries))
        self._entries: OrderedDict[str, bool] = OrderedDict()

    def record(self, url: str, carries_ads: bool) -> None:
        key = (url or "").strip()
        if not key:
            return
        self._entries[key] = bool(carries_ads)
        self._entries.move_to_end(key)
        while len(self._entries) > self._max:
            self._entries.popitem(last=False)

    def record_manifest(
        self,
        url: str,
        manifest_text: str,
        *,
        truncated: bool = False,
        is_master: bool = False,
    ) -> bool:
        """分析清单并记录结论;返回是否携带广告标记。

        截断样本或主清单(master)若未发现广告信号,不能写成 ``False``(“确认干净”),
        否则会让片中/子清单广告绕过剪裁器。
        """
        carries = bool(analyze_manifest(manifest_text).markers)
        if not carries and not is_master:
            from .hls_clean import clean_playlist

            _, report = clean_playlist(manifest_text, url)
            carries = report.changed
        if carries:
            self.record(url, True)
            return True
        if not truncated and not is_master:
            self.record(url, False)
        return False

    def carries_ads(self, url: str) -> bool | None:
        """``True``/``False`` 为已知结论;``None`` 表示从未分析过。

        区分 ``False`` 与 ``None`` 是要紧的:前者"确认干净,不必剪裁",
        后者"没验过",调用方对后者的处理可以更保守。
        """
        return self._entries.get((url or "").strip())

    def forget(self, url: str) -> None:
        self._entries.pop((url or "").strip(), None)

    def clear(self) -> None:
        self._entries.clear()

    def __len__(self) -> int:
        return len(self._entries)


#: 进程级共享实例。聚合器写入,播放层读取。
AD_CARRIER_CACHE = AdCarrierCache()
