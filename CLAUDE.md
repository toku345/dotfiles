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

Files ending in `.tmpl` are chezmoi templates that use Go's text/template syntax. The primary template is:

- `.chezmoi.toml.tmpl` - Chezmoi configuration (defines `scriptEnv` for scripts)

### Encrypted Files

Files with `.age` extension are encrypted using the age encryption tool. This repository uses a **two-layer security model**:

#### Security Architecture

```
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
age -d -o ~/key.txt ~/.local/share/chezmoi/key.txt.age
# Enter password from 1Password

# Set correct permissions
chmod 600 ~/key.txt

# Chezmoi will automatically use ~/key.txt to decrypt other files
chezmoi apply
```

**Note:** Never commit `~/key.txt` (the unencrypted private key) to the repository. Only `key.txt.age` (password-protected) should be in the repository.

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

## Working with This Repository

When making changes:

1. Edit files in the chezmoi source directory (`~/.local/share/chezmoi/`)
2. Test changes with `chezmoi diff` before applying
3. Apply changes with `chezmoi apply`
4. Commit changes to git from the source directory

## Go Template Usage Policy

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
- `$CHEZMOI_SOURCE_DIR` - chezmoi source directory

**Note:** Do not define these in `scriptEnv` - they are reserved variables and will cause warnings.

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
- DO store the password in 1Password
- NEVER commit plaintext secrets or API keys
- DO review `git diff` before committing
- NEVER share your age private key

**Emergency Key Rotation:**
Only rotate your age key in emergencies:
- Accidental commit of `~/key.txt` to public repository
- Device lost, stolen, or compromised
- Suspected unauthorized access

For detailed security procedures, see [docs/security.md](docs/security.md)

## Backup and Recovery Strategy

### What You Need for Disaster Recovery

Only **3 things** are required to restore everything on a new machine:

1. **GitHub account access** - to clone the repository
2. **1Password account access** - to retrieve the key.txt.age password
3. **key.txt.age password** - stored in 1Password

### Critical Backups (Must Have)

- **1Password Emergency Kit** - Print and store in a safe place (fireproof safe, bank deposit box)
- **1Password Master Password** - Memorize it (don't rely only on password manager)
- **GitHub 2FA Recovery Codes** - Save in 1Password + print and store physically
- **key.txt.age password** - Optionally write on paper and store in safe (insurance if 1Password fails)

### What NOT to Backup

- ❌ `~/key.txt` (unencrypted private key) - Never back up to USB/cloud
- ❌ Local dotfiles archives - Already in GitHub
- ❌ Multiple copies of encrypted files - Already in GitHub repository

### New Machine Setup (Quick Reference)

```bash
# 1. Install tools
brew install chezmoi age

# 2. Setup SSH key and add to GitHub
ssh-keygen -t ed25519 -C "your_email@example.com"
# Add public key to GitHub Settings > SSH and GPG keys

# 3. Clone repository
chezmoi init toku345

# 4. Decrypt age key (get password from 1Password)
cd ~/.local/share/chezmoi
age -d -o ~/key.txt key.txt.age
chmod 600 ~/key.txt

# 5. Apply dotfiles
chezmoi diff  # Review changes
chezmoi apply # Apply configurations
```

For detailed instructions, see [docs/backup-restore.md](docs/backup-restore.md)

## Important Notes

- This repository uses chezmoi's naming conventions:
  - `dot_` prefix becomes `.` in the target
  - `private_` prefix sets permissions to 0600
  - `encrypted_` prefix indicates age-encrypted files
- Template files (`.tmpl`) are processed before being applied to the target system
- The repository includes configurations for macOS-specific tools (Homebrew, iTerm2, Karabiner)
- **Security**: All sensitive files are encrypted with age. The age private key itself is password-protected in the repository.
