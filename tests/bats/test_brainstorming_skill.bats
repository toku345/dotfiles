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

@test "SKILL.md exists and is under 80 lines" {
  [ -f "$SKILL_MD" ]
  local n
  n="$(wc -l <"$SKILL_MD")"
  [ "$n" -lt 80 ]
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
# Shortening the description is one of the ADR 0022 risks; this test pins it.
@test "SKILL.md description preserves Japanese triggers" {
  grep -q 'ブレスト' "$SKILL_MD"
  grep -q '設計相談' "$SKILL_MD"
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
      echo "$body" | grep -qE '^[[:space:]]*-[[:space:]]+\S' \
        || { echo "$f section '$section' has no bullet" >&2; return 1; }
    done
  done
}
