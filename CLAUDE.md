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

## Security

### Encryption and Key Management

- **Two-layer security model**: Age private key is encrypted with a password (scrypt)
- **Key rotation policy**: Periodic rotation is NOT required for personal use
  - Only rotate keys in emergency situations (key leak, device theft, etc.)
  - See [docs/key-rotation.md](docs/key-rotation.md) for detailed procedures

### Automated Security Checks

This repository includes GitHub Actions workflows for automated security validation:

- **Age file format validation** - Ensures encrypted files are in correct format
- **Required files verification** - Checks that all necessary encrypted files exist
- **Plaintext key detection** - Prevents accidental commit of decrypted keys
- **Public key consistency** - Verifies all files use the same encryption key
- **Secret scanning** - Detects passwords, API keys, and other sensitive data with git-secrets

**Note:** CI/CD checks do NOT perform actual decryption (no password in CI environment). For complete validation including decryption tests, use the local validation script:

```bash
cd ~/.local/share/chezmoi
./scripts/validate-encryption.sh
```

For detailed information about security checks, see [docs/security-ci-cd.md](docs/security-ci-cd.md)

### Security Best Practices

✅ **DO:**
- Keep `~/key.txt` permissions at 600
- Store password only in 1Password
- Run local validation script before important commits
- Review GitHub Actions security check results

❌ **DON'T:**
- Never commit `~/key.txt` (unencrypted private key) to the repository
- Never store password in GitHub Secrets or environment variables
- Never ignore security check failures without investigation

## Important Notes

- This repository uses chezmoi's naming conventions:
  - `dot_` prefix becomes `.` in the target
  - `private_` prefix sets permissions to 0600
  - `encrypted_` prefix indicates age-encrypted files
- Template files (`.tmpl`) are processed before being applied to the target system
- The repository includes configurations for macOS-specific tools (Homebrew, iTerm2, Karabiner)
