#!/usr/bin/env bats
# shellcheck shell=bash

# Issue #146: the three native-bin prepends are idempotent and keep existing order.
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  export BASHRC="$REPO_ROOT/dot_bashrc"
  mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.bun/bin"
  cat > "$BATS_TEST_TMPDIR/path-assert.bash" <<'EOF'
entry_count() {
  local needle="$1" rest="$PATH" item count=0
  while true; do
    item=${rest%%:*}
    [[ "$item" == "$needle" ]] && count=$((count + 1))
    case "$rest" in
      *:*) rest=${rest#*:} ;;
      *) break ;;
    esac
  done
  printf '%s' "$count"
}

assert_native_bins() {
  local block="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin" dir
  case ":$PATH:" in
    *":${block}:"*) ;;
    *) printf 'native bins out of order: %s\n' "$PATH" >&2; return 1 ;;
  esac
  for dir in "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/.local/bin"; do
    [ "$(entry_count "$dir")" -eq 1 ] || return 1
  done
}
EOF
}

run_isolated_bashrc() {
  local script="$1"
  run --separate-stderr env -i \
    HOME="$HOME" \
    BASHRC="$BASHRC" \
    PATH="${PATH_UNDER_TEST:-/usr/bin:/bin}" \
    /bin/bash --noprofile --norc -c '
      source "$1"
      eval "$2"
    ' bash "$BATS_TEST_TMPDIR/path-assert.bash" "$script"
}

@test "dot_bashrc passes bash -n and shellcheck" {
  run -0 /bin/bash -n "$BASHRC"
  command -v shellcheck >/dev/null || {
    printf 'shellcheck is required\n' >&2
    return 1
  }
  run -0 shellcheck --severity=warning "$BASHRC"
}

@test "first source prepends native bins once and a second source does not duplicate them" {
  run_isolated_bashrc '
    export -n PATH
    source "$BASHRC" || true
    set -e
    assert_native_bins
    exported=$(/bin/bash --noprofile --norc -c "printf %s \"\$PATH\"")
    [ "$exported" = "$PATH" ]
    if [[ ! -e /home/linuxbrew/.linuxbrew/bin/brew ]]; then
      [ "$PATH" = "$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin" ]
    fi
    first=$PATH
    set +e
    source "$BASHRC" || true
    set -e
    assert_native_bins
    if [[ ! -e /home/linuxbrew/.linuxbrew/bin/brew ]]; then
      [ "$PATH" = "$first" ]
    fi
  '
  [ "$status" -eq 0 ]
}

@test "existing PATH entries keep their order and a prefix lookalike stays distinct" {
  PATH_UNDER_TEST="$HOME/.local/bin-extra:/usr/bin:$HOME/.cargo/bin:/bin:$HOME/.bun/bin"
  run_isolated_bashrc '
    source "$BASHRC" || true
    set -e
    original="$HOME/.local/bin-extra:/usr/bin:$HOME/.cargo/bin:/bin:$HOME/.bun/bin"
    case "$PATH" in
      *":${original}") ;;
      *) printf "existing PATH order changed: %s\n" "$PATH" >&2; exit 1 ;;
    esac
    case "${PATH%"$original"}" in
      *"$HOME/.local/bin:"*) ;;
      *) printf "real ~/.local/bin was not prepended: %s\n" "$PATH" >&2; exit 1 ;;
    esac
    [ "$(entry_count "$HOME/.local/bin")" -eq 1 ]
    [ "$(entry_count "$HOME/.local/bin-extra")" -eq 1 ]
    [ "$(entry_count "$HOME/.cargo/bin")" -eq 1 ]
    [ "$(entry_count "$HOME/.bun/bin")" -eq 1 ]
    first=$PATH
    set +e
    source "$BASHRC" || true
    set -e
    [ "$(entry_count "$HOME/.local/bin")" -eq 1 ]
    [ "$(entry_count "$HOME/.cargo/bin")" -eq 1 ]
    [ "$(entry_count "$HOME/.bun/bin")" -eq 1 ]
    if [[ ! -e /home/linuxbrew/.linuxbrew/bin/brew ]]; then
      [ "$PATH" = "$first" ]
    fi
  '
  [ "$status" -eq 0 ]
}
