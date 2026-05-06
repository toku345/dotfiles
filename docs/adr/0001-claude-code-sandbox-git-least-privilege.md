# ADR 0001: Claude Code Sandbox — Git Least Privilege Model

## Status

Accepted

## Context

Claude Code's sandbox (`~/.claude/settings.json`) was configured with
`excludedCommands: ["git", "gh"]`, which runs these commands completely outside
the sandbox. This ADR addresses removing `git` from `excludedCommands`.
`gh` is covered separately in
[ADR 0002](0002-claude-code-sandbox-gh-investigation.md).

**Scope**: This ADR covers the global user settings (`~/.claude/settings.json`),
which apply to all repositories. Per-project `.claude/settings.json` overrides
are not used.

`git` was excluded as a pragmatic workaround for two issues:

1. **SSH access**: `git push` via SSH requires reading `~/.ssh/known_hosts` and
   `~/.ssh/config`, plus access to the SSH agent Unix socket (`$SSH_AUTH_SOCK`),
   all of which the default sandbox denies.
2. **Git hooks**: Tools like Lefthook and Husky execute as git child processes.
   Their stash operations write to `/tmp`, which the default sandbox write
   allowlist (`allowOnly: ["."]`) blocks.

However, `excludedCommands` runs commands outside the sandbox, removing most
filesystem and network restrictions — though Mach service access remains
enforced (see Known Limitations). This still violates the principle of least
privilege.

The official Claude Code documentation recommends:

> "This is the recommended approach when a tool needs write access to a specific
> location, rather than excluding the tool from the sandbox entirely with
> `excludedCommands`."
>
> — [Claude Code Sandboxing Documentation](https://code.claude.com/docs/en/sandboxing)

### Environment

- macOS (local Claude Code sessions)
- Linux via SSH from macOS (remote Claude Code sessions)
- SSH agent socket paths are dynamic:
  - macOS: `/private/tmp/com.apple.launchd.<random>/Listeners`
  - Linux: `/tmp/ssh-<random>/agent.<PID>`

### Sandbox configuration layers

The sandbox consists of two independently managed layers:

| Layer | Set by | Configured in | Purpose |
|---|---|---|---|
| Default deny rules (`read.denyOnly`, `write.denyWithinAllow`) | Anthropic (Claude Code built-in) | Not visible in any settings file; shown only in session startup sandbox display | Baseline protection for secrets (`*.key`, `*.pem`, `.env`, `~/.ssh/id_*`, `~/.docker/config.json`, etc.) |
| User allow/exclude rules (`allowRead`, `allowWrite`, `excludedCommands`, etc.) | Repository maintainer | `~/.claude/settings.json` (global user settings; managed via chezmoi in this repo) | User-level sandbox permissions applied to all repositories (this ADR's scope) |

**Important**: The default deny rules use two types of path patterns with
different enforcement behavior — see Known Limitations for details.

**Note**: Some files appear in both `sandbox.filesystem.allowRead` and
`permissions.deny` (e.g., `~/.ssh/config`, `~/.ssh/known_hosts`). These layers
are independent: `permissions.deny` blocks Claude's Read/Edit/Write tool access;
`sandbox.filesystem.allowRead` permits child processes (git, ssh) to read at the
OS/Seatbelt level. Both entries are required.

## Decision

Remove `git` from `excludedCommands` and grant minimal sandbox permissions.
`gh` remains in `excludedCommands` (see
[ADR 0002](0002-claude-code-sandbox-gh-investigation.md)).

```json
{
  "sandbox": {
    "filesystem": {
      "allowRead": ["~/.ssh/known_hosts", "~/.ssh/config", "~/.ssh/config.local", "~/.orbstack/ssh/config"],
      "allowWrite": ["/tmp", "~/.ssh/known_hosts"]
    },
    "network": {
      "allowLocalBinding": true,
      "allowAllUnixSockets": true
    },
    "excludedCommands": ["docker", "gh", "codex"]
  }
}
```

### Rationale for each permission

| Permission | Why |
|---|---|
| `allowRead: ~/.ssh/known_hosts` | SSH host key verification |
| `allowRead: ~/.ssh/config` | SSH host aliases and identity file selection |
| `allowRead: ~/.ssh/config.local` | SSH config `Include` target; OpenSSH aborts if unreadable |
| `allowRead: ~/.orbstack/ssh/config` | SSH config `Match exec` Include target; required when OrbStack is installed |
| `allowWrite: /tmp` | Lefthook/Husky stash operations and temp files |
| `allowWrite: ~/.ssh/known_hosts` | First SSH connection writes host key; contains only public keys |
| `allowAllUnixSockets: true` | SSH agent access; `allowUnixSockets` requires literal paths but `$SSH_AUTH_SOCK` is dynamic (note: opens ALL Unix sockets, not just SSH agent — see Negative consequences) |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory), `/tmp`, and `~/.ssh/known_hosts`
- Arbitrary network hosts — `allowedDomains` is not explicitly configured; new outbound domains trigger a permission prompt at runtime

## Consequences

### Positive

- **Reduced attack surface for git**: Git operations are now constrained by
  filesystem and network restrictions, whereas `excludedCommands` removed most
  filesystem and network restrictions.
- **Aligned with official guidance**: Follows Claude Code's recommended
  `allowWrite` pattern over `excludedCommands`.

### Negative

- **`allowAllUnixSockets: true` is broader than ideal**: Allows all sandboxed
  commands (not just `git`) to connect to any Unix socket, including Docker /
  OrbStack daemons. Compared to `excludedCommands: ["git"]` (which removed all
  filesystem, network, and socket restrictions), total exposure is smaller — but
  Unix socket access is a new attack surface not present in the default sandbox.
  A future `allowUnixSockets` glob/pattern support would allow narrowing to
  `$SSH_AUTH_SOCK` only.
  **Accepted because**: (1) all attack vectors require prompt injection as a
  prerequisite; (2) `docker` is already in `excludedCommands` with unrestricted
  access; (3) HTTPS migration was evaluated but rejected due to global settings
  scope — SSH is used across multiple repos and environments; (4) upstream
  feature request for `allowUnixSockets` glob/env-var support is the long-term
  fix.
- **`/tmp` write access is global**: All sandboxed commands can write to `/tmp`.
  `/tmp` is an OS-standard world-writable directory; risk increase is limited.
- **`.` (cwd) includes `.git/` — hook/config modification possible**: The default
  `allowOnly: ["."]` permits writes to `.git/config` and `.git/hooks/` within the
  working directory. This is inherent to the sandbox's cwd write permission; no
  additional configuration is needed or possible to narrow it.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| First connection to new SSH host auto-adds host key to `known_hosts` | Low | `~/.ssh/known_hosts` is in `allowWrite`; contains only public host keys |
| `allowedDomains` doesn't apply to SSH (port 22) | Low | SSH access is gated by SSH agent and `~/.ssh/config` allowRead; no additional mitigation needed |
| Lefthook needs writes beyond `/tmp` | Low | Add paths to `allowWrite` as discovered |
| New SSH config `Include` target not in `allowRead` | Low | Add to `allowRead`; missing entries cause silent SSH config resolution failure |

### Known Limitations

- **`denyOnly` glob patterns only protect files within cwd** (empirically
  observed; not documented by Anthropic — behavior may change): Bare glob
  patterns in the sandbox `denyOnly` read config (e.g., `*.key`, `.env.*`) are
  resolved relative to cwd by `sandbox-runtime`'s `normalizePathForSandbox()`.
  As a result, `*.key` only blocks `<cwd>/*.key`, not `~/secret.key` or files
  in subdirectories. Absolute-path entries (e.g., `~/.docker/config.json`) are
  enforced regardless of cwd. Verified on macOS 15.7.4 and macOS 26.3.1 with
  Claude Code 2.1.81.
- **`excludedCommands` does not bypass Mach service restrictions** (empirically
  observed; not documented by Anthropic — behavior may change): Commands in
  `excludedCommands` are still blocked from accessing Mach services (e.g.,
  `trustd`). Corroborated by community reports:
  [#28954](https://github.com/anthropics/claude-code/issues/28954),
  [#17821](https://github.com/anthropics/claude-code/issues/17821).
- **`pgrep` / `ps` cannot enumerate processes inside the sandbox**
  (empirically observed on Darwin 25.4.0 with Claude Code; not documented by
  Anthropic — behavior may change): macOS process enumeration goes through the
  `sysmond` Mach service, which the sandbox denies. `pgrep` then prints
  `sysmon request failed with error: sysmond service not found` followed by
  `pgrep: Cannot get process list` and exits non-zero with empty stdout.
  Same root cause as `trustd` above; listed separately because the failure mode
  silently skews PID-tree logic (an empty result looks like "no descendants",
  not an error). Affected paths in this repository:
  - `tests/bats/test_triple_review.bats` T1-7 / T1-8 / T1-10 — guarded with a
    `pgrep -P $$` availability check that `skip`s under sandbox.
  - `dot_local/bin/executable_triple-review` `collect_descendants` /
    `kill_children` — works correctly when `triple-review` is invoked directly
    from a terminal (the supported entry point); running it through Claude
    Code's Bash tool requires `dangerouslyDisableSandbox: true`.
- **User settings relative paths resolve against `~/.claude/`** (documented in
  [Sandbox path prefixes](https://code.claude.com/docs/en/settings#sandbox-path-prefixes)):
  Paths without a prefix (e.g., `foo`) in `~/.claude/settings.json` resolve to
  `~/.claude/foo`, not `<cwd>/foo`. Use absolute paths or `~/` prefixes for
  paths outside `~/.claude/`. Project settings (`.claude/settings.json`), if used,
  resolve relative to the project root. This ADR does not use project-level settings.

### Resolved Limitations

- **SSH config `Include` targets not in `allowRead`** (resolved by adding
  `~/.ssh/config.local` and `~/.orbstack/ssh/config` to `allowRead`): OpenSSH
  aborts config resolution if an `Include` target is unreadable, even under
  `Match exec` conditions. `~/.ssh/config.local` is present in this
  environment. `~/.orbstack/ssh/config` is included defensively for
  OrbStack-enabled environments.
- **`git push -u` writes to `.git/config`** (non-issue in the current
  configuration — covered by default `allowOnly: ["."]`): Initially suspected
  that `.git/config` writes were blocked despite `.` being in the write
  allowlist. Empirical testing confirmed `.` recursively covers `.git/` within
  cwd, so no explicit `allowWrite` entry is needed here.
  If a future sandbox blocks `.git/config` writes, treat the remote push and
  upstream setup as separate outcomes: the push may succeed, but upstream
  tracking is not persisted. In that failure mode, later bare `git push` /
  `git pull` commands still fail until `branch.*` config is written in a
  writable context.

### Rollback

Add `"git"` back to `excludedCommands` and remove `filesystem` /
`allowAllUnixSockets`.
