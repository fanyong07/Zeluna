"""逐站验证独立爬虫的搜索、详情、剧集和真实播放能力。

该脚本不把搜索成功当作可用。每个站点至少需要解析出媒体候选，并由
``ContentAggregator`` 完成 HLS 清单与首媒体分片验证，才记为服务端可播。

用法（在 ``server/`` 目录）：

    python tools/probe_crawlers.py
    python tools/probe_crawlers.py --source dm706 --source jibi

最终结果应以 VPS 出口运行的数据为准，本机代理或 Fake-IP 环境仅供调试。
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
from collections import Counter
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from server.aggregator import (  # noqa: E402
    CLIENT_PROBE_REQUIRED,
    SERVER_VERIFIED,
    ContentAggregator,
)


KEYWORDS = ("葬送的芙莉莲", "斗罗大陆", "咒术回战")


async def probe_source(
    aggregator: ContentAggregator,
    source_name: str,
    *,
    line_limit: int,
) -> dict[str, object]:
    scraper = aggregator._crawler_scrapers[source_name]
    started = time.monotonic()
    result: dict[str, object] = {
        "source": source_name,
        "keyword": "",
        "search": False,
        "detail": False,
        "episodes": 0,
        "candidates": 0,
        "verified": 0,
        "client_probe": 0,
        "latency": 0.0,
        "note": "",
    }
    try:
        for keyword in KEYWORDS:
            items = await scraper.search(keyword)
            if not items:
                continue
            result["search"] = True
            result["keyword"] = keyword
            for item in items[:5]:
                detail = await scraper.get_detail(item.source_id)
                if detail is None or not detail.episodes:
                    continue
                result["detail"] = True
                result["episodes"] = max(
                    int(result["episodes"]), len(detail.episodes)
                )
                first_episode = min(
                    detail.episodes,
                    key=lambda episode: episode.number,
                ).number
                lines = await scraper.get_video_urls(
                    item.source_id,
                    max(1, first_episode),
                )
                if not lines:
                    continue
                limited = lines[: max(1, line_limit)]
                result["candidates"] = int(result["candidates"]) + len(limited)
                statuses = await asyncio.gather(
                    *(aggregator._line_verification_status(line) for line in limited),
                    return_exceptions=True,
                )
                counts = Counter(
                    status for status in statuses if isinstance(status, str)
                )
                result["verified"] = int(result["verified"]) + counts[
                    SERVER_VERIFIED
                ]
                result["client_probe"] = int(result["client_probe"]) + counts[
                    CLIENT_PROBE_REQUIRED
                ]
                if result["verified"] or result["client_probe"]:
                    return result
            if result["detail"]:
                break
    except Exception as error:
        result["note"] = type(error).__name__
    finally:
        result["latency"] = round(time.monotonic() - started, 1)
    return result


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--line-limit", type=int, default=3)
    parser.add_argument("--source-timeout", type=float, default=45.0)
    args = parser.parse_args()

    aggregator = ContentAggregator()
    available = tuple(aggregator._crawler_scrapers)
    selected = tuple(dict.fromkeys(args.source)) if args.source else available
    unknown = [name for name in selected if name not in available]
    if unknown:
        await aggregator.aclose()
        parser.error(f"未知来源: {', '.join(unknown)}")

    semaphore = asyncio.Semaphore(max(1, args.concurrency))

    async def run(name: str) -> dict[str, object]:
        async with semaphore:
            try:
                return await asyncio.wait_for(
                    probe_source(
                        aggregator,
                        name,
                        line_limit=max(1, args.line_limit),
                    ),
                    timeout=max(5.0, args.source_timeout),
                )
            except TimeoutError:
                return {
                    "source": name,
                    "keyword": "",
                    "search": False,
                    "detail": False,
                    "episodes": 0,
                    "candidates": 0,
                    "verified": 0,
                    "client_probe": 0,
                    "latency": round(max(5.0, args.source_timeout), 1),
                    "note": "整站超时",
                }

    try:
        results = await asyncio.gather(*(run(name) for name in selected))
    finally:
        await aggregator.aclose()

    print(
        f"{'来源':<16} {'搜索':<4} {'详情':<4} {'集数':<6} "
        f"{'候选':<6} {'服务端':<7} {'客户端复验':<9} {'耗时':<7} 备注"
    )
    print("-" * 86)
    for result in results:
        flag = lambda value: "✓" if value else "·"
        note = str(result["note"] or result["keyword"] or "无结果")
        print(
            f"{result['source']:<16} {flag(result['search']):<4} "
            f"{flag(result['detail']):<4} {result['episodes']:<6} "
            f"{result['candidates']:<6} {result['verified']:<7} "
            f"{result['client_probe']:<9} {str(result['latency']) + 's':<7} "
            f"{note}"
        )

    playable = sum(
        1
        for result in results
        if int(result["verified"]) > 0 or int(result["client_probe"]) > 0
    )
    print(f"\n可进入生产候选的独立站点：{playable}/{len(results)}")


if __name__ == "__main__":
    asyncio.run(main())
