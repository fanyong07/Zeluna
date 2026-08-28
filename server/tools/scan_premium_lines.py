"""扫描一批作品,把见到的高画质档登记进清单。

清单只存元数据(作品/集数/画质档/来源标识/媒体主机/路径摘要),不存可播地址
——这类直链天级失效,存下来等要用时多半已经 404。真正下载前用
``tools/resolve_premium_line.py`` 现场重新取址。

从 ``server/`` 运行::

    # 扫当季热门(默认取上游最新列表的前 N 部)
    python tools/scan_premium_lines.py --latest 20 --episodes 1

    # 扫指定作品
    python tools/scan_premium_lines.py --title 葬送的芙莉莲 --title 咒术回战

    # 每部多扫几集
    python tools/scan_premium_lines.py --latest 10 --episodes 3

节流沿用适配器内置的串行间隔,不并发轰上游。
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.database import async_session  # noqa: E402
from server.premium_catalog import (  # noqa: E402
    build_record,
    is_premium_quality,
    record_premium_line,
)
from server.scrapers.anime.anich import AniChScraper  # noqa: E402


async def scan_subject(
    scraper: AniChScraper,
    *,
    title: str,
    episodes: int,
    session,
    verbose: bool = True,
) -> tuple[int, int]:
    """→ (登记条数, 新建条数)"""
    hits = await scraper.search(title)
    if not hits:
        if verbose:
            print(f"  {title[:24]:<26} 搜索无结果")
        return 0, 0
    subject = hits[0]
    stable_id = f"anich:{subject.source_id}"
    logged = created = 0

    for episode in range(1, max(1, episodes) + 1):
        try:
            lines = await scraper.get_video_urls(subject.source_id, episode)
        except Exception as error:  # noqa: BLE001
            if verbose:
                print(f"  {subject.title[:20]:<22} 第{episode}集 取流失败 "
                      f"{type(error).__name__}")
            continue
        premium = [line for line in lines if is_premium_quality(line.quality)]
        for line in premium:
            record = build_record(
                subject_stable_id=stable_id,
                episode=episode,
                url=line.url,
                quality_label=line.quality,
                source_tag=line.source_name,
                provider_id="crawler.anich",
                subject_title=subject.title,
                container=line.format or "",
                reachable=False,          # 扫描阶段不逐条探活,避免打洪峰
                note="scan_premium_lines",
            )
            if record is None:
                continue
            logged += 1
            if await record_premium_line(session, record):
                created += 1
        if verbose:
            qualities = sorted({line.quality for line in premium if line.quality})
            print(
                f"  {subject.title[:20]:<22} 第{episode}集  "
                f"线路{len(lines):>3}  高画质{len(premium):>3}  "
                f"{'/'.join(q[:12] for q in qualities[:4])}"
            )
    await session.commit()
    return logged, created


async def main_async(args: argparse.Namespace) -> int:
    scraper = AniChScraper()
    titles: list[str] = list(args.title or [])

    try:
        if args.latest:
            latest = await scraper.get_latest()
            for item in latest[: args.latest]:
                if item.title and item.title not in titles:
                    titles.append(item.title)
            print(f"从上游最新列表取到 {len(titles)} 部作品\n")

        if not titles:
            print("没有要扫的作品。用 --latest N 或 --title <作品名>")
            return 2

        print(f"{'作品':<24}{'集':<8}{'线路':>5}{'高画质':>7}  画质档")
        print("-" * 74)
        total_logged = total_created = 0
        started = time.monotonic()

        async with async_session() as session:
            for title in titles:
                logged, created = await scan_subject(
                    scraper,
                    title=title,
                    episodes=args.episodes,
                    session=session,
                )
                total_logged += logged
                total_created += created

        elapsed = time.monotonic() - started
        print("\n" + "=" * 74)
        print(f"扫描 {len(titles)} 部 × {args.episodes} 集,耗时 {elapsed:.0f}s")
        print(f"登记高画质线路 {total_logged} 条(其中新建 {total_created} 条)")
        print("\n查看清单: python tools/export_premium_catalog.py --format table")
        print("取真实地址: python tools/resolve_premium_line.py --subject <id> --episode <n>")
    finally:
        await scraper.aclose()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--latest", type=int, default=0, help="从上游最新列表取前 N 部"
    )
    parser.add_argument(
        "--title", action="append", help="指定作品名(可重复)"
    )
    parser.add_argument("--episodes", type=int, default=1, help="每部扫前几集")
    args = parser.parse_args()
    try:
        return asyncio.run(main_async(args))
    except KeyboardInterrupt:  # pragma: no cover
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
