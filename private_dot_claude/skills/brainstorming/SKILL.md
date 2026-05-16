---
name: brainstorming
description: ソクラテス式対話で要件と設計を詰めてから実装方針を固めるブレインストーミングスキル。「ブレスト」「設計を考えたい」「どう実装すべきか」「アーキテクチャを相談したい」「設計相談」「実装の前に整理したい」「方針を決めたい」などのリクエストで発動する。Triggers Socratic-dialogue design refinement before implementation; surfaces 2-3 approaches and records key decisions as ADRs.
---

<!-- Derived from obra/superpowers — Brainstorming Skill. See LICENSE.superpowers for MIT terms and derivative notes. -->
<!-- BRAINSTORMING_SKILL_V1 -->

# Brainstorming Ideas Into Designs

<HARD-GATE>No code, scaffolding, implementation skill, or implementation action before context check → brief design → user approval. Simple tasks get shorter designs, never skip.</HARD-GATE>

**Pre-send self-check** (run before sending any message that asks the user something): ask exactly one decision per message; count decisions, not question marks; never 3+; never bundle orthogonal axes into one preset; always include your recommendation; when refusing under HARD-GATE, paraphrase the rule in your own words — never paste the literal `<HARD-GATE>...</HARD-GATE>` tag block from this file.

## Core rules

- One user-answerable question per message; lead with a hypothesis ("Based on X, I'm assuming Y — right?"), not interrogation.
- Investigate before asking — for repo-factual questions, list/grep plus up to 3 directly relevant files; ask only if intent is needed or ambiguity remains.
- Decompose multiple independent subsystems before refining details. Each sub-project gets its own design → ADR → plan cycle.
- Follow existing patterns when working in existing codebases. Include targeted improvements only when they serve the current goal.
- Design boundaries explicitly: each unit has one purpose, a well-defined interface, and is testable in isolation.
- Side-effect actions (commit, push) require explicit user confirmation; opt-in, not default.

## Safety rules (non-negotiable)

- **Refuse commit on detached HEAD**: if `git branch --show-current` is empty, ask the user to create a branch first.
- **Never commit to the default branch without explicit confirmation**: detect via `git rev-parse --abbrev-ref origin/HEAD` (strip the `origin/` prefix); on failure, fall back to `main` / `master` / `trunk` / `develop`.
- **Stage explicit paths only**: never `git add -A` / `git add .`. Verify with `git diff --cached --name-only` before commit.

## Checklist

Create a task for each and complete in order:

1. **Explore project context and assess scope** — files, docs, recent commits. Decompose if multiple independent subsystems.
2. **Ask clarifying questions** — one decision per message, hypothesis-driven. Read `references/approaches.md` before step 3.
3. **Propose 2-3 approaches** — with trade-off table, your recommendation, and a visible strongest-objection check. Read `references/design-section.md` before step 4.
4. **Present design in sections** — scale to complexity, ASCII art where it helps, approve after each section.
5. **Write ADR(s)** — auto-detect ADR directory and next number; one ADR per distinct decision. Read `references/after-design.md` before writing.
6. **Confirm ADR(s) with the user** — present and accept revisions before committing.
7. **Commit ADR(s) or skip per user preference** — apply the Safety rules above; see `references/after-design.md` for the full procedure.

<HARD-GATE>After design and ADR handling, hand off to plan mode for implementation. No code, scaffolding, implementation skill, or implementation action until the user enters plan mode — regardless of task triviality. The user-global "軽く扱ってよい対象" classification (`~/.claude/CLAUDE.md`) does not authorize bypassing this handoff once brainstorming has loaded.</HARD-GATE>
