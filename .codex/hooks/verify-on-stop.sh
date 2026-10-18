#!/usr/bin/env bash
# shellcheck shell=bash
# Codex Stop adapter. Keep runtime root, input and state explicit.
set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/hooks/verify-on-stop-common.sh"

if ! cd "$repo_root"; then
  echo "verify-on-stop: cannot cd to project dir; allowing stop." >&2
  exit 0
fi

STATE_FILE=$(state_path_for_project codex block-count)
NAG_STATE_FILE=$(state_path_for_project codex bats-reminder-count)
readonly STATE_FILE NAG_STATE_FILE

# Drain the runtime payload; Stop validation does not use its contents.
cat >/dev/null
verify_changed_files_on_stop "$STATE_FILE" "$NAG_STATE_FILE"
