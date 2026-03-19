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
  "env": {
    "SSL_CERT_FILE": "/etc/ssl/cert.pem"
  },
  "sandbox": {
    "filesystem": {
      "allowRead": ["~/.ssh/known_hosts", "~/.ssh/config", "~/.config/gh/hosts.yml"],
      "allowWrite": ["/tmp", ".git"]
    },
    "network": {
      "allowAllUnixSockets": true
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
| `allowWrite: .git` | `git push -u` upstream tracking config, branch metadata, index updates |
| `allowAllUnixSockets: true` | SSH agent access; `allowUnixSockets` requires literal paths but `$SSH_AUTH_SOCK` is dynamic |
| `SSL_CERT_FILE: /etc/ssl/cert.pem` | Bypass macOS `trustd` TLS service; Go programs read certs from this file directly |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory), `.git`, and `/tmp`
- Arbitrary network hosts — restricted to `allowedDomains` defaults (includes `github.com`)

### Why `gh` is now sandboxed

`gh` (Go-based) previously required `excludedCommands` because the sandbox blocks
macOS `com.apple.trustd.agent` for TLS certificate verification, causing
`x509: OSStatus -26276` errors. Setting `SSL_CERT_FILE=/etc/ssl/cert.pem` in the
sandbox environment allows Go's TLS stack to read certificates directly from the
filesystem, bypassing `trustd`. This file is a standard macOS system certificate
bundle.

If `SSL_CERT_FILE` does not resolve TLS errors (e.g., cgo-enabled builds still
prefer Security framework), `gh` should be added back to `excludedCommands`.

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
- **`.git` write access allows hook/config modification**: All sandboxed commands
  can write to `.git/config` and `.git/hooks/`. Risk is equivalent to when `git`
  was in `excludedCommands` (full filesystem access).
- **`SSL_CERT_FILE` may not work on all builds**: Go's cgo-enabled builds on
  macOS may still prefer Security framework over `SSL_CERT_FILE`. If `gh` fails,
  it must be moved back to `excludedCommands`.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| First connection to new SSH host fails (can't write `known_hosts`) | Medium | Run `ssh -T git@github.com` manually beforehand |
| `allowedDomains` doesn't apply to SSH (port 22) | Low | Add `network.allowedDomains: ["github.com"]` if needed |
| Lefthook needs writes beyond `/tmp` | Low | Add paths to `allowWrite` as discovered |

### Known Limitations

- **`SSL_CERT_FILE` is macOS-specific**: `/etc/ssl/cert.pem` is a macOS path.
  Linux では存在しないため、この設定のまま Linux に適用すると `gh` が TLS
  エラーで失敗する。Linux へ手動コピーする際は `SSL_CERT_FILE` を削除するか、
  Linux 側のパス（例: `/etc/ssl/certs/ca-certificates.crt`）に書き換えること。
- **`excludedCommands` does not fully bypass sandbox restrictions**: Commands in
  `excludedCommands` may still be blocked from reading files in the sandbox's
  `denyOnly` list. Explicit `allowRead` entries are required as workarounds.
- **`enableWeakerNetworkIsolation` requires `httpProxyPort`**: This setting only
  enables TLS trust service access when a MITM proxy is configured. It has no
  effect in non-proxy environments.

### Resolved Limitations

- **`git push -u` writes to `.git/config`** (resolved by `allowWrite: [".git"]`):
  Previously the sandbox blocked writes to `.git/config` even though `.` was in
  the write allowlist. Adding `.git` explicitly resolved this.
- **`gh` TLS certificate verification** (resolved by `SSL_CERT_FILE`):
  Previously `gh` required `excludedCommands` due to `trustd` access being
  blocked. Setting `SSL_CERT_FILE=/etc/ssl/cert.pem` allows Go to read certs
  directly.

### Rollback

Add `"git"` back to `excludedCommands` and remove `filesystem` /
`allowAllUnixSockets`.
