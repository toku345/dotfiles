#!/usr/bin/env bats
# shellcheck shell=bash
# Tests for .claude/hooks/* — Stop hook (verify-on-stop.sh) and PostToolUse
# hook (fish-syntax-check.sh). These hooks gate Claude Code's stop event and
# editor writes, so silent failures here defeat the verification loop.

bats_require_minimum_version 1.5.0

setup() {
  # bats preprocesses .bats files into /tmp; BASH_SOURCE[0] at the test scope
  # points there, so resolve the repo via BATS_TEST_FILENAME (the original
  # path) instead of BASH_SOURCE.
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  HOOK_VERIFY="$REPO_ROOT/.claude/hooks/verify-on-stop.sh"
  export REPO_ROOT HOOK_VERIFY

  # Per-test scratch project. CLAUDE_PROJECT_DIR isolates the hook from the
  # real chezmoi worktree so tests never touch repo-level state.
  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
}

# -----------------------------------------------------------------------------
# C1 regression: git enumeration must fail loud, not silently allow stop.
#
# Before the fix, `mapfile -t changed < <({ git diff; git ls-files; } | sort)`
# swallowed git failures because process substitution does not propagate the
# producer's exit status to the parent under set -Eeuo pipefail. A broken git
# repo therefore produced empty `changed[]` → all gates skipped → exit 0 +
# counter reset, masking the broken state and bypassing verification.
# -----------------------------------------------------------------------------

@test "C1: git diff HEAD failure causes block (was silent fail-open)" {
  # Fresh repo with zero commits → `git diff --name-only HEAD` exits non-zero
  # ("fatal: bad revision 'HEAD'"). This is the realistic broken-state case.
  git init -q "$PROJECT_DIR"

  # A file matching one of the gate-relevant globs ensures that on a healthy
  # repo the hook would run gates. Without this, a passing test could not
  # distinguish "skipped because no relevant changes" from "skipped because
  # git failed silently".
  mkdir -p "$PROJECT_DIR/tests/bats"
  touch "$PROJECT_DIR/tests/bats/dummy.bats"
  git -C "$PROJECT_DIR" add tests/bats/dummy.bats

  run "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"git enumeration failed"* ]]
}
