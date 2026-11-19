#!/usr/bin/env bats
# shellcheck shell=bash
bats_require_minimum_version 1.5.0

setup() {
  [[ "$(uname -s)" == Linux ]] || skip 'bashrc is deployed only on Linux'
  BASHRC="$BATS_TEST_DIRNAME/../../dot_bashrc"
  FIXTURE_HOME="$BATS_TEST_TMPDIR/home"
  BREW_PREFIX="$BATS_TEST_TMPDIR/linuxbrew"
  BREW_BASH_BIN="$BREW_PREFIX/opt/bash/bin"
  # The lookalike and repeated custom entry are not managed by bashrc.
  ORIGINAL_PATH="$FIXTURE_HOME/.local/bin-extra:/custom/first:/usr/bin:/custom/second:/custom/first:/bin"
  NATIVE_PATH="$FIXTURE_HOME/.bun/bin:$FIXTURE_HOME/.cargo/bin:$FIXTURE_HOME/.local/bin"

  mkdir -p "$FIXTURE_HOME"/{.local/bin,.cargo/bin,.bun/bin} "$BREW_PREFIX/bin"
  printf ':\n' > "$FIXTURE_HOME/.bashrc.local"

  # Redirect only the fixed Linuxbrew executable in an isolated copy. Neither
  # a real host installation nor the caller's Homebrew variables can leak in.
  FIXTURE_BASHRC="$BATS_TEST_TMPDIR/bashrc"
  grep -Fq '/home/linuxbrew/.linuxbrew/bin/brew' "$BASHRC"
  sed -E 's@"?/home/linuxbrew/\.linuxbrew/bin/brew"?@"${FIXTURE_BREW}"@g' "$BASHRC" > "$FIXTURE_BASHRC"
}

install_brew_fixture() {
  mkdir -p "$BREW_BASH_BIN" "$BREW_PREFIX/sbin"
  cat > "$BREW_PREFIX/bin/brew" <<'BREW'
#!/bin/bash
[[ "$1" == shellenv ]] || exit 98
prefix=${0%/bin/brew}
# Model the PATH behavior in Homebrew/brew's Library/Homebrew/cmd/shellenv.sh.
case "$PATH:" in
  "$prefix/bin:$prefix/sbin:"*) ;;
  *)
    printf 'export HOMEBREW_PREFIX=%q\n' "$prefix"
    printf 'export PATH=%q\n' "$prefix/bin:$prefix/sbin:$PATH"
    ;;
esac
BREW
  printf '#!/bin/sh\nexit 97\n' > "$FIXTURE_HOME/.cargo/bin/bash"
  chmod +x "$BREW_PREFIX/bin/brew" "$FIXTURE_HOME/.cargo/bin/bash"
  ln -s /bin/bash "$BREW_BASH_BIN/bash"
}

capture_startup() {
  local bashrc="${2:-$FIXTURE_BASHRC}"
  run --separate-stderr env -i HOME="$FIXTURE_HOME" PATH="$1" \
    XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime" FIXTURE_BREW="$BREW_PREFIX/bin/brew" \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    /bin/bash --noprofile --norc -c '
      # Do not run optional prompt or version-manager integrations from the host.
      command() {
        case "$1:${2:-}" in
          -v:mise|-v:asdf|-v:starship|-v:direnv) return 1 ;;
          *) builtin command "$@" ;;
        esac
      }
      source "$1" || exit
      printf "%s\n" "$PATH"
      command -v bash || exit
      source "$1" || exit
      printf "%s\n" "$PATH"
      command -v bash || exit
    ' -- "$bashrc"
  [[ "$status" -eq 0 ]]
  [[ -z "$stderr" ]]
  [[ "${#lines[@]}" -eq 4 ]]
}

assert_path_stable() {
  if [[ "${lines[0]}" != "${lines[2]}" ]]; then
    printf 'PATH changed after the second source:\n  first:  %s\n  second: %s\n' "${lines[0]}" "${lines[2]}" >&2
    return 1
  fi
}

@test "Linux bashrc preserves first-source PATH precedence without Linuxbrew" {
  capture_startup "$ORIGINAL_PATH"
  [[ "${lines[0]}" == "$NATIVE_PATH:$ORIGINAL_PATH" ]]
}

@test "Linux bashrc keeps the entire PATH unchanged on re-source without Linuxbrew" {
  capture_startup "$ORIGINAL_PATH"
  assert_path_stable
}

@test "Linux bashrc selects Homebrew Bash even when its bin is inherited after system Bash" {
  install_brew_fixture
  capture_startup "$ORIGINAL_PATH:$BREW_BASH_BIN"
  [[ "${lines[1]}" == "$BREW_BASH_BIN/bash" ]]
  [[ "${lines[3]}" == "$BREW_BASH_BIN/bash" ]]
}

@test "Linux bashrc keeps the entire PATH unchanged on re-source with Linuxbrew" {
  install_brew_fixture
  capture_startup "$ORIGINAL_PATH"
  [[ "${lines[0]}" == "$BREW_BASH_BIN:$NATIVE_PATH:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$ORIGINAL_PATH" ]]
  assert_path_stable
}

@test "Linux bashrc initializes Homebrew despite an inherited bin/sbin-first PATH" {
  install_brew_fixture
  capture_startup "$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$ORIGINAL_PATH"
  [[ "${lines[0]}" == "$BREW_BASH_BIN:$NATIVE_PATH:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$ORIGINAL_PATH" ]]
  [[ "${lines[1]}" == "$BREW_BASH_BIN/bash" ]]
  [[ "${lines[3]}" == "$BREW_BASH_BIN/bash" ]]
  assert_path_stable
}

@test "Linux bashrc ignores output and preserves existing Brew bin/sbin positions when shellenv fails" {
  install_brew_fixture
  cat > "$BREW_PREFIX/bin/brew" <<'BREW'
#!/bin/bash
printf 'export HOMEBREW_PREFIX=%q\n' "${0%/bin/brew}"
printf 'export PATH=%q\n' "/unexpected-path:$PATH"
exit 42
BREW
  local inherited="$ORIGINAL_PATH:$BREW_PREFIX/bin:$BREW_PREFIX/sbin"
  capture_startup "$inherited"
  [[ "${lines[0]}" == "$NATIVE_PATH:$inherited" ]]
  [[ "${lines[1]}" == "$FIXTURE_HOME/.cargo/bin/bash" ]]
  assert_path_stable
}

@test "Linux bashrc re-source is stable with the real Linuxbrew shellenv" {
  local prefix=/home/linuxbrew/.linuxbrew
  local bash_bin="$prefix/opt/bash/bin"
  [[ -x "$prefix/bin/brew" && -x "$bash_bin/bash" ]] ||
    skip 'real Linuxbrew and its Bash are required for this integration case'
  capture_startup "$prefix/bin:$prefix/sbin:$ORIGINAL_PATH" "$BASHRC"
  [[ "${lines[0]}" == "$bash_bin:$NATIVE_PATH:$prefix/bin:$prefix/sbin:$ORIGINAL_PATH" ]]
  [[ "${lines[1]}" == "$bash_bin/bash" ]]
  [[ "${lines[3]}" == "$bash_bin/bash" ]]
  assert_path_stable
}
