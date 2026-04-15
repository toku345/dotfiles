# ADR 0007: Replace codex exec diff review with /codex:adversarial-review

## Status

Accepted

## Context

The CLAUDE.md Codex integration had two AI-automatic review modes using `codex exec`:
implementation plan review and diff-based code review. Both used manually crafted
prompts ("致命的な点のみ指摘してください") to filter Codex output.

The codex-plugin-cc now provides `/codex:adversarial-review`, a purpose-built skill
with a "default to skepticism" prompt, structured JSON output with confidence scores,
and automatic filtering of style/naming noise. Author testing on real PRs confirmed it produces
detailed, material findings that catch implementation gaps before PR review.

Meanwhile, the user's actual code review workflow runs three tools before PR submission:
`/pr-review-toolkit:review-pr`, `/security-review`, and Codex CLI `/review` (in a
separate terminal session). Replacing the Codex CLI session with
`/codex:adversarial-review` inside Claude Code consolidates the workflow into a single
session.

## Decision

- Remove the AI-automatic `codex exec` diff review from CLAUDE.md
- Add `/codex:adversarial-review` as a user-invoked pre-PR review tool
- Keep `codex exec` for implementation plan review (no adversarial-review equivalent exists for plan text)
- Enable `autoUpdate` on the codex plugin marketplace entry to receive prompt/skill improvements automatically

## Consequences

- **Positive**: Pre-PR review workflow consolidates into one Claude Code session (review-pr + security-review + adversarial-review). No separate Codex CLI session needed.
- **Positive**: Adversarial review uses a higher-quality, maintained prompt with structured output, replacing a hand-crafted one-liner.
- **Positive**: AI no longer blocks on automatic `codex exec` during code review, reducing latency.
- **Negative**: Adversarial review is user-initiated, not automatic. If the user forgets to run it before PR, the safety net is absent. Partially mitigated by `/pr-review-toolkit:review-pr`, which covers standard code review but not the adversarial design-challenge perspective.
- **Risk**: `autoUpdate` may introduce breaking changes to plugin skills. Mitigated by pinning or rolling back via plugin reinstall if needed.
