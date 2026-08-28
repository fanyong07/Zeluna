"""AniCh 聚合源上游传输层(域名白名单唯一模块)。

本文件是运行时代码中**唯一**允许出现 AniCh 及其镜像主机名的地方
(``tests/test_independent_backend.py`` 按相对路径豁免本文件并校验这一点)。
所有请求必须经 ``AniChTransport`` 发出;禁止在别处拼 URL。

协议要点(逆向与实测记录):
  * 主域 ``anich.sends.eu.org``;api.json 分发的旧域名已全部 404,
    真实备胎域由客户端内置(下表按优先顺序排列);
  * 请求只需约定 UA,匿名无签名;
  * 上游有风控:同一进程内串行 + 请求间隔 ≥1.2s,403/429 需退避。

容灾模型:真实业务请求即探活。``request()`` 按优先序扫过未被冷却的
候选域,成功者被记为工作主域(后续调用优先),失败者进入冷却;
单次调用内按序尝试至多一轮,不扇出、不做合成探测请求。
"""

from __future__ import annotations

import asyncio
import time
from urllib.parse import quote

import httpx

from ... import config

# 红线测试豁免仅限本文件:新增主机名只能写在这里。
ANICH_FALLBACK_BASES: tuple[str, ...] = (
    "https://anich.sends.eu.org",
    "https://host.anich.sends.eu.org",
    "https://api.500403.xyz",
    "https://ani.emmmm.eu.org",
    "https://api.emmmm.eu.org.cdn.cloudflare.net",
)
ANICH_USER_AGENT = "cx.xs.open Android 1.5.23"
# 上游自建 CDN 主域判据(线路排序加分用);cloudflare 托管别名由子串命中。
ANICH_OWN_CDN_HOST_TOKENS: tuple[str, ...] = (
    "vod-cdn.sends.eu.org",
    "v-cdn.emmmm.eu.org",
)


def anich_search_path(keyword: str, skip: int = 0) -> str:
    return f"/bangumi/search?keyword={quote(keyword)}&skip={int(skip)}"


def anich_latest_path() -> str:
    return "/bangumi/latest"


def anich_detail_path(bangumi_id: int | str) -> str:
    return f"/bangumi/detail/{int(bangumi_id)}"


def anich_episodes_path(bangumi_id: int | str) -> str:
    return f"/bangumi/episodes/{int(bangumi_id)}"


def anich_vod_path(bangumi_id: int | str, episode_sort: int) -> str:
    """注意第二个参数是跨季全局集号(``sort``),不是季内序号。"""
    return f"/vod/{int(bangumi_id)}/{int(episode_sort)}"


class AniChUpstreamError(RuntimeError):
    """一次不可恢复的上游失败(status 为 None 表示连接层错误)。"""

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class AniChTransport:
    """串行 + 节流 + 多域容灾的极薄 HTTP 层。

    单个 ``AniChScraper`` 实例在进程内是单例(aggregator 构造),
    实例级锁即全局锁:quick/full 双通道并发进来也只会排队。
    """

    def __init__(
        self,
        *,
        bases: tuple[str, ...] | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        interval: float | None = None,
        timeout: float | None = None,
        backoff_max: float | None = None,
        base_cooldown_seconds: float | None = None,
        clock=time.monotonic,
        sleep_func=asyncio.sleep,
    ) -> None:
        self._bases = tuple(bases or ANICH_FALLBACK_BASES)
        self._interval = (
            config.ANICH_MIN_REQUEST_INTERVAL_SECONDS
            if interval is None
            else interval
        )
        self._timeout = (
            config.ANICH_HTTP_TIMEOUT_SECONDS if timeout is None else timeout
        )
        self._backoff_max = (
            config.ANICH_BACKOFF_MAX_SECONDS if backoff_max is None else backoff_max
        )
        self._base_cooldown_seconds = (
            config.ANICH_BASE_COOLDOWN_SECONDS
            if base_cooldown_seconds is None
            else base_cooldown_seconds
        )
        self._clock = clock
        self._sleep = sleep_func
        self._client = httpx.AsyncClient(
            headers={"User-Agent": ANICH_USER_AGENT},
            timeout=self._timeout,
            transport=transport,
        )
        self._dispatch_lock = asyncio.Lock()
        self._last_dispatch_at: float | None = None
        self._working_base: str | None = None
        self._base_cooldown_until: dict[str, float] = {}

    @property
    def base(self) -> str | None:
        """当前工作主域(诊断用;不得写入日志或对外元数据)。"""
        return self._working_base

    async def aclose(self) -> None:
        await self._client.aclose()

    # ── 对外请求入口 ──────────────────────────────────────────
    async def request(self, path: str) -> bytes:
        """GET ``<base><path>`` 并返回响应体。

        失败语义:每个候选域先直试;403/429 退避后对该域再试一次;
        连接层错误或仍失败则冷却该域并顺延到下一候选。全部候选耗尽
        后抛 ``AniChUpstreamError``(status 取最后一次限流状态或 None)。
        """
        last_error: BaseException | None = None
        last_status: int | None = None
        candidates = self._available_bases()
        if not candidates:
            raise AniChUpstreamError("all anich bases cooling down")
        for candidate in candidates:
            retried_rate_limit = False
            while True:
                try:
                    status, body = await self._dispatch(candidate + path)
                except httpx.HTTPError as error:
                    last_error = AniChUpstreamError(
                        f"anich transport error: {error}"
                    )
                    self._note_failure(candidate)
                    break
                if status == 200 and body:
                    self._note_success(candidate)
                    return body
                if status in (403, 429) and not retried_rate_limit:
                    retried_rate_limit = True
                    await self._sleep(min(self._backoff_max, 5.0))
                    continue
                last_status = status
                last_error = AniChUpstreamError(
                    f"unexpected anich response ({status})",
                    status=status,
                )
                self._note_failure(candidate)
                break
        raise AniChUpstreamError(
            f"anich request failed ({type(last_error).__name__}: {last_error}); "
            f"last_status={last_status}",
            status=getattr(last_error, "status", None),
        )

    # ── 内部细节 ─────────────────────────────────────────────
    async def _dispatch(self, url: str) -> tuple[int, bytes]:
        """串行派发:发出前补足最小间隔。"""
        async with self._dispatch_lock:
            now = self._clock()
            if self._last_dispatch_at is not None:
                wait = self._interval - (now - self._last_dispatch_at)
                if wait > 0:
                    await self._sleep(wait)
                    now = self._clock()
            self._last_dispatch_at = now
            response = await self._client.get(url)
            return response.status_code, response.content

    def _available_bases(self) -> list[str]:
        """工作主域优先、已冷却者剔除的候选序。"""
        now = self._clock()
        ordered = list(self._bases)
        working = self._working_base
        if working in ordered:
            ordered.remove(working)
            ordered.insert(0, working)
        return [
            candidate
            for candidate in ordered
            if self._base_cooldown_until.get(candidate, 0) <= now
        ]

    def _note_success(self, base: str) -> None:
        self._working_base = base
        self._base_cooldown_until.pop(base, None)

    def _note_failure(self, base: str) -> None:
        self._base_cooldown_until[base] = self._clock() + self._base_cooldown_seconds
