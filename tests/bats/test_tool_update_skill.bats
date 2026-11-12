#!/usr/bin/env bats
# shellcheck shell=bash
# Static checks for the project-scope tool-update skill (#462). The skill is a
# procedure that points at docs; these tests catch a skill that no longer loads
# or that cites a file or section which has moved.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL="$REPO_ROOT/.claude/skills/tool-update/SKILL.md"
  export REPO_ROOT SKILL
}

# Print the YAML frontmatter (the lines between the first two `---` lines).
frontmatter() {
  awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { exit } NR > 1' "$SKILL"
}

# Print every repo path the skill cites in backticks, one per line.
cited_paths() {
  # shellcheck disable=SC2016 # the backticks are literal Markdown, not a command substitution
  grep -oE '`(docs|tests|private_dot_config|\.claude)/[^` ]+`|`AGENTS\.md`' "$SKILL" | tr -d '`' | sort -u
}

@test "tool-update skill has the frontmatter Claude Code needs to load it" {
  run frontmatter
  [ "$status" -eq 0 ]
  grep -Fqx 'name: tool-update' <<<"$output"
  grep -Eq '^description: .+' <<<"$output"
}

@test "every repo path the tool-update skill cites exists" {
  run cited_paths
  [ "$status" -eq 0 ]
  local path count=0
  while IFS= read -r path; do
    count=$((count + 1))
    [ -e "$REPO_ROOT/$path" ] || { echo "cited path does not exist: $path" >&2; return 1; }
  done <<<"$output"
  # The skill must keep pointing at the procedure and the policy test.
  (( count >= 3 ))
  grep -Fqx 'docs/mise.md' <<<"$output"
  grep -Fqx 'docs/security.md' <<<"$output"
  grep -Fqx 'tests/bats/test_mise_policy.bats' <<<"$output"
}

@test "the doc sections the tool-update skill names still exist" {
  grep -Fqx '## 更新 (lock の bump)' "$REPO_ROOT/docs/mise.md"
  grep -Fqx '### When to bypass the cooldown' "$REPO_ROOT/docs/security.md"
  grep -Fq 'Chezmoi Operations' "$REPO_ROOT/AGENTS.md"
  grep -Fq '更新 (lock の bump)' "$SKILL"
  grep -Fq 'When to bypass the cooldown' "$SKILL"
}

@test "docs/mise.md points agents at the tool-update skill" {
  grep -Fq '.claude/skills/tool-update/SKILL.md' "$REPO_ROOT/docs/mise.md"
}
