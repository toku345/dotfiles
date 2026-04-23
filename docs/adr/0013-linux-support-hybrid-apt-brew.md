# ADR 0013: Linux support via hybrid apt + Linuxbrew with Bash

## Status

Accepted

## Context

The repository has been macOS-only. Adding Linux support (primary target: Ubuntu / DGX OS as an SSH-accessed development server) raises several architectural questions:

1. **Login shell**: fish is the primary shell on macOS, but fish introduces per-OS install overhead and the user's SSH workflow does not require fish-specific features.
2. **Package source**: Linuxbrew offers identical CLI tool coverage to Homebrew, but system-level prerequisites still need apt.
3. **Bootstrap chicken-and-egg**: chezmoi and age must exist before `chezmoi init --apply` can run, so they cannot be installed by the chezmoi-managed script itself.
4. **Language runtimes**: macOS uses asdf; on Linux the user already uses uv (Python), bun (JavaScript), and rustup (Rust) directly and does not need asdf.
5. **Starship prompt**: macOS uses Nerd Font symbols; on Linux (accessed via SSH from macOS or potentially other clients) a font-independent prompt is safer and clearer.
6. **VPN module**: The macOS-only custom starship module is gated by `os = "macos"` in the current static toml, and the existing `vpn_check` chezmoi data (collected via `promptBoolOnce`) is not wired up — personal macOS machines still evaluate the module needlessly.
7. **PR #77** previously attempted Linux support with a heavy install script (apt + GitHub releases for every tool). That approach was abandoned in favor of the simpler apt + Linuxbrew split.

The forces at play: keep the setup simple, avoid drift between OSs, respect the user's existing macOS workflow, and produce a Linux setup that is minimal but functional for SSH-based development.

### Target host prerequisites (explicit)

This ADR assumes the following about the target Linux host:

- **sudo access**: The user on the target host can run `sudo apt-get install ...`. DGX OS and personal Ubuntu workstations satisfy this; managed multi-tenant hosts typically do not.
- **System-wide Linuxbrew**: Linuxbrew is installed at `/home/linuxbrew/.linuxbrew` (the default, matching the existing assumption in `private_dot_config/private_fish/config.fish`). Per-user `~/.linuxbrew` installs are **out of scope** for this ADR.
- **Internet access**: Required for both apt and brew package downloads, plus the Bootstrap step's `curl | bash` language-manager installers.

Hosts lacking sudo or requiring a per-user Linuxbrew prefix are **not supported** by this PR. Adding no-sudo fallbacks can be revisited in a separate ADR if that use case emerges.

## Decision

### 1. OS split: Bash on Linux, fish on macOS

Linux uses bash as the login shell. fish is neither installed nor deployed on Linux (excluded via `.chezmoiignore`). The fish-based `gw` / `gb` / `gbd` worktree commands are deferred to a separate PR — they are not critical for Linux SSH workflows.

### 2. Package manager split: apt for OS, Linuxbrew for apps

- **apt**: `build-essential curl file git procps` (Linuxbrew prerequisites and OS essentials).
- **Linuxbrew**: application tools (`gh`, `tmux`, `git-gtr`, `starship`, `fzf`, `eza`, `bat`, `fd`, `ripgrep`, `git-delta`, `direnv`, `nano`, `aspell`, `git-secrets`).
- **Bootstrap (manual)**: `chezmoi` and `age` are installed by hand via Linuxbrew before `chezmoi init --apply` can run.

### 3. Formulae reconciliation between macOS and Linux

- **Added to both OSs**: `gh`, `git-gtr` (previously installed manually on macOS; now managed by the install script on both).
- **Removed from both OSs**: `gpg` — verified as unused across the repository (`.chezmoi.toml.tmpl` uses `encryption = "age"`, no `.gitconfig` signing keys, no `~/.gnupg`).
- **Linux-excluded**: `coreutils` (Linux-native), `shadowenv` (fish-only hook), `fish`, `asdf` (replaced by uv/bun/rustup), `karabiner-elements`, `font-cask` (macOS/desktop-only).
- **git-gtr** uses the fully qualified `coderabbitai/tap/git-gtr` formula name (third-party tap), avoiding a separate `brew tap` step.

### 4. Bash configuration: `dot_bashrc` + `dot_bash_profile`

- `dot_bashrc` sets up PATH (Linuxbrew, `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`), initializes starship/direnv, sources fzf key bindings (Ctrl-R history), and defines simple aliases (`gst`, `l`, `ll`, etc.) translated from the macOS fish configuration.
- `dot_bash_profile` is a one-liner that sources `~/.bashrc` so SSH login shells pick up the config.
- Both files are excluded from macOS via `.chezmoiignore`.
- A `~/.bashrc.local` hook allows machine-specific overrides (consistent with existing fish `config.fish.local` pattern).

### 5. Starship: single `starship.toml.tmpl` with OS + vpn_check branching

- Rename `starship.toml` to `starship.toml.tmpl` and wrap the existing Nerd Font Symbols preset in `{{ if eq .chezmoi.os "darwin" }}`.
- Add a Linux branch using the **Bracketed Segments preset** (ASCII-only, font-independent) plus an `ssh_only` hostname block.
- Wire the VPN `[custom.vpn]` module to `{{ if .vpn_check }}` under the darwin branch, finally using the existing `vpn_check` prompt data.
- Tighten `private_dot_config/starship/.chezmoiignore.tmpl` to also guard on OS (so `check-vpn.sh` never deploys on Linux regardless of the vpn_check answer).

### 6. Language managers on Linux: uv / bun / rustup via native installers

No brew/apt entries for language managers on Linux. `dot_bashrc` conditionally adds `~/.cargo/bin` and `~/.bun/bin` to PATH (`~/.local/bin` is already on PATH for uv). Users install each language manager via its own installer as an optional post-chezmoi step documented in `docs/linux-setup.md`.

### 7. Docs scope for this PR

- **NEW**: `docs/linux-setup.md` — Linux-specific bootstrap flow.
- **MOD**: `docs/backup-restore.md` — short Linux recovery section.
- **Deferred**: `docs/security.md` refresh → separate PR.

### 8. Verification strategy: manual parity via Docker

Linux CI is not expanded in this PR. Instead, the existing manual pattern (`docker run ubuntu:24.04 bash ...`) is documented in `docs/linux-setup.md` and treated as the pre-PR validation step, consistent with AGENTS.md guidance on Ubuntu CI parity.

### 9. PR #77 disposition

Close PR #77 with a comment linking to the new PR. The approach diverges enough that a clean diff is clearer than amending the existing branch.

## Consequences

### Positive

- Linux SSH developers get a working bash environment with starship, fzf Ctrl-R history, and aliases consistent with the macOS fish workflow.
- Install script becomes OS-aware but stays a single file, reducing maintenance surface compared to the two-script alternative.
- The existing `vpn_check` prompt data is finally wired — personal macOS machines (`vpn_check=false`) no longer evaluate the VPN module, closing a latent inefficiency.
- Linuxbrew reuses the macOS formula ecosystem, so app-level tool versions stay aligned across OSs.
- `gh` and `git-gtr` are now managed by the install script on both OSs; the script matches reality instead of trailing it.
- Removing unused `gpg` applies YAGNI consistently based on codebase evidence (no signing config, no `~/.gnupg`, no scripts calling gpg).

### Negative / Trade-offs

- Users of existing macOS setups must run `brew uninstall gpg` manually after applying this PR — chezmoi cannot un-install packages declaratively.
- The Bracketed Segments preset on Linux is visually different from macOS; users SSH-ing from a Nerd-Font-capable terminal see the "simpler" prompt style even when their terminal could render richer symbols. This is an intentional choice for portability but trades off visual parity.
- `starship.toml.tmpl` loses full TOML schema validation from editors because of the Go template syntax; the common (non-branched) portion still benefits from TOML tooling.
- `git-gtr` is pinned to a third-party tap (`coderabbitai/tap`); availability depends on that tap staying published.
- Deferring `gw` / `gb` / `gbd` to a future PR means Linux users don't get worktree workflow helpers yet.

### Risks and monitoring

- **Host prerequisites**: If a target host lacks sudo or has a non-standard Linuxbrew prefix, the install script fails on `sudo apt-get`. The failure is loud (non-zero exit); users are directed to `docs/linux-setup.md` which states the prerequisites. No silent fallback is attempted.
- **Linuxbrew formula availability**: `git-secrets`, `git-gtr`, and `fzf` shell script paths must exist on Linuxbrew. Verify in Docker before publishing the PR.
- **bash 5.x portability**: `dot_bashrc` uses bash-3.2-compatible syntax to stay portable, but Linux distros ship bash 5.x. No known issue but worth watching.
- **`.chezmoiignore` template correctness**: chezmoi templates OS-branch logic; `chezmoi execute-template` should be run during verification to catch syntax errors before apply.
- **VPN module regression**: Existing macOS users with `vpn_check=true` must verify the custom.vpn block still runs after the switch from static `os = "macos"` to template branching.

### Follow-ups

- Separate PR: refresh `docs/security.md` for Linux.
- Separate PR: bash-native translations of `gw` / `gb` / `gbd` for Linux workflow parity.
- Optional: expand `.github/workflows/ci.yml` with a Docker-based chezmoi dry-run job for Linux coverage.
