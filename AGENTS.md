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

### Working with Templates

Files ending in `.tmpl` are chezmoi templates that use Go's text/template syntax. The primary template is:

- `.chezmoi.toml.tmpl` - Chezmoi configuration (defines `scriptEnv` for scripts)

### Encrypted Files

Files with `.age` extension are encrypted using the age encryption tool. This repository uses a **two-layer security model**:

#### Security Architecture

```text
key.txt.age (in repository, password-protected)
    ↓ Decrypt with password from 1Password
~/key.txt (local age identity/private key)
    ↓ Decrypt other encrypted files
encrypted_*.age (SSH config, Google IME dictionary, etc.)
```

**Key Points:**
- `key.txt.age` is stored in the repository, encrypted with a password (scrypt)
- The password is stored in 1Password
- Only those with the password can extract the age private key
- The age private key is used to decrypt other encrypted files

#### Working with Encrypted Files

```bash
# Install age
brew install age

# Decrypt key.txt.age to get the private key (one-time setup)
age -d -o ~/key.txt "$(chezmoi source-path)/key.txt.age"
# Enter password from 1Password

# Set correct permissions
chmod 600 ~/key.txt

# Chezmoi will automatically use ~/key.txt to decrypt other files
chezmoi apply
```

**Note:** Never commit `~/key.txt` (the unencrypted private key) to the repository. Only `key.txt.age` (password-protected) should be in the repository.

## Repository Structure

- `private_dot_config/` - Configuration files that will be placed in `~/.config/`
  - `asdf/` - asdf version manager configuration
  - `private_fish/` - Fish shell configuration
  - `cmux/` - cmux terminal multiplexer settings
  - `ghostty/` - Ghostty terminal configuration
  - `git/` - Git configuration
  - `google_ime/` - Google IME dictionary
  - `iterm2/` - iTerm2 terminal preferences
  - `nano/` - Nano editor configuration
  - `private_karabiner/` - Karabiner-Elements keyboard customization
  - `starship.toml` - Starship prompt configuration
  - `tmux/` - Tmux configuration
- `private_dot_ssh/` - SSH configuration
- `private_dot_claude/` - Claude Code configuration
  - `skills/` - Claude Code skills (maps to `~/.claude/skills/`)
    - ⚠️ Global scope: changes affect ALL projects. Avoid hardcoded paths; keep default behaviors opt-in.
  - `agents/` - Claude Code custom agents
  - `settings.json` - Claude Code settings
  - `CLAUDE.md` - Global Claude Code instructions (distinct from root `CLAUDE.md` symlink)
  - `executable_statusline-command.sh` - Status line script
- `.chezmoiscripts/` - One-time setup scripts run by chezmoi
- `.github/` - GitHub Actions workflows (CI, security checks)
- `docs/` - Detailed documentation (security, backup/restore)
- `dot_ocamlinit` - OCaml initialization file
- `images/` - Documentation images
- `key.txt.age` - Encrypted age key

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

## Working with This Repository

When making changes:

1. Edit files in the chezmoi source directory (`~/.local/share/chezmoi/`)
2. Test changes with `chezmoi diff` before applying
3. Apply changes with `chezmoi apply`
4. Commit changes to git from the source directory

### Responding to PR Review Comments

1. Verify each finding against codebase facts (trace code paths, confirm shell control flow semantics)
2. Classify Accept/Reject with evidence before starting implementation
3. When findings depend on external tool behavior, verify in a test repository

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

## Go Template Usage Policy

### Fish Shell Gotchas

- `test -n (command substitution)` with empty output becomes `test -n` (no args), which returns **true** in fish. Always capture into a variable first: `set -l val (cmd); test -n "$val"`
- `$pipestatus` is available after command substitution (`set x (a | b)` still exposes `$pipestatus[1..N]`). Branch on individual pipe stages instead of a single `$status` to avoid misclassifying left-side failures as right-side cancellations.
- `ls` is an embedded fish function that adds `--color=auto`/`-F`. In pipelines whose consumer needs raw filenames (e.g. fzf input), use `command ls -1 --` to bypass the function and any future user override (eza/lsd/icon wrappers).
- `return ""` (empty arg from an unset variable) fails with `invalid integer` and exits 2. Guard with `test -n "$v"; and return $v; or return 1`.
- fzf exit codes: `0`=selection, `1`=no match, `2`=error, `126`/`127`=become-action errors, `130`=Ctrl-C/Esc. Treat `1` and `130` as user cancel; everything else fail-loud.

### CI での chezmoi テンプレート検証

- `promptBoolOnce` 等の init 専用関数は `chezmoi execute-template` 単体では未定義エラーになる。`--init` フラグで有効化する
- テンプレートで chezmoi data を参照する際、CI 等データ未定義環境では `.key` が失敗する。`index . "key"` を使えばキー未定義時に nil を返しエラーにならない

### Principles

- Use Go Templates only in chezmoi configuration files (`.chezmoi.toml.tmpl`)
- Use environment variables or runtime detection in shell scripts (`.chezmoiscripts/`) and config files

### Rationale

- Full compatibility with ShellCheck and editor extensions
- Syntax highlighting preserved by avoiding `.tmpl` extension

### Environment Variables

chezmoi automatically provides environment variables to scripts in `.chezmoiscripts/`:

- `$CHEZMOI` - Set to `1` when run by chezmoi
- `$CHEZMOI_OS` - OS type (darwin, linux, etc.)
- `$CHEZMOI_ARCH` - Architecture (arm64, amd64, etc.)
- `$CHEZMOI_SOURCE_DIR` - chezmoi source directory

**Note:** You can use `scriptEnv` to define custom variables, but do not override auto-provided variables above - they will cause warnings.

### OS Detection in Config Files

Config files like `config.fish` use runtime OS detection. According to [fish-shell official documentation](https://fishshell.com/docs/current/language.html), `switch (uname)` is the canonical way:

```fish
switch (uname)
    case Darwin
        # macOS
    case Linux
        # Linux
end
```

## Security

### Automated Security Checks

This repository includes CI/CD security checks that run automatically on every push and pull request:

- **Plaintext Key Detection** - Prevents accidental commit of unencrypted `~/key.txt`
- **Age Encryption Verification** - Validates all `.age` files are properly encrypted
- **Secret Pattern Detection** - Scans for AWS keys, private keys, GitHub tokens, and API keys

The workflow runs in GitHub Actions (`.github/workflows/security-checks.yml`) and will fail if any security issues are detected.

### Security Best Practices

**Critical Rules:**
- DO commit `key.txt.age` (password-protected)
- NEVER commit `~/key.txt` (plaintext private key)
- NEVER commit plaintext secrets or API keys

For detailed security procedures, see [docs/security.md](docs/security.md)

## Backup and Recovery Strategy

Disaster recovery requires only **3 things**:

1. **GitHub account access** - to clone the repository
2. **1Password account access** - to retrieve the key.txt.age password
3. **key.txt.age password** - stored in 1Password

For detailed setup and recovery instructions, see [docs/backup-restore.md](docs/backup-restore.md)

## Sandbox Gotchas

- `codex exec` / `codex login` may require `dangerouslyDisableSandbox: true` on macOS when authentication checks run inside sandbox (`system-configuration` access restriction; Rust `dynamic_store.rs` NULL object panic). AI automatically judges sandbox bypass; manual disable is rarely necessary
- `gh` commands require `dangerouslyDisableSandbox: true` — `excludedCommands` does not bypass macOS Seatbelt Mach service restrictions (`trustd` for TLS). See `docs/adr/0002-claude-code-sandbox-gh-investigation.md`
- `chezmoi apply` / `chezmoi diff` require `dangerouslyDisableSandbox` (needs `~/.config/chezmoi/chezmoistate.boltdb`)
- `GODEBUG=x509usefallbackroots=1` is ineffective for `gh` — do not use
- `git push` works within the sandbox (SSH agent via `allowAllUnixSockets`, `known_hosts` via `allowRead`/`allowWrite`)
- `git push -u` needs `.git/config` write access to persist upstream tracking. In this repository's current sandbox, cwd write access covers `.git/config`, so no extra allowlist entry is needed. If Git reports `could not write config file .git/config`, do not assume upstream was set. See [`docs/adr/0001-claude-code-sandbox-git-least-privilege.md`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#resolved-limitations)
- `denyOnly` bare globs (`*.key`, `.env.*`) only protect files within cwd — `sandbox-runtime` resolves them relative to cwd. Absolute-path entries (`~/.docker/config.json`) work system-wide. See [`docs/adr/0001-claude-code-sandbox-git-least-privilege.md`](docs/adr/0001-claude-code-sandbox-git-least-privilege.md#known-limitations)
- fish シェル経由の Bash ヒアドキュメントで `!` が `\!` にエスケープされることがある。`!` を含むファイルは `Write` ツールで直接書き込む

## Important Notes

- This repository uses chezmoi's naming conventions:
  - `dot_` prefix becomes `.` in the target
  - `private_` prefix sets permissions to 0600
  - `encrypted_` prefix indicates age-encrypted files
  - `.chezmoiignore` lists files excluded from `chezmoi apply` (e.g., `AGENTS.md`, `CLAUDE.md`)
- Template files (`.tmpl`) are processed before being applied to the target system
- The repository includes configurations for macOS-specific tools (Homebrew, iTerm2, Karabiner)
- **Security**: All sensitive files are encrypted with age. The age private key itself is password-protected in the repository.
