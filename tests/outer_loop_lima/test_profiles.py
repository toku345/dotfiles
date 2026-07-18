from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))


class ProfileTests(unittest.TestCase):
    def test_profiles_are_static_and_disable_integration_surfaces(self) -> None:
        for runtime in ("codex", "claude"):
            profile = (HARNESS / "profiles" / f"week0-{runtime}.yaml").read_text()
            self.assertNotIn("{{", profile)
            self.assertIn("vmType: vz", profile)
            self.assertIn("arch: aarch64", profile)
            self.assertIn("cpus: 4", profile)
            self.assertIn("memory: 8GiB", profile)
            self.assertIn("disk: 40GiB", profile)
            self.assertIn("mounts: []", profile)
            self.assertIn("additionalDisks: []", profile)
            self.assertIn("networks: []", profile)
            self.assertIn("portForwards: []", profile)
            self.assertIn("plain: true", profile)
            self.assertIn("forwardAgent: false", profile)
            self.assertIn("forwardX11: false", profile)
            self.assertIn("system: false", profile)
            self.assertIn("user: false", profile)

    def test_claude_managed_policy_has_no_auxiliary_escape(self) -> None:
        settings = json.loads(
            (HARNESS / "seeds" / "claude" / "managed-settings.json").read_text()
        )
        self.assertTrue(settings["sandbox"]["enabled"])
        self.assertTrue(settings["sandbox"]["failIfUnavailable"])
        self.assertFalse(settings["sandbox"]["allowUnsandboxedCommands"])
        self.assertEqual(settings["sandbox"]["network"]["allowedDomains"], [])
        self.assertEqual(settings["allowedMcpServers"], [])
        self.assertTrue(settings["disableAllHooks"])
        self.assertTrue(settings["disableSideloadFlags"])
        self.assertIn("WebFetch", settings["permissions"]["deny"])
        self.assertIn("WebSearch", settings["permissions"]["deny"])

    def test_app_armor_change_is_narrow_to_bwrap_userns(self) -> None:
        profile = (HARNESS / "guest" / "apparmor" / "bwrap").read_text()
        self.assertIn("/usr/bin/bwrap", profile)
        self.assertIn("userns,", profile)
        self.assertNotIn("sysctl", profile)


if __name__ == "__main__":
    unittest.main()
