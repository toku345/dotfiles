# ADR 0002: Claude Code Sandbox — GitHub CLI (`gh`) Cannot Be Sandboxed

## Status

Superseded (2026-10-27). The Decision below rested on the conclusion that `excludedCommands` cannot bypass the `trustd` Mach service restriction. That conclusion most likely came from tests in which the exclusion never matched: `sandbox.excludedCommands` uses the same matching as Bash permission rules (verified on 2.1.310; not re-checked on the older versions the original tests used), the bare entry `gh` matches only `gh` with no arguments, so those `gh <args>` invocations most likely remained sandboxed. With the wildcard entry `gh *`, a standalone `gh` call runs outside the sandbox and TLS to `api.github.com` succeeds without `dangerouslyDisableSandbox`. This is historical probe evidence from [PR #438](https://github.com/toku345/dotfiles/pull/438), not a new probe during integration. The current configuration is recorded in [Re-investigation 2026-10-27](#re-investigation-2026-10-27). The investigation results below remain accurate for `gh` running *inside* the sandbox.

## Context (historical)

`gh` was in `excludedCommands` alongside `git` (see [ADR 0001](0001-claude-code-sandbox-git-least-privilege.md)). ADR 0001 moved `git` to a least-privilege sandbox model. This ADR documents why `gh` cannot follow the same approach and remains in `excludedCommands`.

`gh` (Go-based) requires macOS TLS trust service (`com.apple.trustd.agent`) for HTTPS certificate verification. The sandbox blocks this Mach service.

## Decision (superseded)

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

> Superseded: the tests below used the bare entry `gh`, which under the matching verified on 2.1.310 does not match `gh <args>`. See [Re-investigation 2026-10-27](#re-investigation-2026-10-27).

Testing confirmed that `excludedCommands` does not bypass Seatbelt Mach service restrictions. `gh` in `excludedCommands` still fails with the same TLS error. The only working method is `dangerouslyDisableSandbox: true` on each Bash invocation. `gh` remains in `excludedCommands` to relax filesystem restrictions, but TLS requires per-call sandbox bypass.

## Consequences

> Superseded: see [Re-investigation 2026-10-27](#re-investigation-2026-10-27).

- `gh` remains in `excludedCommands`, relaxing filesystem restrictions but not Mach service restrictions
- TLS-dependent `gh` operations require `dangerouslyDisableSandbox: true` per invocation

## Re-investigation 2026-10-27

Reported and verified in [PR #438](https://github.com/toku345/dotfiles/pull/438) with Claude Code 2.1.310 on macOS. The integration work did not repeat these runtime probes.

### Findings

- **Matching semantics**: `sandbox.excludedCommands` entries are matched like Bash permission rules; without a wildcard the match is exact. The [sandboxing docs](https://code.claude.com/docs/en/sandboxing) state: "`docker` matches only `docker` with no arguments. `docker *` matches `docker` with or without arguments". Empirically, with a bare `ruby` entry excluded, `ruby -e` writing to `$HOME` fails with `EPERM`, i.e. it ran sandboxed. The previous `["docker", "gh", "codex"]` therefore had no effect on any invocation with arguments.
- **Compound commands are not excluded unless every part matches** (a necessary, not sufficient condition; redirects, `cd`, and substitutions may keep a call sandboxed). Under `claude -p --settings '{"sandbox":{"excludedCommands":["gh *"]}}'`, `gh pr list -L 1 --json number` succeeded (including TLS to `api.github.com`), while the same command piped into `jq` ran sandboxed and failed reading `~/.config/gh/hosts.yml`.
- **Behavior inside the sandbox**: `gh` cannot read `~/.config/gh/hosts.yml` and fails at startup; `docker` socket operations (`docker ps`) succeed via `allowAllUnixSockets`, but `~/.docker/config.json` (registry credentials) is unreadable; `codex` cannot write `~/.codex`.
- **Codex plugin**: `codex@openai-codex` launches through `node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-companion.mjs" ...`, so a `codex *` exclusion would not apply to plugin calls.

### Decision

Set `sandbox.excludedCommands` to `[]`: remove the ineffective bare `docker`, `gh`, and `codex` entries without turning them into blanket exclusions.

- Do not adopt `gh *`: it would automatically put writes, extensions, and other arbitrary `gh` invocations outside the filesystem/network sandbox. Prior retries do not establish that every future invocation has equivalent exposure.
- No narrow read-only exclusion is added yet. Even a command-prefix exception needs verified matching, argument/extension behavior, compound-command behavior, and negative tests before deployment; this integration has no such runtime evidence for a safe small set.
- `gh` continues to start sandboxed. When a sandbox-specific failure is established, use the ordinary approval-controlled unsandboxed retry rather than changing command form to evade a block. `--jq` avoids a pipeline but does not itself grant an exclusion in this baseline.
- `docker` needs no blanket exclusion for socket access. Direct credential-file denial remains useful, but Docker daemon/socket reachability is not full isolation and remains a hardening follow-up.
- `codex *` would not cover the plugin's `node` launcher. Direct CLI and plugin calls retain their ordinary retry/permission paths; no broader `node` exclusion is added.

### Accepted trade-offs and boundaries

- Read-only `gh` calls may still require a per-call retry. We accept that friction rather than automatically widening sandbox access.
- Exclusion bypasses OS filesystem/network isolation, not ordinary permission checks. Explicit asks remain; read-only or allow-rule decisions may bypass the classifier, while other commands can reach it. Conversation agreement is separate: commit, push, apply, and shared writes still need explicit agreement within task scope ([permission policy](../agent-permissions.md)).
- The matching findings above are version-specific evidence, not a promise of universal technical enforcement.

### Not adopted

- **`allowUnsandboxedCommands: false`**: some paths may still rely on the unsandboxed retry (e.g. scripts that enumerate processes with `pgrep`). Escape-path and socket hardening remain separately scoped follow-ups, not changes in this integration.

## TODO

- [ ] After Claude Code [#26466](https://github.com/anthropics/claude-code/issues/26466) is resolved, re-test `enableWeakerNetworkIsolation`
- [ ] When `gh` or Go is updated to a new major version, re-test `SSL_CERT_FILE` and `GODEBUG=x509usefallbackroots=1`
- [ ] Re-test whether authenticated `gh` can run inside the retained sandbox boundary without a retry; do not add persistent exclusions without a scoped decision and matching tests.
