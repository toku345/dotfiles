# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a dotfiles repository managed by [chezmoi](https://www.chezmoi.io/), a tool for managing personal configuration files across multiple machines. The repository contains configuration files for various development tools and environments.

## Common Commands

### Chezmoi Operations

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

Files ending in `.tmpl` are chezmoi templates that use Go's text/template syntax. The most notable template is:

- `private_dot_config/private_fish/config.fish.tmpl` - Fish shell configuration

### Encrypted Files

Files with `.age` extension are encrypted using the age encryption tool. To work with these files:

- Ensure `age` is installed: `brew install age`
- Chezmoi will handle encryption/decryption automatically

## Repository Structure

- `private_dot_config/` - Configuration files that will be placed in `~/.config/`
  - `private_fish/` - Fish shell configuration
  - `git/` - Git configuration
  - `starship.toml` - Starship prompt configuration
  - `tmux/` - Tmux configuration
  - `karabiner/` - Karabiner-Elements keyboard customization
  - `iterm2/` - iTerm2 terminal preferences
- `private_dot_ssh/` - SSH configuration
- `images/` - Documentation images
- `key.txt.age` - Encrypted age key

## Key Configuration Files

### Fish Shell (`config.fish.tmpl`)

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

## Working with This Repository

When making changes:

1. Edit files in the chezmoi source directory (`~/.local/share/chezmoi/`)
2. Test changes with `chezmoi diff` before applying
3. Apply changes with `chezmoi apply`
4. Commit changes to git from the source directory

## Important Notes

- This repository uses chezmoi's naming conventions:
  - `dot_` prefix becomes `.` in the target
  - `private_` prefix sets permissions to 0600
  - `encrypted_` prefix indicates age-encrypted files
- Template files (`.tmpl`) are processed before being applied to the target system
- The repository includes configurations for macOS-specific tools (Homebrew, iTerm2, Karabiner)
