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
  # Create a wrapper instead of a symlink. The in-tree source is stored as
  # mode 0644 in git (chezmoi's `executable_` prefix sets 0755 only on apply,
  # not in the repo). Direct execution via a symlink would fail on systems
  # where the target has no exec bit (e.g. a fresh checkout in CI). The
  # wrapper invokes bash explicitly so the exec bit of the source does not
  # matter.
  cat > "$LIVE_BIN/triple-review" <<EOF
#!/usr/bin/env bash
exec bash "$SRC_SCRIPT" "\$@"
EOF
  chmod +x "$LIVE_BIN/triple-review"

  # Initialize a scratch git repo. Each test decides whether to configure
  # refs/remotes/origin/HEAD. Silencing init noise keeps bats output clean.
  git init -q "$SCRATCH_REPO"
  cd "$SCRATCH_REPO" || return 1

  # PATH order: gh/date/etc stubs first (STUB_BIN), then the symlink to
  # triple-review under its real name, then the system PATH so that git,
  # pgrep, bash, etc. are still discoverable.
  export PATH="$STUB_BIN:$LIVE_BIN:$PATH"

  # Unset any fake-gh / fake-uname / sleep-inhibitor env from prior tests so
  # stubs default to pass-through and wrap-gate defaults to "not yet wrapped".
  unset FAKE_GH_BASE FAKE_GH_STDERR FAKE_GH_RC TEST_FAKE_UNAME TRIPLE_REVIEW_SLEEP_INHIBITED
}

# Skip when pgrep cannot enumerate processes. macOS Seatbelt (used by Claude
# Code's Bash tool) denies access to the sysmond Mach service, so pgrep
# exits rc=3 with empty stdout — silently indistinguishable from "no
# descendants". Probe by spawning a known short-lived parent and asking
# pgrep -P <that PID> for its child; this avoids conflating "PID 1 has no
# children right now" (possible in minimal containers) with "pgrep is
# unusable." See docs/adr/0001-claude-code-sandbox-git-least-privilege.md
# Known Limitations.
skip_if_pgrep_unavailable() {
  bash -c 'sleep 2 & wait' &
  local probe_parent=$!
  local i ok=0
  for ((i=0; i<20; i++)); do
    if pgrep -P "$probe_parent" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 0.05
  done
  kill "$probe_parent" 2>/dev/null || true
  wait "$probe_parent" 2>/dev/null || true
  [ "$ok" -eq 1 ] \
    || skip "pgrep unavailable (likely Claude Code sandbox: sysmond Mach service deny — see docs/adr/0001)"
}
