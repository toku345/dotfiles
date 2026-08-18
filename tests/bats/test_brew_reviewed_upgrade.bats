#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SOURCE="$REPO_ROOT/dot_local/bin/executable_brew-reviewed-upgrade"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  BREW_STUB_LOG="$BATS_TEST_TMPDIR/brew.log"
  BREW_STUB_ENV_LOG="$BATS_TEST_TMPDIR/brew-env.log"
  BREW_STUB_HINT_LOG="$BATS_TEST_TMPDIR/brew-hints.log"
  GH_STUB_LOG="$BATS_TEST_TMPDIR/gh.log"
  SMOKE_STUB_LOG="$BATS_TEST_TMPDIR/smoke.log"
  BREW_STUB_SIGNAL_MARKER="$BATS_TEST_TMPDIR/verify-started"
  BREW_STUB_SIGNAL_RESULT="$BATS_TEST_TMPDIR/verify-signal"
  LAUNCH_CHILD_PID_FILE="$BATS_TEST_TMPDIR/launch-child-pid"
  YES_FILE="$BATS_TEST_TMPDIR/yes"
  NO_FILE="$BATS_TEST_TMPDIR/no"

  mkdir -p "$TEST_HOME/.homebrew" "$TEST_BIN"
  cp "$REPO_ROOT/dot_homebrew/brew.env" "$TEST_HOME/.homebrew/brew.env"
  printf 'yes\n' >"$YES_FILE"
  printf 'no\n' >"$NO_FILE"
  : >"$BREW_STUB_LOG"
  : >"$BREW_STUB_ENV_LOG"
  : >"$BREW_STUB_HINT_LOG"
  : >"$GH_STUB_LOG"

  export SOURCE TEST_HOME TEST_BIN BREW_STUB_LOG BREW_STUB_ENV_LOG
  export BREW_STUB_HINT_LOG GH_STUB_LOG
  export SMOKE_STUB_LOG BREW_STUB_SIGNAL_MARKER BREW_STUB_SIGNAL_RESULT
  export LAUNCH_CHILD_PID_FILE
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
} >>"$GH_STUB_LOG"

if [[ "$*" == "auth status --hostname github.com" ]]; then
  printf '%s\n' 'authenticated as test-user' >&2
  exit "${GH_STUB_STATUS:-0}"
fi
if [[ "${1:-}" == "api" ]]; then
  if [[ "${GH_STUB_API_STATUS:-0}" != "0" ]]; then
    printf '%s\n' 'release lookup failed' >&2
    exit "$GH_STUB_API_STATUS"
  fi
  if [[ -n "${GH_STUB_RELEASE_JSON:-}" ]]; then
    printf '%s\n' "$GH_STUB_RELEASE_JSON"
  else
    printf '{"tag_name":"%s","html_url":"%s","published_at":"%s","draft":%s,"prerelease":%s}\n' \
      "${GH_STUB_RELEASE_TAG:-2.0}" \
      "${GH_STUB_RELEASE_HTML_URL:-https://github.com/BurntSushi/ripgrep/releases/tag/2.0}" \
      "${GH_STUB_RELEASE_PUBLISHED_AT:-2020-01-01T00:00:00Z}" \
      "${GH_STUB_RELEASE_DRAFT:-false}" \
      "${GH_STUB_RELEASE_PRERELEASE:-false}"
  fi
  exit 0
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
printf '%s\t%s\t%s\n' \
  "$command_name" "${HOMEBREW_NO_INSTALL_CLEANUP-unset}" "$*" \
  >>"$BREW_STUB_ENV_LOG"
printf '%s\t%s\t%s\n' \
  "$command_name" "${HOMEBREW_NO_ENV_HINTS-unset}" "$*" \
  >>"$BREW_STUB_HINT_LOG"

formula_info() {
  local requested="${!#}"
  local canonical="$requested"
  local tap="homebrew/core"
  local pinned=false
  local bottle=true
  local bottle_files='{"arm64_linux":{}}'
  local installed='[]'
  local stable_version="${BREW_STUB_STABLE_VERSION:-2.0}"
  local stable_url="${BREW_STUB_STABLE_URL:-https://github.com/BurntSushi/ripgrep/archive/refs/tags/2.0.tar.gz}"
  local stable_tag_json=""

  if [[ -n "${BREW_STUB_STABLE_TAG:-}" ]]; then
    stable_tag_json=',"tag":"'"$BREW_STUB_STABLE_TAG"'"'
  fi

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
  elif [[ "$canonical" == "${BREW_STUB_SOURCE_DEP:-}" ]]; then
    installed='[{"version":"1.0","built_as_bottle":false,"poured_from_bottle":false}]'
  fi

  printf '{"formulae":[{"name":"%s","full_name":"%s","tap":"%s","pinned":%s,"versions":{"stable":"%s","bottle":%s},"urls":{"stable":{"url":"%s"%s}},"bottle":{"stable":{"files":%s}},"installed":%s}]}\n' \
    "$canonical" "$canonical" "$tap" "$pinned" "$stable_version" "$bottle" \
    "$stable_url" "$stable_tag_json" "$bottle_files" "$installed"
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
      trap 'printf INT >"$BREW_STUB_SIGNAL_RESULT"; exit 130' INT
      trap 'printf TERM >"$BREW_STUB_SIGNAL_RESULT"; exit 143' TERM
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

refute_log() {
  local match_mode="$1"
  local pattern="$2"
  local grep_status

  set +e
  case "$match_mode" in
    line) grep -Fqx -- "$pattern" "$BREW_STUB_LOG" ;;
    contains) grep -Fq -- "$pattern" "$BREW_STUB_LOG" ;;
    *)
      printf 'unsupported refute_log mode: %s\n' "$match_mode" >&2
      set -e
      return 2
      ;;
  esac
  grep_status=$?
  set -e

  case "$grep_status" in
    0)
      printf 'unexpected log entry matching: %s\n' "$pattern" >&2
      return 1
      ;;
    1) return 0 ;;
    *)
      printf 'grep failed with status %s while checking the brew log\n' \
        "$grep_status" >&2
      return 2
      ;;
  esac
}

@test "refute_log rejects matches and propagates grep errors" {
  printf '%s\n' 'forbidden' >"$BREW_STUB_LOG"
  run refute_log line forbidden
  [ "$status" -eq 1 ]

  rm "$BREW_STUB_LOG"
  run refute_log line forbidden
  [ "$status" -eq 2 ]
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
  grep -Fxq $'upgrade\t1\t--formula --dry-run ripgrep' "$BREW_STUB_ENV_LOG"
  grep -Fxq $'upgrade\t1\t--formula --no-ask ripgrep' "$BREW_STUB_ENV_LOG"
  [ "$(awk -F '\t' '$1 != "upgrade" && $2 == "1" { count++ } END { print count + 0 }' "$BREW_STUB_ENV_LOG")" -eq 0 ]
  grep -Fq 'Release notes: https://github.com/BurntSushi/ripgrep/releases/tag/2.0' <<<"$output"
  grep -Fq 'Cooldown: eligible' <<<"$output"
  grep -Fq $'  - ripgrep' <<<"$output"
  grep -Fq $'  - pcre2' <<<"$output"
  grep -Fq 'Smoke check: configured' <<<"$output"
  [[ "$stderr" != *"authenticated as test-user"* ]]
  grep -Fxq $'api\t-H\tAccept: application/vnd.github+json\t-H\tX-GitHub-Api-Version: 2026-03-10\trepos/BurntSushi/ripgrep/releases/tags/2.0' "$GH_STUB_LOG"
  grep -Fxq $'upgrade\t1\t--formula --dry-run ripgrep' "$BREW_STUB_HINT_LOG"
  grep -Fxq $'deps\t1\t--formula --full-name --include-build --include-test --include-implicit ripgrep' "$BREW_STUB_HINT_LOG"
  [ "$(awk -F '\t' '$1 != "upgrade" && $1 != "deps" && $2 == "1" { count++ } END { print count + 0 }' "$BREW_STUB_HINT_LOG")" -eq 0 ]
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

@test "unavailable smoke command fails before Homebrew runs" {
  run -127 brew-reviewed-upgrade ripgrep -- unavailable-smoke-command

  [ "$status" -eq 127 ]
  [[ "$output" == *"required command not found on PATH"* ]]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "multiple Formulae are rejected as a usage error" {
  run brew-reviewed-upgrade ripgrep pcre2 -- smoke-command

  [ "$status" -eq 2 ]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "cooldown exception requires one non-empty single-line reason" {
  run brew-reviewed-upgrade --cooldown-exception "" --no-check ripgrep
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be non-empty and single-line"* ]]

  run brew-reviewed-upgrade --cooldown-exception $'security fix\nsecond line' --no-check ripgrep
  [ "$status" -eq 2 ]

  run brew-reviewed-upgrade --cooldown-exception first \
    --cooldown-exception second --no-check ripgrep
  [ "$status" -eq 2 ]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "Cask-like input is rejected by Formula-only metadata resolution" {
  run brew-reviewed-upgrade --no-check visual-studio-code

  [ "$status" -eq 1 ]
  [[ "$output" == *"not found or is not a Formula"* ]]
  refute_log line 'update'
}

@test "managed policy file is parsed as data and never sourced" {
  marker="$BATS_TEST_TMPDIR/policy-executed"
  printf 'UNRELATED=$(touch %s)\n' "$marker" >>"$HOME/.homebrew/brew.env"
  export BREW_STUB_OUTDATED_MODE=current

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "managed policy parser failure is rejected even after partial output" {
  run --separate-stderr bash -c '
    source "$SOURCE"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brew-reviewed-upgrade-policy.XXXXXX")"
    awk() {
      printf "1\n"
      return 42
    }
    validate_policy_file
  '

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not parse managed Homebrew policy"* ]]
  [ ! -s "$BREW_STUB_LOG" ]
}

@test "effective policy negative scan propagates grep errors" {
  run --separate-stderr bash -c '
    source "$SOURCE"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brew-reviewed-upgrade-policy.XXXXXX")"
    BREW_BIN="$TEST_BIN/brew"
    grep() {
      if [[ "$1" == "-Eq" ]] \
        && [[ "$2" == "^HOMEBREW_(NO_VERIFY_ATTESTATIONS|NO_ASK): set$" ]]; then
        return 42
      fi
      command grep "$@"
    }
    validate_effective_policy
  '

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not inspect effective Homebrew policy"* ]]
  refute_log line 'update'
}

@test "effective attestation opt-out fails before brew update" {
  export BREW_STUB_POLICY_OVERRIDE=no-verify

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"disables attestations"* ]]
  refute_log line 'update'
}

@test "GitHub authentication failure stops before metadata update" {
  export GH_STUB_STATUS=1

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  refute_log line 'update'
}

@test "developer mode already enabled is rejected without automatic mutation" {
  export BREW_STUB_DEVELOPER_ENABLED=true

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be disabled"* ]]
  [ "$(count_log_line $'developer\toff')" -eq 0 ]
  refute_log line 'update'
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

  refute_log line 'update'
}

@test "already-current Formula is a successful no-op" {
  export BREW_STUB_OUTDATED_MODE=current

  run brew-reviewed-upgrade ripgrep -- smoke-command

  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
  refute_log contains $'verify\t'
  run ! grep -Fq $'api\t' "$GH_STUB_LOG"
  [ ! -e "$SMOKE_STUB_LOG" ]
}

@test "release age boundary becomes eligible at exactly seven days" {
  run bash -c '
    source "$SOURCE"
    JQ_BIN="$TEST_BIN/jq"
    published="2026-01-01T00:00:00Z"
    published_epoch="$("$JQ_BIN" -nr \
      --arg published "$published" "\$published | fromdateiso8601")"

    evaluate_release_age "$published" "$((published_epoch + 604799))"
    if release_age_is_eligible; then
      before=eligible
    else
      before=blocked
    fi

    evaluate_release_age "$published" "$((published_epoch + 604800))"
    if release_age_is_eligible; then
      exact=eligible
    else
      exact=blocked
    fi
    printf "%s %s %s\n" "$before" "$exact" "$RELEASE_ELIGIBLE_AT"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "blocked eligible 2026-01-08T00:00:00Z" ]
}

@test "new release stops before dry-run unless a reasoned exception is supplied" {
  export GH_STUB_RELEASE_PUBLISHED_AT
  GH_STUB_RELEASE_PUBLISHED_AT="$("$TEST_BIN/jq" -nr \
    'now - 86400 | strftime("%Y-%m-%dT%H:%M:%SZ")')"

  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cooldown: blocked"* ]]
  [[ "$output" == *"GitHub Release is newer than 7 days"* ]]
  [[ "$stderr" == *"--cooldown-exception REASON"* ]]
  refute_log contains $'upgrade\t--formula\t--dry-run'
  refute_log contains $'deps\t'
  refute_log contains $'verify\t'

  : >"$BREW_STUB_LOG"
  run brew-reviewed-upgrade --cooldown-exception \
    "CVE fix reviewed" --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cooldown: exception"* ]]
  [[ "$output" == *"Exception reason: CVE fix reviewed"* ]]
  grep -Fq $'upgrade\t--formula\t--dry-run\tripgrep' "$BREW_STUB_LOG"
  grep -Fq $'upgrade\t--formula\t--no-ask\tripgrep' "$BREW_STUB_LOG"
}

@test "eligible release reports that a supplied exception was not needed" {
  run brew-reviewed-upgrade --cooldown-exception \
    "stale manual decision" --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Cooldown: eligible (exception not needed)"* ]]
  [[ "$output" != *"Exception reason:"* ]]
}

@test "unsupported source requires the same explicit exception path" {
  export BREW_STUB_STABLE_URL="https://curl.se/ca/cacert-2026-08-13.pem"

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cooldown: unverified"* ]]
  [[ "$output" == *"not a supported GitHub release URL"* ]]
  run ! grep -Fq $'api\t' "$GH_STUB_LOG"
  refute_log contains $'upgrade\t--formula\t--dry-run'

  : >"$BREW_STUB_LOG"
  : >"$GH_STUB_LOG"
  run brew-reviewed-upgrade --cooldown-exception \
    "vendor notes reviewed" --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Exception reason: vendor notes reviewed"* ]]
  run ! grep -Fq $'api\t' "$GH_STUB_LOG"
}

@test "release lookup errors malformed metadata and prereleases fail closed" {
  export GH_STUB_API_STATUS=22
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  [[ "$output" == *"lookup failed with status 22"* ]]
  refute_log contains $'upgrade\t--formula\t--dry-run'
  unset GH_STUB_API_STATUS

  : >"$BREW_STUB_LOG"
  export GH_STUB_RELEASE_JSON='{"unexpected":true}'
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  [[ "$output" == *"metadata is malformed"* ]]
  refute_log contains $'upgrade\t--formula\t--dry-run'
  unset GH_STUB_RELEASE_JSON

  : >"$BREW_STUB_LOG"
  export GH_STUB_RELEASE_PUBLISHED_AT
  GH_STUB_RELEASE_PUBLISHED_AT="$("$TEST_BIN/jq" -nr \
    'now + 3600 | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  [[ "$output" == *"Published:"*"(unverified)"* ]]
  [[ "$output" == *"published_at is in the future"* ]]
  [[ "$output" != *"Eligible after:"* ]]
  refute_log contains $'upgrade\t--formula\t--dry-run'
  unset GH_STUB_RELEASE_PUBLISHED_AT

  : >"$BREW_STUB_LOG"
  export GH_STUB_RELEASE_DRAFT=true
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  [[ "$output" == *"GitHub Release is a draft"* ]]
  refute_log contains $'upgrade\t--formula\t--dry-run'
  unset GH_STUB_RELEASE_DRAFT

  : >"$BREW_STUB_LOG"
  export GH_STUB_RELEASE_PRERELEASE=true
  run brew-reviewed-upgrade --no-check ripgrep
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cooldown: blocked"* ]]
  [[ "$output" == *"marked as a prerelease"* ]]
  refute_log contains $'upgrade\t--formula\t--dry-run'
}

@test "supported source URL forms preserve and encode the exact release tag" {
  export BREW_STUB_STABLE_URL="https://github.com/jqlang/jq/releases/download/jq-2.0/jq.tar.gz"
  export GH_STUB_RELEASE_TAG="jq-2.0"
  export GH_STUB_RELEASE_HTML_URL="https://github.com/jqlang/jq/releases/tag/jq-2.0"
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 0 ]
  grep -Fq $'repos/jqlang/jq/releases/tags/jq-2.0' "$GH_STUB_LOG"

  : >"$GH_STUB_LOG"
  export BREW_STUB_STABLE_URL="https://github.com/vendor/tool.git"
  export BREW_STUB_STABLE_TAG="v2.0"
  export GH_STUB_RELEASE_TAG="v2.0"
  export GH_STUB_RELEASE_HTML_URL="https://github.com/vendor/tool/releases/tag/v2.0"
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 0 ]
  grep -Fq $'repos/vendor/tool/releases/tags/v2.0' "$GH_STUB_LOG"

  : >"$GH_STUB_LOG"
  unset BREW_STUB_STABLE_TAG
  export BREW_STUB_STABLE_URL="https://github.com/vendor/tool/archive/refs/tags/release%2F2.0.tar.gz"
  export GH_STUB_RELEASE_TAG="release/2.0"
  export GH_STUB_RELEASE_HTML_URL="https://github.com/vendor/tool/releases/tag/release/2.0"
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 0 ]
  grep -Fq $'repos/vendor/tool/releases/tags/release%2F2.0' "$GH_STUB_LOG"
}

@test "outdated exit status and JSON disagreement fails closed" {
  export BREW_STUB_OUTDATED_MODE=contradictory

  run brew-reviewed-upgrade --no-check ripgrep

  [ "$status" -eq 1 ]
  [[ "$output" == *"status and JSON disagree"* ]]
  refute_log contains $'upgrade\t--formula\t--dry-run'
}

@test "failed or empty dry-run stops before confirmation and verification" {
  export BREW_STUB_DRY_RUN_STATUS=5
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 1 ]
  refute_log contains $'verify\t'
  unset BREW_STUB_DRY_RUN_STATUS

  : >"$BREW_STUB_LOG"
  export BREW_STUB_DRY_RUN_EMPTY=true
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty plan"* ]]
  refute_log contains $'verify\t'
}

@test "dry-run display failure stops before confirmation" {
  run --separate-stderr bash -c '
    source "$SOURCE"
    TEMP_DIR="$TEST_HOME/dry-run-display"
    BREW_BIN="$TEST_BIN/brew"
    mkdir -p "$TEMP_DIR"
    cat() {
      return 42
    }
    exercise() {
      show_dry_run ripgrep || return $?
      printf "continued after dry-run display failure\n"
    }
    exercise
  '

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not display the Homebrew dry-run plan"* ]]
  [[ "$output" != *"continued after dry-run display failure"* ]]
}

@test "rejection and EOF report that metadata was already updated" {
  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep <"$NO_FILE"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"brew update completed"* ]]
  refute_log contains $'verify\t'

  : >"$BREW_STUB_LOG"
  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep </dev/null
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"brew update completed"* ]]
  refute_log contains $'verify\t'
}

@test "mixed-case confirmation is accepted without external normalization" {
  printf 'YeS\n' >"$BATS_TEST_TMPDIR/mixed-yes"

  run brew-reviewed-upgrade --no-check ripgrep <"$BATS_TEST_TMPDIR/mixed-yes"

  [ "$status" -eq 0 ]
  grep -Fq $'upgrade\t--formula\t--no-ask\tripgrep' "$BREW_STUB_LOG"
}

@test "confirmation prompt failure cannot consume approval input" {
  run --separate-stderr bash -c '
    source "$SOURCE"
    printf() {
      if [[ "$1" == "%s" && "${2:-}" == "Proceed with the displayed dry-run"* ]]; then
        return 42
      fi
      command printf "$@"
    }
    exercise() {
      confirm_review ripgrep || return $?
      printf "continued after prompt failure\n"
    }
    exercise
  ' <"$YES_FILE"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not display the review confirmation prompt"* ]]
  [[ "$output" != *"continued after prompt failure"* ]]
}

@test "dependency command failure stops before verification and upgrade" {
  export BREW_STUB_DEPS_STATUS=5

  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not resolve dependencies for: ripgrep"* ]]
  refute_log contains $'verify\t'
  refute_log contains $'upgrade\t--formula\t--no-ask'
}

@test "non-core dependency blocks attestation verification" {
  export BREW_STUB_ROOT_DEPS=foreign/dep

  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"dependency is not an attestable"* ]]
  refute_log contains $'verify\t'
}

@test "source-built installed dependency blocks attestation verification" {
  export BREW_STUB_SOURCE_DEP=pcre2

  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Bottle-installed homebrew/core Formula"* ]]
  refute_log contains $'verify\t'
}

@test "transitive dependency traversal deduplicates converging edges" {
  export BREW_STUB_ROOT_DEPS=$'pcre2\nzlib'
  export BREW_STUB_DEP_DEPS=zlib
  export BREW_STUB_VERIFY_JSON='[{"verificationResult":{"statement":{"subject":[{"name":"ripgrep--2.0.arm64_linux.bottle.tar.gz"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"pcre2--2.0.arm64_linux.bottle.tar.gz"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"zlib--2.0.arm64_linux.bottle.tar.gz"}]}}}]'

  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Expected Bottle attestations: 3"* ]]
  [ "$(count_log_line $'deps\t--formula\t--full-name\t--include-build\t--include-test\t--include-implicit\tzlib')" -eq 1 ]
  [ "$(count_log_line $'info\t--formula\t--json=v2\tzlib')" -eq 1 ]
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
  [[ "$output" == *"do not fully cover each other"* ]]
  refute_log contains $'upgrade\t--formula\t--no-ask'
}

@test "valid multi-subject attestations remain supported" {
  export BREW_STUB_VERIFY_JSON='[{"verificationResult":{"statement":{"subject":[{"name":"unrelated-build-output"},{"name":"ripgrep--2.0.arm64_linux.bottle.tar.gz"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"pcre2--2.0.arm64_linux.bottle.tar.gz"}]}}}]'

  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 0 ]
  grep -Fq 'Verified Bottle attestations for 2 Formulae.' <<<"$output"
}

@test "attestation display failure stops before coverage acceptance" {
  run --separate-stderr bash -c '
    source "$SOURCE"
    TEMP_DIR="$TEST_HOME/attestation-display"
    BREW_BIN="$TEST_BIN/brew"
    JQ_BIN="$TEST_BIN/jq"
    mkdir -p "$TEMP_DIR"
    expected_file="$TEMP_DIR/expected-formulae"
    printf "ripgrep\npcre2\n" >"$expected_file"
    cat() {
      return 42
    }
    exercise() {
      verify_attestations ripgrep "$expected_file" || return $?
      printf "continued after attestation display failure\n"
    }
    exercise
  '

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not display Bottle attestation output"* ]]
  [[ "$output" != *"continued after attestation display failure"* ]]
}

@test "unmatched attestation result cannot hide behind a multi-subject result" {
  export BREW_STUB_VERIFY_JSON='[{"verificationResult":{"statement":{"subject":[{"name":"ripgrep--2.0.arm64_linux.bottle.tar.gz"},{"name":"pcre2--2.0.arm64_linux.bottle.tar.gz"}]}}},{"verificationResult":{"statement":{"subject":[{"name":"unrelated--2.0.arm64_linux.bottle.tar.gz"}]}}}]'

  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"do not fully cover each other"* ]]
  refute_log contains $'upgrade\t--formula\t--no-ask'
}

@test "operation failure is preserved when developer cleanup also fails" {
  export BREW_STUB_UPGRADE_STATUS=7
  export BREW_STUB_DEVELOPER_OFF_STATUS=9

  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"

  [ "$status" -eq 7 ]
  [[ "$stderr" == *"operation failed with status 7"* ]]
  [[ "$stderr" == *"cleanup also failed with status 9"* ]]
  refute_log contains $'vulns\t'
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 2 ]
}

@test "verify vulnerability linkage and smoke failures stop later stages" {
  export BREW_STUB_VERIFY_STATUS=6
  run --separate-stderr brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 6 ]
  refute_log contains $'upgrade\t--formula\t--no-ask'
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 2 ]
  [[ "$stderr" == *"Developer mode is disabled."* ]]
  unset BREW_STUB_VERIFY_STATUS

  : >"$BREW_STUB_LOG"
  export BREW_STUB_VULNS_STATUS=8
  run brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE"
  [ "$status" -eq 8 ]
  refute_log contains $'linkage\t--test'
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
  [ "$(<"$BREW_STUB_SIGNAL_RESULT")" = TERM ]
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 2 ]
  refute_log contains $'upgrade\t--formula\t--no-ask'
}

@test "INT during verify terminates the child cleans up once and returns 130" {
  export BREW_STUB_BLOCK_VERIFY=true
  output_file="$BATS_TEST_TMPDIR/helper.out"
  error_file="$BATS_TEST_TMPDIR/helper.err"

  set -m
  brew-reviewed-upgrade --no-check ripgrep <"$YES_FILE" >"$output_file" 2>"$error_file" &
  helper_pid=$!
  set +m

  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e "$BREW_STUB_SIGNAL_MARKER" ]] && break
    sleep 0.05
  done
  [ -e "$BREW_STUB_SIGNAL_MARKER" ]

  kill -INT "$helper_pid"
  if wait "$helper_pid"; then
    helper_status=0
  else
    helper_status=$?
  fi

  [ "$helper_status" -eq 130 ]
  [ "$(<"$BREW_STUB_SIGNAL_RESULT")" = TERM ]
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 2 ]
  refute_log contains $'upgrade\t--formula\t--no-ask'
}

@test "signal queued during launch is delivered after PID publication" {
  export BREW_STUB_BLOCK_VERIFY=true

  run --separate-stderr bash -c '
    source "$SOURCE"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brew-reviewed-upgrade-signal.XXXXXX")"
    BREW_BIN="$TEST_BIN/brew"
    DEVELOPER_CLEANUP_ARMED=1
    install_lifecycle_traps

    "$BREW_BIN" verify --deps --json ripgrep >/dev/null &
    managed_pid=$!
    printf "%s\n" "$managed_pid" >"$LAUNCH_CHILD_PID_FILE"
    for ((attempt = 0; attempt < 100; attempt++)); do
      [[ -e "$BREW_STUB_SIGNAL_MARKER" ]] && break
      sleep 0.05
    done
    [[ -e "$BREW_STUB_SIGNAL_MARKER" ]]

    MANAGED_LAUNCHING=1
    handle_signal TERM 143
    [[ "$PENDING_SIGNAL_NAME" == TERM ]]
    kill -0 "$managed_pid"
    publish_managed_pid "$managed_pid"
  '

  [ "$status" -eq 143 ]
  [ "$(<"$BREW_STUB_SIGNAL_RESULT")" = TERM ]
  run ! kill -0 "$(<"$LAUNCH_CHILD_PID_FILE")"
  [ "$status" -eq 1 ]
  [ "$(count_log_line $'developer\toff')" -eq 1 ]
  [ "$(count_log_line $'developer\tstate')" -eq 1 ]
}

@test "signal forwarding and reap failures are diagnosed" {
  run --separate-stderr bash -c '
    source "$SOURCE"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brew-reviewed-upgrade-signal.XXXXXX")"
    BREW_BIN="$TEST_BIN/brew"
    ACTIVE_PID=12345
    DEVELOPER_CLEANUP_ARMED=1
    kill() {
      [[ "$1" == "-0" ]]
    }
    wait() {
      return 127
    }
    install_lifecycle_traps
    handle_signal INT 130
  '

  [ "$status" -eq 130 ]
  [[ "$stderr" == *"could not stop managed process 12345 after INT"* ]]
  [[ "$stderr" == *"could not reap managed process 12345 after INT"* ]]
}
