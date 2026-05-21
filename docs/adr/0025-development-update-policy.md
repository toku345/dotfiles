# ADR 0025: Developer environment update policy for supply-chain risk

## Status

Accepted (2026-05-21)

## Context

Developer machines have multiple update channels that can become arbitrary-code execution paths: VS Code extensions, editor applications, Homebrew/Linuxbrew formulae and casks, apt packages, language package managers, runtime managers, cloud CLIs, AI coding tools, and their plugin systems. The goal is not to stop all updates. The goal is to move routine updates into reviewable windows while keeping security updates timely.

This repository already has hardening for npm, bun, pip, and uv in `docs/security.md`: lifecycle scripts are disabled for npm/bun, uv and bun use a 7-day freshness cooldown, and Python installs prefer wheels over sdists. The missing policy surface is how to treat editor extensions, OS package managers, high-privilege CLIs, Codex/Claude, and asdf.

## Decision

Adopt a 7-day cooldown as the default for routine developer-tool updates. Exceptions are security updates, active exploit fixes, and break/fix updates needed to restore work. OS security updates must not be delayed by the cooldown.

VS Code Stable and VS Code Insiders both remain supported, but both are hardened: extension auto-update is disabled, extension update checks remain enabled, application update mode is manual, and untrusted files open in a new restricted window. Insiders is not treated as safer than Stable; it is a higher-change-rate environment and should be used with deliberate extension updates.

Homebrew and Linuxbrew remain the base distribution mechanisms for macOS and Linux CLI tools. Disable implicit update/upgrade behavior via shell environment (`HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_UPGRADE=1`, `HOMEBREW_ASK=1`, `HOMEBREW_CASK_OPTS=--require-sha`). Avoid unreviewed `brew upgrade` across the whole machine. Prefer `brew update`, inspect `brew outdated`, then upgrade named packages. Do not long-term pin security-sensitive libraries such as `git`, `curl`, `openssl`, or `ca-certificates`.

High-privilege Homebrew casks and CLIs get stricter handling: Codex, Karabiner-Elements, cloud CLIs, credential/session helpers, editor casks, container tooling, and tools that can read repositories or credentials should be manually reviewed before upgrade. Pinning is acceptable for these tools, but pinned tools need an explicit periodic review so security fixes are not missed.

Ubuntu/DGX OS security updates should stay enabled or be applied promptly by the host operator. Normal apt updates can rely on Ubuntu phased updates or a manual review window. NVIDIA driver, CUDA, kernel, and DGX-specific packages should not be automatically upgraded on active compute hosts; apply them during planned maintenance.

asdf is retained for runtime pinning. `.tool-versions` should use exact versions, not `latest`. asdf does not provide a release-age gate comparable to mise `minimum_release_age`; its safety comes from exact pinning and manual review. Disable short-name plugin repository sync and avoid `asdf plugin update --all`. Add new plugins by explicit Git URL and update plugins only when intentionally reviewing a runtime upgrade.

Codex and Claude are high-privilege AI coding tools. Codex should be updated manually and should not rely on uncontrolled self-update behavior. Claude Code native auto-updates should be disabled where supported, and plugin auto-updates that affect internal automation contracts should remain off unless a specific update is being reviewed. The existing `openai-codex` Claude plugin `autoUpdate=false` setting stays in place.

Do not introduce mise, aqua, or Nix as part of this policy change. mise remains a plausible future replacement or supplement for asdf because it has release-age support, but the current environment already uses exact runtime pins and the immediate risk reduction is higher in VS Code, Homebrew/casks, and AI tool updates.

## Consequences

Routine updates become a deliberate operation instead of a side effect of installing or opening tools. This adds a small amount of friction but makes high-risk changes visible before they run with repository, credential, shell, editor, or input-monitoring privileges.

The policy is intentionally hybrid. No single manager covers VS Code extensions, Homebrew casks, apt security updates, asdf runtimes, npm/bun/uv/pip dependencies, and AI tool plugins equally well. Each update channel uses the smallest mechanism that fits its actual risk surface.

Pinned tools can silently miss fixes if never reviewed. Any cask or plugin pin must be paired with a periodic manual review habit, especially for tools that touch credentials, cloud accounts, source control, or input devices.

## Implementation notes

Immediate manual action: update both VS Code Stable and VS Code Insiders user settings to set `extensions.autoUpdate=false`, `extensions.autoCheckUpdates=true`, `update.mode=manual`, and `security.workspace.trust.untrustedFiles=newWindow`.

Follow-up PRs should be small: first record this ADR and stop VS Code auto-update, then add shell-level Homebrew/asdf hardening, then add Claude/Codex and high-risk cask update procedures.

## References

- VS Code extension management: <https://code.visualstudio.com/docs/editor/extension-marketplace>
- VS Code Workspace Trust: <https://code.visualstudio.com/docs/editing/workspaces/workspace-trust>
- Homebrew manpage and version locking: <https://docs.brew.sh/Manpage>, <https://docs.brew.sh/Versions>
- Claude Code setup and updates: <https://code.claude.com/docs/en/setup>
- asdf configuration: <https://asdf-vm.com/manage/configuration.html>
- mise `minimum_release_age`: <https://mise.jdx.dev/configuration/settings.html>
- npm config `min-release-age`: <https://docs.npmjs.com/cli/v11/using-npm/config#min-release-age>
- uv dependency cooldowns: <https://docs.astral.sh/uv/concepts/resolution/>
