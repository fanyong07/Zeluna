"""Kazumi 规则库活跃规则的联网实测脚本(离线可重复,不写库、不改状态)。

用途:对 18 条活跃规则逐条跑"搜索 → 章节 → 播放地址",把真实结果打印出来
并按类别统计成功率。失败逐条隔离,单条规则异常不影响其它规则。

用法::

    $env:PYTHONIOENCODING="utf-8"
    .venv\\Scripts\\python.exe tools\\kazumi_live_probe.py [关键词] [--json 输出路径]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from server.scrapers.anime.kazumi import (  # noqa: E402
    KazumiRuleEngine,
    KazumiScraper,
    split_source_id,
)
from server.scrapers.anime.kazumi_rules import KazumiRule  # noqa: E402

DEFAULT_KEYWORD = "葬送的芙莉莲"


@dataclass
class RuleProbe:
    """单条规则的实测结果。"""

    rule: str = ""
    base_url: str = ""
    search_mode: str = ""
    chapter_mode: str = ""
    search_ok: bool = False
    search_count: int = 0
    search_error: str = ""
    sample_titles: list[str] = field(default_factory=list)
    detail_url: str = ""
    chapter_ok: bool = False
    chapter_count: int = 0
    chapter_error: str = ""
    sample_episodes: list[str] = field(default_factory=list)
    video_lines: int = 0
    seconds: float = 0.0


#: 单条规则单次调用的墙钟上限。国内出口到这批站的 RTT 波动很大,给宽松值,
#: 否则"慢"会被误记成"失败"。
PER_RULE_TIMEOUT_SECONDS = 60.0


async def probe_rule(scraper: KazumiScraper, rule: KazumiRule, keyword: str) -> RuleProbe:
    """跑一条规则的完整链路,任何异常都收敛成字符串而不是抛出。"""
    result = RuleProbe(
        rule=rule.name,
        base_url=rule.base_url,
        search_mode=rule.search_mode,
        chapter_mode=rule.chapter_mode,
    )
    engine = KazumiRuleEngine(rule, max_results=30)
    started = time.monotonic()

    pairs: list[tuple[Any, str]] = []
    try:
        pairs = await asyncio.wait_for(
            engine.search(scraper._fetcher_for(rule), keyword), timeout=PER_RULE_TIMEOUT_SECONDS
        )
        result.search_ok = bool(pairs)
        result.search_count = len(pairs)
        result.sample_titles = [subject.title for subject, _ in pairs[:3]]
    except Exception as error:  # noqa: BLE001 - 实测脚本就是要收敛所有异常
        result.search_error = f"{type(error).__name__}: {error}"[:200]

    detail_url = ""
    for _subject, candidate in pairs:
        if candidate:
            detail_url = candidate
            break
    result.detail_url = detail_url

    # 章节链路走**爬虫的公开方法** get_detail,而不是直接调引擎:接口式规则的
    # 章节请求要用站内 ID 填 @source,而"站内 ID 从哪来"这部分逻辑在
    # KazumiScraper 里(引擎只认 detail_url)。绕过去测出的数字是假的
    # —— 实测过:直接调 engine.chapters 时 giriGiriLove 记成 0 章节,
    # 走 get_detail 实际有 20 集。
    if pairs:
        subject, _ = pairs[0]
        result.detail_url = result.detail_url or subject.source_id
        try:
            detail = await asyncio.wait_for(
                scraper.get_detail(subject.source_id),
                timeout=PER_RULE_TIMEOUT_SECONDS,
            )
            episodes = detail.episodes if detail is not None else []
            result.chapter_ok = bool(episodes)
            result.chapter_count = len(episodes)
            result.sample_episodes = [
                f"{item.number}:{item.title}" for item in episodes[:3]
            ]
        except Exception as error:  # noqa: BLE001
            result.chapter_error = f"{type(error).__name__}: {error}"[:200]

    # 播放地址链路:验证"规则库拿不到直链"这个结论在运行期是否成立。
    if pairs:
        subject_id = pairs[0][0].source_id
        try:
            lines = await scraper.get_video_urls(subject_id, 1)
            result.video_lines = len(lines)
        except Exception as error:  # noqa: BLE001
            result.chapter_error = result.chapter_error or f"video: {type(error).__name__}"

    result.seconds = round(time.monotonic() - started, 2)
    return result


async def main() -> int:
    parser = argparse.ArgumentParser(description="Kazumi 规则联网实测")
    parser.add_argument("keyword", nargs="?", default=DEFAULT_KEYWORD)
    parser.add_argument("--json", dest="json_out", default="")
    parser.add_argument("--interval", type=float, default=0.4)
    parser.add_argument("--timeout", type=float, default=12.0)
    args = parser.parse_args()

    scraper = KazumiScraper(
        enabled=True,
        min_interval=args.interval,
        timeout=args.timeout,
        max_results_per_rule=30,
    )
    rules = scraper.rules
    print(f"规则目录: {scraper._rules_dir}")
    print(f"活跃规则: {len(rules)} 条")
    print(f"关键词: {args.keyword!r}")
    print("=" * 100)

    probes: list[RuleProbe] = []
    for index, rule in enumerate(rules, 1):
        print(f"[{index:2}/{len(rules)}] {rule.name:<14} ...", end="", flush=True)
        probe = await probe_rule(scraper, rule, args.keyword)
        probes.append(probe)
        flag = "搜索OK" if probe.search_ok else "搜索失败"
        chap = f"章节{probe.chapter_count}" if probe.chapter_ok else "章节失败"
        print(
            f" {flag} {probe.search_count:>2} 条 | {chap} | "
            f"直链 {probe.video_lines} | {probe.seconds}s"
            + (f" | {probe.search_error}" if probe.search_error else "")
        )

    # 端到端:走地对聚合入口跑一次整体搜索,验证失败隔离与汇总。
    print("=" * 100)
    started = time.monotonic()
    aggregated = await scraper.search(args.keyword)
    elapsed = round(time.monotonic() - started, 2)
    by_rule: dict[str, int] = {}
    for subject in aggregated:
        rule_name, _ = split_source_id(subject.source_id)
        by_rule[rule_name] = by_rule.get(rule_name, 0) + 1

    search_ok = [p for p in probes if p.search_ok]
    chapter_ok = [p for p in probes if p.chapter_ok]
    full_ok = [p for p in probes if p.search_ok and p.chapter_ok]

    print(f"聚合 search() 返回 {len(aggregated)} 条 / {elapsed}s,覆盖 {len(by_rule)} 条规则")
    print()
    print(f"搜索成功 : {len(search_ok)}/{len(probes)}  ->  "
          + ", ".join(p.rule for p in search_ok))
    print(f"章节成功 : {len(chapter_ok)}/{len(probes)}  ->  "
          + ", ".join(p.rule for p in chapter_ok))
    print(f"全链成功 : {len(full_ok)}/{len(probes)}  ->  "
          + ", ".join(p.rule for p in full_ok))
    print()
    print("失败明细:")
    for probe in probes:
        if probe.search_ok and probe.chapter_ok:
            continue
        reasons = []
        if not probe.search_ok:
            reasons.append(f"搜索: {probe.search_error or '0 命中'}")
        elif not probe.chapter_ok:
            reasons.append(f"章节: {probe.chapter_error or '0 章节'}")
        print(f"  {probe.rule:<14} {'; '.join(reasons)}")

    await scraper.aclose()

    if args.json_out:
        payload = {
            "keyword": args.keyword,
            "total": len(probes),
            "search_ok": [p.rule for p in search_ok],
            "chapter_ok": [p.rule for p in chapter_ok],
            "full_ok": [p.rule for p in full_ok],
            "probes": [asdict(probe) for probe in probes],
        }
        Path(args.json_out).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"\nJSON 报告: {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
