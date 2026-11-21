#!/usr/bin/env bats
# shellcheck shell=bash
# The Cursor pr-review entry is an explicit door, not a third review procedure.
# .cursor/skills/pr-review/SKILL.md is the only editable copy. The chezmoi
# template must render to those same bytes at ~/.cursor/skills/pr-review/SKILL.md.
# A second copy under .agents, .claude, or .codex would change which skill
# Codex or Claude loads for this name.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  CANONICAL="$REPO_ROOT/.cursor/skills/pr-review/SKILL.md"
  TEMPLATE="$REPO_ROOT/dot_cursor/skills/pr-review/SKILL.md.tmpl"
  command -v chezmoi >/dev/null || {
    printf 'Required test dependency missing: chezmoi\n' >&2
    return 1
  }
  CM_ROOT="$BATS_TEST_TMPDIR/cm"
  mkdir -p "$CM_ROOT/home" "$CM_ROOT/config" "$CM_ROOT/data" "$CM_ROOT/cache"
  : > "$CM_ROOT/config.toml"
  export REPO_ROOT CANONICAL TEMPLATE CM_ROOT
}

chezmoi_env() {
  env HOME="$CM_ROOT/home" XDG_CONFIG_HOME="$CM_ROOT/config" \
    XDG_DATA_HOME="$CM_ROOT/data" XDG_CACHE_HOME="$CM_ROOT/cache" \
    chezmoi --source "$REPO_ROOT" --config "$CM_ROOT/config.toml" \
    --persistent-state "$CM_ROOT/state.boltdb" "$@"
}

@test "cursor pr-review template renders the canonical skill" {
  [ -f "$CANONICAL" ]
  [ -f "$TEMPLATE" ]
  [ ! -L "$CANONICAL" ]
  grep -q 'include "\.cursor/skills/pr-review/SKILL\.md"' "$TEMPLATE"
  chezmoi_env execute-template --file "$TEMPLATE" > "$BATS_TEST_TMPDIR/rendered" || {
    printf 'template failed to render\n' >&2
    return 1
  }
  cmp "$CANONICAL" "$BATS_TEST_TMPDIR/rendered"
}

@test "cursor pr-review deploys only through dot_cursor" {
  run chezmoi_env target-path "dot_cursor/skills/pr-review/SKILL.md.tmpl"
  [ "$status" -eq 0 ]
  [ "$output" = "$CM_ROOT/home/.cursor/skills/pr-review/SKILL.md" ]

  run chezmoi_env source-path "$CM_ROOT/home/.cursor/skills/pr-review/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEMPLATE" ]

  run chezmoi_env managed --include=files --exclude=encrypted
  [ "$status" -eq 0 ]
  copies=$(printf '%s\n' "$output" | grep -c '^\.cursor/skills/pr-review/SKILL\.md$' || true)
  [ "$copies" -eq 1 ]
}

@test "cursor pr-review is explicit and does not run a review" {
  [ "$(basename "$(dirname "$CANONICAL")")" = "pr-review" ]
  grep -q '^name: pr-review$' "$CANONICAL"
  grep -q '^disable-model-invocation: true$' "$CANONICAL"
  grep -q '^レビューをしない。specialist を起動しない。diff を読んで指摘を書かない。次の3点を返して止まる。$' "$CANONICAL"
  # A full specialist procedure does not fit in this cap. Growing past it
  # means the undecided Claude/Codex choice leaked into this entry.
  [ "$(wc -l < "$CANONICAL")" -le 60 ]
}

@test "cursor pr-review is not on a Claude or Codex skill path" {
  [ ! -e "$REPO_ROOT/dot_agents/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.agents/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.claude/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.codex/skills/pr-review" ]
  [ -f "$REPO_ROOT/private_dot_claude/skills/pr-review/SKILL.md" ]
  [ -f "$REPO_ROOT/private_dot_codex/skills/pr-review/SKILL.md" ]
}
