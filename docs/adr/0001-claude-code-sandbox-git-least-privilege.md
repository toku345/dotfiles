# ADR 0001: Claude Code Sandbox — Git Least Privilege Model

## Status

Accepted

## Context

Claude Code's sandbox (`settings.json`) was configured with
`excludedCommands: ["git", "gh"]`, which runs these commands completely outside
the sandbox. This ADR addresses removing `git` from `excludedCommands`.
`gh` is covered separately in
[ADR 0002](0002-claude-code-sandbox-gh-investigation.md).

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

## Decision

Remove `git` from `excludedCommands` and grant minimal sandbox permissions.
`gh` remains in `excludedCommands` (see
[ADR 0002](0002-claude-code-sandbox-gh-investigation.md)).

```json
{
  "sandbox": {
    "filesystem": {
      "allowRead": ["~/.ssh/known_hosts", "~/.ssh/config", "~/.ssh/config.local", "~/.orbstack/ssh/config", "~/.config/gh/hosts.yml"],
      "allowWrite": ["/tmp", ".git", "~/.ssh/known_hosts"]
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
| `allowRead: ~/.config/gh/hosts.yml` | `gh` (in `excludedCommands`) auth config; see [ADR 0002](0002-claude-code-sandbox-gh-investigation.md) |
| `allowWrite: /tmp` | Lefthook/Husky stash operations and temp files |
| `allowWrite: .git` | `git push -u` upstream tracking config, branch metadata, index updates |
| `allowWrite: ~/.ssh/known_hosts` | First SSH connection writes host key; contains only public keys |
| `allowAllUnixSockets: true` | SSH agent access; `allowUnixSockets` requires literal paths but `$SSH_AUTH_SOCK` is dynamic (note: opens ALL Unix sockets, not just SSH agent — see Negative consequences) |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory), `.git`, `/tmp`, and `~/.ssh/known_hosts`
- Arbitrary network hosts — `allowedDomains` is not explicitly configured; new outbound domains trigger a permission prompt at runtime

## Consequences

### Positive

- **Reduced attack surface for git**: Git operations are now constrained by
  filesystem and network restrictions, whereas `excludedCommands` provided no
  restrictions at all.
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
- **`/tmp` write access is global**: All sandboxed commands can write to `/tmp`.
  `/tmp` is an OS-standard world-writable directory; risk increase is limited.
- **`.git` write access allows hook/config modification**: All sandboxed commands
  can write to `.git/config` and `.git/hooks/`. Risk is equivalent to when `git`
  was in `excludedCommands` (full filesystem access).

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| First connection to new SSH host auto-adds host key to `known_hosts` | Low | `~/.ssh/known_hosts` is in `allowWrite`; contains only public host keys |
| `allowedDomains` doesn't apply to SSH (port 22) | Low | SSH access is gated by SSH agent and `~/.ssh/config` allowRead; no additional mitigation needed |
| Lefthook needs writes beyond `/tmp` | Low | Add paths to `allowWrite` as discovered |

### Known Limitations

- **`denyOnly` glob patterns are not enforced at the Seatbelt level**
  (empirically observed; not documented by Anthropic — behavior may change):
  Glob patterns in the sandbox `denyOnly` read config (e.g., `*.key`, `.env.*`)
  do not block reads — only absolute-path entries (e.g.,
  `~/.docker/config.json`) are enforced. Verified on macOS 15.7.4 and
  macOS 26.3.1 with Claude Code 2.1.81.
- **`excludedCommands` does not bypass Mach service restrictions** (empirically
  observed; not documented by Anthropic — behavior may change): Commands in
  `excludedCommands` are still blocked from accessing Mach services (e.g.,
  `trustd`). Corroborated by community reports:
  [#28954](https://github.com/anthropics/claude-code/issues/28954),
  [#17821](https://github.com/anthropics/claude-code/issues/17821).
- **`.git` in `allowWrite` resolves relative to cwd**: If Claude Code is started
  from a subdirectory (e.g., `repo/subdir/`), `.git` resolves to
  `repo/subdir/.git` which doesn't exist. `git add`, `git commit`, and
  `git push -u` may fail. In practice, Claude Code sessions start from the
  repository root, so impact is limited.

### Resolved Limitations

- **SSH config `Include` targets not in `allowRead`** (resolved by adding
  `~/.ssh/config.local` and `~/.orbstack/ssh/config` to `allowRead`): OpenSSH
  aborts config resolution if an `Include` target is unreadable, even under
  `Match exec` conditions. Both files exist in this environment.
- **`git push -u` writes to `.git/config`** (resolved by `allowWrite: [".git"]`):
  Previously the sandbox blocked writes to `.git/config` even though `.` was in
  the write allowlist. Adding `.git` explicitly resolved this.

### Rollback

Add `"git"` back to `excludedCommands` and remove `filesystem` /
`allowAllUnixSockets`.
