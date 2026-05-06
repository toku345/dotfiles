#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0
load test_helper_triple_review

setup() {
  standard_env_triple_review
}

# =============================================================================
# Tier 1-A: resolve_base fail-closed matrix
# =============================================================================

@test "T1-1 resolve_base: PR exists -> prints baseRefName" {
  export FAKE_GH_BASE=develop
  run --separate-stderr bash -c "source '$SRC_SCRIPT'; resolve_base"
  [ "$status" -eq 0 ]
  [ "$output" = "develop" ]
}

@test "T1-2 resolve_base: no-PR + origin/HEAD set -> origin/HEAD with warning" {
  export FAKE_GH_RC=1
  export FAKE_GH_STDERR="no pull requests found for branch"
  # Configure origin/HEAD via symbolic-ref (doesn't require an actual remote)
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run --separate-stderr bash -c "source '$SRC_SCRIPT'; resolve_base"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [[ "$stderr" == *"No PR found for current branch"* ]]
}

@test "T1-3 resolve_base: gh auth error -> fail-closed abort" {
  export FAKE_GH_RC=4
  export FAKE_GH_STDERR="HTTP 401: authentication required"
  run --separate-stderr bash -c "source '$SRC_SCRIPT'; resolve_base"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refusing to fall back"* ]]
  [[ "$stderr" == *"401"* ]]
}

@test "T1-4 resolve_base: gh rate limit -> fail-closed abort" {
  export FAKE_GH_RC=1
  export FAKE_GH_STDERR="API rate limit exceeded"
  run --separate-stderr bash -c "source '$SRC_SCRIPT'; resolve_base"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refusing to fall back"* ]]
}

@test "T1-5 resolve_base: no-PR + no origin/HEAD -> abort with diagnostic" {
  export FAKE_GH_RC=1
  export FAKE_GH_STDERR="no pull requests found"
  # Do NOT set refs/remotes/origin/HEAD
  run --separate-stderr bash -c "source '$SRC_SCRIPT'; resolve_base"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Base branch resolution failed"* ]]
}

# =============================================================================
# Tier 1-B: collect_descendants recursive enumeration
# =============================================================================

@test "T1-6 collect_descendants: non-existent parent -> empty output" {
  run bash -c "source '$SRC_SCRIPT'; collect_descendants 999999"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T1-7 collect_descendants: 2-level tree -> direct child only" {
  skip_if_pgrep_unavailable
  # Spawn 1 child (sleep) under a parent bash; spawned bash writes the
  # sleep PID to child.pid before calling wait, so the file's presence
  # is a positive readiness signal independent of scheduler timing.
  bash -c 'sleep 30 & echo "$!" > "$1"; wait' bash "$SCRATCH_DIR/child.pid" &
  local top=$!
  # Poll for readiness (max ~3s) instead of a fixed sleep to reduce
  # flakiness under CI contention.
  local i
  for ((i=0; i<30; i++)); do
    [ -s "$SCRATCH_DIR/child.pid" ] && break
    sleep 0.1
  done
  [ -s "$SCRATCH_DIR/child.pid" ]

  run bash -c "source '$SRC_SCRIPT'; collect_descendants $top"
  [ "$status" -eq 0 ]
  # Output should contain exactly one PID (the sleep child)
  local count
  count=$(printf '%s\n' "$output" | grep -c '^[0-9]\+$' || true)
  [ "$count" -eq 1 ]

  # Cleanup
  kill "$top" 2>/dev/null || true
  wait "$top" 2>/dev/null || true
}

@test "T1-8 collect_descendants: 3-level tree -> child + grandchild" {
  skip_if_pgrep_unavailable
  # Spawn bash -> bash -> sleep
  bash -c 'bash -c "sleep 30 & wait" & wait' &
  local top=$!
  # Poll until the grandchild is visible (pgrep -P <child> returns a PID).
  # Max ~3s — sufficient even on busy CI runners.
  local i child
  for ((i=0; i<30; i++)); do
    child=$(pgrep -P "$top" 2>/dev/null | head -n1 || true)
    if [ -n "$child" ] && pgrep -P "$child" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  [ -n "$child" ]

  run bash -c "source '$SRC_SCRIPT'; collect_descendants $top"
  [ "$status" -eq 0 ]
  # Expect 2 descendants: the intermediate bash + the sleep grandchild
  local count
  count=$(printf '%s\n' "$output" | grep -c '^[0-9]\+$' || true)
  [ "$count" -ge 2 ]

  # Cleanup
  kill "$top" 2>/dev/null || true
  pkill -P "$top" 2>/dev/null || true
  wait "$top" 2>/dev/null || true
}

# =============================================================================
# Tier 1-C: kill_children full-tree extermination
# =============================================================================

@test "T1-9 kill_children: empty CHILDREN -> no-op rc=0" {
  run bash -c "source '$SRC_SCRIPT'; CHILDREN=(); MONITOR_PID=''; kill_children"
  [ "$status" -eq 0 ]
}

@test "T1-10 kill_children: 3 parallel 3-level trees -> all 9 PIDs killed" {
  skip_if_pgrep_unavailable
  # Spawn via a dedicated helper so PIDs land in a known file
  local pid_file="$SCRATCH_DIR/parents.txt"
  : > "$pid_file"
  local i
  for i in 1 2 3; do
    bash -c 'bash -c "sleep 60 & wait" & wait' &
    printf '%s\n' "$!" >> "$pid_file"
  done

  # Poll until all 3 trees have fully spawned (3 children + 3 grandchildren
  # = 6 descendants visible), max ~3s. Avoids flakiness vs. a fixed sleep.
  local desc_count p c
  for ((i=0; i<30; i++)); do
    desc_count=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      for c in $(pgrep -P "$p" 2>/dev/null || true); do
        desc_count=$((desc_count + 1))
        # grandchildren count too (we don't need their PIDs yet here)
        local gc_list
        gc_list=$(pgrep -P "$c" 2>/dev/null || true)
        if [ -n "$gc_list" ]; then
          local gc
          for gc in $gc_list; do
            desc_count=$((desc_count + 1))
          done
        fi
      done
    done < "$pid_file"
    [ "$desc_count" -ge 6 ] && break
    sleep 0.1
  done

  # Snapshot the full tree (parents + descendants) before kill
  local all_pids=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    all_pids+=("$p")
    # Collect all descendants (parent->child->grandchild)
    for c in $(pgrep -P "$p" 2>/dev/null || true); do
      all_pids+=("$c")
      for gc in $(pgrep -P "$c" 2>/dev/null || true); do
        all_pids+=("$gc")
      done
    done
  done < "$pid_file"

  # Sanity: expect at least 9 PIDs (3 parents + 3 children + 3 grandchildren)
  [ "${#all_pids[@]}" -ge 9 ]

  # Invoke kill_children with the 3 parents in CHILDREN
  local parents
  parents=$(paste -sd' ' "$pid_file")
  run bash -c "source '$SRC_SCRIPT'; CHILDREN=($parents); MONITOR_PID=''; kill_children"
  [ "$status" -eq 0 ]

  # Poll for reap completion (max ~2s) instead of a fixed post-kill sleep.
  local pid alive_count
  for ((i=0; i<20; i++)); do
    alive_count=0
    for pid in "${all_pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive_count=$((alive_count + 1))
    done
    [ "$alive_count" -eq 0 ] && break
    sleep 0.1
  done

  # Verify all snapshotted PIDs are dead
  local alive=()
  for pid in "${all_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      alive+=("$pid")
    fi
  done
  [ "${#alive[@]}" -eq 0 ]
}

# =============================================================================
# Tier 2-A: is_error_token_only
# =============================================================================

@test "T2-1 is_error_token_only: 'Execution error' (1 line) -> true" {
  local f="$SCRATCH_DIR/banner.md"
  printf 'Execution error: session interrupted\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; is_error_token_only '$f'"
  [ "$status" -eq 0 ]
}

@test "T2-2 is_error_token_only: 'API Error: 429' (1 line) -> true" {
  local f="$SCRATCH_DIR/banner.md"
  printf 'API Error: 429 Too Many Requests\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; is_error_token_only '$f'"
  [ "$status" -eq 0 ]
}

@test "T2-3 is_error_token_only: long review (>3 lines) -> false" {
  local f="$SCRATCH_DIR/long.md"
  printf '# Findings\nline1\nline2\nline3\nline4\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; is_error_token_only '$f'"
  [ "$status" -eq 1 ]
}

@test "T2-4 is_error_token_only: short non-banner heading -> false" {
  local f="$SCRATCH_DIR/short.md"
  printf '# Findings\nnothing serious\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; is_error_token_only '$f'"
  [ "$status" -eq 1 ]
}

@test "T2-5 is_error_token_only: empty file -> false" {
  local f="$SCRATCH_DIR/empty.md"
  : > "$f"
  run bash -c "source '$SRC_SCRIPT'; is_error_token_only '$f'"
  [ "$status" -eq 1 ]
}

# =============================================================================
# Tier 2-B: inject_failed_marker
# =============================================================================

@test "T2-6 inject_failed_marker: appends FAILED block to non-empty file" {
  local f="$SCRATCH_DIR/existing.md"
  printf 'prior content\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; inject_failed_marker PR '$f' 1"
  [ "$status" -eq 0 ]
  grep -q '^prior content$' "$f"
  grep -q '<FAILED reviewer=PR exit_code=1>' "$f"
  grep -q '</FAILED>' "$f"
}

@test "T2-7 inject_failed_marker: appends FAILED block to empty file" {
  local f="$SCRATCH_DIR/empty.md"
  : > "$f"
  run bash -c "source '$SRC_SCRIPT'; inject_failed_marker SEC '$f' empty-output"
  [ "$status" -eq 0 ]
  grep -q '<FAILED reviewer=SEC exit_code=empty-output>' "$f"
}

# =============================================================================
# Tier 2-C: check_reviewer_result
# =============================================================================

@test "T2-8 check_reviewer_result: rc!=0 -> fail, marker injected" {
  local f="$SCRATCH_DIR/r.md"
  printf 'partial output\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; check_reviewer_result PR 2 '$f'"
  [ "$status" -eq 1 ]
  grep -q '<FAILED reviewer=PR exit_code=2>' "$f"
}

@test "T2-9 check_reviewer_result: rc=0 + empty file -> fail(empty-output)" {
  local f="$SCRATCH_DIR/r.md"
  : > "$f"
  run bash -c "source '$SRC_SCRIPT'; check_reviewer_result SEC 0 '$f'"
  [ "$status" -eq 1 ]
  grep -q '<FAILED reviewer=SEC exit_code=empty-output>' "$f"
}

@test "T2-10 check_reviewer_result: rc=0 + error-token file -> fail(error-token)" {
  local f="$SCRATCH_DIR/r.md"
  printf 'Execution error: something\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; check_reviewer_result ADV 0 '$f'"
  [ "$status" -eq 1 ]
  grep -q '<FAILED reviewer=ADV exit_code=error-token>' "$f"
}

@test "T2-11 check_reviewer_result: rc=0 + valid content -> pass, no marker" {
  local f="$SCRATCH_DIR/r.md"
  printf '# Findings\nline1\nline2\nline3\nline4\n' > "$f"
  run bash -c "source '$SRC_SCRIPT'; check_reviewer_result PR 0 '$f'"
  [ "$status" -eq 0 ]
  ! grep -q '<FAILED' "$f"
}

# =============================================================================
# Tier 2-D: remove_pid
# =============================================================================

@test "T2-12 remove_pid: empty CHILDREN + missing target -> still empty" {
  run bash -c "source '$SRC_SCRIPT'; CHILDREN=(); remove_pid 999; printf '%s' \"\${#CHILDREN[@]}\""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "T2-13 remove_pid: removes target from middle of array" {
  run bash -c "source '$SRC_SCRIPT'; CHILDREN=(100 200 300); remove_pid 200; printf '%s\n' \"\${CHILDREN[@]}\""
  [ "$status" -eq 0 ]
  [ "$output" = "100"$'\n'"300" ]
}

@test "T2-14 remove_pid: removing last element -> empty CHILDREN" {
  run bash -c "source '$SRC_SCRIPT'; CHILDREN=(100); remove_pid 100; printf '%s' \"\${#CHILDREN[@]}\""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# =============================================================================
# Tier 2-E: build_aggregation_prompt
# =============================================================================

@test "T2-15 build_aggregation_prompt: includes unique delimiter and content" {
  local a="$SCRATCH_DIR/pr.md" b="$SCRATCH_DIR/sec.md" c="$SCRATCH_DIR/adv.md"
  printf 'PR finding alpha\n' > "$a"
  printf 'SEC finding beta\n' > "$b"
  printf 'ADV finding gamma\n' > "$c"
  run bash -c "source '$SRC_SCRIPT'; build_aggregation_prompt '$a' '$b' '$c'"
  [ "$status" -eq 0 ]
  # Boundary marker with TRIPLEREV prefix appears
  [[ "$output" == *"===BEGIN_TRIPLEREV_"* ]]
  [[ "$output" == *"===END_TRIPLEREV_"* ]]
  # Reviewer content interpolated verbatim
  [[ "$output" == *"PR finding alpha"* ]]
  [[ "$output" == *"SEC finding beta"* ]]
  [[ "$output" == *"ADV finding gamma"* ]]
  # Instructions section is present
  [[ "$output" == *"対応必須"* ]]
  [[ "$output" == *"要検討"* ]]
}

@test "T2-16 build_aggregation_prompt: BSD date %N fallback -> pid+hex delimiter" {
  local stub_dir="$SCRATCH_DIR/date_stub"
  mkdir -p "$stub_dir"
  # Use /bin/date absolute path to avoid infinite recursion: `command date`
  # still honors PATH for external commands and would find this stub again.
  cat > "$stub_dir/date" <<'STUB'
#!/usr/bin/env bash
# Emulate BSD date: %N not expanded -> returns literal "<epoch>N"
if [ "$1" = "+%s%N" ]; then
  printf '%sN\n' "$(/bin/date +%s)"
else
  exec /bin/date "$@"
fi
STUB
  chmod +x "$stub_dir/date"
  local a="$SCRATCH_DIR/a" b="$SCRATCH_DIR/b" c="$SCRATCH_DIR/c"
  printf 'x\n' > "$a"; printf 'y\n' > "$b"; printf 'z\n' > "$c"
  PATH="$stub_dir:$PATH" run bash -c "source '$SRC_SCRIPT'; build_aggregation_prompt '$a' '$b' '$c'"
  [ "$status" -eq 0 ]
  # Fallback delimiter: TRIPLEREV_<epoch>_<pid>_<16hex>
  [[ "$output" =~ TRIPLEREV_[0-9]+_[0-9]+_[0-9a-f]{16} ]]
}

@test "T2-17 build_aggregation_prompt: <FAILED> marker preserved in prompt" {
  local a="$SCRATCH_DIR/pr.md" b="$SCRATCH_DIR/sec.md" c="$SCRATCH_DIR/adv.md"
  printf 'partial output\n<FAILED reviewer=PR exit_code=1>\nfoo\n</FAILED>\n' > "$a"
  printf 'SEC content\n' > "$b"
  printf 'ADV content\n' > "$c"
  run bash -c "source '$SRC_SCRIPT'; build_aggregation_prompt '$a' '$b' '$c'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<FAILED reviewer=PR exit_code=1>"* ]]
  [[ "$output" == *"欠損として扱い"* ]]
}

# =============================================================================
# Tier 2-F: make_workdir
# =============================================================================

@test "T2-18 make_workdir: TMPDIR with trailing slash -> no double-slash" {
  local base="$SCRATCH_DIR/tmpbase/"
  mkdir -p "$base"
  run bash -c "TMPDIR='$base' bash -c 'source \"$SRC_SCRIPT\"; make_workdir'"
  [ "$status" -eq 0 ]
  # Path should not contain `//`
  [[ "$output" != *"//"* ]]
  [ -d "$output" ]
  [[ "$output" == *"/triple-review-"* ]]
}

@test "T2-19 make_workdir: unset TMPDIR -> falls back to /tmp" {
  run bash -c "unset TMPDIR; source '$SRC_SCRIPT'; make_workdir"
  [ "$status" -eq 0 ]
  [[ "$output" == /tmp/triple-review-* ]]
  [ -d "$output" ]
  # Cleanup — this landed in real /tmp, not BATS_TEST_TMPDIR
  rmdir "$output"
}

# =============================================================================
# Tier 2-G: CLI argument guard (PATH-invoked, short-circuit paths only)
# =============================================================================

@test "T2-20 triple-review foo -> rc=1, 'Unknown argument'" {
  run triple-review foo
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown argument: foo"* ]]
}

@test "T2-21 triple-review -h -> rc=0, usage" {
  run triple-review -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: triple-review"* ]]
}

@test "T2-22 triple-review --help -> rc=0, usage" {
  run triple-review --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: triple-review"* ]]
}

# =============================================================================
# Tier 2-H: sleep inhibitor selection (select_sleep_inhibitor_cmd + maybe_wrap)
# Function override pattern is used instead of PATH-based stubs because real
# macOS always has /usr/bin/caffeinate and real Ubuntu always has
# /usr/bin/systemd-inhibit; stripping /usr/bin from PATH to fake "command
# absent" would also strip uname/printf/head/grep and break the script
# itself. Overriding has_caffeinate / has_systemd_inhibit / systemd_is_pid1 at
# the function level sidesteps that problem.
# =============================================================================

@test "T2-23 select_sleep_inhibitor: Darwin + caffeinate present -> 'caffeinate -i -s'" {
  export TEST_FAKE_UNAME=Darwin
  run bash -c "source '$SRC_SCRIPT'; has_caffeinate() { return 0; }; select_sleep_inhibitor_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = $'caffeinate\n-i\n-s' ]
}

@test "T2-24 select_sleep_inhibitor: Darwin + caffeinate absent -> empty" {
  export TEST_FAKE_UNAME=Darwin
  run bash -c "source '$SRC_SCRIPT'; has_caffeinate() { return 1; }; select_sleep_inhibitor_cmd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T2-25 select_sleep_inhibitor: Linux + all prereqs satisfied -> 4 tokens" {
  # Override all three guards so the test does not depend on the host's
  # systemd/dbus state (real CI Ubuntu containers have no logind).
  # --mode=block is spelled out so the production wrap argv is literally
  # aligned with the acquisition probe's argv (probe-vs-wrap drift guard).
  export TEST_FAKE_UNAME=Linux
  run bash -c "source '$SRC_SCRIPT'; has_systemd_inhibit() { return 0; }; systemd_is_pid1() { return 0; }; systemd_inhibitor_reachable() { return 0; }; select_sleep_inhibitor_cmd"
  [ "$status" -eq 0 ]
  [ "$output" = $'systemd-inhibit\n--what=idle:sleep\n--mode=block\n--why=triple-review in progress' ]
}

@test "T2-26 select_sleep_inhibitor: Linux + systemd-inhibit present + systemd not PID 1 -> empty" {
  export TEST_FAKE_UNAME=Linux
  run bash -c "source '$SRC_SCRIPT'; has_systemd_inhibit() { return 0; }; systemd_is_pid1() { return 1; }; select_sleep_inhibitor_cmd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T2-27 select_sleep_inhibitor: Linux + systemd-inhibit absent -> empty" {
  export TEST_FAKE_UNAME=Linux
  run bash -c "source '$SRC_SCRIPT'; has_systemd_inhibit() { return 1; }; systemd_is_pid1() { return 0; }; select_sleep_inhibitor_cmd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T2-28 select_sleep_inhibitor: unknown OS (FreeBSD) -> empty" {
  export TEST_FAKE_UNAME=FreeBSD
  run bash -c "source '$SRC_SCRIPT'; select_sleep_inhibitor_cmd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T2-29 maybe_wrap: TRIPLE_REVIEW_SLEEP_INHIBITED set -> no-op return, no exec" {
  export TRIPLE_REVIEW_SLEEP_INHIBITED=1
  run bash -c "source '$SRC_SCRIPT'; maybe_wrap_with_inhibitor; echo REACHED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED"* ]]
}

# =============================================================================
# Tier 2-I: maybe_wrap exec fallback + success path + call-site integration.
# Regression guard for the `set -Eeuo pipefail` + `exec ... || fallback`
# dead-code bug: without `set +e` around exec, a failing exec under set -e
# exits the shell before the `||` branch can fire, leaving the warn banner
# unreachable and TRIPLE_REVIEW_SLEEP_INHIBITED stuck to 1 for wrappers.
# =============================================================================

@test "T2-30 maybe_wrap: exec failure -> fallback fires, gate unset, rc=0" {
  # Override select_sleep_inhibitor_cmd to emit a path that does not exist.
  # The `||` fallback must fire: warn banner on stderr, gate unset so the
  # next invocation is free to try again, rc=0 so main() proceeds.
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    select_sleep_inhibitor_cmd() { printf '%s\n' /nonexistent/inhibitor; }
    maybe_wrap_with_inhibitor
    printf 'AFTER_RC=%s\n' \"\$?\"
    printf 'SLEEP_GATE=[%s]\n' \"\${TRIPLE_REVIEW_SLEEP_INHIBITED:-<unset>}\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"AFTER_RC=0"* ]]
  [[ "$output" == *"SLEEP_GATE=[<unset>]"* ]]
  [[ "$stderr" == *"Sleep inhibitor exec failed"* ]]
  [[ "$stderr" == *"/nonexistent/inhibitor"* ]]
}

@test "T2-31 maybe_wrap: exec success -> bash re-entry + argv forwarded, gate=1 exported" {
  # Fake wrapper that records argv + the TRIPLE_REVIEW_SLEEP_INHIBITED value
  # it inherited, then exits 0. After exec, the bats subshell is replaced
  # by this wrapper; inspection happens via the capture file.
  #
  # Contract: the wrapper receives [bash, BASH_SOURCE[0], ...positional args].
  # Going through the bash interpreter decouples the wrap path from file mode
  # — git stores the script as 0644 and execve-ing it directly would bail
  # rc=126 on any source-tree invocation.
  local fake="$SCRATCH_DIR/fake_wrap"
  local capture="$SCRATCH_DIR/wrap_capture"
  cat > "$fake" <<STUB
#!/usr/bin/env bash
{
  printf 'ARGC=%d\n' "\$#"
  for a in "\$@"; do
    printf 'ARG=%s\n' "\$a"
  done
  printf 'SLEEP_GATE=%s\n' "\${TRIPLE_REVIEW_SLEEP_INHIBITED:-<unset>}"
} > '$capture'
exit 0
STUB
  chmod +x "$fake"

  run bash -c "
    source '$SRC_SCRIPT'
    select_sleep_inhibitor_cmd() { printf '%s\n' '$fake'; }
    maybe_wrap_with_inhibitor foo bar baz
  "
  [ "$status" -eq 0 ]
  # argv after exec: [bash, BASH_SOURCE[0]=SRC_SCRIPT, foo, bar, baz] = 5 tokens.
  grep -q '^ARGC=5$' "$capture"
  # First arg is the bash interpreter (absolute or bare).
  grep -qE '^ARG=(bash|/.*/bash)$' "$capture"
  # Second arg is the sourced script path.
  grep -qF "ARG=$SRC_SCRIPT" "$capture"
  grep -q '^ARG=foo$' "$capture"
  grep -q '^ARG=bar$' "$capture"
  grep -q '^ARG=baz$' "$capture"
  # Gate must be exported to 1 BEFORE exec so the re-entered child is a no-op.
  grep -q '^SLEEP_GATE=1$' "$capture"
}

@test "T2-36 argv shape: bash-prefixed re-entry survives 0644 file, \$0-direct fails" {
  # Regression guard for the Phase 4 fix. The source file is 0644 in git
  # (chezmoi sets 0755 only on apply), so a real inhibitor doing
  # `execve("$0")` — as the pre-Phase-4 code shape would produce — bails
  # rc=126 before the review can run. The current `bash "$BASH_SOURCE[0]"`
  # shape lets bash interpret the script without requiring the execute bit.
  #
  # Two assertions pin both directions so a reverter has to explain away
  # a broken test rather than a silent behavior change.

  [ ! -x "$SRC_SCRIPT" ]

  # Positive: what maybe_wrap_with_inhibitor emits today works on 0644.
  run bash -c "exec bash '$SRC_SCRIPT' --help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: triple-review"* ]]

  # Negative: the \$0-direct shape the Phase 4 fix replaced. Pin the rc=126
  # so future refactors can't silently reintroduce the failure mode.
  run bash -c "exec '$SRC_SCRIPT' --help"
  [ "$status" -eq 126 ]
}

@test "T2-32 call-site: --help does not pay wrap cost" {
  # With systemd-inhibit/caffeinate actually available on the host, moving
  # maybe_wrap_with_inhibitor above the arg-validation block would emit the
  # wrap banner for --help. Guard the current ordering.
  run --separate-stderr triple-review --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: triple-review"* ]]
  [[ "$stderr" != *"Wrapping with sleep inhibitor"* ]]
}

@test "T2-33 call-site: unknown-arg exits before wrap" {
  run --separate-stderr triple-review bogus
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Unknown argument: bogus"* ]]
  [[ "$stderr" != *"Wrapping with sleep inhibitor"* ]]
}

# =============================================================================
# Tier 2-J: systemd-inhibit dbus readiness probe.
# Guards against the WSL2 / rootless container / sudo-stripped case where
# systemd-inhibit is installed and /run/systemd/system exists, but the
# session dbus bus logind listens on is unreachable — in which case exec'ing
# the wrapper would replace bash and the child would bail before running
# triple-review, leaving the user with no review.
# =============================================================================

@test "T2-34 select_sleep_inhibitor: Linux + all present but dbus probe fails -> empty" {
  export TEST_FAKE_UNAME=Linux
  run bash -c "
    source '$SRC_SCRIPT'
    has_systemd_inhibit() { return 0; }
    systemd_is_pid1() { return 0; }
    systemd_inhibitor_reachable() { return 1; }
    select_sleep_inhibitor_cmd
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T2-35 systemd_inhibitor_reachable: delegates to systemd-inhibit acquisition probe" {
  # systemd_inhibitor_reachable is invoked only under select_sleep_inhibitor_cmd's case Linux); macOS uses caffeinate (case Darwin)) and never reaches this function in production. Linux CI / Docker parity provides full coverage; macOS skip avoids false failures from missing GNU timeout.
  [[ "$(uname)" == "Linux" ]] || skip "Linux-only: systemd_inhibitor_reachable is gated by select_sleep_inhibitor_cmd's case Linux); macOS production uses caffeinate"
  # PATH stub controls systemd-inhibit's behavior so we exercise the real
  # probe implementation end-to-end rather than just mocking the helper.
  local stub_dir="$SCRATCH_DIR/inhibit_stub"
  mkdir -p "$stub_dir"

  # Success path: acquisition probe (--what=idle:sleep --mode=block /bin/true)
  # exits 0. Other argv shapes exit 2 so a regression that drops the new
  # tokens fails the test instead of silently passing.
  cat > "$stub_dir/systemd-inhibit" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--what=idle:sleep*--mode=block*/bin/true*) exit 0;;
esac
exit 2
STUB
  chmod +x "$stub_dir/systemd-inhibit"
  PATH="$stub_dir:$PATH" run bash -c "source '$SRC_SCRIPT'; systemd_inhibitor_reachable"
  [ "$status" -eq 0 ]

  # Failure path: any invocation exits non-zero, mimicking dbus unavailable.
  cat > "$stub_dir/systemd-inhibit" <<'STUB'
#!/usr/bin/env bash
echo "Failed to connect to bus" >&2
exit 1
STUB
  chmod +x "$stub_dir/systemd-inhibit"
  PATH="$stub_dir:$PATH" run bash -c "source '$SRC_SCRIPT'; systemd_inhibitor_reachable"
  [ "$status" -eq 1 ]
}

@test "T2-37 systemd_inhibitor_reachable: polkit denial detected (regression vs --list-only probe)" {
  [[ "$(uname)" == "Linux" ]] || skip "Linux-only: systemd_inhibitor_reachable is gated by select_sleep_inhibitor_cmd's case Linux); macOS production uses caffeinate"
  # Simulate restrictive polkit policy: --list passes (dbus reachable) but
  # --what=idle:sleep --mode=block fails (acquisition denied by polkit).
  # The old probe used --list and would mistakenly succeed; the new
  # acquisition probe must detect the denial and return non-zero so
  # select_sleep_inhibitor_cmd falls through to wrap-skip.
  local stub_dir="$SCRATCH_DIR/inhibit_stub_polkit"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/systemd-inhibit" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--what=idle:sleep*--mode=block*/bin/true*)
    echo "Failed to inhibit: Access denied" >&2
    exit 1
    ;;
  *--list*)
    exit 0
    ;;
esac
exit 2
STUB
  chmod +x "$stub_dir/systemd-inhibit"
  PATH="$stub_dir:$PATH" run bash -c "source '$SRC_SCRIPT'; systemd_inhibitor_reachable"
  [ "$status" -eq 1 ]
}

@test "T2-38 systemd_inhibitor_reachable: invokes acquisition probe with expected argv" {
  [[ "$(uname)" == "Linux" ]] || skip "Linux-only: systemd_inhibitor_reachable is gated by select_sleep_inhibitor_cmd's case Linux); macOS production uses caffeinate"
  # Witness records argv so we can verify the probe asks for the same lock
  # the production wrap takes (--what=idle:sleep --mode=block /bin/true).
  # Three quoting layers cooperate to keep $witness from being expanded at
  # the wrong time:
  #   - heredoc is unquoted (`<<STUB`), so $witness expands at heredoc-emit
  #     time to the test-side path.
  #   - \$@ / \$* are escaped, so they survive heredoc expansion and remain
  #     bash-runtime references inside the stub.
  #   - the emitted '$witness' is single-quoted within the stub source, so
  #     stub-runtime never re-expands it (defense against literal $ chars in
  #     SCRATCH_DIR; the single quotes also block any future editor that
  #     drops the heredoc-time expansion in favor of stub-time expansion).
  local stub_dir="$SCRATCH_DIR/inhibit_stub_argv"
  local witness="$SCRATCH_DIR/inhibit_argv"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/systemd-inhibit" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > '$witness'
case "\$*" in
  *--what=idle:sleep*--mode=block*/bin/true*) exit 0;;
esac
exit 3
STUB
  chmod +x "$stub_dir/systemd-inhibit"
  PATH="$stub_dir:$PATH" run bash -c "source '$SRC_SCRIPT'; systemd_inhibitor_reachable"
  [ "$status" -eq 0 ]
  grep -qx -- '--what=idle:sleep' "$witness"
  grep -qx -- '--mode=block' "$witness"
  grep -qx -- '/bin/true' "$witness"

  # Drift guard: T2-25 fixes the production wrap argv and T2-38 (above)
  # fixes the probe witness, but both are independent literals. A
  # synchronized rename (e.g. --mode=block -> --mode=delay in both call
  # sites at once) would slip past both tests. Assert the lock-defining
  # tokens appear in the production wrap output as well, so probe and
  # wrap cannot drift apart silently.
  export TEST_FAKE_UNAME=Linux
  local wrap_output
  wrap_output=$(bash -c "source '$SRC_SCRIPT'; has_systemd_inhibit() { return 0; }; systemd_is_pid1() { return 0; }; systemd_inhibitor_reachable() { return 0; }; select_sleep_inhibitor_cmd")
  echo "$wrap_output" | grep -qFx -- '--what=idle:sleep'
  echo "$wrap_output" | grep -qFx -- '--mode=block'
}

@test "T2-39 systemd_inhibitor_reachable: hanging systemd-inhibit -> bounded by timeout(1)" {
  [[ "$(uname)" == "Linux" ]] || skip "Linux-only: systemd_inhibitor_reachable is gated by select_sleep_inhibitor_cmd's case Linux); macOS production uses caffeinate"
  # Codex adversarial review surfaced this gap: a degraded logind/polkit
  # path that waits indefinitely instead of returning immediately would
  # hang the probe without an explicit timeout, blocking startup before
  # the wrap-skip fallback can fire. TRIPLE_REVIEW_PROBE_TIMEOUT lets the
  # test compress the 5s production budget so CI doesn't pay it.
  local stub_dir="$SCRATCH_DIR/inhibit_stub_hang"
  mkdir -p "$stub_dir"
  # `exec /bin/sleep 30` replaces the stub bash with sleep itself so
  # `timeout(1)` SIGTERMs the sleeper directly. Without `exec`, bash's
  # default signal disposition leaves the forked sleep as an orphan that
  # outlives the test by ~30s.
  cat > "$stub_dir/systemd-inhibit" <<'STUB'
#!/usr/bin/env bash
exec /bin/sleep 30
STUB
  chmod +x "$stub_dir/systemd-inhibit"
  local before=$SECONDS
  PATH="$stub_dir:$PATH" TRIPLE_REVIEW_PROBE_TIMEOUT=1 \
    run bash -c "source '$SRC_SCRIPT'; systemd_inhibitor_reachable"
  local elapsed=$((SECONDS - before))
  # Assert specifically on GNU timeout's documented timeout exit (124)
  # instead of `-ne 0`. The looser check would also be satisfied by 127
  # (command-not-found, e.g. host missing GNU timeout), masking a regression
  # where the production wrap stops invoking timeout(1) at all.
  [ "$status" -eq 124 ]
  # Wide ceiling tolerates CI scheduler jitter while still failing loud
  # if the timeout wrap is removed (sleep 30 would otherwise stall here).
  [ "$elapsed" -lt 5 ]
}

# =============================================================================
# Tier 3-A: check_prerequisites fail-fast matrix.
# Each required-command path must abort with a clear diagnostic so an
# incomplete environment surfaces before reviewers spawn. Also covers the
# new dynamic codex-companion resolver: 0 installed versions must err out
# at startup instead of failing 30s into the parallel run.
# =============================================================================

@test "T3-1 check_prerequisites: missing gh -> abort" {
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    require_cmd() {
      [ \"\$1\" = 'gh' ] && err 'Required command not found in PATH: gh'
      return 0
    }
    resolve_codex_companion() { printf 'fake'; }
    check_prerequisites
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Required command not found in PATH: gh"* ]]
}

@test "T3-2 check_prerequisites: missing git -> abort" {
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    require_cmd() {
      [ \"\$1\" = 'git' ] && err 'Required command not found in PATH: git'
      return 0
    }
    resolve_codex_companion() { printf 'fake'; }
    check_prerequisites
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Required command not found in PATH: git"* ]]
}

@test "T3-3 check_prerequisites: missing claude -> abort" {
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    require_cmd() {
      [ \"\$1\" = 'claude' ] && err 'Required command not found in PATH: claude'
      return 0
    }
    resolve_codex_companion() { printf 'fake'; }
    check_prerequisites
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Required command not found in PATH: claude"* ]]
}

@test "T3-4 check_prerequisites: missing node -> abort" {
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    require_cmd() {
      [ \"\$1\" = 'node' ] && err 'Required command not found in PATH: node'
      return 0
    }
    resolve_codex_companion() { printf 'fake'; }
    check_prerequisites
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Required command not found in PATH: node"* ]]
}

@test "T3-5 check_prerequisites: companion not found -> abort with ADR pointer" {
  # Empty cache root simulates a fresh install where the codex plugin has
  # not been added yet. The resolver must err with a recognizable hint.
  local empty_cache="$SCRATCH_DIR/empty_cache"
  mkdir -p "$empty_cache"
  run --separate-stderr bash -c "
    export CODEX_COMPANION_CACHE_ROOT='$empty_cache'
    source '$SRC_SCRIPT'
    require_cmd() { return 0; }
    check_prerequisites
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Codex companion script not found"* ]]
  [[ "$stderr" == *"ADR 0012"* ]]
}

# Tier 3-A2: require_output_style_triple_review fail-loud matrix.
#
# These tests guard against the silent fallback in `claude -p --settings '{"outputStyle":"triple-review"}'` when the style file is missing/stale (verified empirically with claude 2.1.126 — silent default-style fallback). chezmoi deploy skew between the script and the output-style is the practical failure mode (ADR 0017 §Negative risk b).

@test "T3-8 require_output_style_triple_review: missing style file -> abort with chezmoi apply hint" {
  local fake_home="$SCRATCH_DIR/fake_home_no_style"
  mkdir -p "$fake_home/.claude/output-styles"
  # Intentionally NOT creating triple-review.md.
  run --separate-stderr bash -c "
    export HOME='$fake_home'
    source '$SRC_SCRIPT'
    require_cmd() { return 0; }
    resolve_codex_companion() { printf 'fake'; }
    check_prerequisites
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Output-style 'triple-review'"* ]]
  [[ "$stderr" == *"chezmoi apply"* ]]
  [[ "$stderr" == *"TRIPLE_REVIEW_OUTPUT_STYLE_V1"* ]]
}

@test "T3-9 require_output_style_triple_review: style file present but sentinel missing -> abort" {
  local fake_home="$SCRATCH_DIR/fake_home_no_sentinel"
  mkdir -p "$fake_home/.claude/output-styles"
  printf '%s\n' '# Some Other Style' 'no sentinel here' \
    > "$fake_home/.claude/output-styles/triple-review.md"
  run --separate-stderr bash -c "
    export HOME='$fake_home'
    source '$SRC_SCRIPT'
    require_cmd() { return 0; }
    resolve_codex_companion() { printf 'fake'; }
    check_prerequisites
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"TRIPLE_REVIEW_OUTPUT_STYLE_V1"* ]]
  [[ "$stderr" == *"chezmoi apply"* ]]
}

@test "T3-10 require_output_style_triple_review: style file with sentinel -> proceeds (rc=0)" {
  local fake_home="$SCRATCH_DIR/fake_home_ok"
  mkdir -p "$fake_home/.claude/output-styles"
  printf '%s\n' '# Triple-Review Headless Style' '<!-- TRIPLE_REVIEW_OUTPUT_STYLE_V1 -->' 'stub style body' \
    > "$fake_home/.claude/output-styles/triple-review.md"
  # All other gates stubbed to pass; setup() already cd'd into a git work tree.
  run --separate-stderr bash -c "
    export HOME='$fake_home'
    source '$SRC_SCRIPT'
    require_cmd() { return 0; }
    resolve_codex_companion() { printf 'fake'; }
    check_prerequisites
  "
  [ "$status" -eq 0 ]
}

# =============================================================================
# Tier 3-B: resolve_codex_companion version selection.
# The dynamic resolver must pick the highest installed version so a leftover
# older copy alongside a newer one does not silently bind us to the older
# CLI contract. Empty-cache case is covered by T3-5 above.
# =============================================================================

@test "T3-6 resolve_codex_companion: multiple versions -> highest selected" {
  local cache="$SCRATCH_DIR/multi_version_cache"
  # Out-of-order on disk to confirm the test exercises sort -V, not directory
  # listing order. 1.0.10 must beat 1.0.4 numerically, not lexicographically.
  for v in 1.0.4 1.0.10 1.0.2; do
    mkdir -p "$cache/$v/scripts"
    : > "$cache/$v/scripts/codex-companion.mjs"
  done
  run --separate-stderr bash -c "
    export CODEX_COMPANION_CACHE_ROOT='$cache'
    source '$SRC_SCRIPT'
    resolve_codex_companion
  "
  [ "$status" -eq 0 ]
  [ "$output" = "$cache/1.0.10/scripts/codex-companion.mjs" ]
}

# =============================================================================
# Tier 3-C: ADV invocation contract snapshot.
# The bypass-claude-p workaround (ADR 0012) hinges on four argv tokens and a
# stdout/stderr split. Pin them as a source-level snapshot so a refactor that
# silently drops `--model gpt-5.4` (reverting the captureTurn-await-forever
# workaround) or merges the streams (re-hiding the diagnostic from M2) fails
# this test instead of regressing in production.
# =============================================================================

@test "T3-7 ADV invocation contract: source contains required argv + redirection" {
  # grep -F -- terminates option parsing so tokens starting with `--` are
  # treated as the search pattern, not as flags.
  grep -F -- 'node "$CODEX_COMPANION" adversarial-review' "$SRC_SCRIPT"
  grep -F -- '--base "$base"' "$SRC_SCRIPT"
  grep -F -- '--scope branch' "$SRC_SCRIPT"
  grep -F -- '--model gpt-5.4' "$SRC_SCRIPT"
  grep -F -- '> "$workdir/adv.md" 2> "$workdir/adv.err"' "$SRC_SCRIPT"
}

# =============================================================================
# Tier 4: codex broker cleanup (issue #162).
# triple-review's bare-CLI ADV reviewer creates an `app-server-broker.mjs`
# that lives past the review and re-parents to PID 1 once triple-review
# `exec`s into the auto-handoff `claude --` session. The auto-handoff
# `SessionEnd` hook then stalls trying to graceful-shutdown the orphan,
# producing `SessionEnd hook ... failed: Hook cancelled`. We close that
# hole with a snapshot/teardown helper that drives the plugin's
# broker-lifecycle.mjs API.
#
# The helper imports broker-lifecycle.mjs and process.mjs from the codex
# plugin cache. To exercise the helper without depending on the real
# plugin (Docker Ubuntu CI lacks it), each test seeds a minimal mock cache
# matching the API surface the helper consumes.
# =============================================================================

# Build a fake codex plugin cache layout with mock library files. The mocks
# implement just enough of broker-lifecycle.mjs / process.mjs for the helper
# to drive snapshot/teardown end-to-end. State is rooted at $1/state, broker
# JSON is at $MOCK_BROKER_STATE_FILE, shutdown calls are appended to
# $MOCK_BROKER_SHUTDOWN_LOG, and kill calls are appended to $MOCK_KILL_LOG.
# The mock layout matches the real plugin (cache_root/<version>/scripts/lib).
seed_mock_codex_cache() {
  local root="$1"
  local lib_dir="$root/1.0.4/scripts/lib"
  mkdir -p "$lib_dir"
  # Mock broker-lifecycle.mjs — minimal subset of the real exports. State
  # location is controlled by env var so tests can pre-populate broker.json
  # to model "broker exists" vs "broker absent" without rebuilding the
  # mock cache between tests.
  cat > "$lib_dir/broker-lifecycle.mjs" <<'MOCK_BROKER'
import fs from "node:fs";

function statePath() {
  return process.env.MOCK_BROKER_STATE_FILE || "";
}

export function loadBrokerSession(_cwd) {
  const p = statePath();
  if (!p || !fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

export async function sendBrokerShutdown(endpoint) {
  const log = process.env.MOCK_BROKER_SHUTDOWN_LOG;
  if (log) fs.appendFileSync(log, `${endpoint}\n`);
}

export function teardownBrokerSession({ endpoint, pidFile, logFile, sessionDir, pid, killProcess }) {
  if (Number.isFinite(pid) && killProcess) {
    try { killProcess(pid); } catch { /* ignore */ }
  }
  for (const f of [pidFile, logFile]) {
    if (f && fs.existsSync(f)) fs.unlinkSync(f);
  }
  if (typeof endpoint === "string" && endpoint.startsWith("unix:")) {
    const sock = endpoint.slice(5);
    if (fs.existsSync(sock)) fs.unlinkSync(sock);
  }
  if (sessionDir && fs.existsSync(sessionDir)) {
    try { fs.rmdirSync(sessionDir); } catch { /* non-empty or missing */ }
  }
}

export function clearBrokerSession(_cwd) {
  const p = statePath();
  if (p && fs.existsSync(p)) fs.unlinkSync(p);
}
MOCK_BROKER
  cat > "$lib_dir/process.mjs" <<'MOCK_PROC'
import fs from "node:fs";

export function terminateProcessTree(pid) {
  const log = process.env.MOCK_KILL_LOG;
  if (log) fs.appendFileSync(log, `${pid}\n`);
  return { attempted: true, delivered: false, method: "test-mock" };
}
MOCK_PROC
}

# Resolve the helper script path. Tests run from the chezmoi worktree,
# so the helper lives next to triple-review under its `executable_` name.
broker_helper_path() {
  printf '%s/executable_triple-review-broker-cleanup.mjs\n' "$SRC_BIN_DIR"
}

@test "T4-1 helper snapshot: no broker.json -> existed=false" {
  local cache="$SCRATCH_DIR/cache"
  seed_mock_codex_cache "$cache"
  export MOCK_BROKER_STATE_FILE="$SCRATCH_DIR/broker.json"  # absent
  export CODEX_COMPANION_CACHE_ROOT="$cache"

  run --separate-stderr node "$(broker_helper_path)" snapshot "$SCRATCH_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = '{"existed":false}' ]
}

@test "T4-2 helper snapshot: broker.json present -> existed=true" {
  local cache="$SCRATCH_DIR/cache"
  seed_mock_codex_cache "$cache"
  export MOCK_BROKER_STATE_FILE="$SCRATCH_DIR/broker.json"
  printf '{"endpoint":"unix:/tmp/x.sock","pid":42}\n' > "$MOCK_BROKER_STATE_FILE"
  export CODEX_COMPANION_CACHE_ROOT="$cache"

  run --separate-stderr node "$(broker_helper_path)" snapshot "$SCRATCH_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = '{"existed":true}' ]
}

@test "T4-3 helper teardown: snapshot.existed=true -> no-op (broker.json kept)" {
  local cache="$SCRATCH_DIR/cache"
  seed_mock_codex_cache "$cache"
  export MOCK_BROKER_STATE_FILE="$SCRATCH_DIR/broker.json"
  printf '{"endpoint":"unix:/tmp/x.sock","pid":42}\n' > "$MOCK_BROKER_STATE_FILE"
  export MOCK_BROKER_SHUTDOWN_LOG="$SCRATCH_DIR/shutdown.log"
  export MOCK_KILL_LOG="$SCRATCH_DIR/kill.log"
  export CODEX_COMPANION_CACHE_ROOT="$cache"

  run --separate-stderr node "$(broker_helper_path)" teardown "$SCRATCH_REPO" '{"existed":true}'
  [ "$status" -eq 0 ]
  # Conservative skip: pre-existing broker belongs to a concurrent session.
  [ -f "$MOCK_BROKER_STATE_FILE" ]
  [ ! -f "$MOCK_BROKER_SHUTDOWN_LOG" ]
  [ ! -f "$MOCK_KILL_LOG" ]
}

@test "T4-4 helper teardown: snapshot.existed=false but no broker now -> no-op" {
  local cache="$SCRATCH_DIR/cache"
  seed_mock_codex_cache "$cache"
  export MOCK_BROKER_STATE_FILE="$SCRATCH_DIR/broker.json"  # absent
  export MOCK_BROKER_SHUTDOWN_LOG="$SCRATCH_DIR/shutdown.log"
  export MOCK_KILL_LOG="$SCRATCH_DIR/kill.log"
  export CODEX_COMPANION_CACHE_ROOT="$cache"

  run --separate-stderr node "$(broker_helper_path)" teardown "$SCRATCH_REPO" '{"existed":false}'
  [ "$status" -eq 0 ]
  [ ! -f "$MOCK_BROKER_SHUTDOWN_LOG" ]
  [ ! -f "$MOCK_KILL_LOG" ]
}

@test "T4-5 helper teardown: existed=false + broker present -> shutdown + kill + clear" {
  local cache="$SCRATCH_DIR/cache"
  seed_mock_codex_cache "$cache"
  export MOCK_BROKER_STATE_FILE="$SCRATCH_DIR/broker.json"
  local session_dir="$SCRATCH_DIR/cxc-test"
  local sock_path="$session_dir/broker.sock"
  local pid_file="$session_dir/broker.pid"
  local log_file="$session_dir/broker.log"
  mkdir -p "$session_dir"
  : > "$sock_path"
  : > "$pid_file"
  : > "$log_file"
  cat > "$MOCK_BROKER_STATE_FILE" <<EOF
{
  "endpoint": "unix:$sock_path",
  "pidFile": "$pid_file",
  "logFile": "$log_file",
  "sessionDir": "$session_dir",
  "pid": 999999
}
EOF
  export MOCK_BROKER_SHUTDOWN_LOG="$SCRATCH_DIR/shutdown.log"
  export MOCK_KILL_LOG="$SCRATCH_DIR/kill.log"
  export CODEX_COMPANION_CACHE_ROOT="$cache"

  run --separate-stderr node "$(broker_helper_path)" teardown "$SCRATCH_REPO" '{"existed":false}'
  [ "$status" -eq 0 ]
  # Graceful shutdown was attempted via the broker socket.
  [ -f "$MOCK_BROKER_SHUTDOWN_LOG" ]
  grep -qF "unix:$sock_path" "$MOCK_BROKER_SHUTDOWN_LOG"
  # Process kill was attempted with the recorded broker pid.
  [ -f "$MOCK_KILL_LOG" ]
  grep -qx '999999' "$MOCK_KILL_LOG"
  # Broker artifacts and state file are gone.
  [ ! -f "$MOCK_BROKER_STATE_FILE" ]
  [ ! -f "$sock_path" ]
  [ ! -f "$pid_file" ]
  [ ! -f "$log_file" ]
  [ ! -d "$session_dir" ]
}

@test "T4-6 helper resolves highest installed plugin version (natural compare)" {
  local cache="$SCRATCH_DIR/cache"
  # Seed three versions out of lexicographic order. Real lib files only go
  # into 1.0.10 — if helper picks 1.0.4 or 1.0.9 instead, the import fails
  # with ERR_MODULE_NOT_FOUND. Empty lib dirs are deliberate so the wrong
  # pick is loud, not silent.
  for v in 1.0.4 1.0.10 1.0.9; do
    mkdir -p "$cache/$v/scripts/lib"
  done
  local lib_dir="$cache/1.0.10/scripts/lib"
  cat > "$lib_dir/broker-lifecycle.mjs" <<'MOCK'
export function loadBrokerSession() { return null; }
export async function sendBrokerShutdown() {}
export function teardownBrokerSession() {}
export function clearBrokerSession() {}
MOCK
  cat > "$lib_dir/process.mjs" <<'MOCK'
export function terminateProcessTree() {}
MOCK
  export CODEX_COMPANION_CACHE_ROOT="$cache"
  run --separate-stderr node "$(broker_helper_path)" snapshot "$SCRATCH_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = '{"existed":false}' ]
}

@test "T4-7 helper missing cache -> non-zero with diagnostic" {
  export CODEX_COMPANION_CACHE_ROOT="$SCRATCH_DIR/nonexistent_cache"
  run --separate-stderr node "$(broker_helper_path)" snapshot "$SCRATCH_REPO"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"codex plugin cache not found"* ]]
}

# =============================================================================
# Tier 4-B: bash-side integration of the cleanup helper.
# =============================================================================

@test "T4-8 resolve_broker_cleanup_helper: finds executable_-prefixed .mjs helper in source tree" {
  run --separate-stderr bash -c "source '$SRC_SCRIPT'; resolve_broker_cleanup_helper"
  [ "$status" -eq 0 ]
  [ "$output" = "$SRC_BIN_DIR/executable_triple-review-broker-cleanup.mjs" ]
}

@test "T4-9 cleanup_codex_broker: idempotent (BROKER_CLEANUP_DONE guard)" {
  # First call sets BROKER_CLEANUP_DONE=1; subsequent calls must early-return
  # before invoking the helper. The helper is wired to a fail-loud script —
  # if any call past the first invoked it, stderr would contain the warn.
  local fail_helper="$SCRATCH_DIR/fail_helper"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_helper"
  chmod +x "$fail_helper"
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    BROKER_CLEANUP_HELPER='$fail_helper'
    BROKER_PRE_SNAPSHOT='{\"existed\":true}'
    INITIAL_PWD=/tmp
    cleanup_codex_broker
    cleanup_codex_broker
    cleanup_codex_broker
    printf 'done=%s\n' \"\$BROKER_CLEANUP_DONE\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"done=1"* ]]
  # Helper would have stayed silent only if early-skip via existed=true held;
  # both layers (idempotency guard + existed=true skip) are intentional.
}

@test "T4-10 cleanup_codex_broker: no-op when BROKER_PRE_SNAPSHOT empty" {
  # No pre-snapshot means main() never called the helper (early abort path).
  # Cleanup must not invoke the helper either.
  local fail_helper="$SCRATCH_DIR/fail_helper"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_helper"
  chmod +x "$fail_helper"
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    BROKER_CLEANUP_HELPER='$fail_helper'
    BROKER_PRE_SNAPSHOT=''
    INITIAL_PWD=/tmp
    cleanup_codex_broker
  "
  [ "$status" -eq 0 ]
  # Helper exit-1 would have triggered the warn; absence of stderr proves the
  # helper was not invoked.
  [ -z "$stderr" ]
}

@test "T4-11 cleanup_codex_broker: no-op when helper file missing" {
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    BROKER_CLEANUP_HELPER='$SCRATCH_DIR/nonexistent_helper'
    BROKER_PRE_SNAPSHOT='{\"existed\":false}'
    INITIAL_PWD=/tmp
    cleanup_codex_broker
  "
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "T4-12 cleanup_codex_broker: helper failure -> warn, no abort" {
  local fail_helper="$SCRATCH_DIR/fail_helper"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_helper"
  chmod +x "$fail_helper"
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    BROKER_CLEANUP_HELPER='$fail_helper'
    BROKER_PRE_SNAPSHOT='{\"existed\":false}'
    INITIAL_PWD=/tmp
    cleanup_codex_broker
    printf 'survived\n'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == "survived" ]]
  [[ "$stderr" == *"Codex broker teardown failed"* ]]
}

@test "T4-13 kill_children calls cleanup_codex_broker even when CHILDREN empty" {
  # Regression for the 'early-return when CHILDREN is empty' path that was
  # restructured. The trap target must always reach the broker cleanup so
  # post-aggregation failures (CHILDREN already drained by remove_pid)
  # still tear down the broker.
  local marker="$SCRATCH_DIR/cleanup_called"
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    cleanup_codex_broker() { touch '$marker'; }
    CHILDREN=()
    MONITOR_PID=''
    kill_children
  "
  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

# -----------------------------------------------------------------------------
# WRAPPER-*: enforce claude_p_neutral wrapper usage at all claude -p spawn
# sites. Without this enforcement, persona contamination from user-global
# outputStyle settings can leak into reviewer outputs / aggregator envelope
# (ADR 0017).
# -----------------------------------------------------------------------------

@test "WRAPPER-1A: PR reviewer spawn site uses claude_p_neutral" {
  # Spawn-site-specific assertion (replaces aggregate count==3) so a missing
  # wrapper at one site is diagnosable without staring at a bare count.
  # awk skips line-start `#` comments to prevent documentation that mentions
  # the spawn-site literal from satisfying the test.
  hits=$(awk '
    /^[[:space:]]*#/ { next }
    /claude_p_neutral[[:space:]]+"\/pr-review-toolkit:review-pr"/ { print }
  ' "$SRC_SCRIPT")
  [ -n "$hits" ]
}

@test "WRAPPER-1B: security reviewer spawn site uses claude_p_neutral" {
  hits=$(awk '
    /^[[:space:]]*#/ { next }
    /claude_p_neutral[[:space:]]+"\/security-review"/ { print }
  ' "$SRC_SCRIPT")
  [ -n "$hits" ]
}

@test "WRAPPER-1C: aggregator spawn site uses claude_p_neutral with stdin pipe" {
  # Aggregator uniquely uses stdin redirection (`< prompt.txt`); other sites
  # take the slash command as a positional arg. Pattern is comment-skipped
  # but NOT line-start-anchored: the actual code is
  # `if ! claude_p_neutral < "$workdir/prompt.txt" > ...` so a `^[[:space:]]*`
  # anchor would false-fail on the `if !` prefix.
  hits=$(awk '
    /^[[:space:]]*#/ { next }
    /claude_p_neutral[[:space:]]*</ { print }
  ' "$SRC_SCRIPT")
  [ -n "$hits" ]
}

@test "WRAPPER-2: wrapper definition forces outputStyle=triple-review" {
  # Relaxed from a full literal: tolerates JSON whitespace variations
  # (`{"outputStyle":"triple-review"}`, `{ "outputStyle" : "triple-review" }`)
  # so future style refactors don't have to update this regex.
  # awk skips line-start `#` comments — the script's docstring at line 278
  # quotes the same JSON payload and would otherwise satisfy the test even
  # if the actual wrapper definition were removed.
  hits=$(awk '
    /^[[:space:]]*#/ { next }
    /outputStyle.*triple-review/ { print }
  ' "$SRC_SCRIPT")
  [ -n "$hits" ]
}

@test "WRAPPER-3: no bare claude -p invocations exist outside claude_p_neutral()" {
  # awk-based body exclusion: tracks the `claude_p_neutral() { ... }` block
  # and reports `claude -p` occurrences anywhere else. Survives multi-line
  # refactors (e.g. `claude -p \\` continuation with `--settings` on the next
  # line) that defeated the previous `grep -v -- '--settings'` filter.
  # Comment lines (line-start `#`) are skipped — the script documents the
  # `claude -p` API in several comments; only executable references count.
  bare=$(awk '
    /^claude_p_neutral\(\)[[:space:]]*\{/ { in_wrapper = 1; next }
    in_wrapper && /^\}/ { in_wrapper = 0; next }
    in_wrapper { next }
    /^[[:space:]]*#/ { next }
    /claude[[:space:]]+-p([[:space:]]|$)/ { print FILENAME ":" NR ":" $0 }
  ' "$SRC_SCRIPT")
  [ -z "$bare" ] || { printf 'Bare claude -p outside claude_p_neutral():\n%s\n' "$bare" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# WRAPPER-B*: behavior tests via the tests/bats/bin/claude PATH-shadow stub.
# Static WRAPPER-1/2/3 prove the wrapper is *invoked*; these prove the *argv*
# and *stdin* it produces are correct (Codex adversarial feedback gap: JSON
# quoting, `"$@"` preservation).
# -----------------------------------------------------------------------------

@test "WRAPPER-B1: claude_p_neutral argv layout: -p, --settings, JSON single arg, user arg" {
  export MOCK_CLAUDE_LOG="$SCRATCH_DIR/claude.argv.log"
  run bash -c "source '$SRC_SCRIPT'; claude_p_neutral '/pr-review-toolkit:review-pr'"
  [ "$status" -eq 0 ]
  # 4 positional args: -p / --settings / JSON / user arg
  [ "$(wc -l < "$MOCK_CLAUDE_LOG")" -eq 4 ]
  [ "$(sed -n '1p' "$MOCK_CLAUDE_LOG")" = '-p' ]
  [ "$(sed -n '2p' "$MOCK_CLAUDE_LOG")" = '--settings' ]
  # JSON must arrive as ONE argv element (not whitespace-split into pieces)
  [ "$(sed -n '3p' "$MOCK_CLAUDE_LOG")" = '{"outputStyle":"triple-review"}' ]
  [ "$(sed -n '4p' "$MOCK_CLAUDE_LOG")" = '/pr-review-toolkit:review-pr' ]
}

@test "WRAPPER-B2: claude_p_neutral preserves stdin verbatim (aggregator path)" {
  export MOCK_CLAUDE_STDIN_LOG="$SCRATCH_DIR/claude.stdin.log"
  local payload='### prompt header
multi-line body
with "quotes" and $dollar signs and `backticks`'
  run bash -c "source '$SRC_SCRIPT'; printf '%s' \"\$1\" | claude_p_neutral" \
    bash "$payload"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_CLAUDE_STDIN_LOG")" = "$payload" ]
}

@test "WRAPPER-B3: claude_p_neutral preserves multiple user args under \"\$@\"" {
  export MOCK_CLAUDE_LOG="$SCRATCH_DIR/claude.argv.log"
  # User args containing spaces must remain single argv elements (not split).
  run bash -c "source '$SRC_SCRIPT'; claude_p_neutral 'arg with spaces' '/another/arg' 'third'"
  [ "$status" -eq 0 ]
  # 3 fixed (-p / --settings / JSON) + 3 user args = 6 lines
  [ "$(wc -l < "$MOCK_CLAUDE_LOG")" -eq 6 ]
  [ "$(sed -n '4p' "$MOCK_CLAUDE_LOG")" = 'arg with spaces' ]
  [ "$(sed -n '5p' "$MOCK_CLAUDE_LOG")" = '/another/arg' ]
  [ "$(sed -n '6p' "$MOCK_CLAUDE_LOG")" = 'third' ]
}
