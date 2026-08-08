# ADR 0035: Split the Private Outer Loop into a Dedicated Repository

## Status

Accepted

## Context

[ADR 0032](0032-private-lima-outer-loop-calibration-boundary.md) permitted a small repository-managed Private Lima calibration harness, and [ADR 0033](0033-private-lima-runtime-main-process-egress-risk.md) narrowed its runtime egress claim. The harness, its tests, profiles, fixtures, and active implementation documentation now form an experimental lifecycle with substantially different change cadence and review needs from the dotfiles repository.

Keeping that active lifecycle in dotfiles has made unrelated dotfiles work harder to review and deliver. The current source snapshot at commit `23eebcb5eea4adcfda4f29aa7477345922f6aab0` has passed its post-merge static receipt, while the completed calibration run has been cleaned and verified. This is therefore the appropriate boundary at which to separate future experimental work without importing live VM, disk, LaunchAgent, run, pool, state, or evidence resources.

## Decision

Move the active Private Lima calibration implementation to a dedicated GitHub repository named `toku345/private-outer-loop`, initially private and checked out at `~/works/toku345/private-outer-loop`. Preserve the repository-relative `tools/outer-loop-lima-calibration/` and `tests/outer_loop_lima/` layout so that the harness and its tests do not require an unrelated structural rewrite during migration.

Use a clean snapshot import rather than rewriting or filtering dotfiles history. Import the complete harness, test suite, and active Private Lima design documents from dotfiles commit `23eebcb5eea4adcfda4f29aa7477345922f6aab0`. Keep the exact import as its own commit and apply repository-boundary adaptations in a second commit. Merge the import pull request with a merge commit so the exact snapshot commit remains an ancestor of the cutover commit. Record source tree and blob identities, the exact import commit, the adaptation allowlist, and the final harness manifest digest in private-repository provenance. Mark the accepted cutover with an immutable annotated `migration-cutover-v1` tag.

Before any source push, read back that the destination repository visibility is `private`. The public dotfiles repository may name the destination repository and describe its role, but it must not publish the private repository's commit identifiers, manifest digest, or internal provenance. The reusable secret-scanning workflow may remain a deliberately pinned dependency on the public dotfiles repository.

Keep dotfiles authoritative until the destination import passes its post-merge static receipt. During that interval, freeze Private Lima harness changes and do not begin another calibration run. After the receipt, the dedicated repository becomes authoritative for future implementation changes and the dotfiles copy becomes a frozen fallback until a separate removal pull request merges.

Retain in dotfiles the immutable week0 v1/v2 packages, ADRs 0030 through 0033, the Private Lima design documents as historical snapshots, and the protected-history test. Move that test out of the active runtime suite and continue running it with a full-history checkout. Remove the active harness, runtime tests, Private Lima CI jobs, and harness-specific `.chezmoiignore` entry only after the destination receipt passes.

Do not migrate or modify existing logical state, physical `LIMA_HOME` pools, evidence, retained bindings, VM resources, disks, or LaunchAgents as part of the repository split. A fresh calibration remains a separate human-approved action with a new run ID after cutover.

## Consequences

### Positive

- Experimental implementation and lifecycle changes no longer block unrelated dotfiles work.
- The exact source snapshot remains auditable without importing the full dotfiles history.
- Historical decisions and immutable v1/v2 inputs remain available in their original public context.
- Existing runtime paths, state bindings, and evidence remain untouched by a source-control-only migration.

### Negative

- CI, repository guidance, security scanning, and release provenance must be maintained in a second repository.
- The cutover requires coordinated changes across two repositories and a temporary frozen duplicate.
- Public historical documents and private active documents must state their authority clearly to avoid two competing sources of truth.

### Risks

| Risk | Mitigation |
|---|---|
| Destination repository is accidentally public before import | Require a GitHub visibility read-back before pushing source |
| Snapshot adaptations obscure whether the source was imported faithfully | Preserve an exact import commit, merge without squash or rebase, and verify tree/blob identities |
| Dotfiles history loses its immutability guard | Retain the protected-history test in dotfiles with full-history CI |
| Both repositories accept active changes during cutover | Freeze the source snapshot and assign authority only after the destination receipt |
| Destination receipt or later removal fails | Do not remove the dotfiles copy until receipt; revert the removal pull request if rollback is needed |

## References

- [ADR 0032: Calibrate the Private Outer Loop with Separate Lima Guests](0032-private-lima-outer-loop-calibration-boundary.md)
- [ADR 0033: Accept Unenforced Runtime Main-Process Egress for Private Lima Calibration](0033-private-lima-runtime-main-process-egress-risk.md)
- [Private Lima pre-arm calibration design](../design/codex-claude-outer-loop-private-lima-calibration.md)
- [Private Lima calibration implementation design](../design/codex-claude-outer-loop-private-lima-calibration-implementation.md)
