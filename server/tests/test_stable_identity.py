import json
import unittest
from pathlib import Path

from server.stable_identity import (
    STABLE_IDENTITY_VERSION,
    canonical_identity_uri,
    stable_digest,
    stable_download_task_key,
    stable_episode_key,
    stable_header_fingerprint,
    stable_int63,
    stable_playback_line_key,
    stable_rule_key,
    stable_subject_key,
)


_FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "test"
    / "fixtures"
    / "stable_identity_vectors.json"
)


class StableIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = json.loads(_FIXTURE_PATH.read_text(encoding="utf-8"))

    def test_digest_vectors(self) -> None:
        self.assertEqual(self.fixture["version"], STABLE_IDENTITY_VERSION)
        for vector in self.fixture["digests"]:
            self.assertEqual(stable_digest(vector["input"]), vector["expected"])

    def test_subject_and_episode_vectors(self) -> None:
        for vector in self.fixture["subjects"]:
            self.assertEqual(
                stable_subject_key(vector["source"], vector["identifier"]),
                vector["expected"],
            )
        for vector in self.fixture["episodes"]:
            self.assertEqual(
                stable_episode_key(vector["subjectKey"], vector["number"]),
                vector["expected"],
            )

    def test_uri_vectors_preserve_query_order(self) -> None:
        for vector in self.fixture["uris"]:
            self.assertEqual(
                canonical_identity_uri(vector["input"]), vector["expected"]
            )
        self.assertNotEqual(
            canonical_identity_uri("https://example.test/v?b=2&a=1"),
            canonical_identity_uri("https://example.test/v?a=1&b=2"),
        )
        with self.assertRaises(ValueError):
            canonical_identity_uri("/relative/video.m3u8")

    def test_header_vectors_hash_sensitive_values(self) -> None:
        for vector in self.fixture["headers"]:
            headers = vector["input"]
            fingerprint = stable_header_fingerprint(headers)
            self.assertEqual(fingerprint, vector["expected"])
            self.assertNotIn("value-one", fingerprint)
            self.assertNotIn("session=value-two", fingerprint)
            self.assertEqual(
                stable_header_fingerprint(
                    {**headers, "Range": "bytes=4096-8192"}
                ),
                fingerprint,
            )
            self.assertNotEqual(
                stable_header_fingerprint(
                    {**headers, "Authorization": "value-three"}
                ),
                fingerprint,
            )

    def test_entity_vectors(self) -> None:
        for vector in self.fixture["playbackLines"]:
            self.assertEqual(
                stable_playback_line_key(
                    vector["providerId"],
                    vector["episodeKey"],
                    vector["uri"],
                    vector["headers"],
                ),
                vector["expected"],
            )
        for vector in self.fixture["downloads"]:
            self.assertEqual(
                stable_download_task_key(
                    vector["subjectKey"],
                    vector["episodeKey"],
                    vector["providerId"],
                ),
                vector["expected"],
            )
        for vector in self.fixture["rules"]:
            self.assertEqual(
                stable_rule_key(
                    vector["ruleId"],
                    vector["engine"],
                    vector["sourceRepository"],
                    vector["contentHash"],
                ),
                vector["expected"],
            )
        for vector in self.fixture["int63"]:
            value = stable_int63(vector["input"])
            self.assertEqual(value, vector["expected"])
            self.assertGreaterEqual(value, 1)
            self.assertLessEqual(value, (1 << 63) - 1)


if __name__ == "__main__":
    unittest.main()
