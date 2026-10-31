#!/usr/bin/env bats
# shellcheck shell=bash
# Guards the Claude Code wrappers that render shared skills from dot_agents/.
# Every canonical file needs a wrapper that renders to the same content, or the
# Claude copy silently loses it while include and syntax checks stay green.
# Skills that Codex keeps explicit-only (agents/openai.yaml) must get exactly
# one injected `disable-model-invocation: true` in their SKILL.md frontmatter,
# and nothing else may differ. chezmoi's `replace` is silent when its pattern
# stops matching and rewrites every match, so a reworded canonical `name:` line
# would drop the opt-in and a matching body line would get an injection too.

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

# The Codex policy is the source of truth for which skills are explicit-only.
is_opt_in_skill() {
  local policy="$REPO_ROOT/dot_agents/skills/$1/agents/openai.yaml"
  [ -f "$policy" ] && grep -qE '^[[:space:]]*allow_implicit_invocation:[[:space:]]*false[[:space:]]*$' "$policy"
}

# Copies $1 to $2 without the injected lines inside the leading frontmatter,
# so an injection anywhere else still fails the comparison. Every frontmatter
# copy is removed; the caller checks that exactly one was there.
# Fails when $1 does not start with a closed frontmatter.
strip_frontmatter_injection() {
  awk 'NR == 1 { if ($0 != "---") { bad = 1; exit } print; next }
    !closed && $0 == "---" { closed = 1; print; next }
    !closed && $0 == "disable-model-invocation: true" { next }
    { print }
    END { if (bad || !closed) exit 1 }' "$1" > "$2"
}

# agents/ holds Codex-only metadata (openai.yaml) and has no Claude counterpart.
# The expected output is not derived by repeating the wrapper's replace rule:
# a canonical edit that defeats the rule would defeat the expectation too.
@test "every shared skill file has a Claude wrapper rendering the same content" {
  local canonical rel wrapper expected actual removed checked=0
  expected="$BATS_TEST_TMPDIR/expected"
  actual="$BATS_TEST_TMPDIR/actual"
  while IFS= read -r -d '' canonical; do
    rel="${canonical#"$REPO_ROOT/dot_agents/skills/"}"
    wrapper="$REPO_ROOT/private_dot_claude/skills/${rel%.tmpl}.tmpl"
    [ -f "$wrapper" ] || {
      printf 'Missing Claude wrapper for %s: %s\n' "$rel" "$wrapper" >&2
      return 1
    }
    if [[ "$canonical" == *.tmpl ]]; then
      render_template "$canonical" > "$expected" || {
        printf 'Canonical template failed to render: %s\n' "$rel" >&2
        return 1
      }
    else
      cp "$canonical" "$expected"
    fi
    render_template "$wrapper" > "$actual.raw" || {
      printf 'Claude wrapper failed to render for %s: %s\n' "$rel" "$wrapper" >&2
      return 1
    }
    if [[ "$rel" == */SKILL.md ]] && is_opt_in_skill "${rel%%/*}"; then
      strip_frontmatter_injection "$actual.raw" "$actual" || {
        printf '%s: rendered SKILL.md does not start with a closed frontmatter\n' "$rel" >&2
        return 1
      }
      removed=$(($(wc -l < "$actual.raw") - $(wc -l < "$actual")))
      [ "$removed" -eq 1 ] || {
        printf '%s: expected 1 injected disable-model-invocation line in frontmatter, found %s\n' "$rel" "$removed" >&2
        return 1
      }
    else
      cp "$actual.raw" "$actual"
    fi
    cmp "$expected" "$actual" || {
      printf 'Claude wrapper renders different content for %s\n' "$rel" >&2
      return 1
    }
    checked=$((checked + 1))
  done < <(find "$REPO_ROOT/dot_agents/skills" -type f -not -path '*/agents/*' -print0)
  [ "$checked" -gt 0 ]
}
