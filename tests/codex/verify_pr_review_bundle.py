#!/usr/bin/env python3
"""Static verifier for the vendored Codex pr-review skill and agent bundle.

This complements Bats: Bats covers shell/CLI behavior, while this script checks
TOML parseability, prompt contracts, and vendored license/notice hashes.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys
import tomllib


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENTS_DIR = REPO_ROOT / "private_dot_codex" / "agents"
CODEX_BASELINE = REPO_ROOT / "private_dot_codex" / "private_config.chezmoi.toml"
SKILL_DIR = REPO_ROOT / "private_dot_codex" / "skills" / "pr-review"
SKILL = SKILL_DIR / "SKILL.md"
REVIEW_CRITERIA = SKILL_DIR / "references" / "review-criteria.md"
SEVERITY_RULES = SKILL_DIR / "references" / "severity-rules.json"
BASE_RESOLUTION_CONTRACT = (
    SKILL_DIR / "references" / "base-resolution-runtime-contract.json"
)
V2_RUNTIME_CONTRACT = SKILL_DIR / "references" / "v2-runtime-contract.json"
CLAUDE_REFS_DIR = REPO_ROOT / "private_dot_claude" / "skills" / "pr-review" / "references"
CODEX_DOC = REPO_ROOT / "docs" / "codex.md"
DESIGN_DOC = REPO_ROOT / "docs" / "design" / "codex-pr-review.md"

EXPECTED_REVIEW_PROFILES = {
    "review": {
        "path": REPO_ROOT / "private_dot_codex" / "private_review.config.toml",
        "model_reasoning_effort": "medium",
    },
    "review_deep": {
        "path": REPO_ROOT / "private_dot_codex" / "private_review_deep.config.toml",
        "model_reasoning_effort": "high",
    },
    "review_audit": {
        "path": REPO_ROOT / "private_dot_codex" / "private_review_audit.config.toml",
        "model_reasoning_effort": "xhigh",
    },
}

RUNTIME_CONTRACT_SENTINEL = "PR_REVIEW_RUNTIME_CONTRACT_V1_V2"
BASE_RESOLUTION_SENTINEL = "PR_REVIEW_BASE_RESOLUTION_CONTRACT_V1"
V2_SCHEDULER_SENTINEL = "PR_REVIEW_V2_SCHEDULER_CONTRACT_V1"
EXPECTED_BASE_RESOLUTION_CONTRACT = {
    "sentinel": BASE_RESOLUTION_SENTINEL,
    "version": 1,
    "operations": {
        "pr_view": {
            "argv": [
                "gh",
                "pr",
                "view",
                "--json",
                "baseRefName,baseRefOid",
                "--jq",
                "[.baseRefName,.baseRefOid] | @tsv",
            ],
            "sandbox_first": True,
            "debug_discriminator_env": {"GH_DEBUG": "api"},
            "allow_elevated_retry": True,
        },
        "fetch_branch": {
            "argv_template": [
                "git",
                "fetch",
                "--quiet",
                "origin",
                "refs/heads/<validated-base>",
            ],
            "sandbox_first": True,
            "allow_elevated_retry": True,
        },
        "fetch_default": {
            "argv": ["git", "fetch", "--quiet", "origin"],
            "sandbox_first": True,
            "allow_elevated_retry": True,
        },
        "remote_set_head": {
            "argv": ["git", "remote", "set-head", "origin", "--auto"],
            "sandbox_first": True,
            "allow_elevated_retry": True,
        },
    },
    "escalation": {
        "max_retries_per_operation": 1,
        "require_same_invocation_fingerprint": True,
        "allow_persistent_prefix": False,
        "require_explicit_tool_field": "sandbox_permissions=require_escalated",
        "transport_denial_precedes_credential_text": True,
        "fatal_before_specialist_spawn": True,
    },
    "result_classification": {
        "sandbox_or_transport_denial": "retry-elevated-once",
        "credential_failure_after_github_response": "fatal-stale-auth",
        "explicit_no_pr": "fatal-no-pr",
        "ordinary_git_or_api_failure": "fatal",
        "ambiguous_failure": "fatal",
    },
    "immutable_oid": {
        "skip_gh": True,
        "skip_fetch": True,
        "skip_escalation": True,
    },
}
EXPECTED_V2_RUNTIME_CONTRACT = {
    "sentinel": V2_SCHEDULER_SENTINEL,
    "version": 1,
    "max_concurrency": 3,
    "delivery_grace_ms": 60_000,
    "stage_deadline_ms": {"stage1": 1_800_000, "stage2": 600_000},
    "spawn": {
        "max_retries": 1,
        "retry_only_on_explicit_capacity_error": True,
        "retry_requires_available_slot": True,
        "require_new_attempt_name": True,
    },
    "result": {
        "require_canonical_sender": True,
        "require_final_payload": True,
        "require_terminal_status": True,
        "identical_duplicate": "ignore",
        "conflicting_duplicate": "fatal",
        "pre_usable_disappearance": "fatal",
        "unexpected_descendant": "fatal",
    },
    "cleanup": {
        "interrupt_running_owned_top_level": True,
        "interrupt_running_owned_descendants": True,
        "interrupt_orchestrator": False,
        "interrupt_unrelated": False,
        "require_no_running_owned_after_cleanup": True,
    },
    "aggregation": {
        "require_exact_expected_roles": True,
        "require_unique_canonical_tasks": True,
        "require_all_usable": True,
    },
}
V1_ROLLBACK_COMMAND_SNIPPETS = (
    "codex \\",
    "-c 'features.multi_agent=true'",
    "-c 'features.multi_agent_v2=false'",
    "-c 'model_reasoning_effort=\"medium\"'",
    "exec --model gpt-5.5",
    "-C '<repo-root>'",
    "'$pr-review --base <base>'",
)
RUNTIME_CONTRACT_SNIPPETS = [
    "Before running any shell or Git command and before invoking any collaboration tool",
    "Tool discovery is allowed here; a probe spawn is not.",
    "The V1 adapter",
    "The V2 adapter",
    "`spawn_agent(agent_type,message)`",
    "both arguments required",
    "must not accept `task_name` or `fork_turns`",
    "targeted `wait_agent(targets)`",
    "`close_agent(agent_id)`",
    "`spawn_agent(task_name,message,agent_type?,fork_turns?,model?,reasoning_effort?)`",
    "with `task_name` and `message` required",
    "untargeted `wait_agent(timeout_ms?)`",
    "must not accept `targets`",
    "`close_agent` must not be part of this family",
    "Optional unrelated, non-discriminating fields may be present",
    "`list_agents(path_prefix?)`",
    "`interrupt_agent(target)`",
    "`references/base-resolution-runtime-contract.json`",
    BASE_RESOLUTION_SENTINEL,
    "machine-readable base-resolution contract",
    "fresh agent tree",
    "`references/v2-runtime-contract.json`",
    V2_SCHEDULER_SENTINEL,
    "machine-readable scheduler contract",
    "Missing, unresolved, incomplete, mixed, or unknown definitions are not compatible.",
    "mixed, incomplete, or unknown",
    "No specialist was spawned and no review was performed.",
    "Do not fall back to default agents.",
]

BASE_RESOLUTION_SNIPPETS = [
    "always try the ordinary sandbox first",
    "sandbox_permissions=require_escalated",
    "Never request a persistent prefix approval",
    "exact original executable, argv, cwd, and ordinary environment once",
    "do not run the origin-unscoped `gh auth status`",
    "use the required PR lookup itself as the only GitHub auth/network probe",
    "Give a proven sandbox/transport denial precedence over credential-looking text",
    "original non-debug `gh pr view` invocation once",
    "Do not persist or reproduce raw debug headers",
    "through the scoped retry policy",
    "do not run `gh`, fetch, or any elevated command",
    "abort before specialist spawn",
]

V2_RUNTIME_SNIPPETS = [
    "`prr_<run_token>_s<stage>_",
    'fork_turns="none"',
    "maximum of 3",
    "FINAL_ANSWER",
    "terminal status",
    "60-second delivery grace",
    "wait_agent is notification-only",
    "list_agents is status-only",
    "unexpected descendant",
    "conflicting duplicate",
    "`Task name` identifies the recipient",
    "harvest and validate **all** newly delivered run-owned finals before refilling any slot",
    "one final notification/status drain",
    "no run-owned task or owned descendant remains running",
    "Partial aggregation",
    "explicit capacity error",
    "attempt",
    "canonical",
    "stage deadline",
    "Do not call any collaboration/subagent tools; return only your final review response.",
]

AGENT_CONTROL_PLANE_SNIPPETS = [
    "do not call any collaboration or subagent control-plane tool",
    "spawn_agent",
    "send_message",
    "followup_task",
    "wait_agent",
    "list_agents",
    "interrupt_agent",
    "final response",
]

# The Claude-side copies are drift-proof only while they stay one-line
# {{ include }} templates of the Codex canonical; an inline replacement would
# render fine and pass the CI template-syntax check, so pin the include here.
EXPECTED_TMPL_INCLUDES = {
    "review-criteria.md.tmpl": 'include "private_dot_codex/skills/pr-review/references/review-criteria.md"',
    "severity-rules.json.tmpl": 'include "private_dot_codex/skills/pr-review/references/severity-rules.json"',
}

EXPECTED_AGENTS = {
    "adversarial-reviewer": {
        "file": "adversarial-reviewer.toml",
        "source": "https://github.com/openai/codex-plugin-cc/blob/main/plugins/codex/prompts/adversarial-review.md",
        "commit": "807e03ac9d5aa23bc395fdec8c3767500a86b3cf",
        "copyright": "Copyright 2026 OpenAI",
        "license": "Apache-2.0",
        "license_file": "LICENSE-codex-plugin-cc",
        "notice_file": "NOTICE-codex-plugin-cc",
    },
    "code-reviewer": {
        "file": "code-reviewer.toml",
        "source": "https://github.com/anthropics/claude-plugins-official/blob/main/plugins/pr-review-toolkit/agents/code-reviewer.md",
        "commit": "b5a156b6ecd2f69c418184b7c093930ddabaf9c0",
        "copyright": "Copyright Anthropic PBC",
        "license": "Apache-2.0",
        "license_file": "LICENSE-claude-plugins-official",
    },
    "code-simplifier": {
        "file": "code-simplifier.toml",
        "source": "https://github.com/anthropics/claude-plugins-official/blob/main/plugins/pr-review-toolkit/agents/code-simplifier.md",
        "commit": "b5a156b6ecd2f69c418184b7c093930ddabaf9c0",
        "copyright": "Copyright Anthropic PBC",
        "license": "Apache-2.0",
        "license_file": "LICENSE-claude-plugins-official",
    },
    "comment-analyzer": {
        "file": "comment-analyzer.toml",
        "source": "https://github.com/anthropics/claude-plugins-official/blob/main/plugins/pr-review-toolkit/agents/comment-analyzer.md",
        "commit": "b5a156b6ecd2f69c418184b7c093930ddabaf9c0",
        "copyright": "Copyright Anthropic PBC",
        "license": "Apache-2.0",
        "license_file": "LICENSE-claude-plugins-official",
    },
    "pr-test-analyzer": {
        "file": "pr-test-analyzer.toml",
        "source": "https://github.com/anthropics/claude-plugins-official/blob/main/plugins/pr-review-toolkit/agents/pr-test-analyzer.md",
        "commit": "b5a156b6ecd2f69c418184b7c093930ddabaf9c0",
        "copyright": "Copyright Anthropic PBC",
        "license": "Apache-2.0",
        "license_file": "LICENSE-claude-plugins-official",
    },
    "security-reviewer": {
        "file": "security-reviewer.toml",
        "source": "https://github.com/anthropics/claude-code-security-review/blob/main/.claude/commands/security-review.md",
        "commit": "0c6a49f1fa56a1d472575da86a94dbc1edb78eda",
        "copyright": "Copyright (c) 2025 Anthropic",
        "license": "MIT",
        "license_file": "LICENSE-claude-code-security-review",
    },
    "silent-failure-hunter": {
        "file": "silent-failure-hunter.toml",
        "source": "https://github.com/anthropics/claude-plugins-official/blob/main/plugins/pr-review-toolkit/agents/silent-failure-hunter.md",
        "commit": "b5a156b6ecd2f69c418184b7c093930ddabaf9c0",
        "copyright": "Copyright Anthropic PBC",
        "license": "Apache-2.0",
        "license_file": "LICENSE-claude-plugins-official",
    },
    "type-design-analyzer": {
        "file": "type-design-analyzer.toml",
        "source": "https://github.com/anthropics/claude-plugins-official/blob/main/plugins/pr-review-toolkit/agents/type-design-analyzer.md",
        "commit": "b5a156b6ecd2f69c418184b7c093930ddabaf9c0",
        "copyright": "Copyright Anthropic PBC",
        "license": "Apache-2.0",
        "license_file": "LICENSE-claude-plugins-official",
    },
}

EXPECTED_FILE_HASHES = {
    # Verified against the upstream files at the source commits recorded above.
    "LICENSE-claude-code-security-review": "a9ac868c004c4cce26430b3117767b46397ba4fa25026b1e5ea6694b463baf4b",
    "LICENSE-claude-plugins-official": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
    "LICENSE-codex-plugin-cc": "e591c02a0b2ea7717d99e15bd51ea05d879bbf5a4452d66d15b51a7107d3821a",
    "NOTICE-codex-plugin-cc": "6728b3dff175efe673c1d6a402f5d9f548127a20960a6efdf9047dae1e36ecfb",
}

REQUIRED_SKILL_SNIPPETS = [
    "Intended successor to the legacy bash `triple-review` orchestrator.",
    "using the bundled `references/review-criteria.md` gate policy",
    "Use the bundled `references/review-criteria.md` as the source of truth",
    "Optimize for merge decisions, not finding count.",
    "Do not put nits, style preferences, speculative rewrites, or weakly grounded concerns into the fix queue.",
    "Important findings are capped at 5",
    "Suggestions are capped at 3",
    "Re-review verifies prior Critical/Important findings",
    "Critical findings require `blocking: yes`, `impact_scope`, `verified_assumptions`, and no `unverified_assumptions`",
    "Stop the review loop when Critical and Important are both 0",
    "If the command fails, abort with the command output",
    "To inspect staged, unstaged, and untracked changes first, run `codex review --uncommitted`.",
    "Commit or stash all listed changes, then retry `$pr-review`.",
    "skip `gh` entirely",
    'git check-ref-format --branch "$BASE"',
    'does not start with `-` or `+`, contain `:`',
    'git fetch --quiet origin "refs/heads/$BASE"',
    "set `$BASE_REF=FETCH_HEAD`",
    "Do not pass `$BASE` as a raw refspec",
    "Do not proceed from existing local refs alone.",
    "Sandbox compatibility by base path:",
    "Explicit immutable commit/OID bases do not require network access or `.git` metadata writes",
    "only supported offline/read-only invocation path",
    "Explicit branch-name bases require network access and `git fetch` writing `FETCH_HEAD`",
    "`--allow-no-pr` requires network access, `git fetch`, and `git remote set-head origin --auto`",
    "Auto-PR base resolution requires `gh pr view`, network access, and a verified fetch of the reported base branch",
    "they must supply an immutable base commit OID",
    "Run `git fetch --quiet origin` through the scoped retry policy",
    "Run `git remote set-head origin --auto` through the same policy",
    "Run `git symbolic-ref --quiet --short refs/remotes/origin/HEAD`; if it fails or returns an empty value, abort instead of guessing a base.",
    "Strip the leading `origin/` from the captured value",
    "exactly two non-empty tab-separated fields",
    "Validate it with the same explicit-branch safety rules",
    'Then run `git fetch --quiet origin "refs/heads/$BASE"` through the scoped retry policy',
    "verify it exactly equals the returned `baseRefOid`",
    'BASE_COMMIT=$(git rev-parse --verify "$BASE_REF^{commit}")',
    "operational_paths",
    "private_dot_codex/skills/**/SKILL.md",
    "do not classify ordinary runtime files as tests merely because they contain `test` in a role name such as `pr-test-analyzer`",
    "`type_changes`",
    "modifying lines inside an existing type or schema definition block",
    "Scope contract: review only the orchestrator-provided `$BASE_COMMIT...$HEAD_REF` committed branch diff.",
    "Coverage sentinel contract",
    "Review-only contract: do not edit files",
    "The V1 adapter** treats targeted `wait_agent` as polling",
    "`timeout_ms = min(600000",
    "Final worktree guard",
    "git status --porcelain --untracked-files=normal",
    "If `gh pr view` returned `baseRefOid`, keep `$BASE_REF=FETCH_HEAD` after the verified fetch/OID comparison",
    "If an explicit branch base was fetched, keep `$BASE_REF=FETCH_HEAD`",
    "Do not skip the final worktree or HEAD checks on the empty-diff path.",
]

PROCEDURE_SKILL_SNIPPETS = [
    "Run `git rev-parse HEAD` as an independent, preceding tool call",
    'git log --no-decorate "$BASE_COMMIT..$HEAD_REF"',
    'git diff --name-only "$BASE_COMMIT"..."$HEAD_REF"',
    'git diff "$BASE_COMMIT"..."$HEAD_REF"',
    "Always write the exact full diff to a temp file",
    "BSD/GNU-compatible suffix-free `mktemp` template",
    'diff_packet=$(mktemp "${TMPDIR:-/tmp}/pr-review-diff.XXXXXX")',
    "do not use a suffixed template such as `pr-review-diff.XXXXXX.diff`",
    "Abort if `mktemp`, diff writing, byte counting, or hashing fails.",
    "The diff packet is authoritative",
    "The recorded `$BASE_COMMIT`",
    "The recorded `$HEAD_REF`",
    "review only the orchestrator-provided `$BASE_COMMIT...$HEAD_REF` committed branch diff",
    "diff packet path, byte count, and SHA-256 (always supplied)",
    "the first output line must be either `COVERAGE_OK",
    "`FATAL_COVERAGE_ERROR",
    "missing a first-line `COVERAGE_OK ...` or `FATAL_COVERAGE_ERROR ...` sentinel",
    "Fail closed before Stage 2 or aggregation if any specialist output reports a fatal coverage error",
    "unable to verify the packet",
    "Review-only contract: do not edit files",
    "The V1 adapter** treats targeted `wait_agent` as polling",
    "Dispatch the recorded set through the selected adapter",
    "Run at most 6 Stage 1 agents concurrently",
    "Never omit a scheduled role because of capacity",
    "the V1 adapter closes every remaining running V1 ID",
    "same target description, `$BASE_REF`, `$BASE_COMMIT`, `$HEAD_REF`",
    "Apply the same first-line `COVERAGE_OK ...` / `FATAL_COVERAGE_ERROR ...` sentinel validation",
    "selected adapter",
]

CRITICAL_NORMALIZATION_SNIPPETS = [
    "Apply `references/review-criteria.md` before trusting specialist labels.",
    "Read `references/severity-rules.json` and classify each finding with its escalation table.",
    "shared verbatim with the Claude-side `/pr-review` skill",
    "edit the table, not skill prose",
    "matches any rule in the table's `critical.any_of` AND satisfies `critical.guard`",
    "concrete merge-blocking risk from the committed branch diff",
    "matches any rule in `important.any_of` AND satisfies `important.guard`",
    "Do not promote nits, style preferences, speculative rewrites, or weakly grounded concerns into Critical or Important.",
    "missing verification stated explicitly instead of silently dropping it",
    "Treat a specialist Critical label as a candidate, not final severity.",
    "Re-check `blocking`, `impact_scope`, `verified_assumptions`, and `unverified_assumptions`",
    "Downgrade local-only, ignored generated state, developer-workflow-only false-green",
    "post-verification produces `needs-verification` with non-empty `missingVerification`",
    "downgrade it to Important before final aggregation",
]

# The escalation semantics moved from SKILL.md prose into severity-rules.json
# (shared with the Claude-side /pr-review skill); pin them there instead.
EXPECTED_SEVERITY_SENTINEL = "PR_REVIEW_SEVERITY_RULES_V1"
EXPECTED_SEVERITY_VERSION = 1
EXPECTED_OUTPUT_CAPS = {"important": 5, "suggestion": 3}
EXPECTED_CRITICAL_ANY_OF = [
    {"kind": "explicit_label", "specialist": "*", "labels": ["Critical"], "case_insensitive": True},
    {"kind": "confidence_threshold", "specialist": "code-reviewer", "scale": "0-100", "min": 90},
    {"kind": "framing_with_confidence", "specialist": "adversarial-reviewer", "framing": "needs-attention", "scale": "0-1", "min": 0.7},
    {"kind": "explicit_label", "specialist": "silent-failure-hunter", "labels": ["CRITICAL"], "case_insensitive": True},
    {"kind": "severity_field", "specialist": "security-reviewer", "values": ["High"], "case_insensitive": True},
]
EXPECTED_IMPORTANT_ANY_OF = [
    {"kind": "explicit_label", "specialist": "*", "labels": ["Important", "High"], "case_insensitive": True},
    {"kind": "severity_field", "specialist": "security-reviewer", "values": ["Medium"], "case_insensitive": True},
    {"kind": "category_label", "specialist": "pr-test-analyzer", "labels": ["Critical Gap", "Important Improvement"], "case_insensitive": True},
]

FINAL_GUARD_SNIPPETS = [
    "git status --porcelain --untracked-files=normal",
    "If the command fails, abort with the command output",
    "If output is non-empty, abort",
    "Run `git rev-parse HEAD` again",
    "HEAD changed during review",
]

REQUIRED_REVIEW_CRITERIA_SNIPPETS = [
    "# pr-review Review Criteria",
    "skill-bundled detailed gate policy for `$pr-review`",
    "Global `AGENTS.md` / `CLAUDE.md` files should keep only the short cross-repository policy",
    "When Codex is available, use `codex review --uncommitted` for staged, unstaged, and untracked changes",
    "`codex review --base <branch>` for a low-risk committed branch diff",
    "Quick review is a preflight and everyday floor, not a substitute when Gate review applies.",
    "Optimize for merge decisions, not finding count.",
    "grounded in the committed branch diff",
    "Do not put nits, style preferences, speculative rewrites, or weakly grounded concerns into the fix queue.",
    "silent false-green",
    "`blocking: yes/no`, `impact_scope`, `verified_assumptions`, and `unverified_assumptions`",
    "Machine-local or ignored state",
    "Post-verification, a Critical candidate whose verifier verdict is `needs-verification` with a non-empty `missingVerification`",
    "Important findings are capped at 5",
    "Suggestions are capped at 3",
    "Nits do not enter the fix queue.",
    "Re-review verifies prior Critical/Important findings.",
    "Critical 0 / Important 0",
    "review churn",
]

REQUIRED_CODEX_DOC_SNIPPETS = [
    '`review.config.toml`: `gpt-5.6-sol` / `medium`',
    '`review_deep.config.toml`: `gpt-5.6-sol` / `high`',
    '`review_audit.config.toml`: `gpt-5.6-sol` / `xhigh`',
    "V1/V2",
    "checked-in の legacy V1 profile は置かない",
    "isolated `CODEX_HOME`",
    "scoped escalation",
    "`chezmoi apply` は変更を main に merge した後だけ",
]

REQUIRED_DESIGN_DOC_SNIPPETS = [
    "rev.11",
    "Issue #297",
    "V1/V2",
    "fresh agent tree",
    "at most 3",
    "FINAL_ANSWER",
    "terminal status",
    "60-second delivery grace",
    "unexpected descendant",
    "conflicting duplicate",
    "partial aggregation",
    "control-plane",
    'fork_turns="none"',
    "isolated `CODEX_HOME`",
    "Raw JSONL",
    BASE_RESOLUTION_SENTINEL,
]

FORBIDDEN_STALE_DESIGN_SNIPPETS = [
    "the skill rejects non-V1 exposure",
    "V2 adapter work remains isolated in Issue #297",
    "current V1-only compatibility work",
]

FORBIDDEN_ACTIVE_AGENT_SNIPPETS = [
    "Task tool",
    "<Task tool",
    "Memory safety issues such as buffer overflows or use-after-free-vulnerabilities are impossible in rust",
    "Do not report memory safety issues in rust or any other memory safe languages",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_toml(path: pathlib.Path, description: str) -> dict:
    if not path.is_file():
        fail(f"missing {description}: {path.relative_to(REPO_ROOT)}")
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        fail(f"{path}: invalid TOML: {exc}")
    if not isinstance(data, dict):
        fail(f"{path}: TOML root must be a table")
    return data


def nested_key_paths(value, key: str, prefix: str = "") -> list[str]:
    """Return dotted paths for a key found anywhere in a TOML structure."""
    found = []
    if isinstance(value, dict):
        for child_key, child_value in value.items():
            child_path = f"{prefix}.{child_key}" if prefix else child_key
            if child_key == key:
                found.append(child_path)
            found.extend(nested_key_paths(child_value, key, child_path))
    elif isinstance(value, list):
        for index, child_value in enumerate(value):
            found.extend(nested_key_paths(child_value, key, f"{prefix}[{index}]"))
    return found


def require_no_hide_spawn_metadata(data: dict, context: pathlib.Path) -> None:
    paths = nested_key_paths(data, "hide_spawn_agent_metadata")
    if paths:
        fail(
            f"{context}: hide_spawn_agent_metadata must not be configured "
            f"(found at {', '.join(paths)})"
        )


def require_contains(text: str, needle: str, context: str) -> None:
    if needle not in text:
        fail(f"{context}: missing {needle!r}")


def require_not_contains(text: str, needle: str, context: str) -> None:
    if needle in text:
        fail(f"{context}: forbidden stale text {needle!r}")


def require_ordered_contains(text: str, needles: tuple[str, ...], context: str) -> None:
    cursor = 0
    for needle in needles:
        position = text.find(needle, cursor)
        if position < 0:
            fail(f"{context}: missing or out-of-order command fragment {needle!r}")
        cursor = position + len(needle)


def section_between(text: str, start: str, end: str, context: str) -> str:
    try:
        section = text.split(start, 1)[1]
    except IndexError:
        fail(f"{context}: missing section start {start!r}")
    try:
        return section.split(end, 1)[0]
    except IndexError:
        fail(f"{context}: missing section end {end!r}")


def verify_license_files() -> None:
    for rel, expected_hash in EXPECTED_FILE_HASHES.items():
        path = AGENTS_DIR / rel
        if not path.is_file():
            fail(f"missing bundled license/notice file: {rel}")
        actual_hash = sha256(path)
        if actual_hash != expected_hash:
            fail(f"{rel}: sha256 mismatch: expected {expected_hash}, got {actual_hash}")


def verify_review_criteria() -> None:
    if not REVIEW_CRITERIA.is_file():
        fail(f"missing bundled review criteria: {REVIEW_CRITERIA.relative_to(REPO_ROOT)}")
    raw = REVIEW_CRITERIA.read_text(encoding="utf-8")
    for needle in REQUIRED_REVIEW_CRITERIA_SNIPPETS:
        require_contains(raw, needle, str(REVIEW_CRITERIA))


def verify_runtime_docs() -> None:
    codex_raw = CODEX_DOC.read_text(encoding="utf-8")
    for needle in REQUIRED_CODEX_DOC_SNIPPETS:
        require_contains(codex_raw, needle, str(CODEX_DOC))
    require_ordered_contains(codex_raw, V1_ROLLBACK_COMMAND_SNIPPETS, f"{CODEX_DOC}:V1-rollback")

    design_raw = DESIGN_DOC.read_text(encoding="utf-8")
    for needle in REQUIRED_DESIGN_DOC_SNIPPETS:
        require_contains(design_raw, needle, str(DESIGN_DOC))
    require_ordered_contains(design_raw, V1_ROLLBACK_COMMAND_SNIPPETS, f"{DESIGN_DOC}:V1-rollback")
    for needle in FORBIDDEN_STALE_DESIGN_SNIPPETS:
        require_not_contains(design_raw, needle, str(DESIGN_DOC))


def strip_comments(value):
    """Drop $comment keys (annotation-only) before comparing rule structures."""
    if isinstance(value, dict):
        return {k: strip_comments(v) for k, v in value.items() if k != "$comment"}
    if isinstance(value, list):
        return [strip_comments(v) for v in value]
    return value


def verify_severity_rules() -> None:
    context = str(SEVERITY_RULES)
    if not SEVERITY_RULES.is_file():
        fail(f"missing bundled severity table: {SEVERITY_RULES.relative_to(REPO_ROOT)}")
    try:
        data = json.loads(SEVERITY_RULES.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{context}: invalid JSON: {exc}")

    if data.get("sentinel") != EXPECTED_SEVERITY_SENTINEL:
        fail(f"{context}: sentinel mismatch: expected {EXPECTED_SEVERITY_SENTINEL!r}, got {data.get('sentinel')!r}")
    if data.get("version") != EXPECTED_SEVERITY_VERSION:
        fail(f"{context}: version mismatch: expected {EXPECTED_SEVERITY_VERSION}, got {data.get('version')!r}")
    if data.get("output_caps") != EXPECTED_OUTPUT_CAPS:
        fail(f"{context}: output_caps mismatch: expected {EXPECTED_OUTPUT_CAPS}, got {data.get('output_caps')!r}")

    for severity, expected in (
        ("critical", EXPECTED_CRITICAL_ANY_OF),
        ("important", EXPECTED_IMPORTANT_ANY_OF),
    ):
        section = data.get(severity)
        if not isinstance(section, dict):
            fail(f"{context}: missing {severity!r} section")
        actual = strip_comments(section.get("any_of"))
        if actual != expected:
            fail(f"{context}: {severity}.any_of mismatch:\n  expected {expected}\n  got      {actual}")
        guard = section.get("guard", "")
        if not isinstance(guard, str) or not guard.strip():
            fail(f"{context}: {severity}.guard must be a non-empty string")

    require_contains(data["critical"]["guard"], "merge-blocking risk", f"{context}:critical.guard")
    require_contains(data["critical"]["guard"], "blocking=yes", f"{context}:critical.guard")
    require_contains(data["critical"]["guard"], "impact_scope", f"{context}:critical.guard")
    require_contains(data["critical"]["guard"], "unverified_assumptions", f"{context}:critical.guard")
    downgrade = data["critical"].get("downgrade_to_important")
    if not isinstance(downgrade, dict):
        fail(f"{context}:critical.downgrade_to_important must be an object")
    impact_patterns = downgrade.get("impact_scope_patterns")
    override_patterns = downgrade.get("override_patterns")
    if not isinstance(impact_patterns, list) or not all(isinstance(p, str) and p.strip() for p in impact_patterns):
        fail(f"{context}:critical.downgrade_to_important.impact_scope_patterns must be non-empty strings")
    if not isinstance(override_patterns, list) or not all(isinstance(p, str) and p.strip() for p in override_patterns):
        fail(f"{context}:critical.downgrade_to_important.override_patterns must be non-empty strings")
    require_contains(" ".join(impact_patterns), "machine-local", f"{context}:critical.downgrade_to_important.impact_scope_patterns")
    require_contains(" ".join(override_patterns), "authoritative", f"{context}:critical.downgrade_to_important.override_patterns")
    require_contains(data["important"]["guard"], "not a proven blocker", f"{context}:important.guard")
    require_contains(data.get("nit", {}).get("rule", ""), "nits do not enter the fix queue", f"{context}:nit.rule")
    require_contains(data.get("incomplete_evidence", ""), "do not silently drop it", f"{context}:incomplete_evidence")


def verify_base_resolution_contract() -> None:
    context = str(BASE_RESOLUTION_CONTRACT)
    if not BASE_RESOLUTION_CONTRACT.is_file():
        fail(
            "missing base-resolution runtime contract: "
            f"{BASE_RESOLUTION_CONTRACT.relative_to(REPO_ROOT)}"
        )
    try:
        data = json.loads(BASE_RESOLUTION_CONTRACT.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{context}: invalid JSON: {exc}")
    if data != EXPECTED_BASE_RESOLUTION_CONTRACT:
        fail(f"{context}: base-resolution contract mismatch")

    skill = SKILL.read_text(encoding="utf-8")
    for expected in (
        f"sentinel `{data['sentinel']}`",
        "retry limit",
        "invocation-fingerprint",
        "immutable-OID",
    ):
        require_contains(skill, expected, f"{context}:SKILL.md consistency")


def verify_v2_runtime_contract() -> None:
    context = str(V2_RUNTIME_CONTRACT)
    if not V2_RUNTIME_CONTRACT.is_file():
        fail(
            "missing V2 runtime contract: "
            f"{V2_RUNTIME_CONTRACT.relative_to(REPO_ROOT)}"
        )
    try:
        data = json.loads(V2_RUNTIME_CONTRACT.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{context}: invalid JSON: {exc}")
    if data != EXPECTED_V2_RUNTIME_CONTRACT:
        fail(f"{context}: V2 scheduler contract mismatch")
    skill = SKILL.read_text(encoding="utf-8")
    prose_values = (
        f"maximum of {data['max_concurrency']}",
        f"{data['delivery_grace_ms'] // 1000}-second delivery grace",
        (
            f"monotonic {data['stage_deadline_ms']['stage1'] // 60_000}-minute "
            "Stage 1 deadline"
        ),
        (
            f"monotonic {data['stage_deadline_ms']['stage2'] // 60_000}-minute "
            "Stage 2 deadline"
        ),
    )
    for expected in prose_values:
        require_contains(skill, expected, f"{context}:SKILL.md consistency")


def verify_claude_share_templates() -> None:
    for name, include_line in EXPECTED_TMPL_INCLUDES.items():
        path = CLAUDE_REFS_DIR / name
        if not path.is_file():
            fail(f"missing Claude-side share template: {path.relative_to(REPO_ROOT)}")
        raw = path.read_text(encoding="utf-8")
        require_contains(raw, "{{ " + include_line, str(path))
        body_lines = [
            line
            for line in raw.splitlines()
            if line.strip() and "include " not in line and not line.lstrip().startswith("<!--")
        ]
        if body_lines:
            fail(
                f"{path}: contains inline content beyond the include + sentinel header — "
                f"an inline copy can drift from the Codex canonical: {body_lines[:2]!r}"
            )


def verify_codex_config_profiles() -> None:
    baseline = load_toml(CODEX_BASELINE, "managed Codex baseline")
    expected_baseline = {
        "model": "gpt-5.6-sol",
        "model_reasoning_effort": "high",
        "approval_policy": "on-request",
        "sandbox_mode": "workspace-write",
    }
    for key, expected in expected_baseline.items():
        actual = baseline.get(key)
        if actual != expected:
            fail(f"{CODEX_BASELINE}: {key} must be {expected!r}, got {actual!r}")

    baseline_features = baseline.get("features")
    if not isinstance(baseline_features, dict):
        fail(f"{CODEX_BASELINE}: [features] must be a table")
    if baseline_features.get("multi_agent") is not True:
        fail(f"{CODEX_BASELINE}: features.multi_agent must be true")
    if baseline_features.get("network_proxy") is not True:
        fail(f"{CODEX_BASELINE}: features.network_proxy must be true")
    sandbox_workspace_write = baseline.get("sandbox_workspace_write")
    if not isinstance(sandbox_workspace_write, dict):
        fail(f"{CODEX_BASELINE}: [sandbox_workspace_write] must be a table")
    if sandbox_workspace_write.get("network_access") is not False:
        fail(
            f"{CODEX_BASELINE}: sandbox_workspace_write.network_access "
            "must be false"
        )

    legacy_profiles = baseline.get("profiles", {})
    if not isinstance(legacy_profiles, dict):
        fail(f"{CODEX_BASELINE}: profiles must be a table when present")
    stale = sorted(set(EXPECTED_REVIEW_PROFILES).intersection(legacy_profiles))
    if stale:
        fail(
            f"{CODEX_BASELINE}: legacy review profile tables must be removed: "
            f"{', '.join(stale)}"
        )
    require_no_hide_spawn_metadata(baseline, CODEX_BASELINE)

    for profile_name, spec in EXPECTED_REVIEW_PROFILES.items():
        path = spec["path"]
        data = load_toml(path, f"Codex {profile_name} profile")
        expected_values = {
            "model": "gpt-5.6-sol",
            "model_reasoning_effort": spec["model_reasoning_effort"],
            "sandbox_mode": "workspace-write",
        }
        for key, expected in expected_values.items():
            actual = data.get(key)
            if actual != expected:
                fail(f"{path}: {key} must be {expected!r}, got {actual!r}")

        features = data.get("features")
        if not isinstance(features, dict):
            fail(f"{path}: [features] must be a table")
        if features.get("multi_agent") is not True:
            fail(f"{path}: features.multi_agent must be true")
        if "network_proxy" in features:
            fail(
                f"{path}: features.network_proxy must be inherited from "
                "the managed baseline"
            )
        if "multi_agent_v2" in features:
            fail(f"{path}: features.multi_agent_v2 must not be pinned in the managed V2 profile")
        if "approval_policy" in data:
            fail(f"{path}: approval_policy must be inherited from the managed baseline")
        if "sandbox_workspace_write" in data:
            fail(
                f"{path}: [sandbox_workspace_write] must be inherited from "
                "the managed baseline"
            )
        require_no_hide_spawn_metadata(data, path)


def verify_agent_toml() -> None:
    actual_files = sorted(path.name for path in AGENTS_DIR.glob("*.toml"))
    expected_files = sorted(meta["file"] for meta in EXPECTED_AGENTS.values())
    if actual_files != expected_files:
        fail(f"agent file set mismatch: expected {expected_files}, got {actual_files}")

    for expected_name, meta in EXPECTED_AGENTS.items():
        path = AGENTS_DIR / meta["file"]
        raw = path.read_text(encoding="utf-8")
        try:
            data = tomllib.loads(raw)
        except tomllib.TOMLDecodeError as exc:
            fail(f"{path}: invalid TOML: {exc}")
        require_no_hide_spawn_metadata(data, path)

        for key in ("name", "description", "developer_instructions"):
            value = data.get(key)
            if not isinstance(value, str) or not value.strip():
                fail(f"{path}: missing non-empty TOML field {key!r}")
            for forbidden in FORBIDDEN_ACTIVE_AGENT_SNIPPETS:
                require_not_contains(value, forbidden, f"{path}:{key}")

        if data["name"] != expected_name:
            fail(f"{path}: name field {data['name']!r} does not match {expected_name!r}")
        if path.stem != expected_name:
            fail(f"{path}: filename stem does not match agent name {expected_name!r}")

        for needle in (
            f"Source:        {meta['source']}",
            f"Source commit: {meta['commit']}",
            f"Copyright:     {meta['copyright']}",
            f"License:       {meta['license']}",
            "Modifications from upstream:",
            "Added pr-review control-plane isolation",
        ):
            require_contains(raw, needle, str(path))

        require_contains(raw, meta["license_file"], str(path))
        if meta["license_file"] not in EXPECTED_FILE_HASHES:
            fail(f"{path}: license file {meta['license_file']!r} is not hash-pinned")
        if notice_file := meta.get("notice_file"):
            require_contains(raw, notice_file, str(path))
            if notice_file not in EXPECTED_FILE_HASHES:
                fail(f"{path}: notice file {notice_file!r} is not hash-pinned")
        elif re.search(r"NOTICE-[A-Za-z0-9_.-]+", raw):
            fail(f"{path}: unexpected NOTICE reference")

        require_contains(data["developer_instructions"], "Orchestrator Scope Contract", str(path))
        require_contains(data["developer_instructions"], "review only the orchestrator-provided `$BASE_COMMIT...$HEAD_REF` committed branch diff", str(path))
        require_contains(data["developer_instructions"], "recorded `BASE_COMMIT` and `HEAD_REF`", str(path))
        require_contains(data["developer_instructions"], "packet hash", str(path))
        require_not_contains(data["developer_instructions"], "packet hash when supplied", str(path))
        require_not_contains(data["developer_instructions"], "review only the orchestrator-provided `$BASE_REF...HEAD` committed branch diff", str(path))
        require_not_contains(data["developer_instructions"], 'git log --no-decorate "$BASE_COMMIT"..."$HEAD_REF"', str(path))
        require_contains(data["developer_instructions"], "first output line must be a coverage sentinel", str(path))
        require_contains(data["developer_instructions"], f"COVERAGE_OK {expected_name} $BASE_COMMIT...$HEAD_REF", str(path))
        require_contains(data["developer_instructions"], f"FATAL_COVERAGE_ERROR {expected_name}:", str(path))
        require_contains(data["developer_instructions"], "$BASE_COMMIT...$HEAD_REF", str(path))
        require_contains(data["developer_instructions"], "return a fatal coverage error", str(path))
        require_contains(data["developer_instructions"], "do not edit files", str(path))
        require_contains(data["developer_instructions"], "blocking", str(path))
        require_contains(data["developer_instructions"], "impact_scope", str(path))
        require_contains(data["developer_instructions"], "verified_assumptions", str(path))
        require_contains(data["developer_instructions"], "unverified_assumptions", str(path))
        control_plane_contract = data["developer_instructions"].lower()
        for needle in AGENT_CONTROL_PLANE_SNIPPETS:
            require_contains(control_plane_contract, needle, f"{path}:control-plane-contract")

        if expected_name == "security-reviewer":
            require_contains(data["developer_instructions"], "Do not explore the repository beyond the orchestrator-provided", str(path))
            require_contains(data["developer_instructions"], "Operational Markdown, prompt assets, `SKILL.md`", str(path))
            require_contains(data["developer_instructions"], "Insecure passive prose documentation", str(path))
            require_contains(data["developer_instructions"], "only report findings with confidence >= 8", str(path))
            require_not_contains(data["developer_instructions"], ">80%", str(path))
            require_not_contains(data["developer_instructions"], "0.9-1.0", str(path))
            require_not_contains(data["developer_instructions"], "0.8-0.9", str(path))
            require_not_contains(data["developer_instructions"], "Insecure documentation. Do not report any findings in documentation files such as markdown files.", str(path))
        elif expected_name == "code-reviewer":
            require_contains(data["developer_instructions"], "After any required coverage sentinel, list what you're reviewing.", str(path))
            require_contains(data["developer_instructions"], "**76-89**: Important issue requiring attention", str(path))
            require_contains(data["developer_instructions"], "**90-100**: Critical bug or explicit target repository guidance violation", str(path))
            require_not_contains(data["developer_instructions"], "Start by listing what you're reviewing.", str(path))
            require_not_contains(data["developer_instructions"], "**76-90**: Important issue requiring attention", str(path))
            require_not_contains(data["developer_instructions"], "**91-100**: Critical bug or explicit target repository guidance violation", str(path))
        elif expected_name == "silent-failure-hunter":
            require_contains(data["developer_instructions"], "Failures must reach the right audience", str(path))
            require_contains(data["developer_instructions"], "appropriate caller, operator, or user", str(path))
            require_contains(data["developer_instructions"], "structured errors or operator-visible telemetry", str(path))
            require_contains(data["developer_instructions"], "**Audience Feedback:**", str(path))
            require_not_contains(data["developer_instructions"], "Users deserve actionable feedback", str(path))
            require_not_contains(data["developer_instructions"], "**User Feedback:**", str(path))
        elif expected_name == "type-design-analyzer":
            require_contains(data["developer_instructions"], "### Location", str(path))
            require_contains(data["developer_instructions"], "[file path]:[line or line range]", str(path))


def verify_skill_contract() -> None:
    raw = SKILL.read_text(encoding="utf-8")
    if len(raw.splitlines()) >= 500:
        fail(f"{SKILL}: skill must remain below 500 lines")
    for needle in REQUIRED_SKILL_SNIPPETS:
        require_contains(raw, needle, str(SKILL))

    for agent_name in EXPECTED_AGENTS:
        require_contains(raw, f"`{agent_name}`", str(SKILL))
    require_not_contains(raw, 'git fetch --quiet origin "$BASE"', str(SKILL))
    require_not_contains(raw, "use that immutable OID as `$BASE_REF`", str(SKILL))
    require_not_contains(raw, "Current Codex 0.130.0 contract", str(SKILL))

    if raw.count(RUNTIME_CONTRACT_SENTINEL) != 1:
        fail(
            f"{SKILL}: expected exactly one {RUNTIME_CONTRACT_SENTINEL!r} "
            f"sentinel, got {raw.count(RUNTIME_CONTRACT_SENTINEL)}"
        )
    if raw.count(BASE_RESOLUTION_SENTINEL) != 1:
        fail(
            f"{SKILL}: expected exactly one {BASE_RESOLUTION_SENTINEL!r} "
            f"sentinel, got {raw.count(BASE_RESOLUTION_SENTINEL)}"
        )
    runtime_contract = section_between(
        raw,
        "0. **V1/V2 runtime contract**",
        "1. **Clean worktree**",
        str(SKILL),
    )
    for needle in RUNTIME_CONTRACT_SNIPPETS:
        require_contains(runtime_contract, needle, f"{SKILL}:V1/V2-runtime-contract")
    for needle in BASE_RESOLUTION_SNIPPETS:
        require_contains(raw, needle, f"{SKILL}:base-resolution-contract")
    for needle in V2_RUNTIME_SNIPPETS:
        require_contains(raw, needle, f"{SKILL}:V2-runtime-contract")
    stage1_heading = "2. **Build the Stage 1 specialist set and spawn it in parallel**"
    require_contains(raw, stage1_heading, str(SKILL))
    if raw.index(RUNTIME_CONTRACT_SENTINEL) > raw.index("1. **Clean worktree**"):
        fail(f"{SKILL}: runtime contract must run before repository inspection")
    if raw.index(RUNTIME_CONTRACT_SENTINEL) > raw.index(stage1_heading):
        fail(f"{SKILL}: runtime contract must run before specialist spawn")
    if raw.index(BASE_RESOLUTION_SENTINEL) > raw.index("1. **Clean worktree**"):
        fail(f"{SKILL}: base-resolution contract must run before repository inspection")
    require_not_contains(
        raw,
        "Run `gh auth status`",
        f"{SKILL}:origin-scoped-GitHub-probe",
    )

    procedure = section_between(raw, "## Procedure", "## Output format", str(SKILL))
    for needle in PROCEDURE_SKILL_SNIPPETS:
        require_contains(procedure, needle, f"{SKILL}:procedure")
    require_not_contains(procedure, "new_types", f"{SKILL}:procedure")
    require_not_contains(procedure, '`test_paths`: matches `*test*`', f"{SKILL}:procedure")
    require_not_contains(
        procedure,
        'git log --no-decorate "$BASE_COMMIT"..."$HEAD_REF"',
        f"{SKILL}:procedure",
    )
    require_contains(procedure, "`agent_type`", f"{SKILL}:procedure")
    require_contains(
        procedure,
        "omission and generic/default role fallback are forbidden",
        f"{SKILL}:procedure",
    )

    collection = section_between(
        procedure,
        "1. **Collect the review inputs and classify the diff**",
        "2. **Build the Stage 1 specialist set",
        f"{SKILL}:input-collection",
    )
    for needle in (
        "independent, preceding tool call",
        "wait for it to complete before starting any other collection",
        "Do not put HEAD recording in the same parallel tool call",
        "record its commit OID as immutable `$HEAD_REF`",
        "abort without starting collection",
        "use that immutable OID for every later log, file-list, and diff command",
        "Do not use symbolic `HEAD` for those commands",
        'git log --no-decorate "$BASE_COMMIT..$HEAD_REF"',
        'git diff --name-only "$BASE_COMMIT"..."$HEAD_REF"',
        'git diff "$BASE_COMMIT"..."$HEAD_REF"',
    ):
        require_contains(collection, needle, f"{SKILL}:input-collection")
    for needle in ("..HEAD", "...HEAD"):
        require_not_contains(collection, needle, f"{SKILL}:input-collection")

    v2_dispatch = section_between(
        procedure,
        "- **The V2 adapter** derives",
        "3. **Await all Stage 1 specialists**",
        f"{SKILL}:V2-dispatch",
    )
    for needle in (
        "`prr_<run_token>_s<stage>_",
        'fork_turns="none"',
        "maximum of 3",
        "canonical task path",
        "exactly the requested new name",
        "explicit capacity error",
        "retry once",
        "new `attempt` name",
        "harvest and validate **all** newly delivered run-owned finals before refilling any slot",
    ):
        require_contains(v2_dispatch, needle, f"{SKILL}:V2-dispatch")
    for needle in ('fork_turns="all"', "`close_agent`"):
        require_not_contains(v2_dispatch, needle, f"{SKILL}:V2-dispatch")

    v2_await = section_between(
        procedure,
        "- **The V2 adapter** follows this state machine",
        "4. **Scan Stage 1 output",
        f"{SKILL}:V2-await",
    )
    for needle in (
        "valid final payload plus completed terminal status",
        "60-second delivery grace",
        "wait_agent is notification-only",
        "list_agents is status-only",
        "The only authoritative review body",
        "`Message Type` is `FINAL_ANSWER`",
        "`Sender` exactly equals a saved canonical task path",
        "`Task name` identifies the recipient",
        "malformed/missing first-line sentinel",
        "identical duplicate `FINAL_ANSWER`",
        "conflicting duplicate",
        "min(60000 ms, remaining stage budget, earliest active delivery-grace budget)",
        "task disappearance** before usability is fatal",
        "unexpected descendant",
        "Never interrupt the orchestrator or an unrelated path",
        "only on a still-running run-owned top-level task",
        "still-running unexpected descendant beneath one of its saved canonical paths",
        "both independently observed pieces of evidence",
        "interrupt_agent",
        "one final notification/status drain",
        "no run-owned task or owned descendant remains running",
        "Partial aggregation is forbidden",
    ):
        require_contains(v2_await, needle, f"{SKILL}:V2-await")
    require_not_contains(v2_await, "extract review text from its return", f"{SKILL}:V2-await")

    stage2 = section_between(
        procedure,
        "5. **Stage 2",
        "6. **Final worktree guard**",
        f"{SKILL}:Stage-2",
    )
    for needle in (
        "Use the selected adapter without switching families",
        "one active specialist",
        'fork_turns="none"',
        "matched `FINAL_ANSWER` payload",
        "independently observed terminal status",
        "monotonic 10-minute Stage 2 deadline",
        "same canonical-identity state machine",
        "60-second delivery grace",
        "Partial aggregation is forbidden here too",
    ):
        require_contains(stage2, needle, f"{SKILL}:Stage-2")

    critical_scan = section_between(
        raw,
        "4. **Scan Stage 1 output and normalize severity before Stage 2**:",
        "5. **Stage 2",
        str(SKILL),
    )
    for needle in CRITICAL_NORMALIZATION_SNIPPETS:
        require_contains(critical_scan, needle, f"{SKILL}:critical-normalization")

    final_guard = section_between(raw, "6. **Final worktree guard**:", "7. **Aggregate**", str(SKILL))
    for needle in FINAL_GUARD_SNIPPETS:
        require_contains(final_guard, needle, f"{SKILL}:final-worktree-guard")


def main() -> None:
    verify_license_files()
    verify_review_criteria()
    verify_runtime_docs()
    verify_severity_rules()
    verify_base_resolution_contract()
    verify_v2_runtime_contract()
    verify_claude_share_templates()
    verify_codex_config_profiles()
    verify_agent_toml()
    verify_skill_contract()
    print("OK: Codex pr-review bundle validation passed")


if __name__ == "__main__":
    main()
