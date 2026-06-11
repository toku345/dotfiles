# ADR 0026: Developer environment update policy for supply-chain risk

## Status

Accepted as policy (2026-05-21). Enforcement is partial; remaining controls are tracked in Follow-ups when open.

**Amendment 2026-06-02 (#226)**: The Claude Code updater controls and Claude-side Codex plugin marketplace registration/auto-update controls are implemented, and the AI-tool/high-privilege-CLI manual update runbook is documented. `~/.claude/settings.json` now sets `env.DISABLE_AUTOUPDATER=1` — which disables automatic updates for the Claude Code binary *and* all plugins, including the built-in `claude-plugins-official` marketplace — plus `autoUpdatesChannel=stable`; the Codex plugin marketplace keeps `autoUpdate=false`. `FORCE_AUTOUPDATE_PLUGINS` is intentionally left unset (setting it would re-enable plugin auto-updates despite the kill switch). This user-settings change does not deploy Claude Code managed settings such as `strictKnownMarketplaces`; hard marketplace source allowlisting remains a separate managed-settings control if this machine later needs that stronger gate. The operational runbook — high-privilege CLI/cask review list, manual update flow, and the conditions under which a security fix bypasses the 7-day cooldown — lives in [docs/security.md](../security.md#developer-tool-update-workflow). High-privilege CLI/cask review remains a manual runbook control until a pinned/reviewed inventory or reminder mechanism is added. The Homebrew/asdf surface (#225) and VS Code surface (#229) remain open.

**Amendment 2026-06-03 (#225)**: The Homebrew/Linuxbrew and asdf update controls are implemented. `dot_bashrc` (Linux), `config.fish` (macOS), and the run-once bootstrap installer export `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_UPGRADE=1`, `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1`, `HOMEBREW_ASK=1`, and `HOMEBREW_CASK_OPTS=--require-sha`; `~/.config/asdf/.asdfrc` sets `plugin_repository_last_check_duration = never` and `disable_plugin_short_name_repository = yes`. `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1` extends the original four-variable decision above: without it, `brew install`/`upgrade` still runs an extra outdated-dependent check/auto-upgrade pass after the requested operation (verified against Homebrew 5.1.14). The accepted trade-off is that broken dependent linkage is not auto-repaired; requested formula/cask dependency-plan changes still remain in review scope. The Homebrew controls are environment-scoped — existing shells, unmanaged shells, `sudo`/`env -i`, GUI-launched commands, and future non-rc automation must set the variables explicitly. The asdf controls are shell-scoped via `ASDF_CONFIG_FILE` — non-rc asdf invocations fall back to defaults; this is a documented limitation (no repo automation currently calls asdf), not closed in this change. The Homebrew env, asdf config, and operational rules (exact `.tool-versions`, no `asdf install latest`, no `asdf plugin update --all`) are documented in [docs/security.md](../security.md#homebrew-and-asdf-update-controls). With this, the VS Code surface (#229) is the last open follow-up.

**Amendment 2026-06-03 (#229)**: The VS Code extension/update hardening is addressed as **documented manual machine setup** (not chezmoi-managed: the user `settings.json` is app-owned, frequently rewritten, full of personal config, and macOS-path-specific, so managing it would churn and risk clobbering personal settings for marginal benefit). [docs/security.md](../security.md#vs-code-extensions-and-updates) records the four settings (`extensions.autoUpdate=false`, `extensions.autoCheckUpdates=true`, `update.mode=manual`, `security.workspace.trust.untrustedFiles=newWindow`), default and profile settings paths, JSONC verification caveats, Settings Sync/profile drift conditions, and the dated manual verification rule: as of 2026-06-03, all four settings were verified on the current Macs; every new or rebuilt VS Code install, Insiders install, active profile, and Settings Sync change must rerun the checklist before #229 is considered still satisfied. With this, the documented runbook follow-up for #229 is addressed; VS Code compliance remains a manually revalidated per-machine/build/profile condition rather than a repo-enforced invariant. Forward note: the operator is evaluating a migration to a single-binary editor (Helix / Lem); the extension-marketplace surface is removed only if the replacement editor is installed through the reviewed Homebrew flow and no separate editor plugin/package updater is enabled.

**Amendment 2026-06-11**: `HOMEBREW_ASK=1` is removed from the required Homebrew environment (`dot_bashrc`, `config.fish`, the run-once bootstrap installer, and the setup/recovery docs). The exact Homebrew 5.1.15 tag only announced the transition (`# odeprecated: make HOMEBREW_ASK the default in the next release`) and still described ask mode as enabled by `$HOMEBREW_DEVELOPER`; current Homebrew rolling builds on this machine (`brew --version`: `Homebrew 5.1.15-247-g067da6f`) have completed the transition and mark `HOMEBREW_ASK` as defaulted/deprecated (`env_config.rb`: `default: true`, `replacement: "the default behaviour"`, `odeprecated: true`). The policy intent (plan visibility before install/upgrade/reinstall) is unchanged — it is now satisfied by the current upstream default; the new opt-out `HOMEBREW_NO_ASK` is intentionally not set, and `tests/bats/test_update_policy_env.bats` asserts that `HOMEBREW_ASK` is absent from the managed shell environments so the deprecated compatibility variable does not get reintroduced. The remaining four-variable set (`HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_NO_INSTALL_UPGRADE`, `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`, `HOMEBREW_CASK_OPTS=--require-sha`) is not deprecated and stays as decided in the #225 amendment; the Homebrew variable list in the Decision section below is updated accordingly so it does not contradict this amendment.

## Context

Developer machines have multiple update channels that can become arbitrary-code execution paths: VS Code extensions, editor applications, Homebrew/Linuxbrew formulae and casks, apt packages, language package managers, runtime managers, cloud CLIs, AI coding tools, and their plugin systems. The goal is not to stop all updates. The goal is to move routine updates into reviewable windows while keeping security updates timely.

This repository already has hardening for npm, bun, pip, and uv in `docs/security.md`: lifecycle scripts are disabled for npm/bun, the 7-day freshness cooldown is implemented as bun `minimumReleaseAge` and uv `exclude-newer`, and Python installs prefer wheels over sdists. The missing policy surface is how to treat editor extensions, OS package managers, high-privilege CLIs, Codex/Claude, and asdf.

## Decision

A 7-day cooldown is the default for routine developer-tool updates. Exceptions are security updates, active exploit fixes, and break/fix updates needed to restore work. OS security updates must not be delayed by the cooldown.

The supported configuration for VS Code Stable and Insiders requires extension auto-update disabled, extension update checks enabled, application update mode set to manual, and untrusted files opening in a new restricted window. Insiders is not safer than Stable — it is a higher-change-rate environment and must be used with deliberate extension updates.

Homebrew and Linuxbrew remain the base distribution mechanisms for macOS and Linux CLI tools. Implicit update/upgrade behavior must be disabled via shell environment (`HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_UPGRADE=1`, `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1`, `HOMEBREW_CASK_OPTS=--require-sha`; `HOMEBREW_ASK=1` was part of this set until the 2026-06-11 amendment removed it as deprecated upstream). Unreviewed `brew upgrade` across the whole machine must be avoided; the preferred sequence is `brew update`, inspect `brew outdated`, then upgrade named packages. Security-sensitive libraries such as `git`, `curl`, `openssl`, and `ca-certificates` must not be long-term pinned.

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

Concrete enforcement is implemented incrementally through follow-ups. Current open implementation follow-ups: none; recurring VS Code manual revalidation remains documented in the security runbook.

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
