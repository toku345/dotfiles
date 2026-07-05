#!/usr/bin/env bash
# shellcheck shell=bash
# Codex Stop hook: validate uncommitted shell-related changes before allowing
# the turn to stop. Skips when relevant tools are unavailable or no relevant
# files changed. Anti-infinite-loop guard auto-allows after MAX_BLOCKS
# consecutive blocks.

set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
readonly MAX_BLOCKS=3

state_file_for_project() {
  local app="$1"
  local project_path state_home repo_key

  project_path=$(pwd -P)
  # Only honor an absolute XDG_STATE_HOME. This runs after we cd into the
  # project dir, so a relative value would resolve the loop-guard counter
  # inside the worktree — reintroducing the pollution this indirection avoids.
  if [[ "${XDG_STATE_HOME:-}" = /* ]]; then
    state_home="$XDG_STATE_HOME"
  elif [[ "${HOME:-}" = /* ]]; then
    state_home="$HOME/.local/state"
  else
    state_home="/tmp/${app}-hooks-state"
  fi
  repo_key=$(printf '%s' "$project_path" | cksum | awk '{print $1}')
  printf '%s/%s/project-hooks/stop-hook-block-count.%s\n' \
    "$state_home" "$app" "$repo_key"
}

remove_state_file() {
  rm -f "$STATE_FILE" 2>/dev/null \
    || echo "verify-on-stop: cannot remove loop-guard state ($STATE_FILE); continuing." >&2
}

if ! cd "$repo_root"; then
  echo "verify-on-stop: cannot cd to project dir; allowing stop." >&2
  exit 0
fi
STATE_FILE=$(state_file_for_project codex)
readonly STATE_FILE

# Drain stdin so the upstream pipe never blocks. We don't use the payload.
cat >/dev/null

if ! git_output=$( {
    git diff --name-only HEAD && \
    git ls-files --others --exclude-standard;
  } | sort -u ); then
  echo "verify-on-stop: git enumeration failed; blocking stop." >&2
  exit 2
fi
mapfile -t changed <<<"$git_output"
if [ ${#changed[@]} -eq 1 ] && [ -z "${changed[0]}" ]; then
  changed=()
fi

bats_changed=()
shell_changed=()
fish_changed=()
for f in "${changed[@]}"; do
  case "$f" in
    tests/bats/bin/*|tests/bats/*.bash)
      bats_changed+=("$f")
      [ -f "$f" ] && shell_changed+=("$f")
      ;;
    tests/bats/*)
      bats_changed+=("$f")
      ;;
    dot_local/bin/executable_*|.chezmoiscripts/*.sh|.codex/hooks/*.sh)
      [ -f "$f" ] && shell_changed+=("$f")
      ;;
    *.fish)
      [ -f "$f" ] && fish_changed+=("$f")
      ;;
  esac
done

if [ ${#bats_changed[@]} -eq 0 ] \
   && [ ${#shell_changed[@]} -eq 0 ] \
   && [ ${#fish_changed[@]} -eq 0 ]; then
  remove_state_file
  exit 0
fi

count=0
if [ -L "$STATE_FILE" ]; then
  echo "verify-on-stop: state file is a symlink; resetting." >&2
  remove_state_file
elif [ -f "$STATE_FILE" ]; then
  raw=""
  if IFS= read -r raw < "$STATE_FILE" || [ -n "$raw" ]; then
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      count="$raw"
    else
      echo "verify-on-stop: state file corrupted; resetting." >&2
      remove_state_file
    fi
  else
    echo "verify-on-stop: state file corrupted; resetting." >&2
    remove_state_file
  fi
fi
if [ "$count" -ge "$MAX_BLOCKS" ]; then
  remove_state_file
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
        tests/bats/bin/*|tests/bats/*.bash|.codex/hooks/*.sh)
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
  remove_state_file
  exit 0
fi

# Persist the incremented counter outside the worktree, atomically so a
# concurrent Stop hook never reads a half-written count. If the state home is
# unwritable (e.g. an absolute but read-only XDG_STATE_HOME), fail loud AND
# open: a counter we cannot advance would defeat the MAX_BLOCKS auto-allow and
# could trap the turn in a stop loop.
tmp="$STATE_FILE.tmp.$$"
if ! { mkdir -p "$(dirname "$STATE_FILE")" \
       && echo $((count + 1)) > "$tmp" \
       && mv "$tmp" "$STATE_FILE"; } 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null || true
  {
    echo "verify-on-stop: cannot persist loop-guard state ($STATE_FILE); allowing stop."
    echo "verify-on-stop: verification failures were not enforced:"
    printf '%s\n\n' "${errors[@]}"
  } >&2
  exit 0
fi
{
  echo "verify-on-stop blocked stop ($((count + 1))/$MAX_BLOCKS):"
  printf '%s\n\n' "${errors[@]}"
  echo "Fix issues before stopping. After $MAX_BLOCKS consecutive blocks the hook auto-allows."
} >&2
exit 2
