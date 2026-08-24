import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx

from server.aggregator import ContentAggregator
from tools.maccms_coverage import (
    DEFAULT_COVERAGE_CASES_PATH,
    CoverageCase,
    build_coverage_kpis,
    build_legacy_coverage_baselines,
    build_source_promotion_pipeline,
    load_coverage_cases,
    recommend_source_tier,
    summarize_source_coverage,
)
from tools.probe_maccms import main, probe_coverage_case, probe_site_coverage


class MacCmsCoverageTests(unittest.IsolatedAsyncioTestCase):
    def test_default_dataset_has_100_subject_episode1_and_midpoint_coverage(self):
        cases = load_coverage_cases(DEFAULT_COVERAGE_CASES_PATH)
        subjects: dict[str, list[CoverageCase]] = {}
        for case in cases:
            subjects.setdefault(case.subject_id, []).append(case)

        self.assertGreaterEqual(len(subjects), 100)
        self.assertGreaterEqual(len(cases), 160)
        self.assertEqual(
            {case.content_type for case in cases},
            {"anime", "tv", "movie"},
        )
        self.assertEqual(len({case.case_id for case in cases}), len(cases))
        self.assertTrue(all(case.aliases for case in cases))
        self.assertTrue(all(case.episode >= 1 for case in cases))
        subject_types = {
            subject_id: subject_cases[0].content_type
            for subject_id, subject_cases in subjects.items()
        }
        for content_type in ("anime", "tv", "movie"):
            self.assertGreaterEqual(
                sum(value == content_type for value in subject_types.values()),
                30,
            )
        for subject_id, subject_cases in subjects.items():
            self.assertEqual(
                sum(case.sample_kind == "episode_1" for case in subject_cases),
                1,
                subject_id,
            )
            if subject_cases[0].content_type in {"anime", "tv"}:
                midpoint = [
                    case
                    for case in subject_cases
                    if case.sample_kind == "mid_episode"
                ]
                self.assertEqual(len(midpoint), 1, subject_id)
                self.assertGreater(midpoint[0].episode, 1, subject_id)
            self.assertTrue(
                any(
                    tag in {"popular", "mid-tail", "long-tail"}
                    for tag in subject_cases[0].tags
                ),
                subject_id,
            )
        self.assertGreaterEqual(
            sum("difficult" in case.tags for case in cases),
            30,
        )
        all_tags = {tag for case in cases for tag in case.tags}
        self.assertTrue({
            "chinese",
            "japanese",
            "western",
            "korean",
            "hong-kong",
            "taiwan",
        }.issubset(all_tags))
        years = [subject_cases[0].year for subject_cases in subjects.values()]
        self.assertGreaterEqual(sum(year <= 1999 for year in years), 6)
        self.assertGreaterEqual(sum(2000 <= year <= 2014 for year in years), 20)
        self.assertGreaterEqual(sum(year >= 2015 for year in years), 50)

    def test_v2_subject_dataset_expands_episode_samples_without_duplication(self):
        payload = {
            "schema": "zeluna.maccms-coverage-subjects.v2",
            "subjects": [{
                "subject_id": "anime-example",
                "query": "示例动画",
                "aliases": ["Example Anime"],
                "content_type": "anime",
                "year": 2025,
                "episode_samples": [1, 6],
                "tags": ["anime", "japanese", "mid-tail"],
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "coverage.json"
            path.write_text(
                json.dumps(payload, ensure_ascii=False),
                encoding="utf-8",
            )
            cases = load_coverage_cases(path)

        self.assertEqual(
            [case.case_id for case in cases],
            ["anime-example-episode-1", "anime-example-episode-6"],
        )
        self.assertEqual([case.subject_id for case in cases], ["anime-example"] * 2)
        self.assertEqual(
            [case.sample_kind for case in cases],
            ["episode_1", "mid_episode"],
        )

    def test_source_metrics_keep_verified_client_and_manual_quality_separate(self):
        metrics = summarize_source_coverage([
            {
                "case_id": "anime-a",
                "content_type": "anime",
                "search_responded": True,
                "search_hit": True,
                "accepted_match": True,
                "wrong_match": False,
                "season_conflict": False,
                "detail_success": True,
                "episode_found": True,
                "server_verified": True,
                "client_probe_required": False,
                "route_unavailable": False,
                "deterministic_failure": False,
                "search_latency_ms": 20,
                "verify_latency_ms": 40,
                "media_hosts": ["a.example"],
                "verified_media_hosts": ["a.example"],
            },
            {
                "case_id": "tv-b",
                "content_type": "tv",
                "search_responded": True,
                "search_hit": True,
                "accepted_match": True,
                "wrong_match": None,
                "season_conflict": None,
                "detail_success": True,
                "episode_found": True,
                "server_verified": False,
                "client_probe_required": True,
                "route_unavailable": False,
                "deterministic_failure": False,
                "search_latency_ms": 30,
                "verify_latency_ms": 50,
                "media_hosts": ["b.example"],
                "verified_media_hosts": [],
            },
            {
                "case_id": "movie-c",
                "content_type": "movie",
                "search_responded": True,
                "search_hit": True,
                "accepted_match": True,
                "wrong_match": True,
                "season_conflict": False,
                "detail_success": True,
                "episode_found": True,
                "server_verified": False,
                "client_probe_required": False,
                "route_unavailable": True,
                "deterministic_failure": True,
                "search_latency_ms": 40,
                "verify_latency_ms": 60,
                "media_hosts": ["a.example", "c.example"],
                "verified_media_hosts": [],
            },
        ])

        self.assertEqual(metrics["case_count"], 3)
        self.assertEqual(metrics["search_response_rate"], 1.0)
        self.assertAlmostEqual(metrics["server_verified_rate"], 1 / 3)
        self.assertAlmostEqual(metrics["client_probe_required_rate"], 1 / 3)
        self.assertAlmostEqual(metrics["route_unavailable_rate"], 1 / 3)
        self.assertEqual(metrics["wrong_match_reviewed_cases"], 2)
        self.assertEqual(metrics["wrong_match_rate"], 0.5)
        self.assertEqual(metrics["unique_media_hosts"], 1)
        self.assertEqual(metrics["content_type_coverage"]["anime"], 1.0)
        self.assertEqual(metrics["content_type_coverage"]["tv"], 0.0)

    def test_cross_source_kpis_use_case_union_and_host_diversity(self):
        kpis = build_coverage_kpis([
            {
                "cases": [
                    {
                        "case_id": "anime-a",
                        "content_type": "anime",
                        "server_verified": True,
                        "media_hosts": ["a.example"],
                        "verified_media_hosts": ["a.example"],
                    },
                    {
                        "case_id": "tv-b",
                        "content_type": "tv",
                        "server_verified": False,
                        "media_hosts": [],
                        "verified_media_hosts": [],
                    },
                ],
            },
            {
                "cases": [
                    {
                        "case_id": "anime-a",
                        "content_type": "anime",
                        "server_verified": True,
                        "media_hosts": ["b.example"],
                        "verified_media_hosts": ["b.example"],
                    },
                    {
                        "case_id": "tv-b",
                        "content_type": "tv",
                        "server_verified": False,
                        "media_hosts": ["client-only.example"],
                        "verified_media_hosts": [],
                    },
                ],
            },
        ])

        self.assertEqual(kpis["benchmark_cases"], 2)
        self.assertEqual(kpis["subject_with_any_playable_route_rate"], 0.5)
        self.assertEqual(kpis["episode_with_any_playable_route_rate"], 0.5)
        self.assertEqual(kpis["zero_playable_rate"], 0.5)
        self.assertEqual(kpis["multi_host_rate"], 0.5)
        self.assertEqual(kpis["anime_coverage"], 1.0)
        self.assertEqual(kpis["tv_coverage"], 0.0)

    def test_cross_source_kpis_separate_subject_and_episode_coverage(self):
        source_a = {
            "cases": [
                {
                    "case_id": "anime-a-episode-1",
                    "subject_id": "anime-a",
                    "sample_kind": "episode_1",
                    "content_type": "anime",
                    "server_verified": True,
                    "verified_media_hosts": ["a.example"],
                },
                {
                    "case_id": "anime-a-episode-6",
                    "subject_id": "anime-a",
                    "sample_kind": "mid_episode",
                    "content_type": "anime",
                    "server_verified": False,
                    "verified_media_hosts": [],
                },
                {
                    "case_id": "tv-b-episode-1",
                    "subject_id": "tv-b",
                    "sample_kind": "episode_1",
                    "content_type": "tv",
                    "server_verified": False,
                    "verified_media_hosts": [],
                },
                {
                    "case_id": "tv-b-episode-5",
                    "subject_id": "tv-b",
                    "sample_kind": "mid_episode",
                    "content_type": "tv",
                    "server_verified": True,
                    "verified_media_hosts": ["c.example"],
                },
            ],
        }
        source_b = {
            "cases": [{
                "case_id": "anime-a-episode-1",
                "subject_id": "anime-a",
                "sample_kind": "episode_1",
                "content_type": "anime",
                "server_verified": True,
                "verified_media_hosts": ["b.example"],
            }],
        }

        kpis = build_coverage_kpis([source_a, source_b])

        self.assertEqual(kpis["benchmark_subjects"], 2)
        self.assertEqual(kpis["benchmark_cases"], 4)
        self.assertEqual(kpis["episode_1_cases"], 2)
        self.assertEqual(kpis["mid_episode_cases"], 2)
        self.assertEqual(kpis["subject_with_any_playable_route_rate"], 0.5)
        self.assertEqual(kpis["episode_with_any_playable_route_rate"], 0.5)
        self.assertEqual(kpis["zero_playable_rate"], 0.5)
        self.assertEqual(kpis["zero_playable_episode_rate"], 0.5)
        self.assertEqual(kpis["multi_host_rate"], 0.5)

    def test_legacy_baselines_model_alias0_and_first_match_failures(self):
        site_results = [
            {
                "cases": [{
                    "case_id": "anime-a-episode-1",
                    "subject_id": "anime-a",
                    "sample_kind": "episode_1",
                    "content_type": "anime",
                    "accepted_match": True,
                    "matched_alias_index": 0,
                    "search_latency_ms": 10,
                    "server_verified": False,
                    "verified_media_hosts": [],
                }],
            },
            {
                "cases": [{
                    "case_id": "anime-a-episode-1",
                    "subject_id": "anime-a",
                    "sample_kind": "episode_1",
                    "content_type": "anime",
                    "accepted_match": True,
                    "matched_alias_index": 0,
                    "search_latency_ms": 30,
                    "server_verified": True,
                    "verified_media_hosts": ["good.example"],
                }],
            },
            {
                "cases": [{
                    "case_id": "movie-b-episode-1",
                    "subject_id": "movie-b",
                    "sample_kind": "episode_1",
                    "content_type": "movie",
                    "accepted_match": True,
                    "matched_alias_index": 1,
                    "search_latency_ms": 20,
                    "server_verified": True,
                    "verified_media_hosts": ["alias.example"],
                }],
            },
        ]

        baselines = build_legacy_coverage_baselines(site_results)

        self.assertEqual(
            baselines["legacy_alias0_first_match"][
                "subject_with_any_playable_route_rate"
            ],
            0.0,
        )
        self.assertEqual(
            baselines["legacy_alias0_candidate_cap_6"][
                "subject_with_any_playable_route_rate"
            ],
            0.5,
        )

    def test_promotion_recommendations_never_bypass_manual_review(self):
        core = recommend_source_tier({
            "search_response_rate": 0.95,
            "server_verified_rate": 0.7,
            "client_probe_required_rate": 0.05,
            "deterministic_failure_rate": 0.02,
            "content_type_coverage": {"anime": 0.6, "tv": 0.7, "movie": 0.8},
        })
        specialist = recommend_source_tier({
            "search_response_rate": 0.9,
            "server_verified_rate": 0.25,
            "client_probe_required_rate": 0.05,
            "deterministic_failure_rate": 0.05,
            "content_type_coverage": {"anime": 0.05, "tv": 0.1, "movie": 0.8},
        })
        client_probe = recommend_source_tier({
            "search_response_rate": 0.8,
            "server_verified_rate": 0.02,
            "client_probe_required_rate": 0.6,
            "deterministic_failure_rate": 0.05,
            "content_type_coverage": {"anime": 0.0, "tv": 0.0, "movie": 0.05},
        })
        quarantine = recommend_source_tier({
            "search_response_rate": 0.2,
            "server_verified_rate": 0.0,
            "client_probe_required_rate": 0.0,
            "deterministic_failure_rate": 0.8,
            "content_type_coverage": {"anime": 0.0, "tv": 0.0, "movie": 0.0},
        })

        self.assertEqual(core["recommended_tier"], "core")
        self.assertEqual(specialist["recommended_tier"], "specialist")
        self.assertEqual(specialist["content_types"], ["movie"])
        self.assertEqual(client_probe["recommended_tier"], "client_probe")
        self.assertEqual(quarantine["recommended_tier"], "quarantine")
        for recommendation in (core, specialist, client_probe, quarantine):
            self.assertEqual(
                recommendation["review_status"],
                "manual_review_required",
            )

    def test_promotion_pipeline_requires_every_live_gate_and_manual_review(self):
        smoke = {
            "playable": ["番剧"],
            "note": "",
            "checks": {},
        }
        coverage = {
            "metrics": {"case_count": 3},
            "cases": [{"error_category": ""}],
        }
        pipeline = build_source_promotion_pipeline(
            smoke_result=smoke,
            coverage_result=coverage,
        )
        stages = {stage["name"]: stage["status"] for stage in pipeline["stages"]}

        self.assertEqual(stages["structure_check"], "passed")
        self.assertEqual(stages["ssrf_url_safety_check"], "passed")
        self.assertEqual(stages["smoke"], "passed")
        self.assertEqual(stages["coverage"], "completed")
        self.assertEqual(stages["manual_review"], "required")
        self.assertTrue(pipeline["eligible_for_manual_review"])
        self.assertFalse(pipeline["automatic_promotion"])
        self.assertFalse(pipeline["production_table_mutation"])
        self.assertIn("manual_review_required", pipeline["blocking_reasons"])

        unsafe = build_source_promotion_pipeline(
            smoke_result=smoke,
            coverage_result={
                "metrics": {"case_count": 3},
                "cases": [{"error_category": "non_public_target"}],
            },
        )
        unsafe_stages = {
            stage["name"]: stage["status"] for stage in unsafe["stages"]
        }
        self.assertEqual(unsafe_stages["ssrf_url_safety_check"], "failed")
        self.assertFalse(unsafe["eligible_for_manual_review"])
        self.assertEqual(unsafe["safety_failures"], ["non_public_target"])

    async def test_coverage_profile_loads_dataset_and_emits_v3_report(self):
        case = CoverageCase(
            case_id="coverage-cli",
            query="Coverage CLI",
            aliases=("Coverage CLI Alias",),
            content_type="anime",
            year=2025,
            episode=1,
            tags=("anime",),
        )
        case_result = {
            "case_id": case.case_id,
            "content_type": case.content_type,
            "server_verified": True,
            "client_probe_required": False,
            "media_hosts": ["cdn.example"],
            "verified_media_hosts": ["cdn.example"],
        }
        metrics = summarize_source_coverage([case_result])
        site_result = {
            "name": "coverage-source",
            "api": "https://source.example/api.php/provide/vod",
            "origin": "configured",
            "enabled": True,
            "tier": "core",
            "cases": [case_result],
            "metrics": metrics,
            "promotion": recommend_source_tier(metrics),
            "latency_seconds": 0.1,
        }

        with (
            patch(
                "tools.probe_maccms.CONFIGURED_SITES",
                [{
                    "name": "coverage-source",
                    "api": "https://source.example/api.php/provide/vod",
                    "origin": "configured",
                    "enabled": True,
                    "tier": "core",
                }],
            ),
            patch(
                "tools.probe_maccms.load_coverage_cases",
                return_value=[case],
            ) as load_cases,
            patch(
                "tools.probe_maccms.probe_site_coverage",
                new=AsyncMock(return_value=site_result),
            ) as probe_site,
            patch("tools.probe_maccms._render_coverage_summary"),
        ):
            report = await main([
                "--profile",
                "coverage",
                "--site",
                "coverage-source",
            ])

        load_cases.assert_called_once_with(DEFAULT_COVERAGE_CASES_PATH)
        probe_site.assert_awaited_once()
        self.assertEqual(report["schema"], "zeluna.maccms-probe.v3")
        self.assertEqual(report["profile"], "coverage")
        self.assertEqual(report["benchmark_subject_count"], 1)
        self.assertEqual(report["benchmark_case_count"], 1)
        self.assertIn("legacy_alias0_first_match", report["coverage_baselines"])
        self.assertEqual(
            report["source_inventory"]["configured_source_count"],
            1,
        )
        self.assertEqual(
            report["source_inventory"]["coverage_completed_source_count"],
            1,
        )
        self.assertEqual(
            report["coverage_kpis"]["subject_with_any_playable_route_rate"],
            1.0,
        )

    async def test_url_safety_failure_forces_quarantine_recommendation(self):
        case = CoverageCase(
            case_id="unsafe-candidate",
            query="Unsafe Candidate",
            aliases=("Unsafe Alias",),
            content_type="anime",
            year=2025,
            episode=1,
            tags=("anime",),
        )
        case_result = {
            "case_id": case.case_id,
            "content_type": case.content_type,
            "search_responded": True,
            "search_hit": True,
            "accepted_match": True,
            "detail_success": True,
            "episode_found": True,
            "server_verified": False,
            "client_probe_required": True,
            "route_unavailable": False,
            "deterministic_failure": False,
            "verified_media_hosts": [],
            "error_category": "non_public_target",
        }
        verifier = ContentAggregator(
            crawler_scrapers={},
            enabled_provider_ids=frozenset(),
        )
        try:
            with patch(
                "tools.probe_maccms.probe_coverage_case",
                new=AsyncMock(return_value=case_result),
            ):
                result = await probe_site_coverage(
                    {
                        "name": "unsafe-source",
                        "api": "https://source.example/api.php/provide/vod",
                        "origin": "candidate",
                    },
                    [case],
                    verifier,
                )
        finally:
            await verifier.aclose()

        self.assertEqual(result["metrics"]["client_probe_required_rate"], 1.0)
        self.assertEqual(result["promotion"]["recommended_tier"], "quarantine")
        self.assertEqual(
            result["promotion"]["recommendation_reason"],
            "url_safety_failed",
        )
        self.assertEqual(result["promotion"]["content_types"], [])

    async def test_promotion_profile_runs_smoke_then_coverage_for_manual_review(self):
        case = CoverageCase(
            case_id="promotion-cli",
            query="Promotion CLI",
            aliases=("Promotion Alias",),
            content_type="movie",
            year=2025,
            episode=1,
            tags=("movie",),
        )
        smoke_result = {
            "name": "promotion-source",
            "api": "https://source.example/api.php/provide/vod",
            "origin": "candidate",
            "search": True,
            "detail": True,
            "playable": ["电影"],
            "checks": {},
            "latency_seconds": 0.1,
            "note": "",
        }
        case_result = {
            "case_id": case.case_id,
            "content_type": case.content_type,
            "server_verified": True,
            "client_probe_required": False,
            "verified_media_hosts": ["cdn.example"],
        }
        metrics = summarize_source_coverage([case_result])
        coverage_result = {
            "name": "promotion-source",
            "api": "https://source.example/api.php/provide/vod",
            "origin": "candidate",
            "enabled": None,
            "tier": "candidate",
            "cases": [case_result],
            "metrics": metrics,
            "promotion": recommend_source_tier(metrics),
            "latency_seconds": 0.2,
        }

        with (
            patch(
                "tools.probe_maccms.CONFIGURED_SITES",
                [{
                    "name": "promotion-source",
                    "api": "https://source.example/api.php/provide/vod",
                    "origin": "candidate",
                }],
            ),
            patch(
                "tools.probe_maccms.load_coverage_cases",
                return_value=[case],
            ),
            patch(
                "tools.probe_maccms.probe_site",
                new=AsyncMock(return_value=smoke_result),
            ) as probe_smoke,
            patch(
                "tools.probe_maccms.probe_site_coverage",
                new=AsyncMock(return_value=coverage_result),
            ) as probe_coverage,
            patch("tools.probe_maccms._render_coverage_summary"),
        ):
            report = await main([
                "--profile",
                "promotion",
                "--site",
                "promotion-source",
            ])

        probe_smoke.assert_awaited_once()
        probe_coverage.assert_awaited_once()
        self.assertEqual(report["profile"], "promotion")
        self.assertEqual(report["results"][0]["smoke"]["playable"], ["电影"])
        pipeline = report["results"][0]["promotion"]["pipeline"]
        self.assertTrue(pipeline["eligible_for_manual_review"])
        self.assertFalse(pipeline["automatic_promotion"])
        inventory = report["source_inventory"]
        self.assertEqual(inventory["candidate_source_count"], 1)
        self.assertEqual(inventory["smoke_completed_source_count"], 1)
        self.assertEqual(inventory["coverage_completed_source_count"], 1)
        self.assertEqual(inventory["manual_review_eligible_source_count"], 1)

    async def test_coverage_case_runs_alias_detail_episode_and_first_segment(self):
        api_requests: list[tuple[str, str]] = []

        def api_handler(request: httpx.Request) -> httpx.Response:
            alias = request.url.params.get("wd", "")
            vod_id = request.url.params.get("ids", "")
            api_requests.append((alias, vod_id))
            if alias == "Primary Anime":
                return httpx.Response(200, json={"list": []})
            if alias == "Alternate Anime":
                return httpx.Response(200, json={"list": [{
                    "vod_id": "9",
                    "vod_name": "Alternate Anime",
                    "type_name": "动漫",
                    "vod_year": "2025",
                }]})
            if vod_id == "9":
                return httpx.Response(200, json={"list": [{
                    "vod_id": "9",
                    "vod_name": "Alternate Anime",
                    "type_name": "动漫",
                    "vod_year": "2025",
                    "vod_play_url": (
                        "第1集$https://cdn.example/1.m3u8"
                        "#第2集$https://cdn.example/2.m3u8"
                        "#SP$https://cdn.example/sp.m3u8"
                        "#第3集$https://cdn.example/3.m3u8?token=secret"
                        "$$$第3集$https://stale.example/3.m3u8"
                    ),
                }]})
            return httpx.Response(404)

        def media_handler(request: httpx.Request) -> httpx.Response:
            if request.url.host == "stale.example":
                return httpx.Response(404)
            if request.url.path == "/3.m3u8":
                return httpx.Response(
                    200,
                    text="#EXTM3U\n#EXTINF:4,\nsegment.ts\n",
                    headers={"content-type": "application/vnd.apple.mpegurl"},
                )
            if request.url.path == "/segment.ts":
                return httpx.Response(
                    206,
                    content=b"x" * 188,
                    headers={"content-type": "video/mp2t"},
                )
            return httpx.Response(404)

        case = CoverageCase(
            case_id="anime-alias-episode",
            query="Primary Anime",
            aliases=("Alternate Anime",),
            content_type="anime",
            year=2025,
            episode=3,
            tags=("anime", "difficult"),
            subject_id="anime-alias",
            sample_kind="mid_episode",
        )
        site = {
            "name": "coverage-source",
            "api": "https://source.example/api.php/provide/vod",
            "origin": "candidate",
        }
        verifier = ContentAggregator(
            line_http_transport=httpx.MockTransport(media_handler),
            crawler_scrapers={},
            enabled_provider_ids=frozenset(),
        )
        async with httpx.AsyncClient(
            transport=httpx.MockTransport(api_handler),
            trust_env=False,
        ) as client:
            try:
                with (
                    patch(
                        "tools.probe_maccms._is_public_http_url",
                        new=AsyncMock(return_value=True),
                    ),
                    patch(
                        "server.aggregator._is_public_http_url",
                        new=AsyncMock(return_value=True),
                    ),
                ):
                    result = await probe_coverage_case(
                        site,
                        case,
                        verifier,
                        client,
                    )
            finally:
                await verifier.aclose()

        self.assertEqual(
            api_requests,
            [("Primary Anime", ""), ("Alternate Anime", ""), ("", "9")],
        )
        self.assertTrue(result["search_responded"])
        self.assertTrue(result["search_hit"])
        self.assertTrue(result["accepted_match"])
        self.assertEqual(result["subject_id"], "anime-alias")
        self.assertEqual(result["sample_kind"], "mid_episode")
        self.assertEqual(result["matched_alias_index"], 1)
        self.assertEqual(result["matched_alias"], "Alternate Anime")
        self.assertFalse(result["wrong_match"])
        self.assertTrue(result["detail_success"])
        self.assertTrue(result["episode_found"])
        self.assertFalse(result["wrong_episode"])
        self.assertEqual(result["episode_labels"], ["第3集"])
        self.assertEqual(result["episode_mapping_modes"], ["explicit"])
        self.assertTrue(result["server_verified"])
        self.assertFalse(result["deterministic_failure"])
        self.assertEqual(result["matched_title"], "Alternate Anime")
        self.assertEqual(
            result["media_hosts"],
            ["cdn.example", "stale.example"],
        )
        self.assertEqual(result["verified_media_hosts"], ["cdn.example"])
        self.assertNotIn("token", result["checks"][0]["url"])


if __name__ == "__main__":
    unittest.main()
