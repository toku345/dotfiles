#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  GROK_DOC="$REPO_ROOT/docs/grok.md"
  GROK_SOURCE_DIR="$REPO_ROOT/private_dot_grok"
  CHECK_SCRIPT="$BATS_TEST_TMPDIR/grok-apply-check.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  export REPO_ROOT GROK_DOC GROK_SOURCE_DIR CHECK_SCRIPT STUB_BIN TEST_HOME

  mkdir -p "$STUB_BIN" "$TEST_HOME"

  awk '
    $0 == "<!-- grok-apply-check:start -->" {
      starts++
      in_block=1
      next
    }
    $0 == "<!-- grok-apply-check:end -->" {
      ends++
      in_block=0
      next
    }
    in_block && $0 !~ /^```(sh)?$/ { print }
    END {
      if (starts != 1 || ends != 1 || in_block) exit 2
    }
  ' "$GROK_DOC" > "$CHECK_SCRIPT"

  cat > "$STUB_BIN/grok" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

case "${GROK_STUB_MODE:-mixed-case}" in
  mixed-case)
    printf '{"projectInstructions":[{"scope":"global","path":"%s/.grok/Agents.md"}]}\n' "$HOME"
    ;;
  uppercase)
    printf '{"projectInstructions":[{"scope":"global","path":"%s/.grok/AGENTS.md"}]}\n' "$HOME"
    ;;
  wrong-scope)
    printf '{"projectInstructions":[{"scope":"project","path":"%s/.grok/Agents.md"}]}\n' "$HOME"
    ;;
  duplicate)
    printf '{"projectInstructions":[{"scope":"global","path":"%s/.grok/Agents.md"},{"scope":"global","path":"%s/.grok/AGENTS.md"}]}\n' "$HOME" "$HOME"
    ;;
  missing)
    printf '{"projectInstructions":[]}\n'
    ;;
  missing-key)
    printf '{}\n'
    ;;
  null)
    printf '{"projectInstructions":null}\n'
    ;;
  non-array)
    printf '{"projectInstructions":{}}\n'
    ;;
  nonzero)
    printf '{"projectInstructions":[{"scope":"global","path":"%s/.grok/Agents.md"}]}\n' "$HOME"
    exit 42
    ;;
  *)
    echo "unsupported GROK_STUB_MODE: $GROK_STUB_MODE" >&2
    exit 64
    ;;
esac
STUB
  chmod +x "$STUB_BIN/grok"
}

run_documented_check() {
  local mode="$1"
  run env \
    HOME="$TEST_HOME" \
    PATH="$STUB_BIN:$PATH" \
    GROK_STUB_MODE="$mode" \
    bash "$CHECK_SCRIPT"
}

@test "private_dot_grok contains exactly the current top-level allowlist" {
  [ -f "$GROK_SOURCE_DIR/AGENTS.md" ]
  [ ! -L "$GROK_SOURCE_DIR/AGENTS.md" ]

  run bash -o pipefail -c '
    find "$1" -mindepth 1 -maxdepth 1 -print |
      sed "s#^$1/##" |
      LC_ALL=C sort
  ' bash "$GROK_SOURCE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "AGENTS.md" ]
}

@test "private_dot_grok AGENTS keeps the core Grok trailer contract" {
  run grep -Fxc 'AI-Assisted-By: Grok Build (<model-id>)' "$GROK_SOURCE_DIR/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run grep -Fc 'Do not infer it from a config file, profile, or prior session.' "$GROK_SOURCE_DIR/AGENTS.md"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "documented check accepts Grok path casing variants" {
  run_documented_check mixed-case
  [ "$status" -eq 0 ]
  [ "$output" = "global $TEST_HOME/.grok/Agents.md" ]

  run_documented_check uppercase
  [ "$status" -eq 0 ]
  [ "$output" = "global $TEST_HOME/.grok/AGENTS.md" ]
}

@test "documented check rejects a non-global instruction" {
  run_documented_check wrong-scope
  [ "$status" -eq 1 ]
  [[ "$output" == *"found 0"* ]]
}

@test "documented check rejects duplicate global instructions" {
  run_documented_check duplicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"found 2"* ]]
}

@test "documented check rejects a missing instruction" {
  run_documented_check missing
  [ "$status" -eq 1 ]
  [[ "$output" == *"found 0"* ]]
}

@test "documented check rejects a missing projectInstructions key" {
  run_documented_check missing-key
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing projectInstructions"* ]]
}

@test "documented check rejects non-array projectInstructions" {
  run_documented_check null
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array, got NoneType"* ]]

  run_documented_check non-array
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be an array, got dict"* ]]
}

@test "documented check preserves grok inspect failure" {
  run_documented_check nonzero
  [ "$status" -eq 1 ]
  [[ "$output" == *"returned non-zero exit status 42"* ]]
}
