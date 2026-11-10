#!/usr/bin/env bats
# shellcheck shell=bash
# Policy checks for the global mise config and lock (ADR 0041).

bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  resolve_bash5
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  MISE_DIR="$REPO_ROOT/private_dot_config/mise"
  CONFIG="$MISE_DIR/config.toml"
  LOCK="$MISE_DIR/mise.lock"
  export REPO_ROOT MISE_DIR CONFIG LOCK
}

# Fail when $output contains the fixed string $2 (grep flags in $1). A bare
# `! grep` would not fail the test: errexit ignores negated commands.
refute_output_match() {
  if grep "$1" -- "$2" <<<"$output"; then
    echo "unexpected output: $2" >&2
    return 1
  fi
}

# Runtimes are exempt from the provenance rule (ADR 0041 Decision 2).
RUNTIMES=" node python ruby java zig bun deno "

# Print the [tools] section as "name<TAB>value" lines.
tools_entries() {
  awk '
    /^\[/ { in_tools = ($0 == "[tools]"); next }
    in_tools && /=/ && !/^[[:space:]]*#/ {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      split(line, kv, "=")
      name = kv[1]; value = kv[2]
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", name)
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
      print name "\t" value
    }
  ' "$CONFIG"
}

# Print "tool<TAB>platform<TAB>provenance" for every locked platform entry.
lock_platform_provenance() {
  awk '
    /^\[tools\..*\."platforms\./ {
      if (key != "") print key "\t" prov
      line = $0
      sub(/^\[tools\./, "", line)
      split(line, parts, ".\"platforms.")
      tool = parts[1]; platform = parts[2]
      gsub(/"/, "", tool); gsub(/["\]]/, "", platform)
      key = tool "\t" platform; prov = "-"
      next
    }
    /^\[/ { if (key != "") print key "\t" prov; key = ""; next }
    key != "" && /^provenance[[:space:]]*=/ {
      prov = $0; sub(/^provenance[[:space:]]*=[[:space:]]*/, "", prov); gsub(/"/, "", prov)
    }
    END { if (key != "") print key "\t" prov }
  ' "$LOCK"
}

# Print "tool<TAB>specifiers" for every locked tool, e.g. node<TAB>["26"].
lock_specifiers() {
  awk '
    /^\[\[tools\./ {
      tool = $0; sub(/^\[\[tools\./, "", tool); sub(/\]\]$/, "", tool); gsub(/"/, "", tool)
      next
    }
    /^\[/ { tool = ""; next }
    tool != "" && /^specifiers[[:space:]]*=/ {
      value = $0; sub(/^specifiers[[:space:]]*=[[:space:]]*/, "", value)
      print tool "\t" value
    }
  ' "$LOCK"
}

@test "mise config declares the required safety settings" {
  local setting
  for setting in \
    'minimum_release_age = "48h"' \
    'locked = true' \
    'locked_scopes = ["global"]' \
    'locked_verify_provenance = true' \
    'lockfile_platforms = ["macos-arm64", "linux-x64"]' \
    'auto_install = false' \
    'exec_auto_install = false' \
    'not_found_auto_install = false'
  do
    grep -Fqx "$setting" "$CONFIG" || { echo "missing setting: $setting" >&2; return 1; }
  done
}

@test "mise tools use latest or prefix requests, never exact versions" {
  run tools_entries
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local name value
  while IFS=$'\t' read -r name value; do
    [[ -n "$value" ]] || { echo "empty request for $name" >&2; return 1; }
    # minimum_release_age ignores exact requests, so x.y.z would bypass the cooldown.
    if [[ "$value" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]; then
      echo "exact version is not allowed: $name = $value" >&2
      return 1
    fi
  done <<<"$output"
}

@test "every configured tool is locked for every platform" {
  run lock_platform_provenance
  [ "$status" -eq 0 ]
  local locked="$output" name value platform count=0
  [ -n "$locked" ]
  while IFS=$'\t' read -r name value; do
    count=$((count + 1))
    for platform in macos-arm64 linux-x64; do
      awk -F '\t' -v t="$name" -v p="$platform" '$1 == t && $2 == p { found = 1 } END { exit !found }' \
        <<<"$locked" || { echo "missing lock entry: $name $platform" >&2; return 1; }
    done
  done < <(tools_entries)
  (( count > 0 ))
}

@test "every non-runtime tool has provenance on every locked platform" {
  run lock_platform_provenance
  [ "$status" -eq 0 ]
  local tool platform prov count=0
  while IFS=$'\t' read -r tool platform prov; do
    [[ "$RUNTIMES" == *" $tool "* ]] && continue
    count=$((count + 1))
    if [[ "$prov" == "-" ]]; then
      echo "CLI without provenance: $tool $platform" >&2
      return 1
    fi
  done <<<"$output"
  (( count > 0 ))
}

@test "lock specifiers match the config requests" {
  run lock_specifiers
  [ "$status" -eq 0 ]
  local specs="$output" name value count=0
  while IFS=$'\t' read -r name value; do
    count=$((count + 1))
    awk -F '\t' -v t="$name" -v v="[\"$value\"]" '$1 == t && $2 == v { found = 1 } END { exit !found }' \
      <<<"$specs" || { echo "lock specifiers do not match config: $name = $value" >&2; return 1; }
  done < <(tools_entries)
  (( count > 0 ))
}

# Source config.fish in an isolated HOME and print the resulting PATH entries.
# MISE_FISH_AUTO_ACTIVATE=0 stops Homebrew's vendor_conf.d snippet from running
# the real `mise activate fish` (and its network lookups) on the test host.
# $1 is fish code evaluated before the config (e.g. a mise stub), $2 after it. Set
# FISH_PATH to control the inherited PATH.
run_fish_config() {
  local config_home="$BATS_TEST_TMPDIR/fish-config"
  # SHELL makes `brew shellenv` (macOS) print fish syntax instead of errors.
  run env -u MISE_DATA_DIR -u ASDF_DATA_DIR MISE_FISH_AUTO_ACTIVATE=0 HOME="$HOME" PATH="${FISH_PATH:-$PATH}" \
    SHELL="$(command -v fish)" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$config_home/data" fish -c '
    function fish_config; end
    function starship; end
    function direnv; end
    function shadowenv; end
    eval $argv[2]
    source $argv[1]
    string join \n $PATH
    echo "manager=$__version_manager"
    functions -q __mise_update_java_home; and echo java-hook=mise; or echo java-hook=none
    eval $argv[3]
  ' "$REPO_ROOT/private_dot_config/private_fish/config.fish" "${1:-}" "${2:-}"
}

@test "fish config uses mise shims once mise is installed and ~/.tool-versions is retired" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  run_fish_config 'function mise; end'
  [ "$status" -eq 0 ]
  grep -Fqx "$HOME/.local/share/mise/shims" <<<"$output"
  if grep -Fq "$HOME/.asdf/shims" <<<"$output"; then
    echo "asdf shims must not be on PATH once mise is selected" >&2
    return 1
  fi
  grep -Fqx 'manager=mise' <<<"$output"
  grep -Fqx 'java-hook=mise' <<<"$output"
  grep -Fq 'function __mise_update_java_home --on-event fish_prompt' \
    "$REPO_ROOT/private_dot_config/private_fish/config.fish"
}

@test "fish config keeps mise shims ahead of Homebrew and later PATH additions" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  local brew="$BATS_TEST_TMPDIR/brew"
  mkdir -p "$HOME/.local/share/mise/shims" "$HOME/.asdf/shims" "$HOME/go/bin" "$brew/bin"
  # Universal entries as left by an earlier setup: fish starts with them first.
  # The config then adds ~/go/bin, which was not on PATH yet, after the shims.
  run_fish_config "function mise; end; set -U fish_user_paths '$brew/bin' '$HOME/.asdf/shims'"
  [ "$status" -eq 0 ]
  local shims_line brew_line go_line
  shims_line="$(grep -Fnx "$HOME/.local/share/mise/shims" <<<"$output" | cut -d: -f1)"
  brew_line="$(grep -Fnx "$brew/bin" <<<"$output" | cut -d: -f1)"
  go_line="$(grep -Fnx "$HOME/go/bin" <<<"$output" | cut -d: -f1)"
  [[ -n "$shims_line" && -n "$brew_line" && -n "$go_line" ]]
  (( shims_line < brew_line && shims_line < go_line ))
  refute_output_match -Fx "$HOME/.asdf/shims"
}

@test "fish config does not change the universal fish_user_paths" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  local brew="$BATS_TEST_TMPDIR/brew"
  mkdir -p "$HOME/.local/share/mise/shims" "$HOME/user-bin" "$HOME/go/bin" "$brew/opt/bash/bin"
  printf '#!/bin/sh\n' > "$brew/opt/bash/bin/bash"; chmod +x "$brew/opt/bash/bin/bash"
  # A change makes every running shell rebuild its PATH with these entries first.
  # (On macOS, brew shellenv replaces the fake HOMEBREW_PREFIX with the real one.)
  HOMEBREW_PREFIX="$brew" run_fish_config \
    "function mise; end; set -U fish_user_paths '$HOME/user-bin'" \
    'echo "user-paths=$fish_user_paths"'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "user-paths=$HOME/user-bin" ]
  grep -Fqx "$HOME/go/bin" <<<"$output"
}

@test "fish config keeps asdf shims until mise shims exist" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  run_fish_config 'function mise; end'
  [ "$status" -eq 0 ]
  grep -Fqx "$HOME/.asdf/shims" <<<"$output"
  if grep -Fq "$HOME/.local/share/mise/shims" <<<"$output"; then
    echo "mise shims must not be on PATH before mise install" >&2
    return 1
  fi
  grep -Fqx 'manager=asdf' <<<"$output"
  grep -Fqx 'java-hook=none' <<<"$output"
}

@test "fish config keeps asdf shims while ~/.tool-versions exists" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  : > "$HOME/.tool-versions"
  run_fish_config 'function mise; end'
  [ "$status" -eq 0 ]
  grep -Fqx "$HOME/.asdf/shims" <<<"$output"
  refute_output_match -Fq "$HOME/.local/share/mise/shims"
  grep -Fqx 'manager=asdf' <<<"$output"
}

@test "fish config drops inherited shims of the manager it did not select" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  local mise_shims="$HOME/.local/share/mise/shims" asdf_shims="$HOME/.asdf/shims"
  mkdir -p "$mise_shims"
  FISH_PATH="$asdf_shims:$mise_shims:$PATH" run_fish_config 'function mise; end'
  [ "$status" -eq 0 ]
  grep -Fqx 'manager=mise' <<<"$output"
  refute_output_match -Fqx "$asdf_shims"
  [ "$(grep -Fcx "$mise_shims" <<<"$output")" -eq 1 ]

  : > "$HOME/.tool-versions"
  FISH_PATH="$mise_shims:$asdf_shims:$PATH" run_fish_config 'function mise; end'
  [ "$status" -eq 0 ]
  grep -Fqx 'manager=asdf' <<<"$output"
  refute_output_match -Fqx "$mise_shims"
  [ "$(grep -Fcx "$asdf_shims" <<<"$output")" -eq 1 ]
}

# Line number of the first exact match of $1 in $output (0 if absent).
path_line() {
  local n
  n="$(grep -Fnx -m1 -- "$1" <<<"$output" | cut -d: -f1)"
  echo "${n:-0}"
}

@test "fish config moves inherited shims ahead of a Homebrew dir the parent put first" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  local mise_shims="$HOME/.local/share/mise/shims" asdf_shims="$HOME/.asdf/shims"
  local brew="$BATS_TEST_TMPDIR/brew/bin"
  mkdir -p "$mise_shims" "$brew"
  FISH_PATH="$brew:$mise_shims:$PATH" run_fish_config 'function mise; end'
  [ "$status" -eq 0 ]
  grep -Fqx 'manager=mise' <<<"$output"
  [ "$(path_line "$mise_shims")" -gt 0 ]
  [ "$(path_line "$mise_shims")" -lt "$(path_line "$brew")" ]

  : > "$HOME/.tool-versions"
  FISH_PATH="$brew:$asdf_shims:$PATH" run_fish_config 'function mise; end'
  [ "$status" -eq 0 ]
  grep -Fqx 'manager=asdf' <<<"$output"
  [ "$(path_line "$asdf_shims")" -gt 0 ]
  [ "$(path_line "$asdf_shims")" -lt "$(path_line "$brew")" ]
}

@test "fish JAVA_HOME hook in a child shell clears a JDK its parent's hook exported" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  local jdk="$BATS_TEST_TMPDIR/jdk-a"
  mkdir -p "$jdk/bin"; : > "$jdk/bin/java"
  local config_home="$BATS_TEST_TMPDIR/fish-config" script
  # SELECTED_JAVA is not exported, so java does not resolve in the child.
  script=$(cat <<'EOF'
set -l stubs 'function fish_config; end; function starship; end; function direnv; end; function shadowenv; end; function mise; test "$argv[1]" = which; and echo $SELECTED_JAVA; end'
eval $stubs
source $argv[1]
set -g SELECTED_JAVA $JDK_A; __mise_update_java_home
fish -c "$stubs; source $argv[1]; __mise_update_java_home; echo \"child=[\$JAVA_HOME][\$JDK_HOME]\"" $argv[1]
set -gx JAVA_HOME /user/jdk
fish -c "$stubs; source $argv[1]; __mise_update_java_home; echo \"user=[\$JAVA_HOME]\"" $argv[1]
EOF
)
  run env -u MISE_DATA_DIR -u ASDF_DATA_DIR MISE_FISH_AUTO_ACTIVATE=0 HOME="$HOME" XDG_CONFIG_HOME="$config_home" \
    XDG_DATA_HOME="$config_home/data" JDK_A="$jdk/bin/java" fish -c "$script" \
    "$REPO_ROOT/private_dot_config/private_fish/config.fish"
  [ "$status" -eq 0 ]
  grep -Fqx 'child=[][]' <<<"$output"
  grep -Fqx 'user=[/user/jdk]' <<<"$output"
}

@test "fish JAVA_HOME hook follows the java mise resolves on each prompt" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  local jdk_a="$BATS_TEST_TMPDIR/jdk-a/Contents/Home" jdk_b="$BATS_TEST_TMPDIR/jdk-b"
  mkdir -p "$jdk_a/bin" "$jdk_b/bin"
  : > "$jdk_a/bin/java"; : > "$jdk_b/bin/java"
  local config_home="$BATS_TEST_TMPDIR/fish-config"
  run env -u MISE_DATA_DIR -u ASDF_DATA_DIR MISE_FISH_AUTO_ACTIVATE=0 HOME="$HOME" XDG_CONFIG_HOME="$config_home" \
    XDG_DATA_HOME="$config_home/data" JDK_A="$jdk_a/bin/java" JDK_B="$jdk_b/bin/java" fish -c '
    function fish_config; end
    function starship; end
    function direnv; end
    function shadowenv; end
    # Resolve only when called offline, so a hook without MISE_OFFLINE fails.
    function mise; test "$argv[1]" = which; and test "$MISE_OFFLINE" = 1; and echo $SELECTED_JAVA; end
    source $argv[1]
    # Call the handler directly: emitting fish_prompt also runs unrelated
    # handlers (some reach the network). Event registration is checked above.
    set -g SELECTED_JAVA $JDK_A; __mise_update_java_home; echo "A=$JAVA_HOME"
    set -g SELECTED_JAVA /nonexistent/bin/java; __mise_update_java_home; echo "N=[$JAVA_HOME]"
    set -g SELECTED_JAVA $JDK_B; __mise_update_java_home; echo "B=$JAVA_HOME"
    set -g SELECTED_JAVA; __mise_update_java_home; echo "C=[$JAVA_HOME][$JDK_HOME]"
    set -gx JAVA_HOME /user/jdk; __mise_update_java_home; echo "D=[$JAVA_HOME]"
  ' "$REPO_ROOT/private_dot_config/private_fish/config.fish"
  [ "$status" -eq 0 ]
  grep -Fqx "A=$(cd "$jdk_a" && pwd -P)" <<<"$output"
  # An unresolvable java path is a failed resolution, not JAVA_HOME=".".
  grep -Fqx "N=[]" <<<"$output"
  grep -Fqx "B=$(cd "$jdk_b" && pwd -P)" <<<"$output"
  # A failed resolution clears the hook's previous JDK but keeps a user value.
  grep -Fqx "C=[][]" <<<"$output"
  grep -Fqx "D=[/user/jdk]" <<<"$output"
}

# Source dot_bashrc in an isolated HOME. $1 is the stub prelude, $2 the probe.
# Set BASHRC_PATH to control the inherited PATH.
run_bashrc() {
  run env -i HOME="$HOME" PATH="${BASHRC_PATH:-/usr/bin:/bin}" JDK_JAVA="${JDK_JAVA:-}" \
    "$BASH5_BIN" --noprofile --norc -c '
    eval "$2"
    starship() { :; }; direnv() { :; }
    source "$1"
    eval "$3"
  ' -- "$REPO_ROOT/dot_bashrc" "$1" "$2"
}

@test "dot_bashrc uses mise shims once mise is installed and ~/.tool-versions is retired" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  run_bashrc 'mise() { :; }; asdf() { :; }' 'printf "%s\n" "$PATH" "$PROMPT_COMMAND"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.local/share/mise/shims"* ]]
  [[ "$output" != *"$HOME/.asdf/shims"* ]]
  [[ "$output" == *"_mise_update_java_home"* ]]
}

@test "dot_bashrc keeps asdf shims when mise is installed but has no shims yet" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  run_bashrc 'mise() { :; }; asdf() { :; }' 'printf "%s\n" "$PATH"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.asdf/shims"* ]]
  [[ "$output" != *"/mise/shims"* ]]
}

@test "dot_bashrc keeps asdf shims while ~/.tool-versions exists" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  : > "$HOME/.tool-versions"
  run_bashrc 'mise() { :; }; asdf() { :; }' 'printf "%s\n" "$PATH" "${PROMPT_COMMAND:-}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.asdf/shims"* ]]
  [[ "$output" != *"/mise/shims"* ]]
  [[ "$output" != *"_mise_update_java_home"* ]]
}

@test "dot_bashrc keeps asdf shims on machines without mise" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  run_bashrc 'asdf() { :; }' 'printf "%s\n" "$PATH"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.asdf/shims"* ]]
  [[ "$output" != *"/mise/shims"* ]]
}

@test "dot_bashrc drops inherited shims of the manager it did not select" {
  export HOME="$BATS_TEST_TMPDIR/home"
  local mise_shims="$HOME/.local/share/mise/shims" asdf_shims="$HOME/.asdf/shims"
  mkdir -p "$mise_shims"
  BASHRC_PATH="$asdf_shims:$mise_shims:/usr/bin:/bin" \
    run_bashrc 'mise() { :; }; asdf() { :; }' 'tr : "\n" <<<"$PATH"'
  [ "$status" -eq 0 ]
  refute_output_match -Fqx "$asdf_shims"
  [ "$(grep -Fcx "$mise_shims" <<<"$output")" -eq 1 ]

  : > "$HOME/.tool-versions"
  BASHRC_PATH="$mise_shims:$asdf_shims:/usr/bin:/bin" \
    run_bashrc 'mise() { :; }; asdf() { :; }' 'tr : "\n" <<<"$PATH"'
  [ "$status" -eq 0 ]
  refute_output_match -Fqx "$mise_shims"
  [ "$(grep -Fcx "$asdf_shims" <<<"$output")" -eq 1 ]
}

@test "dot_bashrc moves inherited shims ahead of a Homebrew dir the parent put first" {
  export HOME="$BATS_TEST_TMPDIR/home"
  local mise_shims="$HOME/.local/share/mise/shims" asdf_shims="$HOME/.asdf/shims"
  local brew="$BATS_TEST_TMPDIR/brew/bin"
  mkdir -p "$mise_shims"
  BASHRC_PATH="$brew:$mise_shims:/usr/bin:/bin" \
    run_bashrc 'mise() { :; }; asdf() { :; }' 'tr : "\n" <<<"$PATH"'
  [ "$status" -eq 0 ]
  [ "$(path_line "$mise_shims")" -gt 0 ]
  [ "$(path_line "$mise_shims")" -lt "$(path_line "$brew")" ]
  [ "$(grep -Fcx "$mise_shims" <<<"$output")" -eq 1 ]

  : > "$HOME/.tool-versions"
  BASHRC_PATH="$brew:$asdf_shims:/usr/bin:/bin" \
    run_bashrc 'mise() { :; }; asdf() { :; }' 'tr : "\n" <<<"$PATH"'
  [ "$status" -eq 0 ]
  [ "$(path_line "$asdf_shims")" -gt 0 ]
  [ "$(path_line "$asdf_shims")" -lt "$(path_line "$brew")" ]
  [ "$(grep -Fcx "$asdf_shims" <<<"$output")" -eq 1 ]
}

@test "bash JAVA_HOME hook in a child shell clears a JDK its parent's hook exported" {
  export HOME="$BATS_TEST_TMPDIR/home"
  local jdk="$BATS_TEST_TMPDIR/jdk-a"
  mkdir -p "$HOME/.local/share/mise/shims" "$jdk/bin"
  : > "$jdk/bin/java"
  local probe
  # SEL is not exported, so java does not resolve in the child.
  probe=$(cat <<'EOF'
SEL=$JDK_JAVA; _mise_update_java_home
child='mise() { [[ -n "${SEL:-}" ]] && printf "%s\n" "$SEL"; }; starship() { :; }; direnv() { :; }; source "$1"; _mise_update_java_home'
"$BASH" --noprofile --norc -c "$child"'; printf "child=[%s][%s]\n" "${JAVA_HOME:-}" "${JDK_HOME:-}"' -- "$1"
export JAVA_HOME=/user/jdk
"$BASH" --noprofile --norc -c "$child"'; printf "user=[%s]\n" "${JAVA_HOME:-}"' -- "$1"
EOF
)
  JDK_JAVA="$jdk/bin/java" run_bashrc \
    'mise() { [[ -n "${SEL:-}" ]] && printf "%s\n" "$SEL"; }' "$probe"
  [ "$status" -eq 0 ]
  [[ "${lines[-2]}" == "child=[][]" ]]
  [[ "${lines[-1]}" == "user=[/user/jdk]" ]]
}

@test "bash JAVA_HOME hook follows the java resolved by mise" {
  export HOME="$BATS_TEST_TMPDIR/home"
  local jdk="$BATS_TEST_TMPDIR/jdk-a/Contents/Home"
  mkdir -p "$HOME/.local/share/mise/shims" "$jdk/bin"
  : > "$jdk/bin/java"
  JDK_JAVA="$jdk/bin/java" run_bashrc \
    'mise() { [[ "$1" == which && "$2" == java && "${MISE_OFFLINE:-}" == 1 ]] && printf "%s\n" "$JDK_JAVA"; }' \
    '_mise_update_java_home; printf "%s\n" "$JAVA_HOME"'
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "$(cd "$jdk" && pwd -P)" ]]
}

@test "bash JAVA_HOME hook clears its previous JDK when resolution fails" {
  export HOME="$BATS_TEST_TMPDIR/home"
  local jdk="$BATS_TEST_TMPDIR/jdk-a"
  mkdir -p "$HOME/.local/share/mise/shims" "$jdk/bin"
  : > "$jdk/bin/java"
  JDK_JAVA="$jdk/bin/java" run_bashrc \
    'mise() { [[ -n "${SEL:-}" ]] && printf "%s\n" "$SEL"; }' \
    'SEL=$JDK_JAVA; _mise_update_java_home
     SEL=/nonexistent/bin/java; _mise_update_java_home; printf "N=[%s]\n" "${JAVA_HOME:-}"
     SEL=$JDK_JAVA; _mise_update_java_home
     SEL=; _mise_update_java_home; printf "C=[%s][%s]\n" "${JAVA_HOME:-}" "${JDK_HOME:-}"
     export JAVA_HOME=/user/jdk; _mise_update_java_home; printf "D=[%s]\n" "$JAVA_HOME"'
  [ "$status" -eq 0 ]
  # An unresolvable java path is a failed resolution, not JAVA_HOME=".".
  [[ "${lines[-3]}" == "N=[]" ]]
  [[ "${lines[-2]}" == "C=[][]" ]]
  [[ "${lines[-1]}" == "D=[/user/jdk]" ]]
}

@test "bash JAVA_HOME hook is harmless when java is not installed" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  run_bashrc 'mise() { [[ "$1" == which ]] && return 1; :; }' \
    '_mise_update_java_home; printf "JAVA_HOME=[%s]\n" "${JAVA_HOME:-}"'
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "JAVA_HOME=[]" ]]
}

# Start fish with a fake vendor_conf.d whose snippet mimics Homebrew's mise
# formula, and the repo's conf.d as the user conf.d. $1 names the repo snippet
# copy; $2 is sed applied to it. MISE_FISH_AUTO_ACTIVATE is unset so only the
# repo file can stop the vendor snippet. Each call gets a fresh directory, so a
# snippet from an earlier call cannot mask what this call checks.
run_fish_vendor_mise() {
  local root
  root="$(mktemp -d "$BATS_TEST_TMPDIR/vendor-test.XXXXXX")"
  mkdir -p "$root/share/fish/vendor_conf.d" "$root/config/fish/conf.d"
  printf '%s\n' 'if [ "$MISE_FISH_AUTO_ACTIVATE" != "0" ]' '  set -g VENDOR_MISE_ACTIVATED 1' 'end' \
    > "$root/share/fish/vendor_conf.d/mise-activate.fish"
  if [[ -n "$1" ]]; then
    sed "${2:-}" "$REPO_ROOT/private_dot_config/private_fish/conf.d/mise-activate.fish" \
      > "$root/config/fish/conf.d/$1"
  fi
  run env -u MISE_FISH_AUTO_ACTIVATE HOME="$root" XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" XDG_DATA_DIRS="$root/share" fish -c 'echo "activated=[$VENDOR_MISE_ACTIVATED]"'
}

@test "fish conf.d stops Homebrew's mise auto-activation" {
  command -v fish >/dev/null || skip 'fish is not installed'
  run_fish_vendor_mise ''
  [ "$output" = "activated=[1]" ]    # the fake vendor snippet runs on its own
  run_fish_vendor_mise mise-activate.fish
  [ "$output" = "activated=[]" ]
}

@test "fish mise auto-activation stays off if Homebrew renames the snippet or drops the variable" {
  command -v fish >/dev/null || skip 'fish is not installed'
  run_fish_vendor_mise renamed.fish                            # variable alone
  [ "$output" = "activated=[]" ]
  run_fish_vendor_mise mise-activate.fish '/MISE_FISH_AUTO_ACTIVATE/d'   # mask alone
  [ "$output" = "activated=[]" ]
}

@test "dot_bashrc does not stack the JAVA_HOME hook when sourced again" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  BASHRC_PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" \
    run_bashrc 'mise() { :; }' 'source "$1"; printf "%s\n" "$PROMPT_COMMAND"'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "_mise_update_java_home" ]
}
