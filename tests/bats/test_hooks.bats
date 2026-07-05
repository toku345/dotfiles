#!/usr/bin/env bats
# shellcheck shell=bash
# Tests for .claude/hooks/* — Stop hook (verify-on-stop.sh) and PostToolUse
# hook (fish-syntax-check.sh). These hooks gate Claude Code's stop event and
# editor writes, so silent failures here defeat the verification loop.

bats_require_minimum_version 1.5.0

setup() {
  # bats preprocesses .bats files into /tmp; BASH_SOURCE[0] at the test scope
  # points there, so resolve the repo via BATS_TEST_FILENAME (the original
  # path) instead of BASH_SOURCE.
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  HOOK_VERIFY="$REPO_ROOT/.claude/hooks/verify-on-stop.sh"
  HOOK_FISH="$REPO_ROOT/.claude/hooks/fish-syntax-check.sh"
  export REPO_ROOT HOOK_VERIFY HOOK_FISH

  # Per-test scratch project. CLAUDE_PROJECT_DIR isolates the hook from the
  # real chezmoi worktree so tests never touch repo-level state.
  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  CLAUDE_LEGACY_STATE_FILE="$PROJECT_DIR/.claude/.stop-hook-block-count"
  CLAUDE_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$PROJECT_DIR"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  export CLAUDE_LEGACY_STATE_FILE
  export XDG_STATE_HOME="$CLAUDE_STATE_HOME"
}

claude_state_file() {
  local repo_key
  repo_key=$(printf '%s' "$(cd "$PROJECT_DIR" && pwd -P)" | cksum | awk '{print $1}')
  printf '%s/claude/project-hooks/stop-hook-block-count.%s\n' \
    "$CLAUDE_STATE_HOME" "$repo_key"
}

# init_repo_with_relevant_file <path> [<content>]
# Creates a healthy git repo at $PROJECT_DIR with one initial commit, then
# stages an additional file at <path> so the verify-on-stop change-detection
# has a non-empty changed[] array. Used by tests that need to exercise the
# state-file / counter logic, which only runs after the empty-changed[]
# early-exit at the top of the script.
init_repo_with_relevant_file() {
  local rel="$1" content="${2:-}"
  git init -q "$PROJECT_DIR"
  # `git diff HEAD` requires at least one commit to exist.
  git -C "$PROJECT_DIR" -c user.email=t@t -c user.name=t \
    commit --allow-empty -q -m init
  mkdir -p "$PROJECT_DIR/$(dirname "$rel")"
  printf '%s' "$content" > "$PROJECT_DIR/$rel"
  git -C "$PROJECT_DIR" add "$rel"
}

# -----------------------------------------------------------------------------
# C1 regression: git enumeration must fail loud, not silently allow stop.
#
# Before the fix, `mapfile -t changed < <({ git diff; git ls-files; } | sort)`
# swallowed git failures because process substitution does not propagate the
# producer's exit status to the parent under set -Eeuo pipefail. A broken git
# repo therefore produced empty `changed[]` → all gates skipped → exit 0 +
# counter reset, masking the broken state and bypassing verification.
# -----------------------------------------------------------------------------

@test "C1: git diff HEAD failure causes block (was silent fail-open)" {
  # Fresh repo with zero commits → `git diff --name-only HEAD` exits non-zero
  # ("fatal: bad revision 'HEAD'"). This is the realistic broken-state case.
  git init -q "$PROJECT_DIR"

  # A file matching one of the gate-relevant globs ensures that on a healthy
  # repo the hook would run gates. Without this, a passing test could not
  # distinguish "skipped because no relevant changes" from "skipped because
  # git failed silently".
  mkdir -p "$PROJECT_DIR/tests/bats"
  touch "$PROJECT_DIR/tests/bats/dummy.bats"
  git -C "$PROJECT_DIR" add tests/bats/dummy.bats

  run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  # The hook prints its diagnostic to stderr; --separate-stderr keeps
  # the assertion specific to that stream so a regression that moved
  # the message to stdout would not silently pass.
  [[ "$stderr" == *"git enumeration failed"* ]]
}

# -----------------------------------------------------------------------------
# State file recovery: non-numeric content must reset the counter and warn
# without echoing the raw payload.
# -----------------------------------------------------------------------------

@test "state-file: non-numeric external content is reset without leaking content" {
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish not installed; cannot exercise the gate path"
  fi

  # A valid fish file is a relevant-but-passing change: changed[] is
  # non-empty (so the empty-changed early-exit does not pre-empt the
  # state-file read), the gate succeeds (so the script reaches the
  # success branch and removes the state file), and the corrupted
  # state file forces the parser warning + reset path.
  init_repo_with_relevant_file "scratch.fish" "# valid fish\n"

  local state_file
  state_file="$(claude_state_file)"
  mkdir -p "$(dirname "$state_file")"
  printf 'NONSECRET_MARKER=claude_state_leak\n' > "$state_file"

  run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"state file corrupted"* ]]
  [[ "$stderr" != *"NONSECRET_MARKER"* ]]
  [[ "$output" != *"NONSECRET_MARKER"* ]]
  [ ! -e "$state_file" ]
  [ ! -e "$CLAUDE_LEGACY_STATE_FILE" ]
}

# -----------------------------------------------------------------------------
# MAX_BLOCKS auto-allow: after MAX_BLOCKS consecutive blocks the hook must
# release the stop and clear the counter, otherwise a persistently broken
# gate could trap Claude in an infinite Stop loop.
# -----------------------------------------------------------------------------

@test "MAX_BLOCKS: counter at limit auto-allows BEFORE gates run" {
  # Use a `fish` PATH stub that writes a marker when invoked, so the
  # critical assertion is "marker absent" → the auto-allow branch fired
  # before any gate ran. Without the stub a regression that moved the
  # auto-allow check below the gates would still pass: the failing fish
  # gate's stderr would land in errors[] and the later auto-allow would
  # discard it before exit, masking the regression.
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local marker="$BATS_TEST_TMPDIR/fish-was-invoked"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/fish" <<STUB
#!/usr/bin/env bash
touch '$marker'
exit 1
STUB
  chmod +x "$stub_dir/fish"

  init_repo_with_relevant_file "broken.fish" "function foo\n"

  local state_file
  state_file="$(claude_state_file)"
  mkdir -p "$(dirname "$state_file")"
  printf '3' > "$state_file"

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"blocked 3 times consecutively"* ]]
  [ ! -e "$state_file" ]
  # Critical: the fish gate must not have been invoked. If this assertion
  # fails, the auto-allow check has been moved or otherwise no longer
  # fires before the gates.
  [ ! -e "$marker" ]
}

@test "state-file: legacy worktree symlink is ignored without leaking target" {
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish not installed; cannot exercise the gate path"
  fi

  local secret_file="$BATS_TEST_TMPDIR/local-secret.txt"
  init_repo_with_relevant_file "scratch.fish" "# valid fish\n"

  printf 'NONSECRET_MARKER=legacy_claude_symlink\n' > "$secret_file"
  mkdir -p "$(dirname "$CLAUDE_LEGACY_STATE_FILE")"
  ln -s "$secret_file" "$CLAUDE_LEGACY_STATE_FILE"

  run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"NONSECRET_MARKER"* ]]
  [[ "$output" != *"NONSECRET_MARKER"* ]]
}

@test "state-file: external symlink is reset without leaking target" {
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish not installed; cannot exercise the gate path"
  fi

  local secret_file="$BATS_TEST_TMPDIR/local-secret.txt"
  local state_file
  init_repo_with_relevant_file "scratch.fish" "# valid fish\n"

  state_file="$(claude_state_file)"
  printf 'NONSECRET_MARKER=external_claude_symlink\n' > "$secret_file"
  mkdir -p "$(dirname "$state_file")"
  ln -s "$secret_file" "$state_file"

  run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"state file is a symlink"* ]]
  [[ "$stderr" != *"NONSECRET_MARKER"* ]]
  [[ "$output" != *"NONSECRET_MARKER"* ]]
  [ ! -e "$state_file" ]
}

@test "state-file: relative XDG_STATE_HOME does not create worktree state" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local home_dir="$BATS_TEST_TMPDIR/home"
  local repo_key expected_state
  mkdir -p "$stub_dir" "$home_dir"
  cat > "$stub_dir/fish" <<STUB
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/fish"

  init_repo_with_relevant_file "broken.fish" "function foo\n"

  repo_key=$(printf '%s' "$(cd "$PROJECT_DIR" && pwd -P)" | cksum | awk '{print $1}')
  expected_state="$home_dir/.local/state/claude/project-hooks/stop-hook-block-count.$repo_key"

  run --separate-stderr env \
    HOME="$home_dir" \
    XDG_STATE_HOME=relative-state \
    PATH="$stub_dir:$PATH" \
    "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ -e "$expected_state" ]
  [ ! -e "$PROJECT_DIR/relative-state" ]
}

# -----------------------------------------------------------------------------
# Fail-open on an unwritable state home: relocating the counter outside the
# worktree means the write can now hit a non-writable XDG_STATE_HOME. If that
# write failed silently under set -e, the counter would never advance and a
# persistently failing gate would trap the turn — so the hook must fail loud
# AND allow the stop.
# -----------------------------------------------------------------------------

@test "state-file: unwritable state home fails open (allows stop, no loop trap)" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores directory permissions; cannot simulate an unwritable state home"
  fi
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish not installed; cannot exercise the gate path"
  fi

  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local ro_home="$BATS_TEST_TMPDIR/ro-state"
  mkdir -p "$stub_dir" "$ro_home"
  cat > "$stub_dir/fish" <<STUB
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/fish"

  init_repo_with_relevant_file "broken.fish" "function foo\n"

  # Absolute but read-only XDG_STATE_HOME: the failing fish gate would normally
  # block (exit 2) and bump the counter, but the counter write cannot succeed.
  # The hook must exit 0 with a loud diagnostic rather than a non-zero exit that
  # leaves the counter stuck.
  chmod 500 "$ro_home"

  run --separate-stderr env \
    XDG_STATE_HOME="$ro_home" \
    PATH="$stub_dir:$PATH" \
    "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"cannot persist loop-guard state"* ]]
  [[ "$stderr" == *"allowing stop"* ]]
}

# -----------------------------------------------------------------------------
# L1 regression: any tests/bats/*.bash file (not just test_helper*) is bats
# helper code that gets sourced — these have no shebang by convention but
# still need shellcheck. The earlier matcher widening (commit 4987af5)
# collected them into shell_changed but the downstream shebang-bypass case
# only listed `tests/bats/test_helper*.bash`, so non-test_helper helpers
# were silently dropped at the no-shebang check. Verify the bypass and
# the classification stay aligned.
# -----------------------------------------------------------------------------

@test "L1: tests/bats/*.bash without shebang reaches shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1 || ! command -v fish >/dev/null 2>&1; then
    skip "shellcheck/fish not installed; cannot exercise the gate path"
  fi

  # Sourced helper, deliberately no shebang. SC2034 (unused variable) is
  # warning-severity, so `shellcheck --severity=warning` surfaces it —
  # but only if the file actually reaches shellcheck. Before the fix
  # this file fell through the bypass case (match was test_helper-only),
  # then the no-shebang path silently dropped it from shell_targets.
  init_repo_with_relevant_file "tests/bats/utils.bash" \
'# shellcheck shell=bash
# Sourced helper for bats tests; no shebang.
some_unused_var=42
'

  run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  # Diagnostic must mention the filename — proves shellcheck ran on it
  # rather than silently skipping.
  [[ "$stderr" == *"utils.bash"* ]]
}

# -----------------------------------------------------------------------------
# fish-syntax-check: PostToolUse hook on Edit/Write. Must skip silently for
# unrelated paths and return a `decision: block` JSON envelope when the
# edited *.fish file fails `fish -n`.
# -----------------------------------------------------------------------------

@test "fish-syntax-check: non-.fish path is a silent no-op" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not installed; hook would no-op anyway"
  fi
  local target="$BATS_TEST_TMPDIR/notes.txt"
  printf 'hello\n' > "$target"

  local payload
  payload=$(jq -n --arg p "$target" '{tool_input: {file_path: $p}}')

  run "$HOOK_FISH" <<<"$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fish-syntax-check: valid fish file exits silently" {
  if ! command -v fish >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "fish/jq not installed"
  fi
  local target="$BATS_TEST_TMPDIR/ok.fish"
  printf 'function greet\n  echo hello\nend\n' > "$target"

  local payload
  payload=$(jq -n --arg p "$target" '{tool_input: {file_path: $p}}')

  run "$HOOK_FISH" <<<"$payload"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fish-syntax-check: syntax error emits decision: block JSON" {
  if ! command -v fish >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "fish/jq not installed"
  fi
  local target="$BATS_TEST_TMPDIR/broken.fish"
  # Unterminated function: fish -n flags this as a parse error.
  printf 'function broken\n' > "$target"

  local payload
  payload=$(jq -n --arg p "$target" '{tool_input: {file_path: $p}}')

  run "$HOOK_FISH" <<<"$payload"
  [ "$status" -eq 0 ]
  # The hook prints a JSON envelope on stdout and exits 0 (Claude reads
  # `decision` from stdout, not from the exit status).
  decision=$(jq -r '.decision' <<<"$output")
  [ "$decision" = "block" ]
  hook_event=$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")
  [ "$hook_event" = "PostToolUse" ]
}
