# ADR 0001: Claude Code Sandbox — Git/GitHub CLI Least Privilege Model

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
3. **GitHub CLI auth**: `gh` reads `~/.config/gh/hosts.yml` for authentication,
   which is in the sandbox's `denyOnly` read list.
4. **TLS certificate verification**: `gh` (Go-based) requires access to the
   macOS TLS trust service (`com.apple.trustd.agent`) for HTTPS certificate
   verification.

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

Remove `git` and `gh` from `excludedCommands` and grant minimal sandbox
permissions:

```json
{
  "sandbox": {
    "filesystem": {
      "allowRead": ["~/.ssh/known_hosts", "~/.ssh/config", "~/.config/gh/hosts.yml"],
      "allowWrite": ["/tmp"]
    },
    "network": {
      "allowAllUnixSockets": true,
      "enableWeakerNetworkIsolation": true
    },
    "excludedCommands": ["docker", "codex"]
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
| `enableWeakerNetworkIsolation: true` | macOS TLS trust service (`com.apple.trustd.agent`) access for Go-based tools (gh, gcloud, terraform) |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory) and `/tmp`
- Arbitrary network hosts — restricted to `allowedDomains` defaults (includes `github.com`)

## Consequences

### Positive

- **Reduced attack surface**: Git and gh operations are now constrained by
  filesystem and network restrictions, whereas `excludedCommands` provided no
  restrictions at all.
- **Aligned with official guidance**: Follows Claude Code's recommended
  `allowWrite` pattern over `excludedCommands`.
- **TLS verification works correctly**: `enableWeakerNetworkIsolation` enables
  proper certificate verification for all sandboxed HTTPS connections.

### Negative

- **`allowAllUnixSockets: true` is broader than ideal**: Allows sandboxed
  commands to connect to any Unix socket. Mitigated by `docker` remaining in
  `excludedCommands`. A future `allowUnixSockets` glob support would allow
  narrowing.
- **`/tmp` write access is global**: All sandboxed commands can write to `/tmp`.
  `/tmp` is an OS-standard world-writable directory; risk increase is limited.
- **`enableWeakerNetworkIsolation` opens trustd access**: All sandboxed commands
  gain access to macOS TLS trust service. In practice, this enables proper HTTPS
  certificate verification (a security benefit). The theoretical data exfiltration
  risk via trustd is negligible compared to the previous `excludedCommands` state
  which had no restrictions at all.

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
  `denyOnly` list and from accessing macOS system services. Explicit `allowRead`
  and `enableWeakerNetworkIsolation` entries are required as workarounds.

### Rollback

Add `"git"` and `"gh"` back to `excludedCommands` and remove `filesystem` /
`allowAllUnixSockets` / `enableWeakerNetworkIsolation`.
