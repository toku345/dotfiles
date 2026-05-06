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

## Repository Structure

主要なツリー（自明なサブディレクトリは省略）:

- `private_dot_config/` → `~/.config/`（fish, ghostty, cmux, starship, tmux, karabiner 等）
- `private_dot_ssh/` → `~/.ssh/`
- `private_dot_claude/` → `~/.claude/`（Claude Code 設定）
  - `skills/` ⚠️ Global scope: changes affect ALL projects. Avoid hardcoded paths; keep default behaviors opt-in.
  - `CLAUDE.md` は user-global Claude 指示（root の `CLAUDE.md` symlink とは別物）
- `.chezmoiscripts/` - one-time setup scripts run by chezmoi
- `.github/`, `docs/`, `images/`, `key.txt.age`（age 暗号鍵）

### chezmoi 命名規則の project 固有用法

- `.chezmoiignore` で `AGENTS.md` / `CLAUDE.md` は apply 除外済 (リポジトリドキュメントのため)
- **新規ファイル追加時は `chezmoi add ~/<target-path>` を使う** (mode から `private_` / `executable_` を auto-detect、prefix を手で付ける必要なし)。暗号化は `chezmoi add --encrypt`、template は `--template` フラグ
- security/mode-critical な prefix: `private_` (0600) / `executable_` (0755) / `encrypted_` (age)。直接 Write/cp で source dir に置く際は手動付与必要

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

- `test -n (command substitution)` with empty output becomes `test -n` (no args), which returns **true** in fish. Always capture into a variable first: `set -l val (cmd); test -n "$val"`
- `$pipestatus` is available after command substitution (`set x (a | b)` still exposes `$pipestatus[1..N]`). Branch on individual pipe stages instead of a single `$status` to avoid misclassifying left-side failures as right-side cancellations.
- `ls` is an embedded fish function that adds `--color=auto`/`-F`. In pipelines whose consumer needs raw filenames (e.g. fzf input), use `command ls -1 --` to bypass the function and any future user override (eza/lsd/icon wrappers).
- `return ""` (empty arg from an unset variable) fails with `invalid integer` and exits 2. Guard with `test -n "$v"; and return $v; or return 1`.
- fzf exit codes: `0`=selection, `1`=no match, `2`=error, `126`/`127`=become-action errors, `130`=Ctrl-C/Esc. Treat `1` and `130` as user cancel; everything else fail-loud.
- `fish -c` subprocesses source `config.fish` by default. If the parent prepended a dir to `PATH`, `fish_add_path` inside `config.fish` may reorder via `fish_user_paths` and push the new dir behind system binaries. Use `fish --no-config -c` whenever a test stub or PATH-override must win in the child.
- `set -l out (cmd)` splits multi-line stdout into a fish list, one element per line. Passing a bare `$out` as an argument then expands to that many positional args. Capture with `| string collect` (trims trailing newlines, preserves internal ones) or explicitly join before passing.
- In `set -l x (cmd | string collect)`, `$status` reflects `string collect`'s exit (1 if no input, 0 otherwise), not `cmd`'s. Use `$pipestatus[1]` immediately on the next line before any other command resets it.
- `fish_add_path` (フラグなし) は **prepend** で BSD `date`/`sed`/`cp` 等を GNU 版で shadow する罠あり。gap-fill だけ欲しい場合は `-a` (append) を使う。例: macOS で GNU `timeout` が必要な場合 `fish_add_path -a /opt/homebrew/opt/coreutils/libexec/gnubin` (`brew install coreutils` 後でも unprefixed binary は PATH 未登録、`brew link coreutils` も g-prefix 版のみ生成)。`fish_user_paths` universal var の更新は新規 fish session のみ反映、現在実行中の Claude Code subprocess には Claude 再起動まで届かない

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
- **Deploy skew defense**: chezmoi で deploy される asset (output-styles / themes / 辞書 等) に依存する script は、asset 内に sentinel コメント (例: `<!-- COMPONENT_VX -->`) を埋め込み、script 側 preflight で grep verify する。file 存在のみの check は corrupt / truncated / 古い asset を通してしまう。err 文には `chezmoi apply -v` 復旧手順を併記する

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
- **OS-specific path の skip パターン**: `[[ "$(uname)" == "Linux" ]] || skip "<production-code-path reason>"`。reason は production gating を引用する (例: "gated by `case Linux)` in `select_sleep_inhibitor_cmd`")。「環境に X が無いから」ではなく「production もそこを通らないから」と書くことで coverage claim の正直さを保つ
- **BW01 警告 + exit 127** in `run` 出力 = `command not found`。診断: PATH-override stub が subshell に伝わっていない、または被テスト関数が呼ぶ transitive dep (例: `timeout`) が host に不在で stub 対象外
- **silent-pass トラップ**: `[ "$status" -ne 0 ]` は real failure (timeout 124, signal 128+N) と command-not-found (127) を**両方とも満たす**。timeout-bounded / signal-bounded 検証では `-eq 124` 等の具体的 exit code を使う (`-ne 0` ではなく) — host に dep が無い時に偽陽 pass しないようにする

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
- `git push -u` で `could not write config file .git/config` エラーが出たら upstream 設定失敗を疑う。詳細: [`docs/adr/0001`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#resolved-limitations)
- `denyOnly` bare globs (`*.key`, `.env.*`) only protect files within cwd — `sandbox-runtime` resolves them relative to cwd. Absolute-path entries (`~/.docker/config.json`) work system-wide. See [`docs/adr/0001-claude-code-sandbox-git-least-privilege.md`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#known-limitations)
- fish シェル経由の Bash ヒアドキュメントで `!` が `\!` にエスケープされることがある。`!` を含むファイルは `Write` ツールで直接書き込む

## Claude Code Hooks

検証ループ用 hook スクリプトが `.claude/hooks/` に配置されている (本体はコミット対象、配線は `.claude/settings.local.json` で local 限定)。

提供 hook (配線 JSON 例・配置原則・詳細は [docs/claude-code-hooks.md](docs/claude-code-hooks.md)):

- **`verify-on-stop.sh`** — Stop event。`tests/bats/`・`dot_local/bin/executable_*`・`.chezmoiscripts/*.sh`・`*.fish` 変更時のみ bats / shellcheck / `fish -n` を gate。失敗時 exit 2 で stop をブロック、連続 3 回 (`.claude/.stop-hook-block-count`) で自動許可
- **`fish-syntax-check.sh`** — PostToolUse `Edit|Write`。`*.fish` 編集時に `fish -n` で構文チェック、エラー時 `decision: block` JSON

一行 gotcha:

- macOS で pass / Ubuntu CI で fail する場合は `bats-docker-parity-runner` subagent で Docker Ubuntu 24.04 再走
- Stop hook 無限ループ時は `rm .claude/.stop-hook-block-count`

## Claude Code Configuration Quirks

- `outputStyle` 切替は `/config` メニュー経由のみ (公式スラッシュコマンド・CLI フラグ未提供)、反映は次の新規セッションから
- `outputStyle` はシステムプロンプトを直接置換し headless `claude -p` にも適用 (Agent tool 経由の subagents には伝播しない)
- precedence: project-local (`<repo>/.claude/settings.local.json`) > user-global (`~/.claude/settings.json`)
- 本リポジトリは JUIZ persona を user-global default に設定。triple-review の anti-pollution prompt は撤去済。詳細: `docs/adr/0015-multi-persona-output-styles.md`
- `verbose: true` (公式 doc 未記載だが実在) — UI ラベル "Verbose output"、default `true`、turn-by-turn logging を制御 (`--verbose` CLI flag の persistent 版)
- `viewMode` (`"default"` / `"verbose"` / `"focus"`、default `"default"`) — startup transcript view を制御。`verbose` とは別レイヤーで両者独立。verbose 表示にしたければ明示設定必要。<https://code.claude.com/docs/en/settings>
- `/config` UI 表示値は **effective default**（stored ≠ displayed）。settings.json に該当キーが無くても UI は default を表示する。**閲覧のみでは settings.json は書き換わらず**、UI で toggle した時のみ書き込まれる (2026-05-02 実機検証)
- `/config` toggle 後の運用: `chezmoi diff` で新規キー確認 → 公式 doc 照会 → default / undocumented キーは `chezmoi apply` で live をクリーンアップ (source 主導削除)、必要なキーのみ `chezmoi re-add` で source に取り込み
- `agentPushNotifEnabled` (公式 doc 未記載) — UI ラベル "Push when Claude decides"、default `true`。実モバイル push は Remote Control 有効時のみ発火 (changelog 2026-04-15)
- `teammateMode` (documented, default `"auto"`) — agent team teammates 表示モード (`auto` / `in-process` / `tmux`)。明示値が default と同一なら settings 記載は redundant
- `claude -p --settings '{"outputStyle":"X"}'` は X が live に未配備/壊れていても rc=0/stderr 空で default style にフォールバックする (claude 2.1.126 で実機確認)。output-style 依存 automation は file 存在 check ではなく**埋め込み sentinel 文字列の grep 検証**を preflight に置く (例: `dot_local/bin/executable_triple-review` の `require_output_style_triple_review`)

