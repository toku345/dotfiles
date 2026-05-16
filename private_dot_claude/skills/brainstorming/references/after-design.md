# After the design

Read this file before Checklist step 5 (write ADR(s)).

## Create ADRs

After the user approves the design, record key design decisions as ADR(s).

**Auto-detect ADR directory and next number:**

1. Look for the project's ADR directory. Default: `docs/adr/`. Adapt to the project's conventions (some repos use `docs/adrs/`, `architecture/decisions/`, etc.). Inspect the repo layout first.
2. List the files in that directory and find the highest `NNNN` prefix.
3. Increment by 1 and zero-pad to 4 digits (e.g., `0022` → `0023`).
4. If no ADR directory exists, create `docs/adr/` and start at `0001`.

**ADR template:**

```
# ADR NNNN: <Title>

## Status

Accepted

## Context

<Why this decision was needed — the forces at play>

## Decision

<What was decided and why>

## Consequences

<What follows from this decision — positive, negative, and risks>
```

**Split vs single ADR:**

- One ADR per **distinct design decision**. A single cohesive decision → one ADR. Multiple independent decisions surfaced in the same session → separate ADRs.
- Heuristic: if you can imagine superseding decision A without touching decision B, they belong in separate ADRs.

**ADR vs design boundary:**

The ADR captures the *decision and its rationale*, not the full design. The design conversation itself is the primary record of requirements and exploration. ADRs stay readable years later because they stay decision-shaped; design details that may change after implementation belong in the PR commits or a separate design doc, not in the ADR.

## Confirm ADRs

After writing, present the ADR(s) to the user and ask for confirmation before proceeding. Accept revisions — common ones are wording tweaks, splitting one ADR into two, or extending the Consequences section. Re-present after revisions until the user confirms.

## Commit Or Skip

If the user prefers not to commit, skip this step. When committing:

### 1. Branch safety check

Verify the current branch is suitable for commits.

- **Detached HEAD reject**: `git branch --show-current` returning empty means detached HEAD. Refuse to commit and ask the user to create a branch first.
- **Default branch detect**: `git rev-parse --abbrev-ref origin/HEAD 2>/dev/null` returns something like `origin/main`. Strip the `origin/` prefix before comparing the current branch name.
- **Fallback list** if the detect command fails: check `main`, `master`, `trunk`, `develop`.
- **If on the default branch**: warn the user and suggest creating a feature branch before committing. Do not commit to the default branch without explicit user confirmation.

### 2. Inspect commit-message convention

Run `git log -10 --pretty=%s` and read the subject lines. Match the dominant style (e.g., Conventional Commits like `docs(adr-NNNN): ...`, or repo-specific patterns). If no clear convention is visible, fall back to `docs(adr): <slug>`.

### 3. Commit the ADR file(s)

Stage the explicit ADR paths — never `git add -A`. Verify staged files with `git diff --cached --name-only` before committing. Then commit with a subject following the inspected convention.

### 4. Transition to plan mode

After the design is approved and ADR(s) are handled (committed or skipped per user preference), let the user know they can proceed:

> "After design and ADR handling, hand off to plan mode for implementation. No code, scaffolding, implementation skill, or implementation action until the user enters plan mode — regardless of task triviality. The user-global \"軽く扱ってよい対象\" classification (`~/.claude/CLAUDE.md`) does not authorize bypassing this handoff once brainstorming has loaded."

<!-- SSOT: SKILL.md post-design HARD-GATE. Keep this quote byte-for-byte in sync with SKILL.md (modulo the surrounding quote-mark escaping); the bats gate enforces it. -->

The brainstorming skill's responsibility ends when the design is approved and the user is guided to plan mode.
