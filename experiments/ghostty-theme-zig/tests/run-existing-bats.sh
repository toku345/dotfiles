#!/usr/bin/env bash
# shellcheck shell=bash
# Run the unchanged tests/bats/test_ghostty_theme.bats against the Zig binary.
#
# Usage: run-existing-bats.sh <ghostty-theme-binary> [bats options...]
#
# The .bats file is copied verbatim into a temp dir next to an adapter
# test_helper.bash, which sources the original helper and only swaps the
# `ghostty-theme` exec wrapper so it launches the Zig binary instead of the
# Bash script. Expectations, fixtures, snapshots and stubs stay untouched.
set -euo pipefail

if (( $# < 1 )); then
  printf 'usage: %s <ghostty-theme-binary> [bats options...]\n' "$0" >&2
  exit 2
fi

bin_dir=$(cd "$(dirname "$1")" && pwd)
zig_bin="$bin_dir/$(basename "$1")"
shift
if [[ ! -x "$zig_bin" ]]; then
  printf 'run-existing-bats: not an executable: %s\n' "$zig_bin" >&2
  exit 2
fi
if ! command -v bats >/dev/null 2>&1; then
  printf 'run-existing-bats: bats not found on PATH\n' >&2
  exit 127
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_tests="$(cd "$here/../../../tests/bats" && pwd)"
original="$repo_tests/test_ghostty_theme.bats"

work=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-theme-zig-bats.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$original" "$work/test_ghostty_theme.bats"
cp "$here/bats-adapter/test_helper.bash" "$work/test_helper.bash"
cmp -s "$original" "$work/test_ghostty_theme.bats"

export GHOSTTY_THEME_ZIG_BIN="$zig_bin"
export GHOSTTY_THEME_REPO_TESTS_DIR="$repo_tests"
bats "$@" "$work/test_ghostty_theme.bats"
