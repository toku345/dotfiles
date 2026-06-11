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
  local expected
  for expected in \
    "ASDF_CONFIG_FILE=$BATS_TEST_TMPDIR/home/.config/asdf/.asdfrc" \
    "HOMEBREW_CASK_OPTS=--require-sha" \
    "HOMEBREW_NO_AUTO_UPDATE=1" \
    "HOMEBREW_NO_INSTALL_UPGRADE=1" \
    "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1"
  do
    grep -Fqx "$expected" <<<"$output"
  done
  # Current Homebrew defaults ask mode; HOMEBREW_ASK is deprecated upstream.
  # Bare `! grep` is exempt from bats errexit tracking, so branch explicitly.
  if grep -Eq "^HOMEBREW_ASK=" <<<"$output"; then
    echo "HOMEBREW_ASK must not be exported (deprecated in current Homebrew)" >&2
    return 1
  fi
}

# Discriminate grep exit codes like refute_grep in test_secret_scanning_baseline.bats:
# a bare `if grep ...` treats grep errors (exit 2: missing/unreadable file, bad
# pattern) the same as "pattern absent" and silently passes.
assert_pattern_absent() {
  local pattern="$1"
  local file="$2"
  local grep_status
  set +e
  grep -q "$pattern" "$file"
  grep_status="$?"
  set -e
  case "$grep_status" in
    0)
      echo "pattern '$pattern' must not appear in $file" >&2
      return 1
      ;;
    1) return 0 ;;
    *)
      echo "grep failed (status $grep_status) while checking '$pattern' in $file" >&2
      return 2
      ;;
  esac
}

@test "dot_bashrc exports Homebrew policy env and ASDF_CONFIG_FILE" {
  run env -i \
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
  assert_line_present "set -gx HOMEBREW_CASK_OPTS --require-sha" "$fish_config"
  assert_pattern_absent "HOMEBREW_ASK" "$fish_config"
  assert_line_present 'set -gx ASDF_CONFIG_FILE $HOME/.config/asdf/.asdfrc' "$fish_config"
}

@test "fish config exports the Homebrew policy env and ASDF_CONFIG_FILE when fish is available" {
  if ! command -v fish >/dev/null; then
    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
      echo "fish required to validate fish policy exports in CI" >&2
      return 1
    fi
    skip "fish required to validate fish policy exports"
  fi

  run env -i \
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

@test "run-once package installer exports Homebrew policy env before OS branch and brew calls" {
  script="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"
  first_os_branch_line="$(grep -n '^[[:space:]]*if \[ "\$CHEZMOI_OS" = ' "$script" | cut -d: -f1 | head -n1)"
  first_brew_line="$(grep -n '^[[:space:]]*brew ' "$script" | cut -d: -f1 | head -n1)"
  [ -n "$first_os_branch_line" ]
  [ -n "$first_brew_line" ]

  assert_pattern_absent "HOMEBREW_ASK" "$script"

  for line in \
    "export HOMEBREW_NO_AUTO_UPDATE=1" \
    "export HOMEBREW_NO_INSTALL_UPGRADE=1" \
    "export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1" \
    "export HOMEBREW_CASK_OPTS=--require-sha"
  do
    assert_line_present "$line" "$script"
    policy_line="$(line_number_of "$line" "$script")"
    [ -n "$policy_line" ]
    [ "$policy_line" -lt "$first_os_branch_line" ]
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

  run env -i \
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
  assert_pattern_absent '^HOMEBREW_ASK=' "$BATS_TEST_TMPDIR/brew.log"
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
