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
import socket
import time
from urllib.parse import quote, urlparse

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
ANICH_USER_AGENT = "cx.xs.open Android 1.5.23"# 上游自建 CDN 主域判据(线路排序加分用);cloudflare 托管别名由子串命中。
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


def to_fetch_url(url: str) -> str:
    """把中转交付的地址换成本机中转地址再取流。

    中转给播放地址时会套上它自己的**对外**域名,因为客户端在公网那头必须
    解析得到。但后端取流用的是同一个地址 —— 若照它去取,请求会绕一圈公网
    DNS 与 TLS 再回到本机;域名解析不了时(实测该域名在这台机器上只解析出
    IPv6,而本机没有 IPv6 出口)整条播放直接失败。

    必须覆盖**两处**,缺一处就漏:
      * 线路池里那条清单地址本身(``anich.get_video_urls``);
      * 清单**内部**解析出来的分片地址(``hls_clean._absolute``)。

    只换 scheme、host、port,路径与查询原样保留 —— 这样两端路径前缀不同也
    不会拼错,分片地址、token、签名都不受影响。
    """
    from ... import config

    public = config.ANICH_RELAY_PUBLIC_BASE
    local = config.ANICH_RELAY_FETCH_BASE
    if not public or not local or not url:
        return url
    outer = urlparse(public)
    inner = urlparse(local)
    if not outer.hostname or not inner.hostname:
        return url
    parsed = urlparse(url)
    if parsed.hostname != outer.hostname or parsed.port != outer.port:
        return url
    authority = f"{inner.scheme}://{inner.hostname}"
    if inner.port and inner.port != (443 if inner.scheme == "https" else 80):
        authority += f":{inner.port}"
    suffix = f"?{parsed.query}" if parsed.query else ""
    return f"{authority}{parsed.path}{suffix}"


class AniChUpstreamError(RuntimeError):
    """Structured, endpoint-free failure; retain its cause across cooldowns.

    ``reason`` describes this request, while ``cause_reason`` describes the
    failure that put an origin in cooldown. ``retry_after_seconds`` is relative
    to the current monotonic clock, not a persisted timestamp.
    """

    def __init__(
        self,
        message: str,
        *,
        status: int | None = None,
        reason: str = "upstream_http_error",
        retry_after_seconds: float = 0.0,
        cause_reason: str = "",
    ) -> None:
        super().__init__(message)
        self.status = status
        self.reason = reason
        self.retry_after_seconds = max(0.0, float(retry_after_seconds))
        self.cause_reason = cause_reason or reason


def _http_failure_reason(error: httpx.HTTPError) -> str:
    if isinstance(error, httpx.ConnectTimeout):
        return "connect_timeout"
    if isinstance(error, (httpx.ReadTimeout, httpx.WriteTimeout, httpx.PoolTimeout)):
        return "read_timeout"
    if isinstance(error, httpx.ConnectError):
        cause: BaseException | None = error
        visited: set[int] = set()
        while cause is not None and id(cause) not in visited:
            visited.add(id(cause))
            if isinstance(cause, socket.gaierror):
                return "dns_failure"
            cause = cause.__cause__ or cause.__context__
        if any(marker in str(error).casefold() for marker in (
            "getaddrinfo", "name or service", "nodename", "dns",
        )):
            return "dns_failure"
        return "connect_error"
    return "transport_error"


def _status_failure_reason(status: int) -> str:
    if status == 429:
        return "rate_limited"
    if status in (401, 403, 451):
        return "restricted"
    if status in (404, 410):
        return "stale_route"
    if status == 200:
        return "empty_response"
    return "upstream_http_error"


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
        # 配置中转时仅在中转候选间轮转,不向直连上游发送 relay key。
        relay = config.ANICH_RELAY_BASE
        relay_bases = tuple(dict.fromkeys(
            item.strip().rstrip("/") for item in relay.split(",") if item.strip()
        ))
        self._relay = bool(relay_bases)
        client_headers = {"User-Agent": ANICH_USER_AGENT}
        if self._relay and config.ANICH_RELAY_KEY:
            client_headers["X-Relay-Key"] = config.ANICH_RELAY_KEY
        self._client = httpx.AsyncClient(
            headers=client_headers,
            timeout=self._timeout,
            transport=transport,
        )
        if self._relay:
            self._bases = relay_bases
            # 上游节流由中转统一保证;本地不再叠加长间隔,否则白等。
            self._interval = (
                config.ANICH_RELAY_MIN_INTERVAL_SECONDS
                if interval is None
                else interval
            )
        self._dispatch_lock = asyncio.Lock()
        self._last_dispatch_at: float | None = None
        self._working_base: str | None = None
        self._base_cooldown_until: dict[str, float] = {}
        self._base_failures: dict[str, AniChUpstreamError] = {}

    @property
    def base(self) -> str | None:
        """当前工作主域(诊断用;不得写入日志或对外元数据)。"""
        return self._working_base

    @property
    def via_relay(self) -> bool:
        """是否经由自建中转取数。"""
        return bool(self._relay)

    async def aclose(self) -> None:
        await self._client.aclose()

    # ── 对外请求入口 ──────────────────────────────────────────
    async def request(self, path: str) -> bytes:
        """GET ``<base><path>`` 并返回响应体。

        失败语义:每个候选域先直试;403/429 退避后对该域再试一次;
        连接层错误或仍失败则冷却该域并顺延到下一候选。全部候选耗尽
        后抛 ``AniChUpstreamError``，保留最后失败的分类、HTTP 状态与 cause。
        冷却内不派发请求；剩余重试时间及触发冷却的原因随异常返回。
        """
        last_error: AniChUpstreamError | None = None
        candidates = self._available_bases()
        if not candidates:
            # A zero-I/O failure still has a concrete originating status/cause.
            # Pick the first origin eligible for retry, not a fresh blank error.
            next_base = min(self._bases, key=lambda base: self._base_cooldown_until[base])
            cause = self._base_failures.get(next_base)
            raise AniChUpstreamError(
                "all anich bases cooling down",
                reason="upstream_cooldown",
                status=cause.status if cause else None,
                retry_after_seconds=self._cooldown_remaining(),
                cause_reason=cause.cause_reason if cause else "upstream_cooldown",
            ) from cause
        for candidate in candidates:
            retried_rate_limit = False
            while True:
                url = candidate + path
                try:
                    status, body = await self._dispatch(url)
                except httpx.HTTPError as error:
                    last_error = AniChUpstreamError(
                        f"anich transport error ({type(error).__name__})",
                        reason=_http_failure_reason(error),
                    )
                    last_error.__cause__ = error
                    self._note_failure(candidate, last_error)
                    break
                if status == 200 and (body or path.startswith("/bangumi/search?")):
                    self._note_success(candidate)
                    return body
                # Keep the actual HTTP failure in memory for classification,
                # without putting endpoints or response bodies in error text.
                cause = httpx.HTTPStatusError(
                    f"unexpected anich response ({status})",
                    request=httpx.Request("GET", url),
                    response=httpx.Response(status),
                )
                # AniCh returns HTTP 500 for some unmatched title spellings.
                # A bad alias must not quarantine the otherwise usable origin.
                if path.startswith("/bangumi/search?") and status in (400, 404, 422, 500):
                    raise AniChUpstreamError(
                        f"anich search query failed ({status})",
                        status=status,
                        reason="search_query_failed",
                    ) from cause
                # A missing optional detail record is item-scoped. Search
                # enrichment must not quarantine otherwise usable /search or
                # /vod routes merely because one record is absent.
                if path.startswith("/bangumi/detail/") and status in (404, 410):
                    raise AniChUpstreamError(
                        f"anich detail unavailable ({status})",
                        status=status,
                        reason="stale_route",
                    ) from cause
                if status in (403, 429) and not retried_rate_limit:
                    retried_rate_limit = True
                    await self._sleep(min(self._backoff_max, 5.0))
                    continue
                last_error = AniChUpstreamError(
                    f"unexpected anich response ({status})",
                    status=status,
                    reason=_status_failure_reason(status),
                )
                last_error.__cause__ = cause
                self._note_failure(candidate, last_error)
                break
        assert last_error is not None
        raise AniChUpstreamError(
            f"anich request failed ({last_error.reason}); last_status={last_error.status}",
            status=last_error.status,
            reason=last_error.reason,
            retry_after_seconds=self._cooldown_remaining(),
            cause_reason=last_error.cause_reason,
        ) from last_error

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

    def _cooldown_remaining(self) -> float:
        now = self._clock()
        return min(
            (max(0.0, self._base_cooldown_until.get(base, now) - now)
             for base in self._bases),
            default=0.0,
        )

    def _note_success(self, base: str) -> None:
        self._working_base = base
        self._base_cooldown_until.pop(base, None)
        self._base_failures.pop(base, None)

    def _note_failure(self, base: str, error: AniChUpstreamError) -> None:
        self._base_cooldown_until[base] = self._clock() + self._base_cooldown_seconds
        self._base_failures[base] = error
