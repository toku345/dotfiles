#!/usr/bin/env bats
# shellcheck shell=bash

# Coverage for assert_envelope_valid in dot_local/bin/executable_triple-review.
# Companion to ADR 0016 Decision 7 補強段落: automates the manual triple-review
# verification gate that previously had to be re-run by hand on every persona
# or prompt change.

bats_require_minimum_version 1.5.0
load test_helper_triple_review

# Unit-level coverage: only $SRC_SCRIPT (exported by test_helper at load time)
# is required. The full standard_env_triple_review fixture (git init, PATH
# stubs, scratch repo) is unnecessary because assert_envelope_valid is a
# pure function over a file path.
setup() {
  FIXTURE="$BATS_TEST_TMPDIR/summary.md"
  export FIXTURE
}

# Convenience: run the validator against $FIXTURE and stash REJECT_REASON in
# stdout via a deterministic prefix so tests can assert on the message
# content. `set +e` inside the inner shell is unnecessary because
# assert_envelope_valid returns rc rather than calling exit.
_run_validator() {
  run --separate-stderr bash -c "
    source '$SRC_SCRIPT'
    if assert_envelope_valid '$FIXTURE'; then
      printf 'PASS\n'
    else
      printf 'FAIL: %s\n' \"\$REJECT_REASON\"
    fi
  "
}

# =============================================================================
# Envelope structural check
# =============================================================================

@test "EV-1 envelope: empty file rejected" {
  : > "$FIXTURE"
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"missing or empty"* ]]
}

@test "EV-2 envelope: missing file rejected" {
  rm -f "$FIXTURE"
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"missing or empty"* ]]
}

@test "EV-3 envelope: persona prefix before heading rejected" {
  cat > "$FIXTURE" <<'EOF'
うちに任せるっちゃ！

### 対応必須

- something
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"first non-blank line"* ]]
}

@test "EV-4 envelope: wrong heading level rejected" {
  cat > "$FIXTURE" <<'EOF'
## 対応必須

- something
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"first non-blank line"* ]]
}

@test "EV-5 envelope: trailing text on heading line rejected" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須:

- something
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"first non-blank line"* ]]
}

@test "EV-6 envelope: leading blank lines tolerated" {
  printf '\n\n### 対応必須\n\n- something\n' > "$FIXTURE"
  _run_validator
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "EV-7 envelope: clean multi-section summary accepted" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須

- [high] race condition at server.go:42

### 要検討

- [medium] missing test coverage for retry path

### 対応不要

- nit on indentation (style)

### 矛盾

- reviewer A says X, reviewer B says Y; recommend X
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

# =============================================================================
# Persona marker scan (defense-in-depth)
# =============================================================================

@test "PM-1 persona: marker in prose rejected" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須

うちに任せるっちゃ！この問題は対応必須だっちゃ。
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"persona marker"* ]]
}

@test "PM-2 persona: ダーリン honorific in prose rejected" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須

ダーリン、これは要修正です。
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"persona marker"* ]]
}

@test "PM-3 persona: marker inside fenced code block accepted" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須

- Lum.md の追加例示の文言を確認:

```markdown
## エラー対応

エラーに遭遇したら好奇心と意気込みを表現する (例: 「うちに任せるっちゃ！」「これは興味深いっちゃ」)
```

該当 section に問題なし。
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "PM-4 persona: marker leaks AFTER closing code fence rejected" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須

```diff
+うちに任せるっちゃ
```

うちに任せるっちゃ！この diff の追加は問題だっちゃ。
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"persona marker"* ]]
}

@test "PM-5 persona: えへへ tic in prose rejected" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須

えへへ、見つけました。
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [[ "$output" == FAIL:* ]]
  [[ "$output" == *"persona marker"* ]]
}

@test "PM-6 persona: neutral japanese prose without markers accepted" {
  cat > "$FIXTURE" <<'EOF'
### 対応必須

- データ損失リスクが残るため修正が必要です。
- ロールバック手順の追記をお願いします。

### 要検討

- 命名規則を統一してください。
EOF
  _run_validator
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}
