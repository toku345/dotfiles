#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  BREW_TOOL="$REPO_ROOT/dot_local/bin/executable_brew-reviewed-upgrade"
  GHOSTTY_TOOL="$REPO_ROOT/dot_local/bin/executable_ghostty-theme"
  PREVIEW_TOOL="$REPO_ROOT/dot_local/bin/executable_ghostty-theme-preview"
  README_FILE="$REPO_ROOT/README.md"
  BACKUP_RESTORE_FILE="$REPO_ROOT/docs/backup-restore.md"
  resolve_bash5
}

@test "managed Bash tools enforce exactly Bash 5 or newer" {
  local tool

  for tool in "$BREW_TOOL" "$GHOSTTY_TOOL" "$PREVIEW_TOOL"; do
    run grep -Fxc 'if (( BASH_VERSINFO[0] < 5 )); then' "$tool"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]

    run grep -F 'bash 4+' "$tool"
    [ "$status" -eq 1 ]
  done
}

@test "macOS bootstrap documents Bash 5 while Linux bootstrap stays unchanged" {
  run grep -Fxc '   brew install age bash' "$README_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  run grep -Fxc '   brew install chezmoi age bash' "$BACKUP_RESTORE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]

  run grep -Fxc 'brew install chezmoi age' "$BACKUP_RESTORE_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "Bash 5 executes each managed tool help path" {
  local tool

  for tool in "$BREW_TOOL" "$GHOSTTY_TOOL" "$PREVIEW_TOOL"; do
    run "$BASH5_BIN" "$tool" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done
}

@test "macOS system Bash rejects each managed tool before argument processing" {
  local system_major
  local tool
  local tool_name

  [[ "$(uname -s)" == Darwin ]] || \
    skip "macOS production fallback uses /bin/bash 3.2; Linux system Bash is supported"

  system_major="$(/bin/bash -c 'printf "%s\n" "${BASH_VERSINFO[0]}"')"
  (( system_major < 5 )) || skip "this macOS image no longer provides an old system Bash"

  for tool in "$BREW_TOOL" "$GHOSTTY_TOOL" "$PREVIEW_TOOL"; do
    tool_name="${tool##*/executable_}"
    run /bin/bash "$tool" --help
    [ "$status" -eq 2 ]
    [[ "$output" == *"$tool_name"* ]]
    [[ "$output" == *"requires bash 5+"* ]]
    [[ "$output" == *"brew install bash"* ]]
  done
}
