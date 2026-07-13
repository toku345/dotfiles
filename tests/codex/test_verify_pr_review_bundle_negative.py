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
    shutil.copytree(
        REPO_ROOT / "private_dot_claude" / "skills" / "pr-review" / "references",
        repo / "private_dot_claude" / "skills" / "pr-review" / "references",
    )
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
        (
            "output caps inflation",
            "private_dot_codex/skills/pr-review/references/severity-rules.json",
            '"important": 5',
            '"important": 50',
            "output_caps mismatch",
        ),
        (
            "critical guard weakening",
            "private_dot_codex/skills/pr-review/references/severity-rules.json",
            "merge-blocking risk",
            "noteworthy concern",
            "critical.guard",
        ),
        (
            "claude share template inlined (drift bypass)",
            "private_dot_claude/skills/pr-review/references/severity-rules.json.tmpl",
            'include "private_dot_codex/skills/pr-review/references/severity-rules.json"',
            'print "inlined-weakened-table"',
            "severity-rules.json.tmpl",
        ),
        (
            "v2 metadata hidden",
            "private_dot_codex/private_config.chezmoi.toml",
            "hide_spawn_agent_metadata = false",
            "hide_spawn_agent_metadata = true",
            "features.multi_agent_v2 must configure metadata visibility only",
        ),
        (
            "v2 forced enabled in baseline",
            "private_dot_codex/private_config.chezmoi.toml",
            "hide_spawn_agent_metadata = false",
            "enabled = true\nhide_spawn_agent_metadata = false",
            "features.multi_agent_v2 must configure metadata visibility only",
        ),
        (
            "v2 child metadata exposed",
            "private_dot_codex/agents/code-reviewer.toml",
            "hide_spawn_agent_metadata = true",
            "hide_spawn_agent_metadata = false",
            "child role must re-hide V2 spawn metadata",
        ),
        (
            "v2 fourth concurrent specialist",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "allow at most 3 running specialists because the default four-thread session limit includes the root",
            "allow at most 4 running specialists",
            "allow at most 3 running specialists because the default four-thread session limit includes the root",
        ),
        (
            "mixed schema fallback",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Fail closed before spawning on a mixed or unknown shape.",
            "Continue with V1 on a mixed or unknown shape.",
            "Fail closed before spawning on a mixed or unknown shape.",
        ),
        (
            "generic role fallback",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "never fall back to the generic/default role",
            "fall back to the generic/default role",
            "never fall back to the generic/default role",
        ),
        (
            "v2 spawn before harvest",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Only after this harvest may the next pending specialist be spawned.",
            "Spawn the next pending specialist before harvesting.",
            "Only after this harvest may the next pending specialist be spawned.",
        ),
        (
            "task name sanitizes run token only",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "normalize the **entire task name**, not only the run token",
            "normalize the run token only",
            "normalize the **entire task name**, not only the run token",
        ),
        (
            "v2 full history fork",
            "private_dot_codex/skills/pr-review/SKILL.md",
            'V2 spawn arguments are `agent_type`, `task_name`, `message`, and `fork_turns = "none"`',
            'V2 spawn arguments are `agent_type`, `task_name`, `message`, and `fork_turns = "all"`',
            'V2 spawn arguments are `agent_type`, `task_name`, `message`, and `fork_turns = "none"`',
        ),
        (
            "v2 child model override",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Do not pass `model`, `reasoning_effort`, or `service_tier`; inherit the parent settings.",
            "Pass `model`, `reasoning_effort`, and `service_tier` overrides.",
            "Do not pass `model`, `reasoning_effort`, or `service_tier`; inherit the parent settings.",
        ),
        (
            "v2 wait assumes targets",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "It accepts no targets and its return value contains no specialist result.",
            "It accepts targets and returns specialist results.",
            "its return value contains no specialist result",
        ),
        (
            "v2 missing result retries fail open",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Do not retry a task that disappeared from `list_agents` and do not aggregate partial results.",
            "Retry a task that disappeared from `list_agents` and aggregate available results.",
            "Do not retry a task that disappeared from `list_agents` and do not aggregate partial results.",
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
