#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/.chezmoiscripts/run_after_setup-cc-session-finder-mcp.sh"
  PINNED_REF="$(sed -n 's/^CC_SESSION_FINDER_REF="\([^"]*\)"/\1/p' "$SCRIPT")"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$TEST_HOME" "$STUB_BIN"
  export REPO_ROOT SCRIPT PINNED_REF TEST_HOME STUB_BIN
}

run_setup() {
  run env HOME="$TEST_HOME" PATH="$STUB_BIN:/usr/bin:/bin" sh "$SCRIPT"
}

write_cc_session_finder_stub() {
  mkdir -p "$TEST_HOME/.cargo/bin"
  cat > "$TEST_HOME/.cargo/bin/cc-session-finder" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$TEST_HOME/.cargo/bin/cc-session-finder"
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
  cat > "$STUB_BIN/cargo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$HOME/cargo.args"
mkdir -p "$HOME/.cargo/bin"
cat > "$HOME/.cargo/bin/cc-session-finder" <<'BIN'
#!/bin/sh
exit 0
BIN
chmod +x "$HOME/.cargo/bin/cc-session-finder"
STUB
  chmod +x "$STUB_BIN/cargo"
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
  [[ "$(cat "$TEST_HOME/claude.log")" == *"mcp add --scope user cc-session-finder -- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}

@test "wrong user-scope MCP entry -> replace with pinned binary path" {
  write_cc_session_finder_stub
  write_claude_stub_wrong_user_entry

  run_setup

  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"mcp remove cc-session-finder -s user"* ]]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"mcp add --scope user cc-session-finder -- $TEST_HOME/.cargo/bin/cc-session-finder mcp"* ]]
}
