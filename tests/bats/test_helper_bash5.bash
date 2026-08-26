#!/usr/bin/env bash
# shellcheck shell=bash

resolve_bash5() {
  local candidate="${BASH5_BIN:-}"
  local major

  if [[ -z "$candidate" ]]; then
    candidate="$(type -P bash)" || {
      printf 'Bash 5 test prerequisite failed: bash was not found on PATH.\n' >&2
      return 1
    }
  fi

  if [[ "$candidate" != /* || ! -x "$candidate" ]]; then
    printf 'Bash 5 test prerequisite failed: BASH5_BIN must be an executable absolute path: %s\n' \
      "$candidate" >&2
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
