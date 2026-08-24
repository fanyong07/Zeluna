"""Pure models and metrics for the MacCMS coverage benchmark.

This module deliberately contains no network or production-table mutation. The
probe CLI supplies redacted observations; these helpers validate benchmark
data, aggregate coverage, and produce review-only tier recommendations.
"""

from __future__ import annotations

import json
import math
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_COVERAGE_CASES_PATH = PROJECT_ROOT / "data" / "maccms_coverage_cases.json"
DEFAULT_CANDIDATE_REGISTRY_PATH = PROJECT_ROOT / "data" / "maccms_candidates.json"
CONTENT_TYPES = ("anime", "tv", "movie")
SAMPLE_KINDS = ("episode_1", "mid_episode")
_PROMOTION_SAFETY_FAILURES = {"non_public_target"}


@dataclass(frozen=True)
class CoverageCase:
    case_id: str
    query: str
    aliases: tuple[str, ...]
    content_type: str
    year: int
    episode: int
    tags: tuple[str, ...]
    subject_id: str = ""
    sample_kind: str = "episode_1"

    @property
    def search_aliases(self) -> tuple[str, ...]:
        aliases: list[str] = []
        for value in (self.query, *self.aliases):
            clean = str(value or "").strip()
            if clean and clean not in aliases:
                aliases.append(clean)
        return tuple(aliases)


def _clean_strings(values: object, *, where: str) -> tuple[str, ...]:
    if not isinstance(values, list):
        raise ValueError(f"{where}: expected a list")
    result: list[str] = []
    for value in values:
        clean = str(value or "").strip()
        if clean and clean not in result:
            result.append(clean)
    return tuple(result)


def load_coverage_cases(path: Path = DEFAULT_COVERAGE_CASES_PATH) -> list[CoverageCase]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"{path}: invalid JSON ({error})") from error
    if isinstance(payload, dict) and "subjects" in payload:
        subjects = payload.get("subjects")
        if not isinstance(subjects, list) or not subjects:
            raise ValueError(f"{path}: expected a non-empty subjects list")
        expanded: list[dict[str, Any]] = []
        for index, raw_subject in enumerate(subjects):
            where = f"{path}: subject {index}"
            if not isinstance(raw_subject, dict):
                raise ValueError(f"{where}: expected an object")
            subject_id = str(raw_subject.get("subject_id") or "").strip()
            episode_samples = raw_subject.get("episode_samples")
            if not subject_id:
                raise ValueError(f"{where}: missing subject_id")
            if not isinstance(episode_samples, list) or not episode_samples:
                raise ValueError(f"{where} ({subject_id}): missing episode_samples")
            for raw_episode in episode_samples:
                try:
                    episode = int(raw_episode)
                except (TypeError, ValueError) as error:
                    raise ValueError(
                        f"{where} ({subject_id}): invalid episode sample"
                    ) from error
                expanded.append({
                    **raw_subject,
                    "case_id": f"{subject_id}-episode-{episode}",
                    "subject_id": subject_id,
                    "sample_kind": (
                        "episode_1" if episode == 1 else "mid_episode"
                    ),
                    "episode": episode,
                })
        payload = expanded
    elif isinstance(payload, dict):
        payload = payload.get("cases", [])
    if not isinstance(payload, list) or not payload:
        raise ValueError(f"{path}: expected a non-empty list of benchmark cases")

    cases: list[CoverageCase] = []
    seen_ids: set[str] = set()
    for index, raw in enumerate(payload):
        where = f"{path}: entry {index}"
        if not isinstance(raw, dict):
            raise ValueError(f"{where}: expected an object")
        case_id = str(raw.get("case_id") or "").strip()
        query = str(raw.get("query") or "").strip()
        content_type = str(raw.get("content_type") or "").strip().lower()
        if not case_id or case_id in seen_ids:
            raise ValueError(f"{where}: missing or duplicate case_id")
        if not query:
            raise ValueError(f"{where} ({case_id}): missing query")
        if content_type not in CONTENT_TYPES:
            raise ValueError(f"{where} ({case_id}): invalid content_type")
        try:
            year = int(raw.get("year") or 0)
            episode = int(raw.get("episode") or 0)
        except (TypeError, ValueError) as error:
            raise ValueError(f"{where} ({case_id}): invalid year or episode") from error
        if year < 0 or episode < 1:
            raise ValueError(f"{where} ({case_id}): invalid year or episode")
        aliases = _clean_strings(raw.get("aliases"), where=f"{where} aliases")
        tags = _clean_strings(raw.get("tags"), where=f"{where} tags")
        subject_id = str(raw.get("subject_id") or case_id).strip()
        sample_kind = str(
            raw.get("sample_kind")
            or ("episode_1" if episode == 1 else "mid_episode")
        ).strip()
        if not aliases:
            raise ValueError(f"{where} ({case_id}): aliases must not be empty")
        if content_type not in tags:
            raise ValueError(f"{where} ({case_id}): tags must include content_type")
        if not subject_id:
            raise ValueError(f"{where} ({case_id}): missing subject_id")
        if sample_kind not in SAMPLE_KINDS:
            raise ValueError(f"{where} ({case_id}): invalid sample_kind")
        if (sample_kind == "episode_1") != (episode == 1):
            raise ValueError(
                f"{where} ({case_id}): sample_kind does not match episode"
            )
        seen_ids.add(case_id)
        cases.append(CoverageCase(
            case_id=case_id,
            query=query,
            aliases=aliases,
            content_type=content_type,
            year=year,
            episode=episode,
            tags=tags,
            subject_id=subject_id,
            sample_kind=sample_kind,
        ))
    return cases


def _rate(count: int, total: int) -> float:
    return round(count / total, 9) if total else 0.0


def _percentile(values: list[int], percentile: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return int(ordered[index])


def _has_known_playback_error(item: dict[str, Any]) -> bool:
    return (
        item.get("wrong_match") is True
        or item.get("wrong_episode") is True
    )


def _is_credible_server_verification(item: dict[str, Any]) -> bool:
    return (
        item.get("server_verified") is True
        and not _has_known_playback_error(item)
    )


def _is_credible_client_probe(item: dict[str, Any]) -> bool:
    return (
        item.get("client_probe_required") is True
        and not _has_known_playback_error(item)
    )


def summarize_source_coverage(
    case_results: list[dict[str, Any]],
) -> dict[str, Any]:
    total = len(case_results)

    def count_true(field: str) -> int:
        return sum(item.get(field) is True for item in case_results)

    wrong_match_reviewed = [
        item["wrong_match"]
        for item in case_results
        if isinstance(item.get("wrong_match"), bool)
    ]
    wrong_episode_reviewed = [
        item["wrong_episode"]
        for item in case_results
        if isinstance(item.get("wrong_episode"), bool)
    ]
    season_reviewed = [
        item["season_conflict"]
        for item in case_results
        if isinstance(item.get("season_conflict"), bool)
    ]
    search_latencies = [
        int(item.get("search_latency_ms") or 0)
        for item in case_results
        if int(item.get("search_latency_ms") or 0) > 0
    ]
    verify_latencies = [
        int(item.get("verify_latency_ms") or 0)
        for item in case_results
        if int(item.get("verify_latency_ms") or 0) > 0
    ]
    hosts = {
        str(host).strip().lower()
        for item in case_results
        if _is_credible_server_verification(item)
        for host in item.get("verified_media_hosts", [])
        if str(host).strip()
    }
    content_type_coverage: dict[str, float] = {}
    for content_type in CONTENT_TYPES:
        typed = [
            item
            for item in case_results
            if item.get("content_type") == content_type
        ]
        content_type_coverage[content_type] = _rate(
            sum(_is_credible_server_verification(item) for item in typed),
            len(typed),
        )

    server_verified_count = sum(
        _is_credible_server_verification(item) for item in case_results
    )
    return {
        "case_count": total,
        "search_response_rate": _rate(count_true("search_responded"), total),
        "search_hit_rate": _rate(count_true("search_hit"), total),
        "accepted_match_rate": _rate(count_true("accepted_match"), total),
        "wrong_match_reviewed_cases": len(wrong_match_reviewed),
        "wrong_match_rate": (
            _rate(sum(wrong_match_reviewed), len(wrong_match_reviewed))
            if wrong_match_reviewed
            else None
        ),
        "wrong_episode_reviewed_cases": len(wrong_episode_reviewed),
        "wrong_episode_rate": (
            _rate(sum(wrong_episode_reviewed), len(wrong_episode_reviewed))
            if wrong_episode_reviewed
            else None
        ),
        "season_conflict_reviewed_cases": len(season_reviewed),
        "season_conflict_rate": (
            _rate(sum(season_reviewed), len(season_reviewed))
            if season_reviewed
            else None
        ),
        "detail_success_rate": _rate(count_true("detail_success"), total),
        "episode_found_rate": _rate(count_true("episode_found"), total),
        "server_verified_rate": _rate(server_verified_count, total),
        "client_probe_required_rate": _rate(
            sum(_is_credible_client_probe(item) for item in case_results),
            total,
        ),
        "route_unavailable_rate": _rate(count_true("route_unavailable"), total),
        "deterministic_failure_rate": _rate(
            count_true("deterministic_failure"),
            total,
        ),
        "subject_with_any_playable_route_rate": _rate(
            server_verified_count,
            total,
        ),
        "zero_playable_rate": _rate(total - server_verified_count, total),
        "median_search_latency_ms": (
            int(statistics.median(search_latencies)) if search_latencies else 0
        ),
        "p95_search_latency_ms": _percentile(search_latencies, 0.95),
        "median_verify_latency_ms": (
            int(statistics.median(verify_latencies)) if verify_latencies else 0
        ),
        "p95_verify_latency_ms": _percentile(verify_latencies, 0.95),
        "unique_media_hosts": len(hosts),
        "media_hosts": sorted(hosts),
        "content_type_coverage": content_type_coverage,
    }


def recommend_source_tier(metrics: dict[str, Any]) -> dict[str, Any]:
    """Return a recommendation that can never mutate production automatically."""
    search_rate = float(metrics.get("search_response_rate") or 0)
    verified_rate = float(metrics.get("server_verified_rate") or 0)
    client_rate = float(metrics.get("client_probe_required_rate") or 0)
    deterministic_rate = float(metrics.get("deterministic_failure_rate") or 0)
    coverage = {
        content_type: float(
            (metrics.get("content_type_coverage") or {}).get(content_type) or 0
        )
        for content_type in CONTENT_TYPES
    }
    strong_types = [
        content_type
        for content_type, value in coverage.items()
        if value >= 0.6
    ]

    if deterministic_rate >= 0.5 or (search_rate < 0.35 and verified_rate == 0):
        tier = "quarantine"
        content_types: list[str] = []
    elif client_rate >= 0.3 and verified_rate < 0.15:
        tier = "client_probe"
        content_types = [
            content_type for content_type, value in coverage.items() if value > 0
        ] or list(CONTENT_TYPES)
    elif (
        search_rate >= 0.8
        and verified_rate >= 0.5
        and all(coverage[content_type] >= 0.4 for content_type in CONTENT_TYPES)
    ):
        tier = "core"
        content_types = list(CONTENT_TYPES)
    elif strong_types and len(strong_types) < len(CONTENT_TYPES):
        tier = "specialist"
        content_types = strong_types
    elif verified_rate >= 0.1:
        tier = "fallback"
        content_types = [
            content_type for content_type, value in coverage.items() if value > 0
        ] or list(CONTENT_TYPES)
    else:
        tier = "quarantine"
        content_types = []

    return {
        "recommended_tier": tier,
        "content_types": content_types,
        "review_status": "manual_review_required",
        "automatic_promotion": False,
    }


def _promotion_error_categories(*results: object) -> set[str]:
    categories: set[str] = set()

    def visit(value: object) -> None:
        if isinstance(value, dict):
            for key, nested in value.items():
                if key == "error_category":
                    category = str(nested or "").strip()
                    if category:
                        categories.add(category)
                elif key == "note" and str(nested or "").strip() in (
                    _PROMOTION_SAFETY_FAILURES
                ):
                    categories.add(str(nested).strip())
                else:
                    visit(nested)
        elif isinstance(value, list):
            for nested in value:
                visit(nested)

    for result in results:
        visit(result)
    return categories


def build_source_promotion_pipeline(
    *,
    smoke_result: dict[str, Any] | None,
    coverage_result: dict[str, Any] | None,
) -> dict[str, Any]:
    """Describe the runnable evidence gates without promoting automatically."""
    smoke_ran = isinstance(smoke_result, dict)
    smoke_passed = smoke_ran and bool(smoke_result.get("playable"))
    coverage_metrics = (
        coverage_result.get("metrics", {})
        if isinstance(coverage_result, dict)
        else {}
    )
    coverage_ran = int(coverage_metrics.get("case_count") or 0) > 0
    safety_failures = sorted(
        _promotion_error_categories(smoke_result, coverage_result)
        & _PROMOTION_SAFETY_FAILURES
    )
    safety_ran = smoke_ran or coverage_ran
    safety_passed = safety_ran and not safety_failures

    stages = [
        {"name": "candidate", "status": "registered"},
        {"name": "structure_check", "status": "passed"},
        {
            "name": "ssrf_url_safety_check",
            "status": (
                "failed"
                if safety_failures
                else "passed"
                if safety_ran
                else "not_run"
            ),
        },
        {
            "name": "smoke",
            "status": (
                "passed"
                if smoke_passed
                else "completed_no_playable"
                if smoke_ran
                else "not_run"
            ),
        },
        {
            "name": "coverage",
            "status": "completed" if coverage_ran else "not_run",
        },
        {"name": "manual_review", "status": "required"},
    ]
    blocking_reasons: list[str] = []
    if not safety_passed:
        blocking_reasons.append(
            "url_safety_failed" if safety_failures else "url_safety_not_run"
        )
    if not smoke_passed:
        blocking_reasons.append("smoke_not_passed")
    if not coverage_ran:
        blocking_reasons.append("coverage_not_run")
    blocking_reasons.append("manual_review_required")

    return {
        "schema": "zeluna.maccms-promotion-pipeline.v1",
        "stages": stages,
        "safety_failures": safety_failures,
        "eligible_for_manual_review": (
            safety_passed and smoke_passed and coverage_ran
        ),
        "automatic_promotion": False,
        "production_table_mutation": False,
        "blocking_reasons": blocking_reasons,
    }


def build_coverage_kpis(site_results: list[dict[str, Any]]) -> dict[str, Any]:
    by_case: dict[str, dict[str, Any]] = {}
    wrong_match_reviewed: list[bool] = []
    wrong_episode_reviewed: list[bool] = []
    for site in site_results:
        for result in site.get("cases", []):
            case_id = str(result.get("case_id") or "").strip()
            if not case_id:
                continue
            aggregate = by_case.setdefault(case_id, {
                "subject_id": str(result.get("subject_id") or case_id),
                "sample_kind": str(
                    result.get("sample_kind") or "episode_1"
                ),
                "content_type": str(result.get("content_type") or "unknown"),
                "server_verified": False,
                "client_probe_required": False,
                "verified_hosts": set(),
            })
            if _is_credible_server_verification(result):
                aggregate["server_verified"] = True
                aggregate["verified_hosts"].update(
                    str(host).strip().lower()
                    for host in result.get("verified_media_hosts", [])
                    if str(host).strip()
                )
            if _is_credible_client_probe(result):
                aggregate["client_probe_required"] = True
            if isinstance(result.get("wrong_match"), bool):
                wrong_match_reviewed.append(result["wrong_match"])
            if isinstance(result.get("wrong_episode"), bool):
                wrong_episode_reviewed.append(result["wrong_episode"])

    total = len(by_case)
    verified = sum(item["server_verified"] for item in by_case.values())
    client_probe = sum(
        item["client_probe_required"] and not item["server_verified"]
        for item in by_case.values()
    )
    by_subject: dict[str, dict[str, Any]] = {}
    for case in by_case.values():
        subject_id = case["subject_id"]
        subject = by_subject.setdefault(subject_id, {
            "content_type": case["content_type"],
            "episode_1_verified": False,
            "episode_1_hosts": set(),
            "has_episode_1": False,
            "any_verified": False,
        })
        subject["any_verified"] = (
            subject["any_verified"] or case["server_verified"]
        )
        if case["sample_kind"] == "episode_1":
            subject["has_episode_1"] = True
            subject["episode_1_verified"] = case["server_verified"]
            subject["episode_1_hosts"].update(case["verified_hosts"])
    for subject in by_subject.values():
        if not subject["has_episode_1"]:
            subject["episode_1_verified"] = subject["any_verified"]

    subject_total = len(by_subject)
    subject_verified = sum(
        subject["episode_1_verified"] for subject in by_subject.values()
    )
    single_host = sum(
        subject["episode_1_verified"]
        and len(subject["episode_1_hosts"]) == 1
        for subject in by_subject.values()
    )
    multi_host = sum(
        subject["episode_1_verified"]
        and len(subject["episode_1_hosts"]) >= 2
        for subject in by_subject.values()
    )

    def type_coverage(content_type: str) -> float:
        typed = [
            subject
            for subject in by_subject.values()
            if subject["content_type"] == content_type
        ]
        return _rate(
            sum(subject["episode_1_verified"] for subject in typed),
            len(typed),
        )

    return {
        "benchmark_subjects": subject_total,
        "benchmark_cases": total,
        "episode_1_cases": sum(
            item["sample_kind"] == "episode_1" for item in by_case.values()
        ),
        "mid_episode_cases": sum(
            item["sample_kind"] == "mid_episode" for item in by_case.values()
        ),
        "subject_with_any_playable_route_rate": _rate(
            subject_verified,
            subject_total,
        ),
        "episode_with_any_playable_route_rate": _rate(verified, total),
        "anime_coverage": type_coverage("anime"),
        "tv_coverage": type_coverage("tv"),
        "movie_coverage": type_coverage("movie"),
        "zero_playable_rate": _rate(
            subject_total - subject_verified,
            subject_total,
        ),
        "zero_playable_episode_rate": _rate(total - verified, total),
        "single_host_rate": _rate(single_host, subject_total),
        "multi_host_rate": _rate(multi_host, subject_total),
        "server_verified_rate": _rate(verified, total),
        "client_probe_rate": _rate(client_probe, total),
        "wrong_match_reviewed_cases": len(wrong_match_reviewed),
        "wrong_match_rate": (
            _rate(sum(wrong_match_reviewed), len(wrong_match_reviewed))
            if wrong_match_reviewed
            else None
        ),
        "wrong_episode_reviewed_cases": len(wrong_episode_reviewed),
        "wrong_episode_rate": (
            _rate(sum(wrong_episode_reviewed), len(wrong_episode_reviewed))
            if wrong_episode_reviewed
            else None
        ),
    }


def build_legacy_coverage_baselines(
    site_results: list[dict[str, Any]],
) -> dict[str, Any]:
    """Model bounded legacy discovery from the same live observations.

    This is intentionally labelled as a deterministic model rather than an
    old-runtime replay. It answers how the same routes would have looked if
    only alias zero were eligible and either the first match or first six
    matching sources had been resolved.
    """

    by_case: dict[str, list[dict[str, Any]]] = {}
    for site in site_results:
        for result in site.get("cases", []):
            case_id = str(result.get("case_id") or "").strip()
            if case_id:
                by_case.setdefault(case_id, []).append(result)

    def modeled_cases(candidate_limit: int) -> list[dict[str, Any]]:
        cases: list[dict[str, Any]] = []
        for case_id, observations in by_case.items():
            template = observations[0]
            eligible = [
                item
                for item in observations
                if item.get("accepted_match") is True
                and item.get("matched_alias_index") == 0
            ]
            eligible.sort(
                key=lambda item: int(item.get("search_latency_ms") or 0)
            )
            considered = eligible[:candidate_limit]
            hosts = sorted({
                str(host).strip().lower()
                for item in considered
                if _is_credible_server_verification(item)
                for host in item.get("verified_media_hosts", [])
                if str(host).strip()
            })
            cases.append({
                "case_id": case_id,
                "subject_id": str(template.get("subject_id") or case_id),
                "sample_kind": str(
                    template.get("sample_kind") or "episode_1"
                ),
                "content_type": str(
                    template.get("content_type") or "unknown"
                ),
                "server_verified": any(
                    _is_credible_server_verification(item)
                    for item in considered
                ),
                "client_probe_required": any(
                    _is_credible_client_probe(item)
                    for item in considered
                ),
                "verified_media_hosts": hosts,
            })
        return cases

    return {
        "method": "same_run_alias0_deterministic_model",
        "old_runtime_replay": False,
        "legacy_alias0_first_match": build_coverage_kpis([
            {"cases": modeled_cases(1)}
        ]),
        "legacy_alias0_candidate_cap_6": build_coverage_kpis([
            {"cases": modeled_cases(6)}
        ]),
    }
