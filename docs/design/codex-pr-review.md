# Codex PR Review Migration — Design Doc

Parent tracking: [Issue #206](https://github.com/toku345/dotfiles/issues/206)
Status: Draft (2026-05-17, rev.4 — addresses second Codex auto-review iteration: gh sandbox execution contract)

## Context

`dot_local/bin/executable_triple-review` (1144 lines bash) is the pre-PR review gate. It runs three reviewer legs (`PR` = `claude -p /pr-review-toolkit:review-pr`, `SEC` = `claude -p /security-review`, `ADV` = `node codex-companion.mjs adversarial-review`) in parallel and aggregates findings via a fourth `claude -p` call.

Two converging pressures motivate a rework:

1. **2026-06-15 Claude Code pricing change** — `claude -p` invocations begin consuming Max plan's separate $100/mo Agent SDK credit budget rather than counting against the subscription rate limits. The current script makes 4 `claude -p` calls per run. Source: [Use the Claude Agent SDK with your Claude plan](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) (Anthropic Help Center).
2. **Implementation fragility** — Issues #189 (per-leg timeout missing), #197 (PATH-stripped startup), #201 (3-factor hang: `claude_p_neutral` × `--wait` × production-scale diff), #204 (positive-validator gate), #205 (enrich FAILED marker) all stem from the bash + `claude -p` orchestration layer. Each fix adds complexity rather than removing root causes.

Additionally:

- The 3-leg structure (PR / SEC / ADV) is a **historical artifact**: it automated a prior manual workflow where the user ran 3 separate slash commands and copy-pasted results. There is no design rationale for "3" as the optimal count.
- Codex CLI 0.130.0 ships a **stable** `features.multi_agent` (subagent spawn). Local `codex features list` confirms `multi_agent stable true`. A successor `multi_agent_v2` appears as `under development false` in the same listing and may shift configuration semantics in future releases (tracked as a Low–Medium risk). The primitive did not exist when `triple-review` was first designed.

## Goals

- **Credit economy**: eliminate `claude -p` from the review path
- **Maintainability**: 1144 lines bash → Skill (target `~120–150` lines, accommodating explicit specialist applicability logic, scope-ref propagation, no-PR fail-closed gate, clean-worktree guard, and Stage-1/2 sequential gate; final size confirmed after Phase 3 primitive verification) + 8 `.toml` agents + 3 LICENSE + 1 NOTICE files
- **Quality**: preserve the 6 specialist perspectives from `pr-review-toolkit` + the security and adversarial perspectives currently in `SEC` / `ADV`
- **Architectural clarity**: move from "3 legs" (accident) to "specialist-first" (intentional)
- **License hygiene**: bundle prompts only from Apache-2.0 / MIT sources with attribution, bundled LICENSE files, and NOTICE preservation where required by Apache-2.0 §4(d)

## Non-goals

- Migration of the user's main coding agent (Claude → Codex / other) — separate timeline
- DGX Spark + OpenCode local-LLM fallback — separate Issue, separate timeline
- Activation of the `code-review` plugin from `anthropics/claude-plugins-official` (distinct from `pr-review-toolkit`) — out of scope
- Running `codex exec` (with this skill) from within an enclosing Claude Code session — nested-bwrap "Permission denied" infinite spawn-retry incident verified in `~/.codex/history.jsonl` (2026-03). Same constraint as the legacy `triple-review` per AGENTS.md `Git / PR 規約`.

## Alternatives considered

| # | Approach | Verdict | Reason |
|---|---|---|---|
| A | Incremental bash improvements | ❌ | Leaves credit-cost issue; treats symptoms, not root cause (`claude -p` dependency) |
| B | Full Go rewrite | ❌ | Language swap does not address "over-engineered" structure; same architecture in a different language |
| B′ | Codex-everywhere + bash orchestrator | ❌ | Still requires hand-coded 6-way fan-out in bash; ignores Codex's native subagent primitive |
| C | Hybrid (Claude for PR-leg, Codex for SEC + ADV) | ❌ | Agent SDK credit consumption persists for the heaviest leg |
| D | DGX Spark local LLM end-to-end | ❌ | Review quality unverified at frontier-model standard; unusable away from home network |
| E | Deprecate / opt-in downgrade + harden CI gates | ❌ | Sacrifices the "second pair of eyes" value for solo dotfiles work |
| F | `codex review` builtin subcommand (`codex review --base <branch>`) | ❌ | Single-perspective review only; no multi-specialist fan-out, no per-file-type conditional spawning, no orchestrated output format. Useful as a quick sanity-check or fallback but cannot replace the 8-specialist coverage that motivated the migration |
| **α** | **Pure Codex Skill + 8 specialist subagents** | **✅** | bash fully retired; credit-neutral; narrow context per specialist; standard OSS licensing |

## Trial-and-error log (corrections taken during deliberation)

The following corrections were applied during the brainstorming session that produced this design. They are recorded here (not in the eventual ADR) so future readers can trace why certain options were rejected.

1. **Initial misframing of `pr-review-toolkit` license**: First inferred from the umbrella `anthropics/claude-code` repo's "© Anthropic PBC. All rights reserved" + Commercial Terms. Corrected: the plugin lives in `anthropics/claude-plugins-official` with **per-plugin Apache-2.0 LICENSE files**. Bundling in the user's MIT-licensed chezmoi repo is permitted with standard Apache-2.0 attribution requirements.
2. **(β) consolidation rejected**: Briefly proposed "compress 5 specialist concerns into one PR-leg prompt" for file-count parsimony. Withdrawn — this violates the narrow-context-per-specialist principle that makes specialization work. Each specialist's attention budget should stay focused on one concern; consolidation dilutes findings.
3. **3-leg structure de-anchored**: Treated the existing PR/SEC/ADV split as a design target. User clarified this is a historical residue from automating 3 manual slash-command invocations. The actual design question is "which specialist set is optimal for the user's review needs", not "how do we preserve 3 legs".
4. **Codex subagent primitive initially missed**: First claimed "Codex CLI has no equivalent to Claude Code's Task tool fan-out, so we'd need external 6-way orchestration in bash". Corrected via ChatGPT cross-check, then **locally verified on `codex-cli 0.130.0`** with `codex features list`: `features.multi_agent` is **stable** (`multi_agent stable true`). An intermediate revision of this Design Doc mis-recorded it as `experimental` after a reviewer cited a stale `~/.codex/memories/` snapshot taken under `codex-cli 0.113.0` / `0.124.0` — when the feature genuinely was experimental. The 0.130.0 live `codex features list` reading supersedes those snapshots. `agents.max_threads = 6` closely tracks the typical parallel set (3 always + 1–4 conditional) — though worst-case 7 parallels exceed it by one (acceptable queueing). The fan-out lives inside a single `codex exec` invocation via TOML-defined custom agents.
5. **Thin shell wrapper retracted**: Proposed keeping a `~30` line wrapper for sleep inhibition (`caffeinate` / `systemd-inhibit`) and exit-code mapping. User pointed out that historical "long-running" reviews were stuck-not-running (3-factor hang under `claude_p_neutral`), not genuine multi-hour compute — so `caffeinate` is YAGNI. Gate behaviour is preserved via shell `&&` (`codex exec '...' && gh pr create`).
6. **Codex auto-review corrections (rev.3)**: A `codex exec` auto-review of this Design Doc (rev.2) surfaced 6 Critical findings, all valid and all addressed in rev.3:
   - (a) `codex exec /pr-review` slash-command-style invocation is not the correct skill-loading syntax. Skills are invoked via `$skill-name` mention or `/skills` selector per [Codex Skills docs](https://developers.openai.com/codex/skills). Exact `codex exec` non-interactive syntax deferred to Phase 3 PoC.
   - (b) Subagent spawning is **orchestrator-driven, not description-driven**. The `description` field is "human-facing guidance"; subagents spawn only when the parent explicitly requests them. The orchestrator must compute applicability itself (more logic than initially budgeted — pushes SKILL.md size to ~120–150 lines).
   - (c) The original draft lost #186's fail-closed-on-no-PR default by making `origin/HEAD` fallback unconditional. Corrected: skill aborts when no PR exists; `--allow-no-pr` / `ALLOW_NO_PR=1` opt-in for `origin/HEAD` fallback continues the bash semantics.
   - (d) Clean-worktree invariant from [ADR 0020](../adr/0020-triple-review-handoff-and-clean-worktree.md) was dropped. Corrected: skill includes `git status --porcelain --untracked-files=normal` precondition.
   - (e) Apache-2.0 §4(d) requires NOTICE preservation. `openai/codex-plugin-cc` ships a `NOTICE` file (verified via gh API: 547 bytes, `Copyright 2026 OpenAI`); the original draft only bundled LICENSE. Corrected: `NOTICE-codex-plugin-cc` added to the bundle. `pr-review-toolkit` and `claude-code-security-review` ship no NOTICE (verified) — only LICENSE bundling applies.
   - (f) Skill path uncertainty: docs cite `$HOME/.agents/skills` as the user-skill location, but local install shows empty `~/.codex/skills/` alongside `~/.codex/plugins/cache/.../skills/<name>/`. Canonical path verified in Phase 3 PoC; chezmoi source path adjusted accordingly.
7. **Codex auto-review iteration #2 (rev.4)**: A `codex exec resume --last` re-review of rev.3 surfaced one remaining Critical: prior Finding #5 was only partially resolved. rev.3 added a `gh auth status` preflight (addressing auth) but did not address the broader question of whether `gh` is *executable at all* under `codex exec`'s sandbox. Codex docs note subagents inherit the parent sandbox and non-interactive flows cannot surface fresh approvals; this repo's AGENTS.md L188 documents that `gh` requires `dangerouslyDisableSandbox: true` under Claude Code's macOS Seatbelt (TLS via `trustd` Mach service blocked). Codex's sandbox semantics differ but may impose analogous restrictions. Corrected in rev.4: explicit sandbox-execution contract in Invocation, Phase 3 PoC verifies `gh` runnability under each `--sandbox` mode per OS, Phase 4 verifies the skill's preflight detects sandbox-blocked `gh`, new Risk row covers the residual.

## Selected approach: (α) Pure Codex Skill

### Layout

```
~/.codex/skills/pr-review/SKILL.md         # orchestrator (~120–150 lines, user-authored, MIT)
                                            # NOTE: docs cite `$HOME/.agents/skills` as the canonical
                                            # user-skill path; local install shows empty
                                            # `~/.codex/skills/` alongside
                                            # `~/.codex/plugins/cache/.../skills/<name>/SKILL.md`.
                                            # Path verified in Phase 3 PoC.
~/.codex/agents/
├── code-reviewer.toml                     # Apache-2.0 (Anthropic)
├── code-simplifier.toml                   # Apache-2.0 (Anthropic)
├── comment-analyzer.toml                  # Apache-2.0 (Anthropic)
├── pr-test-analyzer.toml                  # Apache-2.0 (Anthropic)
├── silent-failure-hunter.toml             # Apache-2.0 (Anthropic)
├── type-design-analyzer.toml              # Apache-2.0 (Anthropic)
├── security-reviewer.toml                 # MIT (Anthropic)
├── adversarial-reviewer.toml              # Apache-2.0 (OpenAI)
├── LICENSE-claude-plugins-official        # Apache-2.0 full text
├── LICENSE-claude-code-security-review    # MIT full text
├── LICENSE-codex-plugin-cc                # Apache-2.0 full text
└── NOTICE-codex-plugin-cc                 # Apache-2.0 §4(d) — codex-plugin-cc ships NOTICE; the other two sources do not
```

Source tree (chezmoi): `private_dot_codex/skills/pr-review/` and `private_dot_codex/agents/` (assuming `~/.codex/skills/` is the canonical user-skill path; if Phase 3 PoC confirms `~/.agents/skills/` instead, the source tree shifts accordingly).

### Invocation

```bash
# Skill invocation (exact syntax confirmed in Phase 3 PoC):
codex exec '$pr-review review the current branch against its base ref' && gh pr create ...
```

The non-interactive skill-invocation syntax for `codex exec` is not explicitly documented. Per [Codex Skills docs](https://developers.openai.com/codex/skills), interactive mode uses `$skill-name` mention or `/skills` selector. Phase 3 PoC determines whether `$pr-review` mention works inside `codex exec` argv, requires stdin redirect, or needs a different invocation. The original `codex exec /pr-review` draft (slash-command-style) is **not correct** — slash commands are an interactive-only surface.

**Preconditions** (skill aborts with actionable error message if any fails):

1. **`gh` authenticated** — `codex exec` is non-interactive and cannot surface auth prompts. The skill calls `gh pr view`, which silently fails if auth is stale. Skill probes `gh auth status` first and aborts with a recovery hint if not authenticated.
2. **Terminal direct execution** — invocation from within an enclosing Claude Code session triggers a nested-bwrap "Permission denied" infinite spawn-retry (verified in `~/.codex/history.jsonl`, 2026-03). Same constraint as legacy `triple-review` per AGENTS.md `Git / PR 規約`. Detection heuristic (e.g. checking for Claude Code environment marker) TBD in Phase 4; at minimum the constraint is documented in `SKILL.md` description.
3. **Clean worktree** — uncommitted tracked-modified or untracked-non-ignored changes would be silently excluded from the reviewed diff (silent false-green). Skill aborts via `git status --porcelain --untracked-files=normal` check at startup. Continues the ADR 0020 invariant.
4. **PR exists for the current branch** (default) — for the same scope-divergence reasons as Issue #186, the skill aborts when `gh pr view` reports no PR. Opt-in to `origin/HEAD` fallback via skill argument `--allow-no-pr` or env `ALLOW_NO_PR=1` (residual scope-divergence risk acknowledged, matching the bash semantics).

**Sandbox execution contract**:

The skill calls `gh pr view` to resolve the base ref. `codex exec --sandbox` controls what shell commands the model can execute. The required sandbox depends on whether `gh` is callable under the chosen policy (verified per OS in Phase 3 PoC):

- **If `gh` runs under `--sandbox read-only`**: invoke as `codex exec --sandbox read-only '$pr-review ...'` (defense-in-depth; no filesystem writes needed for a review)
- **If `gh` is blocked under read-only**: invoke as `codex exec --sandbox workspace-write '$pr-review ...'` (broader permissions; required for `gh` execution)
- **Escape hatch**: if `gh` is blocked even under workspace-write or otherwise unavailable, the skill accepts an explicit `--base <branch>` argument that bypasses `gh pr view` entirely (caller takes responsibility for choosing the correct base; loses #186's auto-detect benefit for non-default-base PRs)

Background: AGENTS.md L188 documents that `gh` requires `dangerouslyDisableSandbox: true` under Claude Code's macOS Seatbelt (Mach service `trustd` for TLS blocked). Codex's sandbox semantics differ — but Codex docs note subagents inherit the parent sandbox, so a `gh`-blocking policy at the parent propagates. Phase 3 PoC determines the minimum sufficient mode empirically per OS; the skill's preflight then refuses to run under an inadequate sandbox with an actionable recovery hint pointing to the correct `--sandbox` flag.

**Cross-repo portability**:

The same skill runs across dotfiles / work / Zig / Python / Ruby. Repo-specific behaviour comes through per-repo `AGENTS.md` / `CLAUDE.md` and the skill's specialist applicability logic.

**Gate behaviour**:

- Failure stops PR creation: `codex exec '...' && gh pr create`
- Advisory (don't gate): `codex exec '...' || true && gh pr create`

**Scope alignment** (continuation of Issue #186 fix direction):

The orchestrator skill resolves a **single base ref** via `gh pr view --json baseRefName` (with fail-closed-by-default semantics per Precondition 4) and **passes that resolved ref to every spawned specialist as context**. No specialist re-detects scope independently — eliminating the partial-coverage class of bugs by construction.

**Sequential dependency for `code-simplifier`**:

The orchestrator implements a 2-stage flow: spawn the Stage-1 set in parallel, await completion of all, evaluate Stage-1 findings, then conditionally spawn `code-simplifier` only if Stage-1 surfaces no Critical findings. The exact Codex primitive for the await step (`wait_agent` is plausible but **unverified locally**; alternatives include `spawn_agent` return-value await, completion polling, or a barrier construct) is **determined in Phase 3 PoC** rather than fixed in this design. This sequential gate, combined with explicit applicability logic (see below) and precondition enforcement, is why SKILL.md is sized at ~120–150 lines rather than the initial ~50-line estimate.

### Conditional specialist spawning

The orchestrator skill **computes specialist applicability itself** and explicitly spawns named agents — mirroring `pr-review-toolkit/commands/review-pr.md` §4 "Determine Applicable Reviews". Codex's custom-agent `description` field is "human-facing guidance for when to use" (per docs), **not an execution rule**. Subagents spawn only when the parent explicitly requests them by name; there is no auto-dispatch from `description` matching to file-change types.

Applicability logic in the orchestrator (pseudocode):

```
changed_files = git diff --name-only $BASE...HEAD
spawn(code-reviewer)         # always
spawn(security-reviewer)     # always
spawn(adversarial-reviewer)  # always
if changed_files matches test paths:        spawn(pr-test-analyzer)
if changed_files matches docs/comments:     spawn(comment-analyzer)
if changed_files matches error-handling:    spawn(silent-failure-hunter)
if changed_files matches type definitions:  spawn(type-design-analyzer)
await all  # Stage 1 barrier (primitive TBD in Phase 3)
if no Critical findings: spawn(code-simplifier)  # Stage 2
```

| Specialist | Trigger |
|---|---|
| `code-reviewer` | Always |
| `security-reviewer` | Always |
| `adversarial-reviewer` | Always |
| `pr-test-analyzer` | Changed files include test paths |
| `comment-analyzer` | Changed files include docs / comment changes |
| `silent-failure-hunter` | Changed files include error-handling |
| `type-design-analyzer` | Changed files introduce or modify types |
| `code-simplifier` | Stage 2: only when Stage 1 has no Critical findings |

**On parallelism limits**: the always-spawned group (3) plus all four conditional specialists is 7 parallel — one above Codex's default `agents.max_threads = 6`. In the worst-case all-trigger run, one specialist queues briefly. No functional impact.

### License compliance

| Specialist origin | License | NOTICE? | Attribution requirement |
|---|---|---|---|
| `pr-review-toolkit` (6 specialists) | Apache-2.0 | No (verified: no NOTICE file in source) | Header in each `.toml` (source URL + **commit hash at transcription time** + copyright + license + modification note); `LICENSE-claude-plugins-official` bundled |
| `claude-code-security-review` (security-reviewer) | MIT | No (verified) | Header (copyright + license + source commit hash); `LICENSE-claude-code-security-review` bundled |
| `codex-plugin-cc` (adversarial-reviewer) | Apache-2.0 | **Yes** (`NOTICE`, 547 bytes, `Copyright 2026 OpenAI`) | Header + `LICENSE-codex-plugin-cc` bundled + `NOTICE-codex-plugin-cc` bundled (Apache-2.0 §4(d)) |
| User's chezmoi (orchestrator SKILL.md) | MIT (umbrella repo license) | n/a | n/a (own work) |

Apache-2.0 + MIT downstream is well-established and compatible. Per-source LICENSE files are bundled at transcription time with the source repo's commit hash recorded — see Phase 3 Done 判定基準 for verification steps. **Apache-2.0 §4(d) NOTICE preservation requirement** applies only to `codex-plugin-cc` (the other two Apache-2.0/MIT sources do not ship a NOTICE file).

## Issue triage

| Issue | State | Title (略) | Migration impact | Action on Skill release |
|---|---|---|---|---|
| #186 | CLOSED | scope divergence + partial-failure false-green | Partial-failure concept removed by 1-leg architecture. **#186's fail-closed-on-no-PR default carries forward into Precondition 4** (corrected in rev.3 after Codex auto-review caught a regression draft) | none (already closed); design honours the fix going forward |
| #189 | OPEN | per-leg timeout missing | Disappears: `claude -p` retired; Codex subagents inherit `agents.job_max_runtime_seconds` (default 1800s) | Close with reference to migration PR |
| #197 | OPEN | PATH-stripped startup failures | Disappears: bash entrypoint retired entirely | Close with reference to migration PR |
| #201 | OPEN | wrapper × `--wait` × scale hang | Disappears: `claude_p_neutral` and `codex-companion` both retired; the 3-factor AND condition cannot be reconstructed | Close with reference to migration PR |
| #204 | OPEN | positive-validator gate | Disappears: no `claude -p` stdout to validate; subagent failure semantics native to Codex | Close with reference to migration PR |
| #205 | OPEN | enrich `<FAILED>` marker | Disappears: `<FAILED>` marker concept retired; subagent results carry structured success/failure natively | Close with reference to migration PR |
| #206 | OPEN | triple-review v2 with Agent View | Agent View rejected as substrate (preserves 3 of 6 ADR 0012 blockers); **Codex Skill chosen instead**. Issue body to be rewritten as the parent tracking Issue for this design | Update body to point to this design doc + ADR 0023 |

**Net effect**: 5 OPEN issues become close-by-migration. 1 OPEN issue (#206) survives as the umbrella tracker. The #186 fail-closed default is carried forward as a first-class precondition.

## Implementation plan (phases)

Task IDs below use `T<n>` to avoid collision with GitHub Issue numbering (e.g., `T4` is internal tracker task #4, not GitHub Issue #4).

| Phase | Task ID | Goal |
|---|---|---|
| 1. Decision recording | T4 (this doc), T5 (Codex auto-review) | Crystallize the migration plan and validate it via Codex |
| 2. chezmoi scaffold | T6 | Create source-tree structure for Skill + agents |
| 3. PoC + transcription | T7 | Verify Codex subagent fan-out + skill discovery; transcribe all 8 specialists |
| 4. Orchestrator | T8 | Write SKILL.md with preconditions, applicability logic, Stage-1/2 gating |
| 5. End-to-end test | T9 | Compare new vs legacy review quality on 3 historical PRs |
| 6. Deprecation | T10 | Retire the 1144-line bash and bats test suite |
| 7. ADR 0023 | T11 | Record decisions only (status: Accepted) |

### Done 判定基準 (per Phase)

CLAUDE.md「プラン作成時の Quality Gates」準拠。各 Phase の必須ゲート (動作検証 / 既存機能 / 差分確認 / シークレット未混入) は常に適用。

**Phase 1 (T4, T5)**:
- [x] Design Doc written, structured per AGENTS.md `docs/design/` convention (T4)
- [x] All 7 listed Issues triaged with explicit close-vs-keep determination (T4)
- [x] Codex auto-review of this Design Doc + plan executed; findings catalogued and addressed in rev.3 (T5)
- [x] Trial-and-error log captures all corrections taken during the brainstorming session (T4)

**Phase 2 (T6)**:
- [ ] `private_dot_codex/skills/pr-review/` exists with placeholder `SKILL.md` (chezmoi source path adjusted if Phase 3 PoC determines `~/.agents/skills/` is canonical instead of `~/.codex/skills/`)
- [ ] `private_dot_codex/agents/` exists with 3 LICENSE + 1 NOTICE files (`LICENSE-claude-plugins-official`, `LICENSE-claude-code-security-review`, `LICENSE-codex-plugin-cc`, `NOTICE-codex-plugin-cc`)
- [ ] `chezmoi diff` shows the intended deployment paths under `~/.codex/` (or `~/.agents/` per Phase 3 determination)
- [ ] No secrets in the source tree

**Phase 3 (T7)**:
- [ ] **Codex skill discovery path verified**: place a trivial test `SKILL.md` in `~/.codex/skills/test/` and `~/.agents/skills/test/` (whichever exist / can be created) to determine which `codex exec` actually loads from. Phase 2 chezmoi source path adjusted accordingly
- [ ] **Codex skill invocation syntax verified**: confirm whether `codex exec '$pr-review ...'` (argv `$` mention), stdin redirect, slash command, or another syntax actually triggers skill loading non-interactively
- [ ] **`gh` sandbox runnability verified per OS**: test `gh pr view --json baseRefName` under each `codex exec --sandbox` mode (`read-only`, `workspace-write`) on the OS(es) the user runs the skill on (macOS, Linux). Document the minimum sufficient mode in Invocation > Sandbox execution contract. Cross-reference Claude Code's gh-Seatbelt incident (AGENTS.md L188) for the macOS-specific risk
- [ ] **Codex orchestration primitive verified**: minimum reproducer demonstrates "Stage-1 parallel spawn → all-complete await → Stage-2 conditional spawn" flow. Exact await primitive name (`wait_agent` / `spawn_agent` return await / polling / barrier) recorded for SKILL.md authorship in T8. If no native await primitive exists, fallback approach decided here
- [ ] `adversarial-reviewer.toml` transcribed (PoC) + standalone `codex exec` run produces structured adversarial findings
- [ ] Remaining 7 specialists transcribed
- [ ] **NOTICE bundle**: `NOTICE-codex-plugin-cc` content matches upstream verbatim; `adversarial-reviewer.toml` header references the NOTICE file alongside LICENSE
- [ ] Each `.toml` header includes: source URL, **source repo commit hash at transcription time**, copyright, license, modification note
- [ ] `grep -E 'Apache-2\.0|MIT' agents/*.toml` returns all 8 files (presence check)
- [ ] Per-source 1-time SPDX verification recorded in this Design Doc or PR description (not just inferred — each source repo's LICENSE file content sampled to confirm SPDX)

**Phase 4 (T8)**:
- [ ] `SKILL.md` includes: description, **Preconditions section** (gh auth, terminal direct, clean worktree, PR existence with `ALLOW_NO_PR` opt-in), procedure (Stage 1 parallel spawn + await primitive determined in Phase 3 + Stage 2 conditional `code-simplifier`), **explicit applicability logic** (computes from `git diff --name-only`, not reliance on description auto-dispatch), available specialists, scope alignment via `gh pr view --json baseRefName`, output format
- [ ] **No-PR fail-closed verified**: smoke test on a branch without a PR aborts with actionable error message; same branch with `ALLOW_NO_PR=1` proceeds with `origin/HEAD` fallback and a visible degraded-coverage warning in the output
- [ ] **Clean-worktree guard verified**: smoke test with a deliberately dirty worktree (uncommitted tracked-modified or untracked-non-ignored file) aborts with actionable error
- [ ] **gh-auth precondition verified**: smoke test on a system with stale `gh` auth aborts early with a recovery hint, not a silent silent-fail downstream
- [ ] **Sandbox-blocked-`gh` precondition verified**: smoke test invoking the skill under an inadequate `--sandbox` mode (whichever Phase 3 determined insufficient) aborts early with a recovery hint specifying the correct `--sandbox` flag (and mentions the `--base <branch>` escape hatch), rather than failing mid-flow on the gh shell-out
- [ ] `codex exec` on a tiny test PR completes end-to-end (smoke test)

**Phase 5 (T9)**:
- [ ] 3 historical PRs reviewed by both old `triple-review` and new Codex skill
- [ ] Findings catalogued: Critical retained, Important retained, false-positive delta, runtime delta
- [ ] **Same-model adversarial delta**: legacy ADV (Codex via Claude bridge) vs new ADV (Codex via Codex skill) — finding diversity quantified, since same-model cross-checking may weaken the original adversarial intent (see Risks table)
- [ ] If quality regresses materially, mitigation logged before proceeding (options: per-specialist `model` override, or retain one Claude leg, or accept-and-document)

**Phase 6 (T10)**:
- [ ] `AGENTS.md` Triple-Review CLI section rewritten or removed
- [ ] ADR 0012 (triple-review-bash-script) marked superseded (pointer to ADR 0023)
- [ ] ADR 0020 (clean-worktree invariant) reaffirmed as continuing constraint in the new design (cross-reference added to ADR 0023)
- [ ] **Deprecation window decision**: immediate removal (no shim). Rationale: dotfiles is a solo personal toolset and the new invocation is `codex exec '$pr-review ...'` — distinct enough from `triple-review` that no muscle-memory aliasing is needed. If a transition shim is desired, a 1-line `alias triple-review='codex exec ...'` can be added to `fish` config, then removed
- [ ] `dot_local/bin/executable_triple-review` removed
- [ ] `tests/bats/test_triple_review.bats` removed (review test value transfers to E2E procedure in Phase 5, not bash unit tests)

**Phase 7 (T11)**:
- [ ] `docs/adr/0023-codex-pr-review-skill-migration.md` created, status: Accepted
- [ ] Content: Context, Decision, Consequences only — points to this Design Doc for trial-and-error context
- [ ] No `Status: Proposed` interim state per memory `feedback_adr_decisions_only.md`

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Codex-routed specialist quality < Claude-routed equivalent | Medium | E2E test (Phase 5) on 3 historical PRs catalogues deltas. If material gaps appear, fix by per-specialist `model` field or by language-specific specialists |
| **Same-model adversarial review weakened** — `adversarial-reviewer.toml` was originally meant to bring Codex's "outside perspective" into Claude Code's flow. Running Codex inside Codex may dilute the cross-model property | **Medium** | Phase 5 explicitly catalogues legacy-ADV-vs-new-ADV finding diversity. If degradation is material, options: (a) keep a single Claude leg for ADV only (partial Hybrid), (b) pin a distinct Codex model for `adversarial-reviewer.toml` via `model` field, (c) accept and document the trade-off |
| `features.multi_agent` is stable on `codex-cli 0.130.0` but `multi_agent_v2` is `under development` — `agents.*` configuration semantics or the spawn-await primitive name may shift on v2 migration | Low–Medium | Verified `multi_agent stable true` via `codex features list` on `codex-cli 0.130.0`. ADR records the verified version. When `multi_agent_v2` materialises, re-verify `agents.max_threads` / `agents.job_max_runtime_seconds` / the await primitive determined in Phase 3 against the v2 schema before upgrading. Conversion stays mechanical so re-transcription from upstream is straightforward if breakage occurs |
| **Codex skill discovery / invocation syntax not yet documented for `codex exec`** — non-interactive skill loading may require a syntax (argv `$` mention, stdin redirect, or other) we have not yet verified | Low | Phase 3 PoC explicitly enumerates discovery (`~/.codex/skills/` vs `~/.agents/skills/`) and invocation (`$` mention vs alternative) before committing to a fixed pattern. The orchestrator skill is the same regardless — only its loading path differs |
| **`gh` execution blocked under Codex sandbox** — `codex exec --sandbox read-only` (or default) may restrict `gh`'s TLS path (analogous to Claude Code's macOS Seatbelt restriction in AGENTS.md L188; Codex subagents inherit the parent sandbox per docs). Skill cannot then resolve PR base ref | Medium | Phase 3 PoC verifies `gh` runnability under each sandbox mode per OS. Invocation documents both possibilities (read-only or workspace-write). Skill preflight detects sandbox-blocked `gh` and aborts with recovery hint specifying the correct `--sandbox` flag. Third escape hatch: user passes explicit `--base <branch>` skill argument, bypassing `gh` entirely |
| License attribution gap (header missing in some `.toml`; NOTICE preservation overlooked) | Low | Phase 3 acceptance: per-file header presence + per-source SPDX 1-time verification + bundled LICENSE files + bundled NOTICE for `codex-plugin-cc`. Source repo commit hash recorded for auditability |
| 30-min+ reviews emerge → sleep timer fires mid-review | Low | Empirical: previous "long" runs were stuck, not running. If real long-compute emerges, add a thin `caffeinate` wrapper at that point (YAGNI now) |
| Codex exit-code semantics inadequate for the gate use case | Low | Default behaviour: any subagent failure surfaces via `codex exec` non-zero. If a richer signal is needed, wrapper script can translate |
| Specialist prompts contain JS-specific examples (e.g., "ES modules", "Sentry errorId") that confuse non-JS repos | Low | Codex translates contextually using repo's `CLAUDE.md`. If consistent confusion appears, rewrite the offending `developer_instructions` to be language-neutral |
| **Orchestrator skill bug → false-green or false-red** — SKILL.md now contains Preconditions enforcement, Stage-1/2 gating, scope ref propagation (`gh pr view --json baseRefName`), and explicit conditional specialist spawning. Logic errors could mask findings or fail PRs spuriously | Low–Medium | Phase 5 E2E test includes **at least one PR with known seeded findings** (positive control) to verify the orchestrator does not drop or mis-classify them. Additionally, Phase 4 smoke tests (no-PR / dirty-worktree / stale-gh-auth) catch precondition logic errors early; Phase 4 end-to-end smoke catches catastrophic orchestration errors |

## References

- [Issue #206](https://github.com/toku345/dotfiles/issues/206) — parent tracking Issue
- [ADR 0012 (triple-review-bash-script)](../adr/0012-triple-review-bash-script.md) — current `triple-review` design (to be marked superseded by ADR 0023)
- [ADR 0017 (triple-review-headless-output-style)](../adr/0017-triple-review-headless-output-style.md) — output-style persona suppression (background for `claude_p_neutral`)
- [ADR 0020 (triple-review-handoff-and-clean-worktree)](../adr/0020-triple-review-handoff-and-clean-worktree.md) — clean-worktree invariant carried forward into the new skill
- [ADR 0021 (triple-review-adv-revert-investigation)](../adr/0021-triple-review-adv-revert-investigation.md) — Issue #193 ADV revert investigation (background for the 3-factor hang)
- [ADR 0022 (brainstorming-progressive-disclosure)](../adr/0022-brainstorming-progressive-disclosure.md) — similar minimalism pattern (skill body length discipline)
- [Codex Subagents documentation](https://developers.openai.com/codex/subagents)
- [Codex Skills documentation](https://developers.openai.com/codex/skills)
- [Anthropic Help Center — Use the Claude Agent SDK with your Claude plan](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) — source for 2026-06-15 pricing change
- [anthropics/claude-plugins-official](https://github.com/anthropics/claude-plugins-official) — `pr-review-toolkit` source (Apache-2.0)
- [anthropics/claude-code-security-review](https://github.com/anthropics/claude-code-security-review) — `security-review` source (MIT)
- [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc) — `adversarial-review` source (Apache-2.0; `NOTICE` file requires §4(d) preservation in derivatives)
お
