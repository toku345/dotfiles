---
name: pr-review
description: Comprehensive pre-PR review orchestrator. Spawns up to 8 specialist subagents (code-reviewer, security-reviewer, adversarial-reviewer, pr-test-analyzer, comment-analyzer, silent-failure-hunter, type-design-analyzer, code-simplifier) on the current branch's changes against its base ref, then synthesizes Critical / Important / Suggestions / Strengths findings. Use before creating a pull request as a quality gate. Intended successor to the legacy bash `triple-review` orchestrator.
---

# pr-review

## Goal

Run a comprehensive specialist review of the current branch's changes against its base, then synthesize findings into a single actionable report.

## Preconditions

**Environment note**: this skill must be invoked from a terminal directly (`codex exec ...`), not from within an enclosing Claude Code session. The nested-bwrap permission failure documented in `~/.codex/history.jsonl` (2026-03) makes nested invocation infinite-spawn-retry. The skill cannot reliably self-detect this; the caller takes responsibility.

Run these checks in order. If any fails, abort with the indicated actionable error and do not proceed to the Procedure section.

1. **Clean worktree** — Run `git status --porcelain --untracked-files=normal`. If the command fails, abort with the command output and do not review an unknown worktree state. If output is non-empty (uncommitted tracked changes or untracked-non-ignored files), abort with:
   > "Worktree has uncommitted changes: \<list\>. The review covers committed branch diff only; uncommitted changes would be silently excluded. Commit or stash first, then retry. (See ADR 0020.)"

2. **Base ref resolution** — Determine `$BASE` from one of three sources, in priority order:
   - (a) If the user prompt provides an explicit base (for example, `--base develop` or "review against develop"), use that verbatim and skip all `gh` checks below. If the explicit base is an immutable commit/OID, set `$BASE_REF` to that value. Otherwise treat it as an origin branch name only after it passes `git check-ref-format --branch "$BASE"` and does not start with `-` or `+`, contain `:`, or contain another refspec/control separator; reject anything else before running `git fetch`. For a valid branch name, run `git fetch --quiet origin "refs/heads/$BASE"` before validation, abort if fetch fails, set `$BASE_REF=FETCH_HEAD`, and resolve `$BASE_COMMIT` immediately before any later fetch can overwrite `FETCH_HEAD`. Do not pass `$BASE` as a raw refspec. Do not proceed from existing local refs alone. If the caller needs offline execution, pass an immutable base commit.
   - (b) If the user prompt includes `--allow-no-pr` or `$ALLOW_NO_PR` is set to `1` / `true`, skip `gh` entirely. Run `git fetch --quiet origin`; if it fails, abort instead of reviewing a possibly stale default branch. Run `git remote set-head origin --auto`; if it fails, abort instead of trusting a stale local `origin/HEAD` symref. Run `git symbolic-ref --quiet --short refs/remotes/origin/HEAD`; if it fails or returns an empty value, abort instead of guessing a base. Strip the leading `origin/` from the captured value, use the result as `$BASE`, use the full captured `origin/<branch>` ref as `$BASE_REF`, and add a `**Degraded coverage**: no PR base, fell back to default branch` line to the Output.
   - (c) Otherwise verify that `gh` is callable and authenticated before using it:
     - Run `gh auth status`.
     - If it fails, do not classify the plain output alone. Run `GH_DEBUG=api gh auth status` as the discriminator.
     - If debug output shows sandbox or network denial while contacting GitHub (for example `socket: operation not permitted`, DNS/connect failures caused by sandbox policy, or blocked TLS/service access), abort with:
       > "`gh` cannot execute under the current sandbox/network policy. Re-invoke `codex exec` with a sandbox mode verified for this OS, or supply an explicit base in your prompt to bypass `gh pr view`."
     - If debug output reaches GitHub and indicates a real credential failure, abort with:
       > "Stale `gh` auth detected. Run `gh auth login` and retry — the skill cannot resolve PR base ref without authenticated gh."
     - If the failure remains ambiguous after debug output, abort with the collected output and do not continue.
     - Then run `gh pr view --json baseRefName,baseRefOid --jq '[.baseRefName,.baseRefOid] | @tsv'`.
     - If it returns exactly two non-empty tab-separated fields (branch name and base commit OID), use the branch name as `$BASE`. Validate the returned branch name with the same explicit-branch safety rules (`git check-ref-format --branch "$BASE"`, no leading `-` / `+`, no `:` or other refspec/control separator). Then run `git fetch --quiet origin "refs/heads/$BASE"`; if it fails, abort instead of assuming the returned OID exists locally. Resolve `FETCH_HEAD^{commit}` and verify it exactly equals the returned `baseRefOid`; if it differs, abort with both OIDs. Set `$BASE_REF=FETCH_HEAD` only after that verification.
     - If it succeeds but does not return exactly two non-empty tab-separated fields, abort with the raw output and do not infer a base from malformed data.
     - If it fails, only treat an explicit "no pull request found for the current branch" result as the no-PR case. Any sandbox, network, API, or other unexpected `gh pr view` failure must abort loudly instead of falling back to `origin/HEAD`.

   If none of (a)–(c) yields a base, abort with:
   > "No PR found for the current branch and no explicit base provided. By default the skill requires an open PR (Issue #186 fix) so all specialists share the same base ref. Either create a draft PR first, provide an explicit base in your prompt, or pass `--allow-no-pr` / set `ALLOW_NO_PR=1` to fall back to the default branch (residual scope-divergence risk acknowledged)."

3. **Base ref validation** — Pin the already resolved `$BASE_REF` to an immutable commit before collecting any diff:
   - If `gh pr view` returned `baseRefOid`, keep `$BASE_REF=FETCH_HEAD` after the verified fetch/OID comparison; do not resolve the OID against a possibly stale local object database without fetching the PR base branch first.
   - If an explicit branch base was fetched, keep `$BASE_REF=FETCH_HEAD`; do not replace it with a local branch or local remote-tracking ref.
   - If `--allow-no-pr` selected the default branch, keep `$BASE_REF` as the fetched `origin/<branch>` ref.
   - Otherwise use the explicit immutable base as `$BASE_REF`.
   - Run `BASE_COMMIT=$(git rev-parse --verify "$BASE_REF^{commit}")` immediately after assigning `$BASE_REF` and record the exact output for all later collection and specialist prompts. If it fails, abort with:
     > "Base ref `<base>` does not resolve to a commit. Check the base name or fetch the ref, then retry."

## Procedure

After preconditions pass:

1. **Collect the review inputs and classify the diff**:
   - Run `git rev-parse HEAD` before collecting the diff and record it as `$HEAD_REF`.
   - Run `git status --short`, `git log --no-decorate "$BASE_COMMIT..$HEAD_REF"`, `git diff --name-only "$BASE_COMMIT"..."$HEAD_REF"`, and `git diff "$BASE_COMMIT"..."$HEAD_REF"`.
   - Require every command to exit successfully. If any collection command fails, abort loudly instead of reviewing partial input.
   - If the diff is genuinely empty, run the Final worktree guard immediately, then say `No committed changes relative to <base>; nothing to review.` and stop rather than emitting a normal green review. Do not skip the final worktree or HEAD checks on the empty-diff path.
   - Always write the exact full diff to a temp file, compute its byte count and SHA-256, and include the path, byte count, and SHA-256 in the specialist prompt. The diff packet is authoritative; any inline diff text is only a convenience excerpt. If a specialist cannot read the referenced packet or the packet hash does not match, it must return a fatal coverage error.
   - Use `git diff --name-only` only for path-based categories:
     - `test_paths`: path components or basenames that are tests, such as `tests/`, `test/`, `__tests__/`, `*.test.*`, `*.spec.*`, `*_test.go`, `*_spec.rb`, `*.bats`, or basenames beginning with `test_`; do not classify ordinary runtime files as tests merely because they contain `test` in a role name such as `pr-test-analyzer`
     - `operational_paths`: review/runtime assets such as `private_dot_codex/skills/**/SKILL.md`, `private_dot_codex/agents/*.toml`, `.github/workflows/**`, `.claude/hooks/**`, `.chezmoiscripts/**`, `dot_local/bin/**`, and managed shell/config files whose content affects tool behavior
     - `docs_paths`: passive prose docs such as `docs/`, `*.md`, or `README*`, excluding any path already classified as `operational_paths`
     - `code_paths`: changed paths that are not passive docs-only assets, plus all `operational_paths`
   - Inspect the full diff hunks for content-based categories:
     - `comment_changes`: any added or removed comment line in source files, including mixed code+comment hunks
     - `docs_or_comments`: `docs_paths` non-empty or `comment_changes` non-empty
     - `type_changes`: hunks introducing `class` / `interface` / `type` / `struct` / `enum` / `trait` / `dataclass` / schema definitions, plus hunks modifying lines inside an existing type or schema definition block

   When in doubt, include the specialist (over-coverage is cheaper than missed findings).

2. **Build the Stage 1 specialist set and spawn it in parallel** via `spawn_agent`.
   - Current Codex 0.130.0 contract: `agent_type` selects the custom role; if omitted, Codex uses role `default`. Therefore every specialist spawn **must** set `agent_type = "<specialist-name>"`.
   - Do not set `model` or `reasoning_effort` unless intentionally overriding the parent's selection; those inherit from the parent when omitted.
   - Record the complete `expected_stage1` set before spawning so completeness can be checked before aggregation.
   - Spawn Stage 1 with a bounded fanout: keep `pending_stage1` in deterministic specialist order, `running_stage1` as active `agent_id`s, and `completed_stage1` as final usable outputs. Start at most 6 Stage 1 specialists at a time. If more specialists are pending, wait for a running specialist to reach final usable status, close that completed agent, then spawn the next pending specialist. Never drop a scheduled specialist because of the thread limit; if a pending specialist cannot be spawned after capacity is freed, fail closed before aggregation.
   - Pass each spawn the following structured prompt:
     - Target description: `Pre-PR review of branch <current> against <$BASE>`
     - The resolved `$BASE_REF`
     - The recorded `$BASE_COMMIT`
     - The recorded `$HEAD_REF`
     - The list of changed files (categorized)
     - `git status --short`
     - `git log --no-decorate "$BASE_COMMIT..$HEAD_REF"`
     - The diff packet path, byte count, and SHA-256 (always supplied)
     - Optional inline excerpt from `git diff "$BASE_COMMIT"..."$HEAD_REF"`; the packet remains authoritative if output is truncated
     - Scope contract: review only the orchestrator-provided `$BASE_COMMIT...$HEAD_REF` committed branch diff. Do not substitute unqualified `git diff`, unstaged changes, a PR re-detection, a different base commit, a different HEAD, or another inferred scope. If the diff, file list, base commit, HEAD ref, or packet hash is missing or inconsistent, return a fatal coverage error.
     - Coverage sentinel contract: the first output line must be either `COVERAGE_OK <specialist> $BASE_COMMIT...$HEAD_REF <packet_sha256>` or `FATAL_COVERAGE_ERROR <specialist>: <reason>`. Missing, malformed, or non-first-line sentinels are unusable output.
     - Review-only contract: do not edit files, create files, apply patches, run formatters that write files, or otherwise dirty the worktree. Return markdown findings or suggestions only.

   Always spawn:
   - `code-reviewer`
   - `security-reviewer`
   - `adversarial-reviewer`

   Conditionally spawn (based on categorization):
   - `pr-test-analyzer` — if `code_paths` is non-empty, especially when `test_paths` is empty
   - `comment-analyzer` — only if `docs_or_comments` non-empty
   - `silent-failure-hunter` — if `code_paths` is non-empty (the hunter suppresses noise internally; default-on avoids heuristic false negatives such as shell `|| true`)
   - `type-design-analyzer` — only if `type_changes` non-empty

3. **Await all Stage 1 specialists** before proceeding.
   - `wait_agent` with multiple targets returns when a target reaches a final status, not necessarily when every target is complete. Treat it as a polling primitive, not a barrier.
   - Keep a set of remaining expected `agent_id`s. Call `wait_agent` with the remaining IDs and an explicit `timeout_ms` of 600000. Remove only agents that returned a final usable status. Close completed agents after their output has been recorded. Repeat until the remaining set is empty, spawning any queued Stage 1 specialists as capacity becomes available.
   - Enforce a Stage 1 wall-clock budget of 30 minutes. If no expected specialist completes before a wait timeout, the stage budget is exceeded, or any expected ID is still non-final after the budget, close every remaining running Stage 1 agent, then fail closed before aggregation.
   - Fail closed before aggregation if any expected specialist fails to spawn, errors, times out, returns empty output, or produces unusable output. Before aborting after any Stage 1 spawn, close every remaining running Stage 1 agent so failed reviews do not leave live specialists behind.
   - Fail closed before Stage 2 or aggregation if any specialist output is missing a first-line `COVERAGE_OK ...` or `FATAL_COVERAGE_ERROR ...` sentinel, or if the `COVERAGE_OK` sentinel does not match the expected specialist name, `$BASE_COMMIT...$HEAD_REF` scope, and packet SHA-256.
   - Fail closed before Stage 2 or aggregation if any specialist output reports a fatal coverage error, missing/inconsistent scope, inability to read the diff packet, packet hash mismatch, or otherwise says it was unable to verify the packet or reviewed scope.
   - Do **not** silently aggregate partial coverage. If a future workflow wants partial results, require an explicit opt-in plus a visible degraded-coverage banner.
   - Each successful specialist returns the coverage sentinel followed by markdown findings.

4. **Scan Stage 1 output and normalize severity before Stage 2**:
   - Treat a finding as "Critical" if:
     - The specialist explicitly labels it Critical, OR
     - `code-reviewer` reports confidence ≥ 90, OR
     - `adversarial-reviewer` returns `needs-attention` framing with any finding confidence ≥ 0.7, OR
     - `silent-failure-hunter` explicitly labels the finding CRITICAL, OR
     - `security-reviewer` reports `Severity: High` / `Severity: HIGH` / any case-insensitive equivalent
   - Treat a finding as "Important" if:
     - The specialist explicitly labels it Important, High, or HIGH without meeting the Critical rules above, OR
     - `security-reviewer` reports `Severity: Medium` / `Severity: MEDIUM` / any case-insensitive equivalent, OR
     - `pr-test-analyzer` reports a Critical Gap or Important Improvement that is not already Critical
   - Treat remaining advisory findings as Suggestions unless the specialist explicitly marks them as positive observations.

5. **Stage 2 — conditional `code-simplifier` pass**:
   - If Stage 1 surfaced **no** Critical findings, record `expected_stage2 = {code-simplifier}`, then spawn `code-simplifier` with the same target description, `$BASE_REF`, `$BASE_COMMIT`, `$HEAD_REF`, changed-file list, `git status --short`, `git log --no-decorate "$BASE_COMMIT..$HEAD_REF"`, diff packet path, byte count, SHA-256, Scope contract, Coverage sentinel contract, and review-only contract, plus a brief Stage 1 summary so it knows what's already flagged. Request advisory simplification findings only.
   - Apply the same first-line `COVERAGE_OK ...` / `FATAL_COVERAGE_ERROR ...` sentinel validation, packet SHA-256 validation, and fatal coverage error handling to Stage 2 output before final aggregation.
   - If the scheduled Stage 2 specialist fails to spawn, errors, times out, returns empty output, or produces unusable output, close the running Stage 2 agent if it exists, then fail closed before final aggregation (or require the same future explicit degraded-coverage opt-in as Stage 1).
   - Await Stage 2 with the same explicit remaining-ID loop and a 10 minute Stage 2 wall-clock budget.
   - Otherwise, skip Stage 2 — polishing code with Critical issues is wasted effort.

6. **Final worktree guard**:
   - Run `git status --porcelain --untracked-files=normal` again after all specialists complete and before aggregation, or before the empty-diff early exit.
   - If the command fails, abort with the command output and do not aggregate against an unknown worktree state.
   - If output is non-empty, abort with:
     > "Review subagents or concurrent tooling changed the worktree: \<list\>. These changes were not part of the reviewed committed diff. Revert, commit, or stash them, then retry."
   - Run `git rev-parse HEAD` again and compare it with the recorded `$HEAD_REF`. If it differs, abort with:
     > "HEAD changed during review: started at `<old>`, now `<new>`. The completed specialist results do not cover the current commit. Re-run the review."

7. **Aggregate** all specialist findings into the Output Format below. Preserve the originating specialist name in each bullet so the reader can trace lineage.

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
- ADR 0020: clean-worktree invariant (Precondition 1 origin)
- Issue #186: scope-alignment fix (Precondition 2 origin)
- ADR 0023 (planned): final decision record
