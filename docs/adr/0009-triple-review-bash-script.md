# ADR 0009: Triple-review as an external bash script invoking headless `claude -p`

## Status

Accepted

## Context

PR #134 attempted to implement `triple-review` as a Claude Code skill that orchestrates three pre-PR reviewers (`/pr-review-toolkit:review-pr`, `/security-review`, `/codex:adversarial-review`) from inside an active Claude Code session. Dogfooding surfaced structural blockers:

- `/codex:adversarial-review` and its sibling commands set `disable-model-invocation: true`. When orchestrated via the `Skill` tool, they are rejected.
- `/security-review` ends its prompt with "Your final reply must contain the markdown report and nothing else." When invoked via the `Skill` tool from a parent skill, this terminal rendering directive ends the parent turn and prevents further steps (e.g. aggregation) from running.
- The PR #134 implementation referenced a non-existent `BashOutput` tool and tried to find the Codex task via `TaskList`, which is racy with concurrent tasks.
- Three reviewers could not actually run in parallel from inside a session — the Skill tool serializes by turn.

The structural conclusion: **in-session orchestration is the wrong shape for this problem**. Each `claude -p` headless invocation is a fresh user-originated session where:

- `disable-model-invocation: true` does not apply (verified empirically with `claude -p "/codex:status"`).
- Sub-session rendering directives cannot terminate the parent (the parent is a bash script, not a Claude turn).
- True OS-level parallelism is trivial via bash `&` + `wait`.

Separately, the prior memory note claimed `/security-review` hardcodes `main...HEAD`. Binary inspection of Claude Code 2.1.116 disproves the hardcode claim — the system prompt is scope-agnostic ("the changes on this branch", "this PR") and the Claude Code runtime exposes a `getDefaultBranch` resolver that handles `origin/HEAD` → `origin/main`/`origin/master` fallback. `/security-review` relies on the LLM at runtime to invoke `gh pr view` / `git` commands to determine scope; its prompt does not hardcode `main`. Default-branch resolution correctness for non-`main` repos is therefore probabilistic rather than deterministic — verified empirically on this author's setup but not guaranteed by code inspection alone.

Binary inspection performed against Claude Code 2.1.116.

## Decision

Implement `triple-review` as an external bash script at `~/.local/bin/triple-review`, managed via chezmoi as `dot_local/bin/executable_triple-review`. The extensionless name matches the user-facing invocation (`triple-review`, not `triple-review.sh`); chezmoi's `executable_` prefix sets mode `0755`. The script runs outside any Claude Code session and is invoked from the terminal.

- **Entrypoint**: zero-argument command `triple-review`. No PR number, no `--base` flag, no working-tree mode. All three reviewers auto-detect scope.
- **Base resolution for the Codex `--base` flag**: `gh pr view --json baseRefName` on the current branch first; fall back to `git symbolic-ref refs/remotes/origin/HEAD`. Abort if neither succeeds.
- **Parallel execution**: three `claude -p` invocations in the background, then `wait`.
  - `claude -p "/pr-review-toolkit:review-pr"` → `pr.md`
  - `claude -p "/security-review"` → `sec.md`
  - `claude -p "/codex:adversarial-review --wait --base <base> --scope branch"` → `adv.md`
- **Error handling**: hybrid. If at least one reviewer succeeds, continue; emit a `<FAILED>` marker in the aggregation prompt for any failed reviewer. If all three fail, abort with `exit 1` and surface the log paths.
- **Aggregation**: a fourth `claude -p` call wraps the three outputs in XML-tagged sections and asks for a priority-based summary (`対応必須` / `要検討` / `対応不要` / `矛盾`) with `file:line` evidence. Reference to official docs via `WebFetch`/`WebSearch` is explicitly permitted in the prompt.
- **Output**: stdout contains all four sections (three raw + aggregated summary). Intermediate files are written to `$TMPDIR/triple-review-<timestamp>/` and the path is reported on the last line; `$TMPDIR` is cleaned by macOS automatically.
- **Progress UX**: a short banner before the background jobs (`Running 3 reviewers in parallel...` plus the resolved base branch and work directory) and an `All reviewers done. Generating summary...` line after `wait`. The intermediate directory path is reprinted on the final line after summary output so it is discoverable at a glance.
- **Timeouts**: none. Reviewers typically run 2-10 minutes; interruption is via Ctrl+C.
- **Signal handling**: a `trap` on `EXIT`/`INT`/`TERM` kills backgrounded `claude -p` children (and their descendants) so Ctrl+C does not orphan multi-minute LLM calls.

## Consequences

- **Positive**: Uniform invocation pattern (all three reviewers via `claude -p`) eliminates the codex-companion.mjs path dependency and survives plugin upgrades.
- **Positive**: Real OS-level parallelism cuts wall-clock time roughly to the slowest reviewer instead of the sum of three.
- **Positive**: Hybrid error handling preserves partial results — a single reviewer failure no longer discards the 2-10 minutes of work the others already did.
- **Positive**: Priority-based summary with four Japanese sections (`対応必須` / `要検討` / `対応不要` / `矛盾`) matches the manual review workflow the author used before automation, surfacing "which should I actually fix" directly instead of requiring a second triage pass. All reviewer-facing output is in Japanese per the repository's global `CLAUDE.md` convention.
- **Negative**: Cannot be invoked from within an active Claude Code session — requires dropping to the terminal. This is by design; in-session orchestration was the source of every PR #134 blocker.
- **Negative**: Four `claude -p` calls per run (three reviewers + one aggregation) cost more than a single session turn. Each reviewer runs for many turns against full codebase context (especially `/pr-review-toolkit:review-pr`, which internally spawns several sub-agents). Expected several USD per run, dominated by total token consumption rather than per-call overhead. Actual cost should be measured post-implementation.
- **Risk**: `disable-model-invocation: true` behavior in `claude -p` mode relies on current Claude Code semantics (verified on 2.1.116). If Anthropic tightens the flag to also block headless mode in a future release, the script breaks and requires reverting to the `codex-companion.mjs` direct invocation for the Codex leg.
- **Risk**: Three parallel `claude -p` processes consume Anthropic API quota three-fold simultaneously. For individual-tier users this is within normal bursts; heavy usage could hit per-minute limits.
