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
   blocks this Mach service. `enableWeakerNetworkIsolation` should grant `trustd`
   access but is not wired from settings to the sandbox runtime
   ([#28954](https://github.com/anthropics/claude-code/issues/28954)).
   Therefore `gh` cannot currently be sandboxed and remains in `excludedCommands`.

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
      "allowWrite": ["/tmp", ".git"]
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
| `allowWrite: .git` | `git push -u` upstream tracking config, branch metadata, index updates |
| `allowAllUnixSockets: true` | SSH agent access; `allowUnixSockets` requires literal paths but `$SSH_AUTH_SOCK` is dynamic |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory), `.git`, and `/tmp`
- Arbitrary network hosts — restricted to `allowedDomains` defaults (includes `github.com`)

### Why `gh` remains in `excludedCommands`

`gh` (Go-based) requires access to macOS `com.apple.trustd.agent` for TLS
certificate verification. The sandbox blocks this Mach service.

**Attempted workaround — `SSL_CERT_FILE=/etc/ssl/cert.pem`**: Go's `crypto/x509`
can read certificates from a file specified by `SSL_CERT_FILE`, bypassing `trustd`.
However, macOS `gh` is built with cgo enabled, and the cgo-enabled `crypto/x509`
delegates to Security framework rather than reading `SSL_CERT_FILE`. The workaround
was tested and confirmed to fail with the same `x509: OSStatus -26276` error.

`enableWeakerNetworkIsolation` was also tested but had no effect. This may be
due to a wiring bug ([#28954](https://github.com/anthropics/claude-code/issues/28954))
where Claude Code does not pass this setting to the sandbox runtime, rather than
a requirement for `httpProxyPort`. Re-test after the bug is fixed.

**`excludedCommands` also does not resolve this**: Testing confirmed that
`excludedCommands` does not bypass Seatbelt Mach service restrictions. `gh` in
`excludedCommands` still fails with the same TLS error. The only working method
is `dangerouslyDisableSandbox: true` on each Bash invocation. `gh` remains in
`excludedCommands` to relax filesystem restrictions, but TLS requires per-call
sandbox bypass.

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
- **`gh` remains unsandboxed**: Due to TLS trust service limitations (`trustd`
  blocked by Seatbelt, `SSL_CERT_FILE` ignored by cgo-enabled builds), `gh`
  continues to run without sandbox restrictions.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| First connection to new SSH host fails (can't write `known_hosts`) | Medium | Run `ssh -T git@github.com` manually beforehand |
| `allowedDomains` doesn't apply to SSH (port 22) | Low | Add `network.allowedDomains: ["github.com"]` if needed |
| Lefthook needs writes beyond `/tmp` | Low | Add paths to `allowWrite` as discovered |

### Known Limitations

- **`gh` cannot be sandboxed on macOS**: cgo-enabled Go builds use Security
  framework for TLS, which requires `trustd` Mach service access. Neither
  `SSL_CERT_FILE` nor `enableWeakerNetworkIsolation` (without proxy) resolves this.
  Furthermore, `excludedCommands` does not bypass Seatbelt Mach service restrictions
  — `gh` in `excludedCommands` still fails with `x509: OSStatus -26276`. The only
  working approach is `dangerouslyDisableSandbox: true` per invocation.
  **`GODEBUG=x509usefallbackroots=1` also ineffective** (tested 2026-03-21, gh
  v2.88.1 / Go 1.26): This GODEBUG setting forces Go's pure-Go certificate
  verifier as a fallback. However, it requires the program to call
  `crypto/x509.SetFallbackRoots()` to register a fallback certificate pool — `gh`
  does not call this function. All three combinations were tested and failed with
  the same `x509: OSStatus -26276` error:
  `GODEBUG + SSL_CERT_FILE`, `SSL_CERT_FILE` only, `GODEBUG` only.
  Tracked upstream: [#34876](https://github.com/anthropics/claude-code/issues/34876),
  [#23416](https://github.com/anthropics/claude-code/issues/23416),
  [#26466](https://github.com/anthropics/claude-code/issues/26466).
- **`excludedCommands` does not fully bypass sandbox restrictions**: Commands in
  `excludedCommands` may still be blocked from reading files in the sandbox's
  `denyOnly` list and from accessing Mach services (e.g., `trustd`). Explicit
  `allowRead` entries are required as workarounds for file access.
- **`enableWeakerNetworkIsolation` has no effect (wiring bug)**: This setting
  should allow `trustd` Mach service access, but Claude Code does not pass it to
  the sandbox runtime ([#28954](https://github.com/anthropics/claude-code/issues/28954),
  closed as duplicate of [#26466](https://github.com/anthropics/claude-code/issues/26466)).
  The official documentation states it is for use with `httpProxyPort` (MITM proxy),
  but whether it also works standalone to grant `trustd` access is untested due to
  this bug. Re-test after the bug is fixed.

### Resolved Limitations

- **`git push -u` writes to `.git/config`** (resolved by `allowWrite: [".git"]`):
  Previously the sandbox blocked writes to `.git/config` even though `.` was in
  the write allowlist. Adding `.git` explicitly resolved this.

### Rollback

Add `"git"` back to `excludedCommands` and remove `filesystem` /
`allowAllUnixSockets`.
