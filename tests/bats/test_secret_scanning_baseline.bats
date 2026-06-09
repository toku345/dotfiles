#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  PRE_COMMIT_HOOK="$REPO_ROOT/dot_git-template/hooks/executable_pre-commit"
  REPO_AUDIT="$REPO_ROOT/dot_local/bin/executable_repo-security-audit"
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  export REPO_ROOT PRE_COMMIT_HOOK REPO_AUDIT STUB_DIR
}

write_gitleaks_stub() {
  cat > "$STUB_DIR/gitleaks" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GITLEAKS_STUB_LOG:?}"
exit "${GITLEAKS_STUB_STATUS:-0}"
STUB
  chmod +x "$STUB_DIR/gitleaks"
}

refute_grep() {
  if grep "$@"; then
    return 1
  fi
}

write_gh_stub() {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  *)
    if [ -n "${GH_STUB_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$GH_STUB_LOG"
    fi
    ;;
esac
case "$1 $2" in
  "repo list")
    printf 'toku/ok\tmain\tPRIVATE\tfalse\n'
    printf 'toku/fail\tmain\tPRIVATE\tfalse\n'
    ;;
  "repo clone")
    repo="$3"
    target="$4"
    if [ "${GH_STUB_CLONE_FAIL_REPO:-}" = "$repo" ]; then
      exit 1
    fi
    mkdir -p "$target"
    ;;
  "api user")
    printf 'toku\n'
    ;;
  "api repos/toku/ok/actions/permissions/workflow")
    printf 'read\n'
    ;;
  "api repos/toku/ok/environments")
    printf '0\n'
    ;;
  "api repos/toku/ok/contents/.github/workflows")
    printf '1\n'
    ;;
  "api repos/toku/ok/branches/main/protection")
    if [ "${GH_STUB_POSTURE_FAIL_FIELD:-}" = "bprot" ]; then
      printf 'gh: network denied\n' >&2
      exit 1
    fi
    printf 'gh: Not Found (HTTP 404)\n' >&2
    exit 1
    ;;
  "api repos/toku/ok")
    if [ "${GH_STUB_POSTURE_FAIL_FIELD:-}" = "repo" ]; then
      printf 'gh: network denied\n' >&2
      exit 1
    fi
    printf 'n/a\tn/a\n'
    ;;
  "api repos/toku/fail")
    if [ "${GH_STUB_POSTURE_FAIL:-}" = "1" ]; then
      printf 'gh: network denied\n' >&2
      exit 1
    fi
    printf 'n/a\tn/a\n'
    ;;
  "api "*)
    if [ "${GH_STUB_POSTURE_FAIL:-}" = "1" ]; then
      printf 'gh: network denied\n' >&2
      exit 1
    fi
    printf '0\n'
    ;;
  "secret list")
    if [ "${GH_STUB_POSTURE_FAIL_FIELD:-}" = "secrets" ]; then
      printf 'gh: network denied\n' >&2
      exit 1
    fi
    printf '0\n'
    ;;
  *)
    printf 'unsupported gh invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$STUB_DIR/gh"
}

@test "pre-commit hook warns and exits 0 when gitleaks is missing" {
  run --separate-stderr env PATH="/usr/bin:/bin" /bin/bash "$PRE_COMMIT_HOOK"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"gitleaks not on PATH; skipping local secret scan"* ]]
  [[ "$stderr" == *"Ensure this repo has CI or push protection configured separately"* ]]
}

@test "pre-commit hook delegates to gitleaks protect with staged scan flags" {
  write_gitleaks_stub
  local log="$BATS_TEST_TMPDIR/gitleaks.log"

  run --separate-stderr env \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    GITLEAKS_STUB_LOG="$log" \
    /bin/bash "$PRE_COMMIT_HOOK"

  [ "$status" -eq 0 ]
  [ "$(cat "$log")" = "protect --staged --redact --no-banner" ]
}

@test "repo-security-audit history sweep fails closed on clone failure" {
  write_gh_stub
  write_gitleaks_stub
  local log="$BATS_TEST_TMPDIR/gitleaks.log"

  run --separate-stderr env \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    REPO_AUDIT_OWNER=toku \
    GH_STUB_CLONE_FAIL_REPO=toku/fail \
    GITLEAKS_STUB_LOG="$log" \
    /bin/bash "$REPO_AUDIT" --history-sweep

  [ "$status" -eq 2 ]
  [[ "$output" == *"ok   toku/ok"* ]]
  [[ "$output" != *"No leaks found across history"* ]]
  [[ "$stderr" == *"clone failed: toku/fail"* ]]
  [[ "$stderr" == *"History sweep incomplete"* ]]
}

@test "repo-security-audit history sweep fails when leaks are detected" {
  write_gh_stub
  write_gitleaks_stub
  local log="$BATS_TEST_TMPDIR/gitleaks.log"

  run --separate-stderr env \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    REPO_AUDIT_OWNER=toku \
    GITLEAKS_STUB_LOG="$log" \
    GITLEAKS_STUB_STATUS=42 \
    /bin/bash "$REPO_AUDIT" --history-sweep

  [ "$status" -eq 1 ]
  [[ "$output" == *"LEAK toku/ok"* ]]
  [[ "$output" == *"LEAK toku/fail"* ]]
  [[ "$output" != *"No leaks found across history"* ]]
  [[ "$stderr" == *"Leaks detected — rotate affected keys FIRST, then clean history."* ]]
}

@test "repo-security-audit posture accepts expected not-configured states" {
  write_gh_stub
  local log="$BATS_TEST_TMPDIR/gh.log"

  run --separate-stderr env \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    REPO_AUDIT_OWNER=toku \
    GH_STUB_LOG="$log" \
    /bin/bash "$REPO_AUDIT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"toku/ok"* ]]
  [[ "$output" == *"no"* ]]
  [ -z "$stderr" ]
  [ "$(grep -c '^api repos/toku/ok --jq ' "$log")" -eq 1 ]
  [ "$(grep -c '^api repos/toku/fail --jq ' "$log")" -eq 1 ]
}

@test "PR gitleaks workflows fail closed when trusted base fetch fails" {
  local workflow="$REPO_ROOT/.github/workflows/secret-scan.reusable.yml"

  refute_grep -Eq 'git fetch .*GITHUB_BASE_REF.*\|\| true' "$workflow"
  refute_grep -q 'AUTHORIZATION: bearer' "$workflow"
  grep -q 'x-access-token:%s' "$workflow"
  grep -q 'GITLEAKS_GIT_AUTH_HEADER="AUTHORIZATION: basic' "$workflow"
  grep -q -- '--config-env=http.https://github.com/.extraheader=GITLEAKS_GIT_AUTH_HEADER' "$workflow"
  grep -q 'Failed to fetch trusted base branch' "$workflow"
  grep -q 'refusing to fall back to default gitleaks rules' "$workflow"
  grep -q 'printf .*\[extend\].*useDefault = true' "$workflow"
  grep -q -- '--config /tmp/gitleaks-default.toml' "$workflow"
  grep -Fq "gitleaks git \"\${GITLEAKS_CONFIG_ARGS[@]}\" \"\$fixture_repo\"" "$workflow"
}

@test "security-checks delegates gitleaks to the reusable workflow" {
  local workflow="$REPO_ROOT/.github/workflows/security-checks.yml"

  grep -q 'uses: ./.github/workflows/secret-scan.reusable.yml' "$workflow"
  refute_grep -q 'GITLEAKS_CONFIG_ARGS=' "$workflow"
  refute_grep -q 'gitleaks git' "$workflow"
  refute_grep -q 'gitleaks-version:' "$workflow"
  refute_grep -q 'gitleaks-sha256-linux-x64:' "$workflow"
}

@test "reusable gitleaks workflow keeps scanner version and checksum non-overridable" {
  local workflow="$REPO_ROOT/.github/workflows/secret-scan.reusable.yml"

  refute_grep -q 'gitleaks-version:' "$workflow"
  refute_grep -q 'gitleaks-sha256-linux-x64:' "$workflow"
  refute_grep -q 'inputs.gitleaks-version' "$workflow"
  refute_grep -q 'inputs.gitleaks-sha256-linux-x64' "$workflow"
  grep -q 'GL_VER: "8.30.1"' "$workflow"
  grep -q 'GL_SHA: "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"' "$workflow"
}

@test "repo-security-audit posture fails closed on GitHub API failure" {
  write_gh_stub

  run --separate-stderr env \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    REPO_AUDIT_OWNER=toku \
    GH_STUB_POSTURE_FAIL=1 \
    /bin/bash "$REPO_AUDIT"

  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$stderr" == *"posture check failed: toku/fail token"* ]]
  [[ "$stderr" == *"Posture audit incomplete"* ]]
}
