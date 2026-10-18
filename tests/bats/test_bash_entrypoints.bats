#!/usr/bin/env bats
# shellcheck shell=bash
bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  resolve_bash5
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  for tool in jq fish shellcheck git; do
    command -v "$tool" >/dev/null || { printf 'Required entrypoint test dependency missing: %s\n' "$tool" >&2; return 1; }
  done
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  export BASH_RUNTIME_LOG="$BATS_TEST_TMPDIR/runtime.log"
  export BASH_ENV="$BATS_TEST_TMPDIR/probe.bash"
  mkdir -p "$HOME/.claude" "$CLAUDE_PROJECT_DIR/.codex/hooks" "$CLAUDE_PROJECT_DIR/.claude/hooks"
  cat > "$BASH_ENV" <<'PROBE'
printf '%s\t%s\t%s\t%s\n' "$0" "$BASHPID" "$BASH" "$BASH_VERSION" >> "$BASH_RUNTIME_LOG"
PROBE
  cp "$REPO_ROOT"/.codex/hooks/*.sh "$CLAUDE_PROJECT_DIR/.codex/hooks/"
  cp "$REPO_ROOT"/.claude/hooks/*.sh "$CLAUDE_PROJECT_DIR/.claude/hooks/"
  chmod +x "$CLAUDE_PROJECT_DIR"/.claude/hooks/*.sh
  CLAUDE_PROJECT_DIR="$(cd "$CLAUDE_PROJECT_DIR" && pwd -P)"
  git -c init.templateDir= init -q "$CLAUDE_PROJECT_DIR"
  git -C "$CLAUDE_PROJECT_DIR" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
}

# Match the target's exact $0: Bash-based stubs/children cannot satisfy this.
assert_target_runtime() {
  local target="$1" script pid executable version count=0
  while IFS=$'\t' read -r script pid executable version; do
    [[ "$script" == "$target" ]] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$executable" -ef "$BASH5_BIN" ]] || return 1
    (( ${version%%.*} >= 5 )) || return 1
    printf 'Runtime: %s pid=%s executable=%s version=%s\n' "$script" "$pid" "$executable" "$version" >&3
    count=$((count + 1))
  done < "$BASH_RUNTIME_LOG"
  [[ "$count" -eq 1 ]]
}

@test "normal shebang launch uses Homebrew Bash" {
  local target="$BATS_TEST_TMPDIR/cx"
  cp "$REPO_ROOT/dot_local/bin/executable_cx" "$target"
  chmod +x "$target"
  run -0 env PATH="${BASH5_BIN%/*}:/usr/bin:/bin" "$target" --help
  [[ "$output" == *Usage:* ]]
  assert_target_runtime "$target"
}

@test "statusline settings command selects Homebrew Bash even with system-first PATH" {
  local target="$HOME/.claude/statusline-command.sh" command
  cp "$REPO_ROOT/private_dot_claude/executable_statusline-command.sh" "$target"
  chmod +x "$target"
  command=$(jq -r '.statusLine.command' "$REPO_ROOT/private_dot_claude/settings.json")
  run -0 env PATH="/usr/bin:/bin:$PATH" /bin/sh -c "$command" <<<'{"model":{"display_name":"Fixture"}}'
  [[ "$output" == *Fixture* ]]
  assert_target_runtime "$target"
}

@test "Codex configured hook commands select Homebrew Bash" {
  local command target commands count=0
  cd "$CLAUDE_PROJECT_DIR"
  commands=$(jq -r '.hooks[][] .hooks[].command' "$REPO_ROOT/.codex/hooks.json")
  while IFS= read -r command; do
    : > "$BASH_RUNTIME_LOG"
    run -0 env PATH="/usr/bin:/bin:$PATH" /bin/sh -c "$command" <<<'{}'
    if [[ "$command" == *fish-syntax-check.sh* ]]; then
      target="$CLAUDE_PROJECT_DIR/.codex/hooks/fish-syntax-check.sh"
    else
      target="$CLAUDE_PROJECT_DIR/.codex/hooks/verify-on-stop.sh"
    fi
    assert_target_runtime "$target"
    count=$((count + 1))
  done <<< "$commands"
  [[ "$count" -eq 2 ]]
}

@test "documented Claude hook commands select Homebrew Bash" {
  local command target commands count=0
  commands=$(sed -n '/^```json$/,/^```$/p' "$REPO_ROOT/docs/claude-code-hooks.md" | sed '1d;$d' | jq -r '.hooks[][] .hooks[].command')
  while IFS= read -r command; do
    : > "$BASH_RUNTIME_LOG"
    run -0 env PATH="/usr/bin:/bin:$PATH" /bin/sh -c "$command" <<<'{}'
    if [[ "$command" == *fish-syntax-check.sh* ]]; then
      target="$CLAUDE_PROJECT_DIR/.claude/hooks/fish-syntax-check.sh"
    else
      target="$CLAUDE_PROJECT_DIR/.claude/hooks/verify-on-stop.sh"
    fi
    assert_target_runtime "$target"
    count=$((count + 1))
  done <<< "$commands"
  [[ "$count" -eq 2 ]]
}

@test "narrowed PATH retains Homebrew Bash without leaking other brew tools" {
  local bin="$BATS_TEST_TMPDIR/bin" target="$BATS_TEST_TMPDIR/cx"
  mkdir -p "$bin"
  ln -s "$BASH5_BIN" "$bin/bash"
  cp "$REPO_ROOT/dot_local/bin/executable_cx" "$target"
  chmod +x "$target"
  run -127 env PATH="$bin" "$target" work
  [[ "$output" == *'required command not found on PATH: codex'* ]]
  assert_target_runtime "$target"
}

@test "system Bash substitution fails Homebrew identity check even if version is 5" {
  local target="$BATS_TEST_TMPDIR/cx"
  cp "$REPO_ROOT/dot_local/bin/executable_cx" "$target"
  chmod +x "$target"
  run env PATH="/usr/bin:/bin" "$target" --help
  [[ -s "$BASH_RUNTIME_LOG" ]]
  run assert_target_runtime "$target"
  [[ "$status" -eq 1 ]]
  # Also reject an explicit system interpreter in the fixture resolver.
  run env PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$PATH" BASH5_BIN=/bin/bash "$BASH5_BIN" -c 'source "$1"; resolve_bash5' -- "$BATS_TEST_DIRNAME/test_helper_bash5.bash"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *'is not Homebrew Bash'* ]]
}

@test "minimum package setup installs Bash in the native platform branch" {
  local setup="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"
  local log="$BATS_TEST_TMPDIR/brew.log" platform
  case "$(uname -s)" in Darwin) platform=darwin ;; Linux) platform=linux ;; esac
  # Source the unchanged POSIX script with package-manager functions only.
  # Linux's absolute brew shellenv is read-only; install/update are intercepted.
  run -0 env CHEZMOI_OS="$platform" BREW_TEST_LOG="$log" /bin/sh -c '
    brew() { printf "%s\n" "$*" >> "$BREW_TEST_LOG"; }
    sudo() { :; }
    . "$1"
  ' -- "$setup"
  grep -Eq '^install bash( |$)' "$log"
}

@test "Linux bashrc selects Homebrew Bash after shell initialization" {
  [[ "$(uname -s)" == Linux ]] || skip 'bashrc is deployed only on Linux'
  run -0 "$BASH5_BIN" --noprofile --norc -c '
    asdf() { :; }; starship() { :; }; direnv() { :; }
    source "$1"
    selected=$(type -P bash)
    [[ "$selected" -ef "$BASH5_BIN" ]]
    bash -c '\''printf "Shell PATH runtime: %s %s\n" "$BASH" "$BASH_VERSION"; [[ "$BASH" -ef "$BASH5_BIN" ]] && (( BASH_VERSINFO[0] >= 5 ))'\''
  ' -- "$REPO_ROOT/dot_bashrc"
  [[ "$output" == *'Shell PATH runtime:'* ]]
}

@test "macOS Fish config selects Homebrew Bash after shell initialization" {
  [[ "$(uname -s)" == Darwin ]] || skip 'Fish config is deployed only on macOS'
  run -0 env XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" fish --no-config -c '
    function fish_config; end
    function starship; end
    function direnv; end
    function shadowenv; end
    source $argv[1]
    bash -c '\''printf "Shell PATH runtime: %s %s\n" "$BASH" "$BASH_VERSION"; [[ "$BASH" -ef "$BASH5_BIN" ]] && (( BASH_VERSINFO[0] >= 5 ))'\''
  ' "$REPO_ROOT/private_dot_config/private_fish/config.fish"
  [[ "$output" == *'Shell PATH runtime:'* ]]
}

@test "Bats itself runs under Homebrew Bash" {
  [[ "$BASH" -ef "$BASH5_BIN" ]]
  (( BASH_VERSINFO[0] >= 5 ))
  printf 'Bats runtime: executable=%s version=%s\n' "$BASH" "$BASH_VERSION" >&3
}
