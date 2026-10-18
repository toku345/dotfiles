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

assert_bats_reminder_does_not_consume_the_executing_gates_block_budget() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/bats"

  init_hook_repo "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  local state_file nag_file
  state_file="$(hook_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 2 ]
  # The reminder advanced only its own counter; the executing gates' budget is
  # untouched, so a shellcheck failure later still gets its full 3 blocks.
  [ ! -e "$state_file" ]
  [ -f "$nag_file" ]
  [ "$(cat "$nag_file")" = "1" ]
}

assert_bats_reminder_and_executing_gate_persist_independent_counters() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/bats" "$stub_dir/shellcheck"

  init_hook_repo "tests/bats/utils.bash" \
'some_unused_var=42
'

  local state_file nag_file
  state_file="$(hook_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "1" ]
  [ "$(cat "$nag_file")" = "1" ]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"bats gate requires a gated run"* ]]
}

assert_bats_reminder_persistence_failure_does_not_release_an_executing_gate() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/bats" "$stub_dir/shellcheck"
  install_bats_reminder_mv_failure_stub "$stub_dir"

  init_hook_repo "tests/bats/utils.bash" \
'some_unused_var=42
'

  local state_file nag_file
  state_file="$(hook_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "1" ]
  [ ! -e "$nag_file" ]
  [[ "$stderr" == *"cannot persist bats reminder state"* ]]
  [[ "$stderr" == *"reminder not enforced"* ]]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"blocked stop (1/3)"* ]]
  [[ "$stderr" != *"allowing stop to avoid an unbounded reminder loop"* ]]
}

assert_bats_reminder_persistence_failure_alone_fails_open() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/bats"
  install_bats_reminder_mv_failure_stub "$stub_dir"

  init_hook_repo "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  local state_file nag_file
  state_file="$(hook_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ ! -e "$state_file" ]
  [ ! -e "$nag_file" ]
  [[ "$stderr" == *"cannot persist bats reminder state"* ]]
  [[ "$stderr" == *"reminder not enforced"* ]]
  [[ "$stderr" == *"allowing stop to avoid an unbounded reminder loop"* ]]
  [[ "$stderr" != *"blocked stop"* ]]
}

assert_directory_at_bats_reminder_counter_path_fails_open_instead_of_looping() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/bats"

  init_hook_repo "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  local state_file nag_file
  state_file="$(hook_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"
  mkdir -p "$nag_file"

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ -d "$nag_file" ]
  [[ "$stderr" == *"cannot persist bats reminder state"* ]]
  [[ "$stderr" == *"reminder not enforced"* ]]
  [[ "$stderr" == *"allowing stop to avoid an unbounded reminder loop"* ]]
  [[ "$stderr" != *"blocked stop"* ]]
}

assert_executing_counter_directory_failure_also_reports_pending_bats_reminder() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/bats" "$stub_dir/shellcheck"

  init_hook_repo "tests/bats/utils.bash" \
'some_unused_var=42
'

  local state_file nag_file
  state_file="$(hook_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"
  mkdir -p "$state_file"

  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ -d "$state_file" ]
  [ ! -e "$nag_file" ]
  [[ "$stderr" == *"cannot persist loop-guard state"* ]]
  [[ "$stderr" == *"verification failures were not enforced"* ]]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"pending bats reminder was not enforced"* ]]
  [[ "$stderr" == *"bats gate requires a gated run"* ]]
  [[ "$stderr" != *"blocked stop"* ]]
}

assert_bats_reminder_stops_blocking_at_max_blocks_but_keeps_its_diagnostic() {
  local stub_dir="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/bats" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$stub_dir/shellcheck" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_dir/bats" "$stub_dir/shellcheck"

  init_hook_repo "tests/bats/dummy.bats" \
'@test "noop" { true; }
'

  local state_file nag_file
  state_file="$(hook_state_file)"
  nag_file="${state_file/stop-hook-block-count./stop-hook-bats-reminder-count.}"

  local expected
  for expected in 1 2 3; do
    PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
    [ "$status" -eq 2 ]
    [ "$(cat "$nag_file")" = "$expected" ]
    [[ "$stderr" == *"bats gate requires a gated run"* ]]
  done

  # At MAX_BLOCKS the sentinel remains, the instruction is not repeated, and
  # the non-blocking diagnostic stays visible on later stops.
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ "$(cat "$nag_file")" = "3" ]
  [[ "$stderr" == *"bats reminder issued 3 times consecutively"* ]]
  [[ "$stderr" != *"bats gate requires a gated run"* ]]
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ "$(cat "$nag_file")" = "3" ]
  [[ "$stderr" == *"bats reminder issued 3 times consecutively"* ]]
  [[ "$stderr" != *"bats gate requires a gated run"* ]]

  # A saturated reminder must not suppress a newly failing executing gate.
  printf 'some_unused_var=42\n' > "$PROJECT_DIR/tests/bats/utils.bash"
  git -C "$PROJECT_DIR" add tests/bats/utils.bash
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 2 ]
  [ "$(cat "$state_file")" = "1" ]
  [ "$(cat "$nag_file")" = "3" ]
  [[ "$stderr" == *"shellcheck failed"* ]]
  [[ "$stderr" == *"blocked stop (1/3)"* ]]
  [[ "$stderr" != *"bats gate requires a gated run"* ]]

  # Once tests/bats/ is clean again the sentinel is cleared, so a later change
  # gets a fresh budget rather than being silenced forever.
  git -C "$PROJECT_DIR" rm -q --cached \
    "tests/bats/dummy.bats" "tests/bats/utils.bash"
  rm -f "$PROJECT_DIR/tests/bats/dummy.bats" \
    "$PROJECT_DIR/tests/bats/utils.bash"
  PATH="$stub_dir:$PATH" run_stop_hook <<<'{}'
  [ "$status" -eq 0 ]
  [ ! -e "$state_file" ]
  [ ! -e "$nag_file" ]
}

install_bats_reminder_mv_failure_stub() {
  local stub_dir="$1"
  local real_mv
  real_mv=$(type -P mv)
  [ -n "$real_mv" ] || return 1

  cat > "$stub_dir/mv" <<STUB
#!/usr/bin/env bash
case "\${2:-}" in
  *stop-hook-bats-reminder-count.*) exit 1 ;;
esac
exec '$real_mv' "\$@"
STUB
  chmod +x "$stub_dir/mv"
}
