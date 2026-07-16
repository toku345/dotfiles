# Codex / Claude Outer Loop Private Lima Pre-Arm Calibration — Design Doc

Parent decisions: [ADR 0030](../adr/0030-codex-claude-outer-loop-pilot.md), [ADR 0031](../adr/0031-outer-loop-week0-v2-hard-link-boundary.md)
Target decision: [ADR 0032](../adr/0032-private-lima-outer-loop-calibration-boundary.md)
Status: Accepted

## Context

The `outer-loop-week0/v1` Private Codex calibration stopped before any real task after a harmless control proved that the observed stock path sandbox denied a direct outside-root read but disclosed the same bytes through a pre-existing hard-link alias in an approved root. ADR 0031 and `outer-loop-week0/v2` attempted to preserve a Markdown-only, zero-build pilot by adding an operator collector, all-role hard-link creation denial, and execution-group quiescence. Pre-seal feasibility could not demonstrate those load-bearing controls, and the resulting mechanism was too complex to remain a useful small pilot.

The pilot has therefore learned that preserving zero-build is more costly than the original Week 0 hypothesis warrants. The next step is not to weaken v1 or v2 in place. It is to calibrate a successor boundary on a Private Mac using separate Lima Linux guests for Codex and Claude Code, then design a new self-contained schema/package only if that environment calibration passes.

The first successor cohort will also be Private-only. It will eventually contain two non-sensitive Codex-driven tasks and two non-sensitive Claude-driven tasks, with the opposite runtime acting as the fresh independent reviewer. Work Mac support, Work-derived aggregation, and cross-environment transfer are deferred to a later decision.

The user accepts that a runtime may be able to read its own guest-local subscription credential. That risk is accepted only for non-sensitive tasks, zero-by-default egress from agent-launched commands, guest-local credentials, reviewed export, and logout plus guest destruction after the cohort or abandonment.

## Scope and sequencing

This design covers only a pre-arm calibration of the Private Mac Lima boundary. It does not create a successor Week 0 package, enroll a task, execute a real task, or authorize a cohort.

The work is intentionally split into three design and execution cycles:

1. Design, implement, and run this Lima pre-arm calibration.
2. If calibration passes, design and implement a new `outer-loop-week0/v3` package bound to the sealed environment.
3. If the v3 package rehearsal and runtime calibration pass without drift, run the Private-only four-task cohort.

Passing this calibration ends only as:

```text
LIMA_CALIBRATION_READY_FOR_V3_DESIGN
real_task_allowed: no
```

Any other terminal result is:

```text
BLOCKED
real_task_allowed: no
```

## Goals

- Prove that Codex and Claude Code run in distinct Lima VMs with independent disks and no host filesystem mount, SSH-agent forwarding, shared runtime state, or direct guest-to-guest transport.
- Establish guest-local subscription authentication without copying or mounting host `~/.codex`, `~/.claude`, keychain material, API keys, access tokens, or agent sockets.
- Allow only each CLI's own authentication and model-provider traffic while denying external, host, private, and peer-guest network access from agent-launched commands and disabling Web, app, connector, MCP, and unsandboxed escape paths.
- Prove a guarded, disposable staging workflow in which no Lima sync operation targets an authoritative repository.
- Freeze and digest exact exported bytes before transferring them through the operator to the other guest.
- Calibrate both Codex-driver to Claude-reviewer and Claude-driver to Codex-reviewer handoffs.
- Preserve immutable failure evidence and fail closed on missing, ambiguous, or unsanitizable observations.

## Non-goals

- Running a real task or creating `outer-loop-week0/v3` in this design cycle.
- Modifying `docs/outer-loop/week0-v1/`, `docs/outer-loop/week0-v2/`, ADR 0031, or any existing calibration record.
- Pooling v1, v2, or pre-arm observations with a future v3 cohort.
- Supporting Work Mac tasks, Work-to-Private summaries, or cross-environment comparison.
- Providing direct Codex-to-Claude live messaging, shared `agmsg` storage, or a network relay between guests.
- Proving that a runtime cannot read its own guest-local credential.
- Protecting against compromise of the operator, macOS host, hypervisor, kernel, filesystem implementation, model provider, or subscription account.
- Allowing tasks that require downloads, arbitrary Web access, MCP, browser automation, cloud credentials, SSH credentials, or other external-state access in the first cohort.
- Reproducing v2's all-descendant hard-link creation denial or exhaustive execution-group quiescence proof inside a guest.

## Considered approaches

| Approach | Trade-off | Decision |
|---|---|---|
| Keep one persistent Codex guest and one persistent Claude guest through calibration and the first cohort | Preserves credential and disk separation while avoiding repeated login; environment drift must be checked before every later phase | Adopt |
| Create a fresh guest for every role or task | Strongest residue isolation, but requires repeated authentication and calibration and obscures the small-pilot hypothesis under infrastructure burden | Defer |
| Place both runtimes in one guest, optionally under separate Linux users | Simplifies shared `agmsg` and workspace access but weakens credential separation and fresh-review independence | Reject for this cohort |

## Architecture and trust boundary

```text
Private Mac
|
|-- authoritative repository
|     `-- never mounted or passed directly to Lima --sync
|
|-- operator-owned state (0700)
|     |-- calibration evidence
|     |-- immutable fixture
|     |-- disposable input staging
|     |-- export quarantine
|     `-- frozen handoff bundles
|
|-- dedicated LIMA_HOME (0700)
|     |-- week0-codex
|     |     |-- independent VM disk
|     |     |-- no host mounts or SSH-agent forwarding
|     |     `-- guest-local CODEX_HOME
|     `-- week0-claude
|           |-- independent VM disk
|           |-- no host mounts or SSH-agent forwarding
|           `-- guest-local CLAUDE_CONFIG_DIR
|
`-- operator
      `-- sole mover of staged input, quarantined export, and frozen bundles
```

The macOS operator, pinned Lima binary and template, pinned host and guest rsync implementations, VM boundary, guest kernel, runtime sandboxes, root-owned guest policy, calibration harness, export validator, evidence sanitizer, and digest implementation are trusted for this pilot. Agents and repository content are untrusted. The guests do not trust each other and share no writable storage.

The dedicated `LIMA_HOME` prevents unrelated instances or inherited local state from entering the calibration identity. Each guest is created with explicit plain, no-mount, and no-containerd settings supported by the selected pinned Lima release. The stored effective configuration and the guest mount table must independently prove that the host home and repository are not mounted. Dynamic port forwarding and SSH-agent forwarding are disabled; the operator's loopback-only Lima management channel is not exposed as an agent tool.

Each guest separates the trusted provisioning/operator account from a dedicated non-sudo runtime account. Codex or Claude Code, its tools, and repository commands run only as the runtime account. The runtime account owns its workspace and necessary authentication state but cannot use `sudo` or `su`, join privileged groups, modify the root-owned harness, managed policy, sandbox configuration, runtime binary, or trusted seed, or reach the operator control channel. Calibration proves both denied mutation and denied privilege escalation with harmless controls. If a runtime cannot keep its authentication state writable while enforcing an immutable managed policy layer, that runtime blocks rather than falling back to a writable policy.

The currently observed Homebrew installation is Lima `2.1.4`, and its `limactl` supports `--plain`, `--mount-none`, `--containerd=none`, and `shell --sync`. The calibration records the actual version, resolved binary digest, template digest, and effective configuration at run time instead of treating that observation as timeless. Any mismatch is drift.

## Component boundaries for later implementation

The zero-build constraint is removed for this successor. A small repository-managed calibration harness is allowed, but it must remain decomposed into reviewable units:

1. **Host orchestrator** — creates run state, invokes bounded phases, owns terminal routing, and is the only component allowed to write final evidence.
2. **Lima profiles/templates** — define the two guests, trusted provisioning account, non-sudo runtime account, and their mount, containerd, forwarding, provisioning, resource, and disk settings without containing credentials.
3. **Runtime seed configurations** — provide reviewed root-owned non-secret Codex and Claude managed policy; runtime-writable authentication state remains guest-local and untracked.
4. **Sync guard and export validator** — require an interactive TTY, reject `-y` and `--tty=false`, restrict sync roots to canonical disposable staging with non-symlink ancestors, validate guest-source diagnostics and load-bearing host-quarantine inventories, and freeze accepted bytes.
5. **Evidence recorder and sanitizer** — emit canonical, secret-free control records and summaries while keeping raw sensitive output guest-local and ephemeral.

No component is a daemon, host network service, guest-to-guest broker, general-purpose remote executor, or `agmsg` replacement. The later implementation plan assigns concrete file paths and focused tests to these units.

## Authentication and guest-local state

Codex uses a dedicated guest-local `CODEX_HOME`; Claude uses a dedicated guest-local `CLAUDE_CONFIG_DIR`. Neither path may be a symlink, bind mount, host mount, shared disk, or copied host directory. Directory ownership and mode must be correct before login.

Codex authenticates inside its guest with ChatGPT device authentication. Claude authenticates inside its guest with its subscription OAuth flow and a browser code handoff when required. Copying host credential files, injecting a host API key or access token, silently falling back to API billing, or synchronizing host runtime state is prohibited.

Authentication evidence is deliberately non-sensitive: CLI version and binary digest, configuration digest, credential node type and ownership, directory/file modes, `st_nlink == 1`, an allowlisted authentication-method classification, login-status exit code, and a fixed tool-free smoke result. It never retains credential bytes, credential hashes or sizes, account email, workspace ID, device code, login URL, raw status output, raw environment output, or raw JSONL that may contain identity data.

The same guests are stopped and retained after a passing calibration so that a later v3 package can bind to the calibrated VM, disk, runtime, managed-policy, authentication-method classification, and smoke result. Credential bytes remain opaque and have no recorded identity. A human-approved retention deadline is recorded before login. Any relogin, credential replacement, or authentication-method change is operator-declared drift and reruns `C02`. Abandonment, deadline expiry, credential exposure, or cohort completion requires logout, account-side revocation when applicable, instance deletion, disk deletion, and verified absence from the dedicated `LIMA_HOME`.

## Network boundary

The guest is not claimed to be network-disconnected: trusted provisioning and the CLI process require network access. The calibrated enforcement layer is each runtime's child-command sandbox and root-owned effective policy. The runtime process may reach only the endpoints needed for its own subscription login and model calls. Commands, scripts, and subprocesses launched by the agent receive zero external, host, private, and peer-guest network egress by default. Codex command networking and Web search are disabled. Claude's Linux sandbox is required to start fail-closed; its unsandboxed-command escape is disabled. WebFetch, WebSearch, apps, connectors, MCP, inherited cloud credentials, and SSH credentials are unavailable to both roles.

Runtime-internal loopback listeners and Unix sockets required by the calibrated sandbox or CLI may exist, but their exact purpose and identity must be inventoried and digest-bound. Agent commands may not use undeclared local IPC or use declared IPC to reach the host, peer guest, or an external destination. The exact runtime-specific effective policy and enforcement configuration are digested. For each available DNS, IPv4, IPv6, TCP, and UDP path, an operator-owned control outside the agent command sandbox first proves a controlled destination is reachable, then the corresponding agent-command probe must fail inside the sandbox. An unavailable protocol is recorded as unavailable baseline, not counted as a passing denial. The matrix also covers host gateway, peer guest, public and private destinations, and every runtime proxy or socket that could bridge the sandbox. A fixed tool-free model smoke proves only the CLI path. A failed command is not accepted without the reachable outside-sandbox control and evidence that the intended boundary denied the inside-sandbox probe.

If a later candidate genuinely requires external access, the current action stops. The human must review the exact destination, operation, purpose, duration, and alternatives. A denial makes the candidate ineligible or blocked under the later v3 rules. An approval changes the network-policy and configuration digests and requires the affected positive and negative controls plus both relevant handoff roles to be recalibrated. No prompt or runtime may widen the allowlist itself.

## Staging, sync, export, and handoff

Lima `shell --sync` never points at an authoritative repository. The operator first copies an immutable harmless fixture into a disposable host staging directory owned only by the operator with mode `0700`. The guard resolves and records the staging root and every ancestor with no symlink, unexpected mount, or path escape before use. The driver guest receives only that staging copy.

The selected Lima implementation automatically synchronizes changes back when `--sync` runs without a TTY; `-y` is an alias for `--tty=false`. The host sync guard must therefore prove that stdout is an actual TTY, reject `-y` and `--tty=false`, and refuse any root outside the registered disposable staging tree before invoking Lima. `--sync` is itself a trusted host-write boundary because Lima invokes rsync with deletion semantics before host-quarantine validation. Both host and guest rsync binaries, capabilities, and digests are therefore calibration identities rather than incidental dependencies.

Calibration exercises four sync outcomes independently: an explicit `No` leaves host staging unchanged; a nonzero guest command leaves host staging unchanged and retains the guest copy for operator disposition; an explicit `Yes` changes only disposable staging; and a non-TTY attempt is rejected by the guard before Lima starts. Separate malicious-shape fixtures exercise absolute and relative symlinks, symlinked directories and staging ancestors, deletion, rename, hard links, and path-escape attempts while controlled sentinels immediately outside staging and in the immutable fixture remain byte-identical. Functional round-trip success without those escape controls does not qualify either rsync implementation. Any authoritative repository remains unchanged in every case.

After a positive driver run, operator-controlled guest-side inspection records the source inventory and detects static undeclared roots, links, special nodes, and secret-shaped fixtures before sync-back. This guest-side inspection is diagnostic rather than a concurrency or confidentiality guarantee: an agent process may race it, and rsync may normalize hard-link metadata. Returned bytes enter host export quarantine, whose independent validator is load-bearing for the exact bytes eligible to freeze and checks inventory, type, mode, link, symlink, path, and secret patterns. The design does not claim that either inspection proves absolute credential non-disclosure or recovers normalized source metadata. Any detected credential-like material causes export destruction, logout/revocation, and guest destruction.

Passing export bytes are serialized into a canonical logical-name inventory and manifest, digested, and frozen read-only. The operator then stops the driver guest and records that stopped identity before copying the bundle to the reviewer guest. The reviewer-side preflight recomputes every input digest and the bundle digest before the runtime sees the content. The reviewer receives no live driver channel, shared database, or mutable driver workspace.

The complete flow runs in both directions:

```text
Codex driver  -> operator-frozen bundle -> Claude reviewer
Claude driver -> operator-frozen bundle -> Codex reviewer
```

## Replacement of v2 load-bearing controls

This boundary does not attempt to prove all-role hard-link creation denial or exhaustive execution-group quiescence inside a guest. Those requirements made v2 infeasible and are not necessary to protect an unmounted host filesystem.

Instead, the driver exports into host quarantine with no shared filesystem, the operator freezes exact accepted bytes, and the guest is stopped before any later stage uses the bundle. A background or escaped guest process cannot mutate the already frozen host bundle. The reviewer and any later importer consume only those frozen bytes. Changes remaining in the stopped guest are irrelevant to that handoff and are never merged directly.

Observed hard links, symlinks, special nodes, unexpected paths, and secret-shaped content remain export hazards and are rejected before a bundle can freeze. Static guest-source fixtures must be detected, but only the exact returned host bytes are load-bearing after copy, and normalized source metadata may be unrecoverable. This is export hygiene, not a claim that the runtime sandbox prevents every guest-local alias operation. The accepted residual risk remains explicit: the runtime may access its own guest credential, and detection cannot prove that such bytes were never transiently copied. Non-sensitive tasks, command-egress denial, quarantine, human review, and final credential destruction bound that risk.

## Calibration lifecycle

```text
host preflight
      |
      v
two-guest provisioning
      |
      v
guest-local authentication
      |
      v
isolation and egress controls
      |
      v
Codex -> Claude frozen handoff
      |
      v
Claude -> Codex frozen handoff
      |
      v
stop/start persistence check
      |
      v
evidence seal and guest stop
```

### Host preflight

Record the Private Mac OS and architecture; Lima, template, VM driver, rsync, runtime, sandbox dependency, harness, validator, and sanitizer identities; the accepted risks; the retention deadline; the exact objective and prohibitions; and the two allowed terminal states. Verify a private operator state root and dedicated `LIMA_HOME`. No real repository or task is present.

The currently observed macOS `rsync` identifies itself as OpenRSYNC with rsync `2.6.9` compatibility. It is neither accepted nor rejected by version string alone. The disposable sync controls determine compatibility. If they fail for a proved rsync reason, installing and pinning GNU rsync requires a human decision and a new calibration run.

### Trusted provisioning

Create empty guests before target code or credentials exist. Install and pin required guest packages, host and guest rsync implementations, runtime CLIs, Linux sandbox dependencies, root-owned managed policy, and reviewed seed configuration under operator authority. Create a dedicated non-sudo runtime account and prove that it cannot modify trusted components or enter the provisioning account. Disable runtime auto-update before authentication and capture all non-secret identities. Provisioning network access ends before any agent-controlled command runs.

### Authentication and isolation

Authenticate inside each guest, reduce raw results to sanitized classifications, and run tool-free model smokes. Verify effective Lima configuration, guest mount tables, host sentinel unreadability, cross-guest marker unreadability, absence of inherited secret variables and sockets, agent-command egress denial, and disabled auxiliary tools.

### Bidirectional handoff

Run the guarded sync, export-quarantine, manifest freeze, driver-guest stop, reviewer-side digest verification, and fixed reviewer response in each direction. Each direction has its own control records and bundle identity; a pass in one direction never substitutes for the other. Restarting a previously stopped guest for the reverse direction or reviewer role requires its sealed identity check before use.

### Persistence and seal

Stop and start each guest, then recheck VM/disk identity, Lima configuration, runtime and seed digests, authentication persistence, and the same tool-free smoke. Seal the complete evidence, stop both guests, and record their stopped identity plus the retention deadline. A passing seal still has `real_task_allowed: no`.

## Control matrix

| ID | Control | Passing evidence |
|---|---|---|
| `C00` | Host identity | Pinned Lima, binary, template, driver, host/guest rsync, runtime, harness, configuration, and sanitizer identities recorded without drift |
| `C01` | VM and privilege separation | Distinct VM/disk identities; no host mount, agent forwarding, shared state, cross-guest marker, or guest-to-guest transport; runtime account has no sudo, privileged group, trusted-policy write, or operator-channel access |
| `C02` | Guest-local authentication | Correct guest-local roots and credential metadata; intended subscription method; fixed tool-free smoke before and after restart |
| `C03` | Egress denial | Runtime-specific policy is digest-bound; each available DNS/IP/protocol path is reachable in its outside-sandbox control and denied inside; required local IPC is inventoried and cannot bridge to a denied destination |
| `C04` | Sync guard | Actual TTY required; `-y`, `--tty=false`, non-TTY, non-canonical or symlink-ancestor staging, unregistered root, and authoritative-repository target rejected before Lima invocation |
| `C05` | Sync semantics | Pinned rsync implementations pass `No`, nonzero-command, and `Yes` cases plus deletion, rename, symlink, hard-link, and outside-sentinel escape controls; immutable fixture remains exact |
| `C06` | Export quarantine | Positive fixture passes; static guest-source hazards are diagnosed; only independently validated exact host-quarantine bytes freeze; detected node/path/secret hazards fail |
| `C07` | Frozen handoff | In each direction the bundle freezes, the driver guest is proved stopped, and only then the reviewer recomputes every logical input and bundle digest and uses the frozen bytes |
| `C08` | Restart and seal | Stop/start preserves the sealed identities and authentication smoke; both guests end stopped; human approval and evidence digest recorded |

Every applicable control must be `PASS`. `FAIL`, `UNKNOWN`, `UNVERIFIED`, missing evidence, sanitizer failure, or contradictory evidence blocks the complete run. There is no partial pass and no automatic retry.

## Evidence contract

Evidence remains outside repositories and synchronized directories under an operator-owned `0700` root:

```text
<operator-state>/calibration/<run-id>/
|-- identity.json
|-- controls.jsonl
|-- summary.md
`-- fixture-bundles/
```

Files use mode `0600`. Each control record binds the run ID, control ID, target runtime/direction, expected classification, observed sanitized classification, exit code where non-sensitive, evidence digest, result, and responsible operator step. The final summary binds every control result, the overall terminal state, the human approval, and the sealed identity digest.

Raw login, environment, runtime JSONL, or command output that may contain identity or credential material remains in guest tmpfs only long enough to derive the allowed classification, then is destroyed. If sanitization cannot be proved, no raw material crosses and the control fails. Failure records are immutable; remediation starts a new run ID and never overwrites or pools the old result.

## Fail-closed routing

```text
CALIBRATION_RUNNING
        |
        +---- all controls pass ----> LIMA_CALIBRATION_READY_FOR_V3_DESIGN
        |
        `---- any other result -----> BLOCKED
                                         |
                                         `-- human-approved remediation
                                                |
                                                `--> new run ID
```

Setup infeasibility, authentication failure, unexpected mount or socket, cross-guest visibility, undeclared egress, unsafe sync behavior, export hazard, digest mismatch, missing or unsafe evidence, and drift all block the run. Isolation, egress, or transfer-boundary failures stop both guests and invalidate every derived output. Suspected credential exposure additionally requires export destruction, logout, account-side revocation where possible, and guest destruction.

This is pre-arm calibration, so failures are recorded as `BLOCKED`, not `PAUSED_HARD`. A future v3 cohort may define `PAUSED_HARD` for a failure after real-task authority begins, but calibration never invents that state.

## Drift and recalibration

The seal binds the Lima binary and template, effective guest configuration, VM/disk identities, base image, operator/runtime privilege boundary, host and guest rsync binaries, runtime binaries, authentication method classification, seed and managed-policy configuration, sandbox and network policy, sync guard, export validator, evidence sanitizer, and both handoff directions. Credential bytes remain intentionally unbound; relogin or replacement is declared drift.

- Lima, template, VM driver, base image, mount/forwarding policy, sync guard, export validator, or evidence sanitizer drift invalidates the entire seal and requires both-runtime full recalibration.
- A runtime binary, model, authentication classification, runtime seed, or sandbox/network policy change requires the affected runtime controls and both handoff roles involving that runtime to be recalibrated.
- An approved egress exception changes the network-policy digest and requires affected positive/negative controls and handoffs to rerun before use.
- Missing provenance or inability to determine the affected scope defaults to full recalibration.

## Pass gate and successor relationship

The calibration passes only when every control is `PASS`, both handoff directions pass, no sanitizer failure occurred, the stopped guest identities match the sealed records, and the human records approval over the final evidence digest.

A pass authorizes only design of a new v3 package. That package must be self-contained, receive a new schema and package digest, bind its runtime invocation and controls to the sealed Lima identity, and undergo its own rehearsal before any real task. It must not pool v1, v2, or pre-arm calibration outcomes into cohort results.

The intended first v3 cohort is four non-sensitive Private tasks in arrival order: two Codex-driven and two Claude-driven, with the opposite runtime as fresh reviewer. Frozen contract, fresh implementation context, blind-first independent review, CP1 and CP2, human disposition, `UNVERIFIED` not passing, operator-owned evidence, no delivery inside the run, and immutable failure history remain requirements inherited from ADR 0030 unless the later v3 design explicitly revises them.

Work Mac support and any Work/Private comparison require a later design, calibration, and explicit information-boundary decision. A successful Private cohort makes no claim about Work suitability.

## Consequences

### Positive

- The experiment can finally test the outer-loop hypothesis without requiring the host runtimes to prove an unenforceable shared-user filesystem boundary.
- Separate guests structurally remove host filesystem hard-link aliasing and cross-runtime credential sharing from the normal path.
- The two-runtime comparison and cross-review topology are preserved entirely on the Private Mac.
- Small, repo-managed controls replace a large zero-build manual procedure and can be reviewed and tested directly.
- Exact frozen handoffs preserve review independence without a shared database or live messaging channel.

### Negative

- The user must provision and retain two VMs, authenticate twice, inspect exports, and tolerate deliberately restricted tasks and command networking.
- The same guest persists across the first cohort, so guest-local residue and credential lifetime last until cleanup or the retention deadline.
- Tasks requiring dependency downloads, remote verification, browsers, MCP, cloud state, SSH, or other external access are initially ineligible.
- A material version or configuration change can force both-runtime recalibration before the cohort continues.

### Risks

| Risk | Mitigation |
|---|---|
| Runtime reads its own guest credential | Explicit accepted risk; non-sensitive tasks; command-egress denial; export quarantine; logout/revoke and guest destruction |
| Non-TTY Lima sync silently writes back | Disposable staging only; actual-TTY guard; explicit rejection of `-y` and `--tty=false`; negative control |
| Guest background process changes workspace after driver completion | Freeze exact host quarantine bytes, stop guest, and give later stages only the frozen bundle |
| Copy normalizes hazardous source metadata | Inspect source inside guest and destination on host; reject hazardous fixtures; avoid claims of perfect credential non-disclosure |
| Network control blocks necessary work | First cohort selects offline-capable tasks; later exception requires human approval and recalibration |
| Persistent guest drifts or retains residue | Bind identities, stop between phases, enforce retention deadline, recalibrate on drift, destroy after cohort or abandonment |
| Private success is overgeneralized to Work | Work explicitly deferred; no Work readiness or cross-environment claim |

## Design acceptance

The user approved the separate persistent-guest architecture, the calibration lifecycle and bidirectional frozen handoff, the fail-closed boundary, and the complete control/evidence matrix on 2026-07-16. The current cycle may write this design and ADR 0032 only; implementation and VM creation require a subsequent implementation plan.

## References

- [Lima AI agents guide](https://lima-vm.io/docs/examples/ai/)
- [Lima plain mode](https://lima-vm.io/docs/config/plain/)
- [Lima v2.1.4 `shell --sync` implementation](https://raw.githubusercontent.com/lima-vm/lima/v2.1.4/cmd/limactl/shell.go)
- [Codex authentication](https://developers.openai.com/codex/auth)
- [Codex security](https://developers.openai.com/codex/security)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code sandboxing](https://code.claude.com/docs/en/sandboxing)
