#!/usr/bin/env bats
# shellcheck shell=bash
# Tests for private_dot_claude/skills/brainstorming/{SKILL.md, references/*,
# LICENSE.superpowers} and tests/skills/brainstorming/prompts/T00..T10.
# These tests enforce the progressive-disclosure layout decided in ADR 0022
# and catch structural regressions before merge. CI installs `bats` only,
# so we use `grep` (not `rg`).

bats_require_minimum_version 1.5.0

setup() {
  # bats preprocesses .bats files into /tmp; BASH_SOURCE[0] at the test scope
  # points there, so resolve the repo via BATS_TEST_FILENAME (the original
  # path) instead of BASH_SOURCE — same pattern as test_hooks.bats.
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/private_dot_claude/skills/brainstorming"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  LICENSE_FILE="$SKILL_DIR/LICENSE.superpowers"
  REF_DIR="$SKILL_DIR/references"
  PROMPTS_DIR="$REPO_ROOT/tests/skills/brainstorming/prompts"
  export REPO_ROOT SKILL_DIR SKILL_MD LICENSE_FILE REF_DIR PROMPTS_DIR
}

# -----------------------------------------------------------------------------
# SKILL.md structural guards
#
# ADR 0022's whole point is that SKILL.md stays small, because every line is a
# recurring token cost in the rendered context. 80 lines is the ceiling chosen
# in the implementation plan; the target is ~50.
# -----------------------------------------------------------------------------

@test "SKILL.md exists and is within 20-80 line bounds" {
  [ -f "$SKILL_MD" ]
  local n
  n="$(wc -l <"$SKILL_MD")"
  # Floor guards against silent truncation / accidental wipe; ceiling enforces
  # the ADR 0022 progressive-disclosure target (~50 line core).
  [ "$n" -ge 20 ]
  [ "$n" -lt 80 ]
}

# Heading existence is a precondition for the HARD-GATE position guard below.
# Splitting it out keeps a missing/renamed heading from being misattributed
# to "HARD-GATE missing" in test output.
@test "SKILL.md has expected top-level heading" {
  grep -q '^# Brainstorming Ideas Into Designs$' "$SKILL_MD"
}

# Salience guard: HARD-GATE must appear within the first 15 body lines after
# the `# Brainstorming Ideas Into Designs` heading. If it drifts past line 15,
# it loses priority in the context-resident rendering and the final-checkpoint
# failure mode from PR #207 can recur.
@test "SKILL.md top 15 body lines contain HARD-GATE" {
  local body
  body="$(awk '
    /^# Brainstorming Ideas Into Designs/ { found=1; next }
    found && c < 15 { print; c++ }
  ' "$SKILL_MD")"
  echo "$body" | grep -q 'HARD-GATE'
}

# Progressive-disclosure wiring (per-file). A single counting grep
# (`grep -c references/ >= 3`) would pass with three duplicate links to one
# file; we check each reference individually so the regression guard cannot
# drift to that weaker shape.
@test "SKILL.md links references/approaches.md individually" {
  grep -q 'references/approaches\.md' "$SKILL_MD"
}

@test "SKILL.md links references/design-section.md individually" {
  grep -q 'references/design-section\.md' "$SKILL_MD"
}

@test "SKILL.md links references/after-design.md individually" {
  grep -q 'references/after-design\.md' "$SKILL_MD"
}

# Trigger surface: the Japanese trigger phrases must remain in `description`
# so the skill keeps loading on phrases like 「ブレスト」/「設計相談」.
# Shortening the description is one of the ADR 0022 risks; this test pins
# the full list (not just two) so any silent drop is caught.
@test "SKILL.md description preserves Japanese trigger phrases" {
  grep -q 'ブレスト' "$SKILL_MD"
  grep -q '設計を考えたい' "$SKILL_MD"
  grep -q 'どう実装すべきか' "$SKILL_MD"
  grep -q 'アーキテクチャを相談したい' "$SKILL_MD"
  grep -q '設計相談' "$SKILL_MD"
  grep -q '実装の前に整理したい' "$SKILL_MD"
  grep -q '方針を決めたい' "$SKILL_MD"
}

@test "SKILL.md description preserves English trigger phrase" {
  grep -q 'Socratic-dialogue design refinement' "$SKILL_MD"
}

# -----------------------------------------------------------------------------
# SKILL.md content invariants
#
# Pins the runtime-behavior strings that ADR 0022's bats gate is supposed to
# protect. Each grep target is a string ADR 0022 / Pre-send self-check / Core
# rules / Safety rules / Checklist relies on; silent drift of any of them
# would let T03..T10 fixtures pass while the skill body has regressed.
# -----------------------------------------------------------------------------

@test "SKILL.md contains BRAINSTORMING_SKILL_V1 sentinel" {
  grep -q '<!-- BRAINSTORMING_SKILL_V1 -->' "$SKILL_MD"
}

@test "SKILL.md pins Pre-send self-check naming" {
  grep -q 'Pre-send self-check' "$SKILL_MD"
}

# T02 leak-guard regression: the assistant must paraphrase HARD-GATE on refusal,
# never paste the literal `<HARD-GATE>...</HARD-GATE>` tag block. Surfaced as a
# T02 fixture leak-guard drift during dogfooding of PR #211 — the refusal was
# correct but the assistant copy-pasted SKILL.md L11 verbatim. Pinning the
# instruction here so silent removal of the paraphrase rule fails CI.
@test "SKILL.md T02 invariant — HARD-GATE refusal must paraphrase, not paste tag block" {
  grep -q 'paraphrase the rule' "$SKILL_MD"
  grep -q 'never paste the literal' "$SKILL_MD"
}

# Safety rules (ADV high #1): non-negotiable commit-path guards must live in
# the always-loaded SKILL.md body, not solely in references/after-design.md.
@test "SKILL.md safety rules — detached HEAD refusal" {
  grep -qi 'detached HEAD' "$SKILL_MD"
}

@test "SKILL.md safety rules — origin/HEAD default-branch detection" {
  grep -q 'origin/HEAD' "$SKILL_MD"
}

@test "SKILL.md safety rules — ban on git add -A wildcards" {
  grep -qE 'git add -A|git add \.' "$SKILL_MD"
}

# T03-T08 invariants — Pre-send self-check + Core rules content.
@test "SKILL.md T03 invariant — count decisions, not question marks" {
  grep -q 'count decisions, not question marks' "$SKILL_MD"
}

@test "SKILL.md T04 invariant — lead with a hypothesis" {
  grep -q 'lead with a hypothesis' "$SKILL_MD"
}

@test "SKILL.md T05 invariant — orthogonal axes ban" {
  grep -q 'orthogonal axes' "$SKILL_MD"
}

@test "SKILL.md T06 invariant — never 3+ questions" {
  grep -q 'never 3+' "$SKILL_MD"
}

@test "SKILL.md T07 invariant — investigate before asking with 3-file bound" {
  grep -q 'Investigate before asking' "$SKILL_MD"
  grep -q 'up to 3' "$SKILL_MD"
}

@test "SKILL.md T08 invariant — decompose independent subsystems" {
  grep -q 'Decompose multiple independent subsystems' "$SKILL_MD"
}

# -----------------------------------------------------------------------------
# references/* integrity — existence, non-empty, at least one h2 heading.
# -----------------------------------------------------------------------------

@test "references/approaches.md exists, non-empty, has heading" {
  [ -s "$REF_DIR/approaches.md" ]
  grep -q '^## ' "$REF_DIR/approaches.md"
}

@test "references/design-section.md exists, non-empty, has heading" {
  [ -s "$REF_DIR/design-section.md" ]
  grep -q '^## ' "$REF_DIR/design-section.md"
}

@test "references/after-design.md exists, non-empty, has heading" {
  [ -s "$REF_DIR/after-design.md" ]
  grep -q '^## ' "$REF_DIR/after-design.md"
}

# -----------------------------------------------------------------------------
# references/after-design.md content invariants
#
# T09 (ADR shape) and T10 (branch safety) cannot regress silently while the
# fixture-shape gate alone passes; pin the strings the runtime relies on.
# -----------------------------------------------------------------------------

@test "references/after-design.md T09 invariant — ADR template four sections" {
  local f="$REF_DIR/after-design.md"
  grep -q '^## Status' "$f"
  grep -q '^## Context' "$f"
  grep -q '^## Decision' "$f"
  grep -q '^## Consequences' "$f"
}

@test "references/after-design.md T09 invariant — auto-detect ADR directory" {
  grep -q 'Auto-detect ADR directory' "$REF_DIR/after-design.md"
}

@test "references/after-design.md T10 invariant — detached HEAD reject" {
  grep -q 'Detached HEAD' "$REF_DIR/after-design.md"
}

@test "references/after-design.md T10 invariant — default branch detection chain" {
  local f="$REF_DIR/after-design.md"
  grep -q 'origin/HEAD' "$f"
  grep -q 'main' "$f"
  grep -q 'master' "$f"
  grep -q 'trunk' "$f"
  grep -q 'develop' "$f"
}

# -----------------------------------------------------------------------------
# LICENSE.superpowers attribution sentinel
# -----------------------------------------------------------------------------

@test "LICENSE.superpowers contains MIT sentinel and Jesse Vincent" {
  [ -f "$LICENSE_FILE" ]
  grep -q 'MIT License' "$LICENSE_FILE"
  grep -q 'Jesse Vincent' "$LICENSE_FILE"
}

# -----------------------------------------------------------------------------
# Prompt fixtures T00..T10
#
# Heading-presence catches a missing fixture or a renamed section.
# Content-presence catches a fixture that has all five headings but empty
# bodies (the weaker check would silently pass). Without content the fixture
# cannot drive fresh-session evaluation.
# -----------------------------------------------------------------------------

@test "prompt fixtures T00..T10 exist with all 5 required sections" {
  local i f
  for i in 00 01 02 03 04 05 06 07 08 09 10; do
    f="$(ls "$PROMPTS_DIR"/T${i}_*.md 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "missing fixture T$i" >&2; return 1; }
    [ -f "$f" ]
    grep -q '^## Preconditions$' "$f" || { echo "$f missing ## Preconditions" >&2; return 1; }
    grep -q '^## User turns$' "$f" || { echo "$f missing ## User turns" >&2; return 1; }
    grep -q '^## Expected signals$' "$f" || { echo "$f missing ## Expected signals" >&2; return 1; }
    grep -q '^## Anti-signals$' "$f" || { echo "$f missing ## Anti-signals" >&2; return 1; }
    grep -q '^## Leak guard$' "$f" || { echo "$f missing ## Leak guard" >&2; return 1; }
  done
}

@test "prompt fixtures T00..T10 have non-empty Expected/Anti/Leak guard sections" {
  local i f section body
  for i in 00 01 02 03 04 05 06 07 08 09 10; do
    f="$(ls "$PROMPTS_DIR"/T${i}_*.md 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "missing fixture T$i" >&2; return 1; }
    for section in 'Expected signals' 'Anti-signals' 'Leak guard'; do
      # Grab the lines after `## $section` until the next `## ` heading or
      # EOF, then require at least one bullet line (`- text`) in that block.
      body="$(awk -v sec="## $section" '
        $0 == sec { in_sec=1; next }
        in_sec && /^## / { in_sec=0 }
        in_sec { print }
      ' "$f")"
      echo "$body" | grep -qE '^[[:space:]]*-[[:space:]]+[^[:space:]]' \
        || { echo "$f section '$section' has no bullet" >&2; return 1; }
    done
  done
}
