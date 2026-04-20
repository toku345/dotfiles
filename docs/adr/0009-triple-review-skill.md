# ADR 0009: Triple-Review Skill for Pre-PR Review Aggregation

## Status

Accepted

## Context

Before opening a PR, the recommended review workflow in this repository runs
three independent reviewers (see `CLAUDE.md`):

1. `/pr-review-toolkit:review-pr` — multi-agent code review (code quality,
   tests, comments, error handling, types)
2. `/security-review` — security-focused review
3. `/codex:adversarial-review` — Codex-based challenge review that questions
   design choices and assumptions

Running these three commands manually one after another is tedious, and the
aggregation of findings (which issues were flagged by multiple reviewers,
which were flagged by only one, where reviewers contradict each other) is
left to the user.

A colleague demonstrated a `dual-review` slash command that runs Claude's
built-in `/review` plus Codex in parallel and produces a combined summary.
We want the same ergonomics for our three-reviewer workflow.

In Claude Code, custom slash commands (`commands/*.md`) are being
consolidated into Skills (`skills/<name>/SKILL.md`); auto-completion
regressions for the legacy form have been reported. Skills are the current
standard: auto-invokable via description matching, still triggerable as
`/<name>`, and supporting auxiliary files when needed.

The three reviewers take different forms of input:

- `/codex:adversarial-review` accepts `--base <ref>` and other flags
  natively.
- `/pr-review-toolkit:review-pr` takes `[review-aspects]` as its positional
  argument (e.g. `comments`, `tests`) — not a PR number. It detects PR
  context from the current branch via `gh pr view`.
- `/security-review` takes no arguments relevant to this workflow.

Because `/pr-review-toolkit:review-pr` derives its target from the current
git state rather than an explicit PR argument, all three reviewers can be
aligned on a common review target only by ensuring the session is already
on the PR branch before the skill runs.

## Decision

Create a Skill named `triple-review` under
`private_dot_claude/skills/triple-review/SKILL.md` (chezmoi-managed, global
scope). The Skill:

- Is invokable as `/triple-review` and via natural-language triggers (e.g.
  「トリプルレビュー」「PR 前の最終チェック」) through description matching.
- Accepts `[<PR number or URL>] [--base <ref>]`. The PR argument may be
  given as bare (`123`), hash-prefixed (`#123`), or full GitHub PR URL —
  all three forms are passed through to `gh pr view`, which accepts them
  natively. No custom normalization is needed.
- **Pre-flight validation (replaces naive argument forwarding)**: before
  launching any reviewer, run `gh pr view --json number,headRefName,baseRefName`
  to detect whether the current branch is a PR branch. Validation rules:
  - `/triple-review 123` (or `#123`, or URL): the current branch must be
    PR #123's branch. If not, fail loud and instruct the user to run
    `gh pr checkout 123`.
  - `/triple-review` with no PR argument, on a PR branch: proceed; target
    is that PR.
  - `/triple-review` with no PR argument, not on a PR branch:
    working-tree review. `--base <ref>` may be used here; defaults to
    `main` if omitted.
  - `/triple-review 123 --base <ref>`: reject — `--base` is mutually
    exclusive with a PR argument (base comes from the PR itself).
- **Argument distribution to reviewers**: because pre-flight validation
  guarantees the session is already on the correct branch, reviewers can
  derive context from git state. `/codex:adversarial-review` receives
  `--base` (either user-supplied or `baseRefName` from `gh pr view`).
  `/pr-review-toolkit:review-pr` and `/security-review` are invoked with
  no arguments and pick up context from the current branch.
- **Execution**: `/codex:adversarial-review` launches as a background Bash
  task (Codex runs as an external process, so true parallelism works).
  `/pr-review-toolkit:review-pr` and `/security-review` then run
  sequentially in the foreground — both occupy the main Claude thread and
  cannot be parallelized with each other. Finally, wait for the Codex
  background task and aggregate.
- **Dependency policy**: all three commands must be installed. If any is
  missing, the Skill fails loud (aligns with the "fail loud on missing
  dependencies" policy in `CLAUDE.md`).
- **Output**: four sections — `## PR Review`, `## Security Review`,
  `## Adversarial Review`, `## Summary`. Emitted to the chat only; no file
  artifact.
- **Aggregation**: classify findings into (a) flagged by all reviewers —
  high confidence, (b) flagged by only one — worth a second look, and
  (c) contradictions. Matching is LLM-judgment-based throughout: findings
  with `file:line` anchors are correlated by location; architectural /
  design-level findings (typical of `/codex:adversarial-review`) are
  correlated by semantic similarity of the finding text.
- Is review-only: no fixes are applied. Output is in Japanese per the
  global `CLAUDE.md` convention.

## Consequences

**Positive**

- One command replaces three manual invocations plus manual aggregation.
- Skill format future-proofs against slash-command consolidation.
- Pre-flight validation guarantees all three reviewers see the same review
  target, making the aggregated Summary meaningful.
- Fail-loud on missing commands prevents silently shipping a degraded
  "trio" that is really just a duo.

**Negative**

- Wall-clock time is `max(Codex, review-pr + security-review)`, not
  `max(all three)` — three-way parallelism is impossible because the two
  Claude-side reviewers share the main thread.
- Fail-loud on missing commands means the Skill is unusable until all
  three are installed. Acceptable for the intended pre-PR use case.
- Users must `gh pr checkout <PR#>` before invoking `/triple-review <PR#>`.
  Matches the ergonomics of `/pr-review-toolkit:review-pr`.
- Aggregated output is chat-only, which consumes significant context
  (three full reviews plus summary). No file artifact is produced.

**Risks**

- Semantic matching for design-level findings is LLM-judgment-based and
  may produce inconsistent aggregations across runs. Acceptable because
  the Summary is advisory; the raw per-reviewer sections remain
  authoritative.
- `/pr-review-toolkit:review-pr` and `/security-review` internally spawn
  subagents via the Task tool. Running them back-to-back consumes
  significant context. No direct mitigation — this is a structural cost
  of running two subagent-heavy reviewers in one session.
