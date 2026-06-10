# Claude-side PR Review — Design Doc

Parent decision: [ADR 0029](../adr/0029-claude-pr-review-dynamic-workflow.md)
Status: Accepted (2026-06-11; implemented and live-validated on PR #258 — see "Operational notes")

## Context

See ADR 0029 for the decision and its rationale. In short: company environments restrict Codex, so the thick-change PR review gate must run inside Claude Code. This document covers *how* to build it as a Claude Code skill backed by a dynamic workflow. The Codex-side design (`codex-pr-review.md`) remains authoritative where Codex is available; this is its environment-split sibling, not its replacement.

## Goals

- Reach 8-specialist parity with the Codex `$pr-review` skill, runnable entirely inside a Claude Code session.
- Keep the gate policy (`review-criteria.md`) as one shared source of truth across both skills.
- Stay fail-closed: never silently aggregate partial coverage.
- Bound token cost with an explicit severity gate on the verify stage (the PoC measured 671k tokens for un-pruned verify over a six-specialist subset; parity would be higher).

## Architecture: sandbox-boundary split

The gate spans the sandbox boundary because a capability PoC proved that workflow subagents cannot run `gh` (sandbox-pinned; `~/.config/gh/hosts.yml: operation not permitted`) while `git` runs cleanly. Base resolution that needs `gh` therefore stays in the main session; the workflow uses only `git`.

```
[main Claude session]   gh available; can obtain dangerouslyDisableSandbox
  preconditions ─ clean worktree; base resolution (gh pr view | explicit --base); record HEAD_REF
  diff packet   ─ git diff baseCommit...headRef > $tmp ; packetSha = sha256($tmp)
  Workflow({ args: { base, baseCommit, headRef, packetPath, packetSha } })
        │
        ▼
[dynamic workflow]   git only — gh is sandbox-blocked here
  Stage 1   parallel() fan-out of applicable specialists (true barrier)
  coverage  each specialist echoes packetSha + scope → JS compares to args.packetSha → throw on mismatch (fail-closed)
  normalize severity (review-criteria + escalation logic) → hasCritical?
  Stage 2   code-simplifier ONLY if no Critical
  verify    Critical/Important findings ONLY → adversarial verify subagent (token gate)
  aggregate → structured result
        │
        ▼
[main Claude session]   render structured result → markdown report (Critical / Important≤5 / Suggestions≤3 / Strengths)
```

## Layout (chezmoi source)

```
private_dot_claude/
├── skills/pr-review/
│   ├── SKILL.md                    # main-session wrapper: preconditions, base resolution, Workflow launch, render
│   └── references/
│       ├── review-criteria.md.tmpl   # {{ include }} of the Codex-bundle canonical + generated-from sentinel header
│       └── severity-rules.json.tmpl  # {{ include }} of the Codex-bundle canonical
├── workflows/pr-review.js          # the dynamic workflow (deployed to ~/.claude/workflows/)
└── agents/
    ├── security-reviewer.md        # ported from Codex security-reviewer.toml (MIT)
    └── adversarial-reviewer.md     # ported from Codex adversarial-reviewer.toml (Apache-2.0 + NOTICE)
```

The six `pr-review-toolkit` specialists (`code-reviewer`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`, `pr-test-analyzer`, `code-simplifier`) are reused via `agentType` and are NOT copied.

## Workflow structure (pr-review.js)

Pre-implementation sketch, kept for the shape of the design — the committed `private_dot_claude/workflows/pr-review.js` is authoritative and has since grown beyond it (required `changedFiles`/`criteria`/`severityRules` args, per-specialist confidence scales, verifier coverage echo, overflow returns).

```
meta { phases: [Stage1, Stage2, Verify] }

// args from the main session — never re-resolved inside the workflow
const { base, baseCommit, headRef, packetPath, packetSha } = args

// conditional spawn from diff categorization (git diff --name-only baseCommit...headRef)
const applicable = categorize(changedFiles, fullDiff)   // always: code/security/adversarial
                                                        // +pr-test/comment/silent-failure/type-design per rules

// Stage 1 — true barrier
const stage1 = await parallel(applicable.map(spec => () =>
  agent(specPrompt(spec, {baseCommit, headRef, packetPath, packetSha}),
        { agentType: spec.agentType, phase: 'Stage1', schema: SPECIALIST_SCHEMA })))

// fail-closed: every specialist must echo matching scope + packetSha
for (const r of stage1) {
  if (!r || r.coverage?.packetSha !== packetSha || r.coverage?.scope !== `${baseCommit}...${headRef}`)
    throw new Error(`coverage gate failed: ${r?.coverage?.specialist ?? 'missing specialist'}`)
}

// normalize severity (review-criteria + escalation logic), then conditional Stage 2
const findings = normalize(stage1)                       // Critical / Important / Suggestion
const hasCritical = findings.some(f => f.severity === 'critical')
const stage2 = hasCritical ? null
  : await agent(simplifierPrompt(...), { agentType: 'pr-review-toolkit:code-simplifier', phase: 'Stage2', schema: SPECIALIST_SCHEMA })

// token gate: verify ONLY Critical/Important (never all findings — that is the 671k trap)
const toVerify = findings.filter(f => f.severity === 'critical' || f.severity === 'important')
const verified = await parallel(toVerify.map(f => () =>
  agent(verifyPrompt(f, {packetPath}), { phase: 'Verify', schema: VERDICT_SCHEMA })
    .then(v => ({ ...f, verdict: v }))))

return aggregate(verified, findings, stage2)             // caps: Important≤5, Suggestions≤3
```

`SPECIALIST_SCHEMA` carries `{ coverage: { specialist, scope, packetSha }, findings: [{ severity, confidence, file, line, why, fix }] }`. The first-line coverage sentinel from the Codex skill collapses into the `coverage` object; the hash match is bespoke JS (the PoC confirmed schema validates shape, JS does the comparison).

## Specialist port (.toml → .md)

For `security-reviewer` and `adversarial-reviewer`:

- Convert the Codex TOML prompt body to a Claude subagent `.md` with YAML frontmatter (`name`, `description`, `model`, `tools`).
- Map the Codex read-only / no-exploit-reproduction tool gating to the Claude `tools` frontmatter (review-only: no Write/Edit).
- Preserve the attribution header (source URL, upstream commit hash, copyright, license, modification note) and bundle LICENSE; bundle NOTICE for `adversarial-reviewer` only (Apache-2.0 §4(d); codex-plugin-cc ships NOTICE, the MIT source does not).
- Decide the `model` field deliberately: the reused toolkit `code-reviewer` / `code-simplifier` are `model: opus`-pinned, the other four are `inherit`. Align the two ported agents with that policy (proposed: `inherit`, overridable later).

## Gate policy & severity contract

`review-criteria.md` (26 lines, Codex-decoupled) is the shared gate policy, and `severity-rules.json` (sentinel `PR_REVIEW_SEVERITY_RULES_V1`) is the machine-readable severity-escalation table extracted from the Codex `SKILL.md` step 4 (confidence thresholds, per-specialist label mapping, output caps). Both are canonical in the Codex bundle (`private_dot_codex/skills/pr-review/references/`); the Codex `SKILL.md` now points at the table instead of carrying inline escalation prose.

**Share mechanism (Phase 2 decision): chezmoi template include.** The Claude-side copies under `private_dot_claude/skills/pr-review/references/` are one-line `.tmpl` files (`{{ include "private_dot_codex/..." }}`), so every `chezmoi apply` regenerates them from the canonical files and drift is structurally impossible. Rejected alternatives: a symlink dangles if `~/.codex` is ever machine-gated in `.chezmoiignore`; copy-with-sentinel needs a separate CI equality check to stay honest. Trade-off: this deviates from the repo's Go Template Usage Policy (`.tmpl` avoidance), accepted because a one-line include wrapper for md/json has none of the ShellCheck/syntax-highlighting costs that motivated the policy, and `private_dot_ssh/config.tmpl` is existing precedent. The Claude `SKILL.md` (Phase 4) reads `severity-rules.json` in the main session and passes the parsed rules into the workflow via `args` — workflow scripts have no filesystem access, so the table must cross the boundary as data.

## Implementation plan (phases)

| Phase | Goal |
|---|---|
| 1 | Port `security-reviewer.md` / `adversarial-reviewer.md` into `private_dot_claude/agents/` with license/NOTICE headers |
| 2 | Share `review-criteria.md` + severity table to a Claude-readable path (resolve the deploy mechanism) |
| 3 | Write `pr-review.js`: args intake, conditional spawn, Stage1 barrier, coverage fail-closed, severity normalize, Stage2 gate, token-gated verify, aggregate |
| 4 | Write `SKILL.md` wrapper: preconditions, base resolution (gh/explicit), diff packet, Workflow launch, markdown render |
| 5 | Measure pruned token cost on one representative thick diff; confirm it stays bounded |
| 6 | Smoke test end-to-end on a small PR, including one seeded-finding positive control |
| 7 | Commit ADR 0029 (Accepted); add forward-reference from `codex-pr-review.md`; mark this design Accepted |

## Open questions

- **Per-specialist timeout (ADR 0029 R2 / issue #189):** the workflow runtime exposes no per-subagent wall-clock cap, and a JS deadline is not implementable either (workflow scripts have no `Date.now`/timers). This materialized live on 2026-06-10: an opus-pinned code-reviewer leg went silent for 49 minutes and the Stage 1 `parallel()` barrier waited indefinitely. Operational workaround until the runtime grows a timeout: watch the run's `journal.jsonl` for stalled progress, then `TaskStop` + relaunch with `resumeFromRunId` — completed agents return from the journal cache instantly, so recovery costs only the stuck leg. This remains the gate's weakest operational property.
- ~~**`review-criteria.md` share mechanism**~~ — resolved in Phase 2: chezmoi template include (see "Gate policy & severity contract").
- ~~**Pruned token cost**~~ — measured in Phase 5 (2026-06-10, live run on this branch's own 18-file / 113 KB diff): **20 agents (1 categorizer + 7 Stage 1 + 12 verify), ~1.23M subagent tokens, ~25 min**. The token gate works as designed (9 Suggestions were excluded from verify), but the cost scales with the number of Critical/Important findings (12 here), not just diff size — the un-pruned 671k figure was a six-specialist subset with full verify on a smaller finding set, so it is not a ceiling for finding-heavy thick diffs. Treat ~0.5-1.5M tokens as the realistic budget for a thick change; the gate stays reserved for thick changes per `review-criteria.md` Review Modes.
- **agentType model pins:** the two opus-pinned reused agents set a cost floor; decide whether the ported agents inherit or pin.

## Operational notes (from the 2026-06-10 live runs)

Phase 5/6 ran the gate twice on this feature's own branch (smoke + post-fix re-review). The smoke run surfaced 2 verified Critical findings against the gate's own implementation (confidence-scale mis-normalization, uncommitted test harness) — a stronger positive control than a seeded finding — and the re-review returned 0 Critical after the fixes. Durable observations:

- **Premature task notifications:** the harness can emit a `completed` task-notification while the workflow is still running (observed twice, once 4ms after launch). Do not trust the notification alone; treat `TaskOutput` returning `running` as authoritative and block until it returns the result. The SKILL.md procedure encodes this.
- **`args` may arrive JSON-string-encoded:** the Workflow tool delivered the args object as a JSON string on the first live launch. `pr-review.js` parses string args defensively; this is an adaptation to undocumented harness behavior and may change upstream.
- **Verify refute rate is a watch metric:** across 25 verified findings the refute rate was ~4% (1/25). High finding quality is one explanation, but verifier agreement bias (Claude-in-Claude, the accepted ADR 0029 trade-off) is another; if the refuted section stays empty across future runs, re-examine the verifier prompt's refutation incentive.
- **Approach re-evaluation triggers:** move off the dynamic workflow (to main-loop Agent orchestration plus a deterministic checker script) only if hangs become chronic (≥ frequent per-run intervention), the Workflow tool is deprecated or breaks journal/resume, or a lightweight no-verify variant of the gate is wanted. The code-enforced fail-closed gates, schema-forced specialist outputs, and CI-tested interpreter are workflow-only properties and are the reason this design exists.

## Risks

See ADR 0029 "Risks". The load-bearing ones, updated post-measurement: the verify token cost scales with finding count (measured, see Open questions), the missing per-specialist timeout (observed live, see Open questions), and the lost cross-model adversarial perspective (accepted trade-off in the company environment).

## References

- [ADR 0029](../adr/0029-claude-pr-review-dynamic-workflow.md) — the decision
- [docs/design/codex-pr-review.md](codex-pr-review.md) — Codex-side sibling (authoritative where Codex is available)
- `pr-review-toolkit` (Apache-2.0), `claude-code-security-review` (MIT), `openai/codex-plugin-cc` (Apache-2.0) — specialist sources
