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

install_bats_reminder_mv_failure_stub() {
  local stub_dir="$1"
  local real_mv
  real_mv=$(type -P mv)
  [ -n "$real_mv" ] || return 1

  cat > "$stub_dir/mv" <<STUB
#!/usr/bin/env bash
case "\${2:-}" in
  *stop-hook-bats-reminder-count.*) exit 1 ;;
esac
exec '$real_mv' "\$@"
STUB
  chmod +x "$stub_dir/mv"
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

@test "state-file: empty external content is reset without leaking content" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/fish" <<STUB
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/fish"

  init_repo_with_relevant_file "scratch.fish" "# valid fish\n"

  local state_file
  state_file="$(claude_state_file)"
  mkdir -p "$(dirname "$state_file")"
  : > "$state_file"

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"state file corrupted"* ]]
  [ ! -e "$state_file" ]
}

@test "state-file: numeric prefix with trailing payload is corrupted, not auto-allowed" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/fish" <<STUB
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/fish"

  init_repo_with_relevant_file "broken.fish" "function foo\n"

  local state_file
  state_file="$(claude_state_file)"
  mkdir -p "$(dirname "$state_file")"
  printf '3\nNONSECRET_MARKER=claude_trailing_payload\n' > "$state_file"

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"state file corrupted"* ]]
  [[ "$stderr" != *"NONSECRET_MARKER"* ]]
  [[ "$output" != *"NONSECRET_MARKER"* ]]
  [ "$(cat "$state_file")" = "1" ]
}

@test "state-file: cleanup failure is best effort when no relevant files changed" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores directory permissions; cannot simulate an unwritable state directory"
  fi

  git init -q "$PROJECT_DIR"
  git -C "$PROJECT_DIR" -c user.email=t@t -c user.name=t \
    commit --allow-empty -q -m init

  local state_file state_dir
  state_file="$(claude_state_file)"
  state_dir="$(dirname "$state_file")"
  mkdir -p "$state_dir"
  printf '1\n' > "$state_file"
  chmod 500 "$state_dir"

  run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  chmod 700 "$state_dir"

  [ "$status" -eq 0 ]
  [[ "$stderr" == *"cannot remove loop-guard state"* ]]
  [ -e "$state_file" ]
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
  [[ "$stderr" == *"verification failures were not enforced"* ]]
  [[ "$stderr" == *"fish -n broken.fish"* ]]
  [[ "$stderr" == *"allowing stop"* ]]
}

# -----------------------------------------------------------------------------
# Counter round-trip: the single-invocation tests above never exercise the hook
# reading its OWN newline-terminated output and incrementing a non-zero value.
# Drive a persistently failing gate across four invocations so the counter goes
# 0 -> 1 -> 2 -> 3 -> MAX_BLOCKS auto-allow, proving the read-of-own-"N\n",
# increment-from-nonzero, and auto-allow paths that the loop guard depends on.
# -----------------------------------------------------------------------------

@test "state-file: counter round-trip increments across invocations and auto-allows at MAX_BLOCKS" {
  # A gate stub (not host fish) makes this independent of whether fish is
  # installed, while still driving the failing-gate write path each run.
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/fish" <<STUB
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/fish"

  init_repo_with_relevant_file "broken.fish" "function foo\n"

  local state_file
  state_file="$(claude_state_file)"

  # 1st block: count 0 -> writes newline-terminated "1", exit 2.
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "1" ]

  # 2nd block: reads its own "1\n" and increments a non-zero value -> "2".
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "2" ]

  # 3rd block: "2" -> "3".
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "3" ]

  # 4th invocation: count 3 >= MAX_BLOCKS -> auto-allow, remove counter, exit 0.
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"blocked 3 times consecutively"* ]]
  [ ! -e "$state_file" ]
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
# The Stop hook must never execute the test tree itself. It runs automatically
# at turn end, outside the permission system and outside the sandbox that Bash
# tool calls get, and `bats tests/bats/` executes discovered .bats tests plus
# the shell helpers they load or source. Auto-running it therefore converted
# an auto-approved write under tests/bats/ into unprompted command execution.
# The gate must instead block and require the suite to run through the gated
# tool path.
# -----------------------------------------------------------------------------

@test "bats gate blocks with instructions instead of executing the test tree" {
  # A `bats` PATH stub that marks invocation: the stub makes `command -v bats`
  # succeed (so this is the tool-installed path, not the not-installed skip),
  # and the absent marker is the assertion that no repository test code ran.
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local marker="$BATS_TEST_TMPDIR/bats-was-invoked"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<STUB
#!/usr/bin/env bash
touch '$marker'
exit 0
STUB
  chmod +x "$stub_dir/bats"

  # A plain *.bats file matches only the broad `tests/bats/*` case, so the
  # shellcheck and fish gates stay quiet, nothing lands in errors[], and this
  # reminder is the sole notices[] entry.
  init_repo_with_relevant_file "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"bats gate requires a gated run"* ]]
  # The reminder interpolates MAX_BLOCKS. Assert the rendered number, not just
  # the static first line: if MAX_BLOCKS is renamed or scoped away the message
  # degrades to "its own -reminder auto-allow" and a first-line-only grep
  # would still pass while the agent reads a malformed instruction.
  [[ "$stderr" == *"its own 3-reminder auto-allow"* ]]
  # Critical: the suite must not have been executed by the hook.
  [ ! -e "$marker" ]
}

# The reminder needs no binary, but with bats absent the suite cannot be run at
# all, so blocking would only burn the reminder budget with an instruction
# nobody can follow. Skipping is deliberate; pin it so the choice cannot drift
# silently now that the branch no longer executes anything.
@test "bats gate: not installed -> skip note and exit 0, no reminder" {
  init_repo_with_relevant_file "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  # Build a PATH holding only what the hook needs, with no bats. Dropping whole
  # PATH entries instead would also remove the `bash` that shares Homebrew's
  # bin with bats, and the hook would die at its shebang (127) before reaching
  # the branch under test.
  local shim="$BATS_TEST_TMPDIR/nobats-bin"
  local tool resolved
  mkdir -p "$shim"
  for tool in bash git cksum awk sort cat rm mkdir mv head dirname; do
    resolved=$(command -v "$tool" 2>/dev/null) || skip "$tool not resolvable"
    ln -sf "$resolved" "$shim/$tool"
  done
  [ ! -e "$shim/bats" ] || skip "bats leaked into the shim PATH"

  # `env -i` with an explicit environment, and `bash <hook>` rather than the
  # shebang, so nothing here mutates this shell's PATH — an inline
  # `PATH=... run` would leave the assignment behind (bash keeps it for
  # functions) and break bats' own teardown.
  run --separate-stderr env -i \
    "PATH=$shim" \
    "HOME=${HOME:-}" \
    "XDG_STATE_HOME=$XDG_STATE_HOME" \
    "CLAUDE_PROJECT_DIR=$PROJECT_DIR" \
    bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"bats not installed; skipping bats gate"* ]]
  [[ "$stderr" != *"bats gate requires a gated run"* ]]
}

# The reminder fires on every stop while tests/bats/ is dirty, whether or not
# anything is wrong. If it shared the executing gates' counter it would burn
# their budget, so a genuine shellcheck failure in the same window would be
# auto-allowed after the same 3 stops instead of continuing to block.
@test "bats reminder does not consume the executing gates' block budget" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/bats"

  init_repo_with_relevant_file "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  local state_file nag_file
  state_file="$(claude_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  # The reminder advanced only its own counter; the executing gates' budget is
  # untouched, so a shellcheck failure later still gets its full 3 blocks.
  [ ! -e "$state_file" ]
  [ -f "$nag_file" ]
  [ "$(cat "$nag_file")" = "1" ]
}

@test "bats reminder and executing gate persist independent counters" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/bats" "$stub_dir/shellcheck"

  init_repo_with_relevant_file "tests/bats/utils.bash" \
'some_unused_var=42
'

  local state_file nag_file
  state_file="$(claude_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "1" ]
  [ "$(cat "$nag_file")" = "1" ]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"bats gate requires a gated run"* ]]
}

@test "bats reminder persistence failure does not release an executing gate" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/bats" "$stub_dir/shellcheck"
  install_bats_reminder_mv_failure_stub "$stub_dir"

  init_repo_with_relevant_file "tests/bats/utils.bash" \
'some_unused_var=42
'

  local state_file nag_file
  state_file="$(claude_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "1" ]
  [ ! -e "$nag_file" ]
  [[ "$stderr" == *"cannot persist bats reminder state"* ]]
  [[ "$stderr" == *"reminder not enforced"* ]]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"blocked stop (1/3)"* ]]
  [[ "$stderr" != *"allowing stop to avoid an unbounded reminder loop"* ]]
}

@test "bats reminder persistence failure alone fails open" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/bats"
  install_bats_reminder_mv_failure_stub "$stub_dir"

  init_repo_with_relevant_file "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  local state_file nag_file
  state_file="$(claude_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [ ! -e "$state_file" ]
  [ ! -e "$nag_file" ]
  [[ "$stderr" == *"cannot persist bats reminder state"* ]]
  [[ "$stderr" == *"reminder not enforced"* ]]
  [[ "$stderr" == *"allowing stop to avoid an unbounded reminder loop"* ]]
  [[ "$stderr" != *"blocked stop"* ]]
}

# The reminder's own budget must bound it, and the auto-allow must leave the
# counter at MAX_BLOCKS rather than deleting it. Deleting would make the next
# stop read 0 and re-arm the reminder, so a dirty tests/bats/ tree would loop
# 3-blocked-then-1-allowed forever with nothing the agent could do about it.
@test "bats reminder stops blocking at MAX_BLOCKS but keeps its diagnostic" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/bats" "$stub_dir/shellcheck"

  init_repo_with_relevant_file "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  local state_file nag_file
  state_file="$(claude_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  local expected
  for expected in 1 2 3; do
    PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
    [ "$status" -eq 2 ]
    [ "$(cat "$nag_file")" = "$expected" ]
    [[ "$stderr" == *"bats gate requires a gated run"* ]]
  done

  # At MAX_BLOCKS the sentinel remains, the instruction is not repeated, and
  # the non-blocking diagnostic stays visible on later stops.
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [ "$(cat "$nag_file")" = "3" ]
  [[ "$stderr" == *"bats reminder issued 3 times consecutively"* ]]
  [[ "$stderr" != *"bats gate requires a gated run"* ]]
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [ "$(cat "$nag_file")" = "3" ]
  [[ "$stderr" == *"bats reminder issued 3 times consecutively"* ]]
  [[ "$stderr" != *"bats gate requires a gated run"* ]]

  # A saturated reminder must not suppress a newly failing executing gate.
  printf 'some_unused_var=42\n' > "$PROJECT_DIR/tests/bats/utils.bash"
  git -C "$PROJECT_DIR" add tests/bats/utils.bash
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "1" ]
  [ "$(cat "$nag_file")" = "3" ]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"blocked stop (1/3)"* ]]
  [[ "$stderr" != *"bats gate requires a gated run"* ]]

  # Once tests/bats/ is clean again the sentinel is cleared, so a later change
  # gets a fresh budget rather than being silenced forever.
  git -C "$PROJECT_DIR" rm -q --cached \
    "tests/bats/dummy.bats" "tests/bats/utils.bash"
  rm -f "$PROJECT_DIR/tests/bats/dummy.bats" \
    "$PROJECT_DIR/tests/bats/utils.bash"
  PATH="$stub_dir:$PATH" run --separate-stderr "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [ ! -e "$state_file" ]
  [ ! -e "$nag_file" ]
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
