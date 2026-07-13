# Claude Code Week 0 Invocation

Schema: `outer-loop-week0/v1`

This is a thin operator-facing adapter for a Work Session B. It does not redefine [policy.md](policy.md), create pilot state, or grant authority. The effective task input is only the rendered payload below, the immutable approved contract, and inherited repository/global safety guidance. Safety guidance may narrow but never broaden the contract.

Claude Code documents `/goal` for version 2.1.145 or later. Setting it starts a turn immediately; a separate evaluator checks the condition after each turn and can judge only evidence surfaced in the conversation. One goal is active per session, an achieved goal clears automatically, and resuming an active goal resets its turn, timer, and token-spend baselines. The exact installed behavior MUST still be observed in [calibration.md](calibration.md).

## Operator preflight

- Record the Claude Code version, main model/provider, invocation document version, operating system, schema, and package digest in Work-local operator state.
- Confirm workspace trust and `/goal` availability. If hooks are disabled by local or managed policy, block the Work arm; do not bypass or change that policy as part of the pilot.
- Start a fresh session. A new Claude goal replaces an existing one, so never reuse a session that may contain another run's active goal.
- Verify the final read-only contract whole-file digest and its Checkpoint 1 receipt.
- Verify the current `B-implementation` enforcement profile/config digest, canonical lexical/resolved roots, writable-path symlink/hard-link preflight and per-operation controls, credential/environment/socket exposure, network mode and allowlist digests when enabled, host-brokered external-tool inventory/operation-allowlist digests, and passing-control id.
- Confirm only approved target-worktree paths, declared disposable paths, and `report.md` are writable.
- Use interactive `/goal` for Week 0. Do not use `claude -p` unless that separate mode has passed the same controls and lifecycle rehearsal.
- Substitute the two placeholders below without adding operator-only evaluation or cohort material.

## Agent payload

Copy only the text between the markers into the fresh session. The extracted text MUST start with `/goal ` and contain no Markdown fence.

```text
<!-- AGENT_PAYLOAD_BEGIN -->
/goal Treat the approved read-only contract at "{{CONTRACT_PATH}}" (whole-file SHA-256 "{{CONTRACT_FILE_SHA256}}") as the sole task-specific instruction. Repository and global safety guidance still applies and may only narrow its authority. Before any task write, verify that digest and echo the contract's Goal, Acceptance Criteria, invariants, authority and write boundaries, required-stop conditions, and implementation bound into the contract-approved report and this conversation. If the digest or echo-back cannot be completed, make no task changes and surface STOP_REQUIRED with the reason. Otherwise execute only within the contract. End by surfacing exactly one terminal marker in this conversation: CP2_READY only after the complete contract-required report and Evidence Packet, implementation-time Unknown delta, queued decisions, residual risk, and rollback are recorded and, immediately before the marker, an Acceptance-Criterion-by-Acceptance-Criterion evidence summary is surfaced in this conversation; an honestly recorded FAIL or UNVERIFIED criterion still uses CP2_READY unless another required-stop condition applies, and it never claims delivery success. Use STOP_REQUIRED with evidence for a required stop, refuted approved assumption, exhausted bound, or inability to complete the packet safely. After either marker, perform no further work. The marker is a human-review handoff, not delivery approval.
<!-- AGENT_PAYLOAD_END -->
```

## Observed lifecycle mapping

Record the actual mapping locally during rehearsal. The expected operator procedure is:

| Semantic state | Operator procedure |
|---|---|
| Start | Submit the payload in a fresh session; setting `/goal` starts the turn |
| Inspect | Use `/goal` without arguments and record condition, turns, token use, and evaluator reason locally |
| `STOP_REQUIRED` | The terminal branch should let the evaluator end the loop; if it continues, use `/goal clear`, freeze evidence, and follow the required stop or hard-pause path |
| `CP2_READY` | Evaluator success normally auto-clears the goal; map that event to `CP2_READY_WAIT` and freeze report/canonical-change/Evidence snapshots, including honest `FAIL`/`UNVERIFIED` packets |
| Runtime/host interruption before either marker | Because documented resume resets counters, record `INTERRUPTED_NO_MARKER`, freeze only observed partial evidence with explicit absent/`UNVERIFIED` fields, start no Session C, and allow an unused next attempt only after required post-run reconciliation reaches `reconciled-clear` |
| Redirect | Create a new contract/run/fresh session only when an unused sequence remains; otherwise block/abandon, and never replace the active goal in place or create attempt 3 |
| Restart/resume | Treat a resumed active goal as the next attempt because documented turn/timer/token baselines reset; preserve prior evidence and accounting, require post-run reconciliation to clear first, and follow its block/hard-pause route or the two-attempt limit instead of creating attempt 3 |
| Terminal human disposition | Confirm no goal remains before ordinary delivery outside Week 0 |

The evaluator's success means only that the CP2-ready handoff was surfaced in the conversation. It is not Acceptance-Criterion verification or human disposition. Do not return Session B to a frozen report; post-freeze fixes use the next attempt when available, otherwise the task blocks or is abandoned.

## Drift conditions

Material Claude Code runtime/model/provider, schema, package, or adapter/invocation changes, plus a live hard-route mismatch, require affected role controls, end-to-end rehearsal, and both-runtime calibration before a real task. Enforcement profile/configuration, roots, credential/environment/socket exposure, network mode/allowlists, or host-brokered external-tool inventory/operation allowlists require affected role controls and end-to-end rehearsal; they also require both-runtime calibration when routing or lifecycle behavior may change.

## Source

- [Claude Code: Keep Claude working toward a goal](https://code.claude.com/docs/en/goal)
