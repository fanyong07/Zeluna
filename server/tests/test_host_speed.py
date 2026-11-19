"""``host_speed`` 跨源主机速度先验的固化测试。

先验是**排序优化**,不是正确性判定:它只在同一档位内破平,样本不足时必须
退化到原顺序。测试覆盖这两条边界。
"""

from __future__ import annotations

import unittest

from server.host_speed import HostSpeedPrior, hostname_of


class HostnameTests(unittest.TestCase):
    def test_extracts_lowercased_hostname(self):
        self.assertEqual(hostname_of("https://CDN.Example.com/a/b.m3u8"), "cdn.example.com")

    def test_malformed_input_returns_empty(self):
        for url in ("", "not-a-url", "https://", "http://[bad"):
            with self.subTest(url=url):
                self.assertEqual(hostname_of(url), "")


class ObserveTests(unittest.TestCase):
    def test_single_observation_is_not_enough_to_predict(self):
        prior = HostSpeedPrior()
        prior.observe("https://a.example/x.m3u8", 400)
        self.assertIsNone(prior.predict("https://a.example/x.m3u8"))
        self.assertEqual(prior.observations("https://a.example/x.m3u8"), 1)

    def test_two_observations_enable_prediction(self):
        prior = HostSpeedPrior()
        prior.observe("https://a.example/x.m3u8", 400)
        prior.observe("https://a.example/x.m3u8", 400)
        self.assertAlmostEqual(prior.predict("https://a.example/x.m3u8"), 400.0, places=1)

    def test_ema_moves_toward_new_observations(self):
        prior = HostSpeedPrior(alpha=0.5)
        for _ in range(2):
            prior.observe("https://a.example/x.m3u8", 1000)
        before = prior.predict("https://a.example/x.m3u8")
        prior.observe("https://a.example/x.m3u8", 200)
        after = prior.predict("https://a.example/x.m3u8")
        self.assertLess(after, before)
        self.assertGreater(after, 200)          # 不是直接跳过去,而是折中

    def test_observations_are_per_host_not_per_url(self):
        prior = HostSpeedPrior()
        prior.observe("https://cdn.example/a.m3u8", 500)
        prior.observe("https://cdn.example/b/c.m3u8", 500)
        # 两个不同路径、同一主机 → 已足够预测
        self.assertIsNotNone(prior.predict("https://cdn.example/completely/other.m3u8"))

    def test_implausible_latency_is_ignored(self):
        prior = HostSpeedPrior()
        for bad in (0, -50, 1, 10, 90_000, None, "abc", float("nan")):
            with self.subTest(value=bad):
                prior.observe("https://a.example/x", bad)
        self.assertEqual(len(prior), 0)

    def test_unknown_host_predicts_none(self):
        prior = HostSpeedPrior()
        self.assertIsNone(prior.predict("https://never-seen.example/x.m3u8"))

    def test_lru_eviction_is_bounded(self):
        prior = HostSpeedPrior(max_hosts=3)
        for i in range(6):
            prior.observe(f"https://h{i}.example/x", 400)
            prior.observe(f"https://h{i}.example/x", 400)
        self.assertEqual(len(prior), 3)
        # 最早的被淘汰
        self.assertIsNone(prior.predict("https://h0.example/x"))
        self.assertIsNotNone(prior.predict("https://h5.example/x"))

    def test_sort_key_sinks_hosts_without_prior(self):
        prior = HostSpeedPrior()
        for _ in range(2):
            prior.observe("https://fast.example/x", 300)
        keys = {
            "known": prior.sort_key("https://fast.example/y"),
            "unknown": prior.sort_key("https://slow.example/y"),
        }
        self.assertLess(keys["known"], keys["unknown"])
        self.assertEqual(keys["known"], 300.0)

    def test_clear_resets_state(self):
        prior = HostSpeedPrior()
        prior.observe("https://a.example/x", 400)
        prior.clear()
        self.assertEqual(len(prior), 0)


if __name__ == "__main__":
    unittest.main()
