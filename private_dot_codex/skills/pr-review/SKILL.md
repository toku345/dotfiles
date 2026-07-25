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

0. **V1/V2 runtime contract** — Before running any shell or Git command and before invoking any collaboration tool, inspect the tool definitions exposed to this session. Runtime contract sentinel: `PR_REVIEW_RUNTIME_CONTRACT_V1_V2`.
   - If collaboration tools are deferred, use the runtime's tool-discovery mechanism to resolve and inspect their definitions. Tool discovery is allowed here; a probe spawn is not. Do not infer the contract from feature flags, model name, tool namespace, profile name, or a prior session.
   - Admit exactly one coherent family and record the selected adapter for the entire run:
     - **The V1 adapter** requires `spawn_agent(agent_type,message)` with both arguments required and an `agent_id` in the successful result, targeted `wait_agent(targets)`, and `close_agent(agent_id)`. Its `spawn_agent` must not accept `task_name` or `fork_turns`.
     - **The V2 adapter** requires `spawn_agent(task_name,message,agent_type?,fork_turns?,model?,reasoning_effort?)` with `task_name` and `message` required, untargeted `wait_agent(timeout_ms?)`, `list_agents(path_prefix?)`, and `interrupt_agent(target)`. Its `wait_agent` must not accept `targets`; `close_agent` must not be part of this family. `send_message(target,message)` and `followup_task(target,message)` may also be present and do not make the schema mixed, but the orchestrator must not use them for review-result transport or synchronization, and specialists must not use them under the control-plane ban. Although `agent_type`, `fork_turns`, `model`, and `reasoning_effort` are optional in the tool schema, every pr-review specialist spawn must set the exact `agent_type` and explicitly set `fork_turns` to `"none"`; omit `model` and `reasoning_effort` to inherit the parent.
   - Optional unrelated, non-discriminating fields may be present in either family and do not by themselves make it mixed. Admission is determined by the required and forbidden control fields above; any added field that conflicts with those discriminators, or changes result identity or wait/cleanup semantics, is unknown and incompatible.
   - Missing, unresolved, incomplete, mixed, or unknown definitions are not compatible. Do not combine tools from different families or use a generic/default agent fallback.
   - If no coherent adapter can be selected, abort before repository inspection with this exact message:

     ```text
     ERROR: $pr-review requires one coherent Codex multi-agent V1 or V2 schema, but this session exposes missing, mixed, incomplete, or unknown collaboration tools.

     No specialist was spawned and no review was performed. Tool exposure is fixed for the lifetime of this session.

     Start a new Codex process from the repository under review:

       codex exec --profile review -C '<repo-root>' '$pr-review --base <same-base>'

     If the review-profile command still does not expose one exact supported schema, stop and report compatibility drift. Do not fall back to default agents.
     ```

   - For both adapters, before repository inspection read `references/base-resolution-runtime-contract.json`, require sentinel `PR_REVIEW_BASE_RESOLUTION_CONTRACT_V2`, and use its operation allowlist, classification precedence, retry limit, invocation-fingerprint, immutable-OID values, and `allow_no_pr` transition sequence as the machine-readable base-resolution contract. Record whether the shell tool exposes `sandbox_permissions=require_escalated`; absence does not invalidate the immutable-OID path, but any later sandbox-denied operation that needs escalation must fail closed before specialist spawn. Abort before repository inspection if the contract is missing, malformed, unsupported, or conflicts with this prose.
   - For V2 only, call `list_agents` immediately after selection and require a **fresh agent tree**: the current orchestrator entry may exist, but it must have no descendant. Abort before repository inspection if listing fails, a descendant already exists, or the current tree cannot be identified unambiguously. This prevents this run from adopting, interrupting, or confusing another run's tasks.
   - For V2 only, before repository inspection read `references/v2-runtime-contract.json`, require sentinel `PR_REVIEW_V2_SCHEDULER_CONTRACT_V3`, and use its timing, spawn, result, reconciliation, cleanup, and aggregation values as the machine-readable scheduler contract. Abort before repository inspection if the file is missing, malformed, unsupported, or conflicts with this prose.

1. **Clean worktree** — Run `git status --porcelain --untracked-files=normal`. If the command fails, abort with the command output and do not review an unknown worktree state. If output is non-empty (uncommitted tracked changes or untracked-non-ignored files), abort with:
   > "Worktree has uncommitted changes: \<list\>. The review covers committed branch diff only; uncommitted changes would be silently excluded. To inspect staged, unstaged, and untracked changes first, run `codex review --uncommitted`. Commit or stash all listed changes, then retry `$pr-review`. (See ADR 0020.)"

2. **Base ref resolution** — Determine `$BASE` from one of three sources, in priority order. For the allowlisted `gh pr view`, `git fetch`, and `git remote set-head origin --auto` operations below, always try the ordinary sandbox first. Retry only a sandbox/transport denial (`socket: operation not permitted`, a sandbox-caused DNS/connect denial, blocked TLS/service access, or EROFS/EACCES on required `.git` metadata) by reissuing the exact original executable, argv, cwd, and ordinary environment once with `sandbox_permissions=require_escalated`. Never request a persistent prefix approval. Approval metadata and the sandbox field are the only permitted fingerprint differences. Do not elevate an ordinary Git ref/remote/SSH-auth error, a GitHub API error, or an ambiguous failure. If escalation is unavailable, denied, or fails, abort before specialist spawn and recommend an immutable base OID.
   - (a) If the user prompt provides an explicit base (for example, `--base develop` or "review against develop"), use that verbatim and skip all `gh` checks below. If the explicit base is an immutable commit/OID, set `$BASE_REF` to that value and do not run `gh`, fetch, or any elevated command. Otherwise treat it as an origin branch name only after it passes `git check-ref-format --branch "$BASE"` and does not start with `-` or `+`, contain `:`, or contain another refspec/control separator; reject anything else before running `git fetch`. For a valid branch name, run `git fetch --quiet origin "refs/heads/$BASE"` through the scoped retry policy before validation, abort if it still fails, set `$BASE_REF=FETCH_HEAD`, and resolve `$BASE_COMMIT` immediately before any later fetch can overwrite `FETCH_HEAD`. Do not pass `$BASE` as a raw refspec. Do not proceed from existing local refs alone. If the caller needs offline execution, pass an immutable base commit.
   - (b) If the user prompt includes `--allow-no-pr` or `$ALLOW_NO_PR` is set to `1` / `true`, skip `gh` entirely. Run `git fetch --quiet origin` through the scoped retry policy; if it still fails, abort instead of reviewing a possibly stale default branch. Run `git remote set-head origin --auto` through the same policy; if it still fails, abort instead of trusting a stale local `origin/HEAD` symref. Run `git symbolic-ref --quiet --short refs/remotes/origin/HEAD`; if it fails or returns an empty value, abort instead of guessing a base. Strip the leading `origin/` from the captured value, use the result as `$BASE`, use the full captured `origin/<branch>` ref as `$BASE_REF`, and add a `**Degraded coverage**: no PR base, fell back to default branch` line to the Output.
   - (c) Otherwise use the required PR lookup itself as the only GitHub auth/network probe; do not run the origin-unscoped `gh auth status`:
     - Run `gh pr view --json baseRefName,baseRefOid --jq '[.baseRefName,.baseRefOid] | @tsv'` in the ordinary sandbox.
     - If it fails with the explicit "no pull request found for the current branch" result, treat only that as the no-PR case. Otherwise run the same operation once in the ordinary sandbox with only `GH_DEBUG=api` added as a discriminator.
     - Give a proven sandbox/transport denial precedence over credential-looking text. On such a denial, retry the original non-debug `gh pr view` invocation once with `sandbox_permissions=require_escalated`. If the discriminator or elevated attempt reaches GitHub and proves HTTP 401 / bad credentials, abort with:
       > "Stale `gh` auth detected. Run `gh auth login` and retry — the skill cannot resolve PR base ref without authenticated gh."
     - If the discriminator remains ambiguous, escalation is unavailable/denied, or the elevated command fails for any other reason, abort with a sanitized classification and the immutable-OID escape hatch. Do not persist or reproduce raw debug headers, responses, credential text, or tokens.
     - If the successful authoritative result contains exactly two non-empty tab-separated fields (branch name and base commit OID), use the branch name as `$BASE`. Validate it with the same explicit-branch safety rules (`git check-ref-format --branch "$BASE"`, no leading `-` / `+`, no `:` or other refspec/control separator). Then run `git fetch --quiet origin "refs/heads/$BASE"` through the scoped retry policy. Resolve `FETCH_HEAD^{commit}` and verify it exactly equals the returned `baseRefOid`; if it differs, abort with both OIDs. Set `$BASE_REF=FETCH_HEAD` only after that verification.
     - If a successful result does not contain exactly two non-empty tab-separated fields, abort with sanitized output and do not infer a base from malformed data. Never fall back to `origin/HEAD` after an unexpected `gh pr view` failure.

   If none of (a)–(c) yields a base, abort with:
   > "No PR found for the current branch and no explicit base provided. By default the skill requires an open PR (Issue #186 fix) so all specialists share the same base ref. Either create a draft PR first, provide an explicit base in your prompt, or pass `--allow-no-pr` / set `ALLOW_NO_PR=1` to fall back to the default branch (residual scope-divergence risk acknowledged)."

   Sandbox compatibility by base path:
   - Explicit immutable commit/OID bases do not require network access or `.git` metadata writes after the initial clean-worktree check; this is the only supported offline/read-only invocation path.
   - Explicit branch-name bases require network access and `git fetch` writing `FETCH_HEAD`; sandbox denial may use the bounded scoped retry above.
   - `--allow-no-pr` requires network access, `git fetch`, and `git remote set-head origin --auto`; sandbox denial may use the same bounded scoped retry.
   - Auto-PR base resolution requires `gh pr view`, network access, and a verified fetch of the reported base branch; sandbox denial may use the bounded scoped retry, but offline runs remain unsupported.
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
   - Run `git rev-parse HEAD` as an independent, preceding tool call and wait for it to complete before starting any other collection. Do not put HEAD recording in the same parallel tool call as status, log, file-list, or diff collection.
   - Require that call to succeed and record its commit OID as immutable `$HEAD_REF`. If HEAD recording fails or does not return a commit OID, abort without starting collection.
   - After recording `$HEAD_REF`, use that immutable OID for every later log, file-list, and diff command. Do not use symbolic `HEAD` for those commands.
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

2. **Build the Stage 1 specialist set and spawn it in parallel** via `spawn_agent`.
   - Every specialist spawn **must** select the exact custom role with `agent_type = "<specialist-name>"`; omission and generic/default role fallback are forbidden in either adapter.
   - Do not set `model` or `reasoning_effort` unless intentionally overriding the parent's selection; those inherit from the parent when omitted.
   - Record the complete `expected_stage1` set before spawning so completeness can be checked before aggregation. It contains the three always-on roles plus up to four conditional roles, for a maximum of 7.
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
     - Control-plane contract: `Do not call any collaboration/subagent tools; return only your final review response.`
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

   Dispatch the recorded set through the selected adapter:
   - **The V1 adapter** keeps `pending_stage1` in deterministic order, `running_stage1` keyed by returned `agent_id`, and `completed_stage1` keyed by role. Run at most 6 Stage 1 agents concurrently. When one yields a final usable result, record it, call `close_agent` for that ID, and fill the freed slot. Never omit a scheduled role because of capacity.
   - **The V2 adapter** derives a lowercase alphanumeric `run_token` from the random suffix of the already-created diff-packet `mktemp` path; reject an empty or unsafe token. Name each task `prr_<run_token>_s<stage>_<role-with-hyphens-replaced-by-underscores>_a<attempt>`, and verify before spawning that the name is absent. Every spawn must set `fork_turns="none"`. Keep deterministic pending, running, and usable maps and run a **maximum of 3** children concurrently.
     - Save the exact canonical task path returned by each successful spawn; the local task name alone is never an identity. Before each spawn and after each wait notification, use `list_agents` to verify every non-usable canonical task and the tree shape.
     - If `spawn_agent` reports an error, immediately list status. If exactly the requested new name now exists and it did not exist before the call, adopt its canonical path and track it. If it is absent and the result is an **explicit capacity error**, retry once, only after a slot is available, with a new `attempt` name. A pre-existing name, more than one match, an absent task after any other/ambiguous error, or failure of the single retry is fatal. Never retry the same name.
     - After each notification, run one ordered reconciliation cycle: harvest and validate **all** newly delivered run-owned finals; call `list_agents` for one successful full-tree snapshot; harvest every envelope delivered at that tool boundary; evaluate all tracked tasks and descendants; then refill only if no fatal evidence exists. Never refill between those steps. Fill every freed slot immediately after its child becomes usable under Step 3, even while two other children remain running; do not wait for the current batch to finish. A scheduled role that cannot be spawned after a usable child frees capacity makes the stage fail closed.

3. **Await all Stage 1 specialists** before proceeding.
   - Start one monotonic 30-minute Stage 1 deadline before the first spawn. Neither progress, an interim message, a retry, nor a wait call resets it.
   - **The V1 adapter** treats targeted `wait_agent` as polling, not a barrier: keep the remaining `agent_id` set, call `wait_agent` with those IDs and `timeout_ms = min(600000, remaining stage budget)`, record only final usable results, close completed IDs, fill capacity, and repeat until all expected roles are complete.
   - **The V2 adapter** follows this state machine for each canonical task:

     | State | Evidence | Next action |
     | --- | --- | --- |
     | running | canonical path has running status | wait or inspect a delivered envelope |
     | final-seen | one matched `FINAL_ANSWER` payload, no accepted lifecycle evidence | retain the payload and reconcile status |
     | completed-seen | completed status, no final payload | allow a **60-second delivery grace**, bounded by the stage deadline |
     | retired-seen | task is absent from a successful full-tree snapshot after either observed-running evidence or a valid matching final | allow the same bounded delivery grace when the final is still pending |
     | usable | valid final payload plus completed status or qualified retirement | retain evidence and fill capacity |
     | fatal | error/interrupted status, disappearance without observed-running or a valid matching final, parent-interrupted retirement, invalid evidence, or expired deadline/grace | clean up and abort |

     - `wait_agent is notification-only`; never treat its return as a task result or barrier. `list_agents is status-only`; never extract review text from it. The only authoritative review body is the `Payload` of a delivered envelope whose `Message Type` is `FINAL_ANSWER` and whose `Sender` exactly equals a saved canonical task path. The envelope's `Task name` identifies the recipient (normally `/root`), not the child, and must never be used as sender identity.
     - Ignore interim `MESSAGE` envelopes and do not reset any deadline. Validate a matching final immediately: an empty body, malformed/missing first-line sentinel, `FATAL_COVERAGE_ERROR`, role/scope/hash mismatch, or stated inability to verify the packet is fatal before refill. Record the first valid matching final payload byte-for-byte. Ignore an identical duplicate `FINAL_ANSWER`; a **conflicting duplicate** for the same canonical task is fatal. A final payload from an unknown or merely name-matched sender is not usable.
     - Bound each notification poll to `min(60000 ms, remaining stage budget, earliest active delivery-grace budget)`, then run the ordered reconciliation cycle. Never make a blocking wait longer than 60 seconds. If the result is below the tool's 10000 ms minimum, do not issue a wait that would cross the budget; inspect already-delivered envelopes and current status, then fail when the applicable deadline expires if evidence is still incomplete.
     - Treat `completed` as normal lifecycle evidence. As a V2 compatibility fallback, also accept **qualified retirement** when a successful full-tree snapshot omits the exact saved canonical task after either (a) that task was previously observed with `running` status or (b) a valid matching `FINAL_ANSWER` from that canonical sender was already recorded. The final-backed path is allowed only because the recognized V2 runtime delivers `FINAL_ANSWER` at child-turn completion. Both paths require that the parent has never called `interrupt_agent` on the task and that no run-global fatal evidence exists. A spawn result, a failed/incomplete list, mere name matching, or disappearance before both observed running and a valid matching final is not retirement evidence and is fatal. If the runtime's child-turn-completion semantics or schema is not established, fail closed instead of applying the fallback. Any descendant other than a saved, tracked top-level specialist is an **unexpected descendant** and is fatal.
     - If completed status or qualified retirement arrives first, start one per-task grace at that earliest lifecycle-evidence timestamp. The valid final must arrive strictly before `grace_start + 60000 ms` and before the stage deadline; equality or later is fatal. If the final payload arrives first, keep reconciling until completed status, qualified retirement, or the stage deadline. Later evidence never resets grace.
     - Retain the first valid payload, lifecycle evidence, and canonical identity even after a task becomes usable and until stage aggregation. Continue validating later run-owned envelopes and statuses: ignore a byte-identical duplicate final, but make a conflicting duplicate, later observed error/interrupted status, or any other fatal evidence abort the stage. Run one final ordered reconciliation cycle before aggregation.
   - Fail closed before aggregation if any expected specialist fails to spawn, errors, times out, returns empty output, or produces unusable output. On any abnormal exit after a spawn, stop dispatching pending roles; cleanup start is monotonic fatal and a later final cannot restore usability. The V1 adapter closes every remaining running V1 ID. The V2 adapter performs one final notification/status drain without extending the applicable deadline, then calls `interrupt_agent` only on a still-running run-owned top-level task or a still-running unexpected descendant beneath one of its saved canonical paths. Never interrupt the orchestrator or an unrelated path. Finally list status again and require that no run-owned task or owned descendant remains running; if cleanup cannot be confirmed, report cleanup failure together with the original fatal reason. Do not aggregate any partial result during cleanup.
   - Fail closed before Stage 2 or aggregation if any specialist output is missing a first-line `COVERAGE_OK ...` or `FATAL_COVERAGE_ERROR ...` sentinel, or if the `COVERAGE_OK` sentinel does not match the expected specialist name, `$BASE_COMMIT...$HEAD_REF` scope, and packet SHA-256.
   - Fail closed before Stage 2 or aggregation if any specialist output reports a fatal coverage error, missing/inconsistent scope, inability to read the diff packet, packet hash mismatch, or otherwise says it was unable to verify the packet or reviewed scope.
   - **Partial aggregation is forbidden**: every required role must be usable and pass coverage validation. If a future workflow wants partial results, require an explicit opt-in plus a visible degraded-coverage banner.
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
   - If Stage 1 surfaced **no** Critical findings, record `expected_stage2 = {code-simplifier}`, then spawn `code-simplifier` with the same target description, `$BASE_REF`, `$BASE_COMMIT`, `$HEAD_REF`, changed-file list, `git status --short`, `git log --no-decorate "$BASE_COMMIT..$HEAD_REF"`, diff packet path, byte count, SHA-256, Scope contract, Coverage sentinel contract, review-only contract, and control-plane contract, plus a brief Stage 1 summary so it knows what's already flagged. Request advisory simplification findings only.
   - Use the selected adapter without switching families and keep Stage 2 at one active specialist. The V1 adapter uses the returned `agent_id`, targeted waits, and `close_agent`. The V2 adapter uses the same `run_token`, a stage-2/attempt task name, exact custom `agent_type`, `fork_turns="none"`, saved canonical identity, spawn-error reconciliation, matched `FINAL_ANSWER` payload, accepted lifecycle evidence, ordered tree reconciliation, and run-owned `interrupt_agent` cleanup from Steps 2–3.
   - Apply the same first-line `COVERAGE_OK ...` / `FATAL_COVERAGE_ERROR ...` sentinel validation, packet SHA-256 validation, and fatal coverage error handling to Stage 2 output before final aggregation.
   - Start one monotonic 10-minute Stage 2 deadline before its spawn. The V1 adapter uses the existing targeted-wait/close loop. The V2 adapter applies the same canonical-identity state machine, completed-or-qualified-retirement lifecycle evidence, ordered reconciliation, duplicate handling, 60-second delivery grace, and poll bound of `min(60000 ms, remaining stage budget, earliest active delivery-grace budget)`; none may extend the Stage 2 deadline.
   - If the scheduled specialist fails to spawn, errors, times out, returns empty output, or produces unusable output, perform the selected adapter's run-owned cleanup and fail closed before final aggregation. Partial aggregation is forbidden here too.
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
