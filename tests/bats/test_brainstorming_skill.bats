#!/usr/bin/env bats
# shellcheck shell=bash
# Tests for private_dot_claude/skills/brainstorming/{SKILL.md, references/*,
# LICENSE.superpowers} and tests/skills/brainstorming/prompts/T00..T11.
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

# Print the body lines under `## $section` in $file, stopping at the next
# `## ` heading or EOF. Used by multiple tests that need to scope a substring
# check to a single section so a stray match elsewhere cannot silently pass.
extract_h2_body() {
  local file="$1" section="$2"
  awk -v sec="## $section" '
    $0 == sec { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec { print }
  ' "$file"
}

# -----------------------------------------------------------------------------
# SKILL.md structural guards
#
# ADR 0022's whole point is that SKILL.md stays small, because every line is a
# recurring token cost in the rendered context. ~80 lines is the regression
# ceiling enforced here; ADR 0022's target is a ~50-line core.
# -----------------------------------------------------------------------------

@test "SKILL.md exists and is within 20-80 line bounds" {
  [ -f "$SKILL_MD" ]
  local n
  # awk NR matches ADR 0022's documented line-count unit (robust to files
  # without a trailing newline, unlike `wc -l`).
  n="$(awk 'END{print NR}' "$SKILL_MD")"
  # Floor guards against silent truncation; ceiling enforces the ADR 0022
  # progressive-disclosure target (~50 line core).
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
# failure modes documented in ADR 0022 can recur.
@test "SKILL.md top 15 body lines contain a HARD-GATE tag line" {
  local body
  body="$(awk '
    /^# Brainstorming Ideas Into Designs/ { found=1; next }
    found && c < 15 { print; c++ }
  ' "$SKILL_MD")"
  # Anchor on a real `<HARD-GATE>...</HARD-GATE>` tag line, not a substring
  # token. The literal token also appears inside the Pre-send self-check
  # rule, so substring matching would silently pass even if the real
  # HARD-GATE block were deleted.
  echo "$body" | grep -qE '^<HARD-GATE>.*</HARD-GATE>$'
}

# Pre/post-design HARD-GATE pair: the brainstorming flow is framed by exactly
# two HARD-GATE blocks — pre-design (no code before approval) and post-design
# (no code before plan mode). The T11 dogfooding on PR #211 showed that a
# closing prose sentence (without HARD-GATE tagging) loses to a user-global
# "軽く扱ってよい対象" off-ramp, while the HARD-GATE-tagged pre-design rule
# holds. The symmetric HARD-GATE applies the same pattern to the post-design
# boundary. Enforce exactly two so accidental third / removed second fails CI.
@test "SKILL.md contains exactly two <HARD-GATE>...</HARD-GATE> tag lines (pre-design + post-design)" {
  local count
  count="$(grep -cE '^<HARD-GATE>.*</HARD-GATE>$' "$SKILL_MD")"
  [ "$count" -eq 2 ]
}

# Post-design HARD-GATE content guard (T11 invariant). The 2nd HARD-GATE line
# must pin three properties so dropping any one fails CI:
#   1. "plan mode" — the named handoff target
#   2. "regardless of task triviality" — closes the trivial-task off-ramp
#   3. "軽く扱ってよい対象" — explicit reference to the user-global classification
#      that the T11 dogfooding showed the assistant invokes as an override
@test "SKILL.md post-design HARD-GATE pins unconditional plan-mode handoff (T11 invariant)" {
  local second_hg
  second_hg="$(grep -E '^<HARD-GATE>.*</HARD-GATE>$' "$SKILL_MD" | sed -n '2p')"
  [ -n "$second_hg" ] || { echo "post-design HARD-GATE missing" >&2; return 1; }
  echo "$second_hg" | grep -q 'plan mode'
  echo "$second_hg" | grep -q 'regardless of task triviality'
  echo "$second_hg" | grep -q '軽く扱ってよい対象'
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

# T02 leak-guard regression: the assistant must paraphrase HARD-GATE on
# refusal, never paste the literal `<HARD-GATE>...</HARD-GATE>` tag block.
# Pasting the literal tag leaks skill internals to the user. Pin the
# instruction here so silent removal of the paraphrase rule fails CI.
@test "SKILL.md T02 invariant — HARD-GATE refusal must paraphrase, not paste tag block" {
  grep -q 'paraphrase the rule' "$SKILL_MD"
  grep -q 'never paste the literal' "$SKILL_MD"
  grep -q '<HARD-GATE>' "$SKILL_MD"
}

# Section-scoped pin: the three tokens above must all live inside the
# Pre-send self-check paragraph, not as orphaned strings elsewhere in the
# file. If the paragraph is removed but the tokens leak into unrelated
# sections, the three independent greps above would still pass — this gate
# fails that silent drift. Pre-send self-check uses a blank-line terminator,
# so this section extractor differs from extract_h2_body() and stays inline.
@test "SKILL.md Pre-send self-check section contains the paraphrase rule tokens" {
  local section
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

# Post-design no-code boundary: the rule must live in the always-loaded
# SKILL.md body so a model that never loads references/after-design.md still
# refuses code after design approval. Now HARD-GATE-tagged (PR #211 T11
# dogfooding evidence) — see the "exactly two HARD-GATE" guard above.
@test "SKILL.md contains post-design no-code boundary" {
  grep -q 'until the user enters plan mode' "$SKILL_MD"
}

# SSOT sync: references/after-design.md must carry the same handoff sentence
# as SKILL.md so the two control planes (always-loaded vs. on-demand) cannot
# drift. SKILL.md is the SSOT; the reference quotes it.
@test "references/after-design.md mirrors the SKILL.md post-design handoff" {
  grep -q 'until the user enters plan mode' "$REF_DIR/after-design.md"
}

# Safety rules: non-negotiable commit-path guards must live in the
# always-loaded SKILL.md body, not solely in references/after-design.md.
# The reference side is gated by the "mirrors SKILL.md ..." tests below so
# the two control planes cannot drift.
@test "SKILL.md safety rules — detached HEAD refusal" {
  grep -qi 'detached HEAD' "$SKILL_MD"
}

@test "SKILL.md safety rules — default branch detection chain" {
  # Two-layer chain: origin/HEAD primary detect + main/master/trunk/develop
  # fallback list in canonical order. The reference (after-design.md) must
  # mirror both layers — see the matching mirror tests below.
  grep -q 'origin/HEAD' "$SKILL_MD"
  grep -qE '\bmain\b.*\bmaster\b.*\btrunk\b.*\bdevelop\b' "$SKILL_MD"
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
# SKILL.md is the SSOT for the safety rules; the mirror tests here enforce
# that the on-demand reference cannot drift from the always-loaded core.
# -----------------------------------------------------------------------------

@test "references/after-design.md T09 invariant — ADR template four sections with bodies" {
  # Heading-only checks (AGENTS.md "fixture content-presence" gotcha): a file
  # with all four headings but empty bodies would pass. Extract each section
  # body and require at least one non-blank content line under each heading.
  local section body
  for section in 'Status' 'Context' 'Decision' 'Consequences'; do
    body="$(extract_h2_body "$REF_DIR/after-design.md" "$section")"
    echo "$body" | grep -qE '[^[:space:]]' \
      || { echo "ADR template section '$section' has empty body" >&2; return 1; }
  done
}

@test "references/after-design.md T09 invariant — auto-detect ADR directory" {
  grep -q 'Auto-detect ADR directory' "$REF_DIR/after-design.md"
}

@test "references/after-design.md mirrors SKILL.md detached HEAD safety rule" {
  grep -qi 'detached HEAD' "$REF_DIR/after-design.md"
}

@test "references/after-design.md mirrors SKILL.md default branch fallback chain" {
  local f="$REF_DIR/after-design.md"
  # Both layers pinned independently so a collapse into a single regex
  # cannot silently hide regressions where the primary detect is removed
  # but the fallback list survives, or vice versa. The single-regex match
  # on layer 2 also pins ordering, so a wrong-order fallback fails CI.
  grep -q 'origin/HEAD' "$f"
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
# EXPECTED_FIXTURE_IDS is the single source of truth for the on-disk fixture
# set. Tests enforce two properties against actual T??_*.md files: (1) exact
# match (no missing / extra / silently renamed); (2) no duplicates (no two
# files share the same T?? prefix). It is file-scoped because bats runs
# setup() per-test and we want one shared constant, not 12 per-test copies.
#
# Heading-presence catches a missing fixture or a renamed section.
# Content-presence catches a fixture that has all five headings but empty
# bodies — without content the fixture cannot drive fresh-session evaluation.
# -----------------------------------------------------------------------------

EXPECTED_FIXTURE_IDS=(00 01 02 03 04 05 06 07 08 09 10 11)

@test "prompt fixtures: on-disk set matches EXPECTED_FIXTURE_IDS exactly" {
  local found_ids=()
  local f base id
  # Parse the T??_ prefix from `find` output instead of relying on shell glob
  # expansion (which depends on nullglob / dotglob state).
  while IFS= read -r f; do
    base="$(basename "$f")"
    id="${base#T}"
    id="${id%%_*}"
    found_ids+=("$id")
  done < <(find "$PROMPTS_DIR" -maxdepth 1 -type f -name 'T*_*.md' | sort)

  local expected_sorted found_unique found_unique_count
  expected_sorted="$(printf '%s\n' "${EXPECTED_FIXTURE_IDS[@]}" | sort -u)"
  found_unique="$(printf '%s\n' "${found_ids[@]}" | sort -u)"
  found_unique_count="$(printf '%s\n' "$found_unique" | wc -l)"

  if [ "${#found_ids[@]}" -ne "$found_unique_count" ]; then
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

# Resolve a single fixture file for a given T${i} ID. nullglob is scoped to
# a subshell so the option does not leak into the surrounding test process.
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
      # Require at least one bullet line (`- text`) in the section body.
      body="$(extract_h2_body "$f" "$section")"
      echo "$body" | grep -qE '^[[:space:]]*-[[:space:]]+[^[:space:]]' \
        || { echo "$f section '$section' has no bullet" >&2; return 1; }
    done
  done
}

# T02 fixture content guard: the Leak guard section must explicitly mention
# the literal `<HARD-GATE>` token so silent removal of the "do not paste the
# tag block" instruction in the fixture fails CI.
@test "T02 fixture Leak guard section pins the <HARD-GATE> token" {
  local f body
  f="$(resolve_fixture 02)" || return 1
  body="$(extract_h2_body "$f" "Leak guard")"
  echo "$body" | grep -q '<HARD-GATE>'
}
