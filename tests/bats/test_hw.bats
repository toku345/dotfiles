#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HW_SOURCE="$REPO_ROOT/dot_local/bin/executable_hw"
  REAL_GIT="$(type -P git)"
  REAL_CKSUM="$(type -P cksum)"
  REAL_TR="$(type -P tr)"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  HERDR_STUB_LOG="$BATS_TEST_TMPDIR/herdr.log"
  mkdir -p "$TEST_BIN"

  export HW_SOURCE HERDR_STUB_LOG

  cat > "$TEST_BIN/hw" <<'EOF'
#!/usr/bin/env bash
exec bash "$HW_SOURCE" "$@"
EOF
  cat > "$TEST_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
{
  printf 'HERDR_SESSION=%s\n' "${HERDR_SESSION-unset}"
  printf 'HERDR_SOCKET_PATH=%s\n' "${HERDR_SOCKET_PATH-unset}"
  printf 'HERDR_ENV=%s\n' "${HERDR_ENV-unset}"
  index=0
  for arg in "$@"; do
    printf 'ARG[%d]=%s\n' "$index" "$arg"
    index=$((index + 1))
  done
} > "$HERDR_STUB_LOG"
exit "${HERDR_STUB_EXIT:-0}"
EOF
  chmod +x "$TEST_BIN/hw" "$TEST_BIN/herdr"
  ln -s "$REAL_GIT" "$TEST_BIN/git"
  ln -s "$REAL_CKSUM" "$TEST_BIN/cksum"
  ln -s "$REAL_TR" "$TEST_BIN/tr"
  export PATH="$TEST_BIN:/usr/bin:/bin"
}

init_repo() {
  local path="$1"
  "$REAL_GIT" init -q "$path"
  "$REAL_GIT" -C "$path" config user.email test@example.com
  "$REAL_GIT" -C "$path" config user.name "Test User"
  : > "$path/README.md"
  "$REAL_GIT" -C "$path" add README.md
  "$REAL_GIT" -C "$path" commit -qm initial
}

session_arg() {
  sed -n 's/^ARG\[1\]=//p' "$HERDR_STUB_LOG"
}

expected_checksum() {
  local raw_name="$1"
  local output checksum
  output="$(printf '%s' "$raw_name" | "$REAL_CKSUM")"
  read -r checksum _ <<< "$output"
  printf '%s\n' "$checksum"
}

@test "valid repository basename becomes the session name" {
  local repo="$BATS_TEST_TMPDIR/chezmoi"
  local expected_root
  init_repo "$repo"
  expected_root="$("$REAL_GIT" -C "$repo" rev-parse --show-toplevel)"

  cd "$repo"
  run --separate-stderr hw status server --json

  [ "$status" -eq 0 ]
  [ "$(session_arg)" = "chezmoi" ]
  [[ "$stderr" == *"checkout=$expected_root session=chezmoi"* ]]
  grep -Fxq 'ARG[0]=--session' "$HERDR_STUB_LOG"
  grep -Fxq 'ARG[2]=status' "$HERDR_STUB_LOG"
  grep -Fxq 'ARG[3]=server' "$HERDR_STUB_LOG"
  grep -Fxq 'ARG[4]=--json' "$HERDR_STUB_LOG"
}

@test "nested directory resolves to the Git top-level session" {
  local repo="$BATS_TEST_TMPDIR/project-one"
  init_repo "$repo"
  mkdir -p "$repo/src/nested"

  cd "$repo/src/nested"
  run hw

  [ "$status" -eq 0 ]
  [ "$(session_arg)" = "project-one" ]
}

@test "linked worktree uses the worktree directory basename" {
  local repo="$BATS_TEST_TMPDIR/project-main"
  local worktree="$BATS_TEST_TMPDIR/feature-one"
  init_repo "$repo"
  "$REAL_GIT" -C "$repo" worktree add -qb feature/one "$worktree"

  cd "$worktree"
  run hw

  [ "$status" -eq 0 ]
  [ "$(session_arg)" = "feature-one" ]
}

@test "invalid characters are normalized and suffixed with cksum" {
  local raw_name="foo bar"
  local repo="$BATS_TEST_TMPDIR/$raw_name"
  local checksum
  checksum="$(expected_checksum "$raw_name")"
  init_repo "$repo"

  cd "$repo"
  run hw

  [ "$status" -eq 0 ]
  [ "$(session_arg)" = "foo-bar-$checksum" ]
}

@test "different invalid basenames do not normalize to the same session" {
  local first="$BATS_TEST_TMPDIR/foo bar"
  local second="$BATS_TEST_TMPDIR/foo@bar"
  local first_session second_session
  init_repo "$first"
  init_repo "$second"

  cd "$first"
  run hw
  [ "$status" -eq 0 ]
  first_session="$(session_arg)"

  cd "$second"
  run hw
  [ "$status" -eq 0 ]
  second_session="$(session_arg)"

  [ "$first_session" != "$second_session" ]
}

@test "non-ASCII basename uses a readable fallback and checksum" {
  local raw_name="開発"
  local repo="$BATS_TEST_TMPDIR/$raw_name"
  local checksum
  checksum="$(expected_checksum "$raw_name")"
  init_repo "$repo"

  cd "$repo"
  run hw

  [ "$status" -eq 0 ]
  [ "$(session_arg)" = "session-$checksum" ]
}

@test "long valid basename is capped at forty characters with checksum" {
  local raw_name="abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz"
  local repo="$BATS_TEST_TMPDIR/$raw_name"
  local name checksum
  checksum="$(expected_checksum "$raw_name")"
  init_repo "$repo"

  cd "$repo"
  run hw

  [ "$status" -eq 0 ]
  name="$(session_arg)"
  [ "${#name}" -le 40 ]
  [[ "$name" == *"-$checksum" ]]
}

@test "forty characters stay unchanged and forty-one use a checksum" {
  local forty="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local forty_one="${forty}a"
  local repo_40="$BATS_TEST_TMPDIR/$forty"
  local repo_41="$BATS_TEST_TMPDIR/$forty_one"
  local session_41 checksum_41
  checksum_41="$(expected_checksum "$forty_one")"
  init_repo "$repo_40"
  init_repo "$repo_41"

  cd "$repo_40"
  run hw
  [ "$status" -eq 0 ]
  [ "$(session_arg)" = "$forty" ]

  cd "$repo_41"
  run hw
  [ "$status" -eq 0 ]
  session_41="$(session_arg)"
  [ "${#session_41}" -le 40 ]
  [[ "$session_41" == *"-$checksum_41" ]]
}

@test "reserved default basename never selects the default session" {
  local raw_name="default"
  local repo="$BATS_TEST_TMPDIR/$raw_name"
  local checksum
  checksum="$(expected_checksum "$raw_name")"
  init_repo "$repo"

  cd "$repo"
  run hw

  [ "$status" -eq 0 ]
  [ "$(session_arg)" = "default-$checksum" ]
  [ "$(session_arg)" != "default" ]
}

@test "identical basenames intentionally select the same session" {
  local first="$BATS_TEST_TMPDIR/one/shared"
  local second="$BATS_TEST_TMPDIR/two/shared"
  local first_session second_session
  mkdir -p "$(dirname "$first")" "$(dirname "$second")"
  init_repo "$first"
  init_repo "$second"

  cd "$first"
  run hw
  [ "$status" -eq 0 ]
  first_session="$(session_arg)"

  cd "$second"
  run hw
  [ "$status" -eq 0 ]
  second_session="$(session_arg)"

  [ "$first_session" = "shared" ]
  [ "$second_session" = "$first_session" ]
}

@test "inherited Herdr routing variables are removed" {
  local repo="$BATS_TEST_TMPDIR/project-env"
  init_repo "$repo"
  export HERDR_SESSION=wrong-session
  export HERDR_SOCKET_PATH=/tmp/wrong.sock
  export HERDR_ENV=1

  cd "$repo"
  run hw

  [ "$status" -eq 0 ]
  grep -Fxq 'HERDR_SESSION=unset' "$HERDR_STUB_LOG"
  grep -Fxq 'HERDR_SOCKET_PATH=unset' "$HERDR_STUB_LOG"
  grep -Fxq 'HERDR_ENV=unset' "$HERDR_STUB_LOG"
}

@test "all session-routing option forms are rejected without invoking Herdr" {
  local repo="$BATS_TEST_TMPDIR/project-routing"
  local option
  init_repo "$repo"

  cd "$repo"
  for option in '--session other' '--session=other' '--no-session' '--remote host' '--remote=host'; do
    rm -f "$HERDR_STUB_LOG"
    read -r -a args <<<"$option"
    run --separate-stderr hw "${args[@]}"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"session-routing option is not allowed"* ]]
    [ ! -e "$HERDR_STUB_LOG" ]
  done
}

@test "session management subcommand is rejected without invoking Herdr" {
  local repo="$BATS_TEST_TMPDIR/project-session-command"
  init_repo "$repo"

  cd "$repo"
  run --separate-stderr hw session attach other

  [ "$status" -eq 2 ]
  [[ "$stderr" == *"bypasses checkout-derived routing"* ]]
  [ ! -e "$HERDR_STUB_LOG" ]
}

@test "routing-looking payload after double dash is forwarded" {
  local repo="$BATS_TEST_TMPDIR/project-payload"
  init_repo "$repo"

  cd "$repo"
  run hw agent start worker -- --session payload

  [ "$status" -eq 0 ]
  grep -Fxq 'ARG[6]=--session' "$HERDR_STUB_LOG"
  grep -Fxq 'ARG[7]=payload' "$HERDR_STUB_LOG"
}

@test "outside Git fails with machine-operations guidance" {
  cd "$BATS_TEST_TMPDIR"

  run --separate-stderr hw

  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unable to resolve the current Git worktree"* ]]
  [[ "$stderr" == *"For machine operations outside Git, run: herdr"* ]]
  [ ! -e "$HERDR_STUB_LOG" ]
}

@test "missing Herdr fails with exit 127" {
  local repo="$BATS_TEST_TMPDIR/project-missing-herdr"
  local no_herdr_bin="$BATS_TEST_TMPDIR/no-herdr-bin"
  init_repo "$repo"
  mkdir -p "$no_herdr_bin"
  ln -s "$REAL_GIT" "$no_herdr_bin/git"
  ln -s "$REAL_CKSUM" "$no_herdr_bin/cksum"
  ln -s "$REAL_TR" "$no_herdr_bin/tr"

  cd "$repo"
  PATH="$no_herdr_bin:/usr/bin:/bin" run -127 --separate-stderr bash "$HW_SOURCE"

  [ "$status" -eq 127 ]
  [[ "$stderr" == *"required command not found on PATH: herdr"* ]]
}

@test "Herdr exit status is preserved" {
  local repo="$BATS_TEST_TMPDIR/project-exit"
  init_repo "$repo"
  export HERDR_STUB_EXIT=23

  cd "$repo"
  run hw status server

  [ "$status" -eq 23 ]
}

@test "tr failure aborts normalization without invoking Herdr" {
  local repo="$BATS_TEST_TMPDIR/project with spaces"
  init_repo "$repo"
  rm "$TEST_BIN/tr"
  cat > "$TEST_BIN/tr" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
  chmod +x "$TEST_BIN/tr"

  cd "$repo"
  run --separate-stderr hw

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"failed to normalize the checkout name with tr"* ]]
  [ ! -e "$HERDR_STUB_LOG" ]
}

@test "cksum failure with parseable output aborts without invoking Herdr" {
  local repo="$BATS_TEST_TMPDIR/project with spaces"
  init_repo "$repo"
  rm "$TEST_BIN/cksum"
  cat > "$TEST_BIN/cksum" <<'EOF'
#!/usr/bin/env bash
printf '123 4\n'
exit 9
EOF
  chmod +x "$TEST_BIN/cksum"

  cd "$repo"
  run --separate-stderr hw

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"failed to checksum the checkout name with cksum"* ]]
  [ ! -e "$HERDR_STUB_LOG" ]
}

@test "help succeeds without a Git checkout" {
  cd "$BATS_TEST_TMPDIR"

  run hw --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: hw"* ]]
  [ ! -e "$HERDR_STUB_LOG" ]
}
