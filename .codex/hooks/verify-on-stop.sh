#!/usr/bin/env bash
# shellcheck shell=bash
# Codex Stop hook: validate uncommitted shell-related changes before allowing
# the turn to stop. Skips when relevant tools are unavailable or no relevant
# files changed. Anti-infinite-loop guard auto-allows after MAX_BLOCKS
# consecutive blocks.

set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
readonly MAX_BLOCKS=3

state_path_for_project() {
  local app="$1"
  local name="$2"
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
  printf '%s/%s/project-hooks/stop-hook-%s.%s\n' \
    "$state_home" "$app" "$name" "$repo_key"
}

remove_state_file() {
  local path="$1"
  rm -f "$path" 2>/dev/null \
    || echo "verify-on-stop: cannot remove loop-guard state ($path); continuing." >&2
}

# Read a loop-guard counter, resetting anything that is not a plain number.
# Writes diagnostics to stderr and the count to stdout.
read_block_count() {
  local path="$1"
  local raw count=0

  if [ -L "$path" ]; then
    echo "verify-on-stop: state file is a symlink; resetting." >&2
    remove_state_file "$path"
  elif [ -f "$path" ]; then
    if raw=$(<"$path"); then
      if [[ "$raw" =~ ^[0-9]+$ ]]; then
        count="$raw"
      else
        echo "verify-on-stop: state file corrupted; resetting." >&2
        remove_state_file "$path"
      fi
    else
      echo "verify-on-stop: state file corrupted; resetting." >&2
      remove_state_file "$path"
    fi
  fi
  printf '%s' "$count"
}

# Atomically persist a counter so a concurrent Stop hook never reads a
# half-written value. Returns non-zero when the state home is unwritable.
persist_block_count() {
  local path="$1"
  local value="$2"
  local tmp="$path.tmp.$$"

  if ! { mkdir -p "$(dirname "$path")" \
         && echo "$value" > "$tmp" \
         && mv "$tmp" "$path"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

if ! cd "$repo_root"; then
  echo "verify-on-stop: cannot cd to project dir; allowing stop." >&2
  exit 0
fi
# Two independent loop-guard counters. The executing gates (shellcheck,
# `fish -n`) keep the original file — they block only when something really
# failed. The bats reminder gets its own budget because it fires on every stop
# while tests/bats/ is dirty, whether or not anything is wrong: sharing one
# counter would let the reminder burn the executing gates' budget and
# auto-allow a genuine shellcheck failure early.
STATE_FILE=$(state_path_for_project codex block-count)
NAG_STATE_FILE=$(state_path_for_project codex bats-reminder-count)
readonly STATE_FILE NAG_STATE_FILE

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
  remove_state_file "$STATE_FILE"
  remove_state_file "$NAG_STATE_FILE"
  exit 0
fi

count=$(read_block_count "$STATE_FILE")
nag_count=$(read_block_count "$NAG_STATE_FILE")
if [ "$count" -ge "$MAX_BLOCKS" ]; then
  remove_state_file "$STATE_FILE"
  remove_state_file "$NAG_STATE_FILE"
  echo "verify-on-stop: blocked $count times consecutively, allowing stop." >&2
  exit 0
fi

# errors[]: an executing gate actually failed. notices[]: nothing ran, we are
# only telling the agent to run something. They block through separate budgets.
errors=()
notices=()

if [ ${#bats_changed[@]} -gt 0 ]; then
  if command -v bats >/dev/null 2>&1; then
    # Never run the suite from here. A Stop hook fires automatically at the
    # end of a turn, outside the permission system and outside the sandbox
    # that tool-issued commands run under, and `bats tests/bats/` sources and
    # executes every .bats/.bash file in that tree as shell code. Running it
    # here would turn any write under tests/bats/ — routinely auto-approved —
    # into unprompted command execution. Block instead, so the suite runs
    # through the normal permission-gated path where that decision is made.
    bats_msg="bats gate requires a gated run (files under tests/bats/ changed):"
    bats_msg+=$'\n''Run `bats tests/bats/` as a normal command, so the run goes through the permission/sandbox path this hook bypasses, then fix any failures.'
    bats_msg+=$'\n'"This hook cannot observe tool calls, so it reminds again on each stop until its own $MAX_BLOCKS-reminder auto-allow."
    notices+=("$bats_msg")
  else
    # The reminder needs no binary, but with bats absent the suite cannot be
    # run at all: blocking the turn with an instruction nobody can follow would
    # only burn the reminder budget. Skip, and leave verification to CI.
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

blocking=()
bump_errors=0
bump_nag=0

if [ ${#errors[@]} -gt 0 ]; then
  blocking+=("${errors[@]}")
  bump_errors=1
else
  remove_state_file "$STATE_FILE"
fi

if [ ${#notices[@]} -gt 0 ]; then
  if [ "$nag_count" -ge "$MAX_BLOCKS" ]; then
    remove_state_file "$NAG_STATE_FILE"
    echo "verify-on-stop: bats reminder issued $nag_count times consecutively, allowing stop." >&2
  else
    blocking+=("${notices[@]}")
    bump_nag=1
  fi
else
  remove_state_file "$NAG_STATE_FILE"
fi

if [ ${#blocking[@]} -eq 0 ]; then
  exit 0
fi

# Persist the incremented counters outside the worktree. If the state home is
# unwritable (e.g. an absolute but read-only XDG_STATE_HOME), fail loud AND
# open: a counter we cannot advance would defeat the MAX_BLOCKS auto-allow and
# could trap the turn in a stop loop.
persist_failed=""
if [ "$bump_errors" -eq 1 ] && ! persist_block_count "$STATE_FILE" $((count + 1)); then
  persist_failed="$STATE_FILE"
fi
if [ -z "$persist_failed" ] && [ "$bump_nag" -eq 1 ] \
   && ! persist_block_count "$NAG_STATE_FILE" $((nag_count + 1)); then
  persist_failed="$NAG_STATE_FILE"
fi
if [ -n "$persist_failed" ]; then
  {
    echo "verify-on-stop: cannot persist loop-guard state ($persist_failed); allowing stop."
    echo "verify-on-stop: verification failures were not enforced:"
    printf '%s\n\n' "${blocking[@]}"
  } >&2
  exit 0
fi
if [ "$bump_errors" -eq 1 ]; then
  header="verify-on-stop blocked stop ($((count + 1))/$MAX_BLOCKS):"
else
  header="verify-on-stop blocked stop (bats reminder $((nag_count + 1))/$MAX_BLOCKS):"
fi
{
  echo "$header"
  printf '%s\n\n' "${blocking[@]}"
  echo "Fix issues before stopping. After $MAX_BLOCKS consecutive blocks the hook auto-allows."
} >&2
exit 2
