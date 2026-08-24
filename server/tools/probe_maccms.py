"""Probe configured MacCMS sites from the target server egress.

Media checks deliberately reuse Zeluna's production verifier, covering public
destinations and redirects, HLS child manifests, encryption keys, first media
segments, HTML rejection and sampled direct video responses. Structured output
removes query strings so signed media parameters are not persisted.

Run from ``server/``::

    python tools/probe_maccms.py --json-output probe-results/maccms.json

Run the 48-case anime / TV / movie coverage benchmark::

    python tools/probe_maccms.py --profile coverage \
      --json-output probe-results/coverage.json

Unreviewed sites are evaluated as data before the table is edited. The
promotion profile runs Smoke and Coverage but still requires human review::

    python tools/probe_maccms.py --candidates \
      --profile promotion --json-output probe-results/candidates.json
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import re
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
    CLIENT_PROBE_REQUIRED,
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
from server.scrapers.maccms import (  # noqa: E402
    episode_from_group,
    episode_number_from_label,
    media_type_from_name,
    parse_vod_play_url,
    year_from_value,
)
from server.scrapers.maccms_sites import MACCMS_SITES  # noqa: E402
from server.title_matching import SourceMatchAnalysis, analyze_source_match  # noqa: E402
from tools.maccms_coverage import (  # noqa: E402
    DEFAULT_CANDIDATE_REGISTRY_PATH,
    DEFAULT_COVERAGE_CASES_PATH,
    CoverageCase,
    build_coverage_kpis,
    build_legacy_coverage_baselines,
    build_source_promotion_pipeline,
    load_coverage_cases,
    recommend_source_tier,
    summarize_source_coverage,
)

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

CONFIGURED_ORIGIN = "configured"
CANDIDATE_ORIGIN = "candidate"
CANDIDATE_REGISTRY_SCHEMA = "zeluna.maccms-candidates.v1"
_CANDIDATE_REGISTRY_FIELDS = {
    "schema",
    "generated_on",
    "source_document",
    "policy",
    "source_references",
    "sites",
}
_CANDIDATE_SITE_FIELDS = {
    "name",
    "api",
    "discovered_from",
    "review_status",
    "notes",
    "headers",
}
_FIXED_GITHUB_BLOB_PATH = re.compile(
    r"^/[^/]+/[^/]+/blob/[0-9a-fA-F]{40}/.+$"
)

CONFIGURED_SITES = [
    {
        **{
            key: value
            for key, value in site.items()
            if key in {
                "name",
                "api",
                "headers",
                "enabled",
                "tier",
                "quick",
                "precache",
                "weight",
                "content_types",
            }
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
_DETERMINISTIC_COVERAGE_FAILURES = {
    "invalid_media_url",
    "malformed_manifest",
    "non_public_target",
    "player_page",
    "stale_route",
}


def _redacted_url(value: str) -> str:
    try:
        parsed = urlparse(value)
    except ValueError:
        return ""
    return urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", "", ""))


def _is_fixed_github_blob_url(value: object) -> bool:
    parsed = urlparse(str(value or "").strip())
    return (
        parsed.scheme.lower() == "https"
        and str(parsed.hostname or "").casefold() == "github.com"
        and parsed.username is None
        and parsed.password is None
        and not parsed.query
        and not parsed.fragment
        and _FIXED_GITHUB_BLOB_PATH.fullmatch(parsed.path) is not None
    )


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
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected a candidate registry object")
    unknown_registry_fields = sorted(set(payload) - _CANDIDATE_REGISTRY_FIELDS)
    if unknown_registry_fields:
        raise ValueError(
            f"{path}: unsupported registry fields: "
            f"{', '.join(unknown_registry_fields)}"
        )
    if payload.get("schema") != CANDIDATE_REGISTRY_SCHEMA:
        raise ValueError(f"{path}: unsupported candidate registry schema")
    if not str(payload.get("generated_on") or "").strip():
        raise ValueError(f"{path}: missing generated_on")
    if not str(payload.get("source_document") or "").strip():
        raise ValueError(f"{path}: missing source_document")
    source_references = payload.get("source_references")
    if not isinstance(source_references, dict):
        raise ValueError(f"{path}: source_references must be an object")
    for reference_name, reference_value in source_references.items():
        if (
            not str(reference_name or "").strip()
            or not _is_fixed_github_blob_url(reference_value)
        ):
            raise ValueError(
                f"{path}: source_references must use fixed GitHub blob commits"
            )
    policy = payload.get("policy")
    if not isinstance(policy, dict):
        raise ValueError(f"{path}: policy must be an object")
    required_policy = {
        "logical_candidate_count",
        "excluded_mirror_alias_count",
        "production_table_separate",
        "automatic_promotion",
    }
    if set(policy) != required_policy:
        raise ValueError(f"{path}: candidate registry policy fields are invalid")
    payload_sites = payload.get("sites")
    if not isinstance(payload_sites, list) or not payload_sites:
        raise ValueError(f"{path}: expected a non-empty list of candidate sites")
    logical_count = policy.get("logical_candidate_count")
    excluded_mirrors = policy.get("excluded_mirror_alias_count")
    if type(logical_count) is not int or logical_count != len(payload_sites):
        raise ValueError(f"{path}: logical_candidate_count does not match sites")
    if type(excluded_mirrors) is not int or excluded_mirrors < 0:
        raise ValueError(f"{path}: excluded_mirror_alias_count is invalid")
    if policy.get("production_table_separate") is not True:
        raise ValueError(f"{path}: candidates must stay outside production")
    if policy.get("automatic_promotion") is not False:
        raise ValueError(f"{path}: automatic candidate promotion is forbidden")

    seen = {_normalized_api(site["api"]) for site in CONFIGURED_SITES}
    seen_hosts = {
        str(urlparse(site["api"]).hostname or "").strip().casefold()
        for site in CONFIGURED_SITES
    }
    seen_names: set[str] = set()
    candidates: list[dict] = []
    for index, entry in enumerate(payload_sites):
        where = f"{path}: entry {index}"
        if not isinstance(entry, dict):
            raise ValueError(f"{where}: expected an object")
        unknown_site_fields = sorted(set(entry) - _CANDIDATE_SITE_FIELDS)
        if unknown_site_fields:
            raise ValueError(
                f"{where}: unsupported candidate fields: "
                f"{', '.join(unknown_site_fields)}"
            )
        missing_site_fields = sorted(
            {"name", "api", "discovered_from", "review_status", "notes"}
            - set(entry)
        )
        if missing_site_fields:
            raise ValueError(
                f"{where}: missing candidate fields: "
                f"{', '.join(missing_site_fields)}"
            )
        name = str(entry.get("name") or "").strip()
        api = str(entry.get("api") or "").strip()
        if not name:
            raise ValueError(f"{where}: missing 'name'")
        normalized_name = name.casefold()
        if normalized_name in seen_names:
            raise ValueError(f"{where} ({name}): duplicate candidate name")
        seen_names.add(normalized_name)
        parsed = urlparse(api)
        if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
            raise ValueError(f"{where} ({name}): 'api' must be an http(s) URL")
        if parsed.username is not None or parsed.password is not None:
            raise ValueError(f"{where} ({name}): 'api' must not embed credentials")
        if parsed.query or parsed.fragment:
            raise ValueError(f"{where} ({name}): 'api' must not contain a query")
        host = parsed.hostname.strip().casefold()
        if host == "localhost" or host.endswith((".localhost", ".local")):
            raise ValueError(f"{where} ({name}): 'api' host is not public-shaped")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise ValueError(f"{where} ({name}): IP-literal APIs are forbidden")
        normalized = _normalized_api(api)
        if normalized in seen:
            raise ValueError(f"{where} ({name}): duplicates an already probed API")
        if host in seen_hosts:
            raise ValueError(f"{where} ({name}): duplicate candidate host")
        seen.add(normalized)
        seen_hosts.add(host)
        discovered_from = str(entry.get("discovered_from") or "").strip()
        review_status = str(entry.get("review_status") or "").strip()
        if not discovered_from:
            raise ValueError(f"{where} ({name}): missing discovered_from")
        if not _is_fixed_github_blob_url(discovered_from):
            raise ValueError(
                f"{where} ({name}): discovered_from must use a fixed "
                "GitHub blob commit"
            )
        if review_status != "candidate":
            raise ValueError(f"{where} ({name}): review_status must be candidate")
        headers = entry.get("headers")
        if headers is not None and not isinstance(headers, dict):
            raise ValueError(f"{where} ({name}): headers must be an object")
        if isinstance(headers, dict):
            forbidden_headers = [
                str(name)
                for name in headers
                if str(name).strip().lower() not in {"referer", "origin"}
            ]
            if forbidden_headers:
                raise ValueError(
                    f"{where} ({name}): candidate headers may only contain "
                    "Referer or Origin"
                )
            for header_name, header_value in headers.items():
                parsed_header = urlparse(str(header_value or "").strip())
                if (
                    parsed_header.scheme.lower() not in {"http", "https"}
                    or not parsed_header.hostname
                    or parsed_header.username is not None
                    or parsed_header.password is not None
                    or parsed_header.query
                    or parsed_header.fragment
                ):
                    raise ValueError(
                        f"{where} ({name}): {header_name} is not a safe URL"
                    )
        candidates.append({
            "name": name,
            "api": api,
            "headers": headers if isinstance(headers, dict) else {},
            "origin": CANDIDATE_ORIGIN,
            "discovered_from": discovered_from,
            "review_status": review_status,
            "notes": str(entry.get("notes") or "").strip(),
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


async def probe_coverage_case(
    site: dict,
    case: CoverageCase,
    verifier: ContentAggregator,
    client: httpx.AsyncClient,
) -> dict[str, object]:
    """Exercise search, match, detail, episode mapping, and media verification."""
    result: dict[str, object] = {
        "case_id": case.case_id,
        "subject_id": case.subject_id or case.case_id,
        "sample_kind": case.sample_kind,
        "content_type": case.content_type,
        "year": case.year,
        "episode": case.episode,
        "tags": list(case.tags),
        "aliases_attempted": 0,
        "search_responded": False,
        "search_hit": False,
        "accepted_match": False,
        "matched_title": "",
        "matched_score": None,
        "matched_alias": "",
        "matched_alias_index": None,
        "matched_content_type": "unknown",
        "matched_year": 0,
        "wrong_match": None,
        "season_conflict": None,
        "detail_success": False,
        "episode_found": False,
        "episode_labels": [],
        "episode_mapping_modes": [],
        "wrong_episode": None,
        "server_verified": False,
        "client_probe_required": False,
        "route_unavailable": False,
        "deterministic_failure": False,
        "search_latency_ms": 0,
        "verify_latency_ms": 0,
        "media_hosts": [],
        "verified_media_hosts": [],
        "checks": [],
        "error_category": "",
    }
    search_started = time.monotonic()
    accepted: list[tuple[int, int, dict, SourceMatchAnalysis]] = []
    search_errors: list[str] = []
    for alias_index, alias in enumerate(case.search_aliases):
        result["aliases_attempted"] += 1
        data, error = await _fetch_json(
            client,
            site["api"],
            params={"ac": "detail", "wd": alias},
        )
        if data is None:
            if error:
                search_errors.append(error)
            continue
        result["search_responded"] = True
        items = data.get("list", [])
        if not isinstance(items, list) or not items:
            continue
        result["search_hit"] = True
        for item in items[:15]:
            if not isinstance(item, dict):
                continue
            title = str(item.get("vod_name") or "").strip()
            vod_id = str(item.get("vod_id") or "").strip()
            if not title or not vod_id:
                continue
            analysis = analyze_source_match(
                title,
                list(case.search_aliases),
                candidate_type=media_type_from_name(
                    str(item.get("type_name") or "")
                ),
                expected_type=case.content_type,
                candidate_year=year_from_value(item.get("vod_year")),
                expected_year=case.year,
            )
            if analysis.accepted:
                accepted.append((
                    analysis.ranking_score,
                    alias_index,
                    item,
                    analysis,
                ))
        if accepted:
            break
    result["search_latency_ms"] = max(
        0,
        int((time.monotonic() - search_started) * 1000),
    )
    if not accepted:
        result["error_category"] = (
            "search_hit_no_match"
            if result["search_hit"]
            else search_errors[-1]
            if search_errors
            else "search_miss"
        )
        return result

    score, alias_index, matched, analysis = max(
        accepted,
        key=lambda pair: pair[0],
    )
    result["accepted_match"] = True
    result["matched_title"] = str(matched.get("vod_name") or "").strip()
    result["matched_score"] = score
    result["matched_alias"] = case.search_aliases[alias_index]
    result["matched_alias_index"] = alias_index
    result["matched_content_type"] = media_type_from_name(
        str(matched.get("type_name") or "")
    )
    result["matched_year"] = year_from_value(matched.get("vod_year"))
    evidence = analysis.evidence
    result["season_conflict"] = evidence.season_conflict
    if (
        evidence.season_conflict
        or (evidence.media_type_known and not evidence.media_type_match)
        or (evidence.year_known and not evidence.year_compatible)
    ):
        result["wrong_match"] = True
    elif evidence.allows_circuit_recovery:
        result["wrong_match"] = False
    vod_id = str(matched.get("vod_id") or "").strip()
    detail, detail_error = await _fetch_json(
        client,
        site["api"],
        params={"ac": "detail", "ids": vod_id},
    )
    if detail is None:
        result["error_category"] = detail_error or "detail_error"
        return result
    detail_items = detail.get("list", [])
    if not isinstance(detail_items, list) or not detail_items:
        result["error_category"] = "detail_miss"
        return result
    detail_item = next(
        (
            item
            for item in detail_items
            if isinstance(item, dict)
            and str(item.get("vod_id") or "").strip() == vod_id
        ),
        detail_items[0] if isinstance(detail_items[0], dict) else None,
    )
    if not isinstance(detail_item, dict):
        result["error_category"] = "detail_invalid_shape"
        return result
    result["detail_success"] = True
    groups = parse_vod_play_url(str(detail_item.get("vod_play_url") or ""))
    selected_with_mapping: list[tuple[dict, str, int | None]] = []
    for group in groups:
        selected_episode = episode_from_group(group, case.episode)
        if selected_episode is None:
            continue
        group_numbers = [
            episode_number_from_label(str(item.get("name") or ""))
            for item in group
        ]
        explicit = any(number is not None for number in group_numbers)
        selected_with_mapping.append((
            selected_episode,
            "explicit" if explicit else "position_fallback",
            episode_number_from_label(
                str(selected_episode.get("name") or "")
            ),
        ))
        if len(selected_with_mapping) >= 8:
            break
    if not selected_with_mapping:
        result["error_category"] = "episode_not_found"
        return result
    result["episode_found"] = True
    selected = [item for item, _mode, _number in selected_with_mapping]
    result["episode_labels"] = list(dict.fromkeys(
        str(item.get("name") or "").strip()
        for item in selected
        if str(item.get("name") or "").strip()
    ))
    result["episode_mapping_modes"] = list(dict.fromkeys(
        mode for _item, mode, _number in selected_with_mapping
    ))
    explicit_numbers = [
        number
        for _item, mode, number in selected_with_mapping
        if mode == "explicit" and number is not None
    ]
    if any(number != case.episode for number in explicit_numbers):
        result["wrong_episode"] = True
    elif selected_with_mapping and all(
        mode == "explicit" and number == case.episode
        for _item, mode, number in selected_with_mapping
    ):
        result["wrong_episode"] = False

    media_headers = _safe_site_headers(site)
    checks: list[dict[str, object]] = []
    hosts: set[str] = set()
    verify_started = time.monotonic()
    for episode in selected:
        url = str(episode.get("url") or "").strip()
        host = (urlparse(url).hostname or "").strip().lower()
        if host:
            hosts.add(host)
        checks.append(await verify_media_url(
            verifier,
            url,
            declared_format=media_format_from_url(url),
            headers=media_headers,
        ))
    result["verify_latency_ms"] = max(
        0,
        int((time.monotonic() - verify_started) * 1000),
    )
    result["checks"] = checks
    result["media_hosts"] = sorted(hosts)
    result["verified_media_hosts"] = sorted({
        (urlparse(str(check.get("url") or "")).hostname or "").strip().lower()
        for check in checks
        if check.get("status") == SERVER_VERIFIED
        and (urlparse(str(check.get("url") or "")).hostname or "").strip()
    })
    result["server_verified"] = any(
        check.get("status") == SERVER_VERIFIED for check in checks
    )
    result["client_probe_required"] = any(
        check.get("status") == CLIENT_PROBE_REQUIRED for check in checks
    )
    result["route_unavailable"] = not (
        result["server_verified"] or result["client_probe_required"]
    )
    failure_categories = [
        str(check.get("error_category") or "")
        for check in checks
        if check.get("status") not in {SERVER_VERIFIED, CLIENT_PROBE_REQUIRED}
    ]
    result["deterministic_failure"] = result["route_unavailable"] and bool(
        failure_categories
    ) and all(
        category in _DETERMINISTIC_COVERAGE_FAILURES
        for category in failure_categories
    )
    if result["route_unavailable"] and failure_categories:
        result["error_category"] = failure_categories[0]
    return result


def _attach_coverage_promotion_pipeline(
    coverage_result: dict[str, object],
    *,
    smoke_result: dict[str, object] | None,
) -> None:
    promotion = coverage_result["promotion"]
    pipeline = build_source_promotion_pipeline(
        smoke_result=smoke_result,
        coverage_result=coverage_result,
    )
    promotion["pipeline"] = pipeline
    if pipeline["safety_failures"]:
        promotion["recommended_tier"] = "quarantine"
        promotion["content_types"] = []
        promotion["recommendation_reason"] = "url_safety_failed"
    else:
        promotion["recommendation_reason"] = "coverage_metrics"


async def probe_site_coverage(
    site: dict,
    cases: list[CoverageCase],
    verifier: ContentAggregator,
) -> dict[str, object]:
    started = time.monotonic()
    async with httpx.AsyncClient(
        headers={"User-Agent": _UA, "Accept": "application/json, */*"},
        timeout=httpx.Timeout(20, connect=8),
        follow_redirects=False,
        trust_env=False,
    ) as client:
        case_results = [
            await probe_coverage_case(site, case, verifier, client)
            for case in cases
        ]
    metrics = summarize_source_coverage(case_results)
    output = {
        "name": site["name"],
        "api": _redacted_url(site["api"]),
        "origin": site.get("origin", CONFIGURED_ORIGIN),
        "discovered_from": site.get("discovered_from", ""),
        "review_status": site.get("review_status", "configured"),
        "notes": site.get("notes", ""),
        "enabled": site.get("enabled"),
        "tier": site.get("tier", "candidate"),
        "cases": case_results,
        "metrics": metrics,
        "promotion": recommend_source_tier(metrics),
        "latency_seconds": round(time.monotonic() - started, 1),
    }
    _attach_coverage_promotion_pipeline(
        output,
        smoke_result=None,
    )
    return output


async def probe_site(
    site: dict,
    verifier: ContentAggregator,
) -> dict[str, object]:
    result: dict[str, object] = {
        "name": site["name"],
        "api": _redacted_url(site["api"]),
        "origin": site.get("origin", CONFIGURED_ORIGIN),
        "discovered_from": site.get("discovered_from", ""),
        "review_status": site.get("review_status", "configured"),
        "notes": site.get("notes", ""),
        "enabled": site.get("enabled"),
        "tier": site.get("tier", "candidate"),
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
    result["promotion_pipeline"] = build_source_promotion_pipeline(
        smoke_result=result,
        coverage_result=None,
    )
    return result


def _build_source_inventory(
    results: list[dict[str, object]],
    *,
    registered_candidate_count: int | None,
) -> dict[str, int]:
    selected_candidates = sum(
        result.get("origin") == CANDIDATE_ORIGIN for result in results
    )

    def tier_count(tier: str) -> int:
        return sum(result.get("tier") == tier for result in results)

    def smoke_result(result: dict[str, object]) -> dict[str, object] | None:
        embedded = result.get("smoke")
        if isinstance(embedded, dict):
            return embedded
        return result if "search" in result else None

    return {
        "candidate_source_count": (
            selected_candidates
            if registered_candidate_count is None
            else registered_candidate_count
        ),
        "selected_candidate_source_count": selected_candidates,
        "selected_source_count": len(results),
        "configured_source_count": sum(
            result.get("origin") == CONFIGURED_ORIGIN for result in results
        ),
        "production_source_count": sum(
            result.get("origin") == CONFIGURED_ORIGIN
            and result.get("enabled") is True
            for result in results
        ),
        "core_source_count": tier_count("core"),
        "fallback_source_count": tier_count("fallback"),
        "specialist_source_count": tier_count("specialist"),
        "client_probe_source_count": tier_count("client_probe"),
        "quarantine_source_count": tier_count("quarantine"),
        "retired_source_count": tier_count("retired"),
        "smoke_completed_source_count": sum(
            smoke_result(result) is not None for result in results
        ),
        "smoke_playable_source_count": sum(
            bool((smoke_result(result) or {}).get("playable"))
            for result in results
        ),
        "coverage_completed_source_count": sum(
            int((result.get("metrics") or {}).get("case_count") or 0) > 0
            for result in results
        ),
        "manual_review_eligible_source_count": sum(
            bool(
                (
                    ((result.get("promotion") or {}).get("pipeline") or {})
                ).get("eligible_for_manual_review")
            )
            for result in results
        ),
    }


def build_report(
    results: list[dict[str, object]],
    *,
    candidate_count: int | None = None,
    registered_candidate_count: int | None = None,
) -> dict[str, object]:
    selected_count = len(results) if candidate_count is None else candidate_count
    return {
        "schema": "zeluna.maccms-probe.v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "candidate_count": selected_count,
        "selected_source_count": selected_count,
        "target_egress": "runtime-host",
        "keywords": [{"type": label, "query": keyword} for label, keyword in KEYWORDS],
        "source_inventory": _build_source_inventory(
            results,
            registered_candidate_count=registered_candidate_count,
        ),
        "results": results,
    }


def build_coverage_report(
    results: list[dict[str, object]],
    cases: list[CoverageCase],
    *,
    candidate_count: int,
    profile: str = "coverage",
    registered_candidate_count: int | None = None,
) -> dict[str, object]:
    inventory = _build_source_inventory(
        results,
        registered_candidate_count=registered_candidate_count,
    )
    return {
        "schema": "zeluna.maccms-probe.v3",
        "profile": profile,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "target_egress": "runtime-host",
        "candidate_count": candidate_count,
        "selected_source_count": candidate_count,
        "benchmark_subject_count": len({
            case.subject_id or case.case_id for case in cases
        }),
        "benchmark_case_count": len(cases),
        "benchmark_cases": [
            {
                "case_id": case.case_id,
                "subject_id": case.subject_id or case.case_id,
                "sample_kind": case.sample_kind,
                "content_type": case.content_type,
                "year": case.year,
                "episode": case.episode,
                "tags": list(case.tags),
            }
            for case in cases
        ],
        "source_inventory": inventory,
        "coverage_kpis": build_coverage_kpis(results),
        "coverage_baselines": build_legacy_coverage_baselines(results),
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


def _render_coverage_summary(
    results: list[dict[str, object]],
    report: dict[str, object],
) -> None:
    kpis = report["coverage_kpis"]
    print(
        f"Coverage：{report['benchmark_subject_count']} 部作品 / "
        f"{report['benchmark_case_count']} 个分集案例，"
        f"{len(results)} 个来源\n"
    )
    print(
        f"{'站点':<12} {'来源':<10} {'搜索响应':<9} {'匹配':<8} "
        f"{'服务端可播':<10} {'客户端复验':<10} {'建议层级':<12}"
    )
    print("-" * 96)
    for result in results:
        metrics = result["metrics"]
        promotion = result["promotion"]
        print(
            f"{str(result['name']):<12} {str(result['origin']):<10} "
            f"{metrics['search_response_rate']:<9.1%} "
            f"{metrics['accepted_match_rate']:<8.1%} "
            f"{metrics['server_verified_rate']:<10.1%} "
            f"{metrics['client_probe_required_rate']:<10.1%} "
            f"{promotion['recommended_tier']:<12}"
        )
    print(
        "\n总体："
        f"任一真实可播 {kpis['subject_with_any_playable_route_rate']:.1%} · "
        f"零可播 {kpis['zero_playable_rate']:.1%} · "
        f"多 Host {kpis['multi_host_rate']:.1%}"
    )
    baselines = report["coverage_baselines"]
    legacy = baselines["legacy_alias0_first_match"]
    print(
        "旧策略同批观测模型："
        f"任一真实可播 "
        f"{legacy['subject_with_any_playable_route_rate']:.1%} · "
        f"零可播 {legacy['zero_playable_rate']:.1%}"
    )


async def main(argv: list[str] | None = None) -> dict[str, object]:
    parser = argparse.ArgumentParser(description="Probe MacCMS sites")
    parser.add_argument(
        "--profile",
        choices=("smoke", "coverage", "promotion"),
        default="smoke",
        help=(
            "Smoke keeps the historical three titles; coverage runs the "
            "dataset; promotion runs both and keeps manual review mandatory"
        ),
    )
    parser.add_argument(
        "--cases",
        type=Path,
        help="Override the coverage benchmark case file",
    )
    parser.add_argument(
        "--max-cases",
        type=int,
        help="Limit coverage cases for an explicit development probe",
    )
    parser.add_argument(
        "--site",
        action="append",
        default=[],
        help="Probe only the named source; repeat for multiple sources",
    )
    parser.add_argument(
        "--json-output",
        type=Path,
        help="Write a redacted structured result for later review",
    )
    parser.add_argument(
        "--candidates",
        type=Path,
        nargs="?",
        const=DEFAULT_CANDIDATE_REGISTRY_PATH,
        help=(
            "Validated v1 candidate registry to probe before any site is "
            "considered for maccms_sites.py; omit the value to use the "
            "repository registry"
        ),
    )
    parser.add_argument(
        "--include-configured",
        action="store_true",
        help="Also re-probe the configured table when --candidates is given",
    )
    args = parser.parse_args(argv)

    sites = list(CONFIGURED_SITES)
    registered_candidate_count: int | None = None
    if args.candidates is not None:
        try:
            candidates = load_candidate_sites(args.candidates)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        registered_candidate_count = len(candidates)
        sites = (
            [*CONFIGURED_SITES, *candidates]
            if args.include_configured
            else candidates
        )
    elif args.include_configured:
        parser.error("--include-configured only applies together with --candidates")

    if args.site:
        selected_names = {str(name).strip().casefold() for name in args.site}
        sites = [
            site
            for site in sites
            if str(site.get("name") or "").strip().casefold() in selected_names
        ]
        if not sites:
            parser.error("--site did not match any selected source")

    coverage_cases: list[CoverageCase] = []
    if args.profile in {"coverage", "promotion"}:
        case_path = args.cases or DEFAULT_COVERAGE_CASES_PATH
        try:
            coverage_cases = load_coverage_cases(case_path)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        if args.max_cases is not None:
            if args.max_cases < 1:
                parser.error("--max-cases must be positive")
            coverage_cases = coverage_cases[:args.max_cases]
    elif args.cases is not None or args.max_cases is not None:
        parser.error(
            "--cases and --max-cases require --profile coverage or promotion"
        )

    semaphore = asyncio.Semaphore(
        4 if args.profile in {"coverage", "promotion"} else 8
    )
    verifier = ContentAggregator(
        crawler_scrapers={},
        enabled_provider_ids=frozenset(),
        resolver_search_enabled=False,
    )

    async def run(site: dict) -> dict[str, object]:
        async with semaphore:
            if args.profile == "coverage":
                return await probe_site_coverage(site, coverage_cases, verifier)
            if args.profile == "promotion":
                smoke_result = await probe_site(site, verifier)
                coverage_result = await probe_site_coverage(
                    site,
                    coverage_cases,
                    verifier,
                )
                coverage_result["smoke"] = smoke_result
                _attach_coverage_promotion_pipeline(
                    coverage_result,
                    smoke_result=smoke_result,
                )
                return coverage_result
            return await probe_site(site, verifier)

    try:
        results = await asyncio.gather(*(run(site) for site in sites))
    finally:
        await verifier.aclose()
    if args.profile in {"coverage", "promotion"}:
        results.sort(
            key=lambda item: (
                item["metrics"]["server_verified_rate"],
                item["metrics"]["accepted_match_rate"],
                item["metrics"]["search_response_rate"],
            ),
            reverse=True,
        )
        report = build_coverage_report(
            results,
            coverage_cases,
            candidate_count=len(sites),
            profile=args.profile,
            registered_candidate_count=registered_candidate_count,
        )
        _render_coverage_summary(results, report)
    else:
        results.sort(
            key=lambda item: (
                len(item["playable"]),
                bool(item["detail"]),
                bool(item["search"]),
            ),
            reverse=True,
        )
        report = build_report(
            results,
            candidate_count=len(sites),
            registered_candidate_count=registered_candidate_count,
        )
        _render_summary(results)
    if args.json_output is not None:
        write_json_report(args.json_output, report)
        print(f"结构化结果：{args.json_output.resolve()}")
    return report


if __name__ == "__main__":
    asyncio.run(main())
