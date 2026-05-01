#!/usr/bin/env bash
# shellcheck shell=bash
# Stop hook: validate uncommitted changes against repo gates before allowing
# Claude to stop. Skips when relevant tools are unavailable or no relevant
# files changed. Anti-infinite-loop guard auto-allows after MAX_BLOCKS
# consecutive blocks.
#
# Wired in .claude/settings.local.json (machine-local). Project-shared
# script per CLAUDE.md split: scripts are project assets, wiring is local.

set -Eeuo pipefail

readonly STATE_FILE="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/.stop-hook-block-count"
readonly MAX_BLOCKS=3

if ! cd "${CLAUDE_PROJECT_DIR:-$PWD}"; then
  echo "verify-on-stop: cannot cd to project dir; allowing stop." >&2
  exit 0
fi

# Drain stdin so the upstream pipe never blocks. We don't use the payload.
cat >/dev/null

# git failures here mean the repo is broken; surface them rather than swallowing.
mapfile -t changed < <({
  git diff --name-only HEAD
  git ls-files --others --exclude-standard
} | sort -u)

bats_changed=()
shell_changed=()
fish_changed=()
for f in "${changed[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    tests/bats/*.bats)                                                 bats_changed+=("$f") ;;
    tests/bats/test_helper*.bash|tests/bats/bin/*)                     bats_changed+=("$f"); shell_changed+=("$f") ;;
    dot_local/bin/executable_*|.chezmoiscripts/*.sh)                   shell_changed+=("$f") ;;
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
if [ -f "$STATE_FILE" ]; then
  raw=$(cat "$STATE_FILE")
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    count="$raw"
  else
    echo "verify-on-stop: state file corrupted ($STATE_FILE='$raw'); resetting." >&2
    rm -f "$STATE_FILE"
  fi
fi
if [ "$count" -ge "$MAX_BLOCKS" ]; then
  rm -f "$STATE_FILE"
  echo "verify-on-stop: blocked $count times consecutively, allowing stop." >&2
  exit 0
fi

errors=()

if [ ${#bats_changed[@]} -gt 0 ]; then
  if command -v bats >/dev/null 2>&1; then
    if ! out=$(bats tests/bats/ 2>&1); then
      errors+=("bats failed:"$'\n'"$out")
    fi
  else
    echo "verify-on-stop: bats not installed; skipping bats gate." >&2
  fi
fi

if [ ${#shell_changed[@]} -gt 0 ]; then
  if command -v shellcheck >/dev/null 2>&1; then
    shell_targets=()
    for f in "${shell_changed[@]}"; do
      case "$f" in
        tests/bats/test_helper*.bash|tests/bats/bin/*)
          shell_targets+=("$f")
          continue
          ;;
      esac
      if [ ! -r "$f" ]; then
        echo "verify-on-stop: $f not readable; skipping shebang detection." >&2
        continue
      fi
      head=$(head -n1 "$f")
      if [[ "$head" =~ ^#!.*[[:space:]/](bash|sh|dash|ksh|zsh)([[:space:]]|$) ]]; then
        shell_targets+=("$f")
      fi
    done
    if [ ${#shell_targets[@]} -gt 0 ]; then
      if ! out=$(shellcheck --severity=warning "${shell_targets[@]}" 2>&1); then
        errors+=("shellcheck failed:"$'\n'"$out")
      fi
    fi
  else
    echo "verify-on-stop: shellcheck not installed; skipping shell gate." >&2
  fi
fi

if [ ${#fish_changed[@]} -gt 0 ]; then
  if command -v fish >/dev/null 2>&1; then
    for f in "${fish_changed[@]}"; do
      if ! out=$(fish -n "$f" 2>&1); then
        errors+=("fish -n $f:"$'\n'"$out")
      fi
    done
  else
    echo "verify-on-stop: fish not installed; skipping fish gate." >&2
  fi
fi

if [ ${#errors[@]} -eq 0 ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")"
# Atomic write so a concurrent Stop hook cannot read a half-written count.
tmp="$STATE_FILE.tmp.$$"
echo $((count + 1)) > "$tmp"
mv "$tmp" "$STATE_FILE"
{
  echo "verify-on-stop blocked stop ($((count + 1))/$MAX_BLOCKS):"
  printf '%s\n\n' "${errors[@]}"
  echo "Fix issues before stopping. After $MAX_BLOCKS consecutive blocks the hook auto-allows."
} >&2
exit 2
