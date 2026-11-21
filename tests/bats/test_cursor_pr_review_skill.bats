#!/usr/bin/env bats
# shellcheck shell=bash
# Cursor pr-review runs the Codex procedure. Specialist text and the shared
# gate files are generated from the Codex sources; the chezmoi templates only
# include those files so ~/.cursor gets real files, which skill sync requires.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SKILL="$REPO_ROOT/.cursor/skills/pr-review/SKILL.md"
  command -v chezmoi >/dev/null || {
    printf 'Required test dependency missing: chezmoi\n' >&2
    return 1
  }
  command -v python3 >/dev/null || {
    printf 'Required test dependency missing: python3\n' >&2
    return 1
  }
  CM_ROOT="$BATS_TEST_TMPDIR/cm"
  mkdir -p "$CM_ROOT/home" "$CM_ROOT/config" "$CM_ROOT/data" "$CM_ROOT/cache"
  : > "$CM_ROOT/config.toml"
  export REPO_ROOT SKILL CM_ROOT
}

chezmoi_env() {
  env HOME="$CM_ROOT/home" XDG_CONFIG_HOME="$CM_ROOT/config" \
    XDG_DATA_HOME="$CM_ROOT/data" XDG_CACHE_HOME="$CM_ROOT/cache" \
    chezmoi --source "$REPO_ROOT" --config "$CM_ROOT/config.toml" \
    --persistent-state "$CM_ROOT/state.boltdb" "$@"
}

@test "cursor pr-review files match the Codex sources" {
  python3 "$REPO_ROOT/tests/cursor/render_pr_review_agents.py" --check
}

@test "cursor pr-review templates render the included file" {
  local tmpl rel target checked=0
  while IFS= read -r -d '' tmpl; do
    rel="${tmpl#"$REPO_ROOT/dot_cursor/"}"
    rel="${rel%.tmpl}"
    target="$REPO_ROOT/.cursor/$rel"
    [ -f "$target" ]
    [ ! -L "$target" ]
    chezmoi_env execute-template --file "$tmpl" > "$BATS_TEST_TMPDIR/rendered" || {
      printf 'template failed: %s\n' "$tmpl" >&2
      return 1
    }
    cmp "$target" "$BATS_TEST_TMPDIR/rendered" || {
      printf 'render drifted: %s\n' "$tmpl" >&2
      return 1
    }
    run chezmoi_env target-path "${tmpl#"$REPO_ROOT/"}"
    [ "$status" -eq 0 ]
    [ "$output" = "$CM_ROOT/home/.cursor/$rel" ]
    run chezmoi_env source-path "$CM_ROOT/home/.cursor/$rel"
    [ "$status" -eq 0 ]
    [ "$output" = "$tmpl" ]
    checked=$((checked + 1))
  done < <(find "$REPO_ROOT/dot_cursor/skills/pr-review" "$REPO_ROOT/dot_cursor/agents" -type f -name '*.tmpl' -print0)
  [ "$checked" -gt 0 ]
}

@test "cursor pr-review deploys each included file once" {
  local tmpl rel copies checked=0
  run chezmoi_env managed --include=files --exclude=encrypted
  [ "$status" -eq 0 ]
  while IFS= read -r -d '' tmpl; do
    rel="${tmpl#"$REPO_ROOT/dot_cursor/"}"
    rel="${rel%.tmpl}"
    copies=$(printf '%s\n' "$output" | grep -c -F -x ".cursor/${rel}" || true)
    [ "$copies" -eq 1 ] || {
      printf 'expected one managed .cursor/%s, found %s\n' "$rel" "$copies" >&2
      return 1
    }
    checked=$((checked + 1))
  done < <(find "$REPO_ROOT/dot_cursor/skills/pr-review" "$REPO_ROOT/dot_cursor/agents" -type f -name '*.tmpl' -print0)
  [ "$checked" -gt 0 ]
}

@test "cursor pr-review skill launches Codex specialists through Cursor subagents" {
  [ "$(basename "$(dirname "$SKILL")")" = "pr-review" ]
  grep -q '^name: pr-review$' "$SKILL"
  grep -q '^disable-model-invocation: true$' "$SKILL"
  grep -q 'subagent_type' "$SKILL"
  grep -q 'generalPurpose' "$SKILL"
  grep -q 'Codex の `spawn_agent` は使わない。' "$SKILL"
  grep -q '#482' "$SKILL"
  grep -q 'blocking' "$SKILL"
  grep -q 'validate_finding_evidence.py' "$SKILL"
  if grep -q 'routing-flags' "$SKILL"; then
    printf 'Cursor pr-review must not use the Claude routing floor\n' >&2
    return 1
  fi
}

@test "cursor pr-review is not on a Claude or Codex skill path" {
  [ ! -e "$REPO_ROOT/dot_agents/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.agents/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.claude/skills/pr-review" ]
  [ ! -e "$REPO_ROOT/.codex/skills/pr-review" ]
  [ -f "$REPO_ROOT/private_dot_claude/skills/pr-review/SKILL.md" ]
  [ -f "$REPO_ROOT/private_dot_codex/skills/pr-review/SKILL.md" ]
}
