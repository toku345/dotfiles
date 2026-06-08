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

write_gh_stub() {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo list")
    printf 'toku/ok\tmain\tPRIVATE\tfalse\n'
    printf 'toku/fail\tmain\tPRIVATE\tfalse\n'
    ;;
  "repo clone")
    repo="$3"
    target="$4"
    if [ "$repo" = "toku/fail" ]; then
      exit 1
    fi
    mkdir -p "$target"
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
    GITLEAKS_STUB_LOG="$log" \
    /bin/bash "$REPO_AUDIT" --history-sweep

  [ "$status" -eq 2 ]
  [[ "$output" == *"ok   toku/ok"* ]]
  [[ "$output" != *"No leaks found across history"* ]]
  [[ "$stderr" == *"clone failed: toku/fail"* ]]
  [[ "$stderr" == *"History sweep incomplete"* ]]
}
