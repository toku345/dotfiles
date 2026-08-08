from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
BASE = "0df8b37005faabff6af73ffffff62470643ae134"
PROTECTED = (
    "docs/outer-loop/week0-v1",
    "docs/outer-loop/week0-v2",
    "docs/adr/0030-codex-claude-outer-loop-pilot.md",
    "docs/adr/0031-outer-loop-week0-v2-hard-link-boundary.md",
)


class ProtectedHistoryTests(unittest.TestCase):
    def test_protected_inputs_are_unchanged_from_implementation_base(self) -> None:
        subprocess.run(
            ["git", "cat-file", "-e", f"{BASE}^{{commit}}"],
            cwd=ROOT,
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "diff", "--exit-code", BASE, "--", *PROTECTED],
            cwd=ROOT,
            check=True,
            capture_output=True,
        )


if __name__ == "__main__":
    unittest.main()
