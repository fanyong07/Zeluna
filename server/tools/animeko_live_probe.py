"""animeko-subs 规则库实弹巡检:搜索 → 详情 → 线路/剧集 → 播放页 → 视频地址。

这不是单元测试,而是**对着真实站点**跑一遍全链,用来回答"这 21 个源里现在到底
有几个能用"。单元测试用录制的 fixture 保证解析逻辑不回归,本工具负责暴露真实世界。

用法::

    .venv\\Scripts\\python.exe tools/animeko_live_probe.py
    .venv\\Scripts\\python.exe tools/animeko_live_probe.py --proxy http://127.0.0.1:7897
    .venv\\Scripts\\python.exe tools/animeko_live_probe.py --only xifan-dongman --verify-segment
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

import httpx

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from server.scrapers.anime.animeko import AnimekoScraper  # noqa: E402
from server.scrapers.anime.animeko_engines import (  # noqa: E402
    HttpFetcher,
    JsonApiEngine,
    SelectorEngine,
    SourceBlockedError,
    SourceUnavailableError,
    WebSubject,
)
from server.scrapers.anime.animeko_rules import (  # noqa: E402
    MediaSourceRule,
    RuleRepository,
)


@dataclass
class SourceReport:
    rule_id: str
    name: str
    factory: str
    subjects: int = 0
    chosen: str = ""
    episodes: int = 0
    channels: int = 0
    lines: int = 0
    sample_url: str = ""
    stage: str = "search"
    note: str = ""
    elapsed: float = 0.0
    media_urls: list[str] = field(default_factory=list)


def pick_subject(
    subjects: list[WebSubject], keyword: str, *, prefer_shortest: bool = True
) -> Optional[WebSubject]:
    """挑一个最可能是目标作品的条目:名字里带关键词的优先,其次取最短的。

    站点搜索会回一堆"相关推荐",直接取第一条经常是别的作品,后面几级全跟着错。
    """
    if not subjects:
        return None
    exactish = [item for item in subjects if keyword and keyword[:2] in item.name]
    pool = exactish or subjects
    if prefer_shortest:
        return min(pool, key=lambda item: len(item.name))
    return pool[0]


async def probe_rule(
    rule: MediaSourceRule,
    fetcher: HttpFetcher,
    keyword: str,
    *,
    verify_segment: bool,
) -> SourceReport:
    report = SourceReport(rule_id=rule.id, name=rule.display_name, factory=rule.factory_id)
    started = time.monotonic()
    engine: SelectorEngine | JsonApiEngine
    if rule.selector is not None:
        engine = SelectorEngine(rule, fetcher)
    elif rule.json_api is not None:
        engine = JsonApiEngine(rule, fetcher)
    else:
        report.stage = "rss"
        report.note = "RSS/BT 源,无直链播放链"
        report.elapsed = time.monotonic() - started
        return report

    try:
        subjects = await asyncio.wait_for(engine.search(keyword), timeout=40)
    except SourceBlockedError as error:
        report.stage = "blocked"
        report.note = error.reason
        report.elapsed = time.monotonic() - started
        return report
    except SourceUnavailableError as error:
        report.stage = "search"
        report.note = error.reason
        report.elapsed = time.monotonic() - started
        return report
    except asyncio.TimeoutError:
        report.stage = "search"
        report.note = "搜索超时"
        report.elapsed = time.monotonic() - started
        return report
    except Exception as error:  # noqa: BLE001 - 巡检要把任何异常都变成一行报告
        report.stage = "search"
        report.note = f"{type(error).__name__}: {error}"[:120]
        report.elapsed = time.monotonic() - started
        return report

    report.subjects = len(subjects)
    subject = pick_subject(subjects, keyword)
    if subject is None:
        report.stage = "search"
        report.note = "搜索无结果"
        report.elapsed = time.monotonic() - started
        return report
    report.chosen = subject.name
    report.stage = "detail"

    try:
        if isinstance(engine, SelectorEngine):
            episodes = await asyncio.wait_for(engine.episodes(subject.url), timeout=40)
        else:
            episodes = await asyncio.wait_for(engine.episodes(subject), timeout=40)
    except SourceBlockedError as error:
        report.stage = "detail-blocked"
        report.note = error.reason
        report.elapsed = time.monotonic() - started
        return report
    except SourceUnavailableError as error:
        report.note = error.reason
        report.elapsed = time.monotonic() - started
        return report
    except asyncio.TimeoutError:
        report.note = "详情超时"
        report.elapsed = time.monotonic() - started
        return report
    except Exception as error:  # noqa: BLE001
        report.note = f"{type(error).__name__}: {error}"[:120]
        report.elapsed = time.monotonic() - started
        return report

    report.episodes = len(episodes)
    report.channels = len({item.channel for item in episodes if item.channel})
    if not episodes:
        report.note = "详情页无可解析剧集"
        report.elapsed = time.monotonic() - started
        return report
    report.stage = "play"

    # 优先探第 1 集;有些站把整部片子当一条(sort 解析成 1),也能命中。
    first = min(episodes, key=lambda item: (item.number, item.index))
    try:
        if isinstance(engine, SelectorEngine):
            urls = await asyncio.wait_for(engine.media_urls(first.play_url), timeout=45)
        else:
            urls = await asyncio.wait_for(
                engine.media_urls(first, subject), timeout=45
            )
    except SourceBlockedError as error:
        report.stage = "play-blocked"
        report.note = error.reason
        report.elapsed = time.monotonic() - started
        return report
    except SourceUnavailableError as error:
        report.note = error.reason
        report.elapsed = time.monotonic() - started
        return report
    except asyncio.TimeoutError:
        report.note = "播放页超时"
        report.elapsed = time.monotonic() - started
        return report
    except Exception as error:  # noqa: BLE001
        report.note = f"{type(error).__name__}: {error}"[:120]
        report.elapsed = time.monotonic() - started
        return report

    report.media_urls = urls
    report.lines = len(urls)
    report.sample_url = urls[0] if urls else ""
    if not urls:
        report.note = "播放页未匹配到视频地址"
    elif verify_segment:
        report.note = await verify_first_segment(rule, fetcher, first.play_url, urls[0])
    report.elapsed = time.monotonic() - started
    if urls:
        report.stage = "ok"
    return report


async def verify_first_segment(
    rule: MediaSourceRule, fetcher: HttpFetcher, play_url: str, media_url: str
) -> str:
    """有界跟随清单并读取首段或 MP4 头部小样本,不代表完整播放验证。"""
    headers = {}
    if rule.selector is not None:
        match_video = rule.selector.match_video
        headers["Referer"] = match_video.referer.strip() or play_url
        if match_video.cookie_header:
            headers["Cookie"] = match_video.cookie_header
    from tools.media_sample import probe_media
    client = fetcher._ensure_client()  # noqa: SLF001 - 只读取有界诊断样本
    result = await probe_media(client, media_url, headers)
    hops = result.get("hops", [])
    summary = " → ".join(
        f"HTTP {hop['status']} {hop['kind']} {hop['bytes_read']}B" for hop in hops
    )
    return f"{'样本成功' if result['ok'] else '样本失败'}({result['stage']}): {summary}"


async def main() -> None:
    parser = argparse.ArgumentParser(description="animeko 规则库实弹巡检")
    parser.add_argument("--keyword", default="葬送的芙莉莲")
    parser.add_argument("--proxy", default="")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--verify-segment", action="store_true")
    parser.add_argument("--concurrency", type=int, default=6)
    parser.add_argument("--json", default="")
    args = parser.parse_args()

    client_kwargs: dict[str, object] = {
        "timeout": httpx.Timeout(args.timeout, connect=8.0),
        "follow_redirects": True,
        "headers": {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
            ),
            "Accept-Language": "zh-CN,zh;q=0.9",
        },
    }
    if args.proxy:
        client_kwargs["proxy"] = args.proxy
    client = httpx.AsyncClient(**client_kwargs)
    fetcher = HttpFetcher(client=client, timeout_seconds=args.timeout, retries=1)
    scraper = AnimekoScraper(client=client, fetcher=fetcher, enabled=True)
    try:
        rules = await scraper.rules()
        if args.only:
            wanted = set(args.only)
            rules = tuple(rule for rule in rules if rule.id in wanted)
        if not rules:
            print("规则库为空:订阅拉取失败且无本地缓存")
            return
        print(f"关键词: {args.keyword}    规则数: {len(rules)}    代理: {args.proxy or '直连'}")
        semaphore = asyncio.Semaphore(max(1, args.concurrency))

        async def guarded(rule: MediaSourceRule) -> SourceReport:
            async with semaphore:
                print(f"  → {rule.id} ...", flush=True)
                return await probe_rule(
                    rule, fetcher, args.keyword, verify_segment=args.verify_segment
                )

        reports = await asyncio.gather(*(guarded(rule) for rule in rules))
    finally:
        await scraper.aclose()
        await client.aclose()

    reports = sorted(reports, key=lambda item: (item.lines > 0, item.lines), reverse=True)
    print()
    print(
        f"{'规则':<20}{'搜索':<6}{'剧集':<6}{'线路':<6}{'取流':<6}{'耗时':<8}{'阶段':<14}备注"
    )
    print("-" * 120)
    for item in reports:
        print(
            f"{item.rule_id:<20}{item.subjects:<6}{item.episodes:<6}{item.channels:<6}"
            f"{item.lines:<6}{item.elapsed:<8.1f}{item.stage:<14}{item.note}"
        )
    ok = [item for item in reports if item.lines]
    print()
    print(f"全链跑通(取到视频地址):{len(ok)}/{len(reports)}")
    for item in ok:
        print(f"  ✓ {item.rule_id:<20} {item.chosen[:24]:<26} 线路{item.lines:<3} {item.sample_url[:80]}")
    if args.json:
        Path(args.json).write_text(
            json.dumps([asdict(item) for item in reports], ensure_ascii=False, indent=1),
            encoding="utf-8",
        )
        print(f"\n报告已写入 {args.json}")


if __name__ == "__main__":
    asyncio.run(main())
