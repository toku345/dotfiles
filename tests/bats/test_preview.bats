#!/usr/bin/env bats
# shellcheck shell=bash

load test_helper

setup() {
  standard_env
}

# --- direct path mode ------------------------------------------------------

@test "TestDark preview: full palette + non-palette swatch matches snapshot" {
  run ghostty-theme-preview "$FIXTURES_DIR/themes/TestDark"
  [ "$status" -eq 0 ]
  assert_snapshot "TestDark preview" "$output" "$SNAPSHOTS_DIR/preview/TestDark.expected"
}

@test "TestMinimal preview: palette-only matches snapshot" {
  run ghostty-theme-preview "$FIXTURES_DIR/themes/TestMinimal"
  [ "$status" -eq 0 ]
  assert_snapshot "TestMinimal preview" "$output" "$SNAPSHOTS_DIR/preview/TestMinimal.expected"
}

@test "TestMixed preview: comments/ws tolerated, invalid hex skipped" {
  run ghostty-theme-preview "$FIXTURES_DIR/themes/TestMixed"
  [ "$status" -eq 0 ]
  assert_snapshot "TestMixed preview" "$output" "$SNAPSHOTS_DIR/preview/TestMixed.expected"
}

@test "cursor-text rendered in preview (not applied via OSC but shown)" {
  run ghostty-theme-preview "$FIXTURES_DIR/themes/TestDark"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cursor-text"* ]]
}

@test "5-hex palette=2 skipped in preview (no 'palette  2' entry)" {
  run ghostty-theme-preview "$FIXTURES_DIR/themes/TestMixed"
  [ "$status" -eq 0 ]
  [[ "$output" != *"palette  2"* ]]
}

@test "missing file: exit 1 with diagnostic" {
  run ghostty-theme-preview /nonexistent/path
  [ "$status" -eq 1 ]
  [[ "$output" == *"preview: file not found:"* ]]
}

# --- --map mode (fzf preview invocation) -----------------------------------

@test "--map: known name resolves via TSV and matches direct-path output" {
  local map_file="$SCRATCH_DIR/preview-map.tsv"
  printf 'TestDark\t%s\n' "$FIXTURES_DIR/themes/TestDark" > "$map_file"
  run ghostty-theme-preview --map "$map_file" TestDark
  [ "$status" -eq 0 ]
  assert_snapshot "TestDark via --map" "$output" "$SNAPSHOTS_DIR/preview/TestDark.expected"
  rm -f "$map_file"
}

@test "--map: unknown name exits 1 with diagnostic" {
  local map_file="$SCRATCH_DIR/preview-map-miss.tsv"
  printf 'TestDark\t%s\n' "$FIXTURES_DIR/themes/TestDark" > "$map_file"
  run ghostty-theme-preview --map "$map_file" Ghost
  [ "$status" -eq 1 ]
  [[ "$output" == *"preview: theme not in map: Ghost"* ]]
  rm -f "$map_file"
}

@test "--map: missing map file exits 1" {
  run ghostty-theme-preview --map /nonexistent/map Anything
  [ "$status" -eq 1 ]
  [[ "$output" == *"preview: map file not found:"* ]]
}

@test "--help prints usage and exits 0" {
  run ghostty-theme-preview --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}
