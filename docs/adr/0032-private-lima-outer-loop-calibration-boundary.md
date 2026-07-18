# ADR 0032: Calibrate the Private Outer Loop with Separate Lima Guests

## Status

Accepted

Amended by [ADR 0033](0033-private-lima-runtime-main-process-egress-risk.md), which accepts unenforced runtime main-process egress as `AR-02` and limits `C03` to agent-launched commands. The original decision history below is retained.

## Context

[ADR 0030](0030-codex-claude-outer-loop-pilot.md) selected a zero-build four-task pilot split between Private Codex and Work Claude Code. The `outer-loop-week0/v1` Private Codex calibration stopped safely before any real task when a stock path sandbox disclosed a harmless outside-root sentinel through a pre-existing hard-link alias in an approved root.

[ADR 0031](0031-outer-loop-week0-v2-hard-link-boundary.md) amended the boundary for `outer-loop-week0/v2` while preserving zero-build. V2 made an operator collector, all-role hard-link creation denial, and execution-group quiescence load-bearing. Pre-seal feasibility could not demonstrate those controls reliably, and the resulting manual mechanism no longer served the original purpose of starting small to test whether the outer-loop idea is useful.

The user has separate Codex and Claude Code subscription environments available on a Private Mac and accepts a narrower residual risk for non-sensitive tasks. Work Mac support and stronger general-purpose isolation can wait. Continuing to optimize the shared-user macOS sandbox or weakening v1/v2 in place would preserve the wrong constraint; the pilot needs a successor boundary and new calibration history.

## Decision

### Stop pursuing zero-build v2 as the next pilot path

Retain ADR 0031 as the accepted historical decision for `outer-loop-week0/v2`, but supersede zero-build v2 as the selected path for future pilot execution. No formal v2 calibration observation was recorded before this decision, so add fail-closed supersession notices to ADR 0030, ADR 0031, the v2 design, and every v2 package entry point as the final pre-observation covered-content correction permitted by the v2 policy; regenerate every manifest record and the aggregate package digest. After that correction, keep `docs/outer-loop/week0-v1/`, the corrected `docs/outer-loop/week0-v2/`, the status-marked ADR 0031, and all existing calibration observations immutable. Never pool their results with the successor.

Permit a small repository-managed calibration harness, reviewed Lima profiles, non-secret runtime seed configurations, a sync guard, an export validator, and a secret-free evidence recorder. Do not create these components in this ADR cycle; define them in the subsequent implementation plan.

### Calibrate two separate persistent Lima guests on the Private Mac

Create one Codex guest and one Claude Code guest under a dedicated private `LIMA_HOME`. Each guest has an independent VM disk and guest home. Disable host filesystem mounts, containerd, dynamic port forwarding, and SSH-agent forwarding with explicit settings supported by the pinned Lima release, then verify both the stored effective configuration and live guest mount table.

Separate the trusted guest provisioning account from a dedicated non-sudo runtime account. Run Codex or Claude Code, its tools, and repository commands only as the runtime account. Keep the harness, managed policy, sandbox configuration, runtime binary, and trusted seed root-owned and non-writable by that account. Prove with harmless controls that the runtime cannot use `sudo` or `su`, join a privileged group, modify trusted components, or reach the operator control channel. Block if writable authentication state cannot coexist with an immutable managed-policy layer.

Never mount or copy host `~/.codex`, `~/.claude`, keychain material, API keys, access tokens, SSH credentials, cloud credentials, agent sockets, or an authoritative repository. Authenticate independently inside each guest and retain subscription credentials only on that guest disk. Evidence may record only sanitized authentication classification, status, ownership, mode, link count, version, configuration identity, and a fixed tool-free smoke result; it may not retain credential bytes, hashes, sizes, account identifiers, login codes or URLs, raw environments, or unsafe raw output.

Keep the calibrated guests stopped but intact between calibration and the first cohort so that a later package can bind to the same VM, disk, runtime, managed-policy, authentication-method classification, and smoke result. Credential bytes remain opaque and have no recorded identity. Treat any relogin, credential replacement, or authentication-method change as operator-declared drift that reruns the authentication control. Record a human-approved retention deadline. On abandonment, deadline expiry, credential exposure, or cohort completion, logout, revoke when applicable, delete both instances and disks, and verify their absence.

### Use zero-by-default egress for agent-launched commands

Do not claim that the guest is network-disconnected: trusted provisioning and the CLI process require network access. Bind the exact runtime-specific child-command sandbox and root-owned effective policy. Allow each CLI process to reach only the endpoints needed for its own subscription login and model calls. Deny external, host, private, and peer-guest network access to commands, scripts, and subprocesses launched by the agent. Disable Web search, WebFetch, apps, connectors, MCP, and unsandboxed command escape paths. Inventory and digest-bind any runtime-internal loopback listener or Unix socket required by the calibrated sandbox or CLI; agent commands may not use undeclared local IPC or use declared IPC to reach a denied destination.

For every available DNS, IPv4, IPv6, TCP, and UDP path, first prove a controlled destination is reachable in an operator-owned control outside the agent command sandbox, then require the corresponding inside-sandbox probe to fail. Record an unavailable protocol as unavailable baseline rather than a passing denial. Cover public, private, peer-guest, host-gateway, `host.lima.internal`, and every runtime proxy or socket that could bridge the sandbox. A model smoke proves only the CLI path and never substitutes for these paired controls.

If a later task requires external access, stop the action and obtain a human decision over the exact destination, operation, purpose, duration, and alternatives. An approval changes the network-policy identity and requires affected controls and handoffs to be recalibrated; no runtime may widen the boundary itself.

### Transfer only through disposable staging and operator-frozen bundles

Never point Lima `shell --sync` at an authoritative repository. Copy an immutable harmless fixture or later sanitized task input into operator-only `0700` disposable host staging first. Resolve and reject symlinked or unexpected staging ancestors, mounts, and path escapes. Require an actual interactive TTY, reject `-y`, `--tty=false`, non-TTY invocation, and unregistered roots before invoking Lima.

Treat `--sync` as a trusted host-write boundary because Lima invokes rsync with deletion semantics before host-quarantine validation. Pin and digest both host and guest rsync implementations. Calibrate explicit `No`, nonzero-command, explicit `Yes`, and non-TTY-denial outcomes plus deletion, rename, absolute and relative symlink, symlinked-directory and staging-ancestor, hard-link, and path-escape fixtures. Controlled sentinels outside staging and in the immutable fixture must remain exact; functional round-trip success alone does not pass.

Use guest-source inspection to diagnose static inventory, node, link, symlink, path, and secret-shaped fixtures, but do not treat it as a concurrency or confidentiality guarantee because an agent process can race it and rsync can normalize source metadata. Independently validate the exact returned host-quarantine bytes as the load-bearing freeze input. Treat credential detection or an unsanitizable result as a boundary failure, destroy the export, and revoke and destroy the affected guest. Do not claim that these checks prove complete isolation of a runtime from its own credential or recover normalized source metadata.

Freeze accepted quarantine bytes under a canonical logical-name manifest and digest, then stop the driver guest and record its stopped identity before transfer. The reviewer guest recomputes every input and bundle digest before the runtime receives the content. Guests share no filesystem, SQLite database, direct network channel, or `agmsg` transport. Calibrate both Codex-driver to Claude-reviewer and Claude-driver to Codex-reviewer directions; restarting a stopped guest for the reverse direction or reviewer role requires its sealed identity check before use.

### Replace v2 hard-link and quiescence gates with the VM and frozen-export boundary

Do not require all-role hard-link creation denial or exhaustive execution-group quiescence inside a guest. Instead, remove host mounts, export into operator-owned host quarantine, freeze exact accepted bytes, stop the driver guest, and give every later stage only the frozen bundle. A continuing guest process cannot mutate those host bytes. Hard links, symlinks, special nodes, unexpected paths, and secret-shaped content remain export hazards and fail the export gate, but the design makes no broader guest-local alias-prevention claim.

Accept that a runtime may read its own guest-local subscription credential. Bound that risk with non-sensitive tasks, zero command egress, no auxiliary credentials or tools, export quarantine, human review, a retention deadline, and final logout, revocation, and guest destruction.

### Fail closed before any real task

Run controls for pinned host and tool identity, VM and runtime-account privilege separation, guest-local authentication, paired outside/inside-sandbox egress denial, guarded sync, pinned-rsync sync and escape semantics, export quarantine, both frozen-handoff directions, restart persistence, and final sealing. After each restart, re-derive the runtime-specific effective sandbox and network-policy identities and rerun every applicable paired egress and local IPC control before sealing; pre-restart evidence and a model smoke never substitute for these live controls. Every applicable control must be `PASS`; `FAIL`, `UNKNOWN`, `UNVERIFIED`, missing evidence, sanitizer failure, contradiction, or drift blocks the complete run. Do not infer a pass from an exit code, retry automatically, overwrite a failed run, or pool results across run IDs.

The only passing terminal state is `LIMA_CALIBRATION_READY_FOR_V3_DESIGN` with `real_task_allowed: no`. Every failure ends `BLOCKED` with `real_task_allowed: no`. Remediation requires human approval and a new calibration run ID. Because no real-task authority exists, calibration failures are not relabeled `PAUSED_HARD`.

### Defer the successor package and use a Private-only first cohort

Do not create or execute `outer-loop-week0/v3` until this calibration passes. A later v3 design must create a new self-contained schema/package, bind to the sealed Lima identities, rehearse its controls, and prohibit pooling with v1, v2, or pre-arm calibration results.

Amend ADR 0030's environment allocation for the first successor cohort: use four non-sensitive Private tasks, two driven by Codex and two driven by Claude Code, in recorded arrival order. Use the opposite runtime as the fresh independent reviewer for each task. Preserve frozen contracts, fresh implementation context, blind-first independent review, CP1 and CP2, human disposition, `UNVERIFIED` not passing, operator-owned evidence, no delivery inside the run, and immutable failure history unless the later v3 design explicitly revises them.

Defer Work Mac support, Work information transfer, Work/Private aggregation, and any cross-environment readiness claim to a later design and calibration.

## Consequences

### Positive

- Host filesystem aliasing and cross-runtime credential sharing leave the normal execution path structurally instead of depending on unavailable stock sandbox semantics.
- The pilot can test both runtimes and cross-review entirely on the Private Mac before investing in Work support or a reusable outer-loop Skill.
- A small tested harness can replace thousands of lines of fragile zero-build manual procedure.
- Frozen operator-mediated handoffs preserve independent review without a shared database or live messaging channel.
- V1 and v2 remain truthful, immutable evidence of what failed and why the successor exists.

### Negative

- The user must maintain two VMs, authenticate twice, inspect exports, and accept deliberately constrained offline-capable tasks.
- Guest-local credentials and task residue persist until the first cohort completes, abandonment, or the retention deadline.
- Runtime, Lima, template, network-policy, harness, validator, or sanitizer drift can force expensive recalibration.
- Work Mac validation and cross-environment comparison are delayed.

### Risks

| Risk | Mitigation |
|---|---|
| Runtime accesses its own guest credential | Explicit accepted risk; non-sensitive tasks; zero command egress; export quarantine; logout/revoke and destruction |
| Non-TTY Lima sync writes back without confirmation | Disposable staging only; actual-TTY guard; reject `-y` and `--tty=false`; negative control |
| Guest continues mutating after driver completion | Freeze exact host bytes, stop the guest, and use only the frozen bundle downstream |
| Export copies hidden credential-like material | Guest and host validation, secret-shaped negative fixtures, human review, immediate revoke/destruction on detection, no claim of perfect prevention |
| Offline-only eligibility excludes useful tasks | Accept reduced comfort for the first cohort; add exact egress only by human decision and recalibration |
| Private success is generalized to Work | Work explicitly remains out of scope and requires its own decision, calibration, and evidence |

## References

- [Private Lima pre-arm calibration design](../design/codex-claude-outer-loop-private-lima-calibration.md)
- [ADR 0030: Pilot a Shared Outer Loop for Codex and Claude Code](0030-codex-claude-outer-loop-pilot.md)
- [ADR 0031: Amend the Week 0 Hard-Link Boundary with Integrity Gates](0031-outer-loop-week0-v2-hard-link-boundary.md)
