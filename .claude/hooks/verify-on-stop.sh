#!/usr/bin/env bash
# shellcheck shell=bash
# Stop hook: validate uncommitted changes against repo gates before allowing
# Claude to stop. Skips when relevant tools are unavailable or no relevant
# files changed. Anti-infinite-loop guard auto-allows after MAX_BLOCKS
# consecutive blocks.
#
# Wired in .claude/settings.local.json (machine-local). Project-shared
# script per CLAUDE.md split: scripts are project assets, wiring is local.

set -euo pipefail

readonly STATE_FILE="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.stop-hook-block-count"
readonly MAX_BLOCKS=3

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 0

# Drain stdin so the upstream pipe never blocks. We don't use the payload.
cat >/dev/null

mapfile -t changed < <({
  git diff --name-only HEAD 2>/dev/null
  git ls-files --others --exclude-standard 2>/dev/null
} | sort -u)

bats_changed=()
shell_changed=()
fish_changed=()
for f in "${changed[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    tests/bats/*.bats|tests/bats/test_helper*.bash|tests/bats/bin/*) bats_changed+=("$f") ;;
    dot_local/bin/executable_*|.chezmoiscripts/*.sh)                  shell_changed+=("$f") ;;
    *.fish)                                                            fish_changed+=("$f") ;;
  esac
done

if [ ${#bats_changed[@]} -eq 0 ] \
   && [ ${#shell_changed[@]} -eq 0 ] \
   && [ ${#fish_changed[@]} -eq 0 ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

count=0
[ -f "$STATE_FILE" ] && count=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
if [ "$count" -ge "$MAX_BLOCKS" ]; then
  rm -f "$STATE_FILE"
  echo "verify-on-stop: blocked $count times consecutively, allowing stop." >&2
  exit 0
fi

errors=()

if [ ${#bats_changed[@]} -gt 0 ] && command -v bats >/dev/null 2>&1; then
  if ! out=$(bats tests/bats/ 2>&1); then
    errors+=("bats failed:"$'\n'"$out")
  fi
fi

if [ ${#shell_changed[@]} -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
  shell_targets=()
  for f in "${shell_changed[@]}"; do
    head=$(head -n1 "$f" 2>/dev/null || true)
    if [[ "$head" =~ ^#!.*[[:space:]/](bash|sh|dash|ksh|zsh)([[:space:]]|$) ]]; then
      shell_targets+=("$f")
    fi
  done
  if [ ${#shell_targets[@]} -gt 0 ]; then
    if ! out=$(shellcheck --severity=warning "${shell_targets[@]}" 2>&1); then
      errors+=("shellcheck failed:"$'\n'"$out")
    fi
  fi
fi

if [ ${#fish_changed[@]} -gt 0 ] && command -v fish >/dev/null 2>&1; then
  for f in "${fish_changed[@]}"; do
    if ! out=$(fish -n "$f" 2>&1); then
      errors+=("fish -n $f:"$'\n'"$out")
    fi
  done
fi

if [ ${#errors[@]} -eq 0 ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")"
echo $((count + 1)) > "$STATE_FILE"
{
  echo "verify-on-stop blocked stop ($((count + 1))/$MAX_BLOCKS):"
  printf '%s\n\n' "${errors[@]}"
  echo "Fix issues before stopping. After $MAX_BLOCKS consecutive blocks the hook auto-allows."
} >&2
exit 2
