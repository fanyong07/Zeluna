"""跨源主机速度先验(与具体采集站无关)。

为什么需要它
------------
线路排序已经有一处**实测**信号:``playback`` 在验线时把每个主机的
``startup_latency_ms`` 记进线路对象。但那条信号只对**当次请求验过**的线路
有效;同一部作品的另一条线路、或另一部作品打同一个主机时,排序仍然从零
开始 —— 于是同一批主机每集都要重新"摸索"一次快慢。

本模块把验线得到的延迟观测按**主机**聚合,给出一个跨请求、跨作品的
速度先验。实测数据表明这个先验是稳定的(同一主机在不同作品上反复落在
同一量级):

    大厂对象存储   0.4s 级
    采集站原始 HLS 0.5s 级
    自建 CDN 转存  2.0~2.9s

设计边界
--------
* **只作同类内破平**,绝不推翻"已验证优先"的主层级(见
  ``playback._ordered_for_display`` 的 tier 语义);
* 观测次数不足或数值异常时返回 ``None``,调用方保持原顺序 —— 先验不能
  比它要替代的顺序更差;
* 进程内 EMA、有界容量,不落盘、不跨实例共享;重启即重学。
"""

from __future__ import annotations

from collections import OrderedDict
from typing import Iterable
from urllib.parse import urlparse

__all__ = ["HostSpeedPrior", "hostname_of", "PRIOR_ALPHA", "MIN_OBSERVATIONS"]

#: EMA 权重。0.35 与 playback 既有的 ``_SOURCE_HEALTH_EMA_ALPHA`` 同量级:
#  既不至于被单次抖动带偏,也能在 5~6 次观测内收敛。
PRIOR_ALPHA = 0.35
#: 少于这个观测数就不参与破平 —— 一次样本说明不了问题。
MIN_OBSERVATIONS = 2
#: 有界容量(按最近使用淘汰),防止主机维度无限增长。
MAX_HOSTS = 512
#: 明显超出正常起播范围的观测不采信(单位毫秒)。
_MIN_PLAUSIBLE_MS = 20
_MAX_PLAUSIBLE_MS = 60_000


def hostname_of(url: str) -> str:
    """取小写主机名;解析失败返回空串(调用方须容忍)。"""
    try:
        return (urlparse(url or "").hostname or "").lower()
    except ValueError:
        return ""


class HostSpeedPrior:
    """按主机聚合的起播延迟先验(EMA + 观测计数)。"""

    def __init__(self, *, alpha: float = PRIOR_ALPHA, max_hosts: int = MAX_HOSTS):
        self._alpha = min(1.0, max(0.01, float(alpha)))
        self._max_hosts = max(1, int(max_hosts))
        # host -> (ema_ms, observations);OrderedDict 用于 LRU 淘汰
        self._stats: OrderedDict[str, list[float]] = OrderedDict()

    # ── 写入 ──────────────────────────────────────────────────
    def observe(self, url: str, latency_ms: float | int | None) -> None:
        """记录一次起播延迟观测。非法输入静默忽略(不抛异常)。"""
        host = hostname_of(url)
        if not host:
            return
        try:
            value = float(latency_ms or 0)
        except (TypeError, ValueError):
            return
        if not (_MIN_PLAUSIBLE_MS <= value <= _MAX_PLAUSIBLE_MS):
            return
        entry = self._stats.get(host)
        if entry is None:
            self._stats[host] = [value, 1.0]
        else:
            entry[0] = entry[0] * (1 - self._alpha) + value * self._alpha
            entry[1] += 1.0
        # LRU:命中即移到末尾
        self._stats.move_to_end(host)
        while len(self._stats) > self._max_hosts:
            self._stats.popitem(last=False)

    def observe_many(self, pairs: Iterable[tuple[str, float | int | None]]) -> None:
        for url, latency in pairs:
            self.observe(url, latency)

    # ── 读取 ──────────────────────────────────────────────────
    def predict(self, url: str) -> float | None:
        """该主机的先验延迟(毫秒);样本不足或未知主机返回 ``None``。"""
        entry = self._stats.get(hostname_of(url))
        if entry is None or entry[1] < MIN_OBSERVATIONS:
            return None
        return entry[0]

    def observations(self, url: str) -> int:
        entry = self._stats.get(hostname_of(url))
        return int(entry[1]) if entry else 0

    def sort_key(self, url: str, fallback: float = float("inf")) -> float:
        """可直接用作 ``sorted`` 的键:有先验用先验,没有就沉到 ``fallback``。"""
        value = self.predict(url)
        return fallback if value is None else value

    def __len__(self) -> int:
        return len(self._stats)

    def clear(self) -> None:
        self._stats.clear()
