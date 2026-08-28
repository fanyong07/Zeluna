"""Probe the AniCh aggregation backend from the current egress.

Structured output is sanitized: media URLs are reduced to host + classification
and captions only, so direct links are never printed or persisted.

Run from ``server/``::

    python tools/anich_probe.py --bases                 # 逐域探活
    python tools/anich_probe.py --chain 葬送的芙莉莲     # search→episodes→vod 全链路

结果仅用于人工评估与 MACCMS/probe 对照,不写库、不落直链。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.scrapers.anime.anich import AniChScraper  # noqa: E402
from server.scrapers.anime.anich_transport import (  # noqa: E402
    ANICH_FALLBACK_BASES,
    AniChTransport,
)


def _sanitize_url(url: str) -> dict:
    parsed = urlparse(url)
    return {
        "scheme": parsed.scheme,
        "host": parsed.hostname or "",
        "path_tail": (parsed.path.rsplit("/", 1) or [""])[-1][:24],
        "has_query": bool(parsed.query),
        "kind": "hls" if ".m3u8" in url.lower() else ("mp4" if ".mp4" in url.lower() else "other"),
    }


async def probe_bases(interval: float | None) -> list[dict]:
    results: list[dict] = []
    for base in ANICH_FALLBACK_BASES:
        single = AniChTransport(bases=(base,), interval=interval)
        try:
            body = await single.request("/bangumi/latest")
            alive = len(body) > 16
            error = "" if alive else "empty body"
        except Exception as error:  # noqa: BLE001 - 诊断工具要吐出全部异常形态
            alive = False
            error = f"{type(error).__name__}: {error}"[:120]
        finally:
            await single.aclose()
        results.append({"base": base, "alive": alive, "error": error})
    return results


async def probe_chain(transport: AniChTransport, keyword: str) -> dict:
    scraper = AniChScraper(transport=transport)
    report: dict = {"keyword": keyword}
    try:
        subjects = await scraper.search(keyword)
        report["search_hits"] = [
            {"source_id": s.source_id, "title": s.title[:40], "year": s.year}
            for s in subjects[:5]
        ]
        if not subjects:
            return report
        target = subjects[0]
        detail = await scraper.get_detail(target.source_id)
        report["subject"] = {
            "source_id": target.source_id,
            "title": detail.title if detail else target.title,
            "episode_count": len(detail.episodes) if detail else 0,
        }
        episode_count = len(detail.episodes) if detail else 0
        if not episode_count:
            return report
        lines = await scraper.get_video_urls(target.source_id, episode=1)
        report["first_episode_lines"] = [
            {
                "host_group": _sanitize_host(line.url),
                "quality": line.quality,
                "caption_title": line.title[:24],
                "format": line.format or "auto",
            }
            for line in lines  # 已按服务端排序分输出;直链不落盘
        ]
        report["line_cap_note"] = "已按生产配置截断"
    finally:
        await scraper.aclose()
    return report


def _sanitize_host(url: str) -> str:
    return urlparse(url).hostname or ""


async def main_async(args: argparse.Namespace) -> int:
    transport = AniChTransport(interval=args.interval)
    try:
        output: dict = {"schema_version": 1}
        if args.bases:
            output["bases"] = await probe_bases(args.interval)
        if args.chain:
            output["chain"] = await probe_chain(transport, args.chain)
        print(json.dumps(output, ensure_ascii=False, indent=2))
    finally:
        await transport.aclose()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bases", action="store_true", help="逐域探活")
    parser.add_argument("--chain", metavar="KEYWORD", help="search→episodes→vod 全链路")
    parser.add_argument("--interval", type=float, default=None, help="覆盖请求间隔秒数")
    args = parser.parse_args()
    if not args.bases and not args.chain:
        parser.error("至少指定 --bases 或 --chain")
    try:
        return asyncio.run(main_async(args))
    except KeyboardInterrupt:  # pragma: no cover
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
