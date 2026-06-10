#!/usr/bin/env python3
"""Negative tests for the Codex pr-review bundle verifier.

The verifier proves the current bundle is valid. These tests prove selected
high-risk regressions make the verifier fail closed.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = pathlib.Path("tests/codex/verify_pr_review_bundle.py")


def copy_fixture_repo(tmpdir: pathlib.Path) -> pathlib.Path:
    repo = tmpdir / "repo"
    (repo / "tests" / "codex").mkdir(parents=True)
    shutil.copy2(REPO_ROOT / VERIFY_SCRIPT, repo / VERIFY_SCRIPT)
    shutil.copytree(REPO_ROOT / "private_dot_codex", repo / "private_dot_codex")
    return repo


def run_verifier(repo: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(VERIFY_SCRIPT)],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    raw = path.read_text(encoding="utf-8")
    if old not in raw:
        raise AssertionError(f"{path}: fixture text not found: {old!r}")
    path.write_text(raw.replace(old, new, 1), encoding="utf-8")


def assert_fails_closed(name: str, repo: pathlib.Path, expected: str) -> None:
    result = run_verifier(repo)
    if result.returncode == 0:
        raise AssertionError(f"{name}: verifier unexpectedly passed")
    combined = f"{result.stdout}\n{result.stderr}"
    if expected not in combined:
        raise AssertionError(
            f"{name}: expected {expected!r} in verifier output\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )


def main() -> None:
    mutations = [
        (
            "coverage-sentinel contract removal",
            "private_dot_codex/agents/code-reviewer.toml",
            "COVERAGE_OK code-reviewer $BASE_COMMIT...$HEAD_REF",
            "COVERAGE_MISSING code-reviewer $BASE_COMMIT...$HEAD_REF",
            "COVERAGE_OK code-reviewer $BASE_COMMIT...$HEAD_REF",
        ),
        (
            "license hash drift",
            "private_dot_codex/agents/LICENSE-codex-plugin-cc",
            "Apache License",
            "Apache License modified",
            "sha256 mismatch",
        ),
        (
            "fatal coverage handling removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Fail closed before Stage 2 or aggregation if any specialist output reports a fatal coverage error",
            "coverage warning",
            "Fail closed before Stage 2 or aggregation if any specialist output reports a fatal coverage error",
        ),
        (
            "packet verification removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "The diff packet is authoritative",
            "The diff packet is advisory",
            "The diff packet is authoritative",
        ),
        (
            "severity table threshold weakening",
            "private_dot_codex/skills/pr-review/references/severity-rules.json",
            '"min": 90',
            '"min": 99',
            "critical.any_of mismatch",
        ),
        (
            "severity table sentinel drift",
            "private_dot_codex/skills/pr-review/references/severity-rules.json",
            "PR_REVIEW_SEVERITY_RULES_V1",
            "PR_REVIEW_SEVERITY_RULES_V0",
            "sentinel mismatch",
        ),
    ]

    with tempfile.TemporaryDirectory(prefix="pr-review-verifier-negative-") as tmp:
        root = pathlib.Path(tmp)

        baseline_repo = copy_fixture_repo(root / "baseline")
        baseline = run_verifier(baseline_repo)
        if baseline.returncode != 0:
            raise AssertionError(
                "baseline verifier failed before mutations\n"
                f"stdout:\n{baseline.stdout}\n"
                f"stderr:\n{baseline.stderr}"
            )

        for index, (name, rel_path, old, new, expected) in enumerate(mutations):
            repo = copy_fixture_repo(root / f"case-{index}")
            replace_once(repo / rel_path, old, new)
            assert_fails_closed(name, repo, expected)

    print("OK: pr-review verifier negative tests passed")


if __name__ == "__main__":
    main()
