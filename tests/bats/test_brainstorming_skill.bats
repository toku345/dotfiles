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
  # awk NR counts records; unlike `wc -l`, it does not lose the trailing line
  # when the file ends without a newline. ADR 0022's "~50 line core" target is
  # documented as measured by awk NR.
  n="$(awk 'END{print NR}' "$SKILL_MD")"
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
@test "SKILL.md top 15 body lines contain a HARD-GATE tag line" {
  local body
  body="$(awk '
    /^# Brainstorming Ideas Into Designs/ { found=1; next }
    found && c < 15 { print; c++ }
  ' "$SKILL_MD")"
  # Anchor on a real `<HARD-GATE>...</HARD-GATE>` tag line, not a substring
  # token. SKILL.md L13 mentions the literal token inside the Pre-send
  # self-check rule, so a substring match would silently pass even if the
  # real HARD-GATE block on L11 were deleted.
  echo "$body" | grep -qE '^<HARD-GATE>.*</HARD-GATE>$'
}

# Token-singular guard (ADR 0022 salience design — Codex review of plan v3):
# ADR 0022 keeps HARD-GATE singular so the token's salience stays high. If a
# second `<HARD-GATE>...</HARD-GATE>` block is added (e.g., to "strengthen"
# a different boundary), the token's weight is diluted and the salience
# property silently degrades. Enforce exact-one tag line so this regression
# fails CI loudly.
@test "SKILL.md contains exactly one <HARD-GATE>...</HARD-GATE> tag line" {
  local count
  count="$(grep -cE '^<HARD-GATE>.*</HARD-GATE>$' "$SKILL_MD")"
  [ "$count" -eq 1 ]
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
  grep -q '<HARD-GATE>' "$SKILL_MD"
}

# Section-scoped pin (Codex review of plan v3): the three tokens above must
# all live inside the Pre-send self-check paragraph, not as orphaned strings
# elsewhere in the file. If the paragraph is removed but the tokens leak into
# unrelated sections, the three independent greps above would still pass —
# this gate fails that silent drift.
@test "SKILL.md Pre-send self-check section contains the paraphrase rule tokens" {
  local section
  # Extract the Pre-send self-check paragraph: from the line starting with
  # `**Pre-send self-check**` until the next blank line (or `##` heading).
  section="$(awk '
    /^\*\*Pre-send self-check\*\*/ { in_sec=1 }
    in_sec && /^## / { in_sec=0 }
    in_sec && /^$/ { in_sec=0 }
    in_sec { print }
  ' "$SKILL_MD")"
  echo "$section" | grep -q 'paraphrase the rule'
  echo "$section" | grep -q 'never paste the literal'
  echo "$section" | grep -q '<HARD-GATE>'
}

# Post-design no-code boundary (Codex review of plan v3, P0 #2 / P1 #5):
# the rule must live in the always-loaded SKILL.md body so a model that never
# loads references/after-design.md still refuses code after design approval.
@test "SKILL.md contains post-design no-code boundary" {
  grep -q 'do not write code, scaffold projects, or invoke implementation skills' "$SKILL_MD"
}

# SSOT sync (Codex review of plan v3, P1 #5): references/after-design.md
# must carry the exact same handoff sentence as SKILL.md so the two control
# planes cannot drift. SKILL.md is the SSOT; the reference quotes it. If one
# is edited without the other, this gate fails loudly.
@test "references/after-design.md mirrors the SKILL.md post-design handoff" {
  grep -q 'do not write code, scaffold projects, or invoke implementation skills' "$REF_DIR/after-design.md"
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

@test "references/after-design.md T09 invariant — ADR template four sections with bodies" {
  local f="$REF_DIR/after-design.md"
  # Heading-only checks (AGENTS.md "fixture content-presence" gotcha): a file
  # with all four headings but empty bodies would pass. Extract each section
  # body and require at least one non-blank content line under each heading.
  local section body
  for section in 'Status' 'Context' 'Decision' 'Consequences'; do
    body="$(awk -v sec="$section" '
      $0 == "## " sec { in_sec=1; next }
      in_sec && /^## / { in_sec=0 }
      in_sec { print }
    ' "$f")"
    echo "$body" | grep -qE '[^[:space:]]' \
      || { echo "ADR template section '$section' has empty body" >&2; return 1; }
  done
}

@test "references/after-design.md T09 invariant — auto-detect ADR directory" {
  grep -q 'Auto-detect ADR directory' "$REF_DIR/after-design.md"
}

@test "references/after-design.md T10 invariant — detached HEAD reject" {
  grep -q 'Detached HEAD' "$REF_DIR/after-design.md"
}

@test "references/after-design.md T10 invariant — default branch detection chain" {
  local f="$REF_DIR/after-design.md"
  # The chain has two layers — keep both pinned independently so that
  # collapsing them into one regex (Codex review of plan v3, P0 #1) cannot
  # silently hide regressions where the primary detect is removed but the
  # fallback list survives, or vice versa.
  # Layer 1: primary detect via origin/HEAD.
  grep -q 'origin/HEAD' "$f"
  # Layer 2: fallback list with all four branch names on a single line, in
  # the canonical order. A single-regex match also pins ordering, so a fall
  # back of `develop / main / master / trunk` (i.e., wrong order) fails CI.
  grep -qE '\bmain\b.*\bmaster\b.*\btrunk\b.*\bdevelop\b' "$f"
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
# Prompt fixtures T00..T11
#
# The expected fixture-ID set is centralized at EXPECTED_FIXTURE_IDS so adding
# a new fixture only requires updating one place. Tests then enforce three
# properties against the on-disk T??_*.md files (Codex review of plan v3,
# P1 #4):
#
#   1. exact match — every expected ID has exactly one fixture, no expected
#      ID is missing, and no unexpected fixture exists (catches T12_*.md
#      added without updating tests, or T0X_*.md silently deleted).
#   2. no duplicates — exactly one fixture matches each T${i}_*.md glob
#      (catches a stray rename like `T03_*.md` + `T03_old_*.md`).
#
# Heading-presence catches a missing fixture or a renamed section.
# Content-presence catches a fixture that has all five headings but empty
# bodies (the weaker check would silently pass). Without content the fixture
# cannot drive fresh-session evaluation.
# -----------------------------------------------------------------------------

EXPECTED_FIXTURE_IDS=(00 01 02 03 04 05 06 07 08 09 10 11)

@test "prompt fixtures: on-disk set matches EXPECTED_FIXTURE_IDS exactly" {
  local found_ids=()
  local f base id
  # nullglob is scoped to a subshell elsewhere; here we list the directory
  # explicitly and parse the T??_ prefix so we do not depend on glob
  # expansion semantics.
  while IFS= read -r f; do
    base="$(basename "$f")"
    # Strip the "T" prefix and everything from the first underscore onward.
    id="${base#T}"
    id="${id%%_*}"
    found_ids+=("$id")
  done < <(find "$PROMPTS_DIR" -maxdepth 1 -type f -name 'T*_*.md' | sort)

  # Build sorted expected/found strings for diff-style comparison.
  local expected_sorted found_sorted
  expected_sorted="$(printf '%s\n' "${EXPECTED_FIXTURE_IDS[@]}" | sort -u)"
  found_sorted="$(printf '%s\n' "${found_ids[@]}" | sort)"

  # Duplicate detection: sorted count must equal unique count.
  local found_unique
  found_unique="$(printf '%s\n' "${found_ids[@]}" | sort -u)"
  if [ "$found_sorted" != "$found_unique" ]; then
    echo "duplicate fixture IDs detected:" >&2
    printf '%s\n' "${found_ids[@]}" | sort | uniq -d >&2
    return 1
  fi

  if [ "$expected_sorted" != "$found_unique" ]; then
    echo "fixture ID mismatch" >&2
    echo "--- expected" >&2
    echo "$expected_sorted" >&2
    echo "--- found" >&2
    echo "$found_unique" >&2
    return 1
  fi
}

# Helper: resolve a fixture file for a given T${i} ID, asserting that
# exactly one file matches. Scopes nullglob to a subshell so the option does
# not leak into the surrounding test process (Codex review of plan v3, P1 #4).
resolve_fixture() {
  local i="$1"
  ( shopt -s nullglob
    local matches=("$PROMPTS_DIR"/T${i}_*.md)
    if [ "${#matches[@]}" -eq 0 ]; then
      echo "no fixture for T${i}" >&2
      return 1
    fi
    if [ "${#matches[@]}" -gt 1 ]; then
      echo "multiple fixtures for T${i}: ${matches[*]}" >&2
      return 1
    fi
    printf '%s\n' "${matches[0]}"
  )
}

@test "prompt fixtures T00..T11 exist with all 5 required sections" {
  local i f
  for i in "${EXPECTED_FIXTURE_IDS[@]}"; do
    f="$(resolve_fixture "$i")" || return 1
    [ -f "$f" ]
    grep -q '^## Preconditions$' "$f" || { echo "$f missing ## Preconditions" >&2; return 1; }
    grep -q '^## User turns$' "$f" || { echo "$f missing ## User turns" >&2; return 1; }
    grep -q '^## Expected signals$' "$f" || { echo "$f missing ## Expected signals" >&2; return 1; }
    grep -q '^## Anti-signals$' "$f" || { echo "$f missing ## Anti-signals" >&2; return 1; }
    grep -q '^## Leak guard$' "$f" || { echo "$f missing ## Leak guard" >&2; return 1; }
  done
}

@test "prompt fixtures T00..T11 have non-empty Expected/Anti/Leak guard sections" {
  local i f section body
  for i in "${EXPECTED_FIXTURE_IDS[@]}"; do
    f="$(resolve_fixture "$i")" || return 1
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

# T02 fixture content guard (plan v3 mandatory #1 follow-up):
# the Leak guard section must explicitly mention the literal `<HARD-GATE>`
# token so silent removal of the "do not paste the tag block" instruction
# in the fixture fails CI.
@test "T02 fixture Leak guard section pins the <HARD-GATE> token" {
  local f body
  f="$(resolve_fixture 02)" || return 1
  body="$(awk '
    $0 == "## Leak guard" { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec { print }
  ' "$f")"
  echo "$body" | grep -q '<HARD-GATE>'
}
