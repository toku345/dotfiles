#!/usr/bin/env bats
# shellcheck shell=bash
# Cursor pr-review is a pointer at the Codex sources. A second copy of the
# procedure would fork the gate that #436 is trying to unify.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL="$REPO_ROOT/.cursor/skills/pr-review/SKILL.md"
  TEMPLATE="$REPO_ROOT/dot_cursor/skills/pr-review/SKILL.md.tmpl"
  command -v chezmoi >/dev/null || {
    printf 'Required test dependency missing: chezmoi\n' >&2
    return 1
  }
  CM_ROOT="$BATS_TEST_TMPDIR/cm"
  mkdir -p "$CM_ROOT/home" "$CM_ROOT/config" "$CM_ROOT/data" "$CM_ROOT/cache"
  : > "$CM_ROOT/config.toml"
  export REPO_ROOT SKILL TEMPLATE CM_ROOT
}

chezmoi_env() {
  env HOME="$CM_ROOT/home" XDG_CONFIG_HOME="$CM_ROOT/config" \
    XDG_DATA_HOME="$CM_ROOT/data" XDG_CACHE_HOME="$CM_ROOT/cache" \
    chezmoi --source "$REPO_ROOT" --config "$CM_ROOT/config.toml" \
    --persistent-state "$CM_ROOT/state.boltdb" "$@"
}

@test "cursor pr-review template renders the skill" {
  [ -f "$SKILL" ]
  [ ! -L "$SKILL" ]
  chezmoi_env execute-template --file "$TEMPLATE" > "$BATS_TEST_TMPDIR/rendered" || {
    printf 'template failed to render\n' >&2
    return 1
  }
  cmp "$SKILL" "$BATS_TEST_TMPDIR/rendered"
  run chezmoi_env target-path "dot_cursor/skills/pr-review/SKILL.md.tmpl"
  [ "$status" -eq 0 ]
  [ "$output" = "$CM_ROOT/home/.cursor/skills/pr-review/SKILL.md" ]
}

@test "cursor pr-review points at Codex and does not vendor it" {
  [ "$(basename "$(dirname "$SKILL")")" = "pr-review" ]
  grep -q '^name: pr-review$' "$SKILL"
  grep -q '^disable-model-invocation: true$' "$SKILL"
  grep -q 'private_dot_codex/skills/pr-review/SKILL.md' "$SKILL"
  grep -q 'private_dot_codex/agents/\*\.toml' "$SKILL"
  grep -q 'subagent_type' "$SKILL"
  grep -q 'generalPurpose' "$SKILL"
  grep -q 'どちらも読めなければ止まる' "$SKILL"
  [ ! -e "$REPO_ROOT/.cursor/agents" ]
  [ ! -e "$REPO_ROOT/.cursor/skills/pr-review/agents" ]
  [ ! -e "$REPO_ROOT/.cursor/skills/pr-review/references" ]
  [ ! -e "$REPO_ROOT/.cursor/skills/pr-review/scripts" ]
  [ ! -e "$REPO_ROOT/dot_cursor/agents" ]
  [ ! -e "$REPO_ROOT/tests/cursor" ]
  if grep -q 'routing-flags' "$SKILL"; then
    printf 'Cursor entry must not grow a Claude routing copy\n' >&2
    return 1
  fi
  # The Codex procedure stays in the Codex skill. This file only points at it.
  [ "$(wc -l < "$SKILL")" -le 40 ]
}

@test "cursor pr-review is not on a Claude or Codex skill path" {
  [ ! -e "$REPO_ROOT/dot_agents/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.agents/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.claude/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.codex/skills/pr-review" ]
  [ -f "$REPO_ROOT/private_dot_claude/skills/pr-review/SKILL.md" ]
  [ -f "$REPO_ROOT/private_dot_codex/skills/pr-review/SKILL.md" ]
}
