# shellcheck shell=bash

make_reviewed_binary() {
  local path="$1"
  mkdir -p "${path%/*}"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >>"$SMOKE_STUB_LOG"
if [[ "${1:-}" == --version && "${CHECK_FIRST_FAIL:-false}" == true ]]; then exit 2; fi
if grep -Fq -- '--no-ask' "$BREW_STUB_LOG"; then exit "${CHECK_POST_STATUS:-0}"; fi
printf 'test version\n'
EOF
  chmod +x "$path"
}

prepare_formula_auto_check() {
  local version
  mkdir -p "$TEST_PREFIX/opt"
  for version in 1.0 2.0; do
    make_reviewed_binary "$TEST_PREFIX/Cellar/$BREW_STUB_FORMULA/$version/bin/$BREW_STUB_FORMULA"
  done
  ln -s "$TEST_PREFIX/Cellar/$BREW_STUB_FORMULA/1.0" "$TEST_PREFIX/opt/$BREW_STUB_FORMULA"
}

prepare_cask_auto_check() {
  local version
  mkdir -p "$TEST_PREFIX/bin"
  for version in 1.0.0 2.0.0; do
    make_reviewed_binary "$BREW_STUB_CASKROOM/$version/bin/codex"
  done
  ln -s "$BREW_STUB_CASKROOM/1.0.0/bin/codex" "$TEST_PREFIX/bin/codex"
}

remember_manual_check() {
  local kind="$1" name="$2"
  shift 2
  "$BASH5_BIN" -c '
    source "$SOURCE"
    JQ_BIN="$(type -P jq)"
    br_settings_init "$1" "$2"
    shift 2
    br_save_check manual "$@"
  ' -- "$kind" "$name" "$@" >/dev/null
}
