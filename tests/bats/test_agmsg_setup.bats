#!/usr/bin/env bats
# shellcheck shell=bash
# Tests for .chezmoiscripts/run_after_setup-agmsg.sh — specifically the Codex
# config-drift guard that decides whether the third-party agmsg installer
# changed ~/.codex/config.toml beyond the three allowed writable_roots
# (db/teams/run). The install flow itself (git clone + bash install.sh) is
# network-bound and not exercised here; these tests source the script
# (AGMSG_SETUP_SOURCE_ONLY=1) and drive the extracted guard functions directly so
# the allow-list semantics and BOTH fail-loud paths (unexpected change, broken
# comparison) cannot silently regress.

bats_require_minimum_version 1.5.0

setup() {
  # bats preprocesses .bats files into /tmp; resolve the repo via
  # BATS_TEST_FILENAME (the original path) rather than BASH_SOURCE.
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/.chezmoiscripts/run_after_setup-agmsg.sh"
  AGMSG_REF="$(sed -n 's/^AGMSG_REF="\([^"]*\)"/\1/p' "$SCRIPT")"
  export REPO_ROOT SCRIPT AGMSG_REF

  # The guard compares skill_dir against diff content, so this path need not
  # exist on disk.
  SKILL_DIR="$BATS_TEST_TMPDIR/.agents/skills/agmsg"
  BEFORE="$BATS_TEST_TMPDIR/before.toml"
  AFTER="$BATS_TEST_TMPDIR/after.toml"
  export SKILL_DIR BEFORE AFTER
}

# Run one of the sourced guard functions in an isolated POSIX-sh subshell so the
# script's `set -eu` never leaks into the bats harness, matching production's
# /bin/sh interpreter rather than bash.
run_guard() {
  run sh -c 'AGMSG_SETUP_SOURCE_ONLY=1 . "$1"; "$2" "$3" "$4" "$5"' \
    _ "$SCRIPT" "$1" "$2" "$3" "$4"
}

# The realistic allowed delta: the installer adds the sandbox header plus an
# inline writable_roots array naming exactly the three agmsg runtime dirs (the
# format the pinned installer actually writes).
write_allowed_after() {
  : > "$BEFORE"
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf 'writable_roots = ["%s/db", "%s/teams", "%s/run"]\n' \
      "$SKILL_DIR" "$SKILL_DIR" "$SKILL_DIR"
  } > "$AFTER"
}

write_installed_agmsg_home() {
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_SKILL_DIR="$TEST_HOME/.agents/skills/agmsg"
  TEST_CODEX_CONFIG="$TEST_HOME/.codex/config.toml"
  mkdir -p "$TEST_SKILL_DIR" "$TEST_HOME/.codex"
  : > "$TEST_SKILL_DIR/.agmsg"
  printf '%s\n' "$AGMSG_REF" > "$TEST_SKILL_DIR/.dotfiles-agmsg-ref"
  export TEST_HOME TEST_SKILL_DIR TEST_CODEX_CONFIG
}

write_live_codex_roots() {
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf 'writable_roots = ["%s/db", "%s/teams", "%s/run"]\n' \
      "$TEST_SKILL_DIR" "$TEST_SKILL_DIR" "$TEST_SKILL_DIR"
  } > "$TEST_CODEX_CONFIG"
}

run_setup_script() {
  run env HOME="$TEST_HOME" sh "$SCRIPT"
}

write_git_stub_for_install() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/git" <<'STUB'
#!/bin/sh
if [ "$1" = "clone" ]; then
  clone_dir=$4
  mkdir -p "$clone_dir"
  cat > "$clone_dir/install.sh" <<'INSTALL'
#!/bin/sh
exit 0
INSTALL
  chmod +x "$clone_dir/install.sh"
  exit 0
fi
if [ "$1" = "-C" ] && [ "$3" = "checkout" ]; then
  exit 0
fi
if [ "$1" = "-C" ] && [ "$3" = "rev-parse" ]; then
  printf '%s\n' "$AGMSG_REF"
  exit 0
fi
printf '%s\n' "unexpected git stub invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/git"
  export STUB_BIN
}

run_setup_script_with_stubbed_git() {
  run env HOME="$TEST_HOME" PATH="$STUB_BIN:$PATH" AGMSG_REF="$AGMSG_REF" sh "$SCRIPT"
}

@test "classify: only the three agmsg writable_roots added -> no unexpected lines" {
  write_allowed_after
  run_guard classify_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classify: existing writable_root preserved while agmsg roots are added -> no unexpected lines" {
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf '%s\n' 'writable_roots = ["/existing"]'
  } > "$BEFORE"
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf 'writable_roots = ["/existing", "%s/db", "%s/teams", "%s/run"]\n' \
      "$SKILL_DIR" "$SKILL_DIR" "$SKILL_DIR"
  } > "$AFTER"
  run_guard classify_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classify: a foreign config change -> reported as an unexpected line" {
  write_allowed_after
  printf 'disable_network = false\n' >> "$AFTER"
  run_guard classify_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"disable_network = false"* ]]
}

@test "classify: a foreign writable_root -> reported as an unexpected line" {
  : > "$BEFORE"
  printf 'writable_roots = ["/"]\n' > "$AFTER"
  run_guard classify_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'writable_roots = ["/"]'* ]]
}

@test "classify: incomplete agmsg writable_roots -> reported as an unexpected line" {
  : > "$BEFORE"
  printf 'writable_roots = ["%s/db"]\n' "$SKILL_DIR" > "$AFTER"
  run_guard classify_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"writable_roots"* ]]
}

@test "classify: removing an existing writable_root -> reported as unexpected" {
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf 'writable_roots = ["/existing", "%s/db", "%s/teams", "%s/run"]\n' \
      "$SKILL_DIR" "$SKILL_DIR" "$SKILL_DIR"
  } > "$BEFORE"
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf 'writable_roots = ["%s/db", "%s/teams", "%s/run"]\n' \
      "$SKILL_DIR" "$SKILL_DIR" "$SKILL_DIR"
  } > "$AFTER"
  run_guard classify_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/existing"* ]]
}

@test "classify: an unreadable snapshot (diff trouble) -> return code 2" {
  write_allowed_after
  run_guard classify_codex_config_drift "$BATS_TEST_TMPDIR/missing.toml" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 2 ]
}

@test "assert: allowed-only delta -> exit 0, no output" {
  write_allowed_after
  run_guard assert_no_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "assert: foreign config change -> fail loud (exit 1) listing the line" {
  write_allowed_after
  printf 'disable_network = false\n' >> "$AFTER"
  run_guard assert_no_codex_config_drift "$BEFORE" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed ~/.codex/config.toml unexpectedly"* ]]
  [[ "$output" == *"disable_network = false"* ]]
}

@test "assert: diff trouble (unreadable snapshot) -> fail loud (exit 1), not silent pass" {
  write_allowed_after
  run_guard assert_no_codex_config_drift "$BATS_TEST_TMPDIR/missing.toml" "$AFTER" "$SKILL_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to compare ~/.codex/config.toml"* ]]
}

@test "setup: pinned install fast path succeeds only when live Codex roots are present" {
  write_installed_agmsg_home
  write_live_codex_roots
  run_setup_script
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "setup: pinned install fast path fails loud when live Codex roots are missing" {
  write_installed_agmsg_home
  : > "$TEST_CODEX_CONFIG"
  run_setup_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing one or more required agmsg writable_roots"* ]]
}

@test "setup: pinned install fast path fails loud when roots are only comments" {
  write_installed_agmsg_home
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf '# writable_roots = ["%s/db", "%s/teams", "%s/run"]\n' \
      "$TEST_SKILL_DIR" "$TEST_SKILL_DIR" "$TEST_SKILL_DIR"
  } > "$TEST_CODEX_CONFIG"
  run_setup_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing one or more required agmsg writable_roots"* ]]
}

@test "setup: pinned install fast path fails loud when roots are only an inline comment" {
  write_installed_agmsg_home
  {
    printf '%s\n' '[sandbox_workspace_write]'
    printf 'writable_roots = [] # ["%s/db", "%s/teams", "%s/run"]\n' \
      "$TEST_SKILL_DIR" "$TEST_SKILL_DIR" "$TEST_SKILL_DIR"
  } > "$TEST_CODEX_CONFIG"
  run_setup_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing one or more required agmsg writable_roots"* ]]
}

@test "setup: pinned install fast path fails loud when roots are in the wrong table" {
  write_installed_agmsg_home
  {
    printf '%s\n' '[sandbox_workspace_write_disabled]'
    printf 'writable_roots = ["%s/db", "%s/teams", "%s/run"]\n' \
      "$TEST_SKILL_DIR" "$TEST_SKILL_DIR" "$TEST_SKILL_DIR"
  } > "$TEST_CODEX_CONFIG"
  run_setup_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing one or more required agmsg writable_roots"* ]]
}

@test "setup: install path fails loud when installer omits Codex roots" {
  write_installed_agmsg_home
  rm -f "$TEST_SKILL_DIR/.agmsg" "$TEST_SKILL_DIR/.dotfiles-agmsg-ref"
  : > "$TEST_CODEX_CONFIG"
  write_git_stub_for_install
  run_setup_script_with_stubbed_git
  [ "$status" -eq 1 ]
  [[ "$output" == *"installer completed, but ~/.codex/config.toml is missing"* ]]
  [ ! -f "$TEST_SKILL_DIR/.dotfiles-agmsg-ref" ]
}
