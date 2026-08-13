#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SOURCE="$REPO_ROOT/dot_local/bin/executable_brew-reviewed-upgrade"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  BREW_STUB_LOG="$BATS_TEST_TMPDIR/brew.log"
  SMOKE_STUB_LOG="$BATS_TEST_TMPDIR/smoke.log"
  BREW_STUB_SIGNAL_MARKER="$BATS_TEST_TMPDIR/verify-started"
  YES_FILE="$BATS_TEST_TMPDIR/yes"
  NO_FILE="$BATS_TEST_TMPDIR/no"

  mkdir -p "$TEST_HOME/.homebrew" "$TEST_BIN"
  cp "$REPO_ROOT/dot_homebrew/brew.env" "$TEST_HOME/.homebrew/brew.env"
  printf 'yes\n' >"$YES_FILE"
  printf 'no\n' >"$NO_FILE"
  : >"$BREW_STUB_LOG"

  export SOURCE TEST_HOME TEST_BIN BREW_STUB_LOG SMOKE_STUB_LOG
  export BREW_STUB_SIGNAL_MARKER
  export HOME="$TEST_HOME"
  export PATH="$TEST_BIN:/usr/bin:/bin"
  export BREW_STUB_FORMULA="ripgrep"
  export BREW_STUB_ROOT_DEPS="pcre2"
  export BREW_STUB_DEP_DEPS=""

  cat >"$TEST_BIN/brew-reviewed-upgrade" <<'EOF'
#!/usr/bin/env bash
exec bash "$SOURCE" "$@"
EOF

  cat >"$TEST_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "auth status --hostname github.com" ]]; then
  exit "${GH_STUB_STATUS:-0}"
fi
exit 2
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

  cat >"$TEST_BIN/brew" <<'EOF'
#!/usr/bin/env bash
set -u

{
  first=1
  for argument in "$@"; do
    if (( first )); then
      first=0
    else
      printf '\t'
    fi
    printf '%s' "$argument"
  done
  printf '\n'
} >>"$BREW_STUB_LOG"

command_name="${1:-}"
shift || true

formula_info() {
  local requested="${!#}"
  local canonical="$requested"
  local tap="homebrew/core"
  local pinned=false
  local bottle=true
  local bottle_files='{"arm64_linux":{}}'
  local installed='[]'

  if [[ "$requested" == "visual-studio-code" ]]; then
    exit 1
  fi
  if [[ "${BREW_STUB_INFO_STATUS:-0}" != "0" && "$requested" == "$BREW_STUB_FORMULA" ]]; then
    exit "$BREW_STUB_INFO_STATUS"
  fi
  if [[ "$requested" == "${BREW_STUB_ALIAS:-}" ]]; then
    canonical="$BREW_STUB_FORMULA"
  fi
  if [[ "$canonical" == "$BREW_STUB_FORMULA" ]]; then
    tap="${BREW_STUB_TARGET_TAP:-homebrew/core}"
    pinned="${BREW_STUB_PINNED:-false}"
    bottle="${BREW_STUB_BOTTLE:-true}"
    if [[ "${BREW_STUB_BOTTLE_FILES:-present}" == "missing" ]]; then
      bottle_files='{}'
    fi
    if [[ "${BREW_STUB_INSTALLED:-true}" == "true" ]]; then
      installed='[{"version":"1.0","built_as_bottle":true,"poured_from_bottle":true}]'
      if [[ "${BREW_STUB_SOURCE_INSTALL:-false}" == "true" ]]; then
        installed='[{"version":"1.0","built_as_bottle":false,"poured_from_bottle":false}]'
      fi
    fi
  elif [[ "$canonical" == "foreign/dep" ]]; then
    tap="vendor/tap"
  fi

  printf '{"formulae":[{"name":"%s","full_name":"%s","tap":"%s","pinned":%s,"versions":{"bottle":%s},"bottle":{"stable":{"files":%s}},"installed":%s}]}\n' \
    "$canonical" "$canonical" "$tap" "$pinned" "$bottle" "$bottle_files" "$installed"
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
    if [[ "${BREW_STUB_POLICY_OVERRIDE:-}" == "no-verify" ]]; then
      printf 'HOMEBREW_NO_VERIFY_ATTESTATIONS: set\n'
    fi
    ;;
  developer)
    subcommand="${1:-}"
    case "$subcommand" in
      state)
        if [[ "${BREW_STUB_DEVELOPER_ENABLED:-false}" == "true" ]]; then
          printf 'Developer mode is enabled.\n'
        else
          printf 'Developer mode is disabled.\n'
        fi
        exit "${BREW_STUB_DEVELOPER_STATE_STATUS:-0}"
        ;;
      off)
        exit "${BREW_STUB_DEVELOPER_OFF_STATUS:-0}"
        ;;
    esac
    exit 2
    ;;
  info)
    formula_info "$@"
    ;;
  update)
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
        printf '{"formulae":[{"name":"%s","installed_versions":["1.0"],"current_version":"2.0","pinned":false}],"casks":[]}\n' "$BREW_STUB_FORMULA"
        exit 1
        ;;
    esac
    ;;
  upgrade)
    for argument in "$@"; do
      if [[ "$argument" == "--dry-run" ]]; then
        if [[ "${BREW_STUB_DRY_RUN_EMPTY:-false}" != "true" ]]; then
          printf 'Would upgrade %s 1.0 -> 2.0\n' "$BREW_STUB_FORMULA"
        fi
        exit "${BREW_STUB_DRY_RUN_STATUS:-0}"
      fi
    done
    exit "${BREW_STUB_UPGRADE_STATUS:-0}"
    ;;
  deps)
    requested="${!#}"
    if [[ "$requested" == "$BREW_STUB_FORMULA" ]]; then
      printf '%b' "$BREW_STUB_ROOT_DEPS"
      [[ -z "$BREW_STUB_ROOT_DEPS" || "$BREW_STUB_ROOT_DEPS" == *$'\n' ]] || printf '\n'
    elif [[ "$requested" == "pcre2" ]]; then
      printf '%b' "$BREW_STUB_DEP_DEPS"
      [[ -z "$BREW_STUB_DEP_DEPS" || "$BREW_STUB_DEP_DEPS" == *$'\n' ]] || printf '\n'
    fi
    exit "${BREW_STUB_DEPS_STATUS:-0}"
    ;;
  verify)
    if [[ "${BREW_STUB_BLOCK_VERIFY:-false}" == "true" ]]; then
      : >"$BREW_STUB_SIGNAL_MARKER"
      trap 'exit 130' INT
      trap 'exit 143' TERM
      while :; do sleep 0.05; done
    fi
    printf '%s\n' '==> ripgrep bottle has a valid attestation'
    verify_json="${BREW_STUB_VERIFY_JSON-}"
    if [[ -z "$verify_json" ]]; then
      verify_json='[{"verificationResult":{"statement":{"subject":[{"name":"ripgrep--2.0.arm64_linux.bottle.tar.gz"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"pcre2--2.0.arm64_linux.bottle.tar.gz"}]}}}]'
    fi
    printf '%s\n' "$verify_json"
    exit "${BREW_STUB_VERIFY_STATUS:-0}"
    ;;
  vulns)
    exit "${BREW_STUB_VULNS_STATUS:-0}"
    ;;
  linkage)
    exit "${BREW_STUB_LINKAGE_STATUS:-0}"
    ;;
  *)
    printf 'unexpected brew command: %s\n' "$command_name" >&2
    exit 2
    ;;
esac
EOF

  ln -s "$(type -P jq)" "$TEST_BIN/jq"
  chmod +x "$TEST_BIN/brew-reviewed-upgrade" "$TEST_BIN/brew" "$TEST_BIN/gh" "$TEST_BIN/smoke-command"
}

assert_log_order() {
  local previous=0
  local pattern line
  for pattern in "$@"; do
    line="$(grep -n -m1 -F "$pattern" "$BREW_STUB_LOG" | cut -d: -f1)"
    [[ -n "$line" ]]
    (( line > previous ))
    previous="$line"
  done
}

count_log_line() {
  local pattern="$1"
  grep -Fxc "$pattern" "$BREW_STUB_LOG" || true
}

@test "successful reviewed upgrade preserves smoke command arguments and order" {
  run --separate-stderr brew-reviewed-upgrade ripgrep -- smoke-command "two words" "*" <"$YES_FILE"

  [ "$status" -eq 0 ]
  grep -Fxq 'argc=2' "$SMOKE_STUB_LOG"
  grep -Fxq '<two words>' "$SMOKE_STUB_LOG"
  grep -Fxq '<*>' "$SMOKE_STUB_LOG"
  assert_log_order \
    'config' \
    $'developer\tstate' \
    $'info\t--formula\t--json=v2\tripgrep' \
    'update' \
    $'outdated\t--formula\t--json=v2\tripgrep' \
    $'upgrade\t--formula\t--dry-run\tripgrep' \
    $'verify\t--deps\t--json\tripgrep' \
    $'upgrade\t--formula\t--no-ask\tripgrep' \
    $'vulns\t--deps\tripgrep' \
    $'linkage\t--test' \
    $'developer\toff'
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [[ "$stderr" == *"Developer mode is disabled."* ]]
}

@test "no-check explicitly skips the smoke command" {
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 0 ]
  [ ! -e "$SMOKE_STUB_LOG" ]
}

@test "missing smoke command is a usage error before Homebrew runs" {
  run brew-reviewed-upgrade ripgrep

  [ "$status" -eq 2 ]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "multiple Formulae are rejected as a usage error" {
  run brew-reviewed-upgrade ripgrep pcre2 -- smoke-command

  [ "$status" -eq 2 ]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "Cask-like input is rejected by Formula-only metadata resolution" {
  run brew-reviewed-upgrade --no-check visual-studio-code

  [ "$status" -eq 1 ]
  [[ "$output" == *"not found or is not a Formula"* ]]
  ! grep -Fxq 'update' "$BREW_STUB_LOG"
}

@test "managed policy file is parsed as data and never sourced" {
  marker="$BATS_TEST_TMPDIR/policy-executed"
  printf 'UNRELATED=$(touch %s)\n' "$marker" >>"$HOME/.homebrew/brew.env"
  export BREW_STUB_OUTDATED_MODE=current

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "effective attestation opt-out fails before brew update" {
  export BREW_STUB_POLICY_OVERRIDE=no-verify

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"disables attestations"* ]]
  ! grep -Fxq 'update' "$BREW_STUB_LOG"
}

@test "GitHub authentication failure stops before metadata update" {
  export GH_STUB_STATUS=1

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  ! grep -Fxq 'update' "$BREW_STUB_LOG"
}

@test "developer mode already enabled is rejected without automatic mutation" {
  export BREW_STUB_DEVELOPER_ENABLED=true

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be disabled"* ]]
  [ "$(count_log_line $'developer\toff')" -eq 0 ]
  ! grep -Fxq 'update' "$BREW_STUB_LOG"
}

@test "missing pinned third-party and source-built Formulae are rejected" {
  export BREW_STUB_INFO_STATUS=1
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  unset BREW_STUB_INFO_STATUS

  : >"$BREW_STUB_LOG"
  export BREW_STUB_PINNED=true
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  unset BREW_STUB_PINNED

  : >"$BREW_STUB_LOG"
  export BREW_STUB_TARGET_TAP=vendor/tap
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  unset BREW_STUB_TARGET_TAP

  : >"$BREW_STUB_LOG"
  export BREW_STUB_SOURCE_INSTALL=true
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]

  ! grep -Fxq 'update' "$BREW_STUB_LOG"
}

@test "already-current Formula is a successful no-op" {
  export BREW_STUB_OUTDATED_MODE=current

  run brew-reviewed-upgrade ripgrep -- smoke-command

  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  ! grep -Fq $'verify\t' "$BREW_STUB_LOG"
  [ ! -e "$SMOKE_STUB_LOG" ]
}

@test "outdated exit status and JSON disagreement fails closed" {
  export BREW_STUB_OUTDATED_MODE=contradictory

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"status and JSON disagree"* ]]
  ! grep -Fq $'upgrade\t--formula\t--dry-run' "$BREW_STUB_LOG"
}

@test "failed or empty dry-run stops before confirmation and verification" {
  export BREW_STUB_DRY_RUN_STATUS=5
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 1 ]
  ! grep -Fq $'verify\t' "$BREW_STUB_LOG"
  unset BREW_STUB_DRY_RUN_STATUS

  : >"$BREW_STUB_LOG"
  export BREW_STUB_DRY_RUN_EMPTY=true
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty plan"* ]]
  ! grep -Fq $'verify\t' "$BREW_STUB_LOG"
}

@test "rejection and EOF report that metadata was already updated" {
  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep <"$NO_FILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"brew update completed"* ]]
  ! grep -Fq $'verify\t' "$BREW_STUB_LOG"

  : >"$BREW_STUB_LOG"
  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep </dev/null
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"brew update completed"* ]]
  ! grep -Fq $'verify\t' "$BREW_STUB_LOG"
}

@test "non-core dependency blocks attestation verification" {
  export BREW_STUB_ROOT_DEPS=foreign/dep

  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"dependency is not an attestable"* ]]
  ! grep -Fq $'verify\t' "$BREW_STUB_LOG"
}

@test "incomplete malformed and excessive attestation output fail closed" {
  export BREW_STUB_VERIFY_JSON='[{"verificationResult":{"statement":{"subject":[{"name":"ripgrep--2.0.arm64_linux.bottle.tar.gz"}]}}}]'
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected 2, verified 1"* ]]
  unset BREW_STUB_VERIFY_JSON

  : >"$BREW_STUB_LOG"
  export BREW_STUB_VERIFY_JSON='{"unexpected":true}'
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed or unsupported"* ]]

  : >"$BREW_STUB_LOG"
  export BREW_STUB_VERIFY_JSON='[{"verificationResult":{"statement":{"subject":[{"name":"a"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"b"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"c"}]}}}]'
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected 2, verified 3"* ]]
}

@test "duplicate attestation subjects cannot hide a missing dependency" {
  export BREW_STUB_VERIFY_JSON='[{"verificationResult":{"statement":{"subject":[{"name":"ripgrep--2.0.arm64_linux.bottle.tar.gz"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"ripgrep--2.0.arm64_linux.bottle.tar.gz"}]}}}]'

  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"do not cover each expected Formula exactly once"* ]]
  ! grep -Fq $'upgrade\t--formula\t--no-ask' "$BREW_STUB_LOG"
}

@test "operation failure is preserved when developer cleanup also fails" {
  export BREW_STUB_UPGRADE_STATUS=7
  export BREW_STUB_DEVELOPER_OFF_STATUS=9

  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 7 ]
  [[ "$stderr" == *"operation failed with status 7"* ]]
  [[ "$stderr" == *"cleanup also failed with status 9"* ]]
  ! grep -Fq $'vulns\t' "$BREW_STUB_LOG"
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 2 ]
}

@test "verify vulnerability linkage and smoke failures stop later stages" {
  export BREW_STUB_VERIFY_STATUS=6
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 6 ]
  ! grep -Fq $'upgrade\t--formula\t--no-ask' "$BREW_STUB_LOG"
  unset BREW_STUB_VERIFY_STATUS

  : >"$BREW_STUB_LOG"
  export BREW_STUB_VULNS_STATUS=8
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 8 ]
  ! grep -Fq $'linkage\t--test' "$BREW_STUB_LOG"
  unset BREW_STUB_VULNS_STATUS

  : >"$BREW_STUB_LOG"
  export BREW_STUB_LINKAGE_STATUS=9
  run brew-reviewed-upgrade ripgrep -- smoke-command <"$YES_FILE"
  [ "$status" -eq 9 ]
  [ ! -e "$SMOKE_STUB_LOG" ]
  unset BREW_STUB_LINKAGE_STATUS

  : >"$BREW_STUB_LOG"
  export SMOKE_STUB_STATUS=10
  run brew-reviewed-upgrade ripgrep -- smoke-command <"$YES_FILE"
  [ "$status" -eq 10 ]
}

@test "TERM during verify forwards the signal cleans up once and returns 143" {
  export BREW_STUB_BLOCK_VERIFY=true
  output_file="$BATS_TEST_TMPDIR/helper.out"
  error_file="$BATS_TEST_TMPDIR/helper.err"

  brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE" >"$output_file" 2>"$error_file" &
  helper_pid=$!

  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e "$BREW_STUB_SIGNAL_MARKER" ]] && break
    sleep 0.05
  done
  [ -e "$BREW_STUB_SIGNAL_MARKER" ]

  kill -TERM "$helper_pid"
  if wait "$helper_pid"; then
    helper_status=0
  else
    helper_status=$?
  fi

  [ "$helper_status" -eq 143 ]
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 2 ]
  ! grep -Fq $'upgrade\t--formula\t--no-ask' "$BREW_STUB_LOG"
}

@test "INT handler cleans up once and returns 130" {
  run --separate-stderr bash -c '
    source "$SOURCE"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brew-reviewed-upgrade-int.XXXXXX")"
    BREW_BIN="$TEST_BIN/brew"
    DEVELOPER_CLEANUP_ARMED=1
    install_lifecycle_traps
    handle_signal INT 130
  '

  [ "$status" -eq 130 ]
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 1 ]
  ! grep -Fq $'upgrade\t--formula\t--no-ask' "$BREW_STUB_LOG"
}
