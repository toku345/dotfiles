# ADR 0028: gitleaks secret-scanning baseline (retire git-secrets)

## Status

Accepted

## Context

Two public incidents motivate a portable secret-scanning baseline rather than a per-repo afterthought: the CAMPFIRE breach (leaked GitHub credentials → GitHub Actions abuse → cloud access) and the Money Forward breach (production data and source leaked via GitHub). The Money Forward post-mortems distill three lessons that shape this decision: technical gates beat human discipline ("本人は手順を破っているつもりがない"), private ≠ safe (access control collapses once credentials leak, so defense must be layered), and the authoritative gate must be server-side and un-skippable under schedule pressure.

This repository's prior secret controls had concrete gaps. CI scanned with a hand-rolled `rg 'gh[pusr]_[a-zA-Z0-9]{36}'` regex whose character class omitted `o`, so it silently missed `gho_` (the OAuth token `gh` actually stores) and `github_pat_` (fine-grained PATs) — exactly the durable bearer credentials the threat model targets. The local gate was `git-secrets`, registered for AWS patterns only and wired via `init.templateDir`, which copies hooks only into newly cloned or `git init`ed repos and so was not active on existing checkouts. Neither layer covered the broad universe of provider tokens.

A fleet audit across all personal repos confirmed the gap matters beyond this repo: private repos have no GitHub-native secret scanning (it requires paid Advanced Security), so for those repos a plan-independent scanner is the only available secret gate. A separate Actions-hardening gap (over-privileged default `GITHUB_TOKEN`, an unpinned third-party action receiving a production deploy token) is tracked outside this ADR.

## Decision

Adopt gitleaks as the single secret scanner and retire git-secrets, structured as layers:

- **L2 — local pre-commit (best-effort).** A framework-free global hook at `~/.git-template/hooks/pre-commit` runs `gitleaks protect --staged`. Wired via `init.templateDir`, it covers every new repo or `git init` only when `.git/hooks/pre-commit` does not already exist; existing repos with old git-secrets or custom hooks need manual inspect/replace/chain migration because git templates never overwrite hooks. It is intentionally bypassable with `--no-verify`; it is convenience, not the authoritative gate.
- **L3 — CI (authoritative).** `security-checks.yml` installs a version-pinned gitleaks binary verified against a hardcoded SHA-256 and runs `gitleaks git .` over full history, replacing the hand-rolled regex. On pull requests, the scan uses a trusted `.gitleaks.toml` from the protected base branch when available, otherwise gitleaks default rules, so a PR cannot weaken its own scanner config. `zizmor` lints the workflows themselves for hardening regressions (unpinned actions, `pull_request_target`, credential persistence, excessive permissions). Both are exposed as a reusable workflow (`secret-scan.reusable.yml`) so other repos gain the same gate via one `uses:` line; pin that reference to a commit SHA or version tag, and use `@main` only as an explicit mutable-dependency tradeoff.
- **L3 — server-side (un-skippable).** GitHub secret scanning + push protection, enabled per public repo, is the layer that survives a bypassed local hook.
- **L4 — periodic sweep.** `repo-security-audit` (read-only) reports the fleet's posture and, with `--history-sweep`, runs gitleaks over each repo's full history to surface already-committed live secrets.

The gitleaks config (`.gitleaks.toml`) extends the built-in ruleset (`useDefault = true`) with no repo-wide allowlist; a full scan of current files and all history produced zero findings and zero false positives, so no broader tuning is warranted.

Money Forward's first layer — masking production PII before it can enter a repo — is declined. It targets unstructured business PII (names, card numbers) that gitleaks cannot detect and that does not exist in this personal scope; the age two-layer model already protects secrets at rest. Importing that machinery would be complexity without a matching risk.

## Consequences

- Token coverage becomes comprehensive (150+ providers, all GitHub variants) and plan-independent, so private repos finally have a secret gate.
- The baseline propagates by reference: a caller repo adds one `uses:` line instead of copying YAML, and `repo-security-audit` makes drift across the fleet visible on demand.
- gitleaks does not detect unstructured PII — acceptable here, since none is present and the age model covers secrets at rest.
- The local hook is bypassable and warns/no-ops when gitleaks is absent; this is deliberate, because configured CI and push protection are authoritative, but each repo still needs those layers enabled separately. Pinned gitleaks/zizmor versions and the embedded checksum require periodic bumps.

## Related

- [ADR 0025](0025-global-gitignore-deny-by-default-secret-patterns.md) — global gitignore secret patterns (complementary prevention layer).
- [ADR 0003](0003-https-migration-remove-allowAllUnixSockets.md) — SSH over plaintext PAT; same "minimize durable bearer credentials" thread.
- [docs/security.md](../security.md) — operational secret-scanning details.
