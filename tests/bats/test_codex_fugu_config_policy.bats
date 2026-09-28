#!/usr/bin/env bats
# shellcheck shell=bash
#
# Plan mode pin for the isolated Fugu home
# (private_dot_codex-fugu/modify_private_config.toml, policy: scripts/codex-config/policy-fugu.toml).

bats_require_minimum_version 1.5.0

setup() {
  : "${CODEX_CONFIG_TEST_PYTHON:?Prepare an isolated codex-config environment and set CODEX_CONFIG_TEST_PYTHON}"
  "$CODEX_CONFIG_TEST_PYTHON" -c 'import tomlkit, tomllib' || return 1
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_DATA_HOME="$HOME/data"
  export XDG_CONFIG_HOME="$HOME/config"
  export XDG_CACHE_HOME="$HOME/cache"
  export XDG_STATE_HOME="$HOME/state"
  export CHEZMOI_SOURCE_DIR
  CHEZMOI_SOURCE_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$XDG_DATA_HOME/codex-config-policy"
  ln -s "$(dirname "$(dirname "$CODEX_CONFIG_TEST_PYTHON")")" "$XDG_DATA_HOME/codex-config-policy/venv"
  MERGE="$BATS_TEST_DIRNAME/../../private_dot_codex-fugu/modify_private_config.toml"
  OUT="$BATS_TEST_TMPDIR/out.toml"
  ERR="$BATS_TEST_TMPDIR/err.txt"
  FIXTURE="$BATS_TEST_TMPDIR/config.toml"

  cat >"$FIXTURE" <<'EOF'
# >>> fugu:model_providers.sakana >>>
[model_providers.sakana]
name = "Sakana API"
base_url = "https://api.sakana.ai/v1"
# <<< fugu:model_providers.sakana <<<

[projects."/tmp/repo"]
trust_level = "trusted"

[hooks.state."/tmp/repo/.codex/hooks.json:stop:0:0"]
trusted_hash = "sha256:deadbeef"
enabled = true
EOF
}

merge() {
  /bin/sh "$MERGE" >"$OUT" 2>"$ERR" || {
    cat "$ERR" >&2
    false
  }
}

toml_valid() {
  "$CODEX_CONFIG_TEST_PYTHON" -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$1"
}

@test "inserts the pin above the installer block" {
  merge <"$FIXTURE"
  grep -qxF 'plan_mode_reasoning_effort = "xhigh"' "$OUT"
  [ "$(grep -n 'plan_mode_reasoning_effort' "$OUT" | cut -d: -f1)" -lt \
    "$(grep -n '# >>> fugu:model_providers.sakana >>>' "$OUT" | cut -d: -f1)" ]
  toml_valid "$OUT"
}

@test "preserves the installer block and Codex runtime state" {
  merge <"$FIXTURE"
  grep -qxF '# >>> fugu:model_providers.sakana >>>' "$OUT"
  grep -qxF 'base_url = "https://api.sakana.ai/v1"' "$OUT"
  grep -qxF '# <<< fugu:model_providers.sakana <<<' "$OUT"
  grep -qxF 'trust_level = "trusted"' "$OUT"
  grep -qxF 'trusted_hash = "sha256:deadbeef"' "$OUT"
  [ ! -s "$ERR" ] || {
    cat "$ERR" >&2
    false
  }
}

@test "re-asserts a stored Plan mode effort" {
  printf 'plan_mode_reasoning_effort = "medium"\n\n[tui]\nstatus_line_use_colors = true\n' | merge
  grep -qxF 'plan_mode_reasoning_effort = "xhigh"' "$OUT"
  grep -qxF 'status_line_use_colors = true' "$OUT"
  toml_valid "$OUT"
}

@test "does not import the vanilla pins" {
  merge <"$FIXTURE"
  "$CODEX_CONFIG_TEST_PYTHON" -c 'import sys, tomllib; data = tomllib.load(open(sys.argv[1], "rb")); assert set(data) == {"plan_mode_reasoning_effort", "model_providers", "projects", "hooks"}, data' "$OUT"
}

@test "creates only the pin when the Fugu config does not exist yet" {
  printf '' | merge
  printf 'plan_mode_reasoning_effort = "xhigh"\n' >"$BATS_TEST_TMPDIR/expected.toml"
  cmp -s "$OUT" "$BATS_TEST_TMPDIR/expected.toml" || {
    echo "unexpected output:" >&2
    cat "$OUT" >&2
    false
  }
}

@test "fails closed when the policy environment is missing" {
  rm "$XDG_DATA_HOME/codex-config-policy/venv"
  run --separate-stderr /bin/sh "$MERGE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"setup.sh"* ]]
}

@test "converges and then reports nothing" {
  merge <"$FIXTURE"
  /bin/sh "$MERGE" <"$OUT" >"$OUT.2" 2>"$ERR.2"
  cmp -s "$OUT" "$OUT.2" || {
    echo "second run changed the file" >&2
    false
  }
  [ ! -s "$ERR.2" ] || {
    cat "$ERR.2" >&2
    false
  }
  toml_valid "$OUT.2"
}
