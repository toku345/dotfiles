#!/usr/bin/env bats
# shellcheck shell=bash
# Guards the Claude Code wrappers that render shared skills from dot_agents/.
# Every canonical file needs a wrapper that renders to the same content, or the
# Claude copy silently loses it while include and syntax checks stay green.
# Opt-in wrappers also inject `disable-model-invocation: true`; chezmoi's
# `replace` is silent when its pattern stops matching, so a reworded canonical
# `name:` line would otherwise drop the opt-in.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  command -v chezmoi >/dev/null || {
    printf 'Required test dependency missing: chezmoi\n' >&2
    return 1
  }
  CM_ROOT="$BATS_TEST_TMPDIR/cm"
  mkdir -p "$CM_ROOT/home" "$CM_ROOT/config" "$CM_ROOT/data" "$CM_ROOT/cache"
  : > "$CM_ROOT/config.toml"
  export REPO_ROOT CM_ROOT
}

render_template() {
  env HOME="$CM_ROOT/home" XDG_CONFIG_HOME="$CM_ROOT/config" \
    XDG_DATA_HOME="$CM_ROOT/data" XDG_CACHE_HOME="$CM_ROOT/cache" \
    chezmoi --source "$REPO_ROOT" --config "$CM_ROOT/config.toml" \
    --persistent-state "$CM_ROOT/state.boltdb" \
    execute-template --file "$1"
}

# The expected output is not derived by repeating the wrapper's replace rule:
# a canonical edit that defeats the rule would defeat the expectation too.
assert_opt_in_wrapper() {
  local name="$1" rendered="$BATS_TEST_TMPDIR/$1.md"
  render_template "$REPO_ROOT/private_dot_claude/skills/$name/SKILL.md.tmpl" > "$rendered"

  run awk 'NR == 1 && $0 != "---" { exit 1 }
    NR > 1 && $0 == "---" { exit }
    $0 == "disable-model-invocation: true" { n++ }
    END { print n + 0 }' "$rendered"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]

  grep -vFx 'disable-model-invocation: true' "$rendered" > "$rendered.stripped"
  cmp "$rendered.stripped" "$REPO_ROOT/dot_agents/skills/$name/SKILL.md"
}

@test "co-dev Claude wrapper injects disable-model-invocation into the canonical skill" {
  assert_opt_in_wrapper co-dev
}

@test "teach Claude wrapper injects disable-model-invocation into the canonical skill" {
  assert_opt_in_wrapper teach
}

# agents/ holds Codex-only metadata (openai.yaml) and has no Claude counterpart.
@test "every shared skill file has a Claude wrapper rendering the same content" {
  local canonical rel wrapper expected actual checked=0
  while IFS= read -r -d '' canonical; do
    rel="${canonical#"$REPO_ROOT/dot_agents/skills/"}"
    wrapper="$REPO_ROOT/private_dot_claude/skills/${rel%.tmpl}.tmpl"
    [ -f "$wrapper" ] || {
      printf 'Missing Claude wrapper for %s: %s\n' "$rel" "$wrapper" >&2
      return 1
    }
    expected="$BATS_TEST_TMPDIR/expected"
    actual="$BATS_TEST_TMPDIR/actual"
    if [[ "$canonical" == *.tmpl ]]; then
      render_template "$canonical" > "$expected"
    else
      cp "$canonical" "$expected"
    fi
    render_template "$wrapper" | grep -vFx 'disable-model-invocation: true' > "$actual" || true
    cmp "$expected" "$actual" || {
      printf 'Claude wrapper renders different content for %s\n' "$rel" >&2
      return 1
    }
    checked=$((checked + 1))
  done < <(find "$REPO_ROOT/dot_agents/skills" -type f -not -path '*/agents/*' -print0)
  [ "$checked" -gt 0 ]
}
