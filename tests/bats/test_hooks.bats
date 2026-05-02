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
  mkdir -p "$PROJECT_DIR"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
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

  run "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"git enumeration failed"* ]]
}

# -----------------------------------------------------------------------------
# State file recovery: non-numeric content must reset the counter and warn,
# never crash the hook (the regex guard exists for exactly this).
# -----------------------------------------------------------------------------

@test "state-file: non-numeric content is reset with warning" {
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish not installed; cannot exercise the gate path"
  fi

  # A valid fish file is a relevant-but-passing change: changed[] is
  # non-empty (so the empty-changed early-exit does not pre-empt the
  # state-file read), the gate succeeds (so the script reaches the
  # success branch and removes the state file), and the corrupted
  # state file forces the parser warning + reset path.
  init_repo_with_relevant_file "scratch.fish" "# valid fish\n"

  mkdir -p "$PROJECT_DIR/.claude"
  printf 'garbage' > "$PROJECT_DIR/.claude/.stop-hook-block-count"

  run "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"state file corrupted"* ]]
  [ ! -e "$PROJECT_DIR/.claude/.stop-hook-block-count" ]
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

  mkdir -p "$PROJECT_DIR/.claude"
  printf '3' > "$PROJECT_DIR/.claude/.stop-hook-block-count"

  PATH="$stub_dir:$PATH" run "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked 3 times consecutively"* ]]
  [ ! -e "$PROJECT_DIR/.claude/.stop-hook-block-count" ]
  # Critical: the fish gate must not have been invoked. If this assertion
  # fails, the auto-allow check has been moved or otherwise no longer
  # fires before the gates.
  [ ! -e "$marker" ]
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

  run bash -c "printf %s '$payload' | '$HOOK_FISH'"
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

  run bash -c "printf %s '$payload' | '$HOOK_FISH'"
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

  run bash -c "printf %s '$payload' | '$HOOK_FISH'"
  [ "$status" -eq 0 ]
  # The hook prints a JSON envelope on stdout and exits 0 (Claude reads
  # `decision` from stdout, not from the exit status).
  decision=$(jq -r '.decision' <<<"$output")
  [ "$decision" = "block" ]
  hook_event=$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")
  [ "$hook_event" = "PostToolUse" ]
}
