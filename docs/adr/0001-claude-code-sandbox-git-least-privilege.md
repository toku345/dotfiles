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
   ([#26466](https://github.com/anthropics/claude-code/issues/26466); `#28954` was closed as duplicate).
   Therefore `gh` cannot currently be sandboxed and remains in `excludedCommands`.

However, `excludedCommands` runs commands outside the sandbox, removing most
filesystem and network restrictions — though `denyOnly` read restrictions and
Mach service access remain enforced (see Known Limitations). This still violates
the principle of least privilege.

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
`gh` remains in `excludedCommands` due to TLS trust service restrictions.

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
| `allowRead: ~/.config/gh/hosts.yml` | GitHub CLI auth config; `excludedCommands` does not fully bypass `denyOnly` read restrictions |
| `allowWrite: /tmp` | Lefthook/Husky stash operations and temp files |
| `allowWrite: .git` | `git push -u` upstream tracking config, branch metadata, index updates |
| `allowWrite: ~/.ssh/known_hosts` | First SSH connection writes host key; contains only public keys |
| `allowAllUnixSockets: true` | SSH agent access; `allowUnixSockets` requires literal paths but `$SSH_AUTH_SOCK` is dynamic (note: opens ALL Unix sockets, not just SSH agent — see Negative consequences) |

### What is NOT permitted

- Private keys (`~/.ssh/id_ed25519`, `~/.ssh/id_rsa`) — provided via SSH agent
- Arbitrary filesystem writes — only `.` (working directory), `.git`, `/tmp`, and `~/.ssh/known_hosts`
- Arbitrary network hosts — `allowedDomains` is not explicitly configured; new outbound domains trigger a permission prompt at runtime

### Why `gh` remains in `excludedCommands`

`gh` (Go-based) requires access to macOS `com.apple.trustd.agent` for TLS
certificate verification. The sandbox blocks this Mach service.

**Attempted workaround — `SSL_CERT_FILE=/etc/ssl/cert.pem`**: Go's `crypto/x509`
can read certificates from a file specified by `SSL_CERT_FILE`, bypassing `trustd`.
However, Go's `crypto/x509` excludes macOS from `SSL_CERT_FILE` support at the
platform level, regardless of cgo. On macOS, certificate verification always
delegates to Security framework. The workaround was tested and confirmed to fail
with the same `x509: OSStatus -26276` error.

`enableWeakerNetworkIsolation` was also configured but had no observable effect
due to the wiring issue ([#26466](https://github.com/anthropics/claude-code/issues/26466);
`#28954` was closed as duplicate). This setting is documented for use with
`httpProxyPort` (MITM proxy). Whether it would grant standalone `trustd` access
if the wiring issue were resolved remains unknown. Re-test after the issue is
resolved.

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
- **`gh` remains partially unsandboxed**: `gh` is in `excludedCommands` to relax
  filesystem restrictions, but Seatbelt Mach service restrictions still apply.
  TLS operations require `dangerouslyDisableSandbox: true` per invocation.

### Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| First connection to new SSH host auto-adds host key to `known_hosts` | Low | `~/.ssh/known_hosts` is in `allowWrite`; contains only public host keys |
| `allowedDomains` doesn't apply to SSH (port 22) | Low | SSH access is gated by SSH agent and `~/.ssh/config` allowRead; no additional mitigation needed |
| Lefthook needs writes beyond `/tmp` | Low | Add paths to `allowWrite` as discovered |

### Known Limitations

- **`gh` cannot be sandboxed on macOS**: cgo-enabled Go builds use Security
  framework for TLS, which requires `trustd` Mach service access. Neither
  `SSL_CERT_FILE` nor `enableWeakerNetworkIsolation` (without proxy) resolves this.
  Furthermore, `excludedCommands` does not bypass Seatbelt Mach service restrictions
  — `gh` in `excludedCommands` still fails with `x509: OSStatus -26276`. The only
  working approach is `dangerouslyDisableSandbox: true` per invocation.
  **`GODEBUG=x509usefallbackroots=1` also ineffective** (tested 2026-03-21, gh
  v2.88.1 / Go 1.26): This GODEBUG setting disables the macOS platform verifier
  and forces the pure-Go verifier. However, `gh` does not call
  `crypto/x509.SetFallbackRoots()` to register a fallback certificate pool, so
  the pool is empty and verification fails. All three combinations were tested and failed with
  the same `x509: OSStatus -26276` error:
  `GODEBUG + SSL_CERT_FILE`, `SSL_CERT_FILE` only, `GODEBUG` only.
  Tracked upstream: [#34876](https://github.com/anthropics/claude-code/issues/34876),
  [#23416](https://github.com/anthropics/claude-code/issues/23416),
  [#26466](https://github.com/anthropics/claude-code/issues/26466).
  Re-test when `gh` or Go is updated to a new major version.
- **`excludedCommands` does not fully bypass sandbox restrictions**: Commands in
  `excludedCommands` may still be blocked from reading files in the sandbox's
  `denyOnly` list and from accessing Mach services (e.g., `trustd`). Explicit
  `allowRead` entries are required as workarounds for file access.
- **`.git` in `allowWrite` resolves relative to cwd**: If Claude Code is started
  from a subdirectory (e.g., `repo/subdir/`), `.git` resolves to
  `repo/subdir/.git` which doesn't exist. `git add`, `git commit`, and
  `git push -u` may fail. In practice, Claude Code sessions start from the
  repository root, so impact is limited.
- **`enableWeakerNetworkIsolation` has no effect without `httpProxyPort`**: This
  setting is documented for use with `httpProxyPort` (MITM proxy). Whether it also
  grants standalone `trustd` access is untested due to the wiring issue
  ([#28954](https://github.com/anthropics/claude-code/issues/28954), closed as
  duplicate of [#26466](https://github.com/anthropics/claude-code/issues/26466)).
  Re-test after the issue is resolved.

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
