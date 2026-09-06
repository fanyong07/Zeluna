"""Keep Android CI's portrait/landscape assertions aligned with the launcher."""
from __future__ import annotations

import shlex
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ANDROID_NAME = "{http://schemas.android.com/apk/res/android}name"
PACKAGE = "app.anime.anime"


class AndroidLauncherContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        manifest = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml")
        cls.launchers = []
        for activity in manifest.findall("application/activity"):
            for intent in activity.findall("intent-filter"):
                actions = {item.get(ANDROID_NAME) for item in intent.findall("action")}
                categories = {item.get(ANDROID_NAME) for item in intent.findall("category")}
                if (
                    "android.intent.action.MAIN" in actions
                    and "android.intent.category.LAUNCHER" in categories
                ):
                    cls.launchers.append(activity.get(ANDROID_NAME))
        cls.workflow = (ROOT / ".github/workflows/quality.yml").read_text(encoding="utf-8")

    def test_installed_launcher_component_is_preserved(self):
        self.assertEqual(self.launchers, [".SplashActivity"])

    def assert_smoke_checks_launcher(self, filename):
        self.assertEqual(len(self.launchers), 1, "Exactly one launcher is required.")
        expected_component = f"{PACKAGE}/{self.launchers[0]}"
        commands = []
        for line in self.workflow.splitlines():
            if line.lstrip().startswith("grep "):
                words = shlex.split(line.strip())
                if filename in words:
                    commands.append(words)
        self.assertEqual(len(commands), 1, f"Keep one foreground check for {filename}.")
        command = commands[0]
        self.assertGreaterEqual(len(command), 4)
        self.assertEqual(
            command[2],
            expected_component,
            f"{filename} must check the declared launcher, not its Kotlin superclass.",
        )
        # Require a literal, fatal assertion: no alternate activity or `|| true`.
        self.assertEqual(command, ["grep", "-Fq", expected_component, filename])

    def test_portrait_smoke_checks_declared_launcher(self):
        self.assert_smoke_checks_launcher("resumed-activity.txt")

    def test_landscape_smoke_checks_declared_launcher(self):
        self.assert_smoke_checks_launcher("resumed-activity-landscape.txt")


if __name__ == "__main__":
    unittest.main()
