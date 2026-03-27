# ADR 0003: HTTPS Migration — Remove `allowAllUnixSockets`

## Status

Accepted

## Context

[ADR 0001](0001-claude-code-sandbox-git-least-privilege.md) moved `git` to a
least-privilege sandbox model but required `allowAllUnixSockets: true` for SSH
agent access. This permission allows all sandboxed commands to connect to any
Unix socket, including Docker and OrbStack daemons — broader than ideal.

ADR 0001 noted this as a negative consequence and listed HTTPS migration as a
potential fix, but rejected it at the time because "SSH is used across multiple
repos and environments" (ADR 0001 L128).

This ADR re-evaluates HTTPS migration with two motivations:

1. **Reduce sandbox attack surface**: Remove `allowAllUnixSockets` and all
   SSH-related `allowRead`/`allowWrite` permissions.
2. **Enable `git push` from Linux remote sessions**: `ssh -a` (agent forwarding
   disabled) prevents SSH-based `git push` from remote Linux machines. HTTPS
   authentication does not depend on SSH agent forwarding.

### Investigation Results

#### Homebrew git HTTPS TLS in sandbox

Homebrew's `git-remote-https` links to `/usr/lib/libcurl.4.dylib` (system
curl / SecureTransport). Unlike Go's `crypto/x509` (which fails in sandbox —
see [ADR 0002](0002-claude-code-sandbox-gh-investigation.md)), system curl's
TLS works within the Claude Code sandbox.

Verified: `git ls-remote https://github.com/toku345/dotfiles.git HEAD`
succeeds in sandbox.

#### Credential helper compatibility

Three credential helpers were tested in the sandbox:

| Helper | Sandbox | Cross-platform | Security model |
|--------|---------|----------------|----------------|
| `osxkeychain` | ✅ Works | macOS only | Keychain (no file exposure) |
| `gh auth git-credential` (Keychain) | ✅ Works | macOS + Linux | Keychain on macOS, gh storage on Linux |
| `credential.helper = store` | Not tested | Both | Plaintext file (security regression) |

`gh auth git-credential` was selected for cross-platform support. On macOS,
`gh` stores tokens in the Keychain (via `keyring`). The credential helper
reads stored tokens and outputs them to stdout — it does not make TLS calls,
so the `trustd` issue documented in ADR 0002 does not apply.

A harmless `fatal: failed to get: 100001` error appears on stderr in sandbox
but does not affect credential output on stdout.

#### `url.insteadOf` for global scope

Since `settings.json` applies globally to all repositories, all repos must
work with HTTPS. `url.insteadOf` in git config transparently rewrites
`git@github.com:` to `https://github.com/`, so individual repos do not need
remote URL changes.

Only GitHub SSH remotes are in use (verified via `git remote -v`). The GitLab
backup remote in `docs/backup-restore.md` is an illustrative example, not an
active remote.

## Decision

Migrate git operations from SSH to HTTPS authentication and remove all
SSH-related sandbox permissions.

### Git config changes

```ini
[credential "https://github.com"]
    helper = !gh auth git-credential

[url "https://github.com/"]
    insteadOf = git@github.com:
```

### Sandbox config changes

Removed:
- `allowRead`: `~/.ssh/known_hosts`, `~/.ssh/config`, `~/.ssh/config.local`,
  `~/.orbstack/ssh/config`
- `allowWrite`: `~/.ssh/known_hosts`
- `allowAllUnixSockets: true`

No new `allowRead` entries needed — credential helper reads from Keychain
(macOS) or gh's native storage (Linux), not from files in the sandbox.

## Consequences

### Positive

- **`allowAllUnixSockets` removed**: All Unix socket access (Docker daemon,
  OrbStack, SSH agent) eliminated from sandboxed commands.
- **SSH-related filesystem permissions removed**: `~/.ssh/known_hosts`,
  `~/.ssh/config`, `~/.ssh/config.local`, `~/.orbstack/ssh/config` no longer
  exposed to sandboxed commands.
- **Linux remote `git push` enabled**: HTTPS authentication does not require
  SSH agent forwarding. `git push` now works from Linux machines connected via
  `ssh -a`.
- **No new file exposure**: Unlike the `hosts.yml` fallback approach,
  Keychain-based credential storage does not require adding sensitive files to
  `allowRead`.

### Negative

- **Requires `gh` installed**: `gh auth git-credential` depends on GitHub CLI
  being installed and authenticated on each machine. This is already the case
  for both macOS and Linux environments.
- **`url.insteadOf` rewrites all GitHub SSH URLs**: All repos using
  `git@github.com:` will transparently use HTTPS. This is intentional but
  irreversible without removing the config entry.
- **Harmless stderr noise**: `gh auth git-credential` emits
  `fatal: failed to get: 100001` on stderr when run in sandbox. Does not
  affect functionality.

### Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| `gh` token expires or is revoked | Low | `gh auth login` to re-authenticate |
| Future `gh` version changes credential helper behavior | Low | Pin behavior with `gh auth setup-git`; test on upgrade |
| Non-GitHub SSH remotes added later | Low | Add `url.insteadOf` for new hosts or restore SSH permissions |

### Rollback

Re-add SSH sandbox permissions from ADR 0001 and remove the `credential` and
`url` sections from git config:

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
    }
  }
}
```
