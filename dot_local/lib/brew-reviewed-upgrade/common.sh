#!/usr/bin/env bash
# shellcheck shell=bash
# BREW_REVIEWED_COMMON_V2
# shellcheck disable=SC2034
# Exported globals and nameref outputs are consumed by the two callers.
# Shared settings and smoke selection; Homebrew mutation stays in the callers.

BR_LIB_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
BR_SETTINGS_ROOT=""
BR_SETTINGS_DIR=""
BR_SETTINGS_FILE=""
BR_SETTINGS_JSON='{"schema_version":1}'
BR_COOLDOWN_SOURCE=default
BR_CHECK_AUTO=0
BR_KIND=""
BR_TARGET=""
BR_AUTO_PATH=""
BR_AUTO_ROOT=""
BR_WORDS=()

# Result state belongs to the parent shell, not the managed command's process.
BR_RESULT_ENABLED=0
BR_RESULT_TARGET=""
BR_RESULT_ORDER=()
declare -A BR_RESULT_LABELS=() BR_RESULT_STATES=()

br_result_start() {
  local kind="$1" target="$2" no_check="$3" automatic="$4" id
  BR_RESULT_TARGET="$target"
  BR_RESULT_LABELS=(
    [bottle]='Bottle verification' [upgrade]='Upgrade command'
    [vulns]='Vulnerability check' [linkage]='Linkage check'
    [pre]='Pre-upgrade validation' [post]='Post-upgrade validation'
    [target]='Smoke target validation' [smoke]='Post-upgrade smoke check'
    [developer]='Developer-mode restoration' [temporary]='Temporary-file cleanup'
  )
  if [[ "$kind" == formula ]]; then
    BR_RESULT_ORDER=(bottle upgrade vulns linkage)
  else
    BR_RESULT_ORDER=(pre upgrade post)
  fi
  if (( automatic )); then BR_RESULT_ORDER+=(target); fi
  BR_RESULT_ORDER+=(smoke)
  if [[ "$kind" == formula ]]; then BR_RESULT_ORDER+=(developer); fi
  BR_RESULT_ORDER+=(temporary)
  BR_RESULT_STATES=()
  for id in "${BR_RESULT_ORDER[@]}"; do BR_RESULT_STATES[$id]='not run'; done
  if (( no_check )); then BR_RESULT_STATES[smoke]='waived (--no-check)'; fi
  BR_RESULT_ENABLED=1
}

br_result_skip() {
  if (( BR_RESULT_ENABLED )); then BR_RESULT_STATES[$1]="$2"; fi
}

br_result_record() {
  local id="$1" status="$2"
  if (( ! BR_RESULT_ENABLED )); then return 0; fi
  if (( status != 0 )); then
    BR_RESULT_STATES[$id]="failed (exit $status)"
  elif [[ "$id" == upgrade ]]; then
    BR_RESULT_STATES[$id]=completed
  else
    BR_RESULT_STATES[$id]=passed
  fi
}

br_result_run() {
  local id="$1" status
  shift
  if (( BR_RESULT_ENABLED )); then BR_RESULT_STATES[$id]=running; fi
  # Invoke functions directly: an extra subprocess would discard state changes.
  if "$@"; then status=0; else status=$?; fi
  br_result_record "$id" "$status"
  return "$status"
}

br_result_check_target() {
  local status
  if br_result_run target "$@"; then return 0; else status=$?; fi
  if (( BR_RESULT_ENABLED )); then
    BR_RESULT_STATES[smoke]='not run (target validation failed)'
  fi
  return "$status"
}

br_result_render() {
  local status="$1" id value
  printf '\n==> Result: %s\n' "$BR_RESULT_TARGET" >&2 || return 1
  for id in "${BR_RESULT_ORDER[@]}"; do
    value="${BR_RESULT_STATES[$id]}"
    if [[ "$id" == upgrade && "$value" != completed && "$value" != 'not run' ]]; then
      value+='; installation state uncertain, changes may have occurred'
    fi
    printf '%s: %s\n' "${BR_RESULT_LABELS[$id]}" "$value" >&2 || return 1
  done
  if (( status == 0 )); then
    printf '%s\n' 'Overall: completed' >&2 || return 1
  else
    printf 'Overall: incomplete (exit %s)\n' "$status" >&2 || return 1
  fi
}

br_result_finish() {
  local status="$1" cleanup_status="$2" id value
  if (( status == 0 && cleanup_status != 0 )); then status=1; fi
  if (( BR_RESULT_ENABLED )); then
    for id in "${BR_RESULT_ORDER[@]}"; do
      value="${BR_RESULT_STATES[$id]}"
      if [[ "$value" == running ]]; then
        if (( status == 130 || status == 143 )); then
          BR_RESULT_STATES[$id]="interrupted (exit $status)"
        else
          BR_RESULT_STATES[$id]='incomplete (completion unconfirmed)'
        fi
        if [[ "$id" == target ]]; then
          BR_RESULT_STATES[smoke]='not run (target validation incomplete)'
        fi
      fi
      case "$value" in
        passed|completed|'waived (--no-check)'|'not needed') ;;
        *) if (( status == 0 )); then status=1; fi ;;
      esac
    done
    BR_RESULT_ENABLED=0
    if ! br_result_render "$status"; then
      error 'could not display the result summary'
      if (( status == 0 )); then status=1; fi
    fi
  fi
  return "$status"
}

br_valid_hours() {
  # jq numbers are doubles: keep seconds exactly representable as well as
  # within signed Bash arithmetic. Reject oversized text before conversion.
  [[ "$1" =~ ^[0-9]+$ && ${#1} -le 13 ]] || return 1
  (( 10#$1 <= 2501999792983 ))
}

br_private_path() {
  local path="$1" expected="$2" mode
  [[ ! -L "$path" && -O "$path" ]] || {
    error "unsafe settings ownership or symlink: $path"; return 1;
  }
  if ! mode="$(stat -c '%a' -- "$path" 2>/dev/null)"; then
    mode="$(stat -f '%Lp' "$path")" || return 1
  fi
  [[ "$mode" == "$expected" ]] || {
    error "settings require mode $expected: $path"; return 1;
  }
}

br_settings_init() {
  local key base="${XDG_CONFIG_HOME:-$HOME/.config}"
  BR_KIND="$1" BR_TARGET="$2"
  [[ "$base" == /* && ! "$base" =~ [[:cntrl:]] ]] || {
    error 'XDG_CONFIG_HOME must be an absolute path without control characters'; return 1;
  }
  key="$("$JQ_BIN" -nr --arg name "$BR_TARGET" '$name | @uri')" || return 1
  BR_SETTINGS_ROOT="$base/brew-reviewed-upgrade"
  BR_SETTINGS_DIR="$BR_SETTINGS_ROOT/$BR_KIND"
  BR_SETTINGS_FILE="$BR_SETTINGS_DIR/$key.json"
  br_settings_read || return $?
  COOLDOWN_SECONDS=172800
  BR_COOLDOWN_SOURCE=default
  local hours
  hours="$("$JQ_BIN" -r '.cooldown_hours // empty' <<<"$BR_SETTINGS_JSON")" || return 1
  if [[ -n "$hours" ]]; then
    COOLDOWN_SECONDS=$((hours * 3600))
    BR_COOLDOWN_SOURCE="saved: $BR_SETTINGS_FILE"
  fi
}

br_settings_read() {
  local path
  for path in "$BR_SETTINGS_ROOT" "$BR_SETTINGS_DIR" "$BR_SETTINGS_FILE.lock"; do
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -d "$path" ]] && br_private_path "$path" 700 || return 1
    fi
  done
  BR_SETTINGS_JSON='{"schema_version":1}'
  if [[ ! -e "$BR_SETTINGS_FILE" && ! -L "$BR_SETTINGS_FILE" ]]; then return 0; fi
  [[ -f "$BR_SETTINGS_FILE" ]] && br_private_path "$BR_SETTINGS_FILE" 600 || return 1
  # Validate both optional fields without treating malformed settings as defaults.
  if ! BR_SETTINGS_JSON="$("$JQ_BIN" -cse '
    def text: type == "string" and (index("\u0000") == null);
    select(length == 1) | .[0]
    | select(type == "object" and .schema_version == 1
      and ((keys - ["schema_version", "cooldown_hours", "check"]) | length == 0)
      and (if has("cooldown_hours") then
        (.cooldown_hours | type == "number" and . >= 0 and . <= 2501999792983 and floor == .)
        else true end)
      and (if has("check") then (.check |
        type == "object" and ((keys - ["origin", "argv"]) | length == 0)
        and (.origin == "auto" or .origin == "manual")
        and (.argv | type == "array" and length > 0 and all(.[]; text))
        and (.argv[0] | length > 0)) else true end))
  ' "$BR_SETTINGS_FILE")"; then
    error "invalid settings (repair or remove this file): $BR_SETTINGS_FILE"; return 1
  fi
}

br_settings_write() (
  local field="$1" value="$2" dir lock rc=0 temporary=""
  umask 077
  for dir in "${BR_SETTINGS_ROOT%/*}" "$BR_SETTINGS_ROOT" "$BR_SETTINGS_DIR"; do
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
      mkdir -p -- "$dir" || return 1
    fi
    if [[ "$dir" != "${BR_SETTINGS_ROOT%/*}" ]]; then
      [[ -d "$dir" ]] && br_private_path "$dir" 700 || return 1
    fi
  done
  lock="$BR_SETTINGS_FILE.lock"
  if ! mkdir -- "$lock"; then
    error "settings are locked: $lock (do not remove while another helper is running)"; return 1
  fi
  trap 'rc=$?; [[ -z "$temporary" ]] || rm -f -- "$temporary"; rmdir -- "$lock" || rc=1; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Read only after acquiring the lock. Never persist an invocation's stale
  # snapshot of the other field (in particular a previous zero-hour policy).
  br_settings_read || return 1
  temporary="$(mktemp "$BR_SETTINGS_DIR/.settings.XXXXXX")" || return 1
  "$JQ_BIN" --arg field "$field" --argjson value "$value" '
    if $value == null then del(.[$field]) else .[$field] = $value end
  ' <<<"$BR_SETTINGS_JSON" >"$temporary" || return 1
  [[ ! -L "$BR_SETTINGS_FILE" && ! -d "$BR_SETTINGS_FILE" ]] || return 1
  mv -f -- "$temporary" "$BR_SETTINGS_FILE" || return 1
  temporary=""
  printf 'Saved %s: %s\n' "$field" "$BR_SETTINGS_FILE" || return 1
)

br_config_command() (
  local kind="$1" action="$2" value=null target canonical info
  shift 2
  case "$action" in
    --set-cooldown-hours)
      (( $# == 2 )) || { usage >&2; return 2; }
      if [[ "$1" != default ]]; then
        br_valid_hours "$1" || { error 'hours must be a nonnegative, exactly representable integer'; return 2; }
        value=$((10#$1))
      fi
      target="$2" ;;
    --forget-check)
      (( $# == 1 )) || { usage >&2; return 2; }
      target="$1" ;;
  esac
  [[ -n "$target" && "$target" != -* && ! "$target" =~ [[:space:][:cntrl:]] ]] || return 2
  BREW_BIN="$(resolve_command brew)" || return $?
  JQ_BIN="$(resolve_command jq)" || return $?
  info="$("$BREW_BIN" info "--$kind" --json=v2 "$target")" || return 1
  canonical="$("$JQ_BIN" -er --arg kind "$kind" '
    (if $kind == "formula" then .formulae else .casks end)
    | select(length == 1) | .[0]
    | select(.tap == (if $kind == "formula" then "homebrew/core" else "homebrew/cask" end))
    | (if $kind == "formula" then .full_name else .token end)
    | select(type == "string" and length > 0 and (test("[[:space:][:cntrl:]]") | not))
  ' <<<"$info")" || { error 'could not resolve an official package identity'; return 1; }
  br_settings_init "$kind" "$canonical" || return 1
  if [[ "$action" == --forget-check ]]; then
    br_settings_write check null
  else
    br_settings_write cooldown_hours "$value"
  fi
)

br_parse_words() {
  local input="$1" state=plain word="" present=0 char next i
  BR_WORDS=()
  for ((i=0; i<${#input}; i++)); do
    char="${input:i:1}"
    case "$state:$char" in
      "single:'"| 'double:"') state=plain ;;
      single:*) word+="$char" ;;
      "plain:'") state=single; present=1 ;;
      'plain:"') state=double; present=1 ;;
      'plain:\'|'double:\')
        (( i + 1 < ${#input} )) || { error 'unfinished escape'; return 2; }
        i=$((i + 1)); next="${input:i:1}"; word+="$next"; present=1 ;;
      'plain: ' | $'plain:\t')
        if (( present )); then BR_WORDS+=("$word"); word=""; present=0; fi ;;
      'plain:|'|'plain:&'|'plain:;'|'plain:<'|'plain:>'|'plain:`')
        error 'shell operators are not supported; specify a script instead'; return 2 ;;
      *) word+="$char"; present=1 ;;
    esac
  done
  [[ "$state" == plain ]] || { error 'unclosed quote'; return 2; }
  if (( present )); then BR_WORDS+=("$word"); fi
  (( ${#BR_WORDS[@]} > 0 )) && [[ -n "${BR_WORDS[0]}" ]] || { error 'enter a command'; return 2; }
}

br_realpath() (
  local path="$1" dir base link i
  [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || return 1
  for ((i=0; i<64; i++)); do
    if [[ -d "$path" ]]; then cd -P -- "$path" && pwd -P; return $?; fi
    dir="${path%/*}"; base="${path##*/}"
    dir="$(cd -P -- "${dir:-/}" && pwd -P)" || return 1
    path="${dir%/}/$base"
    if [[ ! -L "$path" ]]; then
      [[ -f "$path" ]] || return 1
      printf '%s\n' "$path"; return $?
    fi
    link="$(readlink "$path")" || return 1
    if [[ "$link" == /* ]]; then path="$link"; else path="$dir/$link"; fi
  done
  return 1
)

br_auto_path() {
  local receipt="$1" prefix name="${BR_TARGET##*/}" candidate root real cellar version relative expected data
  BR_AUTO_PATH=""
  prefix="$("$BREW_BIN" --prefix)" || return 1
  [[ "$prefix" == /* && ! "$prefix" =~ [[:cntrl:]] ]] || return 1
  if [[ "$BR_KIND" == formula ]]; then
    root="$(br_realpath "$prefix/opt/$name")" || return 1
    cellar="$("$BREW_BIN" --cellar "$BR_TARGET")" || return 1
    cellar="$(br_realpath "$cellar")" || return 1
    [[ "$root" == "$cellar/"* ]] || return 1
    candidate="$prefix/opt/$name/bin/$name"
    real="$(br_realpath "$candidate")" || return 1
    [[ "$real" == "$root/"* ]] || return 1
  else
    [[ -f "$receipt" ]] || return 1
    version="$("$JQ_BIN" -er '.source.version | select(type == "string" and length > 0 and (test("[[:cntrl:]]") | not))' "$receipt")" || return 1
    [[ "$version" != */* && "$version" != . && "$version" != .. ]] || return 1
    candidate="$prefix/bin/$name"
    data="$("$JQ_BIN" -ce --arg name "$name" --arg candidate "$candidate" '
      [.uninstall_artifacts[] | select(has("binary")) | .binary
       | select(type == "array" and (length == 1 or length == 2))
       | select(.[0] | type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
       | {source: .[0], target: (.[1].target // (.[0] | split("/") | last))}
       | select(.target == $name or .target == $candidate)]
      | select(length == 1) | .[0].source
    ' "$receipt")" || return 1
    relative="$("$JQ_BIN" -r . <<<"$data")" || return 1
    [[ "$relative" != /* && "$relative" != '~'* && ! "$relative" =~ [[:cntrl:]] ]] || return 1
    case "/$relative/" in */../*|*/./*) return 1 ;; esac
    root="$("$BREW_BIN" --caskroom "$BR_TARGET")" || return 1
    root="$(br_realpath "$root/$version")" || return 1
    expected="$(br_realpath "$root/$relative")" || return 1
    [[ "$expected" == "$root/"* && -L "$candidate" ]] || return 1
    real="$(br_realpath "$candidate")" || return 1
    [[ "$real" == "$expected" ]] || return 1
  fi
  [[ -x "$candidate" ]] || return 1
  BR_AUTO_PATH="$candidate"
  BR_AUTO_ROOT="$root"
}

br_probe() {
  local status
  printf 'Trying:' || return 1
  printf ' %q' "$@" || return 1
  printf '\n' || return 1
  if run_managed "$BASH" "$BR_LIB_DIR/probe.sh" "$@"; then return 0; else status=$?; fi
  if (( status == 130 || status == 143 )); then exit "$status"; fi
  error "check failed with status $status"
  return "$status"
}

br_save_check() {
  local origin="$1" json
  shift
  json="$("$JQ_BIN" -cn --arg origin "$origin" --args \
    '{origin: $origin, argv: $ARGS.positional}' -- "$@")" || return 1
  br_settings_write check "$json"
}

br_has_terminal() { [[ -t 0 ]]; }

br_select_check() {
  local -n selected_check="$1"
  local receipt="$2" origin saved input resolved option
  local -a proposed=() stored=()
  BR_CHECK_AUTO=0
  saved="$("$JQ_BIN" -c '.check // null' <<<"$BR_SETTINGS_JSON")" || return 1
  if [[ "$saved" != null ]]; then
    origin="$("$JQ_BIN" -r .origin <<<"$saved")" || return 1
    # NUL separators preserve empty arguments and whitespace. The schema
    # rejects embedded NULs before decoding.
    "$JQ_BIN" -j '.argv[] | ., "\u0000"' <<<"$saved" >"$TEMP_DIR/check-argv" || return 1
    mapfile -d '' -t stored <"$TEMP_DIR/check-argv" || return 1
    proposed=("${stored[@]}")
    if [[ "$origin" == auto ]]; then
      if br_auto_path "$receipt" && [[ "${proposed[0]}" == "$BR_AUTO_PATH" ]]; then
        if br_probe "${proposed[@]}"; then selected_check=("${proposed[@]}"); BR_CHECK_AUTO=1; return 0; fi
      else error 'saved automatic check no longer belongs to the target'; fi
    elif resolved="$(resolve_command "${proposed[0]}")"; then
      proposed[0]="$resolved"
      if br_probe "${proposed[@]}"; then selected_check=("${proposed[@]}"); return 0; fi
    fi
    error 'saved check failed; use -- COMMAND [ARG...] for a one-time post-upgrade check'
  elif br_auto_path "$receipt"; then
    for option in --version version; do
      proposed=("$BR_AUTO_PATH" "$option")
      if br_probe "${proposed[@]}"; then
        br_save_check auto "${proposed[@]}" || return 1
        selected_check=("${proposed[@]}"); BR_CHECK_AUTO=1; return 0
      fi
    done
  fi
  if ! br_has_terminal; then
    error 'a check command is needed; rerun interactively or use TARGET -- COMMAND [ARG...]'
    return 2
  fi
  while true; do
    printf 'Check command (single command and arguments; Ctrl-D cancels): ' >&2 || return 1
    IFS= read -r input || { error 'check input ended; no upgrade performed'; return 1; }
    if ! br_parse_words "$input"; then continue; fi
    stored=("${BR_WORDS[@]}")
    if ! resolved="$(resolve_command "${stored[0]}")"; then continue; fi
    proposed=("$resolved" "${stored[@]:1}")
    if br_probe "${proposed[@]}"; then
      br_save_check manual "${stored[@]}" || return 1
      selected_check=("${proposed[@]}"); return 0
    fi
  done
}

br_verify_auto_check() {
  local selected="$1" receipt="$2"
  if (( BR_CHECK_AUTO )); then
    if ! br_auto_path "$receipt" || [[ "$selected" != "$BR_AUTO_PATH" ]]; then
      error 'automatic check no longer belongs to the upgraded target; refusing PATH fallback'
      return 1
    fi
    if [[ "$BR_KIND" == formula && "${BR_AUTO_ROOT##*/}" != "$OUTDATED_CANDIDATE" ]]; then
      error 'automatic check still points to a different Formula version after upgrade'
      return 1
    fi
  fi
}
