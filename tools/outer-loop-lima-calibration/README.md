# Private Lima Pre-Arm Calibration Harness

This repository-only harness implements the fail-closed calibration defined by [ADR 0032](../../docs/adr/0032-private-lima-outer-loop-calibration-boundary.md), [ADR 0033](../../docs/adr/0033-private-lima-runtime-main-process-egress-risk.md), and the [implementation design](../../docs/design/codex-claude-outer-loop-private-lima-calibration-implementation.md).

Static validation does not create a VM, authenticate a runtime, register a LaunchAgent, or run a model. A later live cycle must execute every human gate and control in order. The only successful live terminal is:

```text
LIMA_CALIBRATION_READY_FOR_V3_DESIGN
real_task_allowed: no
```

Every other calibration terminal is `BLOCKED` with `real_task_allowed: no`. A failed or interrupted provision cannot be retried in the same run; remediation uses a new run ID, a new physical Lima home, and new guests. Cleanup can additionally record lifecycle disposition `CLEANUP_MANUAL_REQUIRED`, which remains `BLOCKED` and grants no real-task authority.

## Fixed identities and repository boundary

`versions.lock.json` pins the host, image, runtime, sandbox, Node, Ubuntu snapshot/index, and guest package identities. `manifest.json` lists every runtime file below this directory except itself. `preflight` rejects any missing file, unlisted file, symlink, or digest drift, then copies only the manifest-listed bytes into the run's read-only `frozen-harness/`.

The profiles are static YAML. They use VZ/aarch64 with 4 CPUs, 8 GiB RAM, and a 40 GiB disk, and disable host mounts, additional disks, containerd, declared networks, port forwarding, proxy propagation, SSH-agent forwarding, and X11 forwarding. Provisioning uses only the frozen harness and creates the non-sudo `calibration` account. Authentication remains guest-local.

This directory is excluded from chezmoi deployment by the repository `.chezmoiignore`.

## CLI

The public command sequence is fixed:

```text
init
preflight
approve pre-vm
provision
approve pre-auth
authenticate runtime
run isolation
run sync-export
approve pre-handoff
run handoff-forward
run handoff-reverse
run restart
prepare-seal
approve final-seal
seal
status
cleanup
verify-cleanup
```

There is no `--yes`, phase skip, arbitrary control selector, or same-run retry. All approvals require real stdin/stdout TTYs and exact re-entry of the gate name and digest. `approve pre-auth` also requires the operator to confirm that Claude's subscription code-paste flow is feasible without port forwarding; otherwise the run blocks without relaxing the boundary.

Example syntax for a later live cycle (do not run during implementation review):

```bash
python3 tools/outer-loop-lima-calibration/calibrate.py \
  init run-20300102 --retention-deadline 2030-01-03T00:00:00Z
python3 tools/outer-loop-lima-calibration/calibrate.py preflight run-20300102
python3 tools/outer-loop-lima-calibration/calibrate.py approve pre-vm run-20300102
```

The operational logical state root is `~/.local/state/outer-loop/lima-prearm/v1`. Each run binds write-once to a fresh short physical `LIMA_HOME` at `~/.local/state/ol/<10-char-token>`, where the lowercase Base32 token is deterministically derived from a domain-separated SHA-256 of the canonical state root and run ID. The harness checks both its `<=95`-byte socket-path policy and Lima `2.1.4`'s `<104`-byte limit before its first write. Existing bindings, token directories, instance directories, disks, symlink ancestry, or ambiguous Lima state are never reused.

`--lima-pool-root <absolute-path>` selects an explicit physical pool. A custom `--state-root` requires an explicit `--lima-pool-root` before the first write; hermetic tests always pass both temporary roots and never touch the operational pool. Relative paths and implicit environment-derived pool fallback are rejected. The same resolved pool is carried through the orchestrator, every `LIMA_HOME`, the retention wrapper/LaunchAgent read-back, cleanup, and `verify-cleanup`.

Instance names are fixed as `outer-loop-week0-codex` and `outer-loop-week0-claude`. Preflight parses Lima `2.1.4` list output as JSON Lines and requires an empty namespace plus both fixed instance-directory/root-disk paths absent. Arrays, malformed or mistyped records, nonzero results, mixed/additional stderr, and any non-canonical empty result are `UNKNOWN`. H1 binds the physical-home identity, harness manifest, parser contract, and absence snapshot. After retention registration, provision repeats that freshness check immediately before any create, then performs `create -> Stopped identity` for both guests before `start -> Running identity`. Create/start attempts are append-only and are written before invocation. An orphan, duplicate, contradiction, or identity drift blocks without same-run retry.

A run-level advisory lock is held from each started operation through completion: `status` reports a lock-held operation as `IN_PROGRESS` without mutation and converts only a lock-free started occurrence to `ORPHANED_BLOCKED`. Cleanup acquires the same lock before reloading state, so it waits for a healthy phase to finish and classifies only a remaining lock-free marker as orphaned.

New run state, evidence, seal input, and cleanup attestations use runtime `schema_version: 2`. Existing runtime schema 1 runs are read-only; they are not migrated, backfilled, mutated, or re-attested, and mutating commands fail closed. `manifest.json` remains schema 1.

## Live controls

- C00 validates the host lock/manifest, both guest/runtime identities, root-owned policy, and Codex's key-by-key `config/read` plus `configRequirements/read` effective values.
- C01 proves distinct instance/disk identities and the non-sudo, non-mounted, runtime-non-writable policy boundary.
- C02 permits only Codex device authentication and Claude.ai subscription authentication. Raw status/model streams stay in guest tmpfs and the guest sanitizer emits only allowlisted authentication and tool-free-smoke classifications.
- C03 applies only to agent-launched commands. Scheduled host DNS/IPv4 TCP/UDP probes pair a guest-root reachability baseline and operator-side nonce canary with a root-sanitized wrapper receipt and the actual Codex/Claude tool event. The sanitizer accepts markers only from the matching CLI-authored completed command/tool-result event, verifies its structured failure state and full wrapper argv digest, ignores agent-message text, and reconstructs a minimal root-only receipt. Each canary binds only the dedicated non-loopback host IPv4 resolved by the guest for `host.lima.internal`; wildcard listeners are rejected. The fixed probe maps only allowlisted errors raised by its network syscall to an exact marker and exit code; generic stderr remains ambiguous. Claude first runs the same command through pinned SRT and then through the real Bash tool; stage two is load-bearing. Every matrix target must appear exactly once as either a passing applicable control or an `UNAVAILABLE_BASELINE` observation. Listener errors force `UNVERIFIED`; targets without a configured canary provide no route-absence or denial claim. Main-process egress remains accepted risk AR-02, outside control aggregation.
- C04-C06 run once for each driver direction against fresh `0700` disposable staging. The guard requires real TTYs, pins the validated staging inode with a no-follow directory descriptor, runs Lima from that pinned directory with `--sync=.`, and verifies the path identity again afterward. The fixed No/nonzero/Yes cases are inventoried; export then uses no-follow quarantine, double stable inventories, and direction-specific read-only canonical freeze.
- C07 stops each driver before the opposite reviewer recomputes every file digest in the corresponding frozen bundle. Forward and reverse have separate bundle manifests and records.
- C08 stop/starts both guests, reruns C02/C03 with `post_restart`, requires final digest approval, and proves both guests stopped before sealing.

The live sync phase prints the expected response before each Lima prompt. Choosing any other response changes the observed inventory and blocks the run.

## Retention and cleanup

Before provisioning creates either guest, the frozen harness generates and reads back a per-run LaunchAgent with `RunAtLoad`, deadline calendar scheduling, and hourly catch-up. Its wrapper carries the exact resolved state and Lima-pool roots, independently compares the immutable UTC deadline, and exits without side effects before it is due. The orchestrator also checks the deadline before every mutating operation and transitions the run to `BLOCKED` when it is due, even if scheduled cleanup has not run. The live cycle reads back bootstrap/print and runs a not-due kickstart before authentication. An authentication attempt is durably marked before its interactive login command so cleanup can require provider-side revoke disposition even when later classification fails.

Deadline, abandonment, exposure, or cohort completion blocks new work. Cleanup first serializes behind any current run operation and reloads committed state. It may operate only on a fixed guest whose strict live identity matches the recorded Stopped or Running identity and whose provision evidence is coherent. A recognized Running guest is stopped by fixed name, its Stopped identity is read back, and the recognized fixed guest is deleted through Lima. Every destructive Lima call has an immediate strict identity recheck. After strict instance/disk absence, the only direct filesystem removal allowed is one `rmdir` of the bound physical home after proving it unchanged and completely empty.

`UNKNOWN`, a partial instance directory, unrelated content, identity/binding drift, orphaned or contradictory provision evidence, a failed Lima call, or residual content causes `CLEANUP_MANUAL_REQUIRED` with zero further destructive action. The harness does not classify or recover partial layouts, quarantine them, unlink nodes, recursively delete, repair, generate manual deletion commands, or retry cleanup in the same run. Only `status`, read-only diagnostics, and read-only `verify-cleanup` remain. After operator action outside the harness, verification reaches `CLEANUP_VERIFIED` only when the strict namespace, fixed directories/disks, physical home, inactive retention job, and any account-revoke disposition are all clear. The wrapper, plist, and evidence remain as operator-owned records.

Retention does not guarantee complete deletion by the deadline. It guarantees that new runtime work is prohibited and that recognized state receives at most one safe automatic cleanup attempt. A guest, disk, or home may remain for operator inspection. Cleanup attestations are separate schema-2 records bound to the immutable calibration seal.

An unresolved `CLEANUP_MANUAL_REQUIRED` run under the selected state root, or any unexplained/unbound pool entry, blocks initialization of another live run. Read-only diagnostics report the recorded run ID, roots, fixed names, instance directories, disks, and binding/evidence paths; they do not print or execute deletion commands.

## Static verification

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s tests/outer_loop_lima -p 'test_*.py'

find tools/outer-loop-lima-calibration/guest \
  -type f -name '*.sh' \
  -exec shellcheck --severity=warning {} +

limactl validate --tty=false \
  tools/outer-loop-lima-calibration/profiles/week0-codex.yaml \
  tools/outer-loop-lima-calibration/profiles/week0-claude.yaml
```

These checks are hermetic and do not establish a live C00-C08 result.
