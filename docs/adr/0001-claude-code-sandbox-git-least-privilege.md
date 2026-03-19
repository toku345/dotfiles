# ADR 0001: Claude Code Sandbox — Git Least Privilege Model

## Status

Accepted

## Context

Claude Code's sandbox (`settings.json`) was configured with `excludedCommands: ["git"]`,
which runs all git operations completely outside the sandbox — no filesystem, network,
or Unix socket restrictions apply.

This was a pragmatic workaround for two issues:

1. **SSH access**: `git push` via SSH requires reading `~/.ssh/known_hosts` and
   `~/.ssh/config`, plus access to the SSH agent Unix socket (`$SSH_AUTH_SOCK`),
   all of which the default sandbox denies.
2. **Git hooks**: Tools like Lefthook and Husky execute as git child processes.
   Their stash operations write to `/tmp`, which the default sandbox write allowlist
   (`allowOnly: ["."]`) blocks.

However, `excludedCommands` grants unrestricted access across all dimensions
(filesystem, network, sockets), violating the principle of least privilege.

The official Claude Code documentation recommends:

> "This is the recommended approach when a tool needs write access to a specific
> location, rather than excluding the tool from the sandbox entirely with
> `excludedCommands`."
>
> — [Claude Code Sandboxing Documentation](https://code.claude.com/docs/en/sandboxing.md)

### Environment

- macOS (local Claude Code sessions)
- Linux via SSH from macOS (remote Claude Code sessions)
- SSH agent socket paths are dynamic:
  - macOS: `/private/tmp/com.apple.launchd.<random>/Listeners`
  - Linux: `/tmp/ssh-<random>/agent.<PID>`

## Decision

Remove `git` from `excludedCommands` and grant minimal sandbox permissions:

```json
{
  "sandbox": {
    "filesystem": {
      "allowRead": ["~/.ssh/known_hosts", "~/.ssh/config"],
      "allowWrite": ["/tmp"]
    },
    "network": {
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
| `allowWrite: /tmp` | Lefthook/Husky stash operations and temp files |
| `allowAllUnixSockets: true` | SSH agent access; `allowUnixSockets` requires literal paths but `$SSH_AUTH_SOCK` is dynamic |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory) and `/tmp`
- Arbitrary network hosts — restricted to `allowedHosts` (includes `github.com`)

## Consequences

### Positive

- **Reduced attack surface**: Git operations are now constrained by filesystem and
  network restrictions, whereas `excludedCommands` provided no restrictions at all.
- **Aligned with official guidance**: Follows Claude Code's recommended `allowWrite`
  pattern over `excludedCommands`.

### Negative

- **`allowAllUnixSockets: true` is broader than ideal**: Allows sandboxed commands
  to connect to any Unix socket (e.g., Docker socket). Mitigated by `docker` remaining
  in `excludedCommands`. A future `allowUnixSockets` glob support would allow narrowing.
- **`/tmp` write access is global**: All sandboxed commands can write to `/tmp`.
  Risk is limited since `/tmp` is world-writable by convention.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| First connection to new SSH host fails (can't write `known_hosts`) | Medium | Run `ssh -T git@github.com` manually beforehand |
| `allowedHosts` doesn't apply to SSH (port 22) | Low | Add `network.allowedHosts: ["github.com"]` if needed |
| Lefthook needs writes beyond `/tmp` | Low | Add paths to `allowWrite` as discovered |

### Rollback

Add `"git"` back to `excludedCommands` and remove `filesystem` / `allowAllUnixSockets`.
