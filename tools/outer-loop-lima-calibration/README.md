# Private Lima Pre-Arm Calibration Harness

This repository-only harness implements the fail-closed calibration defined by [ADR 0032](../../docs/adr/0032-private-lima-outer-loop-calibration-boundary.md), [ADR 0033](../../docs/adr/0033-private-lima-runtime-main-process-egress-risk.md), and the [implementation design](../../docs/design/codex-claude-outer-loop-private-lima-calibration-implementation.md).

Static validation does not create a VM, authenticate a runtime, register a LaunchAgent, or run a model. A later live cycle must execute every human gate and control in order. The only successful live terminal is:

```text
LIMA_CALIBRATION_READY_FOR_V3_DESIGN
real_task_allowed: no
```

Every other terminal is `BLOCKED` with `real_task_allowed: no`. A failed or interrupted run cannot be retried; remediation uses a new run ID and new guests.

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

Use `--state-root` only to isolate hermetic tests. The operational default is `~/.local/state/outer-loop/lima-prearm/v1`; `LIMA_HOME` is the dedicated `lima-home/` below it. Instance names are fixed as `outer-loop-week0-codex` and `outer-loop-week0-claude`.

## Live controls

- C00 validates the host lock/manifest, both guest/runtime identities, root-owned policy, and Codex's key-by-key `config/read` plus `configRequirements/read` effective values.
- C01 proves distinct instance/disk identities and the non-sudo, non-mounted, runtime-non-writable policy boundary.
- C02 permits only Codex device authentication and Claude.ai subscription authentication. Raw status/model streams stay in guest tmpfs and the guest sanitizer emits only allowlisted authentication and tool-free-smoke classifications.
- C03 applies only to agent-launched commands. Scheduled host DNS/IPv4 TCP/UDP probes pair a guest-root reachability baseline and operator-side nonce canary with a root-sanitized wrapper receipt and the actual Codex/Claude tool event. Claude first runs the same command through pinned SRT and then through the real Bash tool; stage two is load-bearing. Every matrix target must appear exactly once as either a passing applicable control or an `UNAVAILABLE_BASELINE` observation. Targets without a configured canary provide no route-absence or denial claim. Main-process egress remains accepted risk AR-02, outside control aggregation.
- C04-C06 run only against fresh `0700` disposable staging. The guard requires real TTYs; the fixed No/nonzero/Yes cases are inventoried; export then uses no-follow quarantine, double stable inventories, and read-only canonical freeze.
- C07 stops each driver before the opposite reviewer recomputes every file digest in the frozen bundle. Forward and reverse are separate records.
- C08 stop/starts both guests, reruns C02/C03 with `post_restart`, requires final digest approval, and proves both guests stopped before sealing.

The live sync phase prints the expected response before each Lima prompt. Choosing any other response changes the observed inventory and blocks the run.

## Retention and cleanup

After provisioning, the frozen harness generates a per-run LaunchAgent with `RunAtLoad`, deadline calendar scheduling, and hourly catch-up. Its wrapper independently compares the exact immutable UTC deadline and exits without side effects before it is due. The orchestrator also checks the deadline before every mutating operation and transitions the run to `BLOCKED` when it is due, even if scheduled cleanup has not run. The live cycle reads back bootstrap/print and runs a not-due kickstart before authentication.

Deadline, abandonment, exposure, or cohort completion blocks new work. Cleanup attempts each applicable logout once with a 60-second bound, then deletes both guests regardless. Unknown absence, logout failure, or an unconfirmed account-side revoke leaves `CLEANUP_PENDING` and terminal `BLOCKED`. Cleanup attestations are separate from, and bound to, the immutable calibration seal.

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
