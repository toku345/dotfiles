#!/usr/bin/env bats
# shellcheck shell=bash
# Bats gives each test its own environment; changes do not leak across tests.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CX_SOURCE="$REPO_ROOT/dot_local/bin/executable_cx"
  CF_SOURCE="$REPO_ROOT/dot_local/bin/executable_cf"
  TEST_BASH="$(type -P bash)"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  export HOME="$BATS_TEST_TMPDIR/home"
  export CODEX_HOME="$HOME/.codex"
  export CODEX_INSTALL_DIR="$TEST_BIN"
  export ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export STATUS_LOG="$BATS_TEST_TMPDIR/status-calls"
  export STATUS_REPORT="$BATS_TEST_TMPDIR/status-report"
  export GIT_LOG="$BATS_TEST_TMPDIR/git-calls"
  export TEST_BASH
  unset CODEX_FUGU_REAL_CODEX CODEX_FUGU_NO_UPDATE CODEX_FUGU_ASSUME_TTY
  mkdir -p "$TEST_BIN" "$CODEX_HOME/.fugu"
  printf 'model = "fugu-ultra"\n' > "$CODEX_HOME/fugu.config.toml"
  printf 'deployed_target=0.155.0\nrepo_dir=%s\n' "$BATS_TEST_TMPDIR" > "$CODEX_HOME/.fugu/state"
  printf '  installed version : 0.155.0\n  deployed_target   : 0.155.0\n' > "$STATUS_REPORT"
  cat > "$TEST_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' 'codex-cli 0.155.0'
  exit 0
fi
printf '%s\0' "$@" > "$ARGV_LOG"
exit "${STUB_EXIT:-0}"
EOF
  cat > "$TEST_BIN/codex-fugu" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --status ]]; then
  printf 'status\n' >> "$STATUS_LOG"
  cat "$STATUS_REPORT"
  exit "${STATUS_EXIT:-0}"
fi
printf '%s\0' "$@" > "$ARGV_LOG"
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$TEST_BIN/codex" "$TEST_BIN/codex-fugu"
  export PATH="$TEST_BIN:/usr/bin:/bin"
}

assert_argv() {
  printf '%s\0' "$@" > "$BATS_TEST_TMPDIR/expected-argv"
  cmp "$BATS_TEST_TMPDIR/expected-argv" "$ARGV_LOG"
}

assert_cf_argv() {
  assert_argv --no-update -- \
    -c check_for_update_on_startup=false --disable fast_mode \
    -c 'approvals_reviewer="user"' --ask-for-approval on-request "$@"
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
  rm "$TEST_BIN/codex" "$TEST_BIN/codex-fugu"
  run -0 "$TEST_BASH" "$CX_SOURCE" --help
  [[ "$output" == *'Usage: cx'* ]]
  run -0 "$TEST_BASH" "$CF_SOURCE" --help
  [[ "$output" == *'Usage: cf'* ]]
  [[ ! -e "$ARGV_LOG" && ! -e "$STATUS_LOG" ]]
}

@test "missing dependencies have explicit errors and exit 127" {
  rm "$TEST_BIN/codex" "$TEST_BIN/codex-fugu"
  run -127 "$TEST_BASH" "$CX_SOURCE" work
  [[ "$output" == *'required command not found on PATH: codex'* ]]
  run -127 "$TEST_BASH" "$CF_SOURCE"
  [[ "$output" == *'required command not found on PATH: codex-fugu'* ]]
}

@test "both launchers propagate the child exit code" {
  export STUB_EXIT=42
  run -42 "$TEST_BASH" "$CX_SOURCE" quick
  run -42 "$TEST_BASH" "$CF_SOURCE"
}

@test "cf matching versions launch quietly with process-only compatibility overrides" {
  run -0 --separate-stderr "$TEST_BASH" "$CF_SOURCE"
  [[ -z "$stderr" && -z "$output" ]]
  [[ "$(cat "$STATUS_LOG")" == status ]]
  assert_cf_argv
}

@test "cf preserves prompt boundaries including literal launcher management options" {
  run -0 "$TEST_BASH" "$CF_SOURCE" -- '日本語 "quoted" and spaces' '' --check
  assert_cf_argv -- '日本語 "quoted" and spaces' '' --check
}

@test "cf forwards resume with compatibility options preceding the subcommand" {
  run -0 "$TEST_BASH" "$CF_SOURCE" resume known-sakana-id '続けて'
  assert_cf_argv resume known-sakana-id '続けて'
}

@test "cf warns on mismatch every time and continues" {
  printf '  installed version : 0.155.0\n  deployed_target   : 0.154.0\n' > "$STATUS_REPORT"
  for _attempt in 1 2; do
    run -0 --separate-stderr "$TEST_BASH" "$CF_SOURCE"
    [[ "$stderr" == *'Codex is 0.155.0; the installed Fugu configuration targets 0.154.0.'* ]]
    [[ "$stderr" == *'Compatibility is unverified. Continuing without checking for updates.'* ]]
    [[ "$stderr" == *'Run codex-fugu directly'* ]]
    [[ -z "$output" ]]
    assert_cf_argv
  done
}

@test "cf warns and continues when status fails even if stdout looks valid" {
  export STATUS_EXIT=9
  run -0 --separate-stderr "$TEST_BASH" "$CF_SOURCE"
  [[ "$stderr" == *'unable to verify the Codex/Fugu version match'* ]]
  assert_cf_argv
}

@test "cf treats changed, unknown and duplicate status fields as unverified" {
  for report in \
    'new output format' \
    $'installed version : unknown\ndeployed_target : 0.155.0' \
    $'installed version : 0.155.0\ndeployed_target : unknown' \
    $'installed version : 0.155.0\ninstalled version : 0.154.0\ndeployed_target : 0.155.0'; do
    printf '%s\n' "$report" > "$STATUS_REPORT"
    run -0 --separate-stderr "$TEST_BASH" "$CF_SOURCE"
    [[ "$stderr" == *'unable to verify the Codex/Fugu version match'* ]]
    assert_cf_argv
  done
}

@test "cf accepts version suffixes without evaluating status data" {
  printf 'installed version : 0.155.0-alpha.1\ndeployed_target : 0.155.0-alpha.1\n' > "$STATUS_REPORT"
  run -0 --separate-stderr "$TEST_BASH" "$CF_SOURCE"
  [[ -z "$stderr" ]]
  # Keep command substitution literal to test that status is treated as data.
  # shellcheck disable=SC2016
  printf 'installed version : $(touch %s)\ndeployed_target : 0.155.0\n' "$BATS_TEST_TMPDIR/injected" > "$STATUS_REPORT"
  run -0 --separate-stderr "$TEST_BASH" "$CF_SOURCE"
  [[ "$stderr" == *'unable to verify'* ]]
  [[ ! -e "$BATS_TEST_TMPDIR/injected" ]]
}

@test "cf refuses missing state before even invoking status or adoption" {
  rm "$CODEX_HOME/.fugu/state"
  run -1 "$TEST_BASH" "$CF_SOURCE"
  [[ "$output" == *'Complete setup with the official Fugu installer'* ]]
  [[ ! -e "$STATUS_LOG" && ! -e "$ARGV_LOG" && ! -e "$CODEX_HOME/.fugu/state" ]]
}

@test "cf refuses a missing profile" {
  rm "$CODEX_HOME/fugu.config.toml"
  run -1 "$TEST_BASH" "$CF_SOURCE"
  [[ "$output" == *'Fugu profile or installation state is missing'* ]]
  [[ ! -e "$STATUS_LOG" && ! -e "$ARGV_LOG" ]]
}

@test "cf defaults CODEX_HOME to HOME/.codex and honors an explicit path with spaces" {
  unset CODEX_HOME
  run -0 "$TEST_BASH" "$CF_SOURCE"
  export CODEX_HOME="$BATS_TEST_TMPDIR/other codex home"
  mv "$HOME/.codex" "$CODEX_HOME"
  run -0 "$TEST_BASH" "$CF_SOURCE"
  assert_cf_argv
}

@test "installed Fugu launcher skips update paths under simulated TTY conditions" {
  [[ -n "${CODEX_FUGU_TEST_LAUNCHER:-}" ]] || skip 'set CODEX_FUGU_TEST_LAUNCHER to a reviewed official launcher for offline integration'
  [[ -f "$CODEX_FUGU_TEST_LAUNCHER" ]]
  cat > "$TEST_BIN/codex-fugu" <<'EOF'
#!/usr/bin/env bash
exec "$TEST_BASH" "$CODEX_FUGU_TEST_LAUNCHER" "$@"
EOF
  # Any attempt to consult the repository is observable and cannot reach git/network.
  cat > "$TEST_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
exit 1
EOF
  chmod +x "$TEST_BIN/git"
  export CODEX_FUGU_ASSUME_TTY=1
  cp "$CODEX_HOME/.fugu/state" "$BATS_TEST_TMPDIR/state-before"
  run -0 --separate-stderr "$TEST_BASH" "$CF_SOURCE" resume known-sakana-id '日本語 prompt'
  [[ -z "$stderr" ]]
  assert_argv -p fugu -c check_for_update_on_startup=false --disable fast_mode \
    -c 'approvals_reviewer="user"' --ask-for-approval on-request resume known-sakana-id '日本語 prompt'
  [[ ! -e "$GIT_LOG" ]]
  cmp "$BATS_TEST_TMPDIR/state-before" "$CODEX_HOME/.fugu/state"
  [[ "$(find "$CODEX_HOME/.fugu" -type f | wc -l | tr -d ' ')" == 1 ]]
  # Negative control: without --no-update the same TTY path must reach repository checks.
  run -0 "$TEST_BIN/codex-fugu" -- --help
  [[ -s "$GIT_LOG" ]]
}
