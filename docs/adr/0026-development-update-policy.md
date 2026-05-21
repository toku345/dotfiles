# ADR 0026: Developer environment update policy for supply-chain risk

## Status

Accepted as policy (2026-05-21). Enforcement is partial; remaining controls are tracked in Follow-ups.

## Context

Developer machines have multiple update channels that can become arbitrary-code execution paths: VS Code extensions, editor applications, Homebrew/Linuxbrew formulae and casks, apt packages, language package managers, runtime managers, cloud CLIs, AI coding tools, and their plugin systems. The goal is not to stop all updates. The goal is to move routine updates into reviewable windows while keeping security updates timely.

This repository already has hardening for npm, bun, pip, and uv in `docs/security.md`: lifecycle scripts are disabled for npm/bun, the 7-day freshness cooldown is implemented as bun `minimumReleaseAge` and uv `exclude-newer`, and Python installs prefer wheels over sdists. The missing policy surface is how to treat editor extensions, OS package managers, high-privilege CLIs, Codex/Claude, and asdf.

## Decision

A 7-day cooldown is the default for routine developer-tool updates. Exceptions are security updates, active exploit fixes, and break/fix updates needed to restore work. OS security updates must not be delayed by the cooldown.

The supported configuration for VS Code Stable and Insiders requires extension auto-update disabled, extension update checks enabled, application update mode set to manual, and untrusted files opening in a new restricted window. Insiders is not safer than Stable — it is a higher-change-rate environment and must be used with deliberate extension updates.

Homebrew and Linuxbrew remain the base distribution mechanisms for macOS and Linux CLI tools. Implicit update/upgrade behavior must be disabled via shell environment (`HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_UPGRADE=1`, `HOMEBREW_ASK=1`, `HOMEBREW_CASK_OPTS=--require-sha`). Unreviewed `brew upgrade` across the whole machine must be avoided; the preferred sequence is `brew update`, inspect `brew outdated`, then upgrade named packages. Security-sensitive libraries such as `git`, `curl`, `openssl`, and `ca-certificates` must not be long-term pinned.

High-privilege Homebrew casks and CLIs (e.g. `codex`, `karabiner-elements`, `gh`, `op`, `docker`, container tooling, cloud CLIs, credential/session helpers, editor casks) require stricter handling: they must be manually reviewed before upgrade. Pinning is acceptable for these tools, but pinned high-privilege tools must have at least quarterly manual review so security fixes are not missed.

Ubuntu/DGX OS security updates must stay enabled or be applied promptly by the host operator. Normal apt updates can rely on Ubuntu phased updates or a manual review window. NVIDIA driver, CUDA, kernel, and DGX-specific packages must not be automatically upgraded on active compute hosts; they must be applied during planned maintenance.

asdf is retained for runtime pinning. `.tool-versions` must use exact versions, not `latest`. asdf does not provide a release-age gate comparable to mise `minimum_release_age`; its safety must come from exact pinning and manual review. Short-name plugin repository sync must be disabled, and `asdf plugin update --all` must be avoided. New plugins should be added by explicit Git URL, and plugins should be updated only when intentionally reviewing a runtime upgrade.

Codex and Claude are high-privilege AI coding tools. Codex must be updated manually and must not rely on uncontrolled self-update behavior. Claude Code native auto-updates must be disabled where supported, and plugin auto-updates that affect internal automation contracts must remain off unless a specific update is being reviewed.

Pre-existing control brought under this policy: the Codex Claude plugin in `private_dot_claude/settings.json` has `autoUpdate: false` set.

mise, aqua, and Nix are not introduced as part of this policy change. mise remains a plausible future replacement or supplement for asdf because it has release-age support, but the current environment already uses exact runtime pins and the immediate risk reduction is higher in VS Code, Homebrew/casks, and AI tool updates.

## Consequences

Routine updates become a deliberate operation instead of a side effect of installing or opening tools. This adds a small amount of friction but makes high-risk changes visible before they run with repository, credential, shell, editor, or input-monitoring privileges.

The policy is intentionally hybrid. No single manager covers VS Code extensions, Homebrew casks, apt security updates, asdf runtimes, npm/bun/uv/pip dependencies, and AI tool plugins equally well. Each update channel uses the smallest mechanism that fits its actual risk surface.

Pinned tools can silently miss fixes if never reviewed. Any cask or plugin pin must be paired with the at-least-quarterly review habit defined above, especially for tools that touch credentials, cloud accounts, source control, or input devices.

## Follow-ups

Concrete enforcement is implemented incrementally through these follow-ups:

- #229 — VS Code extension autoUpdate hardening per ADR 0026
- #225 — Harden Homebrew and asdf update behavior
- #226 — Define Claude, Codex, and high-risk cask manual update workflow

When a follow-up is implemented, add an `**Amendment YYYY-MM-DD**:` line under Status documenting the change, per this repository's ADR amendment convention.

## References

- VS Code extension management: <https://code.visualstudio.com/docs/editor/extension-marketplace>
- VS Code Workspace Trust: <https://code.visualstudio.com/docs/editing/workspaces/workspace-trust>
- Homebrew manpage and version locking: <https://docs.brew.sh/Manpage>, <https://docs.brew.sh/Versions>
- Claude Code setup and updates: <https://code.claude.com/docs/en/setup>
- asdf configuration: <https://asdf-vm.com/manage/configuration.html>
- mise `minimum_release_age`: <https://mise.jdx.dev/configuration/settings.html>
- npm config `min-release-age`: <https://docs.npmjs.com/cli/v11/using-npm/config#min-release-age>
- uv dependency cooldowns: <https://docs.astral.sh/uv/concepts/resolution/>
