"""把自建 CDN 包装地址解析成真实地址并落库,同时刷新进程内缓存。

分工:
  * ``anich_direct`` 只管"怎么问路"(单次解析、探活);
  * 本模块管"什么时候问、问完存哪、存完怎么让 scraper 看见"。

两条入口:
  * ``resolve_and_store`` —— 批量解析、首字节探活、原子 UPSERT、重载缓存;
  * ``refresh_expiring``   —— 重解临期、降级或超过复检周期的条目。

解析或探活失败均保留旧地址并累计 ``fail_count``;连续 3 次失败后停止参与
缓存交付。恢复成功后替换地址并清零失败计数。并发写入使用 SQLite UPSERT。
"""

from __future__ import annotations

import logging
import time

from sqlalchemy import case, select
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession

from . import anich_direct, config

logger = logging.getLogger(__name__)

#: 连续失败到这个次数就不再参与播放,等下一轮刷新窗口重解。
MAX_FAIL_COUNT = 3

_CONFLICT_TARGET = ["wrap_url"]


async def _upsert(
    session: AsyncSession,
    *,
    wrap_url: str,
    real_url: str,
    host_family: str,
    expires_at: float,
    verify_ok: bool,
    latency_ms: int,
    error: str,
    now: float,
) -> str:
    """原子写入一行。返回 ``inserted`` / ``refreshed`` / ``degraded``。"""
    from .database import AniChResolvedAddress

    statement = sqlite_insert(AniChResolvedAddress).values(
        wrap_url=wrap_url,
        real_url=real_url,
        host_family=host_family,
        resolved_at=now,
        expires_at=expires_at,
        verify_ok=verify_ok,
        verified_at=now if verify_ok else 0.0,
        fail_count=0 if verify_ok else 1,
        last_error=error[:200],
        latency_ms=latency_ms,
    )
    if verify_ok:
        # 解析成功:整行覆盖。
        statement = statement.on_conflict_do_update(
            index_elements=_CONFLICT_TARGET,
            set_={
                "real_url": real_url,
                "host_family": host_family,
                "resolved_at": now,
                "expires_at": expires_at,
                "verify_ok": True,
                "verified_at": now,
                "fail_count": 0,
                "last_error": "",
                "latency_ms": latency_ms,
            },
        )
    else:
        # 探活失败:保留旧地址(它可能只是暂时取不到),只累加并降级。
        statement = statement.on_conflict_do_update(
            index_elements=_CONFLICT_TARGET,
            set_={
                "fail_count": AniChResolvedAddress.fail_count + 1,
                "last_error": error[:200],
                "latency_ms": latency_ms,
                "verify_ok": case(
                    (
                        AniChResolvedAddress.fail_count + 1 >= MAX_FAIL_COUNT,
                        False,
                    ),
                    else_=AniChResolvedAddress.verify_ok,
                ),
            },
        )
    await session.execute(statement)
    if verify_ok:
        return "refreshed"
    return "degraded"


async def resolve_and_store(
    session: AsyncSession,
    wrap_urls: list[str],
    *,
    proxy: str | None = None,
) -> dict[str, object]:
    """解析一批包装地址:问路 → 探活 → 落库 → 刷新内存缓存。"""
    targets = [url for url in dict.fromkeys(wrap_urls) if url]
    if not targets:
        return {"requested": 0, "resolved": 0, "usable": 0, "cache_size": anich_direct.cache_size()}

    resolved = await anich_direct.resolve_many(targets, proxy=proxy)
    usable = 0
    changes = {"refreshed": 0, "degraded": 0}
    failures: list[dict[str, str]] = []

    # 网络操作先完成再写库,避免在慢探活期间长期持有 SQLite 写锁。
    observations: list[tuple[anich_direct.ResolvedAddress, bool, int, str]] = []
    for item in resolved:
        if item.expires_at > 0 and item.expires_at <= time.time() + anich_direct.EXPIRY_SAFETY_SECONDS:
            ok, latency, error = False, 0, "expired destination"
        else:
            ok, latency, error = await anich_direct.probe_real_url(item.real_url)
        usable += int(ok)
        if not ok:
            failures.append({"wrap": item.wrap_url, "error": error})
        observations.append((item, ok, latency, error))

    found = {item.wrap_url for item in resolved}
    for wrap_url in targets:
        if wrap_url in found:
            continue
        error = "wrapper resolution failed"
        failures.append({"wrap": wrap_url, "error": error})
        observations.append((anich_direct.ResolvedAddress(
            wrap_url=wrap_url, real_url="", host_family=anich_direct.family_of(wrap_url),
            expires_at=0, latency_ms=0,
        ), False, 0, error))

    for item, ok, latency, error in observations:
        action = await _upsert(
            session,
            wrap_url=item.wrap_url,
            real_url=item.real_url,
            host_family=item.host_family,
            expires_at=item.expires_at,
            verify_ok=ok,
            latency_ms=latency,
            error=error,
            now=time.time(),
        )
        changes[action] = changes.get(action, 0) + 1

    await session.commit()
    cached = await anich_direct.load_cache_from_session(session)
    logger.info(
        "AniCh 地址解析: %d 个目标 → %d 个拿到重定向, %d 个可下载, 缓存 %d 条",
        len(targets),
        len(resolved),
        usable,
        cached,
    )
    return {
        "requested": len(targets),
        "resolved": len(resolved),
        "usable": usable,
        "changes": changes,
        "failures": failures[:10],
        "cache_size": cached,
    }


async def refresh_expiring(
    session: AsyncSession,
    *,
    limit: int = 200,
    proxy: str | None = None,
) -> dict[str, object]:
    """重解临期、验证失败或超过复检周期的地址(含无签名地址)。"""
    from .database import AniChResolvedAddress

    now = time.time()
    horizon = now + anich_direct.EXPIRY_SAFETY_SECONDS * 2
    rows = (
        await session.scalars(
            select(AniChResolvedAddress)
            .where(
                (
                    (AniChResolvedAddress.expires_at > 0)
                    & (AniChResolvedAddress.expires_at <= horizon)
                )
                | AniChResolvedAddress.verify_ok.is_(False)
                | (
                    AniChResolvedAddress.verified_at
                    <= now - config.ANICH_RESOLVE_REVERIFY_SECONDS
                )
            )
            .order_by(AniChResolvedAddress.verified_at.asc())
            .limit(max(1, limit))
        )
    ).all()
    targets = [row.wrap_url for row in rows]
    if not targets:
        cached = await anich_direct.load_cache_from_session(session)
        return {"requested": 0, "cache_size": cached}
    return await resolve_and_store(session, targets, proxy=proxy)


async def warm_cache(session: AsyncSession) -> int:
    """启动时装载缓存。返回条目数。"""
    try:
        return await anich_direct.load_cache_from_session(session)
    except Exception as error:  # noqa: BLE001 - 启动阶段绝不因缓存失败而中断
        logger.warning("装载 AniCh 地址缓存失败: %s", type(error).__name__)
        return 0


def resolve_proxy() -> str | None:
    return anich_direct.resolve_proxy()


__all__ = [
    "MAX_FAIL_COUNT",
    "refresh_expiring",
    "resolve_and_store",
    "resolve_proxy",
    "warm_cache",
]