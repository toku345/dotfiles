#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for triple-review bats tests.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SRC_BIN_DIR="$REPO_ROOT/dot_local/bin"
SRC_SCRIPT="$SRC_BIN_DIR/executable_triple-review"
STUB_BIN="$TESTS_DIR/bin"

export TESTS_DIR REPO_ROOT SRC_BIN_DIR SRC_SCRIPT STUB_BIN

# Standard environment for triple-review tests. Creates a scratch dir with
# a `triple-review` symlink so PATH-based invocation works without installing
# into $HOME, initializes an empty git repo (individual tests may opt in to
# setting refs/remotes/origin/HEAD), and puts stubs ahead of real binaries.
standard_env_triple_review() {
  SCRATCH_DIR="$BATS_TEST_TMPDIR"
  LIVE_BIN="$SCRATCH_DIR/bin"
  SCRATCH_REPO="$SCRATCH_DIR/repo"
  export SCRATCH_DIR LIVE_BIN SCRATCH_REPO

  mkdir -p "$LIVE_BIN" "$SCRATCH_REPO"
  ln -sf "$SRC_SCRIPT" "$LIVE_BIN/triple-review"

  # Initialize a scratch git repo. Each test decides whether to configure
  # refs/remotes/origin/HEAD. Silencing init noise keeps bats output clean.
  git init -q "$SCRATCH_REPO"
  cd "$SCRATCH_REPO" || return 1

  # PATH order: gh/date/etc stubs first (STUB_BIN), then the symlink to
  # triple-review under its real name, then the system PATH so that git,
  # pgrep, bash, etc. are still discoverable.
  export PATH="$STUB_BIN:$LIVE_BIN:$PATH"

  # Unset any fake-gh env from prior tests so the stub defaults to rc=0
  # with no output until the test opts in.
  unset FAKE_GH_BASE FAKE_GH_STDERR FAKE_GH_RC
}
