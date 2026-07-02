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
  run env -u CARGO_HOME HOME="$TEST_HOME" PATH="$STUB_BIN:/usr/bin:/bin" sh "$SCRIPT"
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
