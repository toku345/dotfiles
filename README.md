# toku345/dotfiles

toku345's dotfiles managed by chezmoi.

## Setup

Every machine runs the same bootstrap; the Codex and Fugu steps are optional
and per machine.

### 1. Install prerequisites

- [chezmoi](https://www.chezmoi.io/install/)
- age, Bash 5+, and uv

   ```sh
   brew install age bash uv
   ```

   Managed tools such as `brew-reviewed-upgrade` and `ghostty-theme` require
   Bash 5 or newer. macOS system Bash 3.2 remains available only for shell
   configuration that intentionally supports it. Linux uses apt and Linuxbrew
   instead; see [docs/linux-setup.md](docs/linux-setup.md).

### 2. Bootstrap the dotfiles

```sh
chezmoi init toku345
cd "$(chezmoi source-path)"
sh scripts/codex-config/setup.sh
chezmoi apply
```

`setup.sh` installs a dedicated Python with uv and prepares the locked config
dependencies before the first status/diff/apply; see
[runtime setup and updates](docs/codex.md#初回準備依存更新). `chezmoi apply`
installs the remaining packages, deploys the dotfiles, applies the
`~/.codex/config.toml` per-key policy, and places the `codex-fugu` wrapper at
`~/.local/bin/codex-fugu` (it exits with an error until the isolated home of
step 5 exists).

Run `chezmoi apply` from the source checked out on `main`, never from a linked
worktree. After `.chezmoi.toml.tmpl` changes, `chezmoi init` must be re-run to
regenerate the config file.

### 3. Answer the per-machine prompts

`chezmoi init` asks these once per machine and stores the answers in
`~/.config/chezmoi/chezmoi.toml`. A stored answer is never asked again: to
change one, set the value in that file (or delete the key to be asked again)
and re-run `chezmoi init` so the config file is regenerated. `chezmoi init
--prompt` forces the questions and needs an interactive terminal.

| Key | Default | Enables |
| --- | --- | --- |
| `vpn_check` | no | VPN status in the starship prompt |
| `codexFugu` | no | Management of the isolated Fugu home base config (`~/.codex-fugu/config.toml`) |

Answer yes to `codexFugu` only on machines that already have the isolated Fugu
home (step 5). While it is off, the whole Fugu source tree is ignored and
`~/.codex-fugu` is never created.

### 4. Install the Codex CLI (optional)

```sh
brew install codex          # or: npm install -g @openai/codex
codex login
```

`~/.codex/config.toml` is managed per key by
`scripts/codex-config/policy.toml` (pin / seed / free). `auth.json`, history,
and sessions are never managed; see [Codex 設定の管理方針](docs/codex.md).

### 5. Set up the isolated Fugu home (optional)

`codex-fugu` runs a separate home (`~/.codex-fugu`) with its own Codex install,
API key, sessions, and memory, launched through the managed wrapper
`~/.local/bin/codex-fugu`. The authoritative procedure is
[docs/codex.md](docs/codex.md#初回セットアップ) (base config policy:
[ADR 0038](docs/adr/0038-fugu-home-config-policy.md)). Order matters:

1. Clone the Fugu repository and read `configs/bundle.sh`
   (`BUNDLE_CODEX_VERSION`).
2. Create `~/.codex-fugu` with mode `0700`, then — in a subshell with the
   dedicated environment — install the bundle-specified Codex into
   `~/.codex-fugu/bin`.
3. Run `<fugu-repo>/scripts/install.sh --reconfigure` and set the Sakana API
   key. Never copy `~/.codex`'s `.env`, `auth.json`, settings, memory, or
   sessions.
4. Verify with `--status` plus one read-only isolated smoke turn, per
   [入口を切り替える前の検証](docs/codex.md#入口を切り替える前の検証).
5. `chezmoi apply -v ~/.local/bin/codex-fugu`, then check `codex-fugu --status`.
   On a machine that already ran the standalone Fugu installer, first copy the
   existing `~/.local/bin/codex-fugu` to a dated backup (see `docs/codex.md`);
   never move or uninstall it.
6. Enable `codexFugu`: set it to `true` in `~/.config/chezmoi/chezmoi.toml`
   (a stored answer is not asked again) and re-run `chezmoi init`, or run
   `chezmoi init --prompt` and answer yes. Then run
   `chezmoi diff --exclude=scripts` and a full `chezmoi apply -v`; applying
   only `~/.codex-fugu/config.toml` would leave the three shared-file
   symlinks uncreated. If an existing
   `~/.codex-fugu/AGENTS.md`, `agents/`, or `rules/managed.rules` is a real
   file or directory, back it up outside the target and remove it before the
   apply. `chezmoi status ~/.codex-fugu` must be empty afterwards.
7. In a new `codex-fugu` session, one Plan mode turn must record
   `"reasoning_effort":"xhigh"`; the Fugu catalog rejects the CLI default.

The installer-owned `fugu.config.toml`, `.env`, `bin/`, `packages/`,
sessions, and `*.sqlite*` files stay outside chezmoi. Keep the Fugu bundle's
verified Codex version unless upstream ships configs for a newer one.

### 6. Restore and updates

- Recovery needs GitHub access, 1Password access, and the `key.txt.age`
  password: [docs/backup-restore.md](docs/backup-restore.md).
- Update policy for Codex and Fugu: [docs/codex.md](docs/codex.md).

## Additional Setup

### Starship

A [Nerd Font](https://www.nerdfonts.com/) installed and enabled in your terminal.

- <https://starship.rs/guide/#prerequisites>

### Claude Code Plugins

`~/.claude/settings.json` contains only environment-agnostic plugins shared across all machines. Language-specific plugins (e.g., `typescript-lsp`, `pyright-lsp`) should be added per-project in each repository's `.claude/settings.json`.

Setup and usage notes for Claude Code plugins and agmsg are documented in [docs/claude-code-plugins.md](docs/claude-code-plugins.md).

Note: `outputStyle` (persona) is an exception — set as a personal preference at user scope. Per-repo overrides via `<repo>/.claude/settings.local.json` still take precedence over the user-scope default. See [docs/adr/0015-multi-persona-output-styles.md](docs/adr/0015-multi-persona-output-styles.md) for rationale.
