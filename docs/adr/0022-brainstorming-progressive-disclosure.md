# ADR 0022: Brainstorming skill progressive-disclosure redesign

## Status

Accepted (2026-05-13)

## Context

The brainstorming skill (`private_dot_claude/skills/brainstorming/SKILL.md`) is 236 lines, with heavy why/how narration across six sections. Fresh-session verification during PR #207 follow-up exposed two runtime violations during the final-checkpoint phase: three user-answerable questions in a single message, and orthogonal axes bundled into one preset.

PR #207 addressed the text-level rules (one-question default, 3+ ban, orthogonal-axes ban, SSOT for numeric invariants). The structural cause — attention dilution from a 236-line context-resident SKILL.md — remained. The rendered SKILL.md content stays in conversation context for the rest of the session, so every line is a recurring token cost that reduces salience of high-priority rules.

Supporting evidence:

- **grill-me skill** (Matt Pocock, ~124K installs, <https://www.skills.sh/mattpocock/skills/grill-me>) keeps a ~60-word body; fresh-session comparison showed its one-question discipline remained salient at runtime.
- **Anthropic Claude Code skill spec** (<https://code.claude.com/docs/en/skills>) states: "Keep SKILL.md under 500 lines", "State what to do rather than narrating how or why", "every line is a recurring token cost". Combined `description` + `when_to_use` is truncated at 1,536 characters.
- **Official ecosystem example**: `gpt-5-4-prompting` (codex plugin) uses a 55-line SKILL.md plus `references/` for progressive disclosure.

Issue #208 tracks this structural follow-up.

## Decision

Adopt **Approach A: Minimalist Single-Layer redesign**, with four interlocking components:

1. **Slim SKILL.md** — concentrate HARD-GATE, pre-send lint, and core rules at the top of a tightly skeletoned file so the highest-priority rules retain salience at every checkpoint.
2. **On-demand `references/` directory** — move phase-specific guidance (approach proposal, design presentation, ADR writing & commit) into reference files loaded only when the corresponding Checklist step fires.
3. **`LICENSE.superpowers` attribution** — move the upstream MIT license text out of the SKILL.md HTML comment into a sibling non-runtime attribution file, freeing budget without losing provenance.
4. **Testing strategy** — codify runtime expectations as prompt fixtures with a structural bats CI gate (line ceiling / wiring / fixture shape) and require fresh-session evidence in the merge DoD. Programmatic skill-adherence (Level 3) testing is deferred to Issue #210.

Implementation specifics (file paths, line budgets, section skeletons, fixture enumeration, commit order) live in the PR closing #208 and its commit messages, not in this ADR.

## Consequences

### Positive

- **Runtime adherence**: SKILL.md attention dilution drops from a 236-line recurring cost to a ~50-line core. Pre-send self-check addresses the failure modes (3+ questions, orthogonal-axes bundling) first observed at the final-checkpoint phase.
- **Progressive disclosure**: phase-specific guidance loads only when needed, aligned with the official anatomy and `gpt-5-4-prompting` prior art.
- **Maintainability**: changes to skill identity (SKILL.md) versus changes to phase tactics (`references/*.md`) become separable concerns.
- **Regression protection**: a structural bats gate (line ceiling, fixture shape, reference-link presence, integrity sentinels) catches drift before merge.

### Negative / risks

- **Judgment-driven reference loading**: even with imperative checklist wording, reference loading remains model-behavior-dependent rather than mechanically enforced. Mitigated by embedding "Read references/X before Y" imperatives in the Checklist and ultimately by Level 3 automation (Issue #210).
- **Manual verification dependency** persists until Level 3 automation lands.
- **Attribution maintenance**: `LICENSE.superpowers` introduces a new non-runtime file in the skill directory. Cost is one-time; risk of unattributed derivative was deemed higher.
- **Trigger-surface drift**: shortening the frontmatter could reduce Japanese trigger coverage. Mitigated by retaining the Japanese trigger phrases in `description` and by fresh-session verification that Japanese phrases still load the skill.

## Related

- PR #207 — preceding text-level fix (one-question default, 3+ ban, orthogonal-axes ban, SSOT)
- Issue #208 — tracks this structural refactor
- Issue #210 — Level 3 automated testing trigger
