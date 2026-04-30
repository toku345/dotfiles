#!/usr/bin/env bash
# shellcheck shell=bash
# PostToolUse hook: after Edit/Write to *.fish, run `fish -n` to catch
# syntax errors. No-op if fish is not installed or the file is not fish.
#
# Wired in .claude/settings.local.json with matcher "Edit|Write".

set -euo pipefail

if ! payload=$(cat); then
  exit 0
fi

file=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null || echo "")
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0

case "$file" in
  *.fish) ;;
  *) exit 0 ;;
esac

command -v fish >/dev/null 2>&1 || exit 0

if out=$(fish -n "$file" 2>&1); then
  exit 0
fi

jq -n --arg file "$file" --arg out "$out" '{
  decision: "block",
  reason: ("fish -n syntax error in " + $file + ":\n" + $out),
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $out
  }
}'
exit 0
