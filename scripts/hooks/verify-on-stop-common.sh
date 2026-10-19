#!/usr/bin/env bash
# shellcheck shell=bash
# Project-only Stop validation shared by the Claude and Codex adapters.
# Never load or execute test files here. The adapters own root, I/O and state.

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

  # `mv <file> <directory>` succeeds by nesting the file under the directory,
  # leaving the intended counter unchanged. Reject every existing node except
  # a regular file so the caller's bounded fail-open path handles it instead.
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    return 1
  fi

  if ! { mkdir -p "$(dirname "$path")" \
         && echo "$value" > "$tmp" \
         && mv "$tmp" "$path"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

verify_changed_files_on_stop() {
  local state_file="$1"
  # git failures here mean the repo is broken; surface them rather than
  # swallowing. Process substitution would hide the producer's exit status
  # (pipefail does not cross `< <(...)`), so capture via command substitution
  # and short-circuit the brace group with `&&` to ensure either git failure
  # propagates through pipefail to the `if !` branch.
  if ! git_output=$( {
      git diff --name-only HEAD && \
      git ls-files --others --exclude-standard;
    } | sort -u ); then
    echo "verify-on-stop: git enumeration failed; blocking stop." >&2
    exit 2
  fi
  mapfile -t changed <<<"$git_output"
  # A heredoc on empty input produces a single empty element; drop it so the
  # downstream emptiness check correctly identifies "no changed files".
  if [ ${#changed[@]} -eq 1 ] && [ -z "${changed[0]}" ]; then
    changed=()
  fi

  bats_changed=()
  shell_changed=()
  fish_changed=()
  # Classification is content-agnostic: a deletion under tests/bats/ should
  # still trigger the bats advisory (a removed test_helper.bash can break other
  # tests via coupling). The existence guard is applied per-operation —
  # only shellcheck and `fish -n` need a readable file; the bats advisory only
  # needs to know that the tree changed.
  for f in "${changed[@]}"; do
    case "$f" in
      # Shell helpers / stub binaries also need shellcheck. Match these
      # before the broader `tests/bats/*` pattern below, since case stops
      # at the first match — otherwise the broad pattern would shadow the
      # shell-specific append.
      tests/bats/bin/*|tests/bats/*.bash)
        bats_changed+=("$f")
        [ -f "$f" ] && shell_changed+=("$f")
        ;;
      # Catch every other file under tests/bats/ — including fixtures,
      # snapshots, and *.bats — since any of them can change a test
      # outcome and so must trigger the bats advisory.
      tests/bats/*)
        bats_changed+=("$f")
        ;;
      dot_local/bin/executable_*|.chezmoiscripts/*.sh|.claude/hooks/*.sh|.codex/hooks/*.sh|scripts/hooks/*.sh|dot_local/lib/*.sh)
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
    remove_state_file "$state_file"
    exit 0
  fi

  count=$(read_block_count "$state_file")
  if [ "$count" -ge "$MAX_BLOCKS" ]; then
    remove_state_file "$state_file"
    echo "verify-on-stop: blocked $count times consecutively, allowing stop." >&2
    exit 0
  fi

  # Only executing checks can block. The advisory has no persistent state.
  errors=()
  bats_advisory=0

  if [ ${#bats_changed[@]} -gt 0 ]; then
    if command -v bats >/dev/null 2>&1; then
      # Never run the suite from here. A Stop hook fires automatically at the
      # end of a turn, outside the permission system and outside the sandbox
      # that Bash tool calls run under, and `bats tests/bats/` executes every
      # discovered .bats test plus the shell helpers those tests load or source.
      # Running it here would turn any write under tests/bats/ — routinely
      # auto-approved — into unprompted command execution. Verification belongs
      # in ordinary tool calls; this user-facing advisory cannot determine its
      # result or require another agent turn.
      bats_advisory=1
    else
      # Preserve the missing-tool diagnostic without suggesting a local run
      # that this environment cannot perform.
      echo "verify-on-stop: bats not installed; skipping bats gate." >&2
    fi
  fi

  if [ ${#shell_changed[@]} -gt 0 ]; then
    if command -v shellcheck >/dev/null 2>&1; then
      shell_targets=()
      for f in "${shell_changed[@]}"; do
        case "$f" in
          # All bats helper bash files and stub binaries: source-style
          # helpers conventionally lack shebangs, so bypass the shebang
          # sniff and shellcheck them unconditionally. The pattern must
          # mirror the wider `tests/bats/*.bash` rule above so a new
          # helper like `tests/bats/utils.bash` is not silently dropped.
          tests/bats/bin/*|tests/bats/*.bash|.claude/hooks/*.sh|.codex/hooks/*.sh|scripts/hooks/*.sh|dot_local/lib/*.sh)
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
    remove_state_file "$state_file"
    if [ "$bats_advisory" -eq 1 ]; then
      # Static JSON needs no encoder dependency. Do not add runtime values here
      # without JSON escaping, or control fields that resume/stop the agent.
      printf '%s\n' '{"systemMessage":"Bats changes detected. Run `bats tests/bats/` through normal tool permissions and report results or unrun checks. This hook does not verify test status."}'
    fi
    exit 0
  fi

  # Persist the executing-gate counter. If it cannot advance, fail loud and
  # open: blocking without a working MAX_BLOCKS guard could trap the turn.
  if ! persist_block_count "$state_file" $((count + 1)); then
    {
      echo "verify-on-stop: cannot persist loop-guard state ($state_file); allowing stop."
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
}
