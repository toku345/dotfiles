# ADR 0033: Accept Unenforced Runtime Main-Process Egress for Private Lima Calibration

## Status

Accepted

Amends [ADR 0032](0032-private-lima-outer-loop-calibration-boundary.md).

## Context

ADR 0032 selected separate persistent Lima guests for the Private Codex / Claude outer-loop pre-arm calibration. It required each runtime process to reach only the endpoints needed for subscription login and model calls, while separately requiring agent-launched commands to have zero-by-default egress.

The proposed implementation can enforce and test the child-command boundary with the runtime-specific sandbox, root-owned policy, execution receipts, and operator-owned canaries. It cannot independently enforce a provider-endpoint allowlist on the Codex or Claude main process without adding a transparent proxy, guest firewall owner rules, certificate interception, or another privileged network mediator. Those mechanisms would materially widen the trusted computing base, introduce provider endpoint discovery and TLS maintenance, and create a different calibration design.

Treating the main-process statement as already enforced would create a false-green result. The calibration must distinguish the load-bearing child-command control from the residual main-process risk.

## Decision

Accept `AR-02 runtime-main-process-egress-not-enforced` for this Private pre-arm calibration.

The Codex and Claude main processes use the guest's ordinary outbound network path. The harness does not enforce or claim an endpoint allowlist for subscription login, configuration retrieval, update checks, telemetry, model calls, or other runtime-originated traffic. Observed provider traffic may be recorded only as non-authoritative diagnostic classification and never as proof of restriction.

Limit `C03` to commands, scripts, and subprocesses launched through the calibrated agent tool boundary. `C03` must prove the intended command argv was actually attempted, the paired outside-sandbox path was reachable when the path exists, the inside-sandbox path produced the expected sandbox-denial classification, and the operator canary did not receive the inside nonce. A failed command alone is not a pass.

Keep `AR-02` outside the control matrix and control aggregator. It is a separately typed risk acceptance with disposition `NOT_PROVIDED_ACCEPTED_RISK`; it is not a `PASS`, `UNAVAILABLE_BASELINE`, or substitute control. Supplying a risk record to control aggregation must fail validation.

The acceptance is valid only while all of the following remain true:

- Calibration and any later candidate task use non-sensitive data only.
- Web search, WebFetch, apps, connectors, MCP, browsers, cloud credentials, SSH credentials, hooks, sideloaded extensions, auto-update, and unsandboxed retry paths remain disabled or absent.
- Runtime seed, managed policy, sandbox configuration, probe wrapper, and trusted harness remain root-owned and runtime-non-writable inside each guest.
- A human approves `AR-02`, the exact lock/manifest identity, and the immutable retention deadline before either guest is created.
- Every terminal state retains `real_task_allowed: no`; a passing calibration authorizes only v3 design.

`AR-01 runtime-may-read-own-guest-credential` remains a separate accepted risk from ADR 0032. Neither accepted risk weakens export quarantine, cleanup, revocation, or child-command egress controls.

## Consequences

### Positive

- The evidence no longer overstates a network property the implementation cannot enforce.
- `C03` has a narrow testable subject and can fail closed on missing execution or ingress evidence.
- The calibration remains small enough to test the outer-loop hypothesis before introducing a privileged network mediator.

### Negative

- A compromised or misbehaving runtime main process could reach destinations beyond its provider endpoints.
- Provider traffic observations cannot establish safety, completeness, or destination restriction.
- Main-process exploitation remains capable of exfiltrating guest-local data available to that runtime, including its own subscription credential.

## Successor requirement

A future v3 design must decide `AR-02` again against its concrete task data, runtime versions, and network architecture. A passing pre-arm calibration does not transfer risk authority into v3. V3 may accept the risk again, add an independently enforced main-process boundary and recalibrate, or remain blocked. It must not describe main-process egress as safe, limited, or verified merely because `C03` passed.

## References

- [ADR 0032: Calibrate the Private Outer Loop with Separate Lima Guests](0032-private-lima-outer-loop-calibration-boundary.md)
- [Private Lima pre-arm calibration design](../design/codex-claude-outer-loop-private-lima-calibration.md)
- [Private Lima calibration implementation design](../design/codex-claude-outer-loop-private-lima-calibration-implementation.md)
