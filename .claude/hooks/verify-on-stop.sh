#!/usr/bin/env bash
# shellcheck shell=bash
# Claude Stop adapter. Keep runtime root, input and state explicit.
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/hooks/verify-on-stop-common.sh"

if ! cd "${CLAUDE_PROJECT_DIR:-$PWD}"; then
  echo "verify-on-stop: cannot cd to project dir; allowing stop." >&2
  exit 0
fi

STATE_FILE=$(state_path_for_project claude block-count)
readonly STATE_FILE

# Drain the runtime payload; Stop validation does not use its contents.
cat >/dev/null
verify_changed_files_on_stop "$STATE_FILE"
