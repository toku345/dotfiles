#!/usr/bin/env bash
# shellcheck shell=bash
# Bats assigns status/stderr/output when run finishes.
# shellcheck disable=SC2154
# Shared regression assertions, invoked separately through each runtime adapter.

assert_changed_shell_inventory() {
  local rel
  # Shebang-less hooks/helpers must be linted, but never sourced/executed.
  init_hook_repo "notes.txt" 'initial'
  for rel in .claude/hooks/check.sh .codex/hooks/check.sh \
    scripts/hooks/check.sh dot_local/lib/nested/check.sh \
    tests/bats/utils.bash tests/bats/bin/new-stub; do
    mkdir -p "$PROJECT_DIR/$(dirname "$rel")"
    printf '# shellcheck shell=bash\nunused_inventory_var=42\ntouch "%s"\n' \
      "$BATS_TEST_TMPDIR/helper-executed" > "$PROJECT_DIR/$rel"
    run_stop_hook <<<'{}'
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"$rel"* ]]
    [[ "$stderr" == *"SC2034"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/helper-executed" ]
    rm "$PROJECT_DIR/$rel"
    rm -f "$(hook_state_file)"
  done
}

assert_stop_checks_changes_only() {
  init_hook_repo "scripts/hooks/unchanged.sh" \
    $'# shellcheck shell=bash\nunused_inventory_var=42\n'
  git -C "$PROJECT_DIR" -c core.hooksPath=/dev/null -c user.email=t@t \
    -c user.name=t commit -qm baseline
  # A non-shell executable must not be sent to ShellCheck by its prefix alone.
  mkdir -p "$PROJECT_DIR/dot_local/bin"
  printf '#!/usr/bin/env python3\nprint("ok")\n' \
    > "$PROJECT_DIR/dot_local/bin/executable_python"
  run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"shellcheck failed"* ]]
}

assert_runtime_root_and_state_isolation() {
  init_hook_repo "scripts/hooks/check.sh" \
    $'# shellcheck shell=bash\nunused_inventory_var=42\n'
  mkdir -p "$PROJECT_DIR/nested"
  cd "$PROJECT_DIR/nested" || return 1
  run_stop_hook <<<'{}'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"scripts/hooks/check.sh"* ]]
  [ "$(cat "$(hook_state_file)")" = 1 ]
  local other_runtime=claude other_state
  [[ "$HOOK_VERIFY" == */.claude/* ]] && other_runtime=codex
  other_state="$(hook_state_file)"
  other_state="${other_state/\/claude\//\/$other_runtime\/}"
  other_state="${other_state/\/codex\//\/$other_runtime\/}"
  [ ! -e "$other_state" ]
}

# A successful lookup must never turn into execution, even for --version.
install_bats_execution_sentinel() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<STUB
#!/usr/bin/env bash
touch '$BATS_TEST_TMPDIR/bats-was-invoked'
exit 97
STUB
  chmod +x "$stub_dir/bats"
}

legacy_reminder_file() {
  local state_file
  state_file="$(hook_state_file)"
  printf '%s\n' "${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"
}

assert_advisory_json() {
  [ "$status" -eq 0 ]
  # Parse the entire stdout stream: exactly one object, no control fields or
  # extra plain text. jq is a required dependency in both CI environments.
  jq -e -s '
    length == 1 and
    (.[0] | keys == ["systemMessage"]) and
    (.[0].systemMessage |
      type == "string" and contains("bats tests/bats/") and
      contains("does not verify test status"))
  ' <<<"$output" >/dev/null
}

assert_bats_advisory_is_stateless_and_never_executes_tests() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  install_bats_execution_sentinel "$stub_dir"
  init_hook_repo "tests/bats/dummy.bats" $'load utils\n@test "noop" { true; }\n'
  # A real helper would be sourced by the test above if the suite ran.
  printf 'touch "%s"\n' "$BATS_TEST_TMPDIR/helper-executed" \
    > "$PROJECT_DIR/tests/bats/utils.bash"

  local attempt
  for attempt in 1 2 3 4 5; do
    PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
    assert_advisory_json
    [ -z "$stderr" ]
    [ ! -e "$(hook_state_file)" ]
    [ ! -e "$(legacy_reminder_file)" ]
    [ ! -e "$BATS_TEST_TMPDIR/bats-was-invoked" ]
    [ ! -e "$BATS_TEST_TMPDIR/helper-executed" ]
  done
  [ ! -e "$XDG_STATE_HOME" ]
}

assert_bats_advisory_detects_changes_and_stays_silent_when_clean() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  install_bats_execution_sentinel "$stub_dir"
  init_hook_repo "tests/bats/fixtures/data.txt" 'baseline'
  git -C "$PROJECT_DIR" -c user.email=t@t -c user.name=t commit -qm baseline

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  printf 'modified\n' > "$PROJECT_DIR/tests/bats/fixtures/data.txt"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  assert_advisory_json

  rm "$PROJECT_DIR/tests/bats/fixtures/data.txt"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  assert_advisory_json

  git -C "$PROJECT_DIR" restore tests/bats/fixtures/data.txt
  printf 'untracked\n' > "$PROJECT_DIR/tests/bats/fixtures/new.txt"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  assert_advisory_json

  rm "$PROJECT_DIR/tests/bats/fixtures/new.txt"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/bats-was-invoked" ]
}

assert_bats_advisory_ignores_legacy_state() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  install_bats_execution_sentinel "$stub_dir"
  init_hook_repo "tests/bats/dummy.bats" '@test "noop" { true; }'

  local nag_file target kind
  nag_file="$(legacy_reminder_file)"
  target="$BATS_TEST_TMPDIR/legacy-target"
  mkdir -p "$(dirname "$nag_file")"
  printf 'NONSECRET_MARKER\n' > "$target"

  for kind in numeric malformed symlink directory unreadable; do
    case "$kind" in
      numeric) printf '3\n' > "$nag_file" ;;
      malformed) printf 'NONSECRET_MARKER\n' > "$nag_file" ;;
      symlink) ln -s "$target" "$nag_file" ;;
      directory) mkdir "$nag_file"; cp "$target" "$nag_file/keep" ;;
      unreadable) cp "$target" "$nag_file"; chmod 000 "$nag_file" ;;
    esac
    PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
    assert_advisory_json
    [ -z "$stderr" ]
    case "$kind" in
      numeric) [ "$(cat "$nag_file")" = 3 ]; rm "$nag_file" ;;
      malformed) cmp "$target" "$nag_file"; rm "$nag_file" ;;
      symlink)
        [ -L "$nag_file" ]
        [ "$(readlink "$nag_file")" = "$target" ]
        [ "$(cat "$target")" = NONSECRET_MARKER ]
        rm "$nag_file"
        ;;
      directory)
        cmp "$target" "$nag_file/keep"
        [ "$(ls -A "$nag_file")" = keep ]
        rm "$nag_file/keep"; rmdir "$nag_file"
        ;;
      unreadable)
        # A mode change would be visible to find even when tests run as root.
        [ "$(find "$nag_file" -perm 000 -print)" = "$nag_file" ]
        chmod 600 "$nag_file"
        cmp "$target" "$nag_file"
        ;;
    esac
  done

  # The clean-tree early return must not clean up the obsolete counter either.
  git -C "$PROJECT_DIR" -c user.email=t@t -c user.name=t commit -qm baseline
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  cmp "$target" "$nag_file"
}

assert_bats_advisory_needs_no_writable_state_home() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  install_bats_execution_sentinel "$stub_dir"
  init_hook_repo "tests/bats/dummy.bats" '@test "noop" { true; }'
  # A regular file at the state-home path prevents creation even as root.
  printf 'keep\n' > "$XDG_STATE_HOME"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  assert_advisory_json
  [[ "$stderr" != *"cannot persist"* ]]
  [ "$(cat "$XDG_STATE_HOME")" = keep ]
}

assert_bats_advisory_preserves_executing_gate_budget() {
  local gate="$1"
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  install_bats_execution_sentinel "$stub_dir"
  cat > "$stub_dir/$gate" <<STUB
#!/usr/bin/env bash
touch '$BATS_TEST_TMPDIR/gate-invoked'
echo 'fixture check failure'
exit 1
STUB
  chmod +x "$stub_dir/$gate"
  init_hook_repo "tests/bats/dummy.bats" '@test "noop" { true; }'

  local attempt state_file
  state_file="$(hook_state_file)"
  for attempt in 1 2 3 4 5; do
    PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
    assert_advisory_json
    [ ! -e "$state_file" ]
  done
  case "$gate" in
    shellcheck) printf '# shellcheck shell=bash\n' > "$PROJECT_DIR/tests/bats/utils.bash" ;;
    fish) printf 'function broken\n' > "$PROJECT_DIR/broken.fish" ;;
  esac
  for attempt in 1 2 3; do
    PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"$gate"* ]]
    [[ "$stderr" == *"fixture check failure"* ]]
    [[ "$stderr" == *"blocked stop ($attempt/3)"* ]]
    [ "$(cat "$state_file")" = "$attempt" ]
    [ ! -e "$(legacy_reminder_file)" ]
  done
  rm "$BATS_TEST_TMPDIR/gate-invoked"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"blocked 3 times consecutively, allowing stop"* ]]
  [ ! -e "$state_file" ]
  [ ! -e "$BATS_TEST_TMPDIR/gate-invoked" ]
  [ ! -e "$BATS_TEST_TMPDIR/bats-was-invoked" ]
}

assert_executing_counter_failure_takes_precedence_over_advisory() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  install_bats_execution_sentinel "$stub_dir"
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
echo 'fixture check failure'
exit 1
STUB
  chmod +x "$stub_dir/shellcheck"
  init_hook_repo "tests/bats/utils.bash" '# shellcheck shell=bash'

  local state_file
  state_file="$(hook_state_file)"
  mkdir -p "$state_file"

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -d "$state_file" ]
  [ ! -e "$(legacy_reminder_file)" ]
  [[ "$stderr" == *"cannot persist loop-guard state"* ]]
  [[ "$stderr" == *"verification failures were not enforced"* ]]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"fixture check failure"* ]]
  [[ "$stderr" != *"blocked stop"* ]]
}

assert_git_untracked_enumeration_failure_blocks_before_advisory() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin" real_git
  real_git=$(type -P git)
  install_bats_execution_sentinel "$stub_dir"
  init_hook_repo "tests/bats/dummy.bats" '@test "noop" { true; }'
  cat > "$stub_dir/git" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = ls-files ]; then
  echo 'fixture enumeration failure' >&2
  exit 42
fi
exec '$real_git' "\$@"
STUB
  chmod +x "$stub_dir/git"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"git enumeration failed"* ]]
  [[ "$stderr" == *"fixture enumeration failure"* ]]
  [ ! -e "$XDG_STATE_HOME" ]
}
