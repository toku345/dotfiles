# Codex Week 0 Invocation

Schema: `outer-loop-week0/v1`

This is a thin operator-facing adapter for a Private Session B. It does not redefine [policy.md](policy.md), create pilot state, or grant authority. The effective task input is only the rendered payload below, the immutable approved contract, and inherited repository/global safety guidance. Safety guidance may narrow but never broaden the contract.

Codex currently documents `/goal <objective>` to set a goal, `/goal` to inspect it, and `/goal pause`, `/goal resume`, or `/goal clear` to control it. The exact installed behavior MUST still be observed in [calibration.md](calibration.md). Do not assume another Codex version or Claude Code has identical semantics.

## Operator preflight

- Record the Codex version, model, any distinct goal-evaluator model/provider/configuration digest or `N/A-no-distinct-evaluator`, invocation document version, operating system, schema, and package digest in local operator state.
- Confirm `/goal` is already available. If absent, block the arm; do not ask Session B to enable a feature or change global configuration.
- In a fresh session, inspect `/goal` and confirm no active goal from another run. Never replace or edit another run's goal.
- Verify the final read-only contract whole-file digest and its Checkpoint 1 receipt.
- Verify the current `B-implementation` enforcement profile/config digest, canonical lexical/resolved roots, read-side single-link control, writable-path symlink/hard-link controls, protected-exclusion/write-root overlap control, credential/environment/socket exposure, network mode and allowlist digests when enabled, host-brokered external-tool inventory plus operation/scope-selector/argument-shape allowlist digests, and passing-control id.
- Confirm only approved target-worktree paths, declared disposable paths, and `report.md` are writable.
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
| Start | Submit the payload in a fresh session; `/goal` sets the narrowly scoped run goal |
| Inspect | Use `/goal` without arguments and record the observed state locally |
| `STOP_REQUIRED` | If still active, use `/goal pause`; freeze local evidence and follow the required stop or hard-pause path |
| `CP2_READY` | Ensure the agent has yielded; freeze report/canonical-change/Evidence snapshots and keep the task active for independent review, including honest `FAIL`/`UNVERIFIED` packets |
| Runtime/host interruption before either marker | Continue the same attempt only when every calibrated continuity property is observed; otherwise record `INTERRUPTED_NO_MARKER`, freeze only observed partial evidence with explicit absent/`UNVERIFIED` fields, start no Session C, and allow an unused next attempt only after required post-run reconciliation reaches `reconciled-clear` |
| Redirect | Clear or close the old goal only after evidence is frozen; create a new contract/run/fresh session only when an unused sequence remains, otherwise block/abandon instead of editing the active goal or creating attempt 3 |
| Restart/resume | Continue the same run only if calibration proved identity, evidence, and measurement continuity; otherwise freeze prior evidence and create the next attempt only when required reconciliation is clear and an unused sequence remains, or follow its block/hard-pause route instead of creating attempt 3 |
| Terminal human disposition | Clear or close any remaining run goal before ordinary delivery outside Week 0 |

If Codex auto-completes the goal after producing the packet, map that runtime completion to `CP2_READY_WAIT` in operator state; it is not Acceptance-Criterion verification or human disposition. If it remains active, pause it. Do not resume Session B to fix post-freeze findings; a fix uses the next attempt when available, otherwise the task blocks or is abandoned.

## Drift conditions

Material Codex runtime/model, distinct goal-evaluator identity/configuration when applicable, schema, package, or adapter/invocation changes, plus a live hard-route mismatch, require affected role controls, end-to-end rehearsal, and both-runtime calibration before a real task. Enforcement profile/configuration, roots, read/write alias or protected-overlap controls, credential/environment/socket exposure, network mode/allowlists, or host-brokered external-tool inventory/operation/scope-selector/argument-shape allowlists require affected role controls and end-to-end rehearsal; they also require both-runtime calibration when routing or lifecycle behavior may change.

## Source

- [Codex: Follow a goal](https://learn.chatgpt.com/use-cases/follow-goals)
