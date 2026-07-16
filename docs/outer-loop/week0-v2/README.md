# Outer Loop Week 0 v2

Schema: `outer-loop-week0/v2`

> **Superseded — do not execute.** [ADR 0032](../../adr/0032-private-lima-outer-loop-calibration-boundary.md) supersedes this zero-build v2 path for all future calibration, arming, enrollment, role launch, and real-task execution. The remaining procedures are retained only as historical design evidence and grant no authority. Continue only through the Private Lima pre-arm calibration, whose passing state still has `real_task_allowed: no`.

This directory preserves the manual, zero-build pilot package selected by [ADR 0030](../../adr/0030-codex-claude-outer-loop-pilot.md) as amended by [ADR 0031](../../adr/0031-outer-loop-week0-v2-hard-link-boundary.md). It was never formally calibrated and must not be used for the two Private Codex tasks or two Work Claude Code tasks it originally described.

The package contains runtime-neutral policy, an exact operator collector procedure, runtime adapters, calibration fixtures, and blank templates. Never store a real contract, report, scorecard, calibration result, task identifier, repository detail, or Work-derived observation in this directory or another repository.

## Package map

| File | Audience | Purpose |
|---|---|---|
| [policy.md](policy.md) | Operator and all session roles | Sole normative source for runtime-neutral Week 0 rules |
| [collector.md](collector.md) | Operator only | Exact inline collector, canonical input/output, and extraction procedure |
| [artifact-templates.md](artifact-templates.md) | Operator; approved contract/report excerpts go to agents | Blank local artifact templates and ownership rules |
| [codex-invocation.md](codex-invocation.md) | Private operator and Session B | Thin Codex `/goal` handoff |
| [claude-invocation.md](claude-invocation.md) | Work operator and Session B | Thin Claude Code `/goal` handoff |
| [calibration.md](calibration.md) | Operator | Routing, integrity, attribution, quiescence, and end-to-end rehearsal sheets |
| [manifest.md](manifest.md) | Operator | Covered-file hashes and canonical package digest |

If this runbook or `collector.md` appears to conflict with `policy.md`, stop and use `policy.md`. If the package conflicts with ADR 0030 as amended by ADR 0031 before a real task, block the arm and revise through the package-change/drift path. During an active pilot, enter `PAUSED_HARD` only when the conflict produces a policy-defined hard-failure trigger.

## Roles and ownership

| Role | May read | May write |
|---|---|---|
| Operator | All locally approved pilot inputs and artifacts | `screening.md`, `contract.md` including its approval receipt, `scorecard.md`, local calibration/control records, canonical CP2 snapshot before freeze, company-arm summary, generalized-learning record, and `cohort.md` |
| Session A1 — discovery | Approved goal context, target worktree, primary evidence | Its response only; target worktree and pilot artifacts are read-only |
| Session A2 — blind-spot pass | Goal, constraints, Acceptance Criteria, target worktree, primary evidence; not A1 inventory or plan | Its response only; target worktree and pilot artifacts are read-only |
| Optional spike | Approved inputs and one declared private temporary root | Evidence-only output inside that temporary root |
| Session B — implementation | Frozen contract, approved target-worktree paths, repository guidance, declared verification inputs | Approved target-worktree paths, declared disposable paths, and `report.md`; no other pilot artifact |
| Session C — independent review | Frozen Goal, Acceptance Criteria, contract, report, verification, complete reviewable CP2 snapshot, and only the aggregate protected-exclusion unchanged attestation; no protected path/metadata detail | Its response only; the operator transcribes findings and questions into `scorecard.md` |

Session C reports `reported_by` metadata; the operator separately records `recorded_by`. This preserves provenance without letting the reviewer modify observer evidence.

## Local state

Choose environment-local paths before starting an arm:

```text
<durable-local-state>/
├── screening.md
├── cohort.md
├── calibration/
├── collections/
├── provenance/
├── accepted-risks/
├── controls/
├── hard-pauses/
└── tasks/<task-id>/scorecard.md

<os-private-temp>/<task-id>/<run-id>/
├── input/contract.md
└── output/report.md
```

Both roots must be outside repositories and synchronized or shared folders. Directories use protection equivalent to `0700`; files use protection equivalent to `0600`. These modes protect against other OS users but do not constrain an agent running as the operator. The role-specific default-deny runtime or OS profile required by [policy.md](policy.md#enforcement-boundary) is the agent boundary.

Task and run identifiers are opaque and machine-local. A Work identifier never crosses to Private. Keep every task scorecard through the final four-task cohort decision and make it independently understandable after raw run artifacts are deleted. If local policy cannot permit this minimum, do not start that environment's arm.

## Arm prerequisites

Complete these locally before a real task:

- Recompute every covered hash and the package digest in [manifest.md](manifest.md); match the last successful cross-runtime calibration.
- Approve the durable state root, private temporary root mechanism, raw retention/deletion policy, and any permitted cross-environment transfer path.
- Record the runtime, main model, any distinct goal-evaluator model/provider/configuration digest, invocation version, operating system, and current package identity.
- For `A1-discovery`, `A2-blind-spot`, `B-implementation`, `C-review`, and optional `spike-temp`, record a passing control id, enforcement profile/configuration digest, read/write roots, task-surface and enforced-denial inventories, collector identity/configuration, passing preflight/postflight safety controls, writable alias/protected-overlap controls where applicable, credential/environment/socket exposure, network mode and allowlist digests when enabled, host-brokered external-tool inventory plus operation/scope-selector/argument-shape allowlist digests, and invocation version.
- Demonstrate with safe disposable sentinels and complete per-control evidence that outside-approved-root reads are denied, pre-existing approved-root hard-link aliases are rejected by the collector before content open and role launch, hard-link creation is denied before destination creation for every role and applicable source/destination class, prohibited writes, every protected-descendant write/delete/rename/link/replacement mutation inside writable roots, credential-source reads, undeclared egress, every otherwise write-capable brokered-tool channel, and every enabled brokered read against an unapproved value on each applicable account/tenant/repository/resource/destination selector axis or a disallowed shape are denied before disclosure, request, or mutation; confirm no secret-bearing inherited environment variable or credential/keychain/agent socket is exposed to role tools. Detection afterward or a hand-entered aggregate result is not a passing control.
- Confirm that no role has write access to operator-owned artifacts and that A1, A2, and C cannot mutate the target worktree.
- On Work, approve the storage, package transfer or manual recreation path, manifest attestation process, reviewer runtime, and retention minimum under company policy.
- Complete both-runtime routing calibration plus success, redirect, and restart/resume rehearsals in [calibration.md](calibration.md).

Any package, profile, canonical root, read/write alias or protected-overlap control, credential/environment/socket exposure, network enforcement, host-brokered external-tool operation/scope-selector/argument-shape boundary, invocation, goal-evaluator identity/configuration, or runtime-behavior drift blocks the affected session until [policy.md](policy.md#drift-and-recalibration) is satisfied.

## V2 integrity lifecycle

For prospective screening and every A1, A2, optional spike, B, and C role, follow this sequence:

1. Freeze the task-visible surface and enforced-denial inventory.
2. Run the exact [collector](collector.md). A failed or incomplete collection means no role launch.
3. Verify the current role's hard-link creation denial and execution-group evidence identity against its passing calibration record.
4. Launch the role under the frozen authority.
5. On completion or interruption, expire authority and prove execution-group quiescence.
6. Run the identical collector and derive the role-specific postflight outcome from [policy.md](policy.md#v2-integrity-lifecycle).
7. Advance only from a complete passing gate. Never use a clean repeat to revive invalidated output.

The operator retains safety, review-state, provenance, attribution, quiescence, and accepted-risk records locally. Agent payloads receive only their role-specific stop conditions and approved inputs; they do not receive operator-only cohort or threat-model material.

## Operator runbook

### 1. Screen and establish the baseline

1. Append every candidate in arrival order to the local `screening.md` created from [artifact-templates.md](artifact-templates.md#screening-log).
2. Apply the eligibility and exclusion rules in [policy.md](policy.md#eligibility).
3. Prospectively record task-specific screening time for each candidate. After arm readiness, irreversibly enroll the first two eligible candidates as local slots 1 and 2 at eligibility time and start their full-burden attention record with that candidate's screening entry. Never replace an enrolled task because of its later outcome.
4. For an enrolled task, assign its dominant class and scope tier and freeze the required same-boundary comparison baseline before discovery.
5. Include per-task package/profile preflight, discovery, contract/template preparation, and session-start effort in advancement attention. Record pre-CP1 effort separately only as an included subset; record one-time arm setup/calibration separately as non-task pilot overhead.

### 2. Discover Unknowns without changing the worktree

1. Record the target worktree's HEAD, status, index state, and diff digest.
2. Run bounded, read-only Session A1.
3. Run fresh, read-only Session A2 without the A1 inventory or plan.
4. If the policy requires risk reduction, narrow the scope or run one evidence-only spike in a declared private temporary root.
5. Record the current attempt's A1, A2, and used-spike declared/observed/status/evidence tuples before Checkpoint 1; they remain even if the contract is not approved.
6. Reconcile candidates into the contract template. Route every retained candidate; do not treat agent agreement as evidence.
7. Recheck HEAD, status, index state, and diff digest. Any unexpected mutation blocks Checkpoint 1.

### 3. Hold Checkpoint 1

1. Assign the next `run_sequence` and present the contract, Unknown evidence and routes, plan-changing questions, authority, rollback, and bounds. The run attempt starts at this first presentation even if approval never occurs; the full-burden task attention window is already active.
2. The human chooses approve, narrow, or block within the policy bounds; record the attempt's Checkpoint 1 bound tuple regardless of outcome.
3. On approval, calculate the approved-payload digest as specified by the contract template, complete the operator receipt, make the final contract read-only, calculate its whole-file digest, and record both digests in `scorecard.md`.
4. Recompute the package digest and verify the `B-implementation` enforcement record immediately before Session B.
5. With the operator-owned canonical collector, freeze the complete pre-Session-B reviewable baseline and local protected-exclusion metadata. Never traverse Git control paths, follow symlinks, or read regular-file content unless `st_nlink == 1`. Before Session B, reject protected/write-root overlap or prove an exact deny overlay for every protected descendant. A multiply linked or otherwise required-but-protected review input, classification failure, or unproved overlap blocks Session B, and the approved-but-not-started ledger variant preserves the run's frozen contract and authority.

### 4. Run fresh Session B with `/goal`

1. Start a fresh runtime session using only repository/global safety guidance and the frozen contract as task-specific instruction.
2. Use the appropriate thin adapter: [Codex](codex-invocation.md) or [Claude Code](claude-invocation.md).
3. Require the contract echo-back before any edit. A handoff gap stops the run.
4. Let Session B implement, verify, maintain `report.md`, and route decisions under `policy.md`.
5. Session B ends at `CP2_READY` or an earlier required stop. It never performs delivery operations.

### 5. Freeze evidence and run fresh Session C

1. At `CP2_READY`, ensure Session B cannot continue without a new human turn. Run the identical collector, freeze `report.md` and the Evidence Packet, and bind pre-B baseline to final state in a canonical CP2 change snapshot covering reviewable tracked/untracked/ignored paths and pre-existing-change attribution. Protected paths remain content-free and Work-local. A protected-path change attributable to Session B triggers the unauthorized-operation hard-failure route; other protected metadata drift, classification failure, or required review content behind that boundary yields `STOP_REQUIRED` with no Session C handoff.
2. Record all component and canonical digests plus a self-contained summary in the operator-owned scorecard.
3. Recompute the package digest and verify the `C-review` enforcement record.
4. Build the canonical exact-byte Session C review-bundle manifest over every policy-required reviewable input and only the aggregate protected-exclusion unchanged attestation; include canonical empty bytes rather than omitting an empty required category. In a fresh context, Session C verifies the required logical-name inventory and recomputes every received input hash and the bundle digest before inspecting Goal, Acceptance Criteria, the snapshot, and verification ahead of the driver's Decision Log. Protected paths and metadata remain operator-local.
5. A complete Session C returns merge-blocking findings, evidence gaps, reviewer-discovered Unknowns, and three to five understanding questions. The operator records them plus durable evidence that the context was fresh and the blind-first order was followed in the scorecard. If Session C launched but timed out, crashed, or returned no complete usable result, retain the real prelaunch facts, record `UNVERIFIED-no-session-c-result` for missing result facts, and fail the review, quiz, and ship gates without inventing output.

### 6. Hold Checkpoint 2

1. Present the frozen Evidence Packet and understanding questions; start the CP2 timer.
2. Resolve quiz misses from evidence within the policy limits. An unresolved or foundational miss cannot result in `ship`.
3. Recheck the operator-local canonical snapshot and protected metadata against live state. Evaluate and record the scorecard's ship gate: every Acceptance Criterion is `PASS`, every Unknown has a complete evidence outcome and is resolved or explicitly accepted by a human owner with evidence, every queued decision has a human-reviewed terminal outcome, Session C recomputed the complete required review bundle and has passing fresh-context/blind-first evidence within its bound, no `blocks-ship` finding remains, and the quiz gate passed.
4. The human records `ship` only after that gate passes; otherwise record `narrow`, `redirect`, or `block`.
5. Close, pause, or replace the runtime goal according to the lifecycle behavior observed during calibration.
6. Immediately before delivery, recheck the live worktree against the frozen snapshot. Only after an exact match and terminal human `ship` disposition may ordinary commit, push, draft-PR, merge, or deployment workflows run outside Week 0 under repository rules and separate approvals. `narrow` and `redirect` use the next attempt when available; otherwise `block` or abandonment prohibits delivery.

### 7. Redirect or finish the task

A same-intent `narrow`, `redirect`, or post-freeze fix may create the next contract and run attempt under the same task id only when sequence 1 or 2 remains. A pre-approval `narrow` already consumed its attempt. Preserve every earlier attempt's A1/A2/spike/CP1 and started B/C bound tuples and derive task bound compliance as their conjunction; a later success cannot erase an earlier overrun or `UNVERIFIED`. Preserve and cumulatively count every earlier attempt; a third is prohibited. A material Goal replacement terminates the old task as non-qualifying and receives a new task id. Do not let a new run erase cost, evidence, or a hard failure.

## Runtime lifecycle mapping

Each environment records the observed mapping rather than assuming identical product semantics:

```text
ACTIVE
  |
  +--> CP2_READY_WAIT
  |      +--> ship
  |      +--> narrow -> next attempt if a sequence remains
  |      +--> redirect -> next attempt if a sequence remains
  |      +--> block
  |      `--> abandonment
  `--> runtime/host interruption
         +--> proven calibrated continuity -> same ACTIVE attempt
         `--> otherwise INTERRUPTED_NO_MARKER -> post-run reconciliation
                +--> reconciled-clear -> next attempt if available, else block/abandonment
                +--> reconciliation-unverified -> block/abandonment
                `--> Session-B-caused unauthorized delta -> PAUSED_HARD
```

At `CP2_READY_WAIT`, Session B yields and cannot continue without a new human turn. If a runtime cannot safely keep a goal waiting, the run goal may complete narrowly as “produce the frozen CP2-ready packet” while the task remains active in the operator scorecard. A runtime/host interruption suspends the run's authority immediately. The same attempt and authority resume only when every calibrated continuity property, including the frozen contract and authority, is observed and recorded. Otherwise authority expires: record `INTERRUPTED_NO_MARKER`, freeze only actually observed partial evidence, mark missing artifacts explicitly, and never start Session C or record `ship`. When the final collector is incomplete, keep those missing fields unchanged and separately reconcile the frozen pre-B baseline against current state with the identical collector before any next attempt or terminal aggregation. Recovery requires `reconciled-clear` and an unused sequence; an unverified reconciliation blocks or abandons, while a Session-B-caused protected or out-of-authority delta enters `PAUSED_HARD`.

## Hard pause and resume

On any hard-failure trigger in [policy.md](policy.md#hard-failure-and-resume), immediately:

1. Freeze and digest local evidence.
2. Set the pilot state to `PAUSED_HARD`; stop the cohort and all pilot-derived transfers.
3. Diagnose and record the cause and affected controls in the originating environment.
4. Choose `STOPPED` or revise the policy/package.
5. After a revision, rerun affected controls and end-to-end rehearsal, recalibrate both runtimes, and obtain explicit human resume approval.
6. Start a new cohort. Keep the prior failure in pilot history; a new cohort does not clear it.

Information-boundary incidents follow the originating environment's security process. Do not transfer incident details merely to justify resumption.

## Work boundary and aggregation

Raw Work artifacts, review, identifiers, code, architecture, conventions, Skills/prompts, paths, logs, tickets, exact timing, and identifiable metric combinations stay on Work. `agmsg` is not an automatic cross-machine or cross-environment transport.

After both Work tasks terminate, use exactly one mode defined by [policy.md](policy.md#information-boundary):

- Have Private issue a current schema/package single-use challenge, then transfer one human-approved seven-field company-arm summary and its canonical challenge-bound integrity envelope atomically through a company-permitted authenticated path; Private verifies sender/channel provenance, envelope schema, challenge freshness, payload hash, and replay absence before consuming the challenge; or
- Perform the comparison in place without persisting Work-derived counts, coverage, gates, reasons, or combined evidence on Private.

Each task result is `qualifying` if and only if it is comfort-eligible, all hard gates are clear, and every comfort check passes. Each arm derives completed count, hard-gate conjunction, qualifying count, and ship coverage from exactly two immutable fixed-slot terminal scorecards. The Work-local receipt must prove that derivation plus fixed-slot/no-replacement validity before the unchanged seven-field payload can be issued; that evidence never transfers. Private derives the four-task advancement gate from its two local rollups and the verified Work summary, and `advance` is valid only when exactly four slots are terminal, all hard gates are clear, at least three tasks qualify, both runtimes have a ship, and every source/aggregate value is consistent. Any missing, contradictory, or failed source-local or receive-side check blocks issuance/advancement or falls back to `in-place-no-transfer`. A generalized-learning statement may cross only after its own abstraction and reconstructability review and only when content and timing do not associate it with a task or arm summary. It is not a cohort result or proxy decision. If no Work outcome may cross, Private records `awaiting_external_decision` and must not begin or claim the shared Skill phase.

If a prior Work hard failure or remediation must be acknowledged, the seven-field summary is insufficient. Keep that comparison and a never-transfer decision receipt in Work-local state; do not add failure/remediation fields to the summary or Private record. If Work policy cannot retain that local receipt, the comparison cannot authorize advancement.

In `approved-summary` mode, the Private advancement gate derives whether any prior Private hard failure exists from a complete provenance-bound Private-local history scan and requires its verified remediation acknowledgement before `advance`. A prior Work hard failure or incomplete Work-local history evidence makes the Work summary issuance gate fail and forces `in-place-no-transfer`; neither condition can be overridden by entering a passing aggregate or human approval.

In `in-place-no-transfer` mode, the Work-local decision receipt requires complete provenance-bound history checks for both originating environments and each applicable originating-environment remediation acknowledgement. Private evidence is checked in place without copying incident detail into the Work receipt. Missing or incomplete history in either environment blocks `advance`; fallback from an ineligible approved summary does not clear that prerequisite.

## Cleanup

- Remove raw contracts, reports, snapshots, and fixture data according to local policy only after their required summaries and digests are safely recorded, including durable per-run authority, scope, expiry, permitted-operation, and prohibited-boundary facts.
- Retain self-contained task scorecards through the final cohort decision and retain remediation records for any hard failure.
- Keep fake and rehearsal data out of repositories and out of the real cohort.
- Keep repository-required ADRs or implementation notes separate from pilot state; normal project guidance remains authoritative for project deliverables.

## Package change procedure

[ADR 0032](../../adr/0032-private-lima-outer-loop-calibration-boundary.md) used the one permitted pre-observation correction to add the supersession notices and regenerate this historical package identity. That correction path is now closed. Do not edit v2 in place; any later proposal must create a new schema and versioned directory with its own manifest, controls, rehearsals, and calibration. Preserve this package and any older observations without pooling identities.

## ADR traceability

| ADR 0030 requirement | Authoritative package location |
|---|---|
| Eligibility and four-task cohort | [Policy: Eligibility](policy.md#eligibility), [Policy: Advancement decision](policy.md#advancement-decision) |
| Shared contract, task/run identity, provenance | [Policy: Identity and provenance](policy.md#identity-and-provenance), [Contract template](artifact-templates.md#run-contract) |
| Checkpoints, session separation, blind-first review, quiz | [Policy: Checkpoints and evidence gate](policy.md#checkpoints-and-evidence-gate), [Operator runbook](#operator-runbook) |
| Artifact ownership, retention, and self-contained scorecard | [Policy: Artifact ownership](policy.md#artifact-ownership), [Artifact templates](artifact-templates.md) |
| Unknown discovery and implementation/reviewer deltas | [Policy: Unknown discovery and routing](policy.md#unknown-discovery-and-routing) |
| Decision routing and interruption policy | [Policy: Decision routes](policy.md#decision-routes) |
| Week 0 authority boundary | [Policy: Enforcement boundary](policy.md#enforcement-boundary) |
| Private/Work separation and transfer allowlists | [Policy: Information boundary](policy.md#information-boundary), [Company-arm template](artifact-templates.md#company-arm-summary) |
| Measurement and comparison baseline | [Policy: Measurement](policy.md#measurement) |
| Task/checkpoint bounds and goal lifecycle | [Policy: Bounds and lifecycle](policy.md#bounds-and-lifecycle), runtime invocation documents |
| Hard-failure pause and resume | [Policy: Hard failure and resume](policy.md#hard-failure-and-resume), [Hard-pause template](artifact-templates.md#hard-pause-and-remediation-record) |
| Cross-runtime calibration and drift | [Policy: Drift and recalibration](policy.md#drift-and-recalibration), [Calibration](calibration.md) |
| Package identity and mismatch behavior | [Policy: Package identity](policy.md#package-identity), [Manifest](manifest.md) |
| Hard-link boundary, collector, role postflight, and quiescence | [Policy: V2 integrity lifecycle](policy.md#v2-integrity-lifecycle), [Collector](collector.md), [Calibration](calibration.md) |
| Post-pilot Skill authority constraints | [Policy: Deferred Skill constraint](policy.md#deferred-skill-constraint); not implemented during Week 0 |

## References

- [ADR 0030](../../adr/0030-codex-claude-outer-loop-pilot.md)
- [ADR 0031](../../adr/0031-outer-loop-week0-v2-hard-link-boundary.md)
- [Week 0 v2 boundary design](../../design/codex-claude-outer-loop-week0-v2.md)
- [Outer-loop pilot design](../../design/codex-claude-outer-loop-pilot.md)
- [Codex: Follow a goal](https://learn.chatgpt.com/use-cases/follow-goals)
- [Claude Code: Keep Claude working toward a goal](https://code.claude.com/docs/en/goal)
