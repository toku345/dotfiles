#!/usr/bin/env bats
# shellcheck shell=bash
bats_require_minimum_version 1.5.0
load test_helper_bash5

setup() {
  resolve_bash5
  export SOURCE="$BATS_TEST_DIRNAME/../../dot_local/bin/executable_brew-reviewed-upgrade"
  export PROBE="$BATS_TEST_DIRNAME/../../dot_local/lib/brew-reviewed-upgrade/probe.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/config"
  mkdir -p "$HOME"
}

common() {
  run "$BASH5_BIN" -c 'source "$SOURCE"; JQ_BIN="$(type -P jq)"; br_settings_init formula tool; '"$1"
}

@test "settings defaults zero reset and independent check updates" {
  common '
    [[ $COOLDOWN_SECONDS == 172800 ]]
    br_settings_write cooldown_hours 0
    br_save_check manual tool "two words" "" "*"
    br_settings_init formula tool
    [[ $COOLDOWN_SECONDS == 0 ]]
    jq -e '\''.check.argv == ["tool", "two words", "", "*"]'\'' "$BR_SETTINGS_FILE"
    br_settings_write cooldown_hours null
    br_settings_init formula tool
    [[ $COOLDOWN_SECONDS == 172800 ]]
    jq -e '\''.check.origin == "manual"'\'' "$BR_SETTINGS_FILE"
    br_settings_write check null
    jq -e '\''has("check") | not'\'' "$BR_SETTINGS_FILE"
  '
  [ "$status" -eq 0 ]
}

@test "stale in-memory check save preserves a newer cooldown" {
  common '
    br_settings_write cooldown_hours 0
    br_settings_init formula tool
    br_settings_write cooldown_hours 48
    br_save_check manual tool --version
    jq -e '\''.cooldown_hours == 48 and .check.argv == ["tool", "--version"]'\'' "$BR_SETTINGS_FILE"
  '
  [ "$status" -eq 0 ]
}

@test "lock contention preserves the other owners lock and contents" {
  common '
    br_settings_write cooldown_hours 24
    mkdir -m 700 "$BR_SETTINGS_FILE.lock"
    if br_settings_write cooldown_hours 0; then exit 9; fi
    [[ -d $BR_SETTINGS_FILE.lock ]]
    jq -e '\''.cooldown_hours == 24'\'' "$BR_SETTINGS_FILE"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings are locked"* ]]
}

@test "failed rename retains settings and releases only its own lock" {
  common '
    br_settings_write cooldown_hours 48
    mv() { return 1; }
    if br_settings_write cooldown_hours 0; then exit 9; fi
    [[ ! -d $BR_SETTINGS_FILE.lock ]]
    jq -e '\''.cooldown_hours == 48'\'' "$BR_SETTINGS_FILE"
    shopt -s nullglob
    leftovers=("$BR_SETTINGS_DIR"/.settings.*)
    [[ ${#leftovers[@]} == 0 ]]
  '
  [ "$status" -eq 0 ]
}

@test "settings reject corruption unknown schema unsafe modes and symlinks" {
  common '
    br_settings_write cooldown_hours 48
    : >"$BR_SETTINGS_FILE"
    if br_settings_read; then exit 9; fi
    printf "{\"schema_version\":1}\n{\"schema_version\":1}\n" >"$BR_SETTINGS_FILE"
    if br_settings_read; then exit 9; fi
    printf "{}\n" >"$BR_SETTINGS_FILE"
    if br_settings_read; then exit 9; fi
    printf "{\"schema_version\":2}\n" >"$BR_SETTINGS_FILE"
    if br_settings_read; then exit 9; fi
    printf "{\"schema_version\":1}\n" >"$BR_SETTINGS_FILE"
    chmod 644 "$BR_SETTINGS_FILE"
    if br_settings_read; then exit 9; fi
    chmod 600 "$BR_SETTINGS_FILE"
    mv "$BR_SETTINGS_FILE" "$HOME/original"
    ln -s "$HOME/original" "$BR_SETTINGS_FILE"
    if br_settings_read; then exit 9; fi
  '
  [ "$status" -eq 0 ]
}

@test "package identity filenames cannot traverse and kinds remain separate" {
  common '
    br_settings_init formula ../../tool
    br_settings_write cooldown_hours 24
    [[ $BR_SETTINGS_FILE == "$XDG_CONFIG_HOME/brew-reviewed-upgrade/formula/..%2F..%2Ftool.json" ]]
    br_settings_init cask ../../tool
    [[ $COOLDOWN_SECONDS == 172800 ]]
  '
  [ "$status" -eq 0 ]
}

@test "hours reject negatives fractions expressions and overflow" {
  common '
    for value in -1 1.5 "1+2" "" 2501999792984 999999999999999999999; do
      if br_valid_hours "$value"; then exit 9; fi
    done
    br_valid_hours 0
    br_valid_hours 00024
    br_valid_hours 2501999792983
  '
  [ "$status" -eq 0 ]
}

@test "tokenization preserves quotes empty arguments and literal substitutions" {
  common '
    br_parse_words '\''tool "two words" "" a\ b "$HOME" "$(touch nope)" "*"'\''
    [[ ${#BR_WORDS[@]} == 7 ]]
    [[ ${BR_WORDS[1]} == "two words" && ${BR_WORDS[2]} == "" && ${BR_WORDS[3]} == "a b" ]]
    [[ ${BR_WORDS[4]} == '\''$HOME'\'' && ${BR_WORDS[5]} == '\''$(touch nope)'\'' ]]
    [[ ! -e nope ]]
    for value in "tool | cat" "tool > file" "tool; other" "tool \"" "tool \\"; do
      if br_parse_words "$value"; then exit 9; fi
    done
  '
  [ "$status" -eq 0 ]
}

@test "probe preserves command failure and does not consume input" {
  run "$BASH5_BIN" "$PROBE" "$BASH5_BIN" -c 'if read -r line; then exit 9; fi; exit 7' <<<"keep"
  [ "$status" -eq 7 ]
}

@test "probe times out a TERM-ignoring process group" {
  run "$BASH5_BIN" "$PROBE" "$BASH5_BIN" -c 'printf %s "$BASHPID" >"$HOME/probe-pid"; trap "" TERM; while :; do sleep 0.1; done'
  [ "$status" -eq 124 ]
  [[ "$output" == *"timed out"* ]]
  run -1 kill -0 "$(cat "$HOME/probe-pid")"
}

@test "probe rejects a successful leader that leaves descendants" {
  run "$BASH5_BIN" "$PROBE" "$BASH5_BIN" -c 'sleep 30 & exit 0'
  [ "$status" -eq 1 ]
  [[ "$output" == *"running descendants"* ]]
}

@test "probe external TERM aborts instead of returning a candidate failure" {
  run "$BASH5_BIN" -c '
    "$BASH" "$PROBE" "$BASH" -c '\''printf ready >"$HOME/ready"; trap "" TERM; while :; do sleep 0.1; done'\'' &
    supervisor=$!
    for ((i=0; i<100; i++)); do [[ ! -f $HOME/ready ]] || break; sleep 0.05; done
    [[ -f $HOME/ready ]] || { kill -TERM "$supervisor"; wait "$supervisor"; exit 9; }
    kill -TERM "$supervisor"
    wait "$supervisor"
  '
  [ "$status" -eq 143 ]
}


@test "normal completion near deadline cancels the watchdog" {
  run "$BASH5_BIN" "$PROBE" "$BASH5_BIN" -c 'sleep 9; printf done'
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "TERM during settings publication releases the owned lock and preserves data" {
  common '
    br_settings_write cooldown_hours 48
    mv() { kill -TERM "$BASHPID"; }
    if br_settings_write cooldown_hours 0; then exit 9; else rc=$?; fi
    [[ $rc == 143 && ! -d $BR_SETTINGS_FILE.lock ]]
    jq -e '\''.cooldown_hours == 48'\'' "$BR_SETTINGS_FILE"
  '
  [ "$status" -eq 0 ]
}
