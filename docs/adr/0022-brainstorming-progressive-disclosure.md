# ADR 0022: Brainstorming skill progressive-disclosure redesign

## Status

Accepted (2026-05-13)

## Context

The brainstorming skill (`private_dot_claude/skills/brainstorming/SKILL.md`) was 236 lines, with heavy why/how narration across six sections (HARD-GATE, Anti-Pattern, Process Flow, The Process, After the Design, Key Principles).

Fresh-session verification during PR #207 follow-up exposed two runtime violations during the final-checkpoint phase of a brainstorming session:

1. Three user-answerable questions in a single message
2. Orthogonal axes bundled (three independent decisions asked together)

PR #207 addressed the immediate text-level rules (one-question default, 3+ ban, orthogonal-axes ban, SSOT for numeric invariants). However, the structural cause — attention dilution from a 236-line context-resident SKILL.md — remained. The rendered SKILL.md content stays in conversation context for the rest of the session, so every line is a recurring token cost that reduces salience of high-priority rules.

This ADR records the structural follow-up tracked by Issue #208.

Supporting evidence:

- **grill-me skill** (Matt Pocock, ~124K installs, <https://www.skills.sh/mattpocock/skills/grill-me>) keeps a ~60-word body. Fresh-session comparison showed its one-question discipline remained salient at runtime.
- **Anthropic Claude Code skill spec** (<https://code.claude.com/docs/en/skills>) states: "Keep SKILL.md under 500 lines", "State what to do rather than narrating how or why", "every line is a recurring token cost". The same doc specifies that combined `description` + `when_to_use` text is truncated at 1,536 characters.
- **Official ecosystem example**: `gpt-5-4-prompting` (codex plugin) uses a 55-line SKILL.md plus `references/` for progressive disclosure.

## Decision

Adopt **Approach A: Minimalist Single-Layer redesign**, with four interlocking components.

### 1. SKILL.md ~50 lines

Tight skeleton with the top 15 lines carrying HARD-GATE and question discipline:

- Frontmatter — Japanese trigger phrases + concise English description (preserves trigger surface; combined `description` + `when_to_use` cap is 1,536 chars per Anthropic spec)
- Attribution comment (1-2 lines pointing to `LICENSE.superpowers`)
- HARD-GATE (1 line: "No code, scaffolding, implementation skill, or implementation action before context check -> brief design -> user approval; simple tasks get shorter designs, never skip")
- Pre-send lint (1-2 lines: "ask exactly one decision, count decisions not question marks, never 3+, never bundle orthogonal axes, include your recommendation")
- Core rules (6 lines: one-question hypothesis-driven, investigate-first bounded, sub-project decomposition, follow existing patterns, design boundaries explicitly, side-effect confirmation)
- Checklist (7 items with embedded "Read references/X before Y" imperatives)
- Transition line ("Requirements are clear ... Switch to plan mode when ready" — fires after ADR confirmation regardless of commit/skip)

### 2. `references/` directory (3 files, on-demand load)

- `approaches.md` (~30-50 lines): 2-3 approach proposal structure, trade-off table, recommendation framing, **visible strongest-objection check**, 2-vs-3 heuristic, sub-project decomposition consequence
- `design-section.md` (~40-60 lines): section partition (default menu, not mandatory sequence), ASCII art convention, scale calibration, decision-shaped approval cadence, design-for-isolation details, working-in-existing-codebases details, pivot handling (local correction vs material goal change)
- `after-design.md` (~60-80 lines): three subsections — Create ADRs (template + numbering + split/single + ADR/design boundary), Confirm ADRs, Commit Or Skip (branch safety, `git log -10 --pretty=%s` for convention inspection, fallback `docs(adr): ...`, skip path, transition)

### 3. `LICENSE.superpowers` in skill directory

Non-runtime attribution: full MIT license text from `obra/superpowers` (Copyright (c) 2025 Jesse Vincent) + source URL + broad derivative-files note. Not listed under runtime references.

### 4. Testing strategy

**Verifiability principle**: "Must/never rules need observable signals; judgment rules need reviewable output criteria."

- 11 codified test prompts (T0-T10) in `<repo-root>/tests/skills/brainstorming/prompts/` (single-turn and multi-turn formats, each with Preconditions, User turns, Expected signals, Anti-signals, and a Leak guard evaluator checklist)
- Bats CI gate at `<repo-root>/tests/bats/test_brainstorming_skill.bats` (uses `grep`, not `rg`, since CI installs only `bats`): integrity checks for reference files (existence, non-empty, heading), LICENSE.superpowers MIT sentinel, SKILL.md line ceiling `< 80` (regression guard), SKILL.md references-link presence, prompt-fixture shape check
- DoD checklist with evidence column for fresh-session verification (T0-T10 all required for merge)
- Level 3 automation (programmatic skill-adherence testing) deferred to Issue #210, which records trigger conditions

## Consequences

### Positive

- **Runtime adherence**: SKILL.md attention dilution drops from 236-line recurring cost to ~50-line core. Pre-send lint targets the observed final-checkpoint failure mode.
- **Progressive disclosure**: phase-specific guidance loaded only when needed, aligned with official anatomy and ecosystem prior art (`gpt-5-4-prompting`).
- **Maintainability**: changes to skill identity (SKILL.md) versus changes to phase tactics (`references/*.md`) become separable concerns.
- **Regression protection**: bats line-ceiling check, fixture-shape check, link-presence check, and integrity sentinels catch structural drift before merge.

### Negative / risks

- **Judgment-driven reference loading**: even with imperative checklist wording, reference loading remains model-behavior-dependent rather than mechanically enforced. Mitigated by embedding "Read references/X before Y" imperatives in Checklist items, by an anti-signal flagging eager startup loading of all references, and ultimately by Level 3 automation (Issue #210) when triggered.
- **Manual verification dependency** persists until Level 3 automation lands (Issue #210).
- **Migration overhead**: zero-base refactor PR is structurally larger than a typical edit despite the smaller line count. Reviewer cognitive load increases. Mitigated by separating the prior text-level fix into PR #207 so this PR's diff is scoped to the restructure.
- **Attribution maintenance**: `LICENSE.superpowers` introduces a new non-runtime file in the skill directory. Cost is one-time; risk of unattributed derivative was deemed higher.
- **Ceiling pressure**: enforcing SKILL.md `< 80` could discourage legitimate growth. Buffer chosen (~50 target vs 80 ceiling) provides 30-line headroom for future invariants. This is a regression guard, not a strict design target.
- **Trigger-surface drift**: shortening frontmatter may reduce Japanese trigger coverage. Mitigated by retaining Japanese trigger phrases in `description` and by T0 fresh-session verification (Japanese trigger phrases must load the skill).

## Migration

1. PR #207 (text-level fix) is merged into `main` first. Issue #208 references this ADR.
2. A new feature branch is cut from `main` after PR #207 lands.
3. This ADR file (`docs/adr/0022-brainstorming-progressive-disclosure.md`) is committed on the new branch.
4. Implementation phase populates SKILL.md, the three `references/*.md` files, `LICENSE.superpowers`, the bats test (`tests/bats/test_brainstorming_skill.bats`), and the 11 prompt fixtures (`tests/skills/brainstorming/prompts/`).
5. Fresh-session verification (T0-T10) is executed and evidence is recorded in the PR Test plan.
6. PR is submitted with `Closes #208`.
7. After merge: monitor for runtime violations. Issue #210 records Level 3 automation trigger conditions: another brainstorming skill revision, or a fresh-session runtime violation. If either trigger fires, begin that work.

## Related

- PR #207 — preceding text-level fix (one-question default, 3+ ban, orthogonal-axes ban, SSOT)
- Issue #208 — tracks this structural refactor
- Issue #210 — Level 3 automated testing trigger
