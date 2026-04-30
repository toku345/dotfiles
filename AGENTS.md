# AGENTS.md

This file provides guidance to coding agents (including Codex and Claude Code) when working with code in this repository.

## Compatibility Note

- `AGENTS.md` is the canonical file.
- Root `CLAUDE.md` is a symlink to this file for backward compatibility.

## Repository Overview

This is a dotfiles repository managed by [chezmoi](https://www.chezmoi.io/), a tool for managing personal configuration files across multiple machines. The repository contains configuration files for various development tools and environments.

## Common Commands

### Chezmoi Operations

**Worktree gotcha**: `chezmoi diff` / `chezmoi apply` always reads from the main source directory (`~/.local/share/chezmoi/`), not the current git worktree. Do not run `chezmoi apply` from a worktree — changes must be merged to main first.

**Source-path gotcha**: `chezmoi apply <source-path>` errors with `not managed`. chezmoi accepts only target paths (e.g. `~/.config/...`) as arguments. Run `chezmoi apply` without args to apply all managed files, or resolve with `chezmoi target-path <source-file>` first.

```bash
# Apply changes from the source directory to your home directory
chezmoi apply

# Edit a file in the source directory (opens in default editor)
chezmoi edit <file>

# Add a file from your home directory to the source state
chezmoi add <file>

# See what changes would be made
chezmoi diff

# Update the source state from the repository
chezmoi update

# Run chezmoi in verbose mode for debugging
chezmoi apply -v
```

### Encrypted Files

`.age` files use a two-layer model: `key.txt.age` (in repo, password-protected via 1Password) → `~/key.txt` (local age private key) → `encrypted_*.age` files (SSH config, Google IME dict, etc.). See [docs/security.md](docs/security.md) for details.

One-time setup:

```bash
brew install age
age -d -o ~/key.txt "$(chezmoi source-path)/key.txt.age"  # password from 1Password
chmod 600 ~/key.txt
chezmoi apply
```

**Critical**: never commit `~/key.txt`. Only `key.txt.age` belongs in the repo.

## Repository Structure

主要なツリー（自明なサブディレクトリは省略）:

- `private_dot_config/` → `~/.config/`（fish, ghostty, cmux, starship, tmux, karabiner 等）
- `private_dot_ssh/` → `~/.ssh/`
- `private_dot_claude/` → `~/.claude/`（Claude Code 設定）
  - `skills/` ⚠️ Global scope: changes affect ALL projects. Avoid hardcoded paths; keep default behaviors opt-in.
  - `CLAUDE.md` は user-global Claude 指示（root の `CLAUDE.md` symlink とは別物）
- `.chezmoiscripts/` - one-time setup scripts run by chezmoi
- `.github/`, `docs/`, `images/`, `key.txt.age`（age 暗号鍵）

### chezmoi 命名規則（target deploy を制御）

- `dot_<name>` → `.<name>`
- `private_<name>` → mode 0600（dir は 0700）
- `encrypted_<name>` → age 暗号化
- `executable_<name>` → mode 0755
- `*.tmpl` → Go text/template として処理してから配置
- `.chezmoiignore` → `chezmoi apply` から除外（例: `AGENTS.md`, `CLAUDE.md`）
- 主要 template: `.chezmoi.toml.tmpl`（chezmoi 設定、`scriptEnv` 定義）

## Key Configuration Files

### Git Worktree Commands (`gw`, `gb`, `gbd`)

- `git gtr` flags are long-form only (`--delete-branch`, `--track none`); short flags like `-D` do not exist. Always verify with `git gtr help <cmd>` or the source at `/opt/homebrew/Cellar/git-gtr/*/lib/commands/`
- `git gtr rm` returns exit 0 even when worktree removal fails (uses `continue` internally). Check worktree existence after removal to detect actual failure
- `%(worktreepath)` in `git for-each-ref` is set for both main and linked worktrees. To target only linked worktrees, explicitly exclude the main worktree's branch

### cmux (Terminal Multiplexer)

- cmux は libghostty を内蔵し、ターミナル描画設定は `~/.config/ghostty/config` を読む
- `cmux themes list` で読み込み元の Ghostty config パスを確認可能
- cmux 固有の設定（sidebar, shortcuts, automation 等）は `~/.config/cmux/settings.json`

### Ghostty Configuration

- 設定変更を即座に試す場合は `~/.config/ghostty/config` を直接編集する（worktree のソースではなく実ファイル）
- Ghostty は `Cmd+Shift+,` でホットリロード。`macos-titlebar-style` 等一部の設定は新しいウィンドウにのみ適用
- cmux は Ghostty config 変更後に再起動が必要な場合がある

### Fish Shell (`config.fish`)

The main shell configuration that sets up:

- Package managers: Homebrew, asdf
- Programming languages: Rust, Go, Java, Scala, OCaml, Haskell
- Development tools: direnv, shadowenv, fzf
- Custom aliases and functions for git operations

### Development Environment

- **asdf**: Version manager for multiple runtime versions
- **direnv**: Environment variable management per directory
- **fzf**: Fuzzy finder integration for history search and directory navigation
- **starship**: Cross-shell prompt
- **git-gtr**: Git worktree runner (`git gtr new/go/list`). Used internally by `gw`/`gb`/`gbd`. Track mode behavior can be verified in `/opt/homebrew/Cellar/git-gtr/*/lib/core.sh`

## Definition of Done（chezmoi 固有）

グローバル DoD に加え、このリポジトリでは変更種別に応じて以下を確認する。

### 設定ファイル変更時

- **構文チェック通過**: Fish shell は `chezmoi cat <file> | fish -n`（.tmpl でも安全）、その他は `chezmoi apply --dry-run` でエラーなし
- **Fish function testing**: After `chezmoi apply`, run `fish -c "cd /path/to/repo; func_name args"` for non-interactive execution. For functions using fzf or other interactive input, simulate the logic path directly
- **chezmoi diff 確認**: `chezmoi diff` で意図した差分のみが出力される
- **chezmoi apply 成功**: `chezmoi apply -v` がエラーなく完了する

### セキュリティ関連変更時

- **暗号化ファイルの整合性**: `.age` ファイルが正しく暗号化されている
- **平文シークレット不在**: `git diff --cached` にパスワード・鍵・トークンが含まれていない

### chezmoi 命名規則変更時

- **命名規則準拠**: `dot_`, `private_`, `encrypted_` プレフィックスが正しい
- **ターゲットパス確認**: `chezmoi target-path <source-file>` で意図した配置先を確認

## Fish Shell Gotchas

- `test -n (command substitution)` with empty output becomes `test -n` (no args), which returns **true** in fish. Always capture into a variable first: `set -l val (cmd); test -n "$val"`
- `$pipestatus` is available after command substitution (`set x (a | b)` still exposes `$pipestatus[1..N]`). Branch on individual pipe stages instead of a single `$status` to avoid misclassifying left-side failures as right-side cancellations.
- `ls` is an embedded fish function that adds `--color=auto`/`-F`. In pipelines whose consumer needs raw filenames (e.g. fzf input), use `command ls -1 --` to bypass the function and any future user override (eza/lsd/icon wrappers).
- `return ""` (empty arg from an unset variable) fails with `invalid integer` and exits 2. Guard with `test -n "$v"; and return $v; or return 1`.
- fzf exit codes: `0`=selection, `1`=no match, `2`=error, `126`/`127`=become-action errors, `130`=Ctrl-C/Esc. Treat `1` and `130` as user cancel; everything else fail-loud.
- `fish -c` subprocesses source `config.fish` by default. If the parent prepended a dir to `PATH`, `fish_add_path` inside `config.fish` may reorder via `fish_user_paths` and push the new dir behind system binaries. Use `fish --no-config -c` whenever a test stub or PATH-override must win in the child.
- `set -l out (cmd)` splits multi-line stdout into a fish list, one element per line. Passing a bare `$out` as an argument then expands to that many positional args. Capture with `| string collect` (trims trailing newlines, preserves internal ones) or explicitly join before passing.
- In `set -l x (cmd | string collect)`, `$status` reflects `string collect`'s exit (1 if no input, 0 otherwise), not `cmd`'s. Use `$pipestatus[1]` immediately on the next line before any other command resets it.

### OS Detection in Config Files

`config.fish` 等 shell config では runtime OS 判定を使う。fish 公式仕様に従い `switch (uname)` が canonical:

```fish
switch (uname)
    case Darwin
        # macOS
    case Linux
        # Linux
end
```

## Bash Script Gotchas

- **`shopt -s execfail` + `set -Eeuo pipefail` で `||` fallback が dead code**: `set -e` が exec 失敗時に `||` 分岐より先に shell を終了させる。fallback を実働させるには `set +e` / `set -e` で exec を括る (bash 5.3 実機検証済)
- **ShellCheck SC2093 false positive on execfail sites**: execfail 併用時の exec 後続コードは意図通り。該当行に `# shellcheck disable=SC2093` + 理由コメントを添える (file 全体 disable は避ける)
- **外部 wrapper 経由の self-exec で `execve($0)` は git 上 0644 の `executable_*` で rc=126**: `exec "${wrapper[@]}" "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"` と書いて bash interpreter 経由で再入する。mode に依存しない (caffeinate/systemd-inhibit/setsid 等すべて該当)

## Go Template Usage Policy

### Principles

- Go Templates は chezmoi 設定ファイル (`.chezmoi.toml.tmpl`) のみで使う
- shell scripts (`.chezmoiscripts/`) や config ファイルでは環境変数 / runtime 判定を使う

理由: ShellCheck / エディタ拡張との互換性、`.tmpl` 拡張子を避けることでシンタックスハイライトが保たれる。

### CI での chezmoi テンプレート検証

- `promptBoolOnce` 等の init 専用関数は `chezmoi execute-template` 単体では未定義エラーになる。`--init` フラグで有効化する
- テンプレートで chezmoi data を参照する際、CI 等データ未定義環境では `.key` が失敗する。`index . "key"` を使えばキー未定義時に nil を返しエラーにならない

### Environment Variables (chezmoi 自動提供)

`.chezmoiscripts/` 配下のスクリプトに自動付与される: `$CHEZMOI` (=`1`), `$CHEZMOI_OS`, `$CHEZMOI_ARCH`, `$CHEZMOI_SOURCE_DIR`。`scriptEnv` で独自変数を追加可だが、上記の自動提供変数は上書きしないこと（警告が出る）。

## Bats Testing (tests/bats/)

- **`executable_*` は git で mode 0644** (chezmoi apply 時に 0755): PATH 経由で直接実行するテストは `ln -sf` ではなく exec wrapper (`exec bash "$SRC" "$@"`) を使う
- **Source-guard パターン**: `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi` を末尾に置くと bats で `source` して関数単体テスト可能
- **`run bash -c "source '$SRC'; func args"` 形式**: スクリプトの `set -Eeuo pipefail` を bats 本体に漏らさない
- **`run --separate-stderr`**: stderr 単独アサーションに使用。bats 1.5+ (`bats_require_minimum_version 1.5.0` 宣言必須)
- **async プロセステスト**: 固定 `sleep` より polling ループ (`for ((i=0; i<30; i++)); do cond && break; sleep 0.1; done`) が CI (Ubuntu runner) で flakiness を回避
- **PATH-override スタブ内の `command date` は PATH を再参照**: スタブ自身を再帰呼び出して fork 爆発する。`/bin/date` 等の絶対パスを使う
- **macOS ローカル pass の落とし穴**: `~/.local/bin/*` にある chezmoi apply 済みスクリプトが PATH shadow でテスト stub を隠蔽しバグを温存する。Docker Ubuntu で cross-check する

### Docker での Ubuntu CI parity 検証

push 前に CI (ubuntu-latest + `apt-get install bats`) と同等環境で実走:

```bash
docker run --rm -v "$(pwd):/work" -w /work ubuntu:24.04 bash -c '
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bats git procps >/dev/null
  bats tests/bats/
'
```

## Security

CI runs plaintext key / age encryption / secret pattern checks on pushes to main/master and on pull requests targeting main/master (`.github/workflows/security-checks.yml`). For details, see [docs/security.md](docs/security.md).

## Backup and Recovery

Recovery needs 3 things: GitHub access, 1Password access, `key.txt.age` password (stored in 1Password). See [docs/backup-restore.md](docs/backup-restore.md).

## Sandbox Gotchas

- `codex exec` / `codex login` may require `dangerouslyDisableSandbox: true` on macOS when authentication checks run inside sandbox (`system-configuration` access restriction; Rust `dynamic_store.rs` NULL object panic). AI automatically judges sandbox bypass; manual disable is rarely necessary
- `gh` commands require `dangerouslyDisableSandbox: true` — `excludedCommands` does not bypass macOS Seatbelt Mach service restrictions (`trustd` for TLS). See `docs/adr/0002-claude-code-sandbox-gh-investigation.md`
- `chezmoi apply` / `chezmoi diff` require `dangerouslyDisableSandbox` (needs `~/.config/chezmoi/chezmoistate.boltdb`)
- `GODEBUG=x509usefallbackroots=1` is ineffective for `gh` — do not use
- `git push` works within the sandbox (SSH agent via `allowAllUnixSockets`, `known_hosts` via `allowRead`/`allowWrite`)
- `git push -u` needs `.git/config` write access to persist upstream tracking. In this repository's current sandbox, cwd write access covers `.git/config`, so no extra allowlist entry is needed. If Git reports `could not write config file .git/config`, do not assume upstream was set. See [`docs/adr/0001-claude-code-sandbox-git-least-privilege.md`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#resolved-limitations)
- `denyOnly` bare globs (`*.key`, `.env.*`) only protect files within cwd — `sandbox-runtime` resolves them relative to cwd. Absolute-path entries (`~/.docker/config.json`) work system-wide. See [`docs/adr/0001-claude-code-sandbox-git-least-privilege.md`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#known-limitations)
- fish シェル経由の Bash ヒアドキュメントで `!` が `\!` にエスケープされることがある。`!` を含むファイルは `Write` ツールで直接書き込む

## Claude Code Configuration Quirks

- `/output-style <name>` は公式スラッシュコマンドとして**存在しない**。切替は `/config` メニュー経由のみで、反映は次の新規セッションから。`--output-style` CLI フラグも公式 CLI reference に未記載
- User-scope `~/.claude/settings.json` の `outputStyle` はシステムプロンプトを直接置換し、headless `claude -p` にも適用される (Agent tool 経由の subagents には伝播しない: 公式仕様 "Output styles directly affect the main agent loop")
- 本リポジトリは JUIZ persona を user-scope default に設定 (ADR 0015 で容認)
- リポジトリ単位の上書きは `<repo>/.claude/settings.local.json` で `outputStyle` を指定 (precedence 上 project-local > user)
- triple-review の anti-pollution prompt は撤去済 (ADR 0015 Decision 5)
- 詳細: `docs/adr/0015-multi-persona-output-styles.md`
- `verbose: true` は **公式設定として未文書化**。documented キーは `viewMode`（`"default"` / `"verbose"` / `"focus"`、default は `"default"`）。verbose な transcript view を維持するには `"viewMode": "verbose"` を明示する必要がある（公式 settings reference: <https://code.claude.com/docs/en/settings>）。`--verbose` CLI フラグ (<https://code.claude.com/docs/en/cli-reference>) は別物で、ランタイム上書きとして `viewMode` 設定とは独立に効く

