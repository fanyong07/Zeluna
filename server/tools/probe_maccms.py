"""Probe configured MacCMS sites from the target server egress.

Media checks deliberately reuse Zeluna's production verifier, covering public
destinations and redirects, HLS child manifests, encryption keys, first media
segments, HTML rejection and sampled direct video responses. Structured output
removes query strings so signed media parameters are not persisted.

Run from ``server/``::

    python tools/probe_maccms.py --json-output probe-results/maccms.json

Unreviewed sites are evaluated as data before the table is edited, so a new
source only enters ``maccms_sites.py`` with target-egress evidence behind it::

    python tools/probe_maccms.py --candidates candidates.json \
      --json-output probe-results/candidates.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse, urlunparse

import httpx

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from server.aggregator import (  # noqa: E402
    SERVER_VERIFIED,
    AggregatedVideoLine,
    ContentAggregator,
    LineVerificationResult,
    _is_public_http_url,
)
from server.scrapers.base import (  # noqa: E402
    INVALID_MEDIA_URL,
    PLAYER_PAGE_URL,
    classify_media_url,
    media_format_from_url,
)
from server.scrapers.maccms import parse_vod_play_url  # noqa: E402
from server.scrapers.maccms_sites import MACCMS_SITES  # noqa: E402

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

CONFIGURED_ORIGIN = "configured"
CANDIDATE_ORIGIN = "candidate"

CONFIGURED_SITES = [
    {
        **{
            key: value
            for key, value in site.items()
            if key in {"name", "api", "headers"}
        },
        "origin": CONFIGURED_ORIGIN,
    }
    for site in MACCMS_SITES
]
KEYWORDS = [("番剧", "斗罗大陆"), ("剧集", "庆余年"), ("电影", "流浪地球")]

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
_REDIRECT_STATUSES = {301, 302, 303, 307, 308}


def _redacted_url(value: str) -> str:
    try:
        parsed = urlparse(value)
    except ValueError:
        return ""
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", "", ""))


def _safe_site_headers(site: dict) -> dict[str, str]:
    return {
        str(name).strip(): str(value).strip()
        for name, value in (site.get("headers") or {}).items()
        if str(name).strip().lower() in {"referer", "origin"}
        and str(value).strip()
    }


def _normalized_api(value: str) -> str:
    try:
        parsed = urlparse(value)
    except ValueError:
        return ""
    return urlunparse((
        parsed.scheme.lower(),
        parsed.netloc.lower(),
        parsed.path.rstrip("/"),
        "",
        "",
        "",
    ))


def load_candidate_sites(path: Path) -> list[dict]:
    """Load unreviewed MacCMS candidates for a target-egress probe.

    The table in ``maccms_sites.py`` must only grow from evidence produced by
    this tool, so candidates are supplied as data instead of being edited in
    first. Entries are rejected when the API is not a public-shaped http(s)
    URL, when credentials are embedded, or when they duplicate a site the
    table already ships.
    """
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"{path}: invalid JSON ({error})") from error
    if isinstance(payload, dict):
        payload = payload.get("sites", [])
    if not isinstance(payload, list) or not payload:
        raise ValueError(f"{path}: expected a non-empty list of candidate sites")

    seen = {_normalized_api(site["api"]) for site in CONFIGURED_SITES}
    candidates: list[dict] = []
    for index, entry in enumerate(payload):
        where = f"{path}: entry {index}"
        if not isinstance(entry, dict):
            raise ValueError(f"{where}: expected an object")
        name = str(entry.get("name") or "").strip()
        api = str(entry.get("api") or "").strip()
        if not name:
            raise ValueError(f"{where}: missing 'name'")
        parsed = urlparse(api)
        if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
            raise ValueError(f"{where} ({name}): 'api' must be an http(s) URL")
        if parsed.username is not None or parsed.password is not None:
            raise ValueError(f"{where} ({name}): 'api' must not embed credentials")
        normalized = _normalized_api(api)
        if normalized in seen:
            raise ValueError(f"{where} ({name}): duplicates an already probed API")
        seen.add(normalized)
        headers = entry.get("headers")
        candidates.append({
            "name": name,
            "api": api,
            "headers": headers if isinstance(headers, dict) else {},
            "origin": CANDIDATE_ORIGIN,
        })
    return candidates


async def _fetch_json(
    client: httpx.AsyncClient,
    url: str,
    *,
    params: dict[str, object],
) -> tuple[dict | None, str]:
    """Fetch source JSON with the same public-target boundary on each hop."""
    current = str(client.build_request("GET", url, params=params).url)
    for _ in range(6):
        if not await _is_public_http_url(current):
            return None, "non_public_target"
        try:
            response = await client.get(current, follow_redirects=False)
        except httpx.TimeoutException:
            return None, "timeout"
        except httpx.HTTPError as error:
            return None, type(error).__name__
        if response.status_code in _REDIRECT_STATUSES:
            location = response.headers.get("location", "").strip()
            if not location:
                return None, "redirect_without_location"
            current = urljoin(str(response.url), location)
            continue
        if response.status_code != 200:
            return None, f"http_{response.status_code}"
        try:
            data = response.json()
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None, "invalid_json"
        return (data, "") if isinstance(data, dict) else (None, "invalid_json_shape")
    return None, "too_many_redirects"


def parse_first_media_urls(raw: str, *, limit: int = 8) -> list[dict[str, str]]:
    """Return the first episode candidate from each MacCMS play group."""
    candidates: list[dict[str, str]] = []
    for group in parse_vod_play_url(raw):
        if not group:
            continue
        url = str(group[0].get("url") or "").strip()
        classification = classify_media_url(url)
        if classification in {INVALID_MEDIA_URL, PLAYER_PAGE_URL}:
            continue
        candidates.append({
            "url": url,
            "format": media_format_from_url(url),
            "classification": classification,
        })
        if len(candidates) >= limit:
            break
    return candidates


async def verify_media_url(
    verifier: ContentAggregator,
    url: str,
    *,
    declared_format: str = "auto",
    headers: dict[str, str] | None = None,
) -> dict[str, object]:
    """Run the exact production line verifier and return redacted evidence."""
    classification = classify_media_url(url, declared_format)
    evidence: dict[str, object] = {
        "url": _redacted_url(url),
        "ok": False,
        "format": declared_format or "auto",
        "status": "unavailable",
        "error_category": "",
        "latency_ms": 0,
        "startup_profile": "unknown",
    }
    if classification in {INVALID_MEDIA_URL, PLAYER_PAGE_URL}:
        evidence["error_category"] = classification
        return evidence
    result = await verifier._line_verification_status(
        AggregatedVideoLine(
            url=url,
            format=declared_format,
            headers=dict(headers or {}),
        ),
        detailed=True,
    )
    if not isinstance(result, LineVerificationResult):
        evidence["error_category"] = "invalid_verifier_result"
        return evidence
    evidence.update({
        "ok": result.status == SERVER_VERIFIED,
        "status": result.status,
        "error_category": result.error_category,
        "latency_ms": result.latency_ms,
        "startup_profile": result.startup_profile,
    })
    return evidence


async def probe_site(
    site: dict,
    verifier: ContentAggregator,
) -> dict[str, object]:
    result: dict[str, object] = {
        "name": site["name"],
        "api": _redacted_url(site["api"]),
        "origin": site.get("origin", CONFIGURED_ORIGIN),
        "search": False,
        "detail": False,
        "playable": [],
        "checks": {},
        "latency_seconds": 0.0,
        "note": "",
    }
    started = time.monotonic()
    media_headers = _safe_site_headers(site)
    async with httpx.AsyncClient(
        headers={"User-Agent": _UA, "Accept": "application/json, */*"},
        timeout=httpx.Timeout(20, connect=8),
        follow_redirects=False,
        trust_env=False,
    ) as client:
        for label, keyword in KEYWORDS:
            label_checks: list[dict[str, object]] = []
            data, error = await _fetch_json(
                client,
                site["api"],
                params={"ac": "detail", "wd": keyword},
            )
            if data is None:
                result["note"] = error
                result["checks"][label] = label_checks
                continue
            items = data.get("list", [])
            if not isinstance(items, list) or not items:
                result["checks"][label] = label_checks
                continue
            result["search"] = True
            for item in items[:6]:
                if not isinstance(item, dict):
                    continue
                raw = str(item.get("vod_play_url") or "")
                if not raw:
                    vod_id = str(item.get("vod_id") or "")
                    if not vod_id:
                        continue
                    detail, detail_error = await _fetch_json(
                        client,
                        site["api"],
                        params={"ac": "detail", "ids": vod_id},
                    )
                    if detail is None:
                        result["note"] = detail_error
                        continue
                    detail_items = detail.get("list", [])
                    if (
                        isinstance(detail_items, list)
                        and detail_items
                        and isinstance(detail_items[0], dict)
                    ):
                        raw = str(detail_items[0].get("vod_play_url") or "")
                if not raw:
                    continue
                result["detail"] = True
                for candidate in parse_first_media_urls(raw):
                    check = await verify_media_url(
                        verifier,
                        candidate["url"],
                        declared_format=candidate["format"],
                        headers=media_headers,
                    )
                    label_checks.append(check)
                    if check["ok"]:
                        result["playable"].append(label)
                        break
                if label in result["playable"]:
                    break
            result["checks"][label] = label_checks
    result["latency_seconds"] = round(time.monotonic() - started, 1)
    return result


def build_report(
    results: list[dict[str, object]],
    *,
    candidate_count: int | None = None,
) -> dict[str, object]:
    return {
        "schema": "zeluna.maccms-probe.v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "candidate_count": (
            len(results) if candidate_count is None else candidate_count
        ),
        "target_egress": "runtime-host",
        "keywords": [{"type": label, "query": keyword} for label, keyword in KEYWORDS],
        "results": results,
    }


def write_json_report(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _flag(value: object) -> str:
    return "✓" if value else "·"


def _render_summary(results: list[dict[str, object]]) -> None:
    print(f"实测 {len(results)} 个站点，逐类验证：{[k for k, _ in KEYWORDS]}\n")
    print(
        f"{'站点':<8} {'来源':<10} {'搜索':<4} {'详情':<4} "
        f"{'可播内容类型':<16} {'耗时':<7} 备注"
    )
    print("-" * 84)
    for result in results:
        playable = "/".join(result["playable"]) or "—"
        note = "" if result["search"] else (result["note"] or "无结果")
        print(
            f"{result['name']:<8} {str(result['origin']):<10} "
            f"{_flag(result['search']):<4} {_flag(result['detail']):<4} "
            f"{playable:<16} {str(result['latency_seconds']) + 's':<7} {note}"
        )
    passed = [result for result in results if result["playable"]]
    print(f"\n至少一类完成真实媒体验证的站点：{len(passed)} 个")
    new_passed = [
        result for result in passed if result["origin"] == CANDIDATE_ORIGIN
    ]
    if new_passed:
        names = "、".join(str(result["name"]) for result in new_passed)
        print(
            f"通过实测的新候选站（仍需合规审核后才可写入 maccms_sites.py）：{names}"
        )


async def main(argv: list[str] | None = None) -> dict[str, object]:
    parser = argparse.ArgumentParser(description="Probe MacCMS sites")
    parser.add_argument(
        "--json-output",
        type=Path,
        help="Write a redacted structured result for later review",
    )
    parser.add_argument(
        "--candidates",
        type=Path,
        help=(
            "JSON file of unreviewed {name, api} sites to probe before they are "
            "considered for maccms_sites.py"
        ),
    )
    parser.add_argument(
        "--include-configured",
        action="store_true",
        help="Also re-probe the configured table when --candidates is given",
    )
    args = parser.parse_args(argv)

    sites = list(CONFIGURED_SITES)
    if args.candidates is not None:
        try:
            candidates = load_candidate_sites(args.candidates)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        sites = (
            [*CONFIGURED_SITES, *candidates]
            if args.include_configured
            else candidates
        )
    elif args.include_configured:
        parser.error("--include-configured only applies together with --candidates")

    semaphore = asyncio.Semaphore(8)
    verifier = ContentAggregator(
        crawler_scrapers={},
        enabled_provider_ids=frozenset(),
        resolver_search_enabled=False,
    )

    async def run(site: dict) -> dict[str, object]:
        async with semaphore:
            return await probe_site(site, verifier)

    try:
        results = await asyncio.gather(*(run(site) for site in sites))
    finally:
        await verifier.aclose()
    results.sort(
        key=lambda item: (
            len(item["playable"]),
            bool(item["detail"]),
            bool(item["search"]),
        ),
        reverse=True,
    )
    report = build_report(results, candidate_count=len(sites))
    _render_summary(results)
    if args.json_output is not None:
        write_json_report(args.json_output, report)
        print(f"结构化结果：{args.json_output.resolve()}")
    return report


if __name__ == "__main__":
    asyncio.run(main())
