#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/private_dot_codex/skills/pr-review-coach"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  CLEANUP_SCRIPT="$SKILL_DIR/scripts/cleanup-state.sh"
  STATE_ROOT="$BATS_TEST_TMPDIR/state"
  export REPO_ROOT SKILL_DIR SKILL_MD CLEANUP_SCRIPT STATE_ROOT
}

make_state_file() {
  local repo_key="$1" name="$2" stamp="$3"
  local dir="$STATE_ROOT/repos/$repo_key"
  mkdir -p "$dir"
  local file="$dir/$name.md"
  printf 'state: %s\n' "$name" > "$file"
  touch -t "$stamp" "$file"
  printf '%s\n' "$file"
}

@test "pr-review-coach cleanup script exists" {
  [ -f "$CLEANUP_SCRIPT" ]
  bash -n "$CLEANUP_SCRIPT"
}

@test "cleanup-state deletes expired files but preserves current file" {
  local expired current
  expired="$(make_state_file repo-a old 202001010000)"
  current="$(make_state_file repo-a current 202001010001)"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 30 \
    --max-files-per-repo 20 \
    --current "$current"

  [ "$status" -eq 0 ]
  [ ! -e "$expired" ]
  [ -e "$current" ]
}

@test "cleanup-state keeps newest N files per repo" {
  local old mid new
  old="$(make_state_file repo-a old 202601010000)"
  mid="$(make_state_file repo-a mid 202601010100)"
  new="$(make_state_file repo-a new 202601010200)"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 99999 \
    --max-files-per-repo 2

  [ "$status" -eq 0 ]
  [ ! -e "$old" ]
  [ -e "$mid" ]
  [ -e "$new" ]
}

@test "cleanup-state dry-run reports deletions without deleting" {
  local expired
  expired="$(make_state_file repo-a old 202001010000)"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 30 \
    --max-files-per-repo 20 \
    --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete $expired"* ]]
  [ -e "$expired" ]
}

@test "SKILL.md stores state outside the target worktree and delegates pruning to script" {
  grep -q 'XDG_STATE_HOME' "$SKILL_MD"
  grep -q 'scripts/cleanup-state.sh' "$SKILL_MD"
  ! grep -q 'State directory: `.codex/pr-review-coach/`' "$SKILL_MD"
}

@test "SKILL.md allows answer continuation without --base only from one current state file" {
  grep -q 'explicit `--base <ref-or-commit>` on the first turn' "$SKILL_MD"
  grep -q 'If `--base` is missing, treat the prompt as an answer continuation' "$SKILL_MD"
  grep -Fq 'Find state files matching `$STATE_DIR/*-$HEAD_SHORT.md`' "$SKILL_MD"
  grep -q 'If multiple matching state files exist' "$SKILL_MD"
  grep -q '`status`: `active` or `complete`' "$SKILL_MD"
  grep -q 'abort if `status` is not `active`' "$SKILL_MD"
  grep -q 'set `status: complete`' "$SKILL_MD"
  grep -q 'current_question' "$SKILL_MD"
  ! grep -q 'If it is missing, stop and ask the user to rerun with `--base`' "$SKILL_MD"
}

@test "SKILL.md fail-closes when context collection commands fail" {
  grep -q 'Run each command independently' "$SKILL_MD"
  grep -q 'If any command fails, abort with the command output' "$SKILL_MD"
  grep -q 'do not continue with partial context' "$SKILL_MD"
}
