#!/usr/bin/env bats
# shellcheck shell=bash
#
# `cx` picks a model and mode-effort profile without touching shared Codex settings
# (dot_local/bin/executable_cx, profiles: ~/.codex/{quick,work}.config.toml).
#
# Bats gives each test its own environment; changes do not leak across tests.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CX_SOURCE="$REPO_ROOT/dot_local/bin/executable_cx"
  TEST_BASH="${CX_TEST_BASH:-$(type -P bash)}"
  [[ "$TEST_BASH" == /* && -x "$TEST_BASH" ]]
  TEST_PYTHON="$(type -P python3)"
  TEST_GREP="$(type -P grep)"
  TEST_CMP="$(type -P cmp)"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  export HOME="$BATS_TEST_TMPDIR/home"
  export CODEX_HOME="$HOME/.codex"
  export ARGV_LOG="$BATS_TEST_TMPDIR/argv"
  export TEST_BASH
  mkdir -p "$TEST_BIN" "$CODEX_HOME"
  for mode in quick work; do
    cp "$REPO_ROOT/private_dot_codex/private_$mode.config.toml" "$CODEX_HOME/$mode.config.toml"
  done
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

mutate_profile() {
  "$TEST_PYTHON" - "$REPO_ROOT/private_dot_codex/private_$1.config.toml" \
    "$CODEX_HOME/$1.config.toml" "$2" <<'PY'
from pathlib import Path
import sys

source, target, change = sys.argv[1:]
data = Path(source).read_bytes()
header, body = data.split(b"\n", 1)
if change.startswith("changed_"):
    key = change.removeprefix("changed_").encode()
    data = data.replace(key + b' = "', key + b' = "unexpected-', 1)
elif change.startswith("missing_") and change != "missing_sentinel":
    key = change.removeprefix("missing_").encode()
    data = b"".join(line for line in data.splitlines(keepends=True) if not line.startswith(key + b" ="))
else:
    changes = {
        "missing_sentinel": body,
        "old_sentinel": data.replace(b"_V1\n", b"_V0\n", 1),
        "other_sentinel": data.replace(header, b"# CX_PROFILE_other_V1", 1),
        "empty": b"",
        "truncated": data[:len(data) // 2],
        "extra_key": data + b'personality = "pragmatic"\n',
        "comment": data + b"# local edit\n",
        "whitespace": data.replace(b"model =", b"model  =", 1),
        "crlf": data.replace(b"\n", b"\r\n"),
        "no_final_newline": data[:-1],
        "extra_final_newline": data + b"\n",
        "nul": data + b"\0",
    }
    data = changes[change]
Path(target).write_bytes(data)
PY
}

assert_profile_rejected() {
  run --separate-stderr -1 "$TEST_BASH" "$CX_SOURCE" "$1"
  [[ "$stderr" == *"$CODEX_HOME/$1.config.toml"* ]]
  [[ "$stderr" == *'run chezmoi apply -v'* ]]
  [[ ! -e "$ARGV_LOG" ]]
}

path_without() {
  local missing=$1 tool target
  ISOLATED_BIN="$BATS_TEST_TMPDIR/without-$missing"
  mkdir -p "$ISOLATED_BIN"
  for tool in codex grep cmp bash; do
    [[ "$tool" == "$missing" ]] && continue
    case "$tool" in
      codex) target="$TEST_BIN/codex" ;;
      grep) target="$TEST_GREP" ;;
      cmp) target="$TEST_CMP" ;;
      bash) target="$TEST_BASH" ;;
    esac
    ln -s "$target" "$ISOLATED_BIN/$tool"
  done
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
  mkdir "$BATS_TEST_TMPDIR/empty-bin"
  run -0 /usr/bin/env PATH="$BATS_TEST_TMPDIR/empty-bin" CODEX_HOME="$BATS_TEST_TMPDIR/not-installed" \
    "$TEST_BASH" "$CX_SOURCE" --help
  [[ "$output" == *'Usage: cx'* ]]
  [[ "$output" == *'gpt-6.1-sol / low; Plan: medium'* ]]
  [[ "$output" == *'gpt-6-astra / high; Plan: xhigh'* ]]
  [[ ! -e "$ARGV_LOG" ]]
}

@test "missing commands have explicit errors and exit 127" {
  for tool in codex grep cmp; do
    path_without "$tool"
    run -127 /usr/bin/env PATH="$ISOLATED_BIN" "$TEST_BASH" "$CX_SOURCE" work
    [[ "$output" == *"required command not found on PATH: $tool"* ]]
    [[ ! -e "$ARGV_LOG" ]]
  done
}

@test "a missing profile stops before launching Codex" {
  rm "$CODEX_HOME/work.config.toml"
  run --separate-stderr -1 "$TEST_BASH" "$CX_SOURCE" work
  [[ "$stderr" == *"profile not found: $CODEX_HOME/work.config.toml"* ]]
  [ ! -e "$ARGV_LOG" ]
}

@test "an empty profile stops before launching Codex" {
  mutate_profile quick empty
  assert_profile_rejected quick
}

@test "stale values with a current sentinel and missing keys stop both modes" {
  for mode in quick work; do
    for key in model model_reasoning_effort plan_mode_reasoning_effort; do
      for change in changed missing; do
        mutate_profile "$mode" "${change}_$key"
        assert_profile_rejected "$mode"
        [[ "$stderr" == *'profile contents mismatch'* ]]
      done
    done
  done
}

@test "missing old and wrong-mode sentinels stop both modes" {
  for mode in quick work; do
    for change in missing_sentinel old_sentinel other_sentinel; do
      mutate_profile "$mode" "$change"
      assert_profile_rejected "$mode"
      [[ "$stderr" == *'profile sentinel mismatch'* ]]
    done
  done
}

@test "noncanonical bytes and truncated profiles stop both modes" {
  for mode in quick work; do
    for change in truncated extra_key comment whitespace crlf no_final_newline extra_final_newline nul; do
      mutate_profile "$mode" "$change"
      assert_profile_rejected "$mode"
    done
  done
}

@test "profiles copied to the wrong mode are rejected" {
  cp "$CODEX_HOME/work.config.toml" "$CODEX_HOME/quick.config.toml"
  assert_profile_rejected quick
}

@test "non-default CODEX_HOME with spaces is used for both modes" {
  export CODEX_HOME="$BATS_TEST_TMPDIR/custom codex home"
  mkdir "$CODEX_HOME"
  for mode in quick work; do
    cp "$REPO_ROOT/private_dot_codex/private_$mode.config.toml" "$CODEX_HOME/$mode.config.toml"
    run -0 "$TEST_BASH" "$CX_SOURCE" "$mode"
    assert_argv --profile "$mode"
  done
}

@test "read errors are reported without launching Codex" {
  printf '%s\n' '#!/bin/sh' 'exit 2' > "$TEST_BIN/grep"
  chmod +x "$TEST_BIN/grep"
  assert_profile_rejected quick
  [[ "$stderr" == *'could not read profile'* ]]
}

@test "comparison errors are distinct from mismatches and stop before Codex" {
  printf '%s\n' '#!/bin/sh' 'exit 2' > "$TEST_BIN/cmp"
  chmod +x "$TEST_BIN/cmp"
  assert_profile_rejected work
  [[ "$stderr" == *'could not compare profile'* ]]
}

@test "cx propagates the child exit code" {
  export STUB_EXIT=42
  run -42 "$TEST_BASH" "$CX_SOURCE" quick
}
