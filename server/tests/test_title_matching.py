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


if __name__ == "__main__":
    unittest.main()
