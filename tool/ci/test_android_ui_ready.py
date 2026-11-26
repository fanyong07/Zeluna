"""Behavior checks for the rendered-home Android smoke boundary."""

from __future__ import annotations

import math
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from tool.ci.android_ui_ready import is_home_visible, wait_for_home

HOME = '<hierarchy><node package="app.anime.anime" content-desc="首页"/><node package="app.anime.anime" text="我的"/><node package="app.anime.anime" content-desc="新番时间表"/></hierarchy>'
STARTUP = '<hierarchy><node package="app.anime.anime" content-desc="Zeluna 正在启动"/></hierarchy>'


class AndroidHomeReadinessTests(unittest.TestCase):
    def test_requires_real_app_navigation_not_startup_or_another_app(self):
        for xml in (
            "",
            "broken xml",
            "<hierarchy/>",
            STARTUP,
            HOME.replace("app.anime.anime", "com.android.launcher"),
            HOME.replace('text="我的"', 'text="网络错误，请重试"'),
            HOME.replace('content-desc="首页"', 'content-desc="返回首页"'),
            HOME.replace('text="我的"', 'text="我的" visible-to-user="false"'),
            HOME.replace(
                "</hierarchy>",
                '<node package="app.anime.anime" text="Zeluna 正在启动"/></hierarchy>',
            ),
        ):
            with self.subTest(xml=xml):
                self.assertFalse(is_home_visible(xml))

    def test_navigation_alone_or_search_error_is_not_the_home_page(self):
        navigation = HOME.replace(
            '<node package="app.anime.anime" content-desc="新番时间表"/>', ""
        )
        self.assertFalse(is_home_visible(navigation))
        error = navigation.replace(
            "</hierarchy>",
            '<node package="app.anime.anime" text="搜索暂时失败，请检查网络后重试。"/></hierarchy>',
        )
        self.assertFalse(is_home_visible(error))

    def test_accepts_portrait_and_landscape_navigation_with_semantics_suffix(self):
        self.assertTrue(is_home_visible(HOME))
        self.assertTrue(
            is_home_visible(HOME.replace('text="我的"', 'content-desc="我的内容"'))
        )
        self.assertTrue(
            is_home_visible(
                HOME.replace(
                    'content-desc="首页"',
                    'content-desc="首页&#10;第 1 个标签，共 3 个"',
                )
            )
        )

    def test_waits_until_home_and_saves_only_observed_ui(self):
        trees = iter((STARTUP, HOME))

        def adb(command, **kwargs):
            self.assertGreater(kwargs["timeout"], 0)
            self.assertLessEqual(kwargs["timeout"], 15)
            xml = next(trees) if command[1:3] == ["exec-out", "cat"] else ""
            return subprocess.CompletedProcess(command, 0, stdout=xml)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ui.xml"
            with patch("subprocess.run", side_effect=adb) as run, patch("time.sleep"):
                wait_for_home(output, 2)
            self.assertEqual(output.read_text(encoding="utf-8"), HOME)
            commands = [call.args[0][1:4] for call in run.call_args_list]
            self.assertEqual(commands[0], ["shell", "rm", "-f"])
            self.assertEqual(commands[3], ["shell", "rm", "-f"])

    def test_blank_ui_times_out_instead_of_passing_or_waiting_forever(self):
        def adb(command, **kwargs):
            self.assertLessEqual(kwargs["timeout"], 0.05)
            return subprocess.CompletedProcess(command, 0, stdout=STARTUP)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ui.xml"
            start = time.monotonic()
            with (
                patch("subprocess.run", side_effect=adb),
                self.assertRaises(TimeoutError),
            ):
                wait_for_home(output, 0.05)
            self.assertLess(time.monotonic() - start, 1)
            self.assertEqual(output.read_text(encoding="utf-8"), STARTUP)

    def test_adb_timeout_is_bounded_and_cannot_pass_using_stale_xml(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ui.xml"
            output.write_text(HOME, encoding="utf-8")
            error = subprocess.TimeoutExpired(["adb"], 0.05)
            with (
                patch("subprocess.run", side_effect=error),
                self.assertRaises(TimeoutError),
            ):
                wait_for_home(output, 0.05)

    def test_rejects_non_positive_or_unbounded_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ui.xml"
            for value in (0, -1, math.nan, math.inf):
                with self.subTest(timeout=value), self.assertRaises(ValueError):
                    wait_for_home(output, value)


if __name__ == "__main__":
    unittest.main()
