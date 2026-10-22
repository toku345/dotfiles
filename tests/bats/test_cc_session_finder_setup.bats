#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/.chezmoiscripts/run_after_setup-cc-session-finder.sh"
  PINNED_REF="$(sed -n 's/^CC_SESSION_FINDER_REF="\([^"]*\)"/\1/p' "$SCRIPT")"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$TEST_HOME" "$STUB_BIN"
  export SCRIPT
}

run_setup() {
  run env -u CARGO_HOME -u CARGO_INSTALL_ROOT -u CC_SESSION_FINDER_REINSTALL HOME="$TEST_HOME" PATH="$STUB_BIN:/usr/bin:/bin" "$@" sh "$SCRIPT"
}

write_finder_stub() {
  local binary_path="${1:-$TEST_HOME/.cargo/bin/cc-session-finder}"
  mkdir -p "${binary_path%/*}"
  printf '#!/bin/sh\nexit 0\n' > "$binary_path"
  chmod +x "$binary_path"
}

write_cargo_stub_installing_binary() {
  _cargo_path="${1:-$STUB_BIN/cargo}"
  cat > "$_cargo_path" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/cargo.args"
install_root="$HOME/.cargo"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--root" ]; then
    shift
    install_root=$1
    break
  fi
  shift
done
mkdir -p "$install_root/bin"
cat > "$install_root/bin/cc-session-finder" <<'BIN'
#!/bin/sh
exit 0
BIN
chmod +x "$install_root/bin/cc-session-finder"
STUB
  chmod +x "$_cargo_path"
}

write_cargo_stub_success_without_binary() {
  cat > "$STUB_BIN/cargo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/cargo.args"
exit 0
STUB
  chmod +x "$STUB_BIN/cargo"
}

write_cargo_stub_failure() {
  cat > "$STUB_BIN/cargo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/cargo.args"
exit 1
STUB
  chmod +x "$STUB_BIN/cargo"
}

write_client_stub() {
  cat > "$STUB_BIN/$1" <<'STUB'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$HOME/clients.log"
exit 99
STUB
  chmod +x "$STUB_BIN/$1"
}

@test "PATH binary is reused when the managed binary is absent" {
  write_finder_stub "$STUB_BIN/cc-session-finder"

  run env -u CARGO_HOME -u CARGO_INSTALL_ROOT HOME="$TEST_HOME" PATH="$STUB_BIN:/usr/bin:/bin" CC_SESSION_FINDER_SETUP_SOURCE_ONLY=1 sh -c '. "$SCRIPT"; find_cc_session_finder'
  [ "$status" -eq 0 ]
  [ "$output" = "$STUB_BIN/cc-session-finder" ]

  run_setup
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.cargo/bin/cc-session-finder" ]
}

@test "CARGO_HOME selects the install root unless CARGO_INSTALL_ROOT overrides it" {
  write_cargo_stub_installing_binary

  run_setup CARGO_HOME="$TEST_HOME/cargo-home"
  [ "$status" -eq 0 ]
  [ -x "$TEST_HOME/cargo-home/bin/cc-session-finder" ]

  run_setup CARGO_HOME="$TEST_HOME/cargo-home" CARGO_INSTALL_ROOT="$TEST_HOME/install-root"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--root $TEST_HOME/install-root"* ]]
  [ -x "$TEST_HOME/install-root/bin/cc-session-finder" ]
}

@test "missing binary and missing cargo -> skip without blocking apply" {
  run_setup

  [ "$status" -eq 0 ]
  [[ "$output" == *"cc-session-finder CLI setup skipped"* ]]
}

@test "missing binary with cargo -> install pinned revision" {
  write_cargo_stub_installing_binary

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--locked"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--git https://github.com/jugyo/cc-session-finder.git"* ]]
  [ -x "$TEST_HOME/.cargo/bin/cc-session-finder" ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--root $TEST_HOME/.cargo"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" != *"--force"* ]]
}

@test "custom CARGO_INSTALL_ROOT -> install at custom managed path" {
  custom_root="$TEST_HOME/custom-cargo"
  write_cargo_stub_installing_binary

  run_setup CARGO_INSTALL_ROOT="$custom_root"

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--root $custom_root"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" != *"--force"* ]]
  [ -x "$custom_root/bin/cc-session-finder" ]
}

@test "managed binary with cargo -> normal setup does not reinstall" {
  write_finder_stub
  write_cargo_stub_installing_binary

  run_setup

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/cargo.args" ]
}

@test "managed binary takes precedence over a PATH binary" {
  write_finder_stub "$STUB_BIN/cc-session-finder"
  write_finder_stub

  run env -u CARGO_HOME -u CARGO_INSTALL_ROOT HOME="$TEST_HOME" PATH="$STUB_BIN:/usr/bin:/bin" CC_SESSION_FINDER_SETUP_SOURCE_ONLY=1 sh -c '. "$SCRIPT"; find_cc_session_finder'

  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_HOME/.cargo/bin/cc-session-finder" ]
}

@test "explicit reinstall -> force pinned revision" {
  write_finder_stub
  write_cargo_stub_installing_binary

  run_setup CC_SESSION_FINDER_REINSTALL=1

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--root $TEST_HOME/.cargo"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--force"* ]]
}

@test "explicit reinstall with custom CARGO_INSTALL_ROOT -> install at custom managed path" {
  custom_root="$TEST_HOME/custom-cargo"
  write_cargo_stub_installing_binary

  run_setup CC_SESSION_FINDER_REINSTALL=1 CARGO_INSTALL_ROOT="$custom_root"

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--root $custom_root"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--force"* ]]
}

@test "explicit reinstall and no cargo -> fail loud" {
  write_finder_stub

  run_setup CC_SESSION_FINDER_REINSTALL=1

  [ "$status" -eq 1 ]
  [[ "$output" == *"CC_SESSION_FINDER_REINSTALL=1 requested, but cargo is unavailable"* ]]
}

@test "cargo only in CARGO_HOME/bin -> explicit reinstall still works" {
  write_finder_stub
  write_cargo_stub_installing_binary "$TEST_HOME/.cargo/bin/cargo"

  run_setup CC_SESSION_FINDER_REINSTALL=1

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--force"* ]]
}

@test "invalid reinstall value -> fail before installation" {
  write_finder_stub

  run_setup CC_SESSION_FINDER_REINSTALL=yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"CC_SESSION_FINDER_REINSTALL must be 0 or 1"* ]]
}

@test "relative CARGO_INSTALL_ROOT -> fail before installation" {
  write_cargo_stub_installing_binary

  run_setup CARGO_INSTALL_ROOT=.cargo

  [ "$status" -eq 1 ]
  [[ "$output" == *"must resolve to an absolute path"* ]]
  [ ! -e "$TEST_HOME/cargo.args" ]
}

@test "explicit reinstall cargo failure -> fail loud" {
  write_finder_stub
  write_cargo_stub_failure

  run_setup CC_SESSION_FINDER_REINSTALL=1

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo install failed for rev $PINNED_REF"* ]]
}

@test "explicit reinstall success without managed binary -> fail loud" {
  write_cargo_stub_success_without_binary

  run_setup CC_SESSION_FINDER_REINSTALL=1

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo install succeeded but $TEST_HOME/.cargo/bin/cc-session-finder is not executable"* ]]
}

@test "new installation and repeat setup preserve client configuration without invoking clients" {
  write_cargo_stub_installing_binary
  write_client_stub claude
  write_client_stub codex
  mkdir -p "$TEST_HOME/.codex"
  cat > "$TEST_HOME/.claude.json" <<'JSON'
{"mcpServers":{"cc-session-finder":{"command":"/old/finder","args":["mcp"]},"other":{"command":"/other/server"}}}
JSON
  cat > "$TEST_HOME/.codex/config.toml" <<'TOML'
[mcp_servers.cc-session-finder]
command = "/old/finder"
args = ["mcp"]
[mcp_servers.other]
command = "/other/server"
TOML
  chmod 600 "$TEST_HOME/.claude.json" "$TEST_HOME/.codex/config.toml"
  cp -p "$TEST_HOME/.claude.json" "$TEST_HOME/claude.before"
  cp -p "$TEST_HOME/.codex/config.toml" "$TEST_HOME/codex.before"

  for phase in install repeat; do
    run_setup
    if [ "$status" -ne 0 ]; then
      printf '%s setup failed: %s\n' "$phase" "$output" >&2
      return 1
    fi
    cmp "$TEST_HOME/claude.before" "$TEST_HOME/.claude.json"
    cmp "$TEST_HOME/codex.before" "$TEST_HOME/.codex/config.toml"
    [ -n "$(find "$TEST_HOME/.claude.json" -perm 0600)" ]
    [ -n "$(find "$TEST_HOME/.codex/config.toml" -perm 0600)" ]
    [ ! -e "$TEST_HOME/clients.log" ]
  done
}
