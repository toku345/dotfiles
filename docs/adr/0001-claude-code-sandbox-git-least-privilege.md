# ADR 0001: Claude Code Sandbox — Git Least Privilege Model

## Status

Accepted

## Context

Claude Code's sandbox (`settings.json`) was configured with
`excludedCommands: ["git", "gh"]`, which runs all git and GitHub CLI operations
completely outside the sandbox — no filesystem, network, or Unix socket
restrictions apply.

This was a pragmatic workaround for several issues:

1. **SSH access**: `git push` via SSH requires reading `~/.ssh/known_hosts` and
   `~/.ssh/config`, plus access to the SSH agent Unix socket (`$SSH_AUTH_SOCK`),
   all of which the default sandbox denies.
2. **Git hooks**: Tools like Lefthook and Husky execute as git child processes.
   Their stash operations write to `/tmp`, which the default sandbox write
   allowlist (`allowOnly: ["."]`) blocks.
3. **GitHub CLI (gh)**: Requires access to macOS TLS trust service
   (`com.apple.trustd.agent`) for HTTPS certificate verification. The sandbox
   blocks this Mach service, and `enableWeakerNetworkIsolation` only works with
   `httpProxyPort` (MITM proxy scenarios). Therefore `gh` cannot be sandboxed
   without a proxy and remains in `excludedCommands`.

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

Remove `git` from `excludedCommands` and grant minimal sandbox permissions.
`gh` remains in `excludedCommands` due to TLS trust service restrictions.

```json
{
  "sandbox": {
    "filesystem": {
      "allowRead": ["~/.ssh/known_hosts", "~/.ssh/config", "~/.config/gh/hosts.yml"],
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
| `allowRead: ~/.config/gh/hosts.yml` | GitHub CLI auth config; `excludedCommands` does not fully bypass `denyOnly` read restrictions |
| `allowWrite: /tmp` | Lefthook/Husky stash operations and temp files |
| `allowAllUnixSockets: true` | SSH agent access; `allowUnixSockets` requires literal paths but `$SSH_AUTH_SOCK` is dynamic |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory) and `/tmp`
- Arbitrary network hosts — restricted to `allowedDomains` defaults (includes `github.com`)

### Why `gh` remains in `excludedCommands`

`gh` (Go-based) requires access to macOS `com.apple.trustd.agent` for TLS
certificate verification. The sandbox setting `enableWeakerNetworkIsolation` was
tested but only functions when `httpProxyPort` is configured (MITM proxy
scenario). Without a proxy, `gh` fails with `x509: OSStatus -26276`. Sandboxing
`gh` would require introducing an unnecessary MITM proxy, so `excludedCommands`
is the pragmatic choice.

## Consequences

### Positive

- **Reduced attack surface for git**: Git operations are now constrained by
  filesystem and network restrictions, whereas `excludedCommands` provided no
  restrictions at all.
- **Aligned with official guidance**: Follows Claude Code's recommended
  `allowWrite` pattern over `excludedCommands`.

### Negative

- **`allowAllUnixSockets: true` is broader than ideal**: Allows sandboxed
  commands to connect to any Unix socket. Mitigated by `docker` remaining in
  `excludedCommands`. A future `allowUnixSockets` glob support would allow
  narrowing.
- **`/tmp` write access is global**: All sandboxed commands can write to `/tmp`.
  `/tmp` is an OS-standard world-writable directory; risk increase is limited.
- **`gh` remains unsandboxed**: Due to TLS trust service limitations, `gh`
  continues to run without sandbox restrictions.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| First connection to new SSH host fails (can't write `known_hosts`) | Medium | Run `ssh -T git@github.com` manually beforehand |
| `allowedDomains` doesn't apply to SSH (port 22) | Low | Add `network.allowedDomains: ["github.com"]` if needed |
| Lefthook needs writes beyond `/tmp` | Low | Add paths to `allowWrite` as discovered |

### Known Limitations

- **`git push -u` writes to `.git/config`**: The sandbox blocks writes to
  `.git/config` even though it is within the allowed working directory (`.`).
  The push itself succeeds; only the upstream tracking config update fails.
  This is an undocumented sandbox restriction.
- **`excludedCommands` does not fully bypass sandbox restrictions**: Commands in
  `excludedCommands` may still be blocked from reading files in the sandbox's
  `denyOnly` list. Explicit `allowRead` entries are required as workarounds.
- **`enableWeakerNetworkIsolation` requires `httpProxyPort`**: This setting only
  enables TLS trust service access when a MITM proxy is configured. It has no
  effect in non-proxy environments.

### Rollback

Add `"git"` back to `excludedCommands` and remove `filesystem` /
`allowAllUnixSockets`.
