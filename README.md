# toku345/dotfiles

toku345's dotfiles managed by chezmoi.

## Setup

1. Install [chezmoi](https://www.chezmoi.io/install/)
2. Install age

   ```sh
   brew install age
   ```

3. Initialize chezmoi

   ```sh
   chezmoi init --apply toku345
   ```

## Additional Setup

### Starship

A [Nerd Font](https://www.nerdfonts.com/) installed and enabled in your terminal.

- <https://starship.rs/guide/#prerequisites>

### Claude Code Plugins

`~/.claude/settings.json` contains only environment-agnostic plugins shared across all machines. Language-specific plugins (e.g., `typescript-lsp`, `pyright-lsp`) should be added per-project in each repository's `.claude/settings.json`.

Note: `outputStyle` (persona) is an exception — set as a personal preference at user scope. Per-repo overrides via `<repo>/.claude/settings.local.json` still take precedence over the user-scope default. See [docs/adr/0015-multi-persona-output-styles.md](docs/adr/0015-multi-persona-output-styles.md) for rationale.
