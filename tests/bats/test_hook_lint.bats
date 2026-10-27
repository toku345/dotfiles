#!/usr/bin/env bats
# shellcheck shell=bash
bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  resolve_bash5
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  LINT="$REPO_ROOT/scripts/hooks/lint-shell-all.sh"
  cd "$BATS_TEST_TMPDIR" || return 1
  mkdir -p .chezmoiscripts dot_local/bin dot_local/lib dot_git-template/hooks \
    tests/bats/bin .claude/hooks .codex/hooks private_dot_claude/skills private_dot_codex \
    private_dot_codex-fugu scripts/codex-config scripts/hooks
}

@test "CI inventory: lint all hook and helper files, including unchanged and shebang-less files" {
  local rel
  for rel in .claude/hooks/check.sh .codex/hooks/check.sh scripts/hooks/check.sh \
    dot_local/lib/check.sh tests/bats/utils.bash tests/bats/bin/new-stub; do
    printf '# shellcheck shell=bash\nunused_inventory_var=42\n' > "$rel"
    run --separate-stderr "$BASH5_BIN" "$LINT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Checking: $rel"* ]]
    [[ "$output" == *"SC2034"* ]]
    rm "$rel"
  done
}

@test "CI inventory: preserve shell templates and exclude non-shell executables" {
  printf '#!/usr/bin/env bash\necho {{ .chezmoi.os }}\n' \
    > .chezmoiscripts/check.sh.tmpl
  printf '#!/usr/bin/env python3\nprint("ok")\n' > dot_local/bin/executable_python
  run --separate-stderr "$BASH5_BIN" "$LINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checking template: .chezmoiscripts/check.sh.tmpl"* ]]
  [[ "$output" == *"Skipping non-shell script: dot_local/bin/executable_python"* ]]
}

@test "CI inventory: discovery failure is not a green lint result" {
  rmdir .codex/hooks
  run --separate-stderr "$BASH5_BIN" "$LINT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *".codex/hooks"* ]]
}
