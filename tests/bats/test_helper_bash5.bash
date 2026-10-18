#!/usr/bin/env bash
# shellcheck shell=bash

resolve_bash5() {
  local candidate="${BASH5_BIN:-}"
  local major homebrew_bash

  homebrew_bash="$(brew --prefix)/opt/bash/bin/bash" || return 1

  if [[ -z "$candidate" ]]; then
    candidate="$homebrew_bash"
  fi

  if [[ "$candidate" != /* || ! -x "$candidate" ]]; then
    printf 'Bash 5 test prerequisite failed: BASH5_BIN must be an executable absolute path: %s\n' \
      "$candidate" >&2
    return 1
  fi

  if [[ ! "$candidate" -ef "$homebrew_bash" ]]; then
    printf 'Bash 5 test prerequisite failed: %s is not Homebrew Bash (%s).\n' \
      "$candidate" "$homebrew_bash" >&2
    return 1
  fi

  major="$("$candidate" -c 'printf "%s\n" "${BASH_VERSINFO[0]}"')" || {
    printf 'Bash 5 test prerequisite failed: could not execute %s.\n' "$candidate" >&2
    return 1
  }

  if [[ ! "$major" =~ ^[0-9]+$ ]] || (( major < 5 )); then
    printf 'Bash 5 test prerequisite failed: %s reports major version %s.\n' \
      "$candidate" "$major" >&2
    return 1
  fi

  BASH5_BIN="$candidate"
  export BASH5_BIN
}
