#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  resolve_bash5
  export SRC="$BATS_TEST_DIRNAME/../../dot_local/bin/executable_codex-fugu"
  export HOME="$BATS_TEST_TMPDIR/home with spaces"
  mkdir -p "$HOME/.codex-fugu/bin" "$HOME/.local/bin"
  cat > "$HOME/.codex-fugu/bin/codex-fugu" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "$CODEX_HOME" == "$HOME/.codex-fugu" ]]
[[ "$CODEX_INSTALL_DIR" == "$CODEX_HOME/bin" ]]
[[ "$CODEX_FUGU_REAL_CODEX" == "$CODEX_INSTALL_DIR/codex" ]]
[[ "$CODEX_SQLITE_HOME" == "$CODEX_HOME" ]]
[[ "$FUGU_ENV_FILE" == "$CODEX_HOME/.env" ]]
[[ "$CODEX_BACKUP_ROOT" == "$CODEX_HOME/backups" ]]
[[ ! -v SAKANA_API_KEY ]]
[[ "$(command -v codex)" == "$CODEX_FUGU_REAL_CODEX" ]]
if [[ "${1:-}" == --check || "${1:-}" == --set-key ]]; then
  "$BASH" -c '[[ "$CODEX_HOME" == "$HOME/.codex-fugu" && "$FUGU_ENV_FILE" == "$CODEX_HOME/.env" && ! -v SAKANA_API_KEY && "$(command -v codex)" == "$CODEX_FUGU_REAL_CODEX" ]]'
fi
exec "$CODEX_FUGU_REAL_CODEX" "$@"
EOF
  cat > "$HOME/.codex-fugu/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'dedicated\n'
printf '<%s>\n' "$@"
exit "${STUB_EXIT:-0}"
EOF
  cat > "$HOME/.local/bin/codex-fugu" <<'EOF'
#!/bin/sh
exec "$BASH5_BIN" "$SRC" "$@"
EOF
  chmod +x "$HOME/.codex-fugu/bin/"* "$HOME/.local/bin/codex-fugu"
  export PATH="$HOME/.local/bin:$PATH"
  export CODEX_HOME=/wrong CODEX_INSTALL_DIR=/wrong CODEX_FUGU_REAL_CODEX=/wrong
  export CODEX_SQLITE_HOME=/wrong FUGU_ENV_FILE=/wrong CODEX_BACKUP_ROOT=/wrong
  export SAKANA_API_KEY=dummy-inherited-key
}

@test "isolates state and key while preserving arguments and the parent environment" {
  local parent_path="$PATH"
  run codex-fugu --no-update '' 'two words' '*'
  [ "$status" -eq 0 ]
  [ "$output" = $'dedicated\n<--no-update>\n<>\n<two words>\n<*>' ]
  [ "$CODEX_HOME" = /wrong ]
  [ "$PATH" = "$parent_path" ]
  [ "$SAKANA_API_KEY" = dummy-inherited-key ]
}

@test "preserves launcher options and exports isolation to update and key children" {
  local option
  for option in --status --check --set-key --recheck; do
    run codex-fugu "$option"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'dedicated\n<%s>' "$option")" ]
  done
}

@test "preserves the launched command exit status" {
  export STUB_EXIT=42
  run codex-fugu
  [ "$status" -eq 42 ]
}

@test "missing CLI never falls back to a same-version codex on PATH" {
  rm "$HOME/.codex-fugu/bin/codex"
  cat > "$HOME/.local/bin/codex" <<'EOF'
#!/bin/sh
touch "$HOME/fallback-used"
printf 'codex-cli 0.154.0\n'
EOF
  chmod +x "$HOME/.local/bin/codex"
  run -127 codex-fugu --version
  [ "$status" -eq 127 ]
  [[ "$output" == *"missing executable:"* ]]
  [ ! -e "$HOME/fallback-used" ]
}

@test "missing or non-executable launcher fails before starting the CLI" {
  chmod -x "$HOME/.codex-fugu/bin/codex-fugu"
  run -127 codex-fugu
  [ "$status" -eq 127 ]
  [[ "$output" != *dedicated* ]]
  rm "$HOME/.codex-fugu/bin/codex-fugu"
  run -127 codex-fugu
  [ "$status" -eq 127 ]
}

@test "rejects a dedicated target symlinked to the managed wrapper" {
  local target
  for target in codex-fugu codex; do
    rm "$HOME/.codex-fugu/bin/$target"
    # Source mode is 0644; a temporary executable copy models the deployed file.
    cp "$SRC" "$HOME/.local/bin/codex-fugu"
    chmod +x "$HOME/.local/bin/codex-fugu"
    ln -s "$HOME/.local/bin/codex-fugu" "$HOME/.codex-fugu/bin/$target"
    run codex-fugu
    [ "$status" -eq 126 ]
    [[ "$output" == *"refusing recursive launcher:"* ]]
    rm "$HOME/.codex-fugu/bin/$target"
    printf '#!/bin/sh\nexit 0\n' > "$HOME/.codex-fugu/bin/$target"
    chmod +x "$HOME/.codex-fugu/bin/$target"
  done
}

@test "macOS system Bash is rejected before any launcher runs" {
  [[ "$(uname -s)" == Darwin ]] || skip "macOS system Bash 3.2 compatibility guard"
  (( $(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"') < 5 )) || skip "system Bash is already supported"
  run /bin/bash "$SRC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires bash 5+"* ]]
}
