#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/.chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh"
  PINNED_REF="$(sed -n 's/^CC_SESSION_FINDER_REF="\([^"]*\)"/\1/p' "$SCRIPT")"
  STALE_REF="0000000000000000000000000000000000000000"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  STATE_FILE="$TEST_HOME/.local/state/dotfiles/cc-session-finder.ref"
  mkdir -p "$TEST_HOME" "$STUB_BIN"
  export REPO_ROOT SCRIPT PINNED_REF STALE_REF TEST_HOME STUB_BIN STATE_FILE
}

run_setup() {
  run env -u CARGO_HOME -u CARGO_INSTALL_ROOT -u XDG_STATE_HOME HOME="$TEST_HOME" PATH="$STUB_BIN:/usr/bin:/bin" sh "$SCRIPT"
}

run_setup_with_cargo_install_root() {
  run env -u CARGO_HOME -u XDG_STATE_HOME CARGO_INSTALL_ROOT="$1" HOME="$TEST_HOME" PATH="$STUB_BIN:/usr/bin:/bin" sh "$SCRIPT"
}

write_managed_binary() {
  mkdir -p "$TEST_HOME/.cargo/bin"
  cat > "$TEST_HOME/.cargo/bin/cc-session-finder" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$TEST_HOME/.cargo/bin/cc-session-finder"
}

write_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n' "$1" > "$STATE_FILE"
}

binary_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Current state marker: rev on line 1, sha256 of the managed binary on line 2.
write_state_current() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n%s\n' "$PINNED_REF" "$(binary_sha256 "$TEST_HOME/.cargo/bin/cc-session-finder")" > "$STATE_FILE"
}

write_cc_session_finder_stub() {
  # Managed install already at the pinned rev: binary plus matching state marker.
  write_managed_binary
  write_state_current
}

write_claude_stub_current() {
  cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/sh
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  cat <<OUT
cc-session-finder:
  Scope: User config (available in all your projects)
  Status: ✔ Connected
  Type: stdio
  Command: $HOME/.cargo/bin/cc-session-finder
  Args: mcp
OUT
  exit 0
fi
printf '%s\n' "unexpected claude invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/claude"
}

write_claude_stub_missing() {
  cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/sh
log="$HOME/claude.log"
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  exit 1
fi
if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
printf '%s\n' "unexpected claude invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/claude"
}

write_claude_stub_wrong_user_entry() {
  cat > "$STUB_BIN/claude" <<'STUB'
#!/bin/sh
log="$HOME/claude.log"
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  cat <<OUT
cc-session-finder:
  Scope: User config (available in all your projects)
  Type: stdio
  Command: /old/cc-session-finder
  Args: mcp
OUT
  exit 0
fi
if [ "$1" = "mcp" ] && [ "$2" = "remove" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
printf '%s\n' "unexpected claude invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/claude"
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

write_cargo_stub_failing() {
  cat > "$STUB_BIN/cargo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/cargo.args"
exit 101
STUB
  chmod +x "$STUB_BIN/cargo"
}

write_codex_stub_current() {
  cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/sh
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  cat <<OUT
cc-session-finder
  enabled: true
  transport: stdio
  command: $HOME/.cargo/bin/cc-session-finder
  args: mcp
  cwd: -
  env: -
  remove: codex mcp remove cc-session-finder
OUT
  exit 0
fi
printf '%s\n' "unexpected codex invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/codex"
}

write_codex_stub_wrong_entry() {
  cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/sh
log="$HOME/codex.log"
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  cat <<OUT
cc-session-finder
  enabled: true
  transport: stdio
  command: /old/cc-session-finder
  args: mcp
  cwd: -
  env: -
  remove: codex mcp remove cc-session-finder
OUT
  exit 0
fi
if [ "$1" = "mcp" ] && [ "$2" = "remove" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
printf '%s\n' "unexpected codex invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/codex"
}

write_codex_stub_missing() {
  cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/sh
log="$HOME/codex.log"
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  printf '%s\n' "Error: No MCP server named 'cc-session-finder' found." >&2
  exit 1
fi
if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
printf '%s\n' "unexpected codex invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/codex"
}

write_codex_stub_prefix_impostor() {
  cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/sh
log="$HOME/codex.log"
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  cat <<OUT
cc-session-finder
  enabled: true
  transport: stdio
  command: $HOME/.cargo/bin/cc-session-finder-wrapper
  args: mcp-extra
  cwd: -
  env: -
  remove: codex mcp remove cc-session-finder
OUT
  exit 0
fi
if [ "$1" = "mcp" ] && [ "$2" = "remove" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
  printf '%s\n' "$*" >> "$log"
  exit 0
fi
printf '%s\n' "unexpected codex invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/codex"
}

write_codex_stub_get_error() {
  cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/sh
if [ "$1" = "mcp" ] && [ "$2" = "get" ] && [ "$3" = "cc-session-finder" ]; then
  printf '%s\n' "Error: failed to parse config" >&2
  exit 2
fi
printf '%s\n' "unexpected codex invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/codex"
}

@test "current user-scope MCP entry is already correct -> no changes" {
  write_cc_session_finder_stub
  write_claude_stub_current

  run_setup

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/claude.log" ]
}

@test "missing binary and missing cargo -> skip without blocking apply" {
  run_setup

  [ "$status" -eq 0 ]
  [[ "$output" == *"cc-session-finder MCP setup skipped"* ]]
}

@test "missing binary with cargo -> install pinned revision and register MCP" {
  write_cargo_stub_installing_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--root $TEST_HOME/.cargo"* ]]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"mcp add --scope user cc-session-finder -- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}

@test "custom CARGO_INSTALL_ROOT -> install and register custom managed path" {
  custom_root="$TEST_HOME/custom-cargo"
  custom_state="$TEST_HOME/.local/state/dotfiles/cc-session-finder.ref"
  write_cargo_stub_installing_binary
  write_claude_stub_missing
  write_codex_stub_missing

  run_setup_with_cargo_install_root "$custom_root"

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--root $custom_root"* ]]
  [ -x "$custom_root/bin/cc-session-finder" ]
  [ "$(sed -n '1p' "$custom_state")" = "$PINNED_REF" ]
  [ "$(sed -n '2p' "$custom_state")" = "$(binary_sha256 "$custom_root/bin/cc-session-finder")" ]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"mcp add --scope user cc-session-finder -- $custom_root/bin/cc-session-finder mcp"* ]]
  [[ "$(cat "$TEST_HOME/codex.log")" == *"mcp add cc-session-finder -- $custom_root/bin/cc-session-finder mcp"* ]]
}

@test "wrong user-scope MCP entry -> replace with pinned binary path" {
  write_cc_session_finder_stub
  write_claude_stub_wrong_user_entry

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"mcp remove cc-session-finder -s user"* ]]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"mcp add --scope user cc-session-finder -- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}

@test "current Codex MCP entry is already correct -> no changes" {
  write_cc_session_finder_stub
  write_codex_stub_current

  run_setup

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/codex.log" ]
}

@test "wrong Codex MCP entry -> replace with pinned binary path" {
  write_cc_session_finder_stub
  write_codex_stub_wrong_entry

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/codex.log")" == *"mcp remove cc-session-finder"* ]]
  [[ "$(cat "$TEST_HOME/codex.log")" == *"mcp add cc-session-finder -- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}

@test "missing Codex MCP entry -> add pinned binary path" {
  write_cc_session_finder_stub
  write_codex_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/codex.log")" == *"mcp add cc-session-finder -- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}

@test "prefix-shaped Codex MCP entry -> replace with pinned binary path" {
  write_cc_session_finder_stub
  write_codex_stub_prefix_impostor

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/codex.log")" == *"mcp remove cc-session-finder"* ]]
  [[ "$(cat "$TEST_HOME/codex.log")" == *"mcp add cc-session-finder -- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}

@test "unexpected Codex MCP lookup error -> fail loud" {
  write_cc_session_finder_stub
  write_codex_stub_get_error

  run_setup

  [ "$status" -eq 2 ]
  [[ "$output" == *"failed to inspect Codex MCP server \"cc-session-finder\""* ]]
  [[ "$output" == *"failed to parse config"* ]]
}

@test "managed binary with stale state and cargo -> reinstall pinned revision" {
  write_managed_binary
  write_state "$STALE_REF"
  write_cargo_stub_installing_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--force"* ]]
  [ "$(sed -n '1p' "$STATE_FILE")" = "$PINNED_REF" ]
  [ "$(sed -n '2p' "$STATE_FILE")" = "$(binary_sha256 "$TEST_HOME/.cargo/bin/cc-session-finder")" ]
}

@test "managed binary with matching state -> no cargo invocation" {
  write_cc_session_finder_stub
  write_cargo_stub_installing_binary
  write_claude_stub_current

  run_setup

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/cargo.args" ]
}

@test "managed binary with stale state and no cargo -> fail loud" {
  write_managed_binary
  write_state "$STALE_REF"

  run_setup

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo is unavailable to reinstall"* ]]
}

@test "managed binary without state -> reinstall pinned revision and write state" {
  write_managed_binary
  write_cargo_stub_installing_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [ "$(sed -n '1p' "$STATE_FILE")" = "$PINNED_REF" ]
  [ "$(sed -n '2p' "$STATE_FILE")" = "$(binary_sha256 "$TEST_HOME/.cargo/bin/cc-session-finder")" ]
}

@test "matching state but managed binary missing -> reinstall" {
  write_state "$PINNED_REF"
  write_cargo_stub_installing_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
}

@test "cargo install failure -> fail loud and keep previous state" {
  write_managed_binary
  write_state "$STALE_REF"
  write_cargo_stub_failing
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo install failed"* ]]
  [ "$(cat "$STATE_FILE")" = "$STALE_REF" ]
  [ ! -e "$TEST_HOME/claude.log" ]
}

@test "cargo install succeeds without managed binary -> fail loud and keep previous state" {
  write_managed_binary
  write_state "$STALE_REF"
  rm "$TEST_HOME/.cargo/bin/cc-session-finder"
  write_cargo_stub_success_without_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo install succeeded but $TEST_HOME/.cargo/bin/cc-session-finder is not executable"* ]]
  [ "$(cat "$STATE_FILE")" = "$STALE_REF" ]
  [ ! -e "$TEST_HOME/claude.log" ]
}

@test "state without managed binary and no cargo -> fail loud" {
  write_state "$PINNED_REF"

  run_setup

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo is unavailable to reinstall"* ]]
}

@test "cargo only in CARGO_HOME/bin (not on PATH) -> still reinstalls" {
  write_managed_binary
  write_state "$STALE_REF"
  write_cargo_stub_installing_binary "$TEST_HOME/.cargo/bin/cargo"
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [ "$(sed -n '1p' "$STATE_FILE")" = "$PINNED_REF" ]
}

@test "PATH binary outside CARGO_HOME never satisfies the pinned fast path" {
  cat > "$STUB_BIN/cc-session-finder" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$STUB_BIN/cc-session-finder"
  write_state "$PINNED_REF"
  write_cargo_stub_installing_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"-- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}

@test "managed binary overwritten out-of-band with matching rev state -> reinstall" {
  write_cc_session_finder_stub
  # Simulate an out-of-band overwrite after the state was recorded: the rev in
  # the state file still matches, but the artifact no longer does.
  cat > "$TEST_HOME/.cargo/bin/cc-session-finder" <<'STUB'
#!/bin/sh
exit 1
STUB
  chmod +x "$TEST_HOME/.cargo/bin/cc-session-finder"
  write_cargo_stub_installing_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--force"* ]]
  [ "$(sed -n '1p' "$STATE_FILE")" = "$PINNED_REF" ]
  [ "$(sed -n '2p' "$STATE_FILE")" = "$(binary_sha256 "$TEST_HOME/.cargo/bin/cc-session-finder")" ]
}

@test "legacy single-line state with matching rev -> reinstall and record fingerprint" {
  write_managed_binary
  write_state "$PINNED_REF"
  write_cargo_stub_installing_binary
  write_claude_stub_missing

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/cargo.args")" == *"--rev $PINNED_REF"* ]]
  [ "$(sed -n '1p' "$STATE_FILE")" = "$PINNED_REF" ]
  [ "$(sed -n '2p' "$STATE_FILE")" = "$(binary_sha256 "$TEST_HOME/.cargo/bin/cc-session-finder")" ]
}
