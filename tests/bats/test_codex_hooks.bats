#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031
# Tests for .codex/hooks/* — the Codex twins of the .claude Stop / PostToolUse
# hooks. test_hooks.bats covers the shared logic via the .claude copies; this
# file locks the .codex-SPECIFIC divergences that no other committed test
# exercises:
#   1. repo_root is derived from `git rev-parse --show-toplevel` (the .claude
#      copy uses ${CLAUDE_PROJECT_DIR:-$PWD}), so the hook must operate on the
#      git toplevel of the cwd.
#   2. the loop-guard state file lives outside the worktree.
#   3. .codex/hooks/*.sh is a gate-relevant path in both the enumeration loop
#      and the shellcheck always-include bypass.
# A regression in any of these would silently break the Codex stop-gate while
# the .claude twin's tests stayed green.

bats_require_minimum_version 1.5.0

setup() {
  # bats preprocesses .bats files into /tmp; resolve the repo via
  # BATS_TEST_FILENAME (the original path) rather than BASH_SOURCE.
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  HOOK_VERIFY="$REPO_ROOT/.codex/hooks/verify-on-stop.sh"
  HOOK_FISH="$REPO_ROOT/.codex/hooks/fish-syntax-check.sh"
  HOOKS_JSON="$REPO_ROOT/.codex/hooks.json"
  RULES_FILE="$REPO_ROOT/private_dot_codex/rules/managed.rules"
  export REPO_ROOT HOOK_VERIFY HOOK_FISH HOOKS_JSON RULES_FILE

  # Per-test scratch git repo. The .codex hook resolves repo_root via
  # `git rev-parse --show-toplevel` from the cwd, so tests cd into here
  # before invoking the hook; this isolates it from the real worktree.
  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  CODEX_LEGACY_STATE_FILE="$PROJECT_DIR/.codex/.stop-hook-block-count"
  CODEX_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export PROJECT_DIR CODEX_LEGACY_STATE_FILE
  export XDG_STATE_HOME="$CODEX_STATE_HOME"
  mkdir -p "$PROJECT_DIR"
}

codex_state_file() {
  local repo_key
  repo_key=$(printf '%s' "$(cd "$PROJECT_DIR" && pwd -P)" | cksum | awk '{print $1}')
  printf '%s/codex/project-hooks/stop-hook-block-count.%s\n' \
    "$CODEX_STATE_HOME" "$repo_key"
}

# init_codex_repo <path> [<content>]
# Creates a git repo at $PROJECT_DIR with one commit, stages an extra file at
# <path>, then cd's into $PROJECT_DIR so the hook's `git rev-parse
# --show-toplevel` resolves to it. The staged file makes changed[] non-empty
# so the state-file / counter logic past the empty-changed early-exit runs.
init_codex_repo() {
  local rel="$1" content="${2:-}"
  git init -q "$PROJECT_DIR"
  # Neutralize any global core.hooksPath (e.g. a gitleaks pre-commit) so the
  # scratch repo's commits stay hermetic and fast.
  git -C "$PROJECT_DIR" config core.hooksPath /dev/null
  git -C "$PROJECT_DIR" -c user.email=t@t -c user.name=t \
    commit --allow-empty -q -m init
  mkdir -p "$PROJECT_DIR/$(dirname "$rel")"
  printf '%s' "$content" > "$PROJECT_DIR/$rel"
  git -C "$PROJECT_DIR" add "$rel"
  cd "$PROJECT_DIR" || return 1
}

# -----------------------------------------------------------------------------
# git enumeration must fail loud, not silently allow stop — exercised through
# the .codex repo_root resolution (git rev-parse) and cd path.
# -----------------------------------------------------------------------------

@test "codex: git diff HEAD failure causes block (fail-closed)" {
  # Zero-commit repo → `git diff --name-only HEAD` exits non-zero. A staged
  # gate-relevant file ensures a healthy repo would have run gates, so a
  # passing test cannot be the no-relevant-changes skip in disguise.
  git init -q "$PROJECT_DIR"
  git -C "$PROJECT_DIR" config core.hooksPath /dev/null
  mkdir -p "$PROJECT_DIR/.codex/hooks"
  touch "$PROJECT_DIR/.codex/hooks/dummy.sh"
  git -C "$PROJECT_DIR" add .codex/hooks/dummy.sh
  cd "$PROJECT_DIR"

  run --separate-stderr bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"git enumeration failed"* ]]
}

# -----------------------------------------------------------------------------
# .codex/hooks/*.sh must reach shellcheck (the divergent case pattern). The
# .claude copy lists .claude/hooks/*.sh here; a copy-paste regression that left
# .claude paths in the .codex script would silently drop these from the gate.
# -----------------------------------------------------------------------------

@test "codex: shebang-less .codex/hooks/*.sh with a warning reaches shellcheck" {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck not installed; cannot exercise the shell gate"
  fi

  # SC2034 (unused variable) is warning-severity, so it only surfaces if the
  # file actually reaches `shellcheck --severity=warning`. Deliberately omit a
  # shebang: this locks the `.codex/hooks/*.sh` always-include bypass, not just
  # the generic shebang-detection fallback.
  init_codex_repo ".codex/hooks/bad.sh" \
'# shellcheck shell=bash
some_unused_var=42
'

  run --separate-stderr bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"bad.sh"* ]]
}

# -----------------------------------------------------------------------------
# Loop-guard state lives outside the worktree. Corrupted content must reset +
# warn without echoing the raw state payload.
# -----------------------------------------------------------------------------

@test "codex: corrupted external state file is reset without leaking content" {
  # A clean shell file plus a stubbed successful shellcheck makes this test
  # exercise the relevant gate path even on hosts without shellcheck.
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local marker="$BATS_TEST_TMPDIR/shellcheck-was-invoked"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shellcheck" <<STUB
#!/usr/bin/env bash
touch '$marker'
exit 0
STUB
  chmod +x "$stub_dir/shellcheck"

  init_codex_repo ".codex/hooks/ok.sh" \
'#!/usr/bin/env bash
echo ok
'

  local state_file
  state_file="$(codex_state_file)"
  mkdir -p "$(dirname "$state_file")"
  printf 'NONSECRET_MARKER=codex_state_leak\n' > "$state_file"

  PATH="$stub_dir:$PATH" run --separate-stderr bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"state file corrupted"* ]]
  [[ "$stderr" != *"NONSECRET_MARKER"* ]]
  [[ "$output" != *"NONSECRET_MARKER"* ]]
  [ -e "$marker" ]
  [ ! -e "$state_file" ]
  [ ! -e "$CODEX_LEGACY_STATE_FILE" ]
}

# -----------------------------------------------------------------------------
# MAX_BLOCKS auto-allow must fire from the external state path BEFORE gates
# run, or a persistently failing gate could trap the turn in an infinite stop
# loop.
# -----------------------------------------------------------------------------

@test "codex: MAX_BLOCKS auto-allows from external state before gates run" {
  # Stub shellcheck to mark invocation. If the auto-allow check moved below
  # the gates, the failing gate would run and touch the marker.
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local marker="$BATS_TEST_TMPDIR/shellcheck-was-invoked"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shellcheck" <<STUB
#!/usr/bin/env bash
touch '$marker'
exit 1
STUB
  chmod +x "$stub_dir/shellcheck"

  init_codex_repo ".codex/hooks/bad.sh" \
'#!/usr/bin/env bash
some_unused_var=42
'

  local state_file
  state_file="$(codex_state_file)"
  mkdir -p "$(dirname "$state_file")"
  printf '3' > "$state_file"

  PATH="$stub_dir:$PATH" run --separate-stderr bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"blocked 3 times consecutively"* ]]
  [ ! -e "$state_file" ]
  [ ! -e "$marker" ]
}

@test "codex: legacy worktree state symlink is ignored without leaking target" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local secret_file="$BATS_TEST_TMPDIR/local-secret.txt"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shellcheck" <<STUB
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/shellcheck"

  init_codex_repo ".codex/hooks/ok.sh" \
'#!/usr/bin/env bash
echo ok
'

  printf 'NONSECRET_MARKER=legacy_codex_symlink\n' > "$secret_file"
  mkdir -p "$(dirname "$CODEX_LEGACY_STATE_FILE")"
  ln -s "$secret_file" "$CODEX_LEGACY_STATE_FILE"

  PATH="$stub_dir:$PATH" run --separate-stderr bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"NONSECRET_MARKER"* ]]
  [[ "$output" != *"NONSECRET_MARKER"* ]]
}

@test "codex: external state symlink is reset without leaking target" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local secret_file="$BATS_TEST_TMPDIR/local-secret.txt"
  local state_file
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shellcheck" <<STUB
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/shellcheck"

  init_codex_repo ".codex/hooks/ok.sh" \
'#!/usr/bin/env bash
echo ok
'

  state_file="$(codex_state_file)"
  printf 'NONSECRET_MARKER=external_codex_symlink\n' > "$secret_file"
  mkdir -p "$(dirname "$state_file")"
  ln -s "$secret_file" "$state_file"

  PATH="$stub_dir:$PATH" run --separate-stderr bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"state file is a symlink"* ]]
  [[ "$stderr" != *"NONSECRET_MARKER"* ]]
  [[ "$output" != *"NONSECRET_MARKER"* ]]
  [ ! -e "$state_file" ]
}

@test "codex: relative XDG_STATE_HOME does not create worktree state" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local home_dir="$BATS_TEST_TMPDIR/home"
  local repo_key expected_state
  mkdir -p "$stub_dir" "$home_dir"
  cat > "$stub_dir/shellcheck" <<STUB
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/shellcheck"

  init_codex_repo ".codex/hooks/bad.sh" \
'#!/usr/bin/env bash
some_unused_var=42
'

  repo_key=$(printf '%s' "$(pwd -P)" | cksum | awk '{print $1}')
  expected_state="$home_dir/.local/state/codex/project-hooks/stop-hook-block-count.$repo_key"

  run --separate-stderr env \
    HOME="$home_dir" \
    XDG_STATE_HOME=relative-state \
    PATH="$stub_dir:$PATH" \
    bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 2 ]
  [ -e "$expected_state" ]
  [ ! -e "$PROJECT_DIR/relative-state" ]
}

# -----------------------------------------------------------------------------
# Fail-open on an unwritable state home (Codex twin): a non-writable
# XDG_STATE_HOME must not leave the counter stuck and trap the turn in a loop.
# -----------------------------------------------------------------------------

@test "codex: unwritable state home fails open (allows stop, no loop trap)" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores directory permissions; cannot simulate an unwritable state home"
  fi

  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  local ro_home="$BATS_TEST_TMPDIR/ro-state"
  mkdir -p "$stub_dir" "$ro_home"
  cat > "$stub_dir/shellcheck" <<STUB
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/shellcheck"

  init_codex_repo ".codex/hooks/bad.sh" \
'#!/usr/bin/env bash
some_unused_var=42
'

  # Absolute but read-only XDG_STATE_HOME: the counter write must fail and the
  # hook must exit 0 with a loud diagnostic, never a non-zero exit that leaves
  # the counter stuck.
  chmod 500 "$ro_home"

  run --separate-stderr env \
    XDG_STATE_HOME="$ro_home" \
    PATH="$stub_dir:$PATH" \
    bash "$HOOK_VERIFY" <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"cannot persist loop-guard state"* ]]
  [[ "$stderr" == *"allowing stop"* ]]
}

# -----------------------------------------------------------------------------
# .codex/hooks.json is the only project-local wiring that makes the tested hook
# scripts run. Keep a thin schema-independent assertion around the event names,
# matcher, and command targets so script tests cannot pass while wiring drifts.
# -----------------------------------------------------------------------------

@test "codex hooks.json wires fish and stop hooks" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not installed"
  fi

  run jq -e '
    .hooks.PostToolUse[0].matcher == "Edit|Write" and
    (.hooks.PostToolUse[0].hooks[0].command | contains(".codex/hooks/fish-syntax-check.sh")) and
    .hooks.PostToolUse[0].hooks[0].timeout == 15 and
    (.hooks.Stop[0].hooks[0].command | contains(".codex/hooks/verify-on-stop.sh")) and
    .hooks.Stop[0].hooks[0].timeout == 300
  ' "$HOOKS_JSON"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# managed.rules is a safety net over user-local broad allows. Verify both the
# managed prompt decisions and an unrelated command that should remain unmatched.
# -----------------------------------------------------------------------------

assert_execpolicy_decision() {
  local expected="$1"
  shift

  run --separate-stderr codex execpolicy check --rules "$RULES_FILE" "$@"
  [ "$status" -eq 0 ]
  decision=$(jq -r '.decision // "none"' <<<"$output")
  [ "$decision" = "$expected" ]
}

@test "codex managed.rules prompts only the managed command prefixes" {
  if ! command -v codex >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "codex/jq not installed"
  fi

  assert_execpolicy_decision prompt gh api graphql
  assert_execpolicy_decision prompt git add AGENTS.md
  assert_execpolicy_decision prompt git commit --amend
  assert_execpolicy_decision none git status
}

# -----------------------------------------------------------------------------
# fish-syntax-check (.codex twin): a broken *.fish edit must emit the
# decision: block JSON envelope on stdout while exiting 0.
# -----------------------------------------------------------------------------

@test "codex fish-syntax-check: syntax error emits decision: block JSON" {
  if ! command -v fish >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "fish/jq not installed"
  fi
  local target="$BATS_TEST_TMPDIR/broken.fish"
  printf 'function broken\n' > "$target"

  local payload
  payload=$(jq -n --arg p "$target" '{tool_input: {file_path: $p}}')

  run bash "$HOOK_FISH" <<<"$payload"
  [ "$status" -eq 0 ]
  decision=$(jq -r '.decision' <<<"$output")
  [ "$decision" = "block" ]
  hook_event=$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")
  [ "$hook_event" = "PostToolUse" ]
}
