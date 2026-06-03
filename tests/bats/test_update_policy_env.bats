#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export REPO_ROOT
}

assert_line_present() {
  local needle="$1"
  local file="$2"
  grep -Fqx "$needle" "$file"
}

line_number_of() {
  local needle="$1"
  local file="$2"
  grep -Fnx "$needle" "$file" | cut -d: -f1 | head -n1
}

assert_policy_env_output() {
  [[ "$output" == *"ASDF_CONFIG_FILE=$BATS_TEST_TMPDIR/home/.config/asdf/.asdfrc"* ]]
  [[ "$output" == *"HOMEBREW_ASK=1"* ]]
  [[ "$output" == *"HOMEBREW_CASK_OPTS=--require-sha"* ]]
  [[ "$output" == *"HOMEBREW_NO_AUTO_UPDATE=1"* ]]
  [[ "$output" == *"HOMEBREW_NO_INSTALL_UPGRADE=1"* ]]
  [[ "$output" == *"HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1"* ]]
}

@test "dot_bashrc exports Homebrew policy env and ASDF_CONFIG_FILE" {
  run --separate-stderr env -i \
    HOME="$BATS_TEST_TMPDIR/home" \
    PATH="/usr/bin:/bin" \
    bash --noprofile --norc -c \
      'source "$1"; env | grep -E "^(HOMEBREW_|ASDF_CONFIG_FILE=)" | sort' \
      bash "$REPO_ROOT/dot_bashrc"

  [ "$status" -eq 0 ]
  assert_policy_env_output
}

@test "fish config declares the Homebrew policy env and ASDF_CONFIG_FILE" {
  fish_config="$REPO_ROOT/private_dot_config/private_fish/config.fish"

  assert_line_present "set -gx HOMEBREW_NO_AUTO_UPDATE 1" "$fish_config"
  assert_line_present "set -gx HOMEBREW_NO_INSTALL_UPGRADE 1" "$fish_config"
  assert_line_present "set -gx HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK 1" "$fish_config"
  assert_line_present "set -gx HOMEBREW_ASK 1" "$fish_config"
  assert_line_present "set -gx HOMEBREW_CASK_OPTS --require-sha" "$fish_config"
  assert_line_present 'set -gx ASDF_CONFIG_FILE $HOME/.config/asdf/.asdfrc' "$fish_config"
}

@test "fish config exports the Homebrew policy env and ASDF_CONFIG_FILE when fish is available" {
  command -v fish >/dev/null || skip "fish required to validate fish policy exports"

  run --separate-stderr env -i \
    HOME="$BATS_TEST_TMPDIR/home" \
    PATH="$PATH" \
    fish --no-config -c '
      function fish_config; end
      source "$argv[1]"
      env | grep -E "^(HOMEBREW_|ASDF_CONFIG_FILE=)" | sort
    ' "$REPO_ROOT/private_dot_config/private_fish/config.fish"

  [ "$status" -eq 0 ]
  assert_policy_env_output
}

@test "run-once package installer exports Homebrew policy env before brew calls" {
  script="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"
  first_brew_line="$(grep -n '^[[:space:]]*brew ' "$script" | cut -d: -f1 | head -n1)"
  [ -n "$first_brew_line" ]

  for line in \
    "export HOMEBREW_NO_AUTO_UPDATE=1" \
    "export HOMEBREW_NO_INSTALL_UPGRADE=1" \
    "export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1" \
    "export HOMEBREW_ASK=1" \
    "export HOMEBREW_CASK_OPTS=--require-sha"
  do
    assert_line_present "$line" "$script"
    policy_line="$(line_number_of "$line" "$script")"
    [ -n "$policy_line" ]
    [ "$policy_line" -lt "$first_brew_line" ]
  done
}

@test "Darwin run-once brew calls inherit Homebrew policy env" {
  script="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"
  stub_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_dir"

  cat >"$stub_dir/brew" <<'STUB'
#!/usr/bin/env bash
{
  printf 'args=%s\n' "$*"
  env | grep -E '^(HOMEBREW_)' | sort
} >>"$BREW_STUB_LOG"
STUB
  chmod +x "$stub_dir/brew"

  run --separate-stderr env -i \
    CHEZMOI_OS=darwin \
    PATH="$stub_dir:/usr/bin:/bin" \
    BREW_STUB_LOG="$BATS_TEST_TMPDIR/brew.log" \
    sh "$script"

  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/brew.log" ]
  output="$(cat "$BATS_TEST_TMPDIR/brew.log")"
  brew_call_count="$(grep -c '^args=' "$BATS_TEST_TMPDIR/brew.log")"
  [ "$brew_call_count" -gt 0 ]
  [[ "$output" == *"args=update"* ]]
  [ "$(grep -c '^HOMEBREW_ASK=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_CASK_OPTS=--require-sha$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_NO_AUTO_UPDATE=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_NO_INSTALL_UPGRADE=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
}

@test "managed asdf config disables the short-name repository" {
  asdfrc="$REPO_ROOT/private_dot_config/asdf/dot_asdfrc"

  assert_line_present "plugin_repository_last_check_duration = never" "$asdfrc"
  assert_line_present "disable_plugin_short_name_repository = yes" "$asdfrc"
}
