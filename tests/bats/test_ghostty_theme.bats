#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  standard_env
}

# --- positional argument cases ---------------------------------------------

@test "TestDark: OSC output matches snapshot" {
  run ghostty-theme TestDark
  [ "$status" -eq 0 ]
  assert_snapshot "TestDark OSC" "$output" "$SNAPSHOTS_DIR/ghostty-theme/TestDark.expected"
}

@test "TestMinimal: palette-only OSC output matches snapshot" {
  run ghostty-theme TestMinimal
  [ "$status" -eq 0 ]
  assert_snapshot "TestMinimal OSC" "$output" "$SNAPSHOTS_DIR/ghostty-theme/TestMinimal.expected"
}

@test "TestMixed: mixed theme (comments, ws, 5-hex invalid) matches snapshot" {
  run ghostty-theme TestMixed
  [ "$status" -eq 0 ]
  assert_snapshot "TestMixed OSC" "$output" "$SNAPSHOTS_DIR/ghostty-theme/TestMixed.expected"
}

@test "applied message includes theme name" {
  run ghostty-theme TestDark
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied 'TestDark'"* ]]
}

@test "missing theme returns exit 1 and mentions not found" {
  run ghostty-theme NoSuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"theme 'NoSuch' not found"* ]]
}

@test "theme name with spaces: OSC output matches snapshot" {
  run ghostty-theme "Test Spaces"
  [ "$status" -eq 0 ]
  assert_snapshot "TestSpaces OSC" "$output" "$SNAPSHOTS_DIR/ghostty-theme/TestSpaces.expected"
}

@test "5-hex palette=2 in TestMixed is skipped (not emitted as OSC)" {
  run ghostty-theme TestMixed
  [ "$status" -eq 0 ]
  # The invalid `palette = 2=#12345` must NOT produce OSC 4;2
  [[ "$output" != *$'\e]4;2;#'* ]]
}

# --- fzf interactive path --------------------------------------------------

@test "fzf stub selection: applied with exit 0" {
  export FAKE_FZF_SELECT=TestDark
  export FAKE_FZF_EXIT=0
  run ghostty-theme
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied 'TestDark'"* ]]
}

@test "fzf stub cancel (130): parent exits 0 without OSC" {
  export FAKE_FZF_EXIT=130
  run ghostty-theme
  [ "$status" -eq 0 ]
  # No OSC 4;/11;/10;/12;/17;/19 sequences should have been emitted
  [[ "$output" != *$'\e]'* ]]
}

@test "fzf stub no-match (1): parent exits 0 without OSC" {
  export FAKE_FZF_EXIT=1
  run ghostty-theme
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\e]'* ]]
}

@test "ghostty stub is invoked via PATH even if a shell function 'ghostty' is defined" {
  # Equivalent in spirit to the fish `command ls` guard: verify that
  # ghostty-theme resolves `ghostty` through PATH (our stub), not through
  # a shell function that might be defined in the caller's environment.
  # Since ghostty-theme runs in its own subshell, a shell function in the
  # bats process cannot hijack it; but we still run a positive smoke test
  # here so that any future change to how ghostty is invoked is caught.
  ghostty() { echo POISONED; }
  export -f ghostty || true
  run ghostty-theme TestDark
  [ "$status" -eq 0 ]
  [[ "$output" != *POISONED* ]]
  [[ "$output" == *"applied 'TestDark'"* ]]
}

# --- user/resources precedence (D1 / D2 / D3) ------------------------------

@test "D1: duplicate name without user dir -> resources path applied (#111111)" {
  run ghostty-theme TestDuplicate
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e]11;#111111\e\\'* ]]
  [[ "$output" != *$'\e]11;#222222\e\\'* ]]
}

@test "D2: duplicate name with user dir -> user path overrides (#222222)" {
  export GHOSTTY_TEST_USER_THEMES_DIR="$FIXTURES_DIR/user_themes"
  run ghostty-theme TestDuplicate
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\e]11;#222222\e\\'* ]]
  [[ "$output" != *$'\e]11;#111111\e\\'* ]]
}

@test "D3: fzf path with duplicate -> name appears once in fzf stdin, user path applied" {
  export GHOSTTY_TEST_USER_THEMES_DIR="$FIXTURES_DIR/user_themes"
  local log_file="$SCRATCH_DIR/fzf-stdin-D3.log"
  export FAKE_FZF_STDIN_LOG="$log_file"
  export FAKE_FZF_SELECT=TestDuplicate
  export FAKE_FZF_EXIT=0
  run ghostty-theme
  [ "$status" -eq 0 ]
  local logged
  logged="$(cat "$log_file")"
  rm -f "$log_file"
  # TestDuplicate must appear exactly once in the fzf input (dedup works)
  local count
  count="$(grep -c '^TestDuplicate$' <<< "$logged" || true)"
  [ "$count" -eq 1 ]
  # And user's #222222 must be the applied value
  [[ "$output" == *$'\e]11;#222222\e\\'* ]]
}

# --- discovery fail-loud (F1 / F2) -----------------------------------------

@test "F1: ghostty +list-themes failure surfaces as non-zero exit with diagnostic" {
  export GHOSTTY_STUB_FAIL=1
  run ghostty-theme TestDark
  [ "$status" -ne 0 ]
  [[ "$output" == *'"ghostty +list-themes" failed'* ]]
}

@test "F2: ghostty binary missing from PATH -> exit 127 with diagnostic" {
  # Rebuild PATH to exclude both stubs and any real ghostty, while keeping
  # whichever dir provides the bash interpreter (so `env bash` in the script
  # shebang doesn't fall back to macOS system bash 3.2).
  local bash_dir
  bash_dir="$(dirname "$(command -v bash)")"
  PATH="$LIVE_BIN:$bash_dir:/usr/bin:/bin" run -127 ghostty-theme TestDark
  [ "$status" -eq 127 ]
  [[ "$output" == *"'ghostty' CLI not found"* ]] || [[ "$output" == *"ghostty"*"not found"* ]]
}

# --- validate-config failure -----------------------------------------------

@test "validate-config failure: non-zero exit, no OSC emitted" {
  export GHOSTTY_STUB_VALIDATE_FAIL=1
  run ghostty-theme TestDark
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed validation"* ]]
  [[ "$output" != *$'\e]4;0'* ]]
}

# --- --help ---------------------------------------------------------------

@test "--help prints usage and exits 0" {
  run ghostty-theme --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ghostty-theme"* ]]
}
