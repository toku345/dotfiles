# ADR 0029: Claude-side PR Review via Dynamic Workflow

## Status

Accepted

## Context

Company environments restrict Codex CLI to the point where it cannot serve as the review backend, so pre-PR review must run inside Claude Code. (`gh` itself remains available in the company environment; only Codex is restricted.) This invalidates the premise behind the Codex migration recorded in `docs/design/codex-pr-review.md`, which rejected every Claude-side orchestration variant (alternatives A/B/B'/C) on credit-economy grounds — that reasoning assumed Codex was freely available to absorb the heaviest review legs.

Three existing options all fail under the company constraint:

- Legacy `triple-review` (the ~1150-line bash orchestrator) drives its adversarial leg through `codex-companion.mjs` (Codex `gpt-5.x`), so it is half-functional where Codex is unavailable, on top of `claude -p` credit consumption and the fragility tracked across issues #197 / #201 / #204 / #205.
- The Codex `$pr-review` skill cannot be invoked from inside a Claude Code session (nested-bwrap infinite spawn-retry, recorded in `codex-pr-review.md` Non-goals) and is unavailable where Codex is restricted.
- The existing `pr-review-toolkit:review-pr` command runs the six bundled specialists but has no committed-branch-diff scope binding, no coverage sentinel, and no fail-closed gate, so it is a daily-floor tool, not a thick-change gate.

ADR 0012 concluded that in-session orchestration was "the wrong shape", but that conclusion was scoped to the `Skill` tool, which serializes by turn. Dynamic workflows are a different orchestration substrate (true in-session parallel subagent fan-out) that ADR 0012 never evaluated.

## Decision

Build the thick-change PR review gate as a Claude Code skill backed by a dynamic workflow, with a deliberate split across the sandbox boundary.

**Sandbox-boundary split.** Base-ref resolution that needs `gh` runs in the main Claude session (which can obtain `dangerouslyDisableSandbox`); the workflow subagents use only `git` (which runs inside the sandbox). A capability PoC confirmed that workflow-subagent Bash is sandbox-pinned and cannot run `gh` (`~/.config/gh/hosts.yml: operation not permitted`), while `git rev-parse` / `diff` run cleanly. That sandbox pin is independent of the company `gh` availability, which only governs the main session. The main session resolves `{base, baseCommit, headRef}` plus an authoritative diff packet, then passes them to the workflow via `Workflow({args})`. The `gh pr view` resolution path from the Codex skill moves to the main session; explicit `--base` is unchanged.

**Specialist set.** Reuse the six `pr-review-toolkit` specialists via `agentType` (`code-reviewer`, `silent-failure-hunter`, `type-design-analyzer`, `comment-analyzer`, `pr-test-analyzer`, `code-simplifier`). Port the two missing specialists (`security-reviewer`, `adversarial-reviewer`) from the Codex `.toml` prompts to Claude subagent `.md` files under `private_dot_claude/agents/`, preserving upstream attribution (MIT for `security-reviewer`, Apache-2.0 for `adversarial-reviewer`) and the Apache-2.0 §4(d) NOTICE that `adversarial-reviewer` (codex-plugin-cc) alone requires; `security-reviewer` (MIT) needs LICENSE bundling only.

**Gate structure.** Stage 1 fans out the applicable specialists with `parallel()` (a true barrier); after the barrier, JS normalizes severity and decides whether to spawn the Stage 2 `code-simplifier` (only when no Critical findings). Fail-closed is enforced in JS: each specialist returns a schema-validated coverage sentinel, and the workflow compares the returned packet hash against the orchestrator-computed hash, throwing on mismatch. The PoC confirmed both the barrier-plus-conditional-spawn pattern and the schema-plus-JS hash comparison; no agent lifecycle-handle API is needed because the barrier waits for all subagents before judging.

**Gate policy and severity contract.** The normalization contract has two parts: the gate policy (`review-criteria.md`, 26 lines, agent-agnostic and Codex-decoupled) and the severity-escalation logic (currently embedded in the Codex `SKILL.md`, e.g. confidence thresholds and per-specialist label mapping). Both must be shared with the Codex path, not just the criteria file. Since `review-criteria.md` currently lives inside the Codex skill bundle (`private_dot_codex/skills/pr-review/references/`), chezmoi must deploy it to a Claude-readable path as well (or both skills read one shared location), so the policy is not duplicated and cannot drift.

**Cross-model adversarial review is dropped.** Where Codex is unavailable, the adversarial specialist runs as a Claude subagent; the cross-model "outside perspective" is forgone and the self-review bias is accepted, mitigated only by the adversarial prompt framing.

## Consequences

### Positive

- Review runs entirely inside Claude Code, removing the Codex dependency that makes `triple-review` and the Codex skill unusable in the company environment.
- The orchestration moves from the bash orchestrator to a JS workflow with schema-enforced structured output and JS-level fail-closed control.
- Six of eight specialists are reused as-is via `agentType`; only two prompts are newly maintained on the Claude side.

### Negative

- Claude-side fan-out re-incurs the Claude token consumption that the Codex migration was designed to eliminate. A PoC measured 671k tokens for an un-pruned verify pass over a six-specialist subset; the eight-specialist parity build with verify will be higher, so a severity gate on which findings reach the verify stage is mandatory, not optional.
- Cross-model adversarial coverage is lost; Claude-reviewing-Claude is the weakest cross-check configuration.
- Two specialist prompts (`security-reviewer`, `adversarial-reviewer`) now exist as near-identical derivatives in both Codex `.toml` and Claude `.md`. The prompt bodies are a standing divergence surface; mitigate by pinning the upstream commit hashes in a shared manifest and by sharing the gate policy, but the bodies themselves still track the same upstream independently.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Un-pruned verify blows up token cost | High without a gate | Gate the adversarial-verify stage to Critical / Important findings only; measure the pruned cost on one representative diff before finalizing the design |
| No per-specialist wall-clock timeout (the #189 gap, unclosed by the Codex migration and unverified for dynamic workflows) lets a hung specialist stall the gate | Medium | The barrier waits for all subagents, so a single hang blocks aggregation; add a JS-level deadline around the `parallel()` await and fail closed on overrun, or accept-and-document if the runtime exposes no per-agent cap |
| `settings.local.json` sandbox write grant drifts from the user-global pattern (ADR 0001) | Low | Worktree base write is machine-agnostic (`~/` prefix); promote to user-global `~/.claude/settings.json` once the gitleaks branch lands and a clean branch is available |
| Self-review bias from same-model adversarial review | Medium | Adversarial prompt framing; revisit a partial-Hybrid Codex leg if Codex becomes available outside the company environment |
| Specialist prompt drift between the Codex `.toml` and Claude `.md` derivatives | Medium | Single shared manifest pinning the three upstream commit hashes; shared `review-criteria.md`; periodic diff of the two derivative sets |

## Relationship to prior decisions

This ADR does not refute ADR 0012; it supersedes ADR 0012's parallel-orchestration verdict only for the dynamic-workflow substrate, which the `Skill`-tool-scoped ADR 0012 did not cover. It does not refute `docs/design/codex-pr-review.md`; that design's credit-economy rejection of Claude-side orchestration holds where Codex is freely available, while this ADR governs the company environment where Codex is restricted. The two review paths are expected to coexist by environment, not to be merged.

## References

- [ADR 0012 (triple-review-bash-script)](0012-triple-review-bash-script.md)
- [ADR 0001 (sandbox git least-privilege)](0001-claude-code-sandbox-git-least-privilege.md) — sandbox filesystem `allowWrite` model
- [docs/design/codex-pr-review.md](../design/codex-pr-review.md) — Codex-side migration and alternatives table
- `pr-review-toolkit` (Apache-2.0), `claude-code-security-review` (MIT), `openai/codex-plugin-cc` (Apache-2.0) — specialist prompt sources
