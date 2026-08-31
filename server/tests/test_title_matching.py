import unittest

from server.title_matching import analyze_source_match


class SourceTitleMatchingTests(unittest.TestCase):
    def test_exact_season_match_returns_trusted_evidence_and_ranking(self):
        analysis = analyze_source_match(
            "团子大家族第二季",
            ["团子大家族 第二季", "CLANNAD AFTER STORY"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2008,
            expected_year=2008,
        )

        self.assertTrue(analysis.accepted)
        self.assertEqual(analysis.ranking_score, 118)
        self.assertTrue(analysis.evidence.exact_title)
        self.assertEqual(analysis.evidence.matched_alias, "团子大家族 第二季")
        self.assertEqual(analysis.evidence.expected_season, 2)
        self.assertEqual(analysis.evidence.candidate_season, 2)
        self.assertFalse(analysis.evidence.season_conflict)
        self.assertTrue(analysis.evidence.media_type_known)
        self.assertTrue(analysis.evidence.media_type_match)
        self.assertTrue(analysis.evidence.year_known)
        self.assertTrue(analysis.evidence.year_compatible)
        self.assertTrue(analysis.evidence.allows_circuit_recovery)

    def test_broad_alias_cannot_hide_an_explicit_season_conflict(self):
        analysis = analyze_source_match(
            "团子大家族 第一季",
            ["团子大家族 第二季", "团子大家族"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2007,
            expected_year=2008,
        )

        self.assertEqual(analysis.evidence.expected_season, 2)
        self.assertEqual(analysis.evidence.candidate_season, 1)
        self.assertTrue(analysis.evidence.season_conflict)
        self.assertFalse(analysis.playback_eligible)
        self.assertFalse(analysis.evidence.allows_circuit_recovery)

    def test_related_edition_can_rank_without_becoming_recovery_evidence(self):
        analysis = analyze_source_match(
            "熔断诊断测试剧场版",
            ["熔断诊断测试"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2026,
            expected_year=2026,
        )

        self.assertTrue(analysis.accepted)
        self.assertFalse(analysis.evidence.exact_title)
        self.assertFalse(analysis.evidence.safe_title_variant)
        self.assertFalse(analysis.evidence.allows_circuit_recovery)

    def test_explicit_year_conflict_can_rank_but_is_not_playback_eligible(self):
        analysis = analyze_source_match(
            "进击的巨人 最终季 完结篇 后篇",
            ["进击的巨人 最终季", "Attack on Titan Final Season"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2023,
            expected_year=2020,
        )

        self.assertTrue(analysis.accepted)
        self.assertTrue(analysis.evidence.year_known)
        self.assertFalse(analysis.evidence.year_compatible)
        self.assertFalse(analysis.playback_eligible)

    def test_animated_movie_taxonomy_difference_remains_playback_eligible(self):
        analysis = analyze_source_match(
            "千与千寻",
            ["千与千寻", "Spirited Away"],
            candidate_type="anime",
            expected_type="movie",
            candidate_year=2001,
            expected_year=2001,
        )

        self.assertTrue(analysis.accepted)
        self.assertTrue(analysis.evidence.media_type_known)
        self.assertFalse(analysis.evidence.media_type_match)
        self.assertTrue(analysis.evidence.media_type_compatible)
        self.assertTrue(analysis.playback_eligible)
        self.assertTrue(analysis.evidence.allows_circuit_recovery)

    def test_explicitly_incompatible_media_types_are_not_playback_eligible(self):
        analysis = analyze_source_match(
            "同名作品",
            ["同名作品"],
            candidate_type="tv",
            expected_type="movie",
            candidate_year=2024,
            expected_year=2024,
        )

        self.assertTrue(analysis.accepted)
        self.assertTrue(analysis.evidence.media_type_known)
        self.assertFalse(analysis.evidence.media_type_compatible)
        self.assertFalse(analysis.playback_eligible)

    def test_unknown_year_and_type_do_not_create_identity_conflicts(self):
        analysis = analyze_source_match(
            "未知元数据作品",
            ["未知元数据作品"],
            candidate_type="unknown",
            expected_type="anime",
            candidate_year=0,
            expected_year=2024,
        )

        self.assertTrue(analysis.accepted)
        self.assertFalse(analysis.evidence.media_type_known)
        self.assertFalse(analysis.evidence.year_known)
        self.assertTrue(analysis.playback_eligible)


class SeasonYearBaselineTests(unittest.TestCase):
    """各库的年份基准不同(制作年 vs 播出年),标题精确到季时年份不该否决。

    实测:上游把《葬送的芙莉莲 第二季》标为 2026(播出年),而请求侧给 2023,
    ±1 年容差把这个正确的季判成了身份冲突。
    """

    def test_matching_season_survives_a_multi_year_gap(self):
        analysis = analyze_source_match(
            "葬送的芙莉莲 第二季",
            ["葬送的芙莉莲 第二季", "葬送的芙莉莲"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2026,
            expected_year=2023,
        )
        self.assertTrue(analysis.accepted)
        self.assertTrue(analysis.evidence.year_compatible)
        self.assertTrue(analysis.playback_eligible)

    def test_exact_title_survives_a_year_gap(self):
        analysis = analyze_source_match(
            "钢之炼金术师",
            ["钢之炼金术师"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2009,
            expected_year=2003,
        )
        self.assertTrue(analysis.evidence.year_compatible)

    def test_season_conflict_still_wins_over_the_year_allowance(self):
        # 年份放宽不能让错误的季蒙混过关
        analysis = analyze_source_match(
            "葬送的芙莉莲 第三季",
            ["葬送的芙莉莲 第二季"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2026,
            expected_year=2023,
        )
        self.assertTrue(analysis.evidence.season_conflict)
        self.assertFalse(analysis.playback_eligible)

    def test_unrelated_title_with_far_year_is_still_rejected(self):
        analysis = analyze_source_match(
            "Transformers: CYBERWORLD 第二季",
            ["葬送的芙莉莲 第二季"],
            candidate_type="anime",
            expected_type="anime",
            candidate_year=2026,
            expected_year=2023,
        )
        self.assertFalse(analysis.accepted)


class DerivativeContentTests(unittest.TestCase):
    """采集站把预告/解说/前传当独立条目收录,标题与正片高度相似。

    用例全部取自 2026-08-28 在生产出口的实测返回。
    """

    def _analyze(self, candidate: str, alias: str, **kwargs):
        params = {
            "candidate_type": "movie",
            "expected_type": "movie",
            "candidate_year": 2019,
            "expected_year": 2019,
        }
        params.update(kwargs)
        return analyze_source_match(candidate, [alias], **params)

    def test_commentary_edition_is_not_playable_as_the_feature(self):
        analysis = self._analyze("流浪地球[电影解说]", "流浪地球")
        self.assertTrue(analysis.evidence.derivative_conflict)
        self.assertEqual(analysis.evidence.derivative_kind, "derivative")
        self.assertFalse(analysis.playback_eligible)

    def test_trailer_is_not_playable_as_the_feature(self):
        analysis = self._analyze("流浪地球3(上)（预告片）", "流浪地球")
        self.assertTrue(analysis.evidence.derivative_conflict)
        self.assertFalse(analysis.playback_eligible)

    def test_spinoff_series_is_not_playable_as_the_feature(self):
        analysis = self._analyze(
            "权力的游戏前传：龙族",
            "权力的游戏",
            candidate_type="tv",
            expected_type="tv",
            candidate_year=2022,
            expected_year=2011,
        )
        self.assertTrue(analysis.evidence.derivative_conflict)
        self.assertEqual(analysis.evidence.derivative_kind, "spinoff")
        self.assertFalse(analysis.playback_eligible)

    def test_derivative_score_falls_below_the_acceptance_line(self):
        feature = self._analyze("流浪地球", "流浪地球")
        commentary = self._analyze("流浪地球[电影解说]", "流浪地球")
        self.assertTrue(feature.accepted)
        self.assertLess(commentary.ranking_score, feature.ranking_score)
        self.assertFalse(commentary.accepted)

    def test_feature_itself_is_unaffected(self):
        analysis = self._analyze("流浪地球", "流浪地球")
        self.assertFalse(analysis.evidence.derivative_conflict)
        self.assertEqual(analysis.evidence.derivative_kind, "")
        self.assertTrue(analysis.playback_eligible)

    def test_user_asking_for_a_derivative_still_gets_it(self):
        """两边都带标记时不算冲突——用户本就在找解说版。"""
        analysis = self._analyze("流浪地球[电影解说]", "流浪地球 电影解说")
        self.assertFalse(analysis.evidence.derivative_conflict)
        self.assertTrue(analysis.playback_eligible)

    def test_english_markers_are_recognized(self):
        for candidate in (
            "The Wandering Earth Official Trailer",
            "The Wandering Earth - Teaser",
            "The Wandering Earth Recap",
        ):
            analysis = self._analyze(candidate, "The Wandering Earth")
            self.assertTrue(
                analysis.evidence.derivative_conflict, f"未识别: {candidate}"
            )

    def test_circuit_recovery_is_denied_for_derivatives(self):
        analysis = self._analyze("流浪地球（预告片）", "流浪地球")
        self.assertFalse(analysis.evidence.allows_circuit_recovery)


if __name__ == "__main__":
    unittest.main()
