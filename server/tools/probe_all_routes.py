"""Audit every registered source and every returned sample route, without promotion.

Run from server/: python tools/probe_all_routes.py --output REPORT.json
--include-candidates also probes the separate, validated candidate registry.
This does not change the production allowlist, quarantine, weights or cache.
Only source labels, media hostnames and verification states leave memory.
"""
from __future__ import annotations

import argparse
import asyncio
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import json
import logging
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from server.aggregator import AggregatedVideoLine, ContentAggregator  # noqa: E402
from server.scrapers.maccms_sites import MACCMS_SITES  # noqa: E402
from server.scrapers.tvbox_adapter import KNOWN_TVBOX_APIS  # noqa: E402
from tools.probe_maccms import load_candidate_sites  # noqa: E402


@dataclass(frozen=True)
class Sample:
    name: str
    aliases: tuple[str, ...]
    kind: str
    year: int
    episodes: tuple[int, ...]


SAMPLES = (
    Sample("庆余年", ("庆余年 第一季", "庆余年"), "series", 2019, (1, 3)),
    Sample("流浪地球", ("流浪地球",), "movie", 2019, (1,)),
    Sample("葬送的芙莉莲", ("葬送的芙莉莲", "葬送のフリーレン"), "anime", 2023, (1, 3)),
    Sample("铃芽之旅", ("铃芽之旅", "すずめの戸締まり"), "movie", 2022, (1,)),
)


def safe_label(value: object) -> str:
    text = str(value or "")
    # Never save upstream errors, raw URL-bearing labels, or header data.
    text = re.sub(r"https?://\S+", "[redacted-url]", text, flags=re.I)
    return re.sub(r"[\x00-\x1f]", " ", text)[:180]


def save_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".partial.json")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


async def verify_all_lines(aggregator, lines, semaphore, cache):
    """Do not truncate, stop on success, or collapse distinct returned identities."""
    async def check(line):
        async with semaphore:
            try:
                result = await asyncio.wait_for(
                    aggregator._line_verification_status(line, detailed=True), 26
                )
                return asdict(result)
            except TimeoutError:
                return {"status": "unavailable", "error_category": "probe_timeout"}
            except Exception as error:
                return {"status": "unavailable", "error_category": type(error).__name__}

    async def row(index, line):
        key = (line.url, line.format, tuple(sorted((line.headers or {}).items())))
        if key not in cache:
            cache[key] = asyncio.create_task(check(line))
        try:
            host = urlsplit(line.url).hostname or ""
        except ValueError:
            host = "invalid"
        result = await cache[key]
        return {
            "index": index,
            "route": safe_label(line.source),
            "label": safe_label(line.title),
            "media_host": safe_label(host),
            "verification": result,
        }

    return await asyncio.gather(*(row(i, line) for i, line in enumerate(lines)))


async def probe_sample(aggregator, scraper, name, sample, media_semaphore, cache):
    started = time.monotonic()
    row = {
        "sample": sample.name, "kind": sample.kind, "year": sample.year,
        "status": "pending", "episodes": [],
    }
    if sample.kind not in scraper.content_types:
        row["status"] = "unsupported_content_type"
        return row
    try:
        matches, diagnostics = await aggregator.discover_source_matches(
            list(sample.aliases), content_type=sample.kind, year=sample.year,
            max_matches=1000, include_diagnostics=True,
        )
        row["discovery"] = [
            {"source": safe_label(n), "status": str(d.status.value),
             "error_category": d.error_category, "queried": d.queried}
            for n, d in diagnostics.items()
        ]
        if not matches:
            row["status"] = "no_accepted_match"
            return row
        match = max(matches, key=lambda item: item.score)
        row["matched"] = {
            "title": safe_label(match.title), "kind": match.content_type,
            "year": match.year, "episode_count": match.episode_count,
        }
        source_id = match.source_id
        native_id = source_id.split(":", 2)[2] if source_id.startswith("crawler:") else source_id
        detail = await asyncio.wait_for(scraper.get_detail(native_id), 20)
        row["detail_success"] = detail is not None
        if detail is None or not detail.episodes:
            row["status"] = "detail_or_episodes_missing"
            return row
        row["detail_episode_count"] = len(detail.episodes)
        numbers = {ep.number for ep in detail.episodes}
        for episode in sample.episodes:
            ep_row = {"episode": episode, "lines": [], "status": "pending"}
            row["episodes"].append(ep_row)
            if episode not in numbers:
                ep_row["status"] = "episode_missing"
                continue
            try:
                # Use the source adapter directly: the public aggregator's URL
                # deduplication must not hide distinct returned line identities.
                lines = await asyncio.wait_for(scraper.get_video_urls(native_id, episode), 45)
                converted = [AggregatedVideoLine(
                    url=line.url, title=line.title, format=line.format,
                    source=line.source_name or name, headers=dict(line.headers),
                ) for line in lines]
                ep_row["lines"] = await verify_all_lines(
                    aggregator, converted, media_semaphore, cache,
                )
                ep_row["status"] = "checked" if lines else "no_media_candidates"
            except TimeoutError:
                ep_row["status"] = "resolve_timeout"
            except Exception as error:
                ep_row["status"] = type(error).__name__
        row["status"] = "checked"
    except TimeoutError:
        row["status"] = "timeout"
    except Exception as error:
        row["status"] = type(error).__name__
    finally:
        row["elapsed_seconds"] = round(time.monotonic() - started, 2)
    return row


async def audit(args):
    inventory = ContentAggregator(resolver_search_enabled=False)
    crawler_names = tuple(inventory._crawler_scrapers)
    await inventory.aclose()
    sites = [("configured", dict(site)) for site in MACCMS_SITES]
    if args.include_candidates:
        sites.extend(("candidate", site) for site in load_candidate_sites(
            ROOT / "data/maccms_candidates.json"
        ))
    tasks = ([("crawler", name) for name in crawler_names] + sites
             + [("tvbox_compatibility", dict(site)) for site in KNOWN_TVBOX_APIS])
    if args.source:
        tasks = [(group, spec) for group, spec in tasks if
                 (spec if isinstance(spec, str) else spec["name"]) in args.source]
        if not tasks:
            raise ValueError("No matching sources")
    report = {
        "schema": "zeluna.all-route-audit.v1", "started_utc": datetime.now(timezone.utc).isoformat(),
        "egress": args.egress, "source_revision": args.revision,
        "scope": "all inventoried sources and ALL adapter-returned routes for four real works and episodes 1/3; not full-catalog or client decoding proof",
        "configuration_mutated": False, "automatic_promotion": False,
        "expected_sources": len(tasks), "sources": [],
        "compatibility_providers": {
            "aggregate.tvbox": "five legacy endpoints audited separately; production provider remains disabled",
            "aggregate.vod": "legacy metadata/resolver adapter not participating in discover_source_matches; production disabled",
        },
    }
    save_report(args.output, report)
    sources_sem = asyncio.Semaphore(args.concurrency)
    media_sem = asyncio.Semaphore(args.media_concurrency)

    async def run(group, spec):
        async with sources_sem:
            if group == "crawler":
                name = spec
                agg = ContentAggregator(
                    enabled_provider_ids=frozenset({f"crawler.{name}"}), resolver_search_enabled=False,
                )
                scraper = agg._crawler_scrapers[name]
                record = {"group": group, "name": name, "samples": []}
            elif group == "tvbox_compatibility":
                name = spec["name"]
                agg = ContentAggregator(crawler_scrapers={},
                    enabled_provider_ids=frozenset({"aggregate.tvbox"}), resolver_search_enabled=False)
                scraper = agg._tvbox
                scraper._source_configs = {name: spec}
                scraper._healthy_sources = [name]
                scraper._last_health_check = time.time()
                record = {"group": group, "name": name, "runtime_enabled": False, "samples": []}
            else:
                name = spec["name"]
                agg = ContentAggregator(crawler_scrapers={},
                    enabled_provider_ids=frozenset({"aggregate.maccms"}), resolver_search_enabled=False)
                # Isolated audit instance only; original dictionaries/config unchanged.
                isolated = dict(spec, enabled=True, quick=True, tier="core")
                agg._maccms._sites = [isolated]
                scraper = agg._maccms
                record = {"group": group, "name": name,
                          "runtime_enabled": spec.get("enabled") is True, "samples": []}
            report["sources"].append(record)
            cache = {}
            try:
                for sample in SAMPLES:
                    record["samples"].append(await probe_sample(
                        agg, scraper, name, sample, media_sem, cache,
                    ))
                    save_report(args.output, report)
                record["completed"] = True
            except Exception as error:
                record["error"] = type(error).__name__
            finally:
                await agg.aclose()
                save_report(args.output, report)
                print(json.dumps({"source": name, "group": group,
                      "completed": sum(bool(s.get("completed")) for s in report["sources"]),
                      "expected": len(tasks)}, ensure_ascii=False), flush=True)

    await asyncio.gather(*(run(group, spec) for group, spec in tasks))
    lines = [line for source in report["sources"] for sample in source["samples"]
             for episode in sample["episodes"] for line in episode["lines"]]
    report["summary"] = {
        "sources_completed": sum(bool(s.get("completed")) for s in report["sources"]),
        "source_groups": dict(Counter(s["group"] for s in report["sources"])),
        "sample_statuses": dict(Counter(c["status"] for s in report["sources"] for c in s["samples"])),
        "returned_routes": len(lines),
        "verification": dict(Counter(line["verification"]["status"] for line in lines)),
    }
    report["completed_utc"] = datetime.now(timezone.utc).isoformat()
    save_report(args.output, report)
    print(json.dumps(report["summary"], ensure_ascii=False), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include-candidates", action="store_true")
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--egress", required=True)
    parser.add_argument("--revision", default="dirty-worktree")
    parser.add_argument("--concurrency", type=int, default=3)
    parser.add_argument("--media-concurrency", type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.concurrency <= 8 or not 1 <= args.media_concurrency <= 8:
        parser.error("concurrency must be between 1 and 8")
    if args.output.exists():
        parser.error("refusing to overwrite an existing audit")
    logging.disable(logging.CRITICAL)
    asyncio.run(audit(args))


if __name__ == "__main__":
    main()
