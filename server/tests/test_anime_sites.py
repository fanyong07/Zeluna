import unittest

from server.scrapers.anime.anime_sites import (
    ANIME_DOMAIN_FAMILIES,
    ANIME_SITES,
    family_of,
    site_entry,
    sites_by_status,
    usable_sites,
)
from server.scrapers.anime.site_base import (
    SITE_STATUS_DEAD,
    SITE_STATUS_OK,
    SITE_STATUS_PARSED_DEAD,
    SITE_STATUSES,
)


class AnimeSitesTableTests(unittest.TestCase):
    def test_every_row_has_required_fields(self):
        required = {"site", "family", "base", "status", "lines", "search",
                    "verified_at", "notes"}
        for row in ANIME_SITES:
            self.assertTrue(required <= set(row), f"{row.get('site')} 缺字段")

    def test_status_values_use_the_three_valued_vocabulary(self):
        for row in ANIME_SITES:
            self.assertIn(row["status"], SITE_STATUSES, row["site"])

    def test_site_identifiers_are_unique(self):
        names = [row["site"] for row in ANIME_SITES]
        self.assertEqual(len(names), len(set(names)))

    def test_bases_are_https_or_explicit_http(self):
        for row in ANIME_SITES:
            self.assertTrue(
                row["base"].startswith(("https://", "http://")), row["site"]
            )

    def test_usable_sites_are_exactly_the_ok_rows(self):
        usable = {row["site"] for row in usable_sites()}
        self.assertEqual(usable, {"yhdmm", "girigiri"})
        for row in usable_sites():
            self.assertGreater(row["lines"], 0, row["site"])

    def test_parsed_dead_rows_document_zero_playable_lines(self):
        rows = sites_by_status(SITE_STATUS_PARSED_DEAD)
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(row["lines"], 0, row["site"])
            # parsed-dead 的意义在于"解析对了、货源没了",必须写明依据
            self.assertTrue(row["notes"].strip(), row["site"])

    def test_dead_rows_exist_and_carry_reason(self):
        rows = sites_by_status(SITE_STATUS_DEAD)
        self.assertTrue(rows)
        for row in rows:
            self.assertTrue(row["notes"].strip(), row["site"])

    def test_lookup_helpers(self):
        entry = site_entry("yhdmm")
        self.assertIsNotNone(entry)
        self.assertEqual(entry["status"], SITE_STATUS_OK)
        self.assertEqual(family_of("yhdmm"), "yinghua")
        self.assertIsNone(site_entry("does-not-exist"))
        self.assertEqual(family_of("does-not-exist"), "")

    def test_search_mode_is_declared(self):
        for row in ANIME_SITES:
            self.assertIn(row["search"], {"site", "index", "none"}, row["site"])


class DomainFamilyTests(unittest.TestCase):
    def test_every_site_family_has_candidate_domains(self):
        families = set(ANIME_DOMAIN_FAMILIES)
        for row in ANIME_SITES:
            self.assertIn(row["family"], families, row["site"])

    def test_family_candidates_are_unique_and_absolute(self):
        for family, bases in ANIME_DOMAIN_FAMILIES.items():
            self.assertEqual(len(bases), len(set(bases)), family)
            for base in bases:
                self.assertTrue(base.startswith("https://"), f"{family}: {base}")

    def test_ok_site_base_is_listed_in_its_family(self):
        for row in usable_sites():
            self.assertIn(
                row["base"], ANIME_DOMAIN_FAMILIES[row["family"]], row["site"]
            )


if __name__ == "__main__":
    unittest.main()
