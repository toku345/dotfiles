#!/usr/bin/env bats
# shellcheck shell=bash
#
# Per-key pin/seed merge for ~/.codex/config.toml
# (private_dot_codex/modify_private_config.toml, policy: docs/codex.md).

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
  MERGE="$BATS_TEST_DIRNAME/../../private_dot_codex/modify_private_config.toml"
  OUT="$BATS_TEST_TMPDIR/out.toml"
  ERR="$BATS_TEST_TMPDIR/err.txt"
  FIXTURE="$BATS_TEST_TMPDIR/config.toml"

  cat >"$FIXTURE" <<'EOF'
approval_policy = "never"
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
sandbox_mode = "danger-full-access"

service_tier = "fast"
notify = ["/x"]

[sandbox_workspace_write]
writable_roots = ["/w"]
network_access = true

[features]
apps = true
multi_agent = true
prevent_idle_sleep = true

[plugins."github@openai-curated"]
enabled = true

[projects."/tmp/x"]
trust_level = "trusted"

[tui]
status_line = [
  "model-with-reasoning",
  "current-dir",
  "git-branch",
  "context-remaining",
  "five-hour-limit",
  "codex-version",
  "pull-request-number",
  "branch-changes",
  "run-state",
  "task-progress",
]
status_line_use_colors = false

# >>> fugu:model_providers.sakana >>>
[model_providers.sakana]
name = "Sakana API"
# <<< fugu:model_providers.sakana <<<

[features.context_management]
experimental_mode = true
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

@test "creates the managed skeleton from an empty config" {
  printf '' | merge
  grep -qxF 'sandbox_mode = "workspace-write"' "$OUT"
  grep -qxF 'approval_policy = "on-request"' "$OUT"
  grep -qxF 'plan_mode_reasoning_effort = "xhigh"' "$OUT"
  grep -qxF 'multi_agent = true' "$OUT"
  grep -qxF 'network_access = false' "$OUT"
  toml_valid "$OUT"
}

@test "re-asserts pins without touching free keys or the installer block" {
  merge <"$FIXTURE"
  grep -qxF 'approval_policy = "on-request"' "$OUT"
  grep -qxF 'sandbox_mode = "workspace-write"' "$OUT"
  grep -qxF 'network_access = false' "$OUT"
  grep -qxF 'status_line_use_colors = true' "$OUT"
  grep -qxF 'enabled = true' "$OUT"

  grep -qxF 'service_tier = "fast"' "$OUT"
  grep -qxF 'notify = ["/x"]' "$OUT"
  grep -qxF 'writable_roots = ["/w"]' "$OUT"
  grep -qxF 'trust_level = "trusted"' "$OUT"
  grep -qxF 'prevent_idle_sleep = true' "$OUT"
  grep -qxF '# >>> fugu:model_providers.sakana >>>' "$OUT"
  grep -qxF 'name = "Sakana API"' "$OUT"
  grep -qxF '# <<< fugu:model_providers.sakana <<<' "$OUT"
  toml_valid "$OUT"
}

@test "does not rewrite an array pin that Codex reformatted" {
  merge <"$FIXTURE"
  grep -qxF 'status_line = [' "$OUT"
  grep -qxF '  "task-progress",' "$OUT"
}

@test "keeps a live seed value and reports the divergence on stderr" {
  merge <"$FIXTURE"
  grep -qxF 'model = "gpt-5.6-sol"' "$OUT"
  grep -qxF 'model_reasoning_effort = "high"' "$OUT"
  grep -q 'seed model differs from the declared value' "$ERR"
  grep -q 'seed model_reasoning_effort differs from the declared value' "$ERR"
}

@test "inserts missing seeds and pins into their sections" {
  merge <"$FIXTURE"
  grep -qxF 'plan_mode_reasoning_effort = "xhigh"' "$OUT"
  grep -qxF 'personality = "pragmatic"' "$OUT"
  grep -qxF 'approvals_reviewer = "guardian_subagent"' "$OUT"
  grep -qxF 'mentions_v2 = true' "$OUT"
  grep -qxF 'guardian_approval = true' "$OUT"
  grep -qxF 'experimental_mode = true' "$OUT"
}

@test "converges and then reports nothing" {
  printf '' | merge
  [ ! -s "$ERR" ] || {
    cat "$ERR" >&2
    false
  }
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
