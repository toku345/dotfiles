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
      grep -Fq "$name"$'\t'"$platform"$'\t' <<<"$locked" \
        || { echo "missing lock entry: $name $platform" >&2; return 1; }
    done
  done < <(tools_entries)
  (( count > 0 ))
}

@test "every aqua CLI has provenance on every locked platform" {
  run lock_platform_provenance
  [ "$status" -eq 0 ]
  local tool platform prov count=0
  while IFS=$'\t' read -r tool platform prov; do
    [[ "$tool" == aqua:* ]] || continue
    count=$((count + 1))
    if [[ "$prov" == "-" ]]; then
      echo "aqua CLI without provenance: $tool $platform" >&2
      return 1
    fi
  done <<<"$output"
  (( count > 0 ))
}

# Source config.fish in an isolated HOME and print the resulting PATH entries.
run_fish_config() {
  local config_home="$BATS_TEST_TMPDIR/fish-config"
  run env HOME="$HOME" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$config_home/data" fish -c '
    function fish_config; end
    function starship; end
    function direnv; end
    function shadowenv; end
    source $argv[1]
    string join \n $PATH
    echo "manager=$__version_manager"
    functions -q __mise_update_java_home; and echo java-hook=mise; or echo java-hook=none
  ' "$REPO_ROOT/private_dot_config/private_fish/config.fish"
}

@test "fish config uses mise shims once they exist" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  run_fish_config
  [ "$status" -eq 0 ]
  grep -Fqx "$HOME/.local/share/mise/shims" <<<"$output"
  if grep -Fq "$HOME/.asdf/shims" <<<"$output"; then
    echo "asdf shims must not be on PATH once mise shims exist" >&2
    return 1
  fi
  grep -Fqx 'manager=mise' <<<"$output"
  grep -Fqx 'java-hook=mise' <<<"$output"
  grep -Fq 'function __mise_update_java_home --on-event fish_prompt' \
    "$REPO_ROOT/private_dot_config/private_fish/config.fish"
}

@test "fish config keeps asdf shims until mise shims exist" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  run_fish_config
  [ "$status" -eq 0 ]
  grep -Fqx "$HOME/.asdf/shims" <<<"$output"
  if grep -Fq "$HOME/.local/share/mise/shims" <<<"$output"; then
    echo "mise shims must not be on PATH before mise install" >&2
    return 1
  fi
  grep -Fqx 'manager=asdf' <<<"$output"
  grep -Fqx 'java-hook=none' <<<"$output"
}

@test "fish JAVA_HOME hook follows the java mise resolves on each prompt" {
  command -v fish >/dev/null || skip 'fish is not installed'
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  local jdk_a="$BATS_TEST_TMPDIR/jdk-a/Contents/Home" jdk_b="$BATS_TEST_TMPDIR/jdk-b"
  mkdir -p "$jdk_a/bin" "$jdk_b/bin"
  : > "$jdk_a/bin/java"; : > "$jdk_b/bin/java"
  local config_home="$BATS_TEST_TMPDIR/fish-config"
  run env HOME="$HOME" XDG_CONFIG_HOME="$config_home" XDG_DATA_HOME="$config_home/data" \
    JDK_A="$jdk_a/bin/java" JDK_B="$jdk_b/bin/java" fish -c '
    function fish_config; end
    function starship; end
    function direnv; end
    function shadowenv; end
    source $argv[1]
    function mise; test "$argv[1]" = which; and echo $SELECTED_JAVA; end
    # Call the handler directly: emitting fish_prompt also runs unrelated
    # handlers (some reach the network). Event registration is checked above.
    set -g SELECTED_JAVA $JDK_A; __mise_update_java_home; echo "A=$JAVA_HOME"
    set -g SELECTED_JAVA $JDK_B; __mise_update_java_home; echo "B=$JAVA_HOME"
  ' "$REPO_ROOT/private_dot_config/private_fish/config.fish"
  [ "$status" -eq 0 ]
  grep -Fqx "A=$(cd "$jdk_a" && pwd -P)" <<<"$output"
  grep -Fqx "B=$(cd "$jdk_b" && pwd -P)" <<<"$output"
}

# Source dot_bashrc in an isolated HOME. $1 is the stub prelude, $2 the probe.
run_bashrc() {
  run env -i HOME="$HOME" PATH="/usr/bin:/bin" JDK_JAVA="${JDK_JAVA:-}" "$BASH5_BIN" --noprofile --norc -c '
    eval "$2"
    starship() { :; }; direnv() { :; }
    source "$1"
    eval "$3"
  ' -- "$REPO_ROOT/dot_bashrc" "$1" "$2"
}

@test "dot_bashrc uses mise shims once they exist" {
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

@test "dot_bashrc keeps asdf shims on machines without mise" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  run_bashrc 'asdf() { :; }' 'printf "%s\n" "$PATH"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.asdf/shims"* ]]
  [[ "$output" != *"/mise/shims"* ]]
}

@test "bash JAVA_HOME hook follows the java resolved by mise" {
  export HOME="$BATS_TEST_TMPDIR/home"
  local jdk="$BATS_TEST_TMPDIR/jdk-a/Contents/Home"
  mkdir -p "$HOME/.local/share/mise/shims" "$jdk/bin"
  : > "$jdk/bin/java"
  JDK_JAVA="$jdk/bin/java" run_bashrc \
    'mise() { [[ "$1" == which && "$2" == java ]] && printf "%s\n" "$JDK_JAVA"; }' \
    '_mise_update_java_home; printf "%s\n" "$JAVA_HOME"'
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "$(cd "$jdk" && pwd -P)" ]]
}

@test "bash JAVA_HOME hook is harmless when java is not installed" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/share/mise/shims"
  run_bashrc 'mise() { return 1; }' '_mise_update_java_home; printf "JAVA_HOME=[%s]\n" "${JAVA_HOME:-}"'
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "JAVA_HOME=[]" ]]
}

@test "mise run-once installer skips Linux before any brew call" {
  local script="$REPO_ROOT/.chezmoiscripts/run_once_before_install-mise.sh"
  local stub_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_dir"
  printf '#!/bin/sh\necho "brew $*" >> "%s/brew.log"\n' "$BATS_TEST_TMPDIR" > "$stub_dir/brew"
  chmod +x "$stub_dir/brew"

  run env PATH="$stub_dir:/usr/bin:/bin" CHEZMOI_OS=linux sh "$script"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/brew.log" ]

  run env PATH="$stub_dir:/usr/bin:/bin" CHEZMOI_OS=darwin sh "$script"
  [ "$status" -eq 0 ]
  grep -Fqx 'brew install mise' "$BATS_TEST_TMPDIR/brew.log"
}
