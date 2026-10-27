# ADR 0002: Claude Code Sandbox — GitHub CLI (`gh`) Cannot Be Sandboxed

## Status

Superseded (2026-10-27). The Decision below rested on the conclusion that `excludedCommands` cannot bypass the `trustd` Mach service restriction. That conclusion was drawn from tests in which the exclusion never matched: `sandbox.excludedCommands` uses the same matching as Bash permission rules, so the bare entry `gh` matches only `gh` with no arguments, and every `gh <args>` invocation ran inside the sandbox. With the wildcard entry `gh *`, a standalone `gh` call runs outside the sandbox and TLS to `api.github.com` succeeds without `dangerouslyDisableSandbox`. The current configuration is recorded in [Re-investigation 2026-10-27](#re-investigation-2026-10-27). The investigation results below remain accurate for `gh` running *inside* the sandbox.

## Context

`gh` was in `excludedCommands` alongside `git` (see [ADR 0001](0001-claude-code-sandbox-git-least-privilege.md)). ADR 0001 moved `git` to a least-privilege sandbox model. This ADR documents why `gh` cannot follow the same approach and remains in `excludedCommands`.

`gh` (Go-based) requires macOS TLS trust service (`com.apple.trustd.agent`) for HTTPS certificate verification. The sandbox blocks this Mach service.

## Decision

`gh` remains in `excludedCommands`. TLS operations additionally require `dangerouslyDisableSandbox: true` per invocation — `excludedCommands` alone does not bypass Seatbelt Mach service restrictions.

Re-attempt sandboxing when either condition is met:

- Claude Code resolves the `enableWeakerNetworkIsolation` wiring issue ([#26466](https://github.com/anthropics/claude-code/issues/26466))
- `gh` or Go adds support for `SSL_CERT_FILE` on macOS

## Investigation Results

### `SSL_CERT_FILE=/etc/ssl/cert.pem`

Go's `crypto/x509` can read certificates from a file specified by `SSL_CERT_FILE`, bypassing `trustd`. However, Go's `crypto/x509` excludes macOS from `SSL_CERT_FILE` support at the platform level, regardless of cgo. On macOS, certificate verification always delegates to Security framework. The workaround was tested and confirmed to fail with the same `x509: OSStatus -26276` error.

### `GODEBUG=x509usefallbackroots=1`

Tested 2026-03-21, gh v2.88.1 / Go 1.26.

This GODEBUG setting is documented to disable the macOS platform verifier and force the pure-Go verifier. However, all three combinations were tested and failed with the same `x509: OSStatus -26276` error (an macOS Security framework error code, not a pure-Go verifier error), indicating the platform verifier is still active despite the GODEBUG setting: `GODEBUG + SSL_CERT_FILE`, `SSL_CERT_FILE` only, `GODEBUG` only. Re-verified 2026-03-23 with identical results.

Re-test when `gh` or Go is updated to a new major version.

Tracked upstream: [#34876](https://github.com/anthropics/claude-code/issues/34876), [#23416](https://github.com/anthropics/claude-code/issues/23416), [#26466](https://github.com/anthropics/claude-code/issues/26466).

### `enableWeakerNetworkIsolation`

`enableWeakerNetworkIsolation` was also configured but had no observable effect due to the wiring issue ([#26466](https://github.com/anthropics/claude-code/issues/26466); `#28954` was closed as duplicate). This setting is documented for use with `httpProxyPort` (MITM proxy). Whether it would grant standalone `trustd` access if the wiring issue were resolved remains unknown. Re-test after the issue is resolved.

### `excludedCommands` does not bypass Mach service restrictions

> Superseded: the tests below used the bare entry `gh`, which never matched `gh <args>`. See [Re-investigation 2026-10-27](#re-investigation-2026-10-27).

Testing confirmed that `excludedCommands` does not bypass Seatbelt Mach service restrictions. `gh` in `excludedCommands` still fails with the same TLS error. The only working method is `dangerouslyDisableSandbox: true` on each Bash invocation. `gh` remains in `excludedCommands` to relax filesystem restrictions, but TLS requires per-call sandbox bypass.

## Consequences

- `gh` remains in `excludedCommands`, relaxing filesystem restrictions but not Mach service restrictions
- TLS-dependent `gh` operations require `dangerouslyDisableSandbox: true` per invocation

## Re-investigation 2026-10-27

Verified with Claude Code 2.1.310 on macOS.

### Findings

- **Matching semantics**: `sandbox.excludedCommands` entries are matched like Bash permission rules; without a wildcard the match is exact. The [sandboxing docs](https://code.claude.com/docs/en/sandboxing) state: "`docker` matches only `docker` with no arguments. `docker *` matches `docker` with or without arguments". Empirically, with a bare `ruby` entry excluded, `ruby -e` writing to `$HOME` fails with `EPERM`, i.e. it ran sandboxed. The previous `["docker", "gh", "codex"]` therefore had no effect on any invocation with arguments.
- **Compound commands are not excluded unless every part matches** (docs: "Every command in the call has to match"). Under `claude -p --settings '{"sandbox":{"excludedCommands":["gh *"]}}'`, `gh pr list -L 1 --json number` succeeded (including TLS to `api.github.com`), while the same command piped into `jq` ran sandboxed and failed reading `~/.config/gh/hosts.yml`.
- **Behavior inside the sandbox**: `gh` cannot read `~/.config/gh/hosts.yml` and fails at startup; `docker` socket operations (`docker ps`) succeed via `allowAllUnixSockets`, but `~/.docker/config.json` (registry credentials) is unreadable; `codex` cannot write `~/.codex`.
- **Codex plugin**: `codex@openai-codex` launches through `node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" ...`, so a `codex *` exclusion would not apply to plugin calls.

### Decision

Set `sandbox.excludedCommands` to `["gh *"]` and remove `docker` and `codex`.

- Standalone `gh` calls run outside the sandbox without a per-call `dangerouslyDisableSandbox` retry. Use `gh --jq` instead of piping to `jq`; a piped form is sandboxed and fails.
- `docker` stays sandboxed: socket operations already work inside the sandbox, so excluding it would only add access to registry credentials, which we prefer to keep unreadable.
- `codex` stays sandboxed: excluding `codex *` would not cover the plugin path, and direct `codex` CLI calls keep using `dangerouslyDisableSandbox` as needed.

### Accepted trade-offs

- Every standalone `gh` invocation, including `gh` extensions, runs outside the sandbox. Previously the same calls also ended up outside the sandbox through a per-call retry, so the effective exposure is unchanged; the retry prompt is removed.
- `gh ... | jq` fails inside the sandbox; callers must use `--jq`.

### Not adopted

- **`allowUnsandboxedCommands: false`**: some paths may still rely on the unsandboxed retry (e.g. scripts that enumerate processes with `pgrep`). Re-evaluate after operating with `gh *` for a while.

## TODO

- [ ] After Claude Code [#26466](https://github.com/anthropics/claude-code/issues/26466) is resolved, re-test `enableWeakerNetworkIsolation`
- [ ] When `gh` or Go is updated to a new major version, re-test `SSL_CERT_FILE` and `GODEBUG=x509usefallbackroots=1`
- [ ] If either unblocks `trustd` access, move `gh` out of `excludedCommands` into a least-privilege model (following [ADR 0001](0001-claude-code-sandbox-git-least-privilege.md))
