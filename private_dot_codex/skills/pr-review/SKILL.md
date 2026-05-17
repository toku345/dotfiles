---
name: pr-review
description: Comprehensive pre-PR review orchestrator. Spawns up to 8 specialist subagents (code-reviewer, security-reviewer, adversarial-reviewer, pr-test-analyzer, comment-analyzer, silent-failure-hunter, type-design-analyzer, code-simplifier) on the current branch's changes against its base ref, then synthesizes Critical / Important / Suggestions / Strengths findings. Use before creating a pull request as a quality gate. Replaces the legacy bash `triple-review` orchestrator.
---

# pr-review

## Goal

Run a comprehensive specialist review of the current branch's changes against its base, then synthesize findings into a single actionable report.

## Preconditions

**Environment note**: this skill must be invoked from a terminal directly (`codex exec ...`), not from within an enclosing Claude Code session. The nested-bwrap permission failure documented in `~/.codex/history.jsonl` (2026-03) makes nested invocation infinite-spawn-retry. The skill cannot reliably self-detect this; the caller takes responsibility.

Run these checks in order. If any fails, abort with the indicated actionable error and do not proceed to the Procedure section.

1. **`gh` authenticated** — Run `gh auth status`. If it succeeds, continue. If it fails, first distinguish real auth failure from sandbox misclassification before aborting:
   - If stderr/debug output shows a sandbox/network denial such as `socket: operation not permitted` while contacting GitHub, treat it as a sandbox failure even when `gh` prints `token is invalid`; continue to Precondition 4 instead of telling the user to re-login. `GH_DEBUG=api gh auth status` is the fast discriminator when the plain output is ambiguous.
   - Otherwise abort with:
     > "Stale `gh` auth detected. Run `gh auth login` and retry — the skill cannot resolve PR base ref without authenticated gh."

2. **Clean worktree** — Run `git status --porcelain --untracked-files=normal`. If output is non-empty (uncommitted tracked changes or untracked-non-ignored files), abort with:
   > "Worktree has uncommitted changes: \<list\>. The review covers committed branch diff only; uncommitted changes would be silently excluded. Commit or stash first, then retry. (See ADR 0020.)"

3. **Base ref resolution** — Determine `$BASE` from one of three sources, in priority order:
   - (a) If the user prompt provides an explicit base (e.g., "review against main", "--base develop"), use that verbatim.
   - (b) Otherwise run `gh pr view --json baseRefName --jq .baseRefName`. If it returns a branch name, use that.
   - (c) Otherwise check `$ALLOW_NO_PR`. If set to `1` / `true`, fall back to `git rev-parse --abbrev-ref origin/HEAD | sed 's@^origin/@@'` and add a `**Degraded coverage**: no PR base, fell back to default branch` line to the Output.

   If none of (a)–(c) yields a base, abort with:
   > "No PR found for the current branch and no explicit base provided. By default the skill requires an open PR (Issue #186 fix) so all specialists share the same base ref. Either create a draft PR first, provide an explicit base in your prompt, or set `ALLOW_NO_PR=1` to fall back to the default branch (residual scope-divergence risk acknowledged)."

4. **Sandbox accommodation for `gh`** — Preconditions 1 and 3 invoke `gh`. If either fails with a sandbox-denial signal (not an auth/network failure), abort with:
   > "`gh` cannot execute under the current sandbox. Re-invoke `codex exec` with `--sandbox workspace-write`, or supply an explicit base in your prompt to bypass `gh pr view`."

## Procedure

After preconditions pass:

1. **Compute changed files** — Run `git diff --name-only $BASE...HEAD` and categorize each path:
   - `test_paths`: matches `*test*`, `*spec*`, `tests/`, `test/`, `__tests__/`, `*.test.*`, `*.spec.*`, `*_test.go`, `*_spec.rb`, `*.bats`
   - `docs_or_comments`: `docs/`, `*.md`, `README*`, or pure-comment changes in source files
   - `error_handling`: hunks containing `try` / `catch` / `except` / `rescue` / `Result<` / `Err(` / `panic` / `unwrap` / `defer` / error-callback signatures
   - `new_types`: hunks introducing `class` / `interface` / `type` / `struct` / `enum` / `trait` / `dataclass` / schema definitions

   When in doubt, include the specialist (over-coverage is cheaper than missed findings).

2. **Spawn Stage 1 specialists in parallel** via `spawn_agent`. **Critical: do not specify `agent_type`, `model`, or `reasoning_effort` in any spawn call** — these inherit from the parent skill, and supplying them causes `Full-history forked agents inherit the parent agent type` errors. Pass each spawn the following structured prompt:
   - Target description: `Pre-PR review of branch <current> against <$BASE>`
   - The list of changed files (categorized)
   - The full `git diff $BASE...HEAD` output

   Always spawn:
   - `code-reviewer`
   - `security-reviewer`
   - `adversarial-reviewer`

   Conditionally spawn (based on categorization):
   - `pr-test-analyzer` — only if `test_paths` non-empty
   - `comment-analyzer` — only if `docs_or_comments` non-empty
   - `silent-failure-hunter` — only if `error_handling` non-empty
   - `type-design-analyzer` — only if `new_types` non-empty

3. **Await all Stage 1 specialists** before proceeding. Each returns markdown findings.

4. **Scan Stage 1 output for Critical findings.** A finding is "Critical" if:
   - The specialist explicitly labels it Critical, OR
   - `code-reviewer` reports confidence ≥ 90, OR
   - `adversarial-reviewer` returns `needs-attention` framing with any finding confidence ≥ 0.7, OR
   - Any `silent-failure-hunter` finding (this hunter only emits high-confidence silent failures)

5. **Stage 2 — conditional `code-simplifier` pass**: If Stage 1 surfaced **no** Critical findings, spawn `code-simplifier` with the same diff plus a brief Stage 1 summary so it knows what's already flagged. Otherwise, skip Stage 2 — polishing code with Critical issues is wasted effort.

6. **Aggregate** all specialist findings into the Output Format below. Preserve the originating specialist name in each bullet so the reader can trace lineage.

## Output format

```markdown
# PR Review: <branch> vs <base>

<degraded-coverage line if applicable>

## Critical Issues (X found)
- [<specialist>]: <description> [<file>:<line>]
  - Why it matters: ...
  - Suggested fix: ...

## Important Issues (X found)
- [<specialist>]: <description> [<file>:<line>]

## Suggestions (X found)
- [<specialist>]: <description> [<file>:<line>]

## Strengths
- <positive observations from specialists>

## Recommended Action
1. Fix Critical issues first
2. Address Important issues
3. Consider Suggestions
4. Re-run review after fixes
```

## See also

- Design Doc: `docs/design/codex-pr-review.md` (dotfiles repo)
- ADR 0020: clean-worktree invariant (Precondition 2 origin)
- Issue #186: scope-alignment fix (Precondition 3 origin)
- ADR 0023 (planned): final decision record
