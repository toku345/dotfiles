#!/usr/bin/env bats
# shellcheck shell=bash
bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  resolve_bash5
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin" "$HOME/.asdf"
  mkdir -p "$BATS_TEST_TMPDIR/prefix/opt/bash/bin"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/prefix/opt/bash/bin/bash"
  chmod +x "$BATS_TEST_TMPDIR/prefix/opt/bash/bin/bash"
}

source_twice() {
  run -0 env \
    -u BASH_ENV -u BUN_INSTALL -u ASDF_DATA_DIR -u ASDF_CONFIG_FILE -u HOMEBREW_PREFIX \
    WITH_ASDF="${WITH_ASDF:-}" \
    "$BASH5_BIN" --noprofile --norc -c '
      export HOME="$1"
      export HOMEBREW_PREFIX="$2"
      export PATH="$3"
      if [[ -n "${WITH_ASDF:-}" ]]; then
        asdf() { return 0; }
      fi
      source "$4"
      first=$PATH
      source "$4"
      if [[ "$PATH" != "$first" ]]; then
        printf "PATH changed on second source\nfirst=%s\nsecond=%s\n" "$first" "$PATH"
        exit 1
      fi
      printf "%s\n" "$first"
    ' -- "$HOME" "$BATS_TEST_TMPDIR/prefix" "$PATH_VALUE" "$REPO_ROOT/dot_bashrc"
}

path_parts() {
  local IFS=:
  read -ra PATH_PARTS <<< "$output"
}

count_entry() {
  local needle="$1" part count=0
  path_parts
  for part in "${PATH_PARTS[@]}"; do
    [[ "$part" == "$needle" ]] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

entry_index() {
  local needle="$1" part i=0
  path_parts
  for part in "${PATH_PARTS[@]}"; do
    if [[ "$part" == "$needle" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

opt_bash_bin() {
  local part found=""
  path_parts
  for part in "${PATH_PARTS[@]}"; do
    if [[ "$part" == */opt/bash/bin ]]; then
      [[ -z "$found" ]] || return 1
      found=$part
    fi
  done
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

assert_once_before() {
  local earlier="$1" later="$2" earlier_count later_count earlier_at later_at
  earlier_count="$(count_entry "$earlier")"
  later_count="$(count_entry "$later")"
  [[ "$earlier_count" -eq 1 ]]
  [[ "$later_count" -eq 1 ]]
  earlier_at="$(entry_index "$earlier")"
  later_at="$(entry_index "$later")"
  [[ "$earlier_at" -lt "$later_at" ]]
}

@test "first source orders user bins ahead of the original PATH and a second source does not grow it" {
  local bash_bin
  PATH_VALUE="/usr/bin:/bin:/bats-path-sentinel"
  source_twice
  assert_once_before "$HOME/.bun/bin" "$HOME/.cargo/bin"
  assert_once_before "$HOME/.cargo/bin" "$HOME/.local/bin"
  assert_once_before "$HOME/.local/bin" /bats-path-sentinel
  [[ "$(count_entry /bats-path-sentinel)" -eq 1 ]]
  bash_bin="$(opt_bash_bin)"
  [[ "$(count_entry "$bash_bin")" -eq 1 ]]
  assert_once_before "$bash_bin" "$HOME/.bun/bin"
}

@test "a directory already on PATH stays where it is" {
  PATH_VALUE="/usr/bin:$HOME/.local/bin:/bats-path-sentinel"
  source_twice
  assert_once_before "$HOME/.bun/bin" "$HOME/.cargo/bin"
  assert_once_before "$HOME/.cargo/bin" /usr/bin
  assert_once_before /usr/bin "$HOME/.local/bin"
  assert_once_before "$HOME/.local/bin" /bats-path-sentinel
  [[ "$(count_entry "$HOME/.local/bin")" -eq 1 ]]
}

@test "asdf shims stay behind native installers and are not duplicated" {
  PATH_VALUE="/usr/bin:/bin:/bats-path-sentinel"
  WITH_ASDF=1 source_twice
  assert_once_before "$HOME/.local/bin" "$HOME/.asdf/shims"
  assert_once_before "$HOME/.asdf/shims" /bats-path-sentinel
  [[ "$(count_entry "$HOME/.asdf/shims")" -eq 1 ]]
}
