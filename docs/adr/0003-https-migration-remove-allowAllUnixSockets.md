# ADR 0003: HTTPS Migration — Remove `allowAllUnixSockets`

## Status

Rejected

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

## Investigation Results

### Homebrew git HTTPS TLS in sandbox

Homebrew's `git-remote-https` links to `/usr/lib/libcurl.4.dylib` (system
curl / SecureTransport). Unlike Go's `crypto/x509` (which fails in sandbox —
see [ADR 0002](0002-claude-code-sandbox-gh-investigation.md)), system curl's
TLS works within the Claude Code sandbox.

Verified: `git ls-remote https://github.com/toku345/dotfiles.git HEAD`
succeeds in sandbox.

### Credential helper compatibility

Three credential helpers were tested in the sandbox:

| Helper | `credential fill` | `git push` | Reason |
|--------|-------------------|------------|--------|
| `osxkeychain` | ✅ Returns credentials | ❌ Fails | Keychain Mach service blocked by Seatbelt; macOS prompts for keychain password but sandbox cannot display interactive prompts |
| `gh auth git-credential` (Keychain) | ❌ Fails | ❌ Fails | `~/.config/gh/hosts.yml` in default `read.denyOnly`; `gh` cannot read its own config |
| `gh auth git-credential` (insecure-storage) | Not tested | Not tested | Requires `~/.config/gh/hosts.yml` in `allowRead` — see Security Analysis |

**Note**: Initial `credential fill` tests appeared to succeed because
`osxkeychain` (Homebrew default) silently provided credentials as a fallback.
Actual `git push` operations failed because `osxkeychain` requires interactive
Keychain authorization prompts that the sandbox cannot display.

### Security analysis: `hosts.yml` in `allowRead`

Adding `~/.config/gh/hosts.yml` to `sandbox.filesystem.allowRead` was
evaluated as a fallback but **rejected** due to security regression:

| | SSH + `allowAllUnixSockets` (current) | HTTPS + `hosts.yml` allowRead |
|---|---|---|
| Attack surface breadth | Broad (all Unix sockets) | Narrow (one file) |
| Secret exposure | **Indirect** — SSH agent mediates; private key never exposed | **Direct** — bearer token readable as plaintext |
| Exfiltration risk | Agent signing only; key cannot be extracted | Token can be exfiltrated and reused independently |
| Docker socket | Accessible, but `docker` already in `excludedCommands` | Not accessible |

The SSH agent model provides stronger secret protection: the private key is
never directly exposed, and access is mediated through the agent. A plaintext
bearer token in `hosts.yml` is a strictly weaker security model despite the
narrower attack surface.

### `url.insteadOf` for global scope

`url.insteadOf` in git config can transparently rewrite `git@github.com:` to
`https://github.com/`, eliminating per-repo remote URL changes. Only GitHub
SSH remotes are in use.

## Decision

**Do not migrate**. Keep SSH + `allowAllUnixSockets` as documented in
[ADR 0001](0001-claude-code-sandbox-git-least-privilege.md).

No credential helper works reliably in the Claude Code sandbox without either:
- Keychain Mach service access (blocked by Seatbelt), or
- Adding sensitive token files to `allowRead` (security regression)

### Re-evaluate when

- Claude Code adds `allowUnixSockets` glob/env-var support (narrowing to
  `$SSH_AUTH_SOCK` only) — tracked in ADR 0001
- Claude Code resolves Mach service restrictions for `excludedCommands`
  ([#26466](https://github.com/anthropics/claude-code/issues/26466))
- macOS Keychain access works within Seatbelt sandbox profiles
