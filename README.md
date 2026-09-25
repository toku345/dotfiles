# toku345/dotfiles

toku345's dotfiles managed by chezmoi.

## Setup

1. Install [chezmoi](https://www.chezmoi.io/install/)
2. Install age, Bash 5+, and uv

   ```sh
   brew install age bash uv
   ```

   Managed tools such as `brew-reviewed-upgrade` and `ghostty-theme` require
   Bash 5 or newer. macOS system Bash 3.2 remains available only for shell
   configuration that intentionally supports it.

   The setup command below installs a dedicated Python with uv and prepares
   the locked config dependencies before the first status/diff/apply.
   See [runtime setup and updates](docs/codex.md#初回準備依存更新).

3. Fetch the source, prepare Codex config dependencies, then apply

   ```sh
   chezmoi init toku345
   cd "$(chezmoi source-path)"
   sh scripts/codex-config/setup.sh
   chezmoi apply
   ```

## Additional Setup

### Starship

A [Nerd Font](https://www.nerdfonts.com/) installed and enabled in your terminal.

- <https://starship.rs/guide/#prerequisites>

### Claude Code Plugins

`~/.claude/settings.json` contains only environment-agnostic plugins shared across all machines. Language-specific plugins (e.g., `typescript-lsp`, `pyright-lsp`) should be added per-project in each repository's `.claude/settings.json`.

Setup and usage notes for Claude Code plugins and agmsg are documented in [docs/claude-code-plugins.md](docs/claude-code-plugins.md).

Note: `outputStyle` (persona) is an exception — set as a personal preference at user scope. Per-repo overrides via `<repo>/.claude/settings.local.json` still take precedence over the user-scope default. See [docs/adr/0015-multi-persona-output-styles.md](docs/adr/0015-multi-persona-output-styles.md) for rationale.
