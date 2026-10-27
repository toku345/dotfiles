#!/usr/bin/env bats
# shellcheck shell=bash
# Fixture tests for the pr-review routing-flag floor. The workflow tests receive
# the flags pre-computed, so a regex regression here would otherwise only show
# up as specialist routing silently narrowing to the categorizer's judgment.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/private_dot_claude/skills/pr-review/scripts/routing-flags.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q "$FIXTURE"
  git -C "$FIXTURE" config user.name fixture
  git -C "$FIXTURE" config user.email fixture@example.invalid
  printf 'seed\n' > "$FIXTURE/README"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -qm base
  BASE_COMMIT="$(git -C "$FIXTURE" rev-parse HEAD)"
}

# commit_file <path> <content>: write the file and commit it on top of base.
commit_file() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "$2" > "$FIXTURE/$1"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -qm change
}

run_flags() {
  cd "$FIXTURE" || return 1
  run --separate-stderr sh "$SCRIPT" "$BASE_COMMIT" HEAD
}

assert_flags() {
  [ "$status" -eq 0 ]
  [ "$output" = "$1" ]
}

@test "JS type: object keys set neither flag" {
  commit_file src/schema.js "const s = { type: 'string', items: { type: 'object' } }"
  run_flags
  assert_flags "commentChanges=false typeChanges=false"
}

@test "markdown prose with type/class/schema keywords sets neither flag" {
  commit_file docs/guide.md "# Notes
Define a class Foo and type Bar = Baz; create table users via the schema."
  run_flags
  assert_flags "commentChanges=false typeChanges=false"
}

@test "removed SQL -- comment line sets commentChanges" {
  commit_file db/q.sql "-- explain the query
select 1;"
  BASE_COMMIT="$(git -C "$FIXTURE" rev-parse HEAD)"
  commit_file db/q.sql "select 1;"
  run_flags
  assert_flags "commentChanges=true typeChanges=false"
}

@test "Go type struct sets typeChanges" {
  commit_file pkg/user.go "type User struct {
	Name string
}"
  run_flags
  assert_flags "commentChanges=false typeChanges=true"
}

@test "TS interface sets typeChanges" {
  commit_file src/user.ts "export interface User {
  name: string
}"
  run_flags
  assert_flags "commentChanges=false typeChanges=true"
}

@test "@dataclass sets typeChanges" {
  commit_file app/model.py "@dataclass
def build(): pass"
  run_flags
  assert_flags "commentChanges=false typeChanges=true"
}

@test "Rust pub struct sets typeChanges" {
  commit_file src/lib.rs "pub(crate) struct Config {}"
  run_flags
  assert_flags "commentChanges=false typeChanges=true"
}

@test "CREATE TABLE sets typeChanges" {
  commit_file db/migrate.sql "CREATE TABLE users (id int);"
  run_flags
  assert_flags "commentChanges=false typeChanges=true"
}

@test "triple-quoted docstring sets commentChanges" {
  commit_file app/util.py '    """Explain the helper."""'
  run_flags
  assert_flags "commentChanges=true typeChanges=false"
}

@test "each comment marker alone sets commentChanges" {
  local spec file line
  # One file per spec: reusing a file would leave the previous spec in the
  # diff as a removed line, which matches too and masks the branch under test.
  for spec in 'a.sh|# note' 'a.js|// note' 'a.c|/* note' 'b.c| * note' \
    'a.html|<!-- note -->' 'a.el|; note' "a.py|'''doc'''"; do
    file="${spec%%|*}" line="${spec#*|}"
    commit_file "$file" "$line"
    run_flags
    [ "$status" -eq 0 ] && [ "$output" = "commentChanges=true typeChanges=false" ] || {
      echo "marker in $file ($line): $output" >&2
      return 1
    }
    BASE_COMMIT="$(git -C "$FIXTURE" rev-parse HEAD)"
  done
}

@test "each type-definition form alone sets typeChanges" {
  local spec file line
  for spec in 'a.kt|abstract class Shape' 'b.kt|data class Point(val x: Int)' \
    'c.kt|sealed interface Expr' 'a.java|final class Box' 'a.rs|enum Color {}' \
    'b.rs|trait Draw {}' 'a.ts|type Id = string' 'a.go|type Reader interface {' \
    'a.sql|ALTER TABLE users ADD age int;' 'b.sql|create schema app;'; do
    file="${spec%%|*}" line="${spec#*|}"
    commit_file "$file" "$line"
    run_flags
    [ "$status" -eq 0 ] && [ "$output" = "commentChanges=false typeChanges=true" ] || {
      echo "type form in $file ($line): $output" >&2
      return 1
    }
    BASE_COMMIT="$(git -C "$FIXTURE" rev-parse HEAD)"
  done
}

# stub_grep <case body>: put a grep stub first on PATH; the real grep stays
# reachable as $REAL_GREP for the stages the stub passes through.
stub_grep() {
  REAL_GREP="$(command -v grep)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n%s\n' "$1" > "$BATS_TEST_TMPDIR/bin/grep"
  chmod +x "$BATS_TEST_TMPDIR/bin/grep"
  export REAL_GREP
}

run_flags_with_stub() {
  cd "$FIXTURE" || return 1
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run --separate-stderr sh "$SCRIPT" "$BASE_COMMIT" HEAD
}

@test "grep error in the first filter stage aborts instead of reporting false flags" {
  commit_file src/app.js "const x = 1"
  stub_grep 'case "$*" in "-E ^[+-]") exit 2 ;; *) exec "$REAL_GREP" "$@" ;; esac'
  run_flags_with_stub
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABORT: grep filter for routing flags failed (exit 2)"* ]]
}

@test "grep error in the header-exclusion filter aborts instead of reporting false flags" {
  commit_file src/app.js "const x = 1"
  stub_grep 'case "$*" in -vE*) exit 2 ;; *) exec "$REAL_GREP" "$@" ;; esac'
  run_flags_with_stub
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABORT: grep filter for routing flags failed (exit 2)"* ]]
}

@test "grep error in a flag pattern aborts instead of reporting false flags" {
  commit_file src/app.js "const x = 1"
  stub_grep 'case "$*" in "-E ^[+-]"|-vE*) exec "$REAL_GREP" "$@" ;; *) exit 2 ;; esac'
  run_flags_with_stub
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABORT: grep for routing flags failed (exit 2)"* ]]
}

@test "git diff failure aborts instead of reporting false flags" {
  cd "$FIXTURE" || return 1
  run --separate-stderr sh "$SCRIPT" 0000000000000000000000000000000000000000 HEAD
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"ABORT: git diff for routing flags failed"* ]]
}

@test "wrong argument count exits 2 with usage" {
  cd "$FIXTURE" || return 1
  run --separate-stderr sh "$SCRIPT" "$BASE_COMMIT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"usage: routing-flags.sh <base-commit> <head-ref>"* ]]
}
