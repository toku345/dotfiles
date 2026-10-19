#!/usr/bin/env bats
# shellcheck shell=bash
bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  resolve_bash5
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  for tool in jq fish shellcheck git chezmoi; do
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
  mkdir -p "$CLAUDE_PROJECT_DIR/scripts/hooks"
  cp "$REPO_ROOT/scripts/hooks/verify-on-stop-common.sh" "$CLAUDE_PROJECT_DIR/scripts/hooks/"
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

@test "Bash-only setup installs only Bash on both supported platforms" {
  local setup="$REPO_ROOT/.chezmoiscripts/run_once_before_install-bash.sh"
  local platform log
  for platform in darwin linux; do
    log="$BATS_TEST_TMPDIR/brew-$platform.log"
    run -0 env CHEZMOI_OS="$platform" BREW_TEST_LOG="$log" /bin/sh -c '
      brew() {
        test "$HOMEBREW_NO_AUTO_UPDATE" = 1
        test "$HOMEBREW_NO_VERIFY_ATTESTATIONS" = 1
        printf "%s\n" "$*" >> "$BREW_TEST_LOG"
      }
      sudo() { return 99; }
      . "$1"
    ' -- "$setup"
    [[ "$(cat "$log")" == 'install bash' ]]
  done
}

competing_bash() {
  mkdir -p "$HOME/.cargo/bin"
  cat > "$HOME/.cargo/bin/bash" <<'COMPETITOR'
#!/bin/sh
printf 'Competing Bash selected\n' >&2
exit 97
COMPETITOR
  chmod +x "$HOME/.cargo/bin/bash"
}

run_bash_startup() {
  run env PATH="/usr/bin:/bin:$PATH" "$BASH5_BIN" --noprofile --norc -c '
    asdf() { :; }; starship() { :; }; direnv() { :; }
    source "$1"
    bash -c '\''printf "Shell PATH runtime: %s %s\n" "$BASH" "$BASH_VERSION"; [[ "$BASH" -ef "$BASH5_BIN" ]] && (( BASH_VERSINFO[0] >= 5 ))'\''
  ' -- "$1"
}

run_fish_startup() {
  # Keep normal Fish PATH handlers; isolate config/universal state per run.
  local config_home
  config_home="$BATS_TEST_TMPDIR/fish-config-$(basename "$1")"
  run env PATH="/usr/bin:/bin:$PATH" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$config_home/data" fish -c '
    function fish_config; end
    function starship; end
    function direnv; end
    function shadowenv; end
    source $argv[1]
    bash -c '\''printf "Shell PATH runtime: %s %s\n" "$BASH" "$BASH_VERSION"; [[ "$BASH" -ef "$BASH5_BIN" ]] && (( BASH_VERSINFO[0] >= 5 ))'\''
  ' "$1"
}

@test "Linux bashrc selects Homebrew Bash over prepended user binaries" {
  [[ "$(uname -s)" == Linux ]] || skip 'bashrc is deployed only on Linux'
  competing_bash
  run_bash_startup "$REPO_ROOT/dot_bashrc"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'Shell PATH runtime:'* ]]
  [[ "$output" != *'Competing Bash selected'* ]]

  # Prove the fixture reaches this selection block, not inherited CI PATH.
  local mutant="$BATS_TEST_TMPDIR/bashrc-without-bash-priority"
  sed '/^# Managed Bash scripts/,/^fi$/d' "$REPO_ROOT/dot_bashrc" > "$mutant"
  run_bash_startup "$mutant"
  [[ "$status" -eq 97 ]]
  [[ "$output" == *'Competing Bash selected'* ]]
}

@test "macOS Fish config selects Homebrew Bash over prepended user binaries" {
  [[ "$(uname -s)" == Darwin ]] || skip 'Fish config is deployed only on macOS'
  competing_bash
  run_fish_startup "$REPO_ROOT/private_dot_config/private_fish/config.fish"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *'Shell PATH runtime:'* ]]
  [[ "$output" != *'Competing Bash selected'* ]]

  local mutant="$BATS_TEST_TMPDIR/fish-without-bash-priority"
  sed '/^## Managed Bash scripts/,/^end$/d' "$REPO_ROOT/private_dot_config/private_fish/config.fish" > "$mutant"
  run_fish_startup "$mutant"
  [[ "$status" -eq 97 ]]
  [[ "$output" == *'Competing Bash selected'* ]]
}

@test "Bats itself runs under Homebrew Bash" {
  [[ "$BASH" -ef "$BASH5_BIN" ]]
  (( BASH_VERSINFO[0] >= 5 ))
  printf 'Bats runtime: executable=%s version=%s\n' "$BASH" "$BASH_VERSION" >&3
}


isolated_chezmoi() {
  env XDG_CONFIG_HOME="$CM_ROOT/config" XDG_DATA_HOME="$CM_ROOT/data" \
    XDG_CACHE_HOME="$CM_ROOT/cache" \
    "$CHEZMOI_BIN" --source "$CM_ROOT/source" --destination "$HOME" \
    --config "$CM_ROOT/config.toml" --persistent-state "$CM_ROOT/state.boltdb" "$@"
}

@test "existing installer state is preserved and only Bash setup runs once" {
  local old="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"
  local old_hash=84b06eba03998bcc27aaeaa2e586a4a8de2fafabec56c80e2286321d778ea279
  # This content hash is the pre-#401 installer. Changing it requires an
  # explicit replay/migration decision, not a silent package-list edit.
  [[ "$(shasum -a 256 "$old" | cut -d ' ' -f 1)" == "$old_hash" ]]
  CM_ROOT="$BATS_TEST_TMPDIR/cm"
  CHEZMOI_BIN="$(type -P chezmoi)"
  local scripts="$CM_ROOT/source/.chezmoiscripts" seed_hash seed_state
  mkdir -p "$scripts" "$CM_ROOT/bin"
  : > "$CM_ROOT/config.toml"
  printf '#!/bin/sh\n:\n' > "$scripts/run_once_before_seed.sh"
  seed_hash=$(shasum -a 256 "$scripts/run_once_before_seed.sh" | cut -d ' ' -f 1)
  isolated_chezmoi apply
  seed_state=$(isolated_chezmoi state get --bucket=scriptState --key="$seed_hash")
  [[ -n "$seed_state" ]]
  # Model an existing machine using a genuine successful script-state value.
  isolated_chezmoi state set --bucket=scriptState --key="$old_hash" --value="$seed_state"
  rm "$scripts/run_once_before_seed.sh"
  cp "$old" "$scripts/"
  cp "$REPO_ROOT/.chezmoiscripts/run_once_before_install-bash.sh" "$scripts/"
  cat > "$CM_ROOT/bin/brew" <<'BREW'
#!/bin/sh
printf '%s\n' "$*" >> "$BREW_TEST_LOG"
BREW
  chmod +x "$CM_ROOT/bin/brew"
  export BREW_TEST_LOG="$CM_ROOT/brew.log"
  export PATH="$CM_ROOT/bin:$PATH"

  # Check the plan before execution: the full installer must not be selected.
  run -0 isolated_chezmoi apply --dry-run --verbose
  [[ "$output" == *'brew install bash'* ]]
  [[ "$output" != *'Minimum package installation'* ]]
  run -0 isolated_chezmoi apply
  [[ "$(cat "$BREW_TEST_LOG")" == 'install bash' ]]
  run -0 isolated_chezmoi apply
  [[ "$(cat "$BREW_TEST_LOG")" == 'install bash' ]]

  # Prove a content change would select the old installer again, without
  # executing package operations or touching real chezmoi state.
  printf '\n# changed fixture content\n' >> "$scripts/${old##*/}"
  run -0 isolated_chezmoi apply --dry-run --verbose
  [[ "$output" == *'Minimum package installation'* ]]
}
