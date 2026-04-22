#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for ghostty-theme bats tests.

# Resolve key paths. Bats sets BATS_TEST_DIRNAME to the .bats file's dir.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SRC_BIN_DIR="$REPO_ROOT/dot_local/bin"
FIXTURES_DIR="$TESTS_DIR/fixtures"
SNAPSHOTS_DIR="$TESTS_DIR/snapshots"
STUB_BIN="$TESTS_DIR/bin"

export TESTS_DIR REPO_ROOT SRC_BIN_DIR FIXTURES_DIR SNAPSHOTS_DIR STUB_BIN

# Standard environment each test inherits: stubs ahead of the live scripts,
# resources themes from fixtures, no user themes unless a test opts in.
standard_env() {
  # Per-test scratch space. $BATS_TEST_TMPDIR is created fresh by bats before
  # setup() and removed after the test, so no cross-test leakage and no
  # rm -rf race on a shared dir (enables `bats --jobs N` in the future).
  SCRATCH_DIR="$BATS_TEST_TMPDIR"
  # Chezmoi names the scripts `executable_ghostty-theme` in the source tree
  # and strips the prefix on `chezmoi apply`. The test harness replicates that
  # rename via symlinks in $LIVE_BIN so PATH-based invocation works without
  # installing to the real $HOME.
  LIVE_BIN="$SCRATCH_DIR/bin"
  export SCRATCH_DIR LIVE_BIN
  mkdir -p "$LIVE_BIN"
  # Symlink executable_* sources under their real names. Safe to re-run.
  ln -sf "$SRC_BIN_DIR/executable_ghostty-theme" "$LIVE_BIN/ghostty-theme"
  ln -sf "$SRC_BIN_DIR/executable_ghostty-theme-preview" "$LIVE_BIN/ghostty-theme-preview"
  # Stub ghostty/fzf come first so the scripts resolve them instead of real
  # binaries. $LIVE_BIN provides the scripts under test. Then the caller's PATH.
  export PATH="$STUB_BIN:$LIVE_BIN:$PATH"
  export GHOSTTY_TEST_THEMES_DIR="$FIXTURES_DIR/themes"
  unset GHOSTTY_TEST_USER_THEMES_DIR
  unset GHOSTTY_STUB_FAIL
  unset GHOSTTY_STUB_VALIDATE_FAIL
  unset FAKE_FZF_SELECT
  unset FAKE_FZF_EXIT
  unset FAKE_FZF_STDIN_LOG
}

# assert_snapshot <label> <actual> <snapshot-file>
# If UPDATE_SNAPSHOTS=1, write the snapshot file; otherwise diff against it.
assert_snapshot() {
  local label="$1"
  local actual="$2"
  local snap_file="$3"

  if [[ "${UPDATE_SNAPSHOTS:-}" == "1" ]]; then
    mkdir -p "$(dirname "$snap_file")"
    printf '%s' "$actual" > "$snap_file"
    return 0
  fi

  if [[ ! -f "$snap_file" ]]; then
    printf 'snapshot missing: %s (%s). Re-run with UPDATE_SNAPSHOTS=1 to create.\n' \
      "$snap_file" "$label" >&2
    return 1
  fi

  local expected
  expected="$(cat "$snap_file")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'snapshot mismatch: %s\n' "$label" >&2
    printf -- '--- expected (%s) ---\n%s\n' "$snap_file" "$expected" >&2
    printf -- '--- actual ---\n%s\n' "$actual" >&2
    return 1
  fi
  return 0
}
