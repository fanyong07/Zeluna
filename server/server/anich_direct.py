"""自建 CDN 包装地址的解析器:经独立出口拿到真实地址并缓存。

背景(实测记录):
  * 线路池里的自建域地址是 **302 包装层**,不是媒体本体;
  * 本部署出口 IP 被 Cloudflare 按 IP 封禁(Error 1006),直连一律 403;
  * 通过已验证的独立出口取得 302;真实地址仍须由部署出口首字节探活;
  * 两族时效不同 —— ``emmmm`` 族带 ``x-expires`` 签名(样本约 30 天),
    ``sends`` 族样本无签名,按独立复检周期重新验证,不承诺永久有效。

所以本模块做三件事,彼此独立:
  1. ``resolve_wrapper``  经出口取 302,解出真实地址与到期时刻;
  2. ``probe_real_url``   验证真实地址确实能取到字节(带 Range);
  3. 进程内缓存           ``load_cache`` 填充,``lookup`` 供 scraper 同步读。

第 3 点存在的原因是 ``BaseScraper`` 契约里没有 session:scraper 不能自己
查库。所以由后台任务把表读进内存,scraper 只做同步查表,零 IO。
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from urllib.parse import parse_qs, urljoin, urlparse

import httpx

from . import config

logger = logging.getLogger(__name__)

#: 解析用的出口。默认指向本机独立 mihomo;留空表示直连(仅在本机出口
#: 未被封禁时才有意义)。
DEFAULT_PROXY = "http://127.0.0.1:7899"

#: 最多读取 1 KiB 验证首字节可达并排除常见错误页,不证明完整播放。
PROBE_RANGE = "bytes=0-1023"


def is_non_media_sample(sample: bytes) -> bool:
    """Reject common HTTP-200 error bodies even when Content-Type is absent."""
    head = sample.lstrip(b"\xef\xbb\xbf \r\n\t").lower()
    return head.startswith((b"<!doctype html", b"<html", b"<head", b"<body", b'{"', b"[{"))

#: 同一时刻最多几个解析请求在飞。出口机是 1 vCPU 的小机器,不扇出。
_RESOLVE_CONCURRENCY = 2

#: 签名到期前多久算"需要重解"。留出足够余量,避免用户正好卡在边界。
EXPIRY_SAFETY_SECONDS = 6 * 3600


class AddressFamily:
    """包装层的族。两族的上游 CDN 与时效机制都不同,必须分开处理。"""

    CLOUDFLARE = "cloudflare"
    """``v-cdn.emmmm.eu.org`` 族。Cloudflare 前置,重定向带签名。"""
    EDGEONE = "edgeone"
    """``vod-cdn.sends.eu.org`` 族。腾讯 EdgeOne,重定向不带签名。"""
    UNKNOWN = "unknown"


#: 原始域及已观察到的 Cloudflare 托管别名,按 DNS 标签边界匹配。
_FAMILY_TOKENS: tuple[tuple[str, str], ...] = (
    ("emmmm.eu.org", AddressFamily.CLOUDFLARE),
    ("sends.eu.org", AddressFamily.EDGEONE),
    ("emmmm.eu.org.cdn.cloudflare.net", AddressFamily.CLOUDFLARE),
    ("sends.eu.org.cdn.cloudflare.net", AddressFamily.EDGEONE),
)


def family_of(url: str) -> str:
    try:
        host = (urlparse(url).hostname or "").rstrip(".").lower()
    except ValueError:
        return AddressFamily.UNKNOWN
    for token, family in _FAMILY_TOKENS:
        if host == token or host.endswith("." + token):
            return family
    return AddressFamily.UNKNOWN


#: 表示"直连"的写法。为什么要单独支持:Windows 上 ``set VAR=`` 与
#: PowerShell 的 ``$env:VAR=""`` 都可能把变量整个删掉,于是回落到默认代理
#: 值,变成"去连一个本机根本不存在的端口"。给个显式关键字,配直连才可靠。
_DIRECT_KEYWORDS = frozenset({"direct", "none", "off", "no", ""})


def resolve_proxy() -> str | None:
    """解析出口地址。返回 ``None`` 表示直连。"""
    configured = getattr(config, "ANICH_RESOLVE_PROXY", None)
    if configured is None:
        return DEFAULT_PROXY or None
    value = configured.strip()
    if value.lower() in _DIRECT_KEYWORDS:
        return None
    return value


@dataclass(frozen=True)
class ResolvedAddress:
    """一次成功解析的结果。"""

    wrap_url: str
    real_url: str
    host_family: str
    expires_at: float
    """0 表示未解析到受支持的明确到期值;仍按复检周期重验。"""
    latency_ms: int


def parse_expiry(real_url: str, resolved_at: float) -> float:
    """从真实地址里读签名到期时刻;没有签名则返回 0。

    ``x-expires`` 是 Unix 秒。实测同一地址两次请求得到 ``1796373464`` 与
    ``1796373473``(相差 9 秒 = 两次请求间隔),说明它是**按请求时刻签发**
    的,不能用"看到的值"当初次签发时间,只能当绝对到期时刻用。
    """
    try:
        query = parse_qs(urlparse(real_url).query)
    except ValueError:
        return 0.0
    raw = (query.get("x-expires") or [""])[0].strip()
    if not raw.isdigit():
        return 0.0
    expires = float(raw)
    # 过期的签名仍是过期签名,不可降成 0(无签名)而被长期缓存。
    return expires if expires > 0 else 0.0


async def resolve_wrapper(
    wrap_url: str,
    *,
    proxy: str | None = None,
    timeout: float = 30.0,
    client: httpx.AsyncClient | None = None,
) -> ResolvedAddress | None:
    """经出口请求包装地址,返回 302 落点。失败返回 ``None``。

    不跟随重定向:我们要的就是 ``Location`` 本身。
    """
    if proxy is None:
        proxy = resolve_proxy()
    started = time.monotonic()
    owns_client = client is None
    if client is None:
        client = httpx.AsyncClient(
            timeout=timeout,
            follow_redirects=False,
            trust_env=False,
            proxy=proxy,
        )
    try:
        # 只取响应头,即使包装端意外返回整片也不读取响应体。
        async with client.stream("GET", wrap_url, follow_redirects=False) as response:
            status = response.status_code
            location = response.headers.get("location") or ""
    except (httpx.HTTPError, ValueError) as error:
        logger.debug("解析包装地址失败 %s: %s", _short(wrap_url), type(error).__name__)
        return None
    finally:
        if owns_client:
            await client.aclose()
    if status not in (301, 302, 303, 307, 308) or not location:
        logger.debug(
            "解析包装地址未得到重定向 %s: HTTP %s",
            _short(wrap_url),
            status,
        )
        return None
    location = urljoin(wrap_url, location)
    try:
        target = urlparse(location)
        if target.scheme not in ("http", "https") or not target.hostname or target.username or target.password:
            return None
    except ValueError:
        return None
    resolved_at = time.time()
    return ResolvedAddress(
        wrap_url=wrap_url,
        real_url=location,
        host_family=family_of(wrap_url),
        expires_at=parse_expiry(location, resolved_at),
        latency_ms=int((time.monotonic() - started) * 1000),
    )


async def probe_real_url(
    real_url: str,
    *,
    timeout: float = 25.0,
    client: httpx.AsyncClient | None = None,
) -> tuple[bool, int, str]:
    """验证真实地址能取到字节。返回 ``(可用, 延迟ms, 错误)``。

    用 GET + Range 而不是 HEAD:实测有主机 HEAD 返回 200 但 Range 请求
    超时(``p3-faceu-img-sign``),而有的主机干脆不报 ``accept-ranges``。
    只靠 HEAD 会把"看起来可用、实际播不动"的地址放进库。
    """
    started = time.monotonic()
    owns_client = client is None
    if client is None:
        # 探活走部署机直连,以验证交付地址不依赖解址代理。
        client = httpx.AsyncClient(timeout=timeout, trust_env=False)
    try:
        # Range 只是请求建议;上游忽略它时也只读取首个 1 KiB 样本并关闭连接。
        async with client.stream("GET", real_url, headers={"Range": PROBE_RANGE}) as response:
            latency = int((time.monotonic() - started) * 1000)
            if response.status_code not in (200, 206):
                return False, latency, f"HTTP {response.status_code}"
            content_type = response.headers.get("content-type", "").lower()
            if "text/html" in content_type or "application/json" in content_type:
                return False, latency, "non-media response"
            async for chunk in response.aiter_bytes(chunk_size=1024):
                if chunk:
                    if is_non_media_sample(chunk):
                        return False, latency, "non-media response"
                    return True, int((time.monotonic() - started) * 1000), ""
            return False, latency, "empty body"
    except httpx.HTTPError as error:
        return False, int((time.monotonic() - started) * 1000), type(error).__name__
    finally:
        if owns_client:
            await client.aclose()


def _short(url: str, limit: int = 70) -> str:
    """日志里只留主机与路径头,别把整条签名地址写进日志。"""
    parsed = urlparse(url)
    return f"{parsed.hostname or '?'}{parsed.path[:limit]}"


# ── 进程内缓存 ────────────────────────────────────────────────
# scraper 的 get_video_urls 契约里没有 session,不能查库;因此由后台任务
# 把表读进内存,scraper 只做同步查表。
_CACHE: dict[str, tuple[str, float]] = {}
"""包装地址 → (真实地址, 到期时刻)。"""
_CACHE_LOADED_AT: float = 0.0
_ORIGINS: dict[str, str] = {}
"""已知真实地址 → 原包装地址,用于旧播放缓存续期与降级回退。"""


def lookup_entry(wrap_url: str, *, now: float | None = None) -> tuple[str, float] | None:
    """返回仍可交付的 ``(真实地址, 签名到期时间)``。"""
    entry = _CACHE.get(wrap_url)
    if entry is None:
        return None
    real_url, expires_at = entry
    moment = time.time() if now is None else now
    if not real_url or (expires_at > 0 and expires_at <= moment + EXPIRY_SAFETY_SECONDS):
        return None
    return entry


def lookup(wrap_url: str, *, now: float | None = None) -> str | None:
    """查已解析的真实地址;没有或已临近过期则返回 ``None``。"""
    entry = lookup_entry(wrap_url, now=now)
    return entry[0] if entry else None


def origin_for(real_url: str) -> str | None:
    return _ORIGINS.get(real_url)


def cache_size() -> int:
    return len(_CACHE)


def cache_loaded_at() -> float:
    return _CACHE_LOADED_AT


def replace_cache(
    entries: dict[str, tuple[str, float]],
    *,
    origins: dict[str, str] | None = None,
) -> int:
    """整体替换可用映射,并保留有界的旧真实地址来源索引。"""
    global _CACHE, _CACHE_LOADED_AT, _ORIGINS
    previous = _ORIGINS if origins is not None else {}
    _CACHE = dict(entries)
    _ORIGINS = {**previous, **(origins or {}), **{
        real_url: wrap_url for wrap_url, (real_url, _) in entries.items() if real_url
    }}
    if len(_ORIGINS) > 8192:
        _ORIGINS = dict(list(_ORIGINS.items())[-8192:])
    _CACHE_LOADED_AT = time.time()
    return len(_CACHE)


async def load_cache_from_session(session, *, now: float | None = None) -> int:
    """从库里装载未过期的条目到内存。"""
    from sqlalchemy import select

    from .database import AniChResolvedAddress

    moment = time.time() if now is None else now
    rows = (await session.scalars(
        select(AniChResolvedAddress).execution_options(populate_existing=True)
    )).all()
    return replace_cache(
        {
            row.wrap_url: (row.real_url, row.expires_at)
            for row in rows
            if row.real_url and row.verify_ok and (
                row.expires_at <= 0 or row.expires_at > moment + EXPIRY_SAFETY_SECONDS
            )
        },
        origins={row.real_url: row.wrap_url for row in rows if row.real_url},
    )


async def resolve_many(
    wrap_urls: list[str],
    *,
    proxy: str | None = None,
    concurrency: int = _RESOLVE_CONCURRENCY,
) -> list[ResolvedAddress]:
    """批量解析,受并发闸门限制。

    出口机只有 1 vCPU,扇出会把解析全部拖成超时,所以这里刻意保守。
    """
    if proxy is None:
        proxy = resolve_proxy()
    gate = asyncio.Semaphore(max(1, concurrency))
    results: list[ResolvedAddress] = []

    async with httpx.AsyncClient(
        timeout=35.0,
        follow_redirects=False,
        trust_env=False,
        proxy=proxy,
    ) as client:

        async def one(wrap_url: str) -> None:
            async with gate:
                resolved = await resolve_wrapper(
                    wrap_url, proxy=proxy, client=client
                )
                if resolved is not None:
                    results.append(resolved)

        await asyncio.gather(*(one(item) for item in wrap_urls))
    return results