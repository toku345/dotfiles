# Codex / Claude Outer Loop Private Lima Calibration — Implementation Design

Parent design: [Private Lima pre-arm calibration](codex-claude-outer-loop-private-lima-calibration.md)
Decisions: [ADR 0032](../adr/0032-private-lima-outer-loop-calibration-boundary.md), amended by [ADR 0033](../adr/0033-private-lima-runtime-main-process-egress-risk.md)
Implementation base: `0df8b37005faabff6af73ffffff62470643ae134`
Status: Implemented for static review; no live calibration has run

## Scope

This implementation adds the repository-managed calibration harness, two static Lima profiles, root-owned guest policy seeds, bounded runtime adapters, guarded sync/export code, typed evidence, retention/cleanup definitions, and hermetic tests. It does not create a VM, authenticate either runtime, register a LaunchAgent, run a live control, create v3, or authorize a real task.

The only successful calibration terminal remains:

```text
LIMA_CALIBRATION_READY_FOR_V3_DESIGN
real_task_allowed: no
```

Every other terminal is:

```text
BLOCKED
real_task_allowed: no
```

`docs/outer-loop/week0-v1/`, `docs/outer-loop/week0-v2/`, ADR 0030, ADR 0031, and existing calibration records are immutable inputs and are not part of this implementation.

## Repository boundary

```text
tools/outer-loop-lima-calibration/
|-- README.md
|-- calibrate.py
|-- versions.lock.json
|-- manifest.json
|-- lib/
|   |-- model.py
|   |-- paths.py
|   |-- identities.py
|   |-- probes.py
|   |-- sync_guard.py
|   |-- export_validator.py
|   |-- evidence.py
|   |-- retention.py
|   |-- cleanup.py
|   `-- orchestrator.py
|-- runtime/
|   |-- codex.py
|   `-- claude.py
|-- profiles/
|   |-- week0-codex.yaml
|   `-- week0-claude.yaml
|-- guest/
|   |-- provision-common.sh
|   |-- provision-codex.sh
|   |-- provision-claude.sh
|   |-- control.py
|   |-- sanitize-auth.py
|   |-- inspect-export.py
|   `-- apparmor/bwrap
|-- seeds/
|   |-- codex/config.toml
|   |-- codex/requirements.toml
|   |-- claude/managed-settings.json
|   |-- claude/managed-mcp.json
|   `-- claude/srt-settings.json
`-- fixtures/

tests/outer_loop_lima/
```

The tools directory is ignored by chezmoi deployment and is repository-only. `manifest.json` lists every file under the tools root except itself. Missing files, unlisted extra files, or digest drift block preflight. The manifest digest is recorded in the run identity instead of recursively listing the manifest inside itself.

## Component contracts

| Component | Owns | Must not do |
|---|---|---|
| Host orchestrator | Fixed phase state machine, bounded subprocesses, TTY approvals, terminal routing, final evidence | Run arbitrary C-IDs, skip phases, accept non-TTY approval, retain raw secrets |
| Lima profiles and guest provisioning | Two static YAML profiles, root provisioning, non-sudo `calibration` runtime, disabled mounts/forwarding/containerd | Render templates, contain credentials, mount authoritative repositories, install unpinned artifacts |
| Runtime adapters and seeds | Root-owned policy, guest-local authentication state, tool-free smoke, effective-policy reads | Copy host authentication, allow API-key fallback, make managed policy runtime-writable |
| Sync/export | Registered disposable staging, TTY confirmation, no-follow quarantine validation, stable inventories, canonical freeze | Sync authoritative repositories, silently follow/drop links, bundle mutable staging directly |
| Evidence/retention/cleanup | Typed records, sanitization boundary, seal, LaunchAgent definition, cleanup attestation | Aggregate risk as control, overwrite failure evidence, store raw authentication material, mutate sealed evidence |

## Identity lock

`versions.lock.json` pins or binds:

- Lima `2.1.4`, the Homebrew arm64 bottle digest, and the expected host `limactl` digest.
- Python `3.14.5` and the expected host interpreter digest.
- Ubuntu Noble arm64 image dated `20260615` and its SHA-256.
- Node `24.18.0` Linux arm64 and its official SHA-256.
- Codex `0.144.5` Linux arm64 npm artifact and registry integrity.
- Claude Code `2.1.211` and SRT `0.0.65` npm registry integrity.
- Ubuntu snapshot timestamp, signed `InRelease` and package-index digests, and exact versions/artifact hashes for AppArmor, bubblewrap, curl, libseccomp, Python, ripgrep, rsync, seccomp, socat, tar, xz, and CA certificates.
- Repository AppArmor, control helper, profiles, seeds, and sanitizer through the harness manifest.
- The host OpenRSYNC binary identity used by the initial Private Mac calibration.

An artifact with no independently checkable integrity blocks before VM creation. A changed host binary, lock, manifest, profile, package index, or repository artifact is drift; no best-effort install is allowed.

## Fixed CLI

`calibrate.py` exposes exactly these commands:

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

There is no `--yes`, arbitrary control selector, phase skip, or same-run retry. A mutating command takes one run ID and the arguments fixed for its phase. Approval requires stdin and stdout TTYs and exact re-entry of both the gate name and target digest. Human-readable prompts are not evidence; the resulting typed approval record is.

The state machine permits only the next command in sequence. A subprocess has an explicit timeout and captured output is treated as untrusted. Started occurrences are written before execution and completion records are append-only. Each started operation holds an operator-owned run lock through its terminal state update. `status` reports a lock-held occurrence as `IN_PROGRESS` without mutation; only a lock-free started occurrence is orphaned, converted to `UNVERIFIED`, and transitioned to `BLOCKED`, after which only `status`, `cleanup`, and `verify-cleanup` remain available.

## Record model

`ControlRecord`, `RiskAcceptanceRecord`, `ApprovalRecord`, and `CleanupRecord` are distinct record types. A control key is `run_id + control_id + occurrence + target`. Control results are only `PASS`, `FAIL`, `UNKNOWN`, or `UNVERIFIED`.

`UNAVAILABLE_BASELINE` is an observation classification. `NOT_PROVIDED_ACCEPTED_RISK` is a risk disposition. Neither can appear as a control result. The control aggregator rejects non-control objects and specifically cannot consume `AR-02`.

## Gates and phases

1. `init` creates a new run with an immutable RFC 3339 UTC retention deadline.
2. `preflight` validates the lock, manifest, host identity, exact objective/prohibitions, terminal states, and risk records `AR-01` and `AR-02`.
3. H1 `approve pre-vm` binds the lock digest, manifest digest, deadline, and both accepted risks.
4. `provision` registers and reads back deadline retention before creating either guest, then creates both new guests and collects guest identities. It closes the deferred C00 aggregate and C01 only when every live observation passes.
5. The operator verifies Claude subscription code-paste login can begin without port forwarding. Infeasibility blocks without relaxing the boundary.
6. H2 `approve pre-auth` binds C00, C01, and code-paste feasibility.
7. `authenticate runtime`, `run isolation`, and `run sync-export` close C02/C03 initial and the direction-specific C04-C06 records in order. Each authentication attempt is durably marked before the interactive login command so cleanup cannot omit logout/revoke handling after a later classification failure.
8. H3 `approve pre-handoff` is separate for each direction. `run handoff-forward` and `run handoff-reverse` close separate C07 records.
9. `run restart` stop/starts both guests and reruns C02/C03 with occurrence `post_restart`.
10. `prepare-seal` constructs the complete pre-approval seal-input digest.
11. H4 `approve final-seal` binds that digest. `seal` closes C08 only if all required records pass and both guests are stopped.
12. Passing guests remain stopped only until deadline/cohort/abandonment cleanup. No real-task authority is granted.

This source tree implements the state machine and command construction. Commands that would create guests, authenticate, register retention, or invoke model traffic are intentionally not executed during the implementation cycle.

## Runtime policy

### Codex

Codex uses only guest-local `CODEX_HOME` authentication and `codex login --device-auth`. `/etc/codex/config.toml` supplies system defaults and `/etc/codex/requirements.toml` supplies enforced constraints; legacy `managed_config.toml` is absent.

C00 starts app-server over stdio, performs the required initialize handshake, and calls `config/read` with `includeLayers: true` and a fixed harmless cwd plus `configRequirements/read`. Every flattened seed key must map to the expected effective value and expected system/requirements origin. Missing keys, unknown seed keys, origin drift, incompatible effective values, or cloud-composed requirements mismatches fail. A digest without key-level comparison cannot pass.

The smoke uses `codex exec --json --ephemeral` with a fixed tool-free prompt. Any command, file, Web, MCP, connector, or other tool event fails the smoke.

### Claude

Claude uses guest-local `CLAUDE_CONFIG_DIR` and a distinct root-owned managed policy. Only `claude auth login --claudeai` is allowed; Console/API billing fallback is rejected. The smoke uses `--safe-mode --tools '' --strict-mcp-config --no-chrome --disable-slash-commands --no-session-persistence --output-format stream-json`. It does not use `--mcp-config` or `--bare`.

Managed settings disable WebFetch/WebSearch, hooks, sideload flags, update paths, unsandboxed retry, and auxiliary integrations. Managed MCP is empty. Sandbox unavailability is fatal. Ubuntu's user-namespace restriction is handled only by the manifest-bound AppArmor profile for bubblewrap; no global user-namespace sysctl is changed.

Raw status, login, environment, JSONL, account identifiers, email, workspace IDs, device codes, URLs, credential bytes/hashes/sizes, and unsafe output stay in guest tmpfs. Guest sanitizers emit only allowlisted classifications and unlink their raw input.

## C03 paired probes

C03 applies only to agent-launched commands. For each runtime, occurrence, address family, protocol, and destination class, the harness creates an independent target record. This implementation schedules paired operator canaries only for host DNS/IPv4 TCP/UDP; the other fixed targets remain explicit unavailable-baseline observations and do not prove route absence or sandbox denial.

Each scheduled host path uses a 30-second one-shot listener with an operator-generated nonce. The listener binds only the dedicated non-loopback host IPv4 that the guest resolves for `host.lima.internal`; wildcard and non-literal bind addresses are rejected before socket creation. Guest root first sends the nonce outside the agent sandbox to prove the guest-to-host route. The fixed probe maps only allowlisted errors raised by the network syscall to an exact root-owned marker and exit code; unrelated stderr and all other failures remain ambiguous. The root-owned guest wrapper emits the intended destination and argv digest plus start/result classification through the exact tool output. A root-run sanitizer validates the actual runtime event and copies only that allowlisted receipt into root-only tmpfs; the runtime policy has no writable receipt path. The listener records actual ingress to an operator-only host path. The intended argv must match the runtime event argv.

PASS requires outside ingress, an inside execution receipt, exact intended/observed argv equality, expected sandbox denial, and no inside ingress. A missing item, refusal, argv mutation, omitted/other tool, ambiguous failure, false ingress, or failed guest-root baseline is `UNVERIFIED`. A target without a configured operator-authority canary is `UNAVAILABLE_BASELINE` and does not provide a route-absence or denial claim. For each occurrence, the orchestrator requires the applicable control targets and unavailable-baseline observations together to cover the fixed matrix exactly once before advancing.

Claude runs the same intended argv and destination twice: an operator-driven SRT `0.0.65` direct probe, then an actual Claude Bash-tool probe under managed settings. Stage two is load-bearing. The Claude CLI itself is not wrapped in SRT.

## Sync, export, and handoff

The immutable order is fixture to `0700` staging, baseline/sentinels, guest command, guest diagnostic, TTY Yes/No, sync-back, sentinel recheck, fresh quarantine, stable source inventory, no-follow copy/validation, canonical manifest, read-only freeze, driver stop, reviewer digest verification.

The sync guard rejects non-TTY stdin/stdout, `-y`, `--yes`, `--tty=false`, symlink ancestors, mount transitions, unregistered roots, path escape, and any authoritative repository before invoking Lima. The canonical containment check independently rejects a staging component swapped to an outside symlink after the ancestor scan. After validation, the guard opens the staging directory with no-follow semantics, verifies its inode, runs Lima from that pinned directory descriptor with `--sync=.`, and verifies the pathname still names the pinned inode after completion. Quarantine treats a symlink as a node to reject: it neither dereferences nor silently drops it. Regular files use no-follow open, fstat/hash/fstat, and two stable inventories. Hard links, special nodes, unsafe modes, path changes, secret-shaped names/content, races, or silent drops fail C06.

C04-C06 run the fixed sync, diagnostic, quarantine, and freeze sequence once with Codex as the forward driver and once with Claude as the reverse driver. C07 forward and reverse consume their corresponding separate bundle manifests and records. The reviewer verifies every logical name and digest only after the driver stop identity matches. Mutable staging is never a handoff input.

## Retention and cleanup

The frozen harness generates a LaunchAgent plist with `RunAtLoad: true`, deadline `StartCalendarInterval`, and `StartInterval: 3600`. The cleanup script independently parses the immutable deadline and exits without side effects before it is due. The orchestrator separately rejects and blocks every mutating operation whose start time is at or after the deadline, leaving only status and cleanup routes. A later live run must read back `launchctl bootstrap`, `launchctl print`, and a not-due kickstart before C02.

Deadline, abandonment, exposure, or cohort completion immediately blocks new runtime work. Cleanup acquires the same run lock used by phases and reloads state after any current phase completes; only an active marker that remains while cleanup owns the lock is classified as orphaned. It then tries each logout once with a 60-second timeout and removes both guest instances/disks regardless. Logout failure or exposure sets `account_revoke_required: true`. Cleanup is not verified until any provider-side revoke requirement is human-dispositioned.

Verification reads back absence of instances, disks, staging, quarantine, raw tmp, listeners, LaunchAgent job, and plist. Unknown or present state yields `CLEANUP_PENDING` and calibration `BLOCKED`. Cleanup evidence is a separate attestation bound to the sealed digest; it never changes sealed evidence.

## Static verification

CI and local verification run Python `unittest` on Python `3.14.5`, ShellCheck on guest shell, and `limactl validate --tty=false` for both profiles on macOS. CI never starts a VM. Tests cover C00-C08 model contracts, lock/manifest drift, risk/control separation, crash recovery, sync/export negative shapes, retention catch-up, cleanup uncertainty, sanitizer leakage, and the immutable historical paths.

Passing static checks proves only that the reviewed harness satisfies its hermetic contracts. It does not report any live C00-C08 result and cannot produce `LIMA_CALIBRATION_READY_FOR_V3_DESIGN`.
