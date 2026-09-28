#!/usr/bin/env bats
# shellcheck shell=bash
#
# `cx` picks an Astra effort profile without touching shared Codex settings
# (dot_local/bin/executable_cx, profiles: ~/.codex/{quick,work}.config.toml).
#
# Bats gives each test its own environment; changes do not leak across tests.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CX_SOURCE="$REPO_ROOT/dot_local/bin/executable_cx"
  TEST_BASH="$(type -P bash)"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  export HOME="$BATS_TEST_TMPDIR/home"
  export CODEX_HOME="$HOME/.codex"
  export ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export TEST_BASH
  mkdir -p "$TEST_BIN" "$CODEX_HOME"
  cat > "$TEST_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' 'codex-cli 0.155.0'
  exit 0
fi
printf '%s\0' "$@" > "$ARGV_LOG"
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$TEST_BIN/codex"
  export PATH="$TEST_BIN:/usr/bin:/bin"
}

assert_argv() {
  printf '%s\0' "$@" > "$BATS_TEST_TMPDIR/expected-argv"
  cmp "$BATS_TEST_TMPDIR/expected-argv" "$ARGV_LOG"
}

@test "cx chooses quick and work without injecting model or effort flags" {
  run -0 "$TEST_BASH" "$CX_SOURCE" quick
  assert_argv --profile quick
  run -0 "$TEST_BASH" "$CX_SOURCE" work
  assert_argv --profile work
}

@test "cx preserves prompt boundaries, empty arguments and explicit native overrides" {
  run -0 "$TEST_BASH" "$CX_SOURCE" quick -c 'model_reasoning_effort="high"' -- '日本語 "quoted" and spaces' ''
  assert_argv --profile quick -c 'model_reasoning_effort="high"' -- '日本語 "quoted" and spaces' ''
}

@test "cx forwards same-provider resume arguments unchanged" {
  run -0 "$TEST_BASH" "$CX_SOURCE" work resume known-openai-id '続けて "確認"'
  assert_argv --profile work resume known-openai-id '続けて "確認"'
}

@test "cx rejects missing and unknown modes without launching Codex" {
  run -2 "$TEST_BASH" "$CX_SOURCE"
  [[ "$output" == *'expected mode: quick or work'* ]]
  run -2 "$TEST_BASH" "$CX_SOURCE" deep
  [[ "$output" == *'Usage: cx'* ]]
  [[ ! -e "$ARGV_LOG" ]]
}

@test "help needs no installation and launches no commands" {
  rm "$TEST_BIN/codex"
  run -0 "$TEST_BASH" "$CX_SOURCE" --help
  [[ "$output" == *'Usage: cx'* ]]
  [[ ! -e "$ARGV_LOG" ]]
}

@test "a missing codex has an explicit error and exit 127" {
  rm "$TEST_BIN/codex"
  run -127 "$TEST_BASH" "$CX_SOURCE" work
  [[ "$output" == *'required command not found on PATH: codex'* ]]
}

@test "cx propagates the child exit code" {
  export STUB_EXIT=42
  run -42 "$TEST_BASH" "$CX_SOURCE" quick
}
