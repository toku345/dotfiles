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

assert_shell_policy_output() {
  grep -Fqx "ASDF_CONFIG_FILE=$BATS_TEST_TMPDIR/home/.config/asdf/.asdfrc" <<<"$output"

  local variable
  for variable in \
    HOMEBREW_CASK_OPTS \
    HOMEBREW_NO_AUTO_UPDATE \
    HOMEBREW_NO_INSTALL_UPGRADE \
    HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK \
    HOMEBREW_NO_VERIFY_ATTESTATIONS \
    HOMEBREW_UPDATE_TO_TAG \
    HOMEBREW_VERIFY_ATTESTATIONS
  do
    if grep -Eq "^${variable}=" <<<"$output"; then
      echo "$variable must be managed only in ~/.homebrew/brew.env" >&2
      return 1
    fi
  done
}

assert_bootstrap_policy_output() {
  local expected
  for expected in \
    "HOMEBREW_CASK_OPTS=--require-sha" \
    "HOMEBREW_NO_AUTO_UPDATE=1" \
    "HOMEBREW_NO_INSTALL_UPGRADE=1" \
    "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1" \
    "HOMEBREW_NO_VERIFY_ATTESTATIONS=1" \
    "HOMEBREW_UPDATE_TO_TAG=1"
  do
    grep -Fqx "$expected" <<<"$output"
  done
  # Current Homebrew defaults ask mode; HOMEBREW_ASK is deprecated upstream.
  # Bare `! grep` is exempt from bats errexit tracking, so branch explicitly.
  if grep -Eq "^HOMEBREW_ASK=" <<<"$output"; then
    echo "HOMEBREW_ASK must not be exported (deprecated in current Homebrew)" >&2
    return 1
  fi
  if grep -Eq "^HOMEBREW_VERIFY_ATTESTATIONS=" <<<"$output"; then
    echo "HOMEBREW_VERIFY_ATTESTATIONS must not be exported during bootstrap" >&2
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

brew_install_block_for_os() {
  local os="$1"
  local script="$2"

  case "$os" in
    darwin)
      sed -n '/if \[ "$CHEZMOI_OS" = "darwin" \]/,/elif \[ "$CHEZMOI_OS" = "linux" \]/p' "$script"
      ;;
    linux)
      sed -n '/elif \[ "$CHEZMOI_OS" = "linux" \]/,/^else$/p' "$script"
      ;;
    *)
      echo "unsupported test OS: $os" >&2
      return 2
      ;;
  esac
}

join_shell_continuations() {
  awk '
    {
      current = $0
      continued = sub(/[[:space:]]*\\[[:space:]]*$/, "", current)
      if (logical == "") {
        logical = current
      } else {
        logical = logical " " current
      }
      if (!continued) {
        print logical
        logical = ""
      }
    }
    END {
      if (logical != "") print logical
    }
  '
}

@test "managed brew.env declares the canonical Homebrew policy" {
  brew_env="$REPO_ROOT/dot_homebrew/brew.env"

  for line in \
    "HOMEBREW_NO_AUTO_UPDATE=1" \
    "HOMEBREW_NO_INSTALL_UPGRADE=1" \
    "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1" \
    "HOMEBREW_CASK_OPTS=--require-sha" \
    "HOMEBREW_UPDATE_TO_TAG=1" \
    "HOMEBREW_VERIFY_ATTESTATIONS=1"
  do
    assert_line_present "$line" "$brew_env"
  done

  assert_pattern_absent "HOMEBREW_ASK" "$brew_env"
  assert_pattern_absent "HOMEBREW_BUNDLE_NO_UPGRADE" "$brew_env"
  assert_pattern_absent "HOMEBREW_ALLOWED_TAPS" "$brew_env"
  assert_pattern_absent "HOMEBREW_NO_INSECURE_REDIRECT" "$brew_env"
  assert_pattern_absent "HOMEBREW_NO_VERIFY_ATTESTATIONS" "$brew_env"
}

@test "Homebrew reads the managed brew.env without shell exports" {
  if ! command -v brew >/dev/null; then
    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
      echo "brew required to validate the managed Homebrew environment in CI" >&2
      return 1
    fi
    skip "brew required to validate the managed Homebrew environment"
  fi

  policy_home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$policy_home/.homebrew"
  cp "$REPO_ROOT/dot_homebrew/brew.env" "$policy_home/.homebrew/brew.env"

  run env -i \
    HOME="$policy_home" \
    PATH="$PATH" \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_INSTALL_FROM_API=1 \
    brew config

  [ "$status" -eq 0 ]
  grep -Fqx "HOMEBREW_NO_AUTO_UPDATE: set" <<<"$output"
  grep -Fqx "HOMEBREW_UPDATE_TO_TAG: set" <<<"$output"
  grep -Fqx "HOMEBREW_VERIFY_ATTESTATIONS: set" <<<"$output"
}

@test "bootstrap attestation opt-out overrides managed brew.env on replay" {
  if ! command -v brew >/dev/null; then
    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
      echo "brew required to validate the bootstrap attestation override in CI" >&2
      return 1
    fi
    skip "brew required to validate the bootstrap attestation override"
  fi

  policy_home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$policy_home/.homebrew"
  cp "$REPO_ROOT/dot_homebrew/brew.env" "$policy_home/.homebrew/brew.env"

  run env -i \
    HOME="$policy_home" \
    PATH="$PATH" \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_INSTALL_FROM_API=1 \
    HOMEBREW_NO_VERIFY_ATTESTATIONS=1 \
    brew config

  [ "$status" -eq 0 ]
  grep -Fqx "HOMEBREW_NO_VERIFY_ATTESTATIONS: set" <<<"$output"
  if [[ $'\n'"$output"$'\n' == *$'\nHOMEBREW_VERIFY_ATTESTATIONS: set\n'* ]]; then
    echo "bootstrap opt-out must disable HOMEBREW_VERIFY_ATTESTATIONS" >&2
    return 1
  fi
}

@test "dot_bashrc leaves Homebrew policy to brew.env and exports ASDF_CONFIG_FILE" {
  run env -i \
    HOME="$BATS_TEST_TMPDIR/home" \
    PATH="/usr/bin:/bin" \
    bash --noprofile --norc -c \
      'source "$1"; env | grep -E "^(HOMEBREW_|ASDF_CONFIG_FILE=)" | sort' \
      bash "$REPO_ROOT/dot_bashrc"

  [ "$status" -eq 0 ]
  assert_shell_policy_output
}

@test "fish config leaves Homebrew policy to brew.env and declares ASDF_CONFIG_FILE" {
  fish_config="$REPO_ROOT/private_dot_config/private_fish/config.fish"

  assert_pattern_absent "set -gx HOMEBREW_NO_AUTO_UPDATE" "$fish_config"
  assert_pattern_absent "set -gx HOMEBREW_NO_INSTALL_UPGRADE" "$fish_config"
  assert_pattern_absent "set -gx HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" "$fish_config"
  assert_pattern_absent "set -gx HOMEBREW_CASK_OPTS" "$fish_config"
  assert_pattern_absent "set -gx HOMEBREW_UPDATE_TO_TAG" "$fish_config"
  assert_pattern_absent "set -gx HOMEBREW_VERIFY_ATTESTATIONS" "$fish_config"
  assert_pattern_absent "HOMEBREW_ASK" "$fish_config"
  assert_line_present 'set -gx ASDF_CONFIG_FILE $HOME/.config/asdf/.asdfrc' "$fish_config"
}

@test "fish config exports ASDF_CONFIG_FILE without duplicating Homebrew policy when fish is available" {
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
  assert_shell_policy_output
}

@test "run-once package installer exports Homebrew policy env before OS branch and brew calls" {
  script="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"
  first_os_branch_line="$(grep -n '^[[:space:]]*if \[ "\$CHEZMOI_OS" = ' "$script" | cut -d: -f1 | head -n1)"
  first_brew_line="$(grep -n '^[[:space:]]*brew ' "$script" | cut -d: -f1 | head -n1)"
  [ -n "$first_os_branch_line" ]
  [ -n "$first_brew_line" ]

  assert_pattern_absent "HOMEBREW_ASK" "$script"
  assert_pattern_absent "export HOMEBREW_VERIFY_ATTESTATIONS=" "$script"

  for line in \
    "export HOMEBREW_NO_AUTO_UPDATE=1" \
    "export HOMEBREW_NO_INSTALL_UPGRADE=1" \
    "export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1" \
    "export HOMEBREW_NO_VERIFY_ATTESTATIONS=1" \
    "export HOMEBREW_CASK_OPTS=--require-sha" \
    "export HOMEBREW_UPDATE_TO_TAG=1"
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
  assert_bootstrap_policy_output
  [ "$(grep -c '^HOMEBREW_CASK_OPTS=--require-sha$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_NO_AUTO_UPDATE=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_NO_INSTALL_UPGRADE=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_NO_VERIFY_ATTESTATIONS=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
  [ "$(grep -c '^HOMEBREW_UPDATE_TO_TAG=1$' "$BATS_TEST_TMPDIR/brew.log")" -eq "$brew_call_count" ]
}

@test "run-once installer includes Herdr in Homebrew packages on macOS and Linux" {
  script="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"

  for os in darwin linux; do
    block="$(brew_install_block_for_os "$os" "$script")"
    normalized="$(printf '%s\n' "$block" | join_shell_continuations)"
    set +e
    grep -Eq '^[[:space:]]*brew[[:space:]]+install([[:space:]]+[^[:space:]]+)*[[:space:]]+herdr([[:space:]]|$)' <<<"$normalized"
    grep_status="$?"
    set -e
    case "$grep_status" in
      0) ;;
      1)
        echo "Herdr missing from $os Homebrew package list" >&2
        return 1
        ;;
      *)
        echo "grep failed while checking $os Homebrew package list" >&2
        return 2
        ;;
    esac
  done
}

@test "managed asdf config disables the short-name repository" {
  asdfrc="$REPO_ROOT/private_dot_config/asdf/dot_asdfrc"

  assert_line_present "plugin_repository_last_check_duration = never" "$asdfrc"
  assert_line_present "disable_plugin_short_name_repository = yes" "$asdfrc"
}
