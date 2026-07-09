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

よく使うコマンド: `chezmoi apply` / `chezmoi diff` / `chezmoi edit <file>` / `chezmoi add <file>` / `chezmoi update` (= git pull + apply)

### Encrypted Files

`.age` ファイルは二層モデル (`key.txt.age` → `~/key.txt` → `encrypted_*.age`)。**`~/key.txt` は絶対にコミットしない**。setup 手順・運用詳細は [docs/security.md](docs/security.md)。

### Pre-PR Review Gates

厚い変更の pre-PR gate は環境別に 2 系統 (共有 gate policy: `private_dot_codex/skills/pr-review/references/`):

- **Codex 利用可能環境**: Codex CLI の `$pr-review` skill (ターミナルから user 実行。Claude Code 内から自走させない — nested-bwrap 制約)
- **Codex 不可環境 (会社等)**: Claude Code の `/pr-review` skill + dynamic workflow (セッション内から起動可)

どちらも PR 必須 + fail-closed が default。draft PR を先に作成しておけば全 specialist が同じ base ref に収束する。詳細: [ADR 0029](docs/adr/0029-claude-pr-review-dynamic-workflow.md) / [docs/design/claude-pr-review.md](docs/design/claude-pr-review.md)。旧 `triple-review` bash orchestrator は 2026-06 に削除済み ([ADR 0012](docs/adr/0012-triple-review-bash-script.md) は Superseded)。

## Repository Structure

主要なツリー（自明なサブディレクトリは省略）:

- `private_dot_config/` → `~/.config/`（fish, ghostty, starship, tmux, karabiner 等）
- `private_dot_ssh/` → `~/.ssh/`（`config.tmpl` 1行目で machine-local `~/.ssh/config.local` を Include。host 固有・per-machine な SSH 設定はそこに置く＝chezmoi 非管理で `apply` 時に消えない）
- `private_dot_claude/` → `~/.claude/`（Claude Code 設定）
  - `skills/` ⚠️ Global scope: changes affect ALL projects. Avoid hardcoded paths; keep default behaviors opt-in.
  - `CLAUDE.md` は user-global Claude 指示（root の `CLAUDE.md` symlink とは別物）
- `.claude/` - このリポジトリの project スコープ Claude 設定（chezmoi 非管理）。`rules/` = path-scoped rules、`hooks/`、`settings.local.json` は machine-local・gitignore
- `.chezmoiscripts/` - one-time setup scripts run by chezmoi
- `.github/`, `docs/`, `images/`, `key.txt.age`（age 暗号鍵）

### chezmoi 命名規則の project 固有用法

- `.chezmoiignore` で `AGENTS.md` / `CLAUDE.md` は apply 除外済 (リポジトリドキュメントのため)
- **新規ファイル追加時は `chezmoi add ~/<target-path>` を使う** (mode から `private_` / `executable_` を auto-detect、prefix を手で付ける必要なし)。暗号化は `chezmoi add --encrypt`、template は `--template` フラグ
- security/mode-critical な prefix: `private_` (0600) / `executable_` (0755) / `encrypted_` (age)。直接 Write/cp で source dir に置く際は手動付与必要

### ADR ドキュメントスタイル

`docs/adr/**` 編集時の hard-wrap しないルールは path-scoped rule [.claude/rules/adr-style.md](.claude/rules/adr-style.md) に移設（該当ファイル参照時に自動ロード）。

## Key Configuration Files

### Git Worktree Commands (`gw`, `gb`, `gbd`)

- `git gtr` flags are long-form only (`--delete-branch`, `--track none`); short flags like `-D` do not exist. Always verify with `git gtr help <cmd>` or the source at `/opt/homebrew/Cellar/git-gtr/*/lib/commands/`
- `git gtr rm` returns exit 0 even when worktree removal fails (uses `continue` internally). Check worktree existence after removal to detect actual failure
- `%(worktreepath)` in `git for-each-ref` is set for both main and linked worktrees. To target only linked worktrees, explicitly exclude the main worktree's branch
- **git-gtr vs coreutils `gtr` collision**: both formulae ship a `gtr` binary (git-gtr's worktree shortcut vs coreutils' GNU `tr`). When coreutils relinks (`brew upgrade`/`reinstall coreutils`) it can grab `gtr` and unlink the **`git-gtr` binary too**, making `git gtr ...` fail with `'gtr' is not a git command` (git resolves subcommands via the `git-<name>` binary on PATH). Recover with `brew link --overwrite git-gtr` — we don't use GNU `tr`, so letting git-gtr own `gtr` is harmless

### Ghostty

Ghostty 設定の gotchas（config 直接編集・ホットリロード挙動）は path-scoped rule [.claude/rules/ghostty-config.md](.claude/rules/ghostty-config.md) に移設（`private_dot_config/ghostty/**` 編集時に自動ロード）。

### Fish Shell (`config.fish`)

メインの shell 設定。具体内容は `private_dot_config/fish/config.fish` を参照。

### Development Environment

- **git-gtr**: Git worktree runner (`git gtr new/go/list`)。`gw`/`gb`/`gbd` の内部実装。track mode 挙動は `/opt/homebrew/Cellar/git-gtr/*/lib/core.sh` で確認可能

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

Fish / シェル設定固有の罠（`$pipestatus`・`ls` 関数・`fish_add_path` の prepend・`switch (uname)` での OS 判定 等）は path-scoped rule [.claude/rules/fish-gotchas.md](.claude/rules/fish-gotchas.md) に移設（`*.fish` / fish config 編集時に自動ロード）。shell config の OS 別 deploy 非対称性（`.chezmoiignore` による fish/bash の deploy 取捨）は [.claude/rules/shell-deploy.md](.claude/rules/shell-deploy.md) に分離（`*.fish` / `dot_bash*` 編集時に自動ロード）。

## Bash Script Gotchas

`execfail` + `set -e` での `||` fallback dead code、wrapper 経由 self-exec の rc=126、deploy skew defense、Bash tool cwd persist による file leak 等は path-scoped rule [.claude/rules/shell-scripts.md](.claude/rules/shell-scripts.md) に移設（`*.sh` / `executable_*` / `.chezmoiscripts/` 編集時に自動ロード）。

## Go Template Usage Policy

Go Template の使用範囲（`.chezmoi.toml.tmpl` のみ）、CI での template 検証、chezmoi 自動提供環境変数は path-scoped rule [.claude/rules/go-templates.md](.claude/rules/go-templates.md) に移設（`*.tmpl` / `.chezmoiscripts/` 編集時に自動ロード）。

## Bats Testing (tests/bats/)

bats テストの罠（`executable_*` の mode 0644、source-guard パターン、silent-pass トラップ、OS-specific skip、Docker Ubuntu 24.04 CI parity recipe 等）は path-scoped rule [.claude/rules/bats-testing.md](.claude/rules/bats-testing.md) に移設（`tests/bats/**` 編集時に自動ロード）。

## Security

CI runs plaintext key / age encryption / secret pattern checks on pushes to main/master and on pull requests targeting main/master (`.github/workflows/security-checks.yml`). For details, see [docs/security.md](docs/security.md).

## Backup and Recovery

Recovery needs 3 things: GitHub access, 1Password access, `key.txt.age` password (stored in 1Password). See [docs/backup-restore.md](docs/backup-restore.md).

## Sandbox Gotchas

- `codex exec` / `codex login` may require `dangerouslyDisableSandbox: true` on macOS when authentication checks run inside sandbox (`system-configuration` access restriction; Rust `dynamic_store.rs` NULL object panic). AI automatically judges sandbox bypass; manual disable is rarely necessary
- `gh` commands require `dangerouslyDisableSandbox: true` — `excludedCommands` does not bypass macOS Seatbelt Mach service restrictions (`trustd` for TLS). See `docs/adr/0002-claude-code-sandbox-gh-investigation.md`
- `pgrep` / `ps` は sandbox 内で `sysmond` Mach service が deny され空 (rc≠0) を返す。失敗が silent に「子プロセスなし」へ縮退する罠。プロセス列挙に依存する script を Claude Code 経由で動かす場合は `dangerouslyDisableSandbox: true` が必要。bats では `pgrep -P $$` 可用性チェックで sandbox 内 skip するパターンを使う (naive な `pgrep -P 1` probe は「子プロセスが偶々無い」と「pgrep 不能」を混同して flaky になる。reference 実装は削除済み `skip_if_pgrep_unavailable`: `git log -- tests/bats/test_helper_triple_review.bash`)。詳細: [`docs/adr/0001`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#known-limitations)
- `chezmoi apply` / `chezmoi diff` require `dangerouslyDisableSandbox` (needs `~/.config/chezmoi/chezmoistate.boltdb`)
- `GODEBUG=x509usefallbackroots=1` is ineffective for `gh` — do not use
- `git push` works within the sandbox (SSH agent via `allowAllUnixSockets`, `known_hosts` via `allowRead`/`allowWrite`)
- 既存 remote branch へ push する前は `git fetch origin $(git branch --show-current)` → `git log --oneline --left-right --cherry-pick origin/$(git branch --show-current)...HEAD` で分岐を確認する。left (`<`) が出たら remote 側に未取り込み commit があるため、force せず rebase/cherry-pick 等で統合してから push する
- `git push -u` で `could not write config file .git/config` エラーが出たら upstream 設定失敗を疑う。詳細: [`docs/adr/0001`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#resolved-limitations)
- `denyOnly` bare globs (`*.key`, `.env.*`) only protect files within cwd — `sandbox-runtime` resolves them relative to cwd. Absolute-path entries (`~/.docker/config.json`) work system-wide. See [`docs/adr/0001-claude-code-sandbox-git-least-privilege.md`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#known-limitations). → User-side bare-name additions to `permissions.deny` (e.g. `Read(.env)`, `Read(id_ed25519)`) trigger `chezmoi apply` failures and `git status` ghost char-special pollution (Issue #212 / PR #216 removed our last batch). Anthropic baseline covers shell and tool configuration bare-names only (`.bashrc` / `.bash_profile` / `.gitconfig` / `.gitmodules` / `.idea` / `.mcp.json`); secret patterns (`.env` / `id_*` / `*.key`) are **not** baseline-covered — see ADR 0001 "Empirical baseline coverage snapshot" before adding new bare-name denies.
- Anthropic baseline の bare-name `permissions.deny` カバレッジを empirical に確認する手順: chezmoi source root で `cd ~/.local/share/chezmoi && ls -la | grep '^c'`。`crw-rw-rw- nobody nogroup 1, 3` の ghost char-special entry が baseline カバー対象の bare-name に対応。user-side で bare-name deny を追加するかの判断前に必ず実行する。baseline 非カバーパターン (`.env` / `id_*` / `*.key` 等) を追加しても cwd-relative best-effort 保護しか得られず、Issue #212 の fallout (`chezmoi apply` 失敗 + `git status` ghost 汚染) を引き起こす。Empirical snapshot は [ADR 0001 "Empirical baseline coverage snapshot"](docs/adr/0001-claude-code-sandbox-git-least-privilege.md) を参照。
- fish シェル経由の Bash ヒアドキュメントで `!` が `\!` にエスケープされることがある。`!` を含むファイルは `Write` ツールで直接書き込む
- secret-like file 名 (`id_ed25519` / `id_rsa` / `.env*` 等) の **存在判定**で `ls -la` を使うと permission gate に弾かれる。代替: `test -e <path> && echo exists || echo not present` または `find <dir> -maxdepth 1 -name <basename> -print` — 中身を読まないことが明確になり permission を通せる

## Agent Hooks

Codex project-local hooks are checked in under `.codex/hooks/` and wired by `.codex/hooks.json`. Codex requires hook trust review when hook definitions change, so inspect `/hooks` after pulling hook changes.

提供 Codex hook:

- **`verify-on-stop.sh`** — Stop event。`tests/bats/`・`dot_local/bin/executable_*`・`.chezmoiscripts/*.sh`・`.codex/hooks/*.sh`・`*.fish` 変更時のみ bats / shellcheck / `fish -n` を gate。失敗時 exit 2 で stop をブロック、連続 3 回 (`${XDG_STATE_HOME:-$HOME/.local/state}/codex/project-hooks/stop-hook-block-count.<repo-key>`) で自動許可
- **`fish-syntax-check.sh`** — PostToolUse `Edit|Write`。`*.fish` 編集時に `fish -n` で構文チェック、エラー時 `decision: block` JSON

Claude Code の machine-local hook 配線は `.claude/settings.local.json` 側で扱う。詳細は [docs/claude-code-hooks.md](docs/claude-code-hooks.md)。

一行 gotcha:

- macOS で pass / Ubuntu CI で fail する場合は `bats-docker-parity-runner` subagent で Docker Ubuntu 24.04 再走
- Stop hook 無限ループ時は該当 runtime の block-count file を削除する。repo root で `repo_key=$(printf '%s' "$(pwd -P)" | cksum | awk '{print $1}')` 後、Codex は `rm "${XDG_STATE_HOME:-$HOME/.local/state}/codex/project-hooks/stop-hook-block-count.$repo_key"`、Claude は `rm "${XDG_STATE_HOME:-$HOME/.local/state}/claude/project-hooks/stop-hook-block-count.$repo_key"`

## Claude Code Configuration Quirks

`outputStyle` 切替・`/config` UI の実挙動（effective default / toggle 時のみ書込）・undocumented キー（`verbose` / `viewMode` / `agentPushNotifEnabled` 等）・`claude -p --settings` の silent fallback と sentinel 検証パターンは path-scoped rule [.claude/rules/claude-code-config.md](.claude/rules/claude-code-config.md) に移設（`private_dot_claude/**` 編集時に自動ロード）。
