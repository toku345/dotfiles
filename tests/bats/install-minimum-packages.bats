#!/usr/bin/env bats
# shellcheck shell=bash

bats_require_minimum_version 1.5.0

require_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local count
  # grep -c exits 1 when the count is 0. That count is a valid outcome.
  count="$(grep -c -F -- "$pattern" "$file" || true)"
  if [ -z "$count" ]; then
    echo "grep failed while counting [$pattern] in $file" >&2
    return 1
  fi
  if [ "$count" -eq "$expected" ]; then
    return 0
  fi
  echo "expected $expected occurrence(s) of [$pattern] in $file, found $count" >&2
  return 1
}

write_log_stub() {
  local path="$1"
  local log="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '#!/bin/sh' \
    "printf '%s\\n' \"\$*\" >> '$log'" \
    >"$path"
  chmod +x "$path"
}

write_linuxbrew_stub() {
  local log="$1"
  local path="$BATS_TEST_TMPDIR/linuxbrew/bin/brew"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$log'
if [ "\$1" = "shellenv" ]; then
  printf 'export PATH="%s:\$PATH"\n' "\${0%/*}"
fi
EOF
  chmod +x "$path"
}

diff_log() {
  local log="$1"
  local expected="$BATS_TEST_TMPDIR/expected.txt"
  cat >"$expected"
  diff -u "$expected" "$log"
}

require_rewritten_linuxbrew_path() {
  local literal="/home/linuxbrew/.linuxbrew/bin/brew"
  local replacement="$BATS_TEST_TMPDIR/linuxbrew/bin/brew"
  local source_script="$REPO_ROOT/.chezmoiscripts/run_once_before_install-minimum-packages.sh"
  local body
  require_count 2 "$literal" "$source_script"
  body="$(cat "$source_script")"
  printf '%s\n' "${body//"$literal"/"$replacement"}" >"$INSTALLER"
  require_count 0 "$literal" "$INSTALLER"
  require_count 2 "$replacement" "$INSTALLER"
  require_count 1 "Error: Linuxbrew not found or not executable at /home/linuxbrew/.linuxbrew. See docs/linux-setup.md" "$INSTALLER"
}

assert_brew_absent_from_path() {
  [ ! -e "$STUB_BIN/brew" ]
}

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  INSTALLER="$BATS_TEST_TMPDIR/install-minimum-packages.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  BREW_LOG="$BATS_TEST_TMPDIR/logs/brew.log"
  SUDO_LOG="$BATS_TEST_TMPDIR/logs/sudo.log"

  require_rewritten_linuxbrew_path

  mkdir -p "$BATS_TEST_TMPDIR/logs" "$STUB_BIN"
  : >"$BREW_LOG"
  : >"$SUDO_LOG"
  write_log_stub "$STUB_BIN/sudo" "$SUDO_LOG"
}

@test "darwin" {
  local os="darwin"
  write_log_stub "$STUB_BIN/brew" "$BREW_LOG"
  run --separate-stderr env -i \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    CHEZMOI_OS="$os" \
    sh "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
  diff -u /dev/null "$SUDO_LOG"
  diff_log "$BREW_LOG" <<'EOF'
update
install coreutils git gitleaks git-delta starship fzf eza bat fd ripgrep
install tmux direnv shadowenv asdf age fish nano aspell gh herdr
install coderabbitai/tap/git-gtr
install --cask karabiner-elements
install --cask font-fira-code-nerd-font font-fira-mono-nerd-font font-hack-nerd-font font-hackgen-nerd
EOF
}

@test "linux success" {
  local os="linux"
  write_linuxbrew_stub "$BREW_LOG"
  assert_brew_absent_from_path
  run --separate-stderr env -i \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    CHEZMOI_OS="$os" \
    sh "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
  diff_log "$SUDO_LOG" <<'EOF'
apt-get update
apt-get install -y build-essential curl file git procps sqlite3
EOF
  diff_log "$BREW_LOG" <<'EOF'
shellenv
update
install gh tmux starship fzf eza bat fd ripgrep git-delta direnv nano aspell gitleaks asdf herdr
install coderabbitai/tap/git-gtr
EOF
}

@test "linux missing" {
  local os="linux"
  write_log_stub "$STUB_BIN/brew" "$BREW_LOG"
  run --separate-stderr env -i \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    CHEZMOI_OS="$os" \
    sh "$INSTALLER"
  [ "$status" -eq 1 ]
  [ "$stderr" = "Error: Linuxbrew not found or not executable at /home/linuxbrew/.linuxbrew. See docs/linux-setup.md" ]
  diff_log "$SUDO_LOG" <<'EOF'
apt-get update
apt-get install -y build-essential curl file git procps sqlite3
EOF
  diff -u /dev/null "$BREW_LOG"
}

@test "empty" {
  local os=""
  write_log_stub "$STUB_BIN/brew" "$BREW_LOG"
  run --separate-stderr env -i \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    CHEZMOI_OS="$os" \
    sh "$INSTALLER"
  [ "$status" -eq 1 ]
  [ "$stderr" = "Error: unsupported CHEZMOI_OS='unset'" ]
  diff -u /dev/null "$SUDO_LOG"
  diff -u /dev/null "$BREW_LOG"
}

@test "garbage" {
  local os="freebsd"
  write_log_stub "$STUB_BIN/brew" "$BREW_LOG"
  run --separate-stderr env -i \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    CHEZMOI_OS="$os" \
    sh "$INSTALLER"
  [ "$status" -eq 1 ]
  [ "$stderr" = "Error: unsupported CHEZMOI_OS='freebsd'" ]
  diff -u /dev/null "$SUDO_LOG"
  diff -u /dev/null "$BREW_LOG"
}
