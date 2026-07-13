---
name: pr-review
description: Comprehensive pre-PR review orchestrator. Spawns up to 8 specialist subagents (code-reviewer, security-reviewer, adversarial-reviewer, pr-test-analyzer, comment-analyzer, silent-failure-hunter, type-design-analyzer, code-simplifier) on the current branch's changes against its base ref, then synthesizes Critical / Important / Suggestions / Strengths findings using the bundled `references/review-criteria.md` gate policy. Use before creating a pull request as a quality gate. Intended successor to the legacy bash `triple-review` orchestrator.
---

# pr-review

## Goal

Run a comprehensive specialist review of the current branch's changes against its base, then synthesize findings into a single actionable report.

## Review Criteria

Use the bundled `references/review-criteria.md` as the source of truth for severity normalization, output budgeting, and re-review behavior. The short global `AGENTS.md` / `CLAUDE.md` policy explains when to choose built-in review versus heavy gates; this skill file and its bundled reference define how `$pr-review` gates a change once invoked.

Apply these high-level constraints throughout the Procedure:
- Optimize for merge decisions, not finding count.
- Do not put nits, style preferences, speculative rewrites, or weakly grounded concerns into the fix queue.
- Important findings are capped at 5 in the final aggregation; Suggestions are capped at 3.
- If evidence is incomplete but the risk may be severe, state the missing verification explicitly instead of silently dropping the finding.
- Re-review verifies prior Critical/Important findings and should not extend the loop with new nits, style feedback, or optional refactors.
- Critical findings require `blocking: yes`, `impact_scope`, `verified_assumptions`, and no `unverified_assumptions` needed for the blocker claim.
- Post-verification `needs-verification` with non-empty `missingVerification` downgrades a Critical candidate to Important; it remains visible, but not as a proven blocker. Other verdicts carrying `missingVerification`, or `needs-verification` without it, are invalid verifier outputs and must fail closed.
- Stop the review loop when Critical and Important are both 0; do not re-run only for Suggestions.

## Preconditions

**Environment note**: this skill must be invoked from a terminal directly (`codex exec ...`), not from within an enclosing Claude Code session. The nested-bwrap permission failure documented in `~/.codex/history.jsonl` (2026-03) makes nested invocation infinite-spawn-retry. The skill cannot reliably self-detect this; the caller takes responsibility.

Run these checks in order. If any fails, abort with the indicated actionable error and do not proceed to the Procedure section.

1. **Clean worktree** — Run `git status --porcelain --untracked-files=normal`. If the command fails, abort with the command output and do not review an unknown worktree state. If output is non-empty (uncommitted tracked changes or untracked-non-ignored files), abort with:
   > "Worktree has uncommitted changes: \<list\>. The review covers committed branch diff only; uncommitted changes would be silently excluded. To inspect staged, unstaged, and untracked changes first, run `codex review --uncommitted`. Commit or stash all listed changes, then retry `$pr-review`. (See ADR 0020.)"

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

   Sandbox compatibility by base path:
   - Explicit immutable commit/OID bases do not require network access or `.git` metadata writes after the initial clean-worktree check; this is the only supported offline/read-only invocation path.
   - Explicit branch-name bases require network access and `git fetch` writing `FETCH_HEAD`.
   - `--allow-no-pr` requires network access, `git fetch`, and `git remote set-head origin --auto`, so it is incompatible with strict read-only sandboxes.
   - Auto-PR base resolution requires `gh pr view`, network access, and a verified fetch of the reported base branch, so it is incompatible with strict read-only or offline runs.
   - If callers need offline/read-only review, they must supply an immutable base commit OID.

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
   - Always write the exact full diff to a temp file, compute its byte count and SHA-256, and include the path, byte count, and SHA-256 in the specialist prompt. Use a BSD/GNU-compatible suffix-free `mktemp` template with the random `X`s at the end, such as `diff_packet=$(mktemp "${TMPDIR:-/tmp}/pr-review-diff.XXXXXX")`; do not use a suffixed template such as `pr-review-diff.XXXXXX.diff`, which can collide on BSD `mktemp`. Abort if `mktemp`, diff writing, byte counting, or hashing fails. The diff packet is authoritative; any inline diff text is only a convenience excerpt. If a specialist cannot read the referenced packet or the packet hash does not match, it must return a fatal coverage error.
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

2. **Select the multi-agent adapter, then build and spawn the Stage 1 specialist set** via `spawn_agent`.
   - Inspect the callable tool schemas before the first spawn; do not probe the runtime by spawning a disposable agent. Prefer V2 only when `spawn_agent` exposes required `task_name` plus `fork_turns`, `wait_agent` has no target argument, and `list_agents` plus `interrupt_agent` are available. Otherwise select V1 only when `spawn_agent` has no `task_name`/`fork_turns`, `wait_agent` accepts `targets`, and `close_agent` is available. Fail closed before spawning on a mixed or unknown shape.
   - Both adapters require `agent_type` to be visible and every specialist spawn **must** set `agent_type = "<specialist-name>"`. If metadata hiding removes `agent_type`, fail closed with guidance to set `[features.multi_agent_v2] hide_spawn_agent_metadata = false`; never fall back to the generic/default role.
   - V1 spawn arguments are `agent_type` and `message`; record the returned `agent_id`. Do not pass V2-only arguments.
   - V2 spawn arguments are `agent_type`, `task_name`, `message`, and `fork_turns = "none"`. `fork_turns = "all"` is forbidden because Codex 0.144.1 rejects role overrides on a full-history fork. Do not pass `model`, `reasoning_effort`, or `service_tier`; inherit the parent settings.
   - The managed specialist TOMLs set `[features.multi_agent_v2] hide_spawn_agent_metadata = true` in the child role layer. The root needs visible `agent_type` to select the role, but reviewer children do not spawn descendants; re-hiding metadata there keeps their reserved tool schema compatible. Treat a child startup/tool-schema error as an unusable result and fail closed.
   - For V2, derive a run token from the authoritative diff packet's `mktemp` suffix. Build the raw name `prr_<run_token>_<stage>_<specialist>_a<attempt>`, then normalize the **entire task name**, not only the run token: lowercase it and replace every character outside `[a-z0-9_]` with `_`. Validate the final name against `^[a-z0-9_]+$` and confirm it has not already been used in this run before spawning. Thus `code-reviewer` becomes `code_reviewer`, for example `prr_ab12cd_s1_code_reviewer_a1`. Start each specialist at attempt 1; every retry increments the attempt and uses a new task name.
   - Record the complete `expected_stage1` set before spawning so completeness can be checked before aggregation.
   - Keep `pending_stage1` in deterministic specialist order. Under V1, keep `running_stage1` as active `agent_id`s and `completed_stage1` as recorded outputs, with at most 6 running specialists. Under V2, keep `pending_stage1`, `running_stage1`, and `harvested_stage1`, key active-run tasks by their requested and returned canonical task names, and allow at most 3 running specialists because the default four-thread session limit includes the root.
   - Under V1, when more specialists are pending, wait for a final usable result, record it, close that completed agent, then spawn the next pending specialist. Under V2, never spawn a pending specialist merely because a mailbox notification arrived: first run the V2 harvest sequence in step 3 and record every completed result, then spawn the next pending specialist. Never drop a scheduled specialist because of the thread limit.
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
     - Finding quality contract: every finding must include `blocking: yes/no`, `impact_scope`, `verified_assumptions`, and `unverified_assumptions`. Use `blocking: yes` only for clear merge blockers in the committed diff. Machine-local or ignored state, local-only performance regressions, developer-workflow-only false-greens, advisory observability gaps, and assumption-dependent risks should be `blocking: no` unless the committed diff proves a wider blocker.

   Always spawn:
   - `code-reviewer`
   - `security-reviewer`
   - `adversarial-reviewer`

   Conditionally spawn (based on categorization):
   - `pr-test-analyzer` — if `code_paths` is non-empty, especially when `test_paths` is empty
   - `comment-analyzer` — only if `docs_or_comments` non-empty
   - `silent-failure-hunter` — if `code_paths` is non-empty (the hunter suppresses noise internally; default-on avoids heuristic false negatives such as shell `|| true`)
   - `type-design-analyzer` — only if `type_changes` non-empty

3. **Await and harvest all Stage 1 specialists** before proceeding.
   - V1: `wait_agent` with multiple targets returns when a target reaches a final status, not necessarily when every target is complete. Treat it as a polling primitive, not a barrier. Keep the remaining expected `agent_id`s, call `wait_agent` with those targets and `timeout_ms = 600000`, record only final usable results, close each recorded completed agent, and then refill from the pending queue.
   - V2: `wait_agent(timeout_ms = 600000)` is mailbox polling only. It accepts no targets and its return value contains no specialist result. After every wait, call `list_agents`, filter to the active run's expected canonical task names, and immediately record and validate the non-empty message from **every** `Completed` task before spawning anything else. Only after this harvest may the next pending specialist be spawned. This harvest-before-spawn order is mandatory because a V2 spawn at capacity may LRU-unload a completed resident and `list_agents` silently omits unloaded threads.
   - For V2, keep running tasks that are still non-final. A listed `Errored` or `Interrupted` expected task is unusable. If any already-spawned, not-yet-harvested task disappears from `list_agents`, fail closed as an unload/runtime mismatch; pending tasks are not subject to this presence check until their spawn succeeds. Treat inter-agent/mailbox completion text only as a notification; the authoritative result is the active-run `Completed` message harvested from `list_agents`.
   - If a V2 spawn reports capacity exhaustion while this run still has running tasks, wait, harvest, increment that specialist's attempt, and retry with a newly normalized unique task name. If this run has no running tasks, fail closed as an external capacity conflict. Do not retry a task that disappeared from `list_agents` and do not aggregate partial results.
   - Enforce a Stage 1 wall-clock budget of 30 minutes. If no expected specialist completes before a wait timeout, the stage budget is exceeded, or any expected agent/task is still non-final after the budget, clean up remaining running work with the selected adapter and fail closed before aggregation.
   - Fail closed before aggregation if any expected specialist fails to spawn, errors, is interrupted, times out, returns empty output, or produces unusable output. Before a V1 abort, close every remaining running Stage 1 agent. Before a V2 abort, interrupt every running task owned by this run; V2 has no `close_agent`, so leave already completed residents to runtime LRU management.
   - Fail closed before Stage 2 or aggregation if any specialist output is missing a first-line `COVERAGE_OK ...` or `FATAL_COVERAGE_ERROR ...` sentinel, or if the `COVERAGE_OK` sentinel does not match the expected specialist name, `$BASE_COMMIT...$HEAD_REF` scope, and packet SHA-256.
   - Fail closed before Stage 2 or aggregation if any specialist output reports a fatal coverage error, missing/inconsistent scope, inability to read the diff packet, packet hash mismatch, or otherwise says it was unable to verify the packet or reviewed scope.
   - Do **not** silently aggregate partial coverage. If a future workflow wants partial results, require an explicit opt-in plus a visible degraded-coverage banner.
   - Each successful specialist returns the coverage sentinel followed by markdown findings.

4. **Scan Stage 1 output and normalize severity before Stage 2**:
   - Apply `references/review-criteria.md` before trusting specialist labels. Specialist labels are useful signals, but final severity must still satisfy the bundled criteria.
   - Read `references/severity-rules.json` and classify each finding with its escalation table. The table is shared verbatim with the Claude-side `/pr-review` skill; when the escalation rules change, edit the table, not skill prose.
     - A finding is **Critical** when it matches any rule in the table's `critical.any_of` AND satisfies `critical.guard` (a concrete merge-blocking risk from the committed branch diff).
       - Treat a specialist Critical label as a candidate, not final severity. Re-check `blocking`, `impact_scope`, `verified_assumptions`, and `unverified_assumptions`; do not keep Critical when the blocker depends on unverified assumptions.
       - Downgrade local-only, ignored generated state, developer-workflow-only false-green, local-only performance, or advisory observability findings to Important or Suggestion unless the committed diff proves an authoritative gate or merge outcome will be wrong.
     - A finding that did not qualify as Critical is **Important** when it matches any rule in `important.any_of` AND satisfies `important.guard`.
     - Treat remaining advisory findings as Suggestions unless the specialist explicitly marks them as positive observations, per the table's `suggestion` rule.
   - Do not promote nits, style preferences, speculative rewrites, or weakly grounded concerns into Critical or Important.
   - If evidence is incomplete but the risk may be severe, keep the item with the missing verification stated explicitly instead of silently dropping it.
   - If post-verification produces `needs-verification` with non-empty `missingVerification` for a Critical candidate, downgrade it to Important before final aggregation. It remains in the fix queue with the missing verification stated, but it is not a proven Critical blocker. Other verdicts carrying `missingVerification`, or `needs-verification` without it, are invalid verifier outputs and must fail closed.

5. **Stage 2 — conditional `code-simplifier` pass**:
   - If Stage 1 surfaced **no** Critical findings, record `expected_stage2 = {code-simplifier}`, then spawn `code-simplifier` through the selected adapter with the same target description, `$BASE_REF`, `$BASE_COMMIT`, `$HEAD_REF`, changed-file list, `git status --short`, `git log --no-decorate "$BASE_COMMIT..$HEAD_REF"`, diff packet path, byte count, SHA-256, Scope contract, Coverage sentinel contract, and review-only contract, plus a brief Stage 1 summary so it knows what's already flagged. Request advisory simplification findings only. For V2 use stage segment `s2`, attempt 1, whole-name normalization, and `fork_turns = "none"`.
   - Apply the same first-line `COVERAGE_OK ...` / `FATAL_COVERAGE_ERROR ...` sentinel validation, packet SHA-256 validation, and fatal coverage error handling to Stage 2 output before final aggregation.
   - If the scheduled Stage 2 specialist fails to spawn, errors, is interrupted, times out, returns empty output, or produces unusable output, clean it up with V1 `close_agent` or V2 `interrupt_agent` when still running, then fail closed before final aggregation (or require the same future explicit degraded-coverage opt-in as Stage 1).
   - Await Stage 2 with the selected adapter's same V1 remaining-ID loop or V2 wait/list/harvest sequence and a 10 minute Stage 2 wall-clock budget.
   - Otherwise, skip Stage 2 — polishing code with Critical issues is wasted effort.

6. **Final worktree guard**:
   - Run `git status --porcelain --untracked-files=normal` again after all specialists complete and before aggregation, or before the empty-diff early exit.
   - If the command fails, abort with the command output and do not aggregate against an unknown worktree state.
   - If output is non-empty, abort with:
     > "Review subagents or concurrent tooling changed the worktree: \<list\>. These changes were not part of the reviewed committed diff. Revert, commit, or stash them, then retry."
   - Run `git rev-parse HEAD` again and compare it with the recorded `$HEAD_REF`. If it differs, abort with:
     > "HEAD changed during review: started at `<old>`, now `<new>`. The completed specialist results do not cover the current commit. Re-run the review."

7. **Aggregate** all specialist findings into the Output Format below. Preserve the originating specialist name in each bullet so the reader can trace lineage. Always include the stop condition in Recommended Action: `Critical 0 / Important 0` means stop; Suggestions alone do not justify another gate run. On the second and later pass, focus on prior Critical/Important resolution. On the third and later pass, if Critical/Important findings keep appearing or changing without stable blocker evidence, call out possible review churn and return the decision to a human maintainer.

## Output format

```markdown
# PR Review: <branch> vs <base>

<degraded-coverage line if applicable>

## Critical Issues (X found)
- [<specialist>]: <description> [<file>:<line>]
  - Impact scope: ...
  - Verified assumptions: ...
  - Unverified assumptions: ...
  - Why it matters: ...
  - Suggested fix: ...

## Important Issues (X shown, top 5)
- [<specialist>]: <description> [<file>:<line>]
  - Impact scope: ...
  - Missing verification: <if any>

## Suggestions (X shown, max 3)
- [<specialist>]: <description> [<file>:<line>]

## Strengths
- <positive observations from specialists>

## Recommended Action
1. Fix Critical issues first
2. Address Important issues
3. Consider Suggestions
4. Re-run review after fixes to verify prior Critical/Important findings
5. Stop when Critical 0 / Important 0; do not re-run for Suggestions only
6. If this is the third or later pass and Critical/Important findings still churn, escalate to human judgment
```

## See also

- Design Doc: `docs/design/codex-pr-review.md` (dotfiles repo)
- ADR 0020: clean-worktree invariant (Precondition 1 origin)
- Issue #186: scope-alignment fix (Precondition 2 origin)
- ADR 0023 (planned): final decision record
