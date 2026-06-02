#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="$REPO_ROOT/.chezmoiscripts/run_after_check-npm-cooldown.sh"
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  export SCRIPT STUB_DIR
}

write_npm_stub() {
  cat > "$STUB_DIR/npm" <<'STUB'
#!/usr/bin/env sh
case "$1" in
  --version)
    if [ "${NPM_STUB_VERSION_FAIL:-0}" = 1 ]; then
      printf '%s\n' "npm version failed" >&2
      exit 1
    fi
    printf '%s\n' "${NPM_STUB_VERSION:-11.10.0}"
    ;;
  config)
    if [ "$2" != get ]; then
      printf '%s\n' "unsupported npm config invocation: $*" >&2
      exit 2
    fi
    if [ -n "${NPM_STUB_CWD_LOG:-}" ]; then
      pwd >> "$NPM_STUB_CWD_LOG"
    fi
    case "$3" in
      min-release-age)
        printf '%s\n' "${NPM_STUB_MIN_RELEASE_AGE:-7}"
        ;;
      before)
        printf '%s\n' "${NPM_STUB_BEFORE:-null}"
        ;;
      *)
        printf '%s\n' "unsupported npm config key: $3" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    printf '%s\n' "unsupported npm invocation: $*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$STUB_DIR/npm"
}

write_node_stub() {
  cat > "$STUB_DIR/node" <<'STUB'
#!/usr/bin/env sh
exit "${NODE_STUB_STATUS:-0}"
STUB
  chmod +x "$STUB_DIR/node"
}

run_gate() {
  run --separate-stderr env \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    TMPDIR="$BATS_TEST_TMPDIR" \
    "$SCRIPT"
}

@test "npm missing passes without requiring other tooling" {
  run --separate-stderr env PATH="$STUB_DIR" "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "npm --version failure blocks apply" {
  write_npm_stub
  export NPM_STUB_VERSION_FAIL=1

  run_gate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"npm --version' failed"* ]]
}

@test "unparseable npm version blocks apply" {
  write_npm_stub
  export NPM_STUB_VERSION=not-a-version

  run_gate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot parse npm version"* ]]
}

@test "npm versions below 11.10.0 block apply" {
  write_npm_stub

  export NPM_STUB_VERSION=10.9.0
  run_gate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"npm cooldown not enforced"* ]]

  export NPM_STUB_VERSION=11.9.9
  run_gate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"npm cooldown not enforced"* ]]
}

@test "npm 11.10.0 and newer pass when min-release-age is effective" {
  write_npm_stub

  for version in 11.10.0 11.10.1 12.0.0; do
    export NPM_STUB_VERSION="$version"
    export NPM_STUB_MIN_RELEASE_AGE=7
    export NPM_STUB_BEFORE=null
    run_gate
    [ "$status" -eq 0 ]
  done
}

@test "effective min-release-age override blocks apply" {
  write_npm_stub
  export NPM_STUB_MIN_RELEASE_AGE=0
  export NPM_STUB_BEFORE=null

  run_gate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"npm cooldown not effective"* ]]
  [[ "$stderr" == *"min-release-age=0"* ]]
}

@test "effective before window is validated" {
  write_npm_stub
  write_node_stub
  export NPM_STUB_MIN_RELEASE_AGE=null
  export NPM_STUB_BEFORE="2026-05-26T00:00:00.000Z"

  export NODE_STUB_STATUS=0
  run_gate
  [ "$status" -eq 0 ]

  export NODE_STUB_STATUS=1
  run_gate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"before=2026-05-26T00:00:00.000Z"* ]]
}

@test "effective config is checked from an empty temporary directory" {
  write_npm_stub
  local project_dir="$BATS_TEST_TMPDIR/project"
  local cwd_log="$BATS_TEST_TMPDIR/npm-cwd.log"
  mkdir -p "$project_dir"
  printf '%s\n' "min-release-age=0" > "$project_dir/.npmrc"

  export NPM_STUB_CWD_LOG="$cwd_log"
  export NPM_STUB_MIN_RELEASE_AGE=7
  export NPM_STUB_BEFORE=null

  run --separate-stderr env \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    TMPDIR="$BATS_TEST_TMPDIR" \
    NPM_STUB_CWD_LOG="$NPM_STUB_CWD_LOG" \
    NPM_STUB_MIN_RELEASE_AGE="$NPM_STUB_MIN_RELEASE_AGE" \
    NPM_STUB_BEFORE="$NPM_STUB_BEFORE" \
    sh -c 'cd "$1" && exec "$2"' sh "$project_dir" "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$cwd_log" ]
  while IFS= read -r cwd; do
    [[ "$cwd" == "$BATS_TEST_TMPDIR"/npm-cooldown-check.* ]]
  done < "$cwd_log"
}
