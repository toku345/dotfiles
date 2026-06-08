#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/private_dot_codex/skills/pr-review-coach"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  CLEANUP_SCRIPT="$SKILL_DIR/scripts/cleanup-state.sh"
  STATE_ROOT="$BATS_TEST_TMPDIR/state"
  export REPO_ROOT SKILL_DIR SKILL_MD CLEANUP_SCRIPT STATE_ROOT
}

make_state_file() {
  local repo_key="$1" name="$2" stamp="$3"
  local dir="$STATE_ROOT/repos/$repo_key"
  mkdir -p "$dir"
  local file="$dir/$name.md"
  printf 'state: %s\n' "$name" > "$file"
  touch -t "$stamp" "$file"
  printf '%s\n' "$file"
}

@test "pr-review-coach cleanup script exists" {
  [ -f "$CLEANUP_SCRIPT" ]
  bash -n "$CLEANUP_SCRIPT"
}

@test "cleanup-state deletes expired files but preserves current file" {
  local expired current
  expired="$(make_state_file repo-a old 202001010000)"
  current="$(make_state_file repo-a current 202001010001)"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 30 \
    --max-files-per-repo 20 \
    --current "$current"

  [ "$status" -eq 0 ]
  [ ! -e "$expired" ]
  [ -e "$current" ]
}

@test "cleanup-state keeps newest N files per repo" {
  local old mid new
  old="$(make_state_file repo-a old 202601010000)"
  mid="$(make_state_file repo-a mid 202601010100)"
  new="$(make_state_file repo-a new 202601010200)"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 99999 \
    --max-files-per-repo 2

  [ "$status" -eq 0 ]
  [ ! -e "$old" ]
  [ -e "$mid" ]
  [ -e "$new" ]
}

@test "cleanup-state preserves current file during count pruning" {
  local current mid new
  current="$(make_state_file repo-a current 202601010000)"
  mid="$(make_state_file repo-a mid 202601010100)"
  new="$(make_state_file repo-a new 202601010200)"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 99999 \
    --max-files-per-repo 2 \
    --current "$current"

  [ "$status" -eq 0 ]
  [ -e "$current" ]
  [ -e "$mid" ]
  [ -e "$new" ]
}

@test "cleanup-state preserves parent dir for not-yet-created current file" {
  local current
  mkdir -p "$STATE_ROOT/repos/repo-a"
  current="$STATE_ROOT/repos/repo-a/current.md"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --current "$current"

  [ "$status" -eq 0 ]
  [ -d "$STATE_ROOT/repos/repo-a" ]
  [ ! -e "$current" ]
}

@test "cleanup-state dry-run reports deletions without deleting" {
  local expired
  expired="$(make_state_file repo-a old 202001010000)"

  run bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 30 \
    --max-files-per-repo 20 \
    --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete $expired"* ]]
  [ -e "$expired" ]
}

@test "cleanup-state fails loudly when state enumeration fails" {
  mkdir -p "$STATE_ROOT/repos/repo-a"
  local stub_dir="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/find" <<'STUB'
#!/usr/bin/env bash
printf 'find stub failure\n' >&2
exit 1
STUB
  chmod +x "$stub_dir/find"

  run --separate-stderr env PATH="$stub_dir:$PATH" bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"find stub failure"* ]]
  [[ "$stderr" == *"failed to enumerate state files under $STATE_ROOT/repos"* ]]
}

@test "cleanup-state fails loudly when state sorting fails" {
  make_state_file repo-a current 203001010000
  local stub_dir="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/sort" <<'STUB'
#!/usr/bin/env bash
printf 'sort stub failure\n' >&2
exit 1
STUB
  chmod +x "$stub_dir/sort"

  run --separate-stderr env PATH="$stub_dir:$PATH" bash "$CLEANUP_SCRIPT" \
    --state-root "$STATE_ROOT" \
    --max-age-days 99999

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"sort stub failure"* ]]
  [[ "$stderr" == *"failed to sort state files under $STATE_ROOT/repos/repo-a"* ]]
}

@test "SKILL.md documented cleanup invocation uses bash and works without execute bit" {
  grep -Fq "bash \"\$SKILL_DIR/scripts/cleanup-state.sh\" --state-root \"\$STATE_ROOT\" --current \"\$STATE_FILE\"" "$SKILL_MD"
  [ ! -x "$CLEANUP_SCRIPT" ]

  local expired current
  expired="$(make_state_file repo-a old 202001010000)"
  current="$(make_state_file repo-a current 202001010001)"

  run bash "$SKILL_DIR/scripts/cleanup-state.sh" \
    --state-root "$STATE_ROOT" \
    --current "$current"

  [ "$status" -eq 0 ]
  [ ! -e "$expired" ]
  [ -e "$current" ]
}

@test "SKILL.md stores state outside the target worktree and delegates pruning to script" {
  grep -q 'XDG_STATE_HOME' "$SKILL_MD"
  grep -q 'scripts/cleanup-state.sh' "$SKILL_MD"
  grep -q 'canonical physical path' "$SKILL_MD"
  grep -Fq 'If the canonical `STATE_ROOT` is equal to canonical `REPO_ROOT` or inside canonical `REPO_ROOT`, abort before creating any state directory' "$SKILL_MD"
  grep -q 'symlinks, or `..` traversal' "$SKILL_MD"
  grep -q 'must never write state into the target worktree' "$SKILL_MD"
  ! grep -q 'State directory: `.codex/pr-review-coach/`' "$SKILL_MD"

  local guard_line mkdir_line
  guard_line="$(grep -n 'canonical `STATE_ROOT` is equal' "$SKILL_MD" | cut -d: -f1)"
  mkdir_line="$(grep -n 'Create the state directory with `mkdir -p`' "$SKILL_MD" | cut -d: -f1)"
  [ -n "$guard_line" ]
  [ -n "$mkdir_line" ]
  [ "$guard_line" -lt "$mkdir_line" ]
}

@test "SKILL.md pins clean worktree and final stale-output guards" {
  grep -Fq "git status --porcelain --untracked-files=normal" "$SKILL_MD"
  grep -Fq "If output is non-empty, abort and explain that the coach covers committed branch diff only" "$SKILL_MD"
  grep -Fq "Run \`git status --porcelain --untracked-files=normal\` again" "$SKILL_MD"
  grep -Fq "Run \`git rev-parse HEAD\` again and compare with \`HEAD_REF\`" "$SKILL_MD"
  grep -Fq "If any worktree content or HEAD changed, abort" "$SKILL_MD"
}

@test "SKILL.md allows answer continuation without --base only from one current state file" {
  grep -q 'explicit `--base <ref-or-commit>` on the first turn' "$SKILL_MD"
  grep -q 'If `--base` is missing, treat the prompt as an answer continuation' "$SKILL_MD"
  grep -Fq 'Find state files matching `$STATE_DIR/*-$HEAD_SHORT.md`' "$SKILL_MD"
  grep -q 'If multiple matching state files exist' "$SKILL_MD"
  grep -q '`status`: `active` or `complete`' "$SKILL_MD"
  grep -Fq 'For any existing `STATE_FILE`, whether it was selected by explicit `--base` or continuation lookup, validate it before reuse' "$SKILL_MD"
  grep -q 'Otherwise, abort if `status` is not `active`' "$SKILL_MD"
  grep -q 'If `status` is `complete`' "$SKILL_MD"
  grep -q 'do not resume it as an active question' "$SKILL_MD"
  grep -q 'passed the existing-state validation' "$SKILL_MD"
  grep -q 'set `status: complete`' "$SKILL_MD"
  grep -q 'current_question' "$SKILL_MD"
  ! grep -q 'If it is missing, stop and ask the user to rerun with `--base`' "$SKILL_MD"
}

@test "SKILL.md requires direct reaction before advancing coaching questions" {
  grep -Fq "On answer turns, respond to the user's answer before moving on" "$SKILL_MD"
  grep -Fq 'Say directly whether the answer is correct, partly correct, or off target' "$SKILL_MD"
  grep -Fq 'Do not advance to the next candidate question until the current answer is good enough to record as answered' "$SKILL_MD"
  response_section="$(
    awk '
      /^## Response To Your Answer$/ {in_section=1; next}
      /^## / && in_section {exit}
      in_section {print}
    ' "$SKILL_MD"
  )"
  [[ -n "$response_section" ]]
  printf '%s\n' "$response_section" | grep -qE '^- .*合っています.*一部合っています.*そこは違います'
  grep -Fq 'If the answer is incomplete, ambiguous, or off target, update `answer_attempts`, keep the same `current_question`' "$SKILL_MD"
  grep -Fq 'If the user sends an additional response for the same question' "$SKILL_MD"
  grep -Fq '`skipped_answer_attempts`: skipped or moved-on question attempts and coach reactions that are no longer tied to `current_question`' "$SKILL_MD"
  grep -Fq 'If the user explicitly asks to skip or move on, record the attempt in `skipped_answer_attempts`, advance `current_question`' "$SKILL_MD"
  grep -Fq 'Keep `answer_attempts` reserved for the active `current_question`; do not carry skipped attempts into the next question' "$SKILL_MD"
}

@test "SKILL.md fail-closes when context collection commands fail" {
  grep -q 'Run each command independently' "$SKILL_MD"
  grep -q 'If any command fails, abort with the command output' "$SKILL_MD"
  grep -q 'do not continue with partial context' "$SKILL_MD"
}
