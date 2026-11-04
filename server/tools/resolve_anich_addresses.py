"""解析自建 CDN 包装地址并入库,顺带做一次端到端自检。

用法:
    python tools/resolve_anich_addresses.py                  # 续期库里待重解的条目
    python tools/resolve_anich_addresses.py --selftest       # 只检查配置与内存缓存
    python tools/resolve_anich_addresses.py URL [URL ...]    # 解析指定包装地址

为什么做成命令行而不是塞进 web 进程:解析依赖一条**独立出口**,出口是否
可用与 backend 本身无关。让运维能单独跑、单独看结果,比把网络依赖藏进
服务里更容易排查 —— web 进程只在启动时装载缓存、在后台续期。
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))

from server import anich_direct, anich_refresh  # noqa: E402
from server.database import async_session  # noqa: E402


def _print_selftest() -> None:
    proxy = anich_direct.resolve_proxy()
    print("=== 解析器配置 ===")
    print(f"  出口           : {proxy or '(直连)'}")
    print(f"  缓存条目       : {anich_direct.cache_size()}")
    loaded = anich_direct.cache_loaded_at()
    print(f"  缓存装载时间   : {loaded or '(未装载)'}")
    print(f"  过期安全余量   : {anich_direct.EXPIRY_SAFETY_SECONDS}s")
    print()
    print("=== 族判定自检 ===")
    for sample in (
        "https://v-cdn.emmmm.eu.org/video/abc",
        "https://vod-cdn.sends.eu.org.cdn.cloudflare.net/video/age_1",
        "https://example.com/x",
    ):
        print(f"  {anich_direct.family_of(sample):10s} ← {sample[:58]}")
    print()
    print("=== 签名到期解析自检 ===")
    signed = "https://p6-faceu-img-sign.byteimg.com/x?lk3s=b&x-expires=1796373464&x-signature=k"
    unsigned = "https://v16.muscdn.com/x/y.mp4"
    import time as _time
    now = _time.time()
    print(f"  带签名 → {anich_direct.parse_expiry(signed, now):.0f} (0 表示判据不成立)")
    print(f"  无签名 → {anich_direct.parse_expiry(unsigned, now):.0f} (期望 0)")


async def _selftest_cache() -> None:
    """装载缓存并打印命中情况,验证 scraper 侧的同步查表能拿到地址。"""
    async with async_session() as session:
        count = await anich_refresh.warm_cache(session)
    print(f"  装载完成,内存缓存 {count} 条")
    if count:
        from server.database import AniChResolvedAddress
        from sqlalchemy import select

        async with async_session() as session:
            rows = (
                await session.scalars(
                    select(AniChResolvedAddress)
                    .where(AniChResolvedAddress.verify_ok.is_(True))
                    .limit(3)
                )
            ).all()
        print("  抽样:")
        for row in rows:
            hit = anich_direct.lookup(row.wrap_url)
            mark = "命中" if hit else "未命中"
            print(f"    [{mark}] {row.host_family:10s} expires={row.expires_at:.0f}")
            print(f"            wrap={row.wrap_url[:70]}")
            print(f"            real={row.real_url[:70]}")


async def _resolve(urls: list[str]) -> None:
    async with async_session() as session:
        result = await anich_refresh.resolve_and_store(session, urls)
    print("=== 解析结果 ===")
    for key in ("requested", "resolved", "usable", "cache_size"):
        print(f"  {key:11s}: {result.get(key)}")
    print(f"  changes    : {result.get('changes')}")
    failures = result.get("failures") or []
    if failures:
        print("  失败明细(前 10):")
        for item in failures:
            print(f"    {item['error']:30s} {item['wrap'][:60]}")


async def _refresh() -> None:
    async with async_session() as session:
        result = await anich_refresh.refresh_expiring(session)
    print("=== 续期结果 ===")
    for key, value in result.items():
        if key == "failures":
            continue
        print(f"  {key:11s}: {value}")
    for item in result.get("failures") or []:
        print(f"    失败 {item['error']:28s} {item['wrap'][:60]}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("urls", nargs="*", help="包装地址;留空则续期库内条目")
    parser.add_argument("--selftest", action="store_true", help="只做配置与缓存自检")
    args = parser.parse_args()

    if args.selftest:
        _print_selftest()
        print()
        asyncio.run(_selftest_cache())
        return 0
    if args.urls:
        asyncio.run(_resolve(args.urls))
        return 0
    asyncio.run(_refresh())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())