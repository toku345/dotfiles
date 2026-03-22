# ADR 0002: Claude Code Sandbox — GitHub CLI (`gh`) Cannot Be Sandboxed

## Status

Accepted

## Context

`gh` was in `excludedCommands` alongside `git`
(see [ADR 0001](0001-claude-code-sandbox-git-least-privilege.md)).
ADR 0001 moved `git` to a least-privilege sandbox model. This ADR documents
why `gh` cannot follow the same approach and remains in `excludedCommands`.

`gh` (Go-based) requires macOS TLS trust service (`com.apple.trustd.agent`)
for HTTPS certificate verification. The sandbox blocks this Mach service.

## Decision

`gh` remains in `excludedCommands`. TLS operations additionally require
`dangerouslyDisableSandbox: true` per invocation — `excludedCommands` alone
does not bypass Seatbelt Mach service restrictions.

Re-attempt sandboxing when either condition is met:

- Claude Code resolves the `enableWeakerNetworkIsolation` wiring issue
  ([#26466](https://github.com/anthropics/claude-code/issues/26466))
- `gh` or Go adds support for `SSL_CERT_FILE` on macOS

## Investigation Results

### `SSL_CERT_FILE=/etc/ssl/cert.pem`

Go's `crypto/x509` can read certificates from a file specified by
`SSL_CERT_FILE`, bypassing `trustd`. However, Go's `crypto/x509` excludes
macOS from `SSL_CERT_FILE` support at the platform level, regardless of cgo.
On macOS, certificate verification always delegates to Security framework.
The workaround was tested and confirmed to fail with the same
`x509: OSStatus -26276` error.

### `GODEBUG=x509usefallbackroots=1`

Tested 2026-03-21, gh v2.88.1 / Go 1.26.

This GODEBUG setting disables the macOS platform verifier and forces the
pure-Go verifier. However, `gh` does not call
`crypto/x509.SetFallbackRoots()` to register a fallback certificate pool,
so the pool is empty and verification fails. All three combinations were
tested and failed with the same `x509: OSStatus -26276` error:
`GODEBUG + SSL_CERT_FILE`, `SSL_CERT_FILE` only, `GODEBUG` only.

Re-test when `gh` or Go is updated to a new major version.

Tracked upstream:
[#34876](https://github.com/anthropics/claude-code/issues/34876),
[#23416](https://github.com/anthropics/claude-code/issues/23416),
[#26466](https://github.com/anthropics/claude-code/issues/26466).

### `enableWeakerNetworkIsolation`

`enableWeakerNetworkIsolation` was also configured but had no observable effect
due to the wiring issue
([#26466](https://github.com/anthropics/claude-code/issues/26466); `#28954` was
closed as duplicate). This setting is documented for use with `httpProxyPort`
(MITM proxy). Whether it would grant standalone `trustd` access if the wiring
issue were resolved remains unknown. Re-test after the issue is resolved.

### `excludedCommands` does not bypass Mach service restrictions

Testing confirmed that `excludedCommands` does not bypass Seatbelt Mach service
restrictions. `gh` in `excludedCommands` still fails with the same TLS error.
The only working method is `dangerouslyDisableSandbox: true` on each Bash
invocation. `gh` remains in `excludedCommands` to relax filesystem restrictions,
but TLS requires per-call sandbox bypass.

## Consequences

- `gh` remains in `excludedCommands`, relaxing filesystem restrictions but not
  Mach service restrictions
- TLS-dependent `gh` operations require `dangerouslyDisableSandbox: true` per
  invocation

## TODO

- [ ] After Claude Code [#26466](https://github.com/anthropics/claude-code/issues/26466)
  is resolved, re-test `enableWeakerNetworkIsolation`
- [ ] When `gh` or Go is updated to a new major version, re-test `SSL_CERT_FILE`
  and `GODEBUG=x509usefallbackroots=1`
- [ ] If either unblocks `trustd` access, move `gh` out of `excludedCommands`
  into a least-privilege model (following [ADR 0001](0001-claude-code-sandbox-git-least-privilege.md))
