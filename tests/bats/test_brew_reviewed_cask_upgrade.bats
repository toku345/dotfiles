#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SOURCE="$REPO_ROOT/dot_local/bin/executable_brew-reviewed-cask-upgrade"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  BREW_STUB_LOG="$BATS_TEST_TMPDIR/brew.log"
  BREW_STUB_ENV_LOG="$BATS_TEST_TMPDIR/brew-env.log"
  GH_STUB_LOG="$BATS_TEST_TMPDIR/gh.log"
  SMOKE_STUB_LOG="$BATS_TEST_TMPDIR/smoke.log"
  BREW_STUB_UPDATED="$BATS_TEST_TMPDIR/updated"
  BREW_STUB_UPGRADED="$BATS_TEST_TMPDIR/upgraded"
  BREW_STUB_INSTALLED_COUNT="$BATS_TEST_TMPDIR/installed-count"
  BREW_STUB_SIGNAL_MARKER="$BATS_TEST_TMPDIR/upgrade-started"
  BREW_STUB_SIGNAL_RESULT="$BATS_TEST_TMPDIR/upgrade-signal"
  YES_FILE="$BATS_TEST_TMPDIR/yes"
  NO_FILE="$BATS_TEST_TMPDIR/no"

  mkdir -p "$TEST_HOME/.homebrew" "$TEST_BIN"
  cp "$REPO_ROOT/dot_homebrew/brew.env" "$TEST_HOME/.homebrew/brew.env"
  printf 'yes\n' >"$YES_FILE"
  printf 'no\n' >"$NO_FILE"
  : >"$BREW_STUB_LOG"
  : >"$BREW_STUB_ENV_LOG"
  : >"$GH_STUB_LOG"
  printf '0\n' >"$BREW_STUB_INSTALLED_COUNT"

  export SOURCE TEST_HOME TEST_BIN BREW_STUB_LOG BREW_STUB_ENV_LOG
  export GH_STUB_LOG SMOKE_STUB_LOG BREW_STUB_UPDATED BREW_STUB_UPGRADED
  export BREW_STUB_INSTALLED_COUNT
  export BREW_STUB_SIGNAL_MARKER BREW_STUB_SIGNAL_RESULT
  export HOME="$TEST_HOME"
  resolve_bash5
  export PATH="$TEST_BIN:/usr/bin:/bin"
  export BREW_STUB_CASK="codex"

  cat >"$TEST_BIN/brew-reviewed-cask-upgrade" <<'EOF'
#!/bin/sh
exec "$BASH5_BIN" "$SOURCE" "$@"
EOF

  cat >"$TEST_BIN/smoke-command" <<'EOF'
#!/usr/bin/env bash
{
  printf 'argc=%s\n' "$#"
  for argument in "$@"; do
    printf '<%s>\n' "$argument"
  done
} >"$SMOKE_STUB_LOG"
exit "${SMOKE_STUB_STATUS:-0}"
EOF

  cat >"$TEST_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_LOG"
if [[ "$*" == "auth status --hostname github.com" ]]; then
  exit "${GH_STUB_AUTH_STATUS:-0}"
fi
if [[ "${1:-}" == "api" ]]; then
  if [[ "${GH_STUB_API_STATUS:-0}" != "0" ]]; then
    exit "$GH_STUB_API_STATUS"
  fi
  printf '{"tag_name":"%s","html_url":"%s","published_at":"%s","draft":%s,"prerelease":%s}\n' \
    "${GH_STUB_RELEASE_TAG:-v2.0.0}" \
    "${GH_STUB_RELEASE_URL:-https://github.com/openai/codex/releases/tag/v2.0.0}" \
    "${GH_STUB_PUBLISHED_AT:-2020-01-01T00:00:00Z}" \
    "${GH_STUB_DRAFT:-false}" \
    "${GH_STUB_PRERELEASE:-false}"
  exit 0
fi
exit 2
EOF

  cat >"$TEST_BIN/brew" <<'EOF'
#!/usr/bin/env bash
set -u

{
  first=1
  for argument in "$@"; do
    if (( first )); then first=0; else printf '\t'; fi
    printf '%s' "$argument"
  done
  printf '\n'
} >>"$BREW_STUB_LOG"

command_name="${1:-}"
shift || true
printf '%s\t%s\t%s\t%s\n' \
  "$command_name" \
  "${HOMEBREW_NO_INSTALL_CLEANUP-unset}" \
  "${HOMEBREW_NO_ENV_HINTS-unset}" \
  "$*" >>"$BREW_STUB_ENV_LOG"

safe_artifacts='[{"binary":["bin/codex"],"target":"/prefix/bin/codex"},{"generate_completions_from_executable":["bin/codex","completion",{"shells":["bash","fish","zsh"]}]},{"zap":[{"rmdir":"~/.codex"}]}]'
old_sha='1111111111111111111111111111111111111111111111111111111111111111'
new_sha='2222222222222222222222222222222222222222222222222222222222222222'

metadata_overrides() {
  local mode="$1"
  tap='homebrew/cask'
  installed='1.0.0'
  pinned=false
  deprecated=false
  disabled=false
  auto_updates=null
  version='2.0.0'
  sha256="$new_sha"
  url='https://github.com/openai/codex/releases/download/v2.0.0/codex.tar.gz'
  homepage='https://github.com/openai/codex'
  artifacts="$safe_artifacts"
  depends_on='{}'
  conflicts_with='null'

  case "$mode" in
    installed)
      version='1.0.0'
      sha256="$old_sha"
      ;;
    current)
      version='1.0.0'
      sha256="$old_sha"
      url='https://github.com/openai/codex/releases/download/v1.0.0/codex.tar.gz'
      ;;
    nonofficial) tap='vendor/tap' ;;
    uninstalled) installed=null ;;
    pinned) pinned=true ;;
    deprecated) deprecated=true ;;
    disabled) disabled=true ;;
    auto) auto_updates=true ;;
    auto_malformed) auto_updates='"false"' ;;
    latest) version='latest' ;;
    nocheck) sha256='no_check' ;;
    badsha) sha256='abc' ;;
    dangerous) artifacts='[{"pkg":["tool.pkg"]}]' ;;
    unknown) artifacts='[{"binary":["bin/codex"]},{"future_artifact":["x"]}]' ;;
    dependency) depends_on='{"formula":["openssl@3"]}' ;;
    conflict) conflicts_with='{"cask":["other"]}' ;;
    nongithub) url='https://vendor.example/codex-2.0.0.tar.gz' ;;
  esac
}

print_metadata() {
  local mode="$1"
  local token="${2:-$BREW_STUB_CASK}"
  metadata_overrides "$mode"
  printf '{"formulae":[],"casks":[{"token":"%s","full_token":"%s","tap":"%s","version":%s,"sha256":%s,"auto_updates":%s,"installed":%s,"pinned":%s,"deprecated":%s,"disabled":%s,"url":"%s","homepage":"%s","artifacts":%s,"depends_on":%s,"conflicts_with":%s}]}\n' \
    "$token" "$token" "$tap" \
    "$(printf '%s' "$version" | jq -R .)" \
    "$(printf '%s' "$sha256" | jq -R .)" \
    "$auto_updates" \
    "$(if [[ "$installed" == null ]]; then printf null; else printf '%s' "$installed" | jq -R .; fi)" \
    "$pinned" "$deprecated" "$disabled" "$url" "$homepage" \
    "$artifacts" "$depends_on" "$conflicts_with"
}

case "$command_name" in
  config)
    cat <<'CONFIG'
HOMEBREW_CASK_OPTS: ["--require-sha"]
HOMEBREW_NO_AUTO_UPDATE: set
HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK: set
HOMEBREW_NO_INSTALL_UPGRADE: set
HOMEBREW_UPDATE_TO_TAG: set
HOMEBREW_VERIFY_ATTESTATIONS: set
CONFIG
    [[ "${BREW_STUB_EFFECTIVE_NO_ASK:-false}" == true ]] && printf 'HOMEBREW_NO_ASK: set\n'
    exit 0
    ;;
  developer)
    if [[ "${1:-}" == state ]]; then
      if [[ "${BREW_STUB_DEVELOPER_ENABLED:-false}" == true ]]; then
        printf 'Developer mode is enabled.\n'
      else
        printf 'Developer mode is disabled.\n'
      fi
      exit "${BREW_STUB_DEVELOPER_STATUS:-0}"
    fi
    exit 2
    ;;
  info)
    if [[ "$*" == *"--installed"* ]]; then
      count="$(cat "$BREW_STUB_INSTALLED_COUNT")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$BREW_STUB_INSTALLED_COUNT"
      if [[ "${BREW_STUB_INSTALLED_MISSING:-false}" == true ]]; then
        printf '{"formulae":[],"casks":[]}\n'
      elif [[ "${BREW_STUB_INSTALLED_AMBIGUOUS:-false}" == true ]]; then
        printf '{"formulae":[],"casks":['
        print_metadata installed | jq -c '.casks[0]'
        printf ','
        print_metadata installed | jq -c '.casks[0]'
        printf ']}\n'
      else
        mode="${BREW_STUB_INSTALLED_MODE:-installed}"
        if [[ "${BREW_STUB_INSTALLED_DRIFT:-false}" == true && "$count" -gt 1 ]]; then
          mode=dependency
        fi
        print_metadata "$mode"
      fi
      exit 0
    fi
    mode="${BREW_STUB_CANDIDATE_MODE:-normal}"
    [[ "$mode" == normal ]] && mode='candidate'
    token="$BREW_STUB_CASK"
    if [[ -e "$BREW_STUB_UPDATED" && -n "${BREW_STUB_POST_UPDATE_TOKEN:-}" ]]; then
      token="$BREW_STUB_POST_UPDATE_TOKEN"
    fi
    if [[ "${BREW_STUB_CURRENT:-false}" == true ]]; then
      mode=current
    fi
    if [[ -e "$BREW_STUB_UPGRADED" ]]; then
      if [[ "${BREW_STUB_POST_MODE:-normal}" != normal ]]; then
        mode="$BREW_STUB_POST_MODE"
      fi
      print_metadata "$mode" "$token" | jq '.casks[0].installed = "2.0.0"'
    else
      print_metadata "$mode" "$token"
    fi
    ;;
  update)
    : >"$BREW_STUB_UPDATED"
    exit "${BREW_STUB_UPDATE_STATUS:-0}"
    ;;
  outdated)
    case "${BREW_STUB_OUTDATED_MODE:-outdated}" in
      current)
        printf '{"formulae":[],"casks":[]}\n'
        exit 0
        ;;
      contradictory)
        printf '{"formulae":[],"casks":[]}\n'
        exit 1
        ;;
      malformed)
        printf 'not-json\n'
        exit 0
        ;;
      outdated)
        printf '{"formulae":[],"casks":[{"name":"%s","installed_versions":["1.0.0"],"current_version":"2.0.0","pinned":false}]}\n' "$BREW_STUB_CASK"
        exit 1
        ;;
    esac
    ;;
  upgrade)
    if [[ "$*" == *"--dry-run"* ]]; then
      [[ "${BREW_STUB_DRY_RUN_EMPTY:-false}" == true ]] || printf 'Would upgrade %s 1.0.0 -> 2.0.0\n' "$BREW_STUB_CASK"
      exit "${BREW_STUB_DRY_RUN_STATUS:-0}"
    fi
    if [[ "${BREW_STUB_BLOCK_UPGRADE:-false}" == true ]]; then
      : >"$BREW_STUB_SIGNAL_MARKER"
      trap 'printf INT >"$BREW_STUB_SIGNAL_RESULT"; exit 130' INT
      trap 'printf TERM >"$BREW_STUB_SIGNAL_RESULT"; exit 143' TERM
      while :; do sleep 0.05; done
    fi
    if [[ "${BREW_STUB_UPGRADE_STATUS:-0}" == 0 ]]; then
      : >"$BREW_STUB_UPGRADED"
    fi
    exit "${BREW_STUB_UPGRADE_STATUS:-0}"
    ;;
  *)
    printf 'unexpected brew command: %s\n' "$command_name" >&2
    exit 2
    ;;
esac
EOF

  ln -s "$(type -P jq)" "$TEST_BIN/jq"
  chmod +x "$TEST_BIN/brew-reviewed-cask-upgrade" "$TEST_BIN/brew" \
    "$TEST_BIN/gh" "$TEST_BIN/smoke-command"
}

assert_log_order() {
  local previous=0 pattern line
  for pattern in "$@"; do
    line="$(grep -n -m1 -F "$pattern" "$BREW_STUB_LOG" | cut -d: -f1)"
    [[ -n "$line" ]]
    (( line > previous ))
    previous="$line"
  done
}

refute_log_contains() {
  ! grep -Fq -- "$1" "$BREW_STUB_LOG"
}

@test "successful Cask upgrade preserves arguments and strict command order" {
  run --separate-stderr brew-reviewed-cask-upgrade codex -- \
    smoke-command "two words" "*" <"$YES_FILE"

  [ "$status" -eq 0 ]
  grep -Fxq 'argc=2' "$SMOKE_STUB_LOG"
  grep -Fxq '<two words>' "$SMOKE_STUB_LOG"
  grep -Fxq '<*>' "$SMOKE_STUB_LOG"
  assert_log_order \
    'config' \
    $'developer\tstate' \
    $'info\t--cask\t--json=v2\tcodex' \
    $'info\t--cask\t--json=v2\t--installed' \
    'update' \
    $'outdated\t--cask\t--json=v2\tcodex' \
    $'upgrade\t--cask\t--dry-run\t--require-sha\t--no-quit\t--skip-cask-deps\tcodex' \
    $'upgrade\t--cask\t--no-ask\t--require-sha\t--no-quit\t--skip-cask-deps\tcodex'
  grep -Fq 'SHA-256: 222222222222' <<<"$output"
  grep -Fq 'generate_completions_from_executable' <<<"$output"
  grep -Fq 'Cooldown: eligible' <<<"$output"
  grep -Fq 'Installed Cask version verified: codex 2.0.0' <<<"$output"
  grep -Fq $'upgrade\t1\t1\t--cask --dry-run --require-sha --no-quit --skip-cask-deps codex' "$BREW_STUB_ENV_LOG"
  grep -Fq $'upgrade\t1\t1\t--cask --no-ask --require-sha --no-quit --skip-cask-deps codex' "$BREW_STUB_ENV_LOG"
}

@test "help and usage errors do not invoke Homebrew" {
  run brew-reviewed-cask-upgrade --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"A smoke command is always required"* ]]

  run brew-reviewed-cask-upgrade codex
  [ "$status" -eq 2 ]

  run brew-reviewed-cask-upgrade codex other -- smoke-command
  [ "$status" -eq 2 ]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "unavailable smoke command fails before Homebrew" {
  run -127 brew-reviewed-cask-upgrade codex -- missing-smoke
  [ "$status" -eq 127 ]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "cooldown exception requires one non-empty single-line reason" {
  run brew-reviewed-cask-upgrade --cooldown-exception "" codex -- smoke-command
  [ "$status" -eq 2 ]
  run brew-reviewed-cask-upgrade --cooldown-exception $'one\ntwo' codex -- smoke-command
  [ "$status" -eq 2 ]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "managed and effective policy drift fail before metadata update" {
  sed '/HOMEBREW_CASK_OPTS/d' "$HOME/.homebrew/brew.env" \
    >"$HOME/.homebrew/brew.env.tmp"
  mv "$HOME/.homebrew/brew.env.tmp" "$HOME/.homebrew/brew.env"
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  refute_log_contains $'update'

  cp "$REPO_ROOT/dot_homebrew/brew.env" "$HOME/.homebrew/brew.env"
  export BREW_STUB_EFFECTIVE_NO_ASK=true
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  refute_log_contains $'update'
}

@test "enabled developer mode fails before metadata update" {
  export BREW_STUB_DEVELOPER_ENABLED=true
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"developer mode must be disabled"* ]]
  refute_log_contains $'update'
}

@test "unsupported candidate metadata is rejected before brew update" {
  local mode
  for mode in nonofficial uninstalled pinned deprecated disabled auto auto_malformed latest \
    nocheck badsha dangerous unknown dependency conflict; do
    export BREW_STUB_CANDIDATE_MODE="$mode"
    run brew-reviewed-cask-upgrade codex -- smoke-command
    [ "$status" -eq 1 ]
    [[ "$output" == *"outside the strict supported scope"* ]]
    refute_log_contains $'update'
    unset BREW_STUB_CANDIDATE_MODE
    : >"$BREW_STUB_LOG"
  done
}

@test "unsafe or missing installed metadata is rejected before brew update" {
  export BREW_STUB_INSTALLED_MODE=dangerous
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  refute_log_contains $'update'

  unset BREW_STUB_INSTALLED_MODE
  export BREW_STUB_INSTALLED_MISSING=true
  : >"$BREW_STUB_LOG"
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing or ambiguous"* ]]
  refute_log_contains $'update'
}

@test "already-current Cask is a successful no-op after brew update" {
  export BREW_STUB_CURRENT=true
  export BREW_STUB_OUTDATED_MODE=current
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  grep -Fxq 'update' "$BREW_STUB_LOG"
  refute_log_contains $'upgrade\t'
  [ ! -e "$SMOKE_STUB_LOG" ]
}

@test "outdated status and JSON disagreements fail closed" {
  export BREW_STUB_OUTDATED_MODE=contradictory
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"status and JSON disagree"* ]]
  refute_log_contains $'upgrade\t'

  export BREW_STUB_OUTDATED_MODE=malformed
  : >"$BREW_STUB_LOG"
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed JSON"* ]]
}

@test "Cask identity drift after brew update fails before dry-run" {
  export BREW_STUB_POST_UPDATE_TOKEN=codex-renamed
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"identity changed"* ]]
  refute_log_contains $'upgrade\t'
}

@test "non-GitHub Cask requires a reasoned exception without requiring gh" {
  export BREW_STUB_CANDIDATE_MODE=nongithub
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a supported GitHub release URL"* ]]
  [ ! -s "$GH_STUB_LOG" ]

  run brew-reviewed-cask-upgrade --cooldown-exception \
    "vendor release reviewed" codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cooldown: exception"* ]]
  [ ! -s "$GH_STUB_LOG" ]
}

@test "GitHub auth and API failures require an exception" {
  export GH_STUB_AUTH_STATUS=1
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"authentication failed"* ]]

  run brew-reviewed-cask-upgrade --cooldown-exception \
    "release reviewed manually" codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 0 ]

  unset GH_STUB_AUTH_STATUS
  export GH_STUB_API_STATUS=22
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"lookup failed with status 22"* ]]
}

@test "missing gh is an exception-eligible release condition" {
  local command_path no_gh_bin="$BATS_TEST_TMPDIR/no-gh-bin"
  mkdir "$no_gh_bin"
  for command_path in awk cat cmp grep mktemp rm; do
    ln -s "$(type -P "$command_path")" "$no_gh_bin/$command_path"
  done
  ln -s "$BASH5_BIN" "$no_gh_bin/bash"
  ln -s "$TEST_BIN/brew" "$no_gh_bin/brew"
  ln -s "$TEST_BIN/jq" "$no_gh_bin/jq"
  ln -s "$TEST_BIN/smoke-command" "$no_gh_bin/smoke-command"

  run env PATH="$no_gh_bin" "$BASH5_BIN" "$SOURCE" \
    --cooldown-exception \
    "release reviewed manually" codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub CLI is unavailable"* ]]
  [[ "$output" != *"required command not found"* ]]
}

@test "new draft and prerelease gates fail closed without an exception" {
  export GH_STUB_PUBLISHED_AT=2999-01-01T00:00:00Z
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]

  export GH_STUB_PUBLISHED_AT=2020-01-01T00:00:00Z
  export GH_STUB_DRAFT=true
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"Release is a draft"* ]]

  unset GH_STUB_DRAFT
  export GH_STUB_PRERELEASE=true
  run brew-reviewed-cask-upgrade codex -- smoke-command
  [ "$status" -eq 1 ]
  [[ "$output" == *"marked as a prerelease"* ]]
}

@test "an unnecessary exception is reported but does not weaken the flow" {
  run brew-reviewed-cask-upgrade --cooldown-exception \
    "reviewed" codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"eligible (exception not needed)"* ]]
}

@test "failed or empty dry-run stops before confirmation and upgrade" {
  export BREW_STUB_DRY_RUN_STATUS=3
  run brew-reviewed-cask-upgrade codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dry-run failed"* ]]
  refute_log_contains $'upgrade\t--cask\t--no-ask'

  unset BREW_STUB_DRY_RUN_STATUS
  export BREW_STUB_DRY_RUN_EMPTY=true
  run brew-reviewed-cask-upgrade codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no reviewable output"* ]]
}

@test "rejection and EOF do not upgrade the Cask" {
  run brew-reviewed-cask-upgrade codex -- smoke-command <"$NO_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upgrade rejected"* ]]
  refute_log_contains $'upgrade\t--cask\t--no-ask'

  run brew-reviewed-cask-upgrade codex -- smoke-command </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"confirmation input ended"* ]]
}

@test "dry-run display failure and prompt failure cannot continue" {
  run --separate-stderr "$BASH5_BIN" -c '
    source "$SOURCE"
    BREW_BIN="$TEST_BIN/brew"
    TEMP_DIR="$(mktemp -d)"
    printf "plan\n" >"$TEMP_DIR/dry-run"
    cat() { return 42; }
    show_dry_run codex
  '
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not display the Cask dry-run"* ]]

  run --separate-stderr "$BASH5_BIN" -c '
    source "$SOURCE"
    printf() {
      if [[ "$1" == "%s" && "${2:-}" == "Proceed with the displayed Cask metadata"* ]]; then
        return 42
      fi
      command printf "$@"
    }
    confirm_review codex
  ' <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not display the Cask review confirmation prompt"* ]]
}

@test "installed metadata drift before mutation fails closed" {
  export BREW_STUB_INSTALLED_DRIFT=true
  run brew-reviewed-cask-upgrade codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"installed Cask metadata"* || "$output" == *"safety metadata changed"* ]]
  refute_log_contains $'upgrade\t--cask\t--no-ask'
}

@test "upgrade failure stops post-check and smoke" {
  export BREW_STUB_UPGRADE_STATUS=7
  run brew-reviewed-cask-upgrade codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 7 ]
  [[ "$output" == *"failed with status 7"* ]]
  [ ! -e "$SMOKE_STUB_LOG" ]
}

@test "post-upgrade metadata mismatch stops smoke and reports possible mutation" {
  export BREW_STUB_POST_MODE=badsha
  run brew-reviewed-cask-upgrade codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"post-upgrade Cask metadata"* || "$output" == *"may already be modified"* ]]
  [ ! -e "$SMOKE_STUB_LOG" ]
}

@test "smoke failure is returned after the reviewed upgrade" {
  export SMOKE_STUB_STATUS=9
  run brew-reviewed-cask-upgrade codex -- smoke-command <"$YES_FILE"
  [ "$status" -eq 9 ]
  [[ "$output" == *"Running smoke command failed with status 9"* ]]
}

@test "TERM during Cask upgrade is forwarded and returns 143" {
  local output_file="$BATS_TEST_TMPDIR/signal-output"
  local error_file="$BATS_TEST_TMPDIR/signal-error"
  local helper_pid status=0
  export BREW_STUB_BLOCK_UPGRADE=true

  brew-reviewed-cask-upgrade codex -- smoke-command <"$YES_FILE" \
    >"$output_file" 2>"$error_file" &
  helper_pid=$!
  for ((i = 0; i < 50; i++)); do
    [[ -e "$BREW_STUB_SIGNAL_MARKER" ]] && break
    sleep 0.05
  done
  [ -e "$BREW_STUB_SIGNAL_MARKER" ]
  kill -TERM "$helper_pid"
  if wait "$helper_pid"; then status=0; else status=$?; fi

  [ "$status" -eq 143 ]
  [ "$(cat "$BREW_STUB_SIGNAL_RESULT")" = TERM ]
  [ ! -e "$SMOKE_STUB_LOG" ]
}
