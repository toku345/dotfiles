#!/usr/bin/env bash
# shellcheck shell=bash
# Adapter loaded by a verbatim copy of tests/bats/test_ghostty_theme.bats
# (see ../run-existing-bats.sh). It reuses the original helper unchanged and
# only replaces the `ghostty-theme` exec wrapper so the suite launches the Zig
# binary ($GHOSTTY_THEME_ZIG_BIN) instead of the Bash implementation.

: "${GHOSTTY_THEME_ZIG_BIN:?GHOSTTY_THEME_ZIG_BIN must point at the Zig binary}"
: "${GHOSTTY_THEME_REPO_TESTS_DIR:?GHOSTTY_THEME_REPO_TESTS_DIR must point at tests/bats}"

# shellcheck source=/dev/null
source "$GHOSTTY_THEME_REPO_TESTS_DIR/test_helper.bash"

# Keep the original as original_standard_env and wrap it.
eval "original_$(declare -f standard_env)"

standard_env() {
  original_standard_env
  cat >"$LIVE_BIN/ghostty-theme" <<'WRAPPER'
#!/bin/sh
exec "$GHOSTTY_THEME_ZIG_BIN" "$@"
WRAPPER
  chmod +x "$LIVE_BIN/ghostty-theme"
}
