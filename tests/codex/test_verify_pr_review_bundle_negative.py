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
    (repo / "docs" / "design").mkdir(parents=True)
    shutil.copy2(REPO_ROOT / "docs" / "codex.md", repo / "docs" / "codex.md")
    shutil.copy2(
        REPO_ROOT / "docs" / "design" / "codex-pr-review.md",
        repo / "docs" / "design" / "codex-pr-review.md",
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
            "review profile model downgrade",
            "private_dot_codex/private_review.config.toml",
            'model = "gpt-5.6-sol"',
            'model = "gpt-5.5"',
            "model must be 'gpt-5.6-sol'",
        ),
        (
            "review profile pins legacy V1",
            "private_dot_codex/private_review.config.toml",
            "multi_agent = true",
            "multi_agent = true\nmulti_agent_v2 = false",
            "features.multi_agent_v2 must not be pinned",
        ),
        (
            "V1/V2 runtime gate sentinel removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "PR_REVIEW_RUNTIME_CONTRACT_V1_V2",
            "PR_REVIEW_RUNTIME_CONTRACT_REMOVED",
            "PR_REVIEW_RUNTIME_CONTRACT_V1_V2",
        ),
        (
            "V1 spawn discriminator removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "must not accept `task_name` or `fork_turns`",
            "may accept `task_name` and `fork_turns`",
            "must not accept `task_name` or `fork_turns`",
        ),
        (
            "V1 required arguments weakened",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "with both arguments required",
            "with both arguments optional",
            "both arguments required",
        ),
        (
            "V1 targeted wait removed",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "targeted `wait_agent(targets)`",
            "untargeted `wait_agent(timeout_ms?)`",
            "targeted `wait_agent(targets)`",
        ),
        (
            "V1 close primitive removed",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "`close_agent(agent_id)`",
            "`interrupt_agent(agent_id)`",
            "`close_agent(agent_id)`",
        ),
        (
            "V2 full spawn signature weakened",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "`spawn_agent(task_name,message,agent_type?,fork_turns?,model?,reasoning_effort?)`",
            "`spawn_agent(task_name,message)`",
            "`spawn_agent(task_name,message,agent_type?,fork_turns?,model?,reasoning_effort?)`",
        ),
        (
            "V2 required identity fields weakened",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "with `task_name` and `message` required",
            "with all fields optional",
            "with `task_name` and `message` required",
        ),
        (
            "V2 untargeted wait removed",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "untargeted `wait_agent(timeout_ms?)`",
            "targeted `wait_agent(targets)`",
            "untargeted `wait_agent(timeout_ms?)`",
        ),
        (
            "V2 list primitive removed",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "`list_agents(path_prefix?)`",
            "`get_agent_status(path_prefix?)`",
            "`list_agents(path_prefix?)`",
        ),
        (
            "V2 interrupt primitive removed",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "`interrupt_agent(target)`",
            "`close_agent(target)`",
            "`interrupt_agent(target)`",
        ),
        (
            "V2 targeted wait admitted",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "must not accept `targets`",
            "may accept `targets`",
            "must not accept `targets`",
        ),
        (
            "V2 close_agent admitted",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "`close_agent` must not be part of this family",
            "`close_agent` may be part of this family",
            "`close_agent` must not be part of this family",
        ),
        (
            "optional schema extension policy removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Optional unrelated, non-discriminating fields may be present",
            "No optional fields may be present",
            "Optional unrelated, non-discriminating fields may be present",
        ),
        (
            "V2 fresh-tree precondition removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "**fresh agent tree**",
            "**existing agent tree**",
            "fresh agent tree",
        ),
        (
            "V2 concurrency cap inflation",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "**maximum of 3** children concurrently",
            "**maximum of 4** children concurrently",
            "maximum of 3",
        ),
        (
            "V2 owned task prefix removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "`prr_<run_token>_s<stage>_",
            "`<run_token>_s<stage>_",
            "`prr_<run_token>_s<stage>_",
        ),
        (
            "V2 fork isolation removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            'Every spawn must set `fork_turns="none"`.',
            "Every spawn may inherit the parent transcript.",
            'fork_turns="none"',
        ),
        (
            "exact specialist role fallback enabled",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "omission and generic/default role fallback are forbidden",
            "generic/default role fallback is allowed",
            "omission and generic/default role fallback are forbidden",
        ),
        (
            "V2 authoritative result weakening",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "The only authoritative review body is",
            "An advisory review body is",
            "The only authoritative review body",
        ),
        (
            "V2 recipient confused with sender",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "`Task name` identifies the recipient",
            "`Task name` identifies the child",
            "`Task name` identifies the recipient",
        ),
        (
            "V2 terminal evidence removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "valid final payload plus completed terminal status",
            "valid final payload",
            "valid final payload plus completed terminal status",
        ),
        (
            "V2 pre-usable disappearance tolerated",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "task disappearance** before usability is fatal",
            "task disappearance** before usability is tolerated",
            "task disappearance** before usability is fatal",
        ),
        (
            "V2 bounded poll removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "min(60000 ms, remaining stage budget, earliest active delivery-grace budget)",
            "remaining stage budget",
            "min(60000 ms, remaining stage budget, earliest active delivery-grace budget)",
        ),
        (
            "V2 ambiguous spawn retry weakening",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "**explicit capacity error**",
            "**any spawn error**",
            "explicit capacity error",
        ),
        (
            "V2 partial aggregation enabled",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "**Partial aggregation is forbidden**",
            "**Partial aggregation is allowed**",
            "Partial aggregation is forbidden",
        ),
        (
            "V2 refill before delivered-result validation",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "harvest and validate **all** newly delivered run-owned finals before refilling any slot",
            "refill a slot after validating any one delivered final",
            "harvest and validate **all** newly delivered run-owned finals before refilling any slot",
        ),
        (
            "V2 final cleanup drain removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "one final notification/status drain",
            "immediate interruption pass",
            "one final notification/status drain",
        ),
        (
            "V2 cleanup confirmation removal",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "no run-owned task or owned descendant remains running",
            "cleanup was requested",
            "no run-owned task or owned descendant remains running",
        ),
        (
            "V2 foreign interrupt allowed",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Never interrupt the orchestrator or an unrelated path",
            "Interrupt any running path to free capacity",
            "Never interrupt the orchestrator or an unrelated path",
        ),
        (
            "V2 cleanup running ownership weakened",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "only on a still-running run-owned top-level task",
            "on any top-level task",
            "only on a still-running run-owned top-level task",
        ),
        (
            "V2 Stage 2 adapter switch allowed",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Use the selected adapter without switching families",
            "Use any available adapter and switch families if needed",
            "Use the selected adapter without switching families",
        ),
        (
            "specialist control-plane isolation removal",
            "private_dot_codex/agents/code-reviewer.toml",
            "do not call any collaboration or subagent control-plane tool",
            "may call collaboration tools",
            "do not call any collaboration or subagent control-plane tool",
        ),
        (
            "documented V1 rollback pin removal",
            "docs/codex.md",
            "-c 'features.multi_agent_v2=false'",
            "-c 'features.multi_agent_v2=true'",
            "features.multi_agent_v2=false",
        ),
        (
            "documented V1 rollback effort removal",
            "docs/codex.md",
            "  -c 'model_reasoning_effort=\"medium\"' \\\n",
            "",
            "model_reasoning_effort",
        ),
        (
            "documented V1 rollback effort drift",
            "docs/design/codex-pr-review.md",
            "-c 'model_reasoning_effort=\"medium\"'",
            "-c 'model_reasoning_effort=\"high\"'",
            "model_reasoning_effort",
        ),
        (
            "HEAD pin sequencing weakened",
            "private_dot_codex/skills/pr-review/SKILL.md",
            "Do not put HEAD recording in the same parallel tool call",
            "HEAD recording may share a parallel tool call",
            "Do not put HEAD recording in the same parallel tool call",
        ),
        (
            "immutable HEAD_REF collection weakened",
            "private_dot_codex/skills/pr-review/SKILL.md",
            'git log --no-decorate "$BASE_COMMIT..$HEAD_REF"',
            'git log --no-decorate "$BASE_COMMIT..HEAD"',
            'git log --no-decorate "$BASE_COMMIT..$HEAD_REF"',
        ),
        (
            "post-merge apply boundary removal",
            "docs/codex.md",
            "`chezmoi apply` は変更を main に merge した後だけ実行する",
            "`chezmoi apply` は merge 前に実行する",
            "merge した後だけ",
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

        missing_profile_repo = copy_fixture_repo(root / "missing-review-profile")
        (missing_profile_repo / "private_dot_codex/private_review.config.toml").unlink()
        assert_fails_closed(
            "missing review profile",
            missing_profile_repo,
            "missing Codex review profile",
        )

        hidden_metadata_repo = copy_fixture_repo(root / "hidden-spawn-metadata")
        agent_path = hidden_metadata_repo / "private_dot_codex/agents/code-reviewer.toml"
        agent_path.write_text(
            agent_path.read_text(encoding="utf-8")
            + "\n[features.multi_agent_v2]\nhide_spawn_agent_metadata = false\n",
            encoding="utf-8",
        )
        assert_fails_closed(
            "hide_spawn_agent_metadata setting added",
            hidden_metadata_repo,
            "hide_spawn_agent_metadata must not be configured",
        )

    print("OK: pr-review verifier negative tests passed")


if __name__ == "__main__":
    main()
