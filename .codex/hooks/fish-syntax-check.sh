#!/usr/bin/env bash
# shellcheck shell=bash
# Codex PostToolUse hook: after Edit/Write to *.fish, run `fish -n` to
# catch syntax errors. No-op if fish is not installed or the payload does
# not identify a fish file.

set -Eeuo pipefail

if ! payload=$(cat); then
  echo "fish-syntax-check: failed to read hook payload; skipping." >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fish-syntax-check: jq not installed; skipping." >&2
  exit 0
fi

if ! file=$(jq -er '.tool_input.file_path // empty' <<<"$payload"); then
  # `jq -e` returns non-zero on null/empty. That just means this payload
  # does not include a file path we care about.
  exit 0
fi
[ -n "$file" ] || exit 0
[ -f "$file" ] || exit 0

case "$file" in
  *.fish) ;;
  *) exit 0 ;;
esac

if ! command -v fish >/dev/null 2>&1; then
  echo "fish-syntax-check: fish not installed; skipping $file." >&2
  exit 0
fi

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
