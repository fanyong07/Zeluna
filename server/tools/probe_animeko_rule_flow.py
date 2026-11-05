"""Bounded live catalogue -> Animeko rules -> chapters -> media probe.

Run from server with DATABASE_URL=sqlite+aiosqlite:///:memory:. Only an explicitly
selected rule-cache JSON is read. run_live_flow() keeps media URLs/headers in its
return value; CLI output is a redacted summary (host, identity, URL SHA-256).
No user database, binding cache, credentials, or playback cache are read.
"""
from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import json
import logging
from pathlib import Path
import sys
import time
from urllib.parse import urlparse

# Support both import tools.probe_animeko_rule_flow and direct execution.
if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from server.aggregator import AggregatedVideoLine, ContentAggregator, SERVER_VERIFIED
from server.catalog import CatalogService
from server.database import Base, CatalogSubject
from server.scrapers.anime.animeko import AnimekoScraper
from server.scrapers.anime.animeko_rules import parse_subscription_payload


DEFAULT_RULE_IDS = (
    "xifan-dongman", "haixing-dongman", "jibi-dongman", "girigiri-ai-dongman",
)
DEFAULT_RULE_CACHE = Path(r"E:\anime\server\data\animeko\animeko_rules_cache.json")


class PublicCatalog(CatalogService):
    def _bangumi_headers(self):
        # This audit deliberately exercises anonymous/public catalogue traffic.
        return {"User-Agent": "Zeluna/1.0 (metadata aggregator)", "Accept": "application/json"}


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


@dataclass
class Candidate:
    line: AggregatedVideoLine = field(repr=False)
    evidence: dict


@dataclass
class FlowResult:
    summary: dict
    candidates: list[Candidate] = field(default_factory=list, repr=False)
    verified_candidates: list[Candidate] = field(default_factory=list, repr=False)

    @property
    def lines(self) -> list[AggregatedVideoLine]:
        return [candidate.line for candidate in self.candidates]

    def __getitem__(self, key):
        return getattr(self, key)


async def run_live_flow(
    keyword: str | None = None, catalog_context: dict | None = None,
    *, stable_id: str = "bangumi:400602", episode: int = 1,
    rule_ids: tuple[str, ...] = DEFAULT_RULE_IDS,
    rule_cache: Path = DEFAULT_RULE_CACHE,
    verify: bool = True,
) -> FlowResult:
    """Return summary/candidates/verified_candidates; URLs stay only in memory."""
    if not 1 <= len(rule_ids) <= 6 or len(set(rule_ids)) != len(rule_ids):
        raise ValueError("select one to six unique rules")
    snapshot = json.loads(rule_cache.read_text(encoding="utf-8"))
    rules_by_id = {
        rule.id: rule
        for bundle in snapshot.get("bundles", [snapshot])
        for rule in parse_subscription_payload(bundle).rules
    }
    missing = set(rule_ids) - set(rules_by_id)
    if missing:
        raise ValueError(f"rules absent from explicit cache: {sorted(missing)}")
    rules = [rules_by_id[name] for name in rule_ids]
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    catalog = PublicCatalog(session_factory=sessions)
    scraper = AnimekoScraper(rules=rules, enabled=True)
    aggregator = ContentAggregator(
        crawler_scrapers={"animeko": scraper},
        enabled_provider_ids=frozenset({"crawler.animeko"}),
        resolver_search_enabled=False,
    )
    started = time.monotonic()
    summary = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "stable_id": stable_id, "episode": episode,
        "selected_rule_ids": list(rule_ids), "database": "explicit_in_memory",
        "catalog_mode": "caller_observed_snapshot" if catalog_context is not None else "fresh_public",
        "metadata": {}, "discovery": {}, "matches": [], "routes": [],
    }
    try:
        async with asyncio.timeout(180):
            async with engine.begin() as connection:
                await connection.run_sync(Base.metadata.create_all)
            if catalog_context is not None:
                snapshot = dict(catalog_context)
                if snapshot.get("stable_id") != stable_id or not snapshot.get("detail_complete"):
                    raise ValueError("caller catalogue snapshot does not identify the requested complete subject")
                async with sessions() as session:
                    session.add(CatalogSubject(
                        stable_id=stable_id, provider=str(snapshot.get("provider") or "bangumi"),
                        provider_id=str(snapshot.get("provider_id") or stable_id.split(":")[-1]),
                        media_type=str(snapshot.get("media_type") or "anime"),
                        title=str(snapshot.get("title") or ""),
                        original_title=str(snapshot.get("original_title") or ""),
                        aliases_json=json.dumps(snapshot.get("aliases", []), ensure_ascii=False),
                        metadata_json=json.dumps(snapshot, ensure_ascii=False), updated_at=time.time(),
                    ))
                    await session.commit()
            async with sessions() as session:
                metadata = await catalog.get_subject(stable_id, session, refresh=catalog_context is None)
            if metadata is None:
                raise RuntimeError("public catalogue returned no subject")
            aliases = await catalog.playback_aliases(metadata)
            if keyword is not None and keyword not in aliases:
                raise ValueError("keyword must be a catalogue alias")
            if keyword:
                aliases = [keyword, *(alias for alias in aliases if alias != keyword)]
            year = int(str(metadata.get("date") or "0000")[:4] or 0)
            summary["metadata"] = {
                "title": metadata.get("title"), "original_title": metadata.get("original_title"),
                "date": metadata.get("date"), "media_type": metadata.get("media_type"),
                "aliases": aliases, "episode_count": len(metadata.get("episodes", [])),
            }
            matches, diagnostics = await aggregator.discover_source_matches(
                aliases, content_type="anime", year=year,
                max_matches=min(6, len(rule_ids)), include_diagnostics=True,
            )
            diagnostic = diagnostics["animeko"]
            summary["discovery"] = {
                "status": diagnostic.status.value, "queried": diagnostic.queried,
                "aliases_attempted": diagnostic.aliases_attempted,
                "search_hit_count": diagnostic.search_hit_count,
                "best_match_score": diagnostic.best_match_score,
                "elapsed_ms": diagnostic.elapsed_ms,
                "matched": diagnostic.matched, "error_category": diagnostic.error_category,
            }
            for match in matches:
                detail = await scraper.get_detail(match.source_id.split(":", 2)[2])
                summary["matches"].append({
                    "provider_id": match.provider_id, "site_name": match.site_name,
                    "rule_id": match.rule_id, "rule_name": match.rule_name,
                    "title": match.title, "year": match.year, "score": match.score,
                    "source_id_sha256": digest(match.source_id), "binding_key": match.binding_key,
                    "episode_count": len(detail.episodes) if detail else 0,
                    "requested_episode_present": any(item.number == episode for item in detail.episodes) if detail else False,
                })
            lines, health, resolution_diagnostics = await aggregator.resolve_source_matches(
                matches, episode=episode, verify=verify, include_diagnostics=True,
            )
            summary["health"] = health
            summary["resolutions"] = {
                key: {"status": value.status, "error_category": value.error_category,
                      "latency_ms": value.latency_ms, "line_count": len(value.lines)}
                for key, value in resolution_diagnostics.items()
            }
            summary["routes"] = [{
                "provider_id": line.provider_id, "site_name": line.site_name,
                "rule_id": line.rule_id, "rule_name": line.rule_name,
                "channel": line.title, "source": line.source,
                "media_host": urlparse(line.url).hostname, "media_url_sha256": digest(line.url),
                "format": line.format, "verification_status": line.verification_status,
                "startup_profile": line.startup_profile,
                "required_header_names": sorted(line.headers),
            } for line in lines]
            summary["elapsed_ms"] = int((time.monotonic() - started) * 1000)
            summary["unique_matched_sites"] = len({item.site_name for item in matches})
            summary["returned_route_count"] = len(lines)
            candidates = [Candidate(line=line, evidence={
                "provider_id": line.provider_id, "site_name": line.site_name,
                "rule_id": line.rule_id, "rule_name": line.rule_name,
                "verification_status": line.verification_status,
                "media_host": urlparse(line.url).hostname,
                "media_url_sha256": digest(line.url),
            }) for line in lines]
            return FlowResult(
                summary=summary, candidates=candidates,
                verified_candidates=[item for item in candidates if item.line.verification_status == SERVER_VERIFIED],
            )
    finally:
        await aggregator.aclose()
        await catalog.aclose()
        await engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subject", default="bangumi:400602")
    parser.add_argument("--episode", type=int, default=1)
    parser.add_argument("--rules", default=",".join(DEFAULT_RULE_IDS))
    parser.add_argument("--rule-cache", type=Path, default=DEFAULT_RULE_CACHE)
    parser.add_argument("--no-verify", action="store_true")
    args = parser.parse_args()
    # Existing adapters log upstream URLs in debug/error text; only emit our
    # explicit redacted summary from this diagnostic command.
    logging.disable(logging.CRITICAL)
    result = asyncio.run(run_live_flow(
        stable_id=args.subject, episode=args.episode,
        rule_ids=tuple(value.strip() for value in args.rules.split(",") if value.strip()),
        rule_cache=args.rule_cache, verify=not args.no_verify,
    ))
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
