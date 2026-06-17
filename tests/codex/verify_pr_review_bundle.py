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
SKILL_DIR = REPO_ROOT / "private_dot_codex" / "skills" / "pr-review"
SKILL = SKILL_DIR / "SKILL.md"
REVIEW_CRITERIA = SKILL_DIR / "references" / "review-criteria.md"
SEVERITY_RULES = SKILL_DIR / "references" / "severity-rules.json"
CLAUDE_REFS_DIR = REPO_ROOT / "private_dot_claude" / "skills" / "pr-review" / "references"

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
    "Run `git fetch --quiet origin`; if it fails, abort instead of reviewing a possibly stale default branch.",
    "Run `git remote set-head origin --auto`; if it fails, abort instead of trusting a stale local `origin/HEAD` symref.",
    "Run `git symbolic-ref --quiet --short refs/remotes/origin/HEAD`; if it fails or returns an empty value, abort instead of guessing a base.",
    "Strip the leading `origin/` from the captured value",
    "exactly two non-empty tab-separated fields",
    "Validate the returned branch name with the same explicit-branch safety rules",
    'Then run `git fetch --quiet origin "refs/heads/$BASE"`',
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
    "`wait_agent` with multiple targets returns when a target reaches a final status",
    "timeout_ms` of 600000",
    "Final worktree guard",
    "git status --porcelain --untracked-files=normal",
    "If `gh pr view` returned `baseRefOid`, keep `$BASE_REF=FETCH_HEAD` after the verified fetch/OID comparison",
    "If an explicit branch base was fetched, keep `$BASE_REF=FETCH_HEAD`",
    "Do not skip the final worktree or HEAD checks on the empty-diff path.",
]

PROCEDURE_SKILL_SNIPPETS = [
    "Run `git rev-parse HEAD` before collecting the diff and record it as `$HEAD_REF`",
    'git log --no-decorate "$BASE_COMMIT..$HEAD_REF"',
    'git diff --name-only "$BASE_COMMIT"..."$HEAD_REF"',
    'git diff "$BASE_COMMIT"..."$HEAD_REF"',
    "Always write the exact full diff to a temp file",
    "BSD/GNU-compatible suffix-free `mktemp` template",
    'diff_packet=$(mktemp "${TMPDIR:-/tmp}/pr-review-diff.XXXXXX")',
    "do not use a suffixed template such as `pr-review-diff.XXXXXX.diff`",
    "Abort if `mktemp`, diff writing, byte counting, or hashing fails.",
    "The diff packet is authoritative",
    "Current Codex 0.130.0 contract: `agent_type` selects the custom role",
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
    "`wait_agent` with multiple targets returns when a target reaches a final status",
    "Spawn Stage 1 with a bounded fanout",
    "Start at most 6 Stage 1 specialists at a time",
    "Never drop a scheduled specialist because of the thread limit",
    "close every remaining running Stage 1 agent",
    "same target description, `$BASE_REF`, `$BASE_COMMIT`, `$HEAD_REF`",
    "Apply the same first-line `COVERAGE_OK ...` / `FATAL_COVERAGE_ERROR ...` sentinel validation",
    "close the running Stage 2 agent if it exists",
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


def require_contains(text: str, needle: str, context: str) -> None:
    if needle not in text:
        fail(f"{context}: missing {needle!r}")


def require_not_contains(text: str, needle: str, context: str) -> None:
    if needle in text:
        fail(f"{context}: forbidden stale text {needle!r}")


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
    for needle in REQUIRED_SKILL_SNIPPETS:
        require_contains(raw, needle, str(SKILL))

    for agent_name in EXPECTED_AGENTS:
        require_contains(raw, f"`{agent_name}`", str(SKILL))
    require_not_contains(raw, 'git fetch --quiet origin "$BASE"', str(SKILL))
    require_not_contains(raw, "use that immutable OID as `$BASE_REF`", str(SKILL))

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
    verify_severity_rules()
    verify_claude_share_templates()
    verify_agent_toml()
    verify_skill_contract()
    print("OK: Codex pr-review bundle validation passed")


if __name__ == "__main__":
    main()
