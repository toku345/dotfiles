# Codex / Claude Outer Loop Week 0 — Design and Implementation Plan

Parent decision: [ADR 0030](../adr/0030-codex-claude-outer-loop-pilot.md)
Status: Draft (2026-07-13)

## Context

ADR 0030 chooses a zero-build Week 0 pilot before any reusable Skill, Dynamic Workflow, hook, or custom runner is created. The pilot must run on separate Private and Work machines, use Codex `/goal` for Private implementation and Claude Code `/goal` for Work implementation, keep raw run state on the originating machine, and concentrate human attention into Checkpoint 1, Checkpoint 2, and genuine hard stops.

This document turns that decision into an executable plan. It describes the tracked manual pilot package to create, the environment-local state it instantiates, the session sequence, validation, and the four-task cohort. It does not start the cohort or implement the future Skill.

## Goals

- Produce one versioned, runtime-neutral Week 0 policy with thin manual invocation instructions for Codex and Claude Code.
- Make `contract.md`, `report.md`, task-level `scorecard.md`, calibration results, and the company-arm summary mechanically distinguishable even though their creation remains manual.
- Let a fresh implementation session reach `CP2_READY` without repeated human supervision when the contract is complete.
- Preserve every redirect, retry, interruption, quiz miss, and hard failure at task level instead of allowing a new run to erase prior cost.
- Run the same generalized calibration on both machines before real tasks.
- Keep all Work raw data on the Work machine and transfer at most one human-approved company-arm summary after both Work tasks reach terminal disposition.
- Produce enough evidence after a same-schema two-Codex/two-Claude cohort to decide whether Skill packaging is worthwhile.

## Non-goals

- Implementing a Skill, plugin, hook, Dynamic Workflow, runner, automatic timer, artifact generator, or aggregator.
- Installing persistent runtime adapters or changing global Codex or Claude Code configuration.
- Automatically synchronizing the two machines or using `agmsg` across the information boundary.
- Storing run instances in this repository or in the target task repository.
- Transferring Work contract, report, scorecard, code, diff, path, log, ticket, timestamp, task order, or run-level measurements.
- Allowing stage, commit, push, draft PR creation, branch/worktree mutation, merge, deploy, or external-state writes inside a Week 0 `/goal` run.
- Optimizing Unknown count or autonomous step count.
- Treating four tasks as evidence of rare-event safety.
- Touching `.claude/worktrees/` as part of this work.

## Delivery approach

### Considered approaches

| Approach | Trade-off | Decision |
|---|---|---|
| One monolithic runbook containing policy, templates, prompts, and evaluation | Easiest to copy, but audience boundaries are weak and operator-only evaluation material is easy to paste into an agent prompt | Reject |
| A small versioned Markdown package with separate operator, artifact, runtime-invocation, and calibration documents | A few more files, but responsibilities and copy boundaries are explicit while remaining zero-build | Adopt |
| Scripts, Skills, or workflows that create and aggregate artifacts | Stronger enforcement, but contradicts the Week 0 learning goal and creates a second system to supervise | Defer until the pilot passes |

### Planned repository layout

The tracked package contains only generalized policy and blank templates. Generated task/run artifacts remain outside every repository.

```text
docs/
├── adr/
│   └── 0030-codex-claude-outer-loop-pilot.md
├── design/
│   └── codex-claude-outer-loop-pilot.md
└── outer-loop/
    └── week0-v1/
        ├── README.md                 # operator runbook, lifecycle, checkpoints
        ├── policy.md                 # shared routes, authority, CP2_READY contract
        ├── artifact-templates.md     # run/task/arm/cohort artifact templates
        ├── codex-invocation.md       # manual Codex /goal handoff only
        ├── claude-invocation.md      # manual Claude Code /goal handoff only
        ├── calibration.md            # generalized scenarios and result sheet
        └── manifest.md               # per-file SHA-256 and package digest
```

The initial schema identifier is `outer-loop-week0/v1`. `manifest.md` records a SHA-256 for each of the other six files and a package digest over the sorted path/digest pairs; the manifest excludes itself from that calculation. Both machines record the schema version and package digest in calibration, contract, and scorecard metadata. A schema or package change requires a new versioned directory, calibration on both machines, and a new advancement cohort. Existing observations are retained and never rewritten to the new version.

## State topology

Each machine chooses its own approved paths. No absolute Work path is recorded in the shared package or Private aggregate.

```text
[tracked generic package]
          |
          +---------------------------+
          v                           v
  Private machine                Work machine
  Codex implementation           Claude implementation
  local task scorecards          local task scorecards
  local run temp dirs            local run temp dirs
          |                           |
          |                 human abstraction gate
          |                           |
          +<---- one arm summary -----+
```

Logical local layout:

```text
<durable-private-state>/
├── screening.md
├── cohort.md
└── tasks/<task-id>/scorecard.md

<os-private-temp>/<task-id>/<run-id>/
├── input/contract.md
└── output/report.md
```

- Durable state is local, non-shared, non-synchronized, and protected with directory/file permissions equivalent to `0700`/`0600`. Those modes protect against other OS users but are not treated as an agent sandbox when the agent runs as the operator's user.
- Each run directory is created with an OS-provided private temporary-directory mechanism and the same permission boundary. Separate input and output roots let the runtime expose the approved contract read-only and `report.md` writable.
- `task-id` and `run-id` are opaque machine-local identifiers and never cross from Work to Private.
- A scorecard lists all associated run ids and remains interpretable after temporary contract/report deletion. Both machines retain task-level scorecards through the final four-task cohort decision; if local policy cannot permit that minimum, the corresponding pilot arm does not start.
- The operator alone creates and modifies each draft contract and its Checkpoint 1 approval receipt. The approved contract digest is recorded in the scorecard, the whole contract becomes read-only with no writer, and any required contract change uses the next attempt rather than editing it in place when an unused run sequence remains; otherwise the task is blocked or abandoned.
- Before any rehearsal or real task, each runtime must demonstrate a default-deny runtime/OS sandbox or approval profile with explicit read and write roots, credential/environment/socket exposure, network enforcement, and host-brokered external-tool boundaries. The agent may read the target worktree and approved contract; it may write only approved target-worktree paths, `report.md`, and declared disposable temporary/cache paths. Every regular-file content read first requires `st_nlink == 1`. Each write root is canonicalized with lexical/resolved identities recorded; every writable entry and existing component below the canonical root is symlink-free, and writable regular files have one hard link. Per-operation enforcement denies symlink traversal, writes to multiply linked files, symlink or hard-link creation, and resolved containment outside the exact canonical write roots before mutation. The operator compares protected exclusions with every write root before launch and blocks any overlap unless an exact deny overlay rejects write, delete, rename, link, and replacement mutation for the protected path or subtree before mutation. Tasks requiring symlink or multiply linked file mutation are outside Week 0. Reads outside approved roots, including symlink-resolved aliases and hard-link aliases, and Git metadata, other repositories, operator-owned pilot state, global configuration, tool-readable credentials or secret-bearing inherited environment variables, credential/keychain/agent sockets, persistent services/databases, and external write-capable network access remain unavailable. Tool-visible network is disabled unless enforcement restricts destinations and request shapes to an approved read-only allowlist; otherwise the operator supplies primary-source material or fixtures. MCP, app, browser, connector, and similar brokered surfaces are inventory/digest-bound and disabled or restricted to enforced read-only allowlists that bind each enabled operation to applicable account, tenant, repository, resource, destination, and argument/request shapes.
- During Session B, `report.md` is the only pilot artifact the `/goal` agent may modify. Draft contract and receipt, scorecard, company-arm summary, cohort decision, generalized-learning records, and package manifest are operator-owned and outside the agent's write roots; after contract freeze, nobody writes the contract. A permission request to cross this boundary is rejected rather than used as a Week 0 override.
- Sandbox negative controls use disposable fixtures and harmless sentinels: an outside-approved-root read, a symlink alias, an approved-root hard-link alias to an outside sentinel, a direct write outside an allowed root, writes through in-root symlink and hard-link aliases to outside sentinels, symlink and hard-link creation, each protected-descendant write/delete/rename/link/replacement mutation inside an otherwise approved write root, a Git-metadata mutation in a fixture repository, an operator-artifact write, a credential-source read, an undeclared-egress request, each distinct brokered write channel, each enabled brokered read operation with an unapproved value on every applicable account/tenant/repository/resource/destination selector axis and a disallowed argument/request shape, and a mock external-state write must all be denied before request, mutation, or disclosure. Alias and protected-overlap controls record the relevant sentinel, protected target, and applicable source/replacement pre/post digests. The launch record also confirms that secret-bearing environment variables and credential/keychain/agent sockets are unavailable to role tools without recording secret values. Every control records fixture, attempted operation, pre/post state, observed result/exit status, denial stage, provenance, and operator verification; an aggregate pass is derived only from complete passing controls. Post-run inspection remains defense in depth, not the primary control. If either runtime cannot demonstrate every applicable denial, that pilot arm is blocked.
- Passing controls are role-specific for `A1-discovery`, `A2-blind-spot`, `B-implementation`, `C-review`, and the optional `spike-temp` exception. Every record includes runtime, OS, main model, any distinct goal-evaluator model/provider/configuration digest, sandbox/approval-profile identity and configuration digest, allowed read/write roots, read-side single-link control, writable alias and protected-overlap controls where applicable, credential/environment/socket exposure, network mode plus destination/request-shape allowlist digests when enabled, external-tool inventory and operation/scope-selector/argument-shape allowlist digests, and invocation version. Before every session, the operator compares that role's current enforcement identity and boundaries with its last passing record. Any drift reruns the role's negative controls and, when it changes runtime or routing behavior, end-to-end rehearsal and both-runtime calibration; the session remains blocked until they pass.
- Work storage, raw-artifact retention beyond the scorecard minimum, and deletion follow company policy. If an approved durable path is unavailable, Work pilot execution does not start.

## Session topology

The default uses `/goal` only after the contract is approved. This keeps one implementation goal aligned with one approved run contract and avoids using an unapproved discovery draft as a durable goal.

```text
Session A1: driver discovery and contract draft
Session A2: fresh blind-spot pass without driver inventory/plan
                       |
                reconcile evidence
                       |
                       v
                 Checkpoint 1
                       |
                       v
Session B: fresh implementation session + /goal
          echo-back -> implement -> verify -> CP2_READY
                       |
                       v
Session C: fresh blind-first independent review
                       |
                       v
                 Checkpoint 2
                       |
          ship / narrow / redirect / block
```

- Before Session A1, the operator records the target worktree's HEAD, status, index state, and diff digest as the pre-discovery baseline. Sessions A1 and A2 receive read-only access to the target worktree. Session A1 is a bounded driver session. Session A2 is a separate fresh context that sees Goal, Constraints, Acceptance Criteria, code, primary documentation, and baseline behavior but not the driver's inventory or plan. Its blind-spot pass is limited to 10 minutes. If it produces two or more high-impact `block` or `ask-human` candidates, the driver narrows scope or runs at most one 20-minute evidence-only throwaway spike in a declared private temporary path, never in the target worktree. After risk reduction, at most five candidates and three plan-changing questions remain; otherwise the task narrows instead of asking piecemeal. The operator verifies the pre-discovery worktree baseline is unchanged before presenting CP1; any unexpected mutation blocks approval. The driver then prepares the CP1 packet.
- The full-burden task attention window starts with the first recorded task-specific screening or preparation activity for the candidate that becomes enrolled; CP1 presentation starts the run-attempt count, not the attention window. Human approval then freezes the run contract.
- Session B is fresh. Immediately before it starts, the operator freezes a canonical reviewable baseline plus local protected-exclusion non-content metadata, requires `st_nlink == 1` before every regular-file content read, and blocks an unproved protected-exclusion/write-root overlap. Session B creates or resumes the runtime's goal using the approved read-only contract as its sole task-specific instruction source; repository and global safety guidance still applies. It records a contract echo-back in `report.md` and stops at `CP2_READY`; runtime self-declared completion is not verification evidence. At `CP2_READY`, the operator stops Session B, freezes the report, runs the identical final collector, and records report, Evidence Packet, and baseline/final canonical change-snapshot digests before review. The collector never traverses Git-control paths or follows symlinks and never reads or bundles denied, secret-bearing, or multiply linked content. A protected-path change attributable to Session B triggers the unauthorized-operation hard-failure route; other protected metadata drift, classification failure, required review content behind that boundary, or unproved overlap yields `STOP_REQUIRED`.
- Session C is fresh and stays inside the same information boundary. It receives read-only snapshots of Goal, Acceptance Criteria, contract, the complete reviewable portion of canonical change state, report, and verification, plus only the aggregate protected-exclusion unchanged attestation. It receives no protected path or metadata detail. The operator supplies a canonical manifest over the exact bytes of every delivered input; Session C recomputes every input hash and the review-bundle digest, verifies the reviewable inventory and attestation, reviews Goal, Acceptance Criteria, the snapshot, and verification before reading the driver Decision Log, then returns findings and three to five understanding questions without modifying the worktree or pilot artifacts. The operator separately verifies the full local canonical snapshot and protected metadata before disposition and delivery and records Session C output in the scorecard's CP2 section.
- Checkpoint 2 records quiz misses, evidence-reviewed resolutions, and the human disposition in the operator-owned scorecard. The runtime adapter closes or replaces the run goal according to the calibrated lifecycle mapping; task disposition remains an operator decision. Delivery happens afterward under the repository's normal workflow.
- A same-intent `narrow` or `redirect` returns through bounded discovery and Checkpoint 1, then creates the next run attempt and a new Session B under the same task id only when an unused sequence remains. Otherwise the task blocks or is abandoned rather than creating attempt 3. A material Goal replacement ends the original task as non-qualifying and starts a new task id.

The exact current UI or CLI steps for creating, resuming, and completing `/goal` are verified during package implementation and again during calibration. The invocation documents must not invent undocumented flags or assume that Codex and Claude Code expose identical lifecycle semantics.

## Artifact contracts

### `contract.md` per run

Required fields:

- schema version, package digest, task, run, runtime/main model, any distinct goal-evaluator model/provider/configuration digest, invocation version, enforcement-profile identity/configuration digest, approved read/write roots, read-side single-link control, writable alias and protected-exclusion/write-root overlap controls, credential/environment/socket exposure, network and host-brokered external-tool inventory/operation/scope-selector/argument-shape allowlist digests, provenance, and human-approved authority
- Goal and Non-goals
- Constraints and invariants
- observable Acceptance Criteria with a verification method for each
- up to five high-impact Unknown candidates with claim kind, affected behavior/interface, false-assumption failure, related Acceptance Criterion, primary evidence, cheapest falsification probe, route, evidence outcome, terminal status, resolution evidence, and accepted-risk owner when applicable; every candidate must be routed before CP1 approval
- writable target-worktree paths, writable `report.md`, declared temporary/cache paths, permitted commands, read-only contract path, and read-only external probes; scorecard/cohort/arm-summary/generalized-learning paths are never writable by the `/goal` agent
- self-resolve, queue, and stop routing plus immediate hard-stop conditions
- time/turn bounds when the runtime does not enforce them natively
- complete `CP2_READY` conditions
- rollback or safe abandonment path
- CP1 approval record and contract digest

### `report.md` per run

Required fields:

- contract echo-back and any handoff gap
- Decision Log with evidence and Goal/Acceptance-Criterion/invariant/authority mapping
- every implementation-time Unknown with claim kind, affected behavior/interface, false-assumption failure, related Acceptance Criterion/invariant/authority boundary, current evidence and cheapest probe, route, evidence outcome, terminal status, resolution evidence, and accepted-risk owner when applicable
- queued decisions and throwaway-prototype results
- permission, interruption, stop, and re-gating events
- Evidence Packet by Acceptance Criterion, including command, result, and provenance
- each declared time/turn bound, the observed result, and `compliant`, `overrun`, or `N/A`; missing compliance evidence is `UNVERIFIED`, while an overrun is visible at CP2 and makes the task non-qualifying
- explicit `UNVERIFIED` entries for unrun verification
- residual risk and rollback
- `CP2_READY` declaration and a final Session B summary

At `CP2_READY`, the operator freezes `report.md` and records its digest. Session C never writes this file. Independent-review findings, quiz evidence, and final disposition belong to the operator-owned scorecard instead.

Every implementation-time or reviewer-discovered Unknown must have complete claim-kind mapping, routing, evidence outcome, terminal status, resolution evidence, and ownership before `ship`. `supported` or `refuted` is an evidence outcome, never a terminal status; only `resolved` or evidence-backed, human-owned `accepted-risk` is ship-eligible. Session-B refutation of a frozen approved assumption requires `STOP_REQUIRED`; reviewer refutation after `CP2_READY` is `blocks-ship`. For the same Goal, either path uses the next attempt through Checkpoint 1 when an unused run sequence remains; otherwise the human blocks or abandons the task. A missing field is `UNVERIFIED` and blocks the quiz gate and disposition.

### `scorecard.md` per task

Required fields:

- eligibility evidence, screening-log reference, local comparison baseline record, and baseline-match rationale
- a self-contained durable summary of Goal, Non-goals, Acceptance Criteria, invariants, every run's human-approved authority/scope/expiry and prohibited boundaries, major implementation decisions, queued-decision outcomes, all Unknown dispositions, key evidence and provenance, residual risk, rollback, and final behavior
- fixed cohort slot and immutable enrollment evidence; every attempt id/sequence/CP1 outcome and authority/session-start status; every attempt's A1, A2, used-spike, and Checkpoint 1 declared bounds, observations, statuses, and evidence even when CP1 is not approved; every CP1-approved attempt's contract, authority, and package/enforcement/baseline preflight result; and, for each started Session B or launched Session C, its bound outcome, terminal-marker provenance, the observed complete, partial, absent, or `UNVERIFIED` report/Evidence/snapshot state without fabrication, applicable live-match checks, recomputed package digest, driver/reviewer runtime and main model, any distinct goal-evaluator model/provider/configuration digest, same-model/cross-model review mode, and role-specific enforcement-profile identity/configuration, approved roots, read-side single-link and writable alias/protected-overlap checks, credential/environment/socket exposure, network and external-tool operation/scope-selector/argument-shape allowlist digests, and passing-control record ids
- full-burden human attention, its pre-CP1 task-specific subset, a reference to the separate one-time arm setup overhead record, CP2 review time, permission prompts, genuine/false unscheduled interruptions, quiz attempts, and re-gating both per run and cumulatively
- Acceptance-Criterion status summary, handoff gaps, wrong queued decisions, independent-review findings and dispositions, durable fresh-context and blind-first-order evidence for each Session C, every reviewer-discovered Unknown with the same mapping/routing/evidence/accepted-risk fields as implementation-time Unknowns, understanding questions, quiz misses and evidence-reviewed resolutions, residual-risk acceptance, unverified claims, and hard failures
- terminal disposition and the full-burden attention/confidence delta from the same-boundary baseline
- the task-level all-role-bounds result derived as the conjunction across every applicable bound in every attempt, and the comfort-criteria result derived as `qualifying` if and only if the task is comfort-eligible, every hard gate is clear, and every required comfort check passes; any contradictory literal invalidates the rollup
- local abstraction candidates plus retention/cleanup status

The scorecard and advancement thresholds are operator material. Only the operator creates or updates scorecard, cohort, company-arm, and generalized-learning records. Agent invocation documents receive only the approved contract and do not copy those thresholds. This is a best-effort context boundary, not secrecy: an agent working in this repository could still read the tracked policy.

### Company-arm summary

Created once, after both Work tasks reach terminal disposition, from task-level rollups. The allowlist is:

- `schema_version`
- `package_digest`
- runtime family
- completed task count
- whether all Work hard gates remained clear
- count of Work tasks satisfying all comfort criteria
- whether at least one Work task reached `ship`

It contains no task/run/repository identifier, order, date, timestamp, path, raw metric, context-linked failure reason, or reconstructable combination. Its Work-local receipt derives fixed slots 1 and 2 and no-replacement validity from screening-entry and terminal-scorecard digests, then derives the completed count, all-hard-gates value, comfort-qualifying count, and `ship` value from exactly those two immutable terminal scorecards; a mismatch blocks issuance and transfer. The same receipt derives approved-summary mode eligibility from a complete provenance-bound Work-local history scan: any prior Work hard failure or incomplete scan makes the mode ineligible because the required acknowledgement cannot cross in the seven-field payload, so the payload remains unissued and comparison moves in place. The derivation evidence remains Work-local. Private first issues a random current-schema/package single-use challenge. Work atomically transfers only the unchanged seven-field payload and an exact challenge-bound envelope containing only version, purpose, schema/package, payload hash, and challenge through an authenticated company-permitted path. Private verifies sender/channel provenance, challenge freshness, schema/package, payload hash, atomicity, and replay absence before consuming the challenge; otherwise the human performs the final comparison in place.

### Generalized-learning statement

Required fields:

- generally applicable phenomenon
- applicability conditions
- proposed shared rule
Approval and reconstructability results remain only in the separate Work-local receipt; they are not part of the transferable payload. The statement contains no Work task/run link, timing association, repository detail, internal convention, Skill/prompt detail, raw measurement, or context-specific reason. Ambiguous statements remain on Work.

### `cohort.md` Private decision record

The template has two mutually exclusive modes:

- `approved-summary`: record schema/package identity, the two fixed-slot local Private task ids/enrollment evidence, their immutable terminal rollups, receive-side integrity/freshness/single-use verification, the approved company-arm summary, complete Private-local prior-hard-failure history and acknowledgement, and a locally derived advancement gate over exactly two Private and two Work terminal tasks. The gate passes only when the history scan is complete, any prior Private hard failure has a verified remediation acknowledgement, all four hard gates are clear, at least three tasks are comfort-qualifying, and each runtime has at least one `ship`; `advance` is permitted only when it passes, while `revise and rerun` or `stop` remain available. This mode is unavailable when Work-local history is incomplete or contains a prior hard failure.
- `in-place-no-transfer`: record only the schema/package identity, two local Private task results, `work_comparison: completed_in_place`, `awaiting_external_decision`, and shared-Skill authorization `false`. The Work-local receipt derives the same four-task gate and permits `advance` only when retention, completed comparison, fixed-slot/no-replacement, any required prior-hard-failure acknowledgement, every gate predicate, and source consistency all pass; the actual predicates and decision remain Work-local and never transfer. A separately timed generalized-learning statement may cross only through its independent abstraction gate; it is not a cohort result, proxy decision, or authorization. Private cannot start or claim the shared Skill phase without a separately approved decision artifact and channel.

Neither mode contains Work task/run identifiers or raw Work metrics. The operator must not infer and persist Work results by subtracting known Private values from combined values in `in-place-no-transfer` mode.

## Measurement definitions

- Each environment maintains an operator-owned local `screening.md` in candidate-arrival order, including every considered candidate, eligibility result, and exclusion reason. Once calibrated, the first two eligible candidates irreversibly occupy local arm slots 1 and 2; no outcome permits replacement. Excluded candidates are not silently omitted.
- Baseline matching uses a fixed local rubric. The operator assigns one dominant class (`behavior-or-external-contract`, `architecture-or-cross-module`, or `security-data-or-invariant`) and one scope tier (`single-component` or `cross-component`). The baseline is the most recently completed eligible thick task in the same environment/runtime, class, scope tier, and normal review/delivery workflow within the previous ten eligible tasks or 90 days; there is no discretionary cherry-pick among matches.
- Before task-specific discovery, the baseline record stores the local source reference, observed full-burden attention minutes under the same boundary, source/assumptions, and a confidence anchor from 1 to 5: `1` cannot dispose, `2` low confidence, `3` can dispose with material uncertainty, `4` can explain behavior/invariants/decisions/risk/rollback with minor uncertainty, and `5` can defend those claims from evidence. If no historical match exists, a prospective attention range and confidence anchor are recorded before discovery, but that task is diagnostic and cannot count toward the three-of-four comfort gate. The baseline cannot be replaced after discovery starts.
- At terminal disposition, attention is `lower` when measured full-burden attention is at most 90% of the same-boundary historical baseline, `same` when it is greater than 90% and less than 110%, and `higher` when it is at least 110%. Confidence compares the terminal 1–5 anchor with the fixed baseline anchor. Estimated-baseline tasks report deltas diagnostically but never qualify.
- The advancement metric is full-burden task-specific human attention. It starts with the first prospectively recorded screening or preparation activity for the candidate that becomes enrolled and ends at terminal task disposition. It includes candidate screening, baseline selection, per-task package/profile checks, worktree capture, discovery, contract/template preparation, session startup, CP1 review, later handoffs, permission-prompt handling, all scheduled and unscheduled human turns, every CP2 attempt, and re-gating across runs. Unrelated interruptions pause active-time measurement.
- The pre-CP1 task-specific portion is recorded separately only as a subset and is included exactly once in full-burden attention. One-time arm setup, package authoring, and both-runtime calibration are recorded as pilot overhead but are not attributed to a task or historical comparison.
- CP2 active review time starts when the complete frozen Evidence Packet and quiz are presented and ends when `ship`, `narrow`, `redirect`, or `block` is recorded. Unrelated interruptions pause the timer, and task-level CP2 time sums every attempt.
- An unscheduled decision interruption is any human decision request between the first CP1 approval and terminal disposition, including a justified hard stop. Execution-permission prompts for contract-authorized operations are counted separately, but their handling time remains part of human attention. Each interruption is classified locally as genuine or false after disposition.
- A task is comfort-qualifying if and only if it has an eligible historical baseline, every hard gate is clear, cumulative full-burden attention is lower than that baseline, confidence is equal or higher, cumulative CP2 active review is at most 20 minutes, the quiz gate passes, and cumulative unscheduled decision interruptions are at most one. The scorecard derives this result from those inputs; a contradictory entered result is invalid.

## Task bounds and hard-pause lifecycle

Week 0 uses fixed outer bounds so cumulative measurement does not become an excuse for an indefinitely running task:

- Session A1 has one 20-minute discovery pass.
- Session A2 has the ADR-defined single 10-minute blind-spot pass.
- A pre-CP1 throwaway spike is optional, evidence-only, and limited to one 20-minute attempt.
- Every Session B contract contains an explicit implementation time or turn bound approved at CP1; an unbounded contract cannot be approved.
- Session C has one 20-minute independent-review pass per run. A timeout leaves review incomplete and blocks `ship`.
- A task may have at most two run attempts beginning at first CP1 presentation, allowing one same-intent re-gate. A pre-approval `narrow` consumes an attempt even though Session B never starts. If attempt 2 cannot reach terminal disposition, the task ends as `block` or abandonment and remains non-qualifying in the cohort; a third attempt is prohibited.
- Each run has one CP1 active-review window of at most 20 minutes and at most two packet presentations. Failure to approve, narrow, or block within either limit ends the task as `block` or abandonment.
- Each CP2 has at most two quiz-answer rounds and a 30-minute active-review hard cap. The existing 20-minute value remains the comfort qualification threshold; reaching 30 minutes without a resolved disposition forces `block`. Unrelated interruptions pause both timers.
- Every attempt records A1, A2, each used spike, and Checkpoint 1 bound evidence whether or not CP1 approves authority; each started Session B and launched Session C adds its own bound evidence. Task-level all-role-bound compliance is the conjunction over all applicable records in every attempt, so one `overrun` or `UNVERIFIED` result cannot be erased by a later successful attempt.

Each runtime invocation maps its current goal lifecycle to `ACTIVE`, `CP2_READY_WAIT`, operator-recorded `INTERRUPTED_NO_MARKER`, and terminal task disposition. At `CP2_READY_WAIT` the implementation agent must yield and cannot continue without a new human turn. If the runtime cannot safely leave a goal waiting, the narrowly scoped run goal is completed as "produce a frozen CP2-ready packet" while the task remains active in the operator scorecard. A runtime/host interruption suspends authority; the same attempt and authority may resume only when calibrated identity, transcript, frozen contract/authority, counters, timer, token accounting, and evidence continuity are all observed and recorded. Otherwise authority expires and the run ends as `INTERRUPTED_NO_MARKER`: freeze only observed partial evidence, launch no Session C, and preserve absent or failed final-collector fields. Before any next attempt or terminal aggregation, a separate identical-collector reconciliation against the frozen pre-B baseline must reach `reconciled-clear`; unverified reconciliation blocks or abandons, and a Session-B-caused protected or out-of-authority delta enters `PAUSED_HARD`. A normal redirect uses the same attempt-cap rule. This mapping is observed in end-to-end rehearsal rather than inferred from product names.

A hard failure uses the following state machine:

```text
ACTIVE
  |
  v
PAUSED_HARD -> freeze/digest local evidence; stop cohort and transfers
  |
  v
DIAGNOSE -> record cause and affected controls locally
  |                         |
  v                         v
STOPPED               REVISED_POLICY
                            |
                            v
                 CONTROL_RECHECK + E2E REHEARSAL
                            |
                            v
                  BOTH-RUNTIME RECALIBRATION
                            |
                            v
                    HUMAN RESUME APPROVAL
                            |
                            v
                       NEW COHORT
```

- Information-boundary incidents follow company/security policy and remain in their originating environment; no incident detail is moved merely to justify resumption.
- Resumption requires an explicit human record of the remediation and passed affected controls. Starting a new cohort alone does not clear the earlier failure.
- The prior failure remains in pilot history. Any later `advance` decision must explicitly acknowledge it and cite the generalized remediation evidence; ambiguous remediation results in `stop`.

## Implementation phases

### Phase 1 — Author the tracked Week 0 package

Tasks:

1. Create `docs/outer-loop/week0-v1/` with the seven planned Markdown files.
2. Put normative runtime-neutral rules, Unknown routing, measurement/baseline definitions, task/checkpoint bounds, enforcement-profile drift handling, and hard-pause state machine in `policy.md`; link to ADR 0030 rather than copying rationale.
3. Put operator sequence, state lifecycle, session topology, cleanup, and pause/resume procedure in `README.md`.
4. Define blank, copyable screening/contract/report/self-contained task-scorecard/company-arm/two-mode cohort-decision/generalized-learning templates in `artifact-templates.md`.
5. Create thin Codex and Claude Code invocation documents that accept an approved contract and target `CP2_READY` without evaluator thresholds.
6. Create seven generalized calibration cases covering self-resolve, queued preference, contract-change stop, security/authority stop, an actually claimed false pass, an honestly recorded `UNVERIFIED` completion, and redirect/retry accounting.
7. Add a traceability table mapping every normative ADR 0030 requirement to one package section.
8. After the other six files stabilize, calculate their SHA-256 values and the sorted package digest into `manifest.md`; record the source revision outside the digest to avoid self-reference.

Done when:

- The package contains no task, repository, company, or machine-specific data.
- Each rule has one authoritative package location.
- Agent invocation documents contain no advancement thresholds or company-arm fields.
- `manifest.md` reproduces the package digest, and modifying any covered file produces a mismatch.
- No executable, Skill, hook, workflow, runtime configuration, or generated state is added.

### Phase 2 — Rehearse Private local state and artifact flow

Tasks:

1. Select a Private durable state root outside repositories and synchronized folders that can retain task scorecards through the final cohort decision.
2. Configure an existing runtime/OS default-deny profile for the planned read/write roots without adding a persistent pilot adapter.
3. Run role-specific safe sandbox negative controls for A1, A2, B, C, and spike-temp against disposable sentinels and a fixture repository, including outside-root, symlink-alias, and approved-root hard-link-alias reads; direct outside-root writes; writes through in-root symlink and hard-link aliases to outside sentinels; symlink/hard-link creation; each protected-descendant write/delete/rename/link/replacement mutation inside writable roots; credential-source reads; undeclared egress; each host-brokered write channel; and every enabled brokered read operation with an unapproved value on every applicable account/tenant/repository/resource/destination selector axis and a disallowed argument/request shape. Confirm relevant target/source/replacement pre/post digests, that secret-bearing environment variables and credential/keychain/agent sockets are unavailable to role tools, require complete per-control evidence rather than asserted enums, and block the Private arm if any prohibited request, mutation, read, or disclosure is allowed or only detected afterward.
4. Create a disposable fake task with two fake runs using private temp input/output directories and a task-level scorecard.
5. Verify pre-CP1 worktree read-only behavior, directory/file permissions, main/evaluator identity recording and drift detection, identical pre-B/final canonical collection, protected secret/Git/symlink/multiply-linked exclusions, protected-exclusion/write-root overlap rejection or exact deny overlay, contract/report/Evidence and snapshot digests, derived live-match evidence, contract and frozen-report immutability, raw-artifact cleanup, and the self-contained scorecard's independence from deleted temp files, including retained authority and expiry facts.
6. Exercise same-intent redirect accumulation and material-Goal-replacement accounting.
7. Exercise simulated safety and gate fixtures without performing a real prohibited operation: an attempted fixture Git mutation, suppressed required stop, actually claimed unverified pass, honestly surfaced `UNVERIFIED` packet, unresolved quiz miss, failed Acceptance Criterion, refuted approved assumption, blocked or unresolved Unknown, incomplete/digest-mismatched canonical snapshot, post-review worktree drift, unresolved queued decision, incomplete Session C review, and unresolved `blocks-ship` finding. The first three hard-fail and pause; the honest `UNVERIFIED` packet may reach `CP2_READY` but rejects `ship`; the remaining failed gates reject `ship` and use the policy-defined next attempt only when one remains. Also prove that a CP1-unapproved attempt retains A1/A2/spike/CP1 bounds, a later success cannot erase an earlier overrun or `UNVERIFIED` bound, contradictory comfort literals are invalid, and each failed advancement predicate rejects `advance`.
8. Confirm the fixture and target worktree HEAD, index, refs, stash, branch/worktree metadata, global config, credential sources, secret-bearing environment exposure, credential/keychain/agent sockets, services, databases, undeclared egress, and external state remain unchanged or unavailable as required.

Done when:

- All fake-run measurements roll up to one task without losing prior-run cost.
- Every hard-failure fixture pauses the fake pilot, while an unresolved quiz miss without another hard-failure trigger rejects `ship` without incorrectly entering `PAUSED_HARD`.
- Every prohibited-operation negative control is denied before mutation or disclosure, not merely found by post-run inspection.
- Only declared disposable locations are written.
- The rehearsal produces no committed or retained fake run data.

### Phase 3 — Establish Work prerequisites locally

This phase runs on the Work machine and records no Work-specific result in this repository.

Tasks:

1. Confirm a company-approved, non-shared, non-synchronized durable scorecard root that can retain task scorecards through the final cohort decision, plus the raw-artifact retention policy.
2. Confirm whether the generic package may be transferred through an approved path or must be manually recreated and reviewed on Work.
3. Recompute the Work package manifest and require exact schema/package-digest agreement. Manual recreation requires a Work-local human attestation against every manifest entry; inability to match blocks the Work arm.
4. Confirm a company-permitted independent-review runtime; default to a fresh same-runtime reviewer when no approved cross-model reviewer is available, and record the mode.
5. Configure and verify the same role-specific default-deny sandboxes, enforcement identities/digests and drift response, pre-CP1/reviewer read-only, permission, immutability, cleanup, and prohibited-write controls as the Private rehearsal.

Done when:

- Storage and retention are locally approved and meet the scorecard minimum through the final cohort decision.
- The Work copy has the same schema version, package digest, manifest entries, and generalized calibration scenario ids.
- No Work path, policy, or raw validation evidence is copied to Private.
- If any prerequisite is unavailable, the Work arm remains blocked rather than weakening the boundary.

### Phase 4 — Run cross-runtime calibration and end-to-end rehearsal

Tasks:

1. Verify the schema and package digest before starting either environment.
2. Run the seven generalized routing scenarios independently on both machines.
3. Record runtime/main-model/invocation versions, any distinct goal-evaluator model/provider/configuration digest, package digest, every role-specific enforcement-profile identity/configuration digest and passing-control record, and classifications locally.
4. Compare only schema version, package digest, scenario id, and route classification across environments.
5. Require exact agreement on hard `self-resolve`, `queue`, and `stop` routes.
6. On each runtime, use a disposable fixture worktree to rehearse one complete success path through A1/A2, CP1, Session B `/goal`, frozen `CP2_READY`, read-only Session C, quiz, CP2 timing, operator scorecard update, and terminal `ship`.
7. On each runtime, rehearse one same-task redirect path, including frozen report/change-snapshot/evidence digests, the calibrated goal close/wait behavior, the next run under the same task id, cumulative metrics, and the two-attempt terminal bound; also verify a pre-approval CP1 `narrow` consumes an attempt and cannot create an unrecordable third attempt.
8. Rehearse both interruption branches before a terminal marker: a calibrated Codex case with fully observed continuity remains the same attempt and records the event, while a missing/ambiguous-continuity case records `INTERRUPTED_NO_MARKER`, marker provenance `NONE`, and only observed partial evidence. Verify that the latter launches no Session C or `ship`, preserves missing final-collector fields, and requires a separate baseline-to-current reconciliation before any unused next attempt; collector/attribution failure blocks or abandons, a Session-B-caused protected or out-of-authority delta hard-pauses, and the same interruption on attempt 2 never creates attempt 3. Claude resume always uses the latter attempt-ending path because its documented counters reset.
9. If any hard route, package identity, sandbox control, artifact ownership, or goal lifecycle differs, revise the policy/package, increment the schema, repeat affected controls and both calibrations, and do not begin a real task.

Done when:

- Every hard route matches.
- Both machines record the same current schema version and package digest.
- The exact local `/goal` lifecycle needed to reach `CP2_READY` has been observed rather than inferred.
- Both runtimes complete success and redirect rehearsals with Session B stopped at `CP2_READY`, frozen implementation evidence, read-only Session C, and operator-owned review/quiz/disposition.
- No fixture or rehearsal artifact remains in a repository or is mistaken for a real cohort task.

### Phase 5 — Execute the four-task advancement cohort

The cohort is fixed to the first two eligible Codex candidates and first two eligible Claude Code candidates in each arm's screening arrival order under one schema version. Eligibility irreversibly assigns slots 1 and 2; a later block, abandonment, Goal replacement, estimated baseline, overrun, hard failure, or other adverse result never permits substitution.

For each task:

1. Append the candidate to the environment-local screening log in arrival order, apply the eligibility/exclusion checklist, and record either the exclusion reason or the eligible task id; immediately assign the next immutable slot when one of the arm's first two candidates is eligible.
2. Start prospective task-specific attention recording when screening begins for a candidate that becomes enrolled. Apply the fixed class/scope/recency rubric, freeze the required same-boundary historical attention and confidence anchor before discovery, and mark a no-history estimate as diagnostic/non-qualifying; retain pre-CP1 time as an included subset and one-time arm setup as separate overhead.
3. Recompute the covered-file hashes and package digest against the canonical manifest and last calibrated digest; compare A1/A2/spike runtime/main-model and distinct evaluator identity, role profiles, roots, read-side single-link and writable alias/protected-overlap controls, credential/environment/socket exposure, network enforcement, and brokered-tool operation/scope-selector/argument-shape allowlist digests with their passing controls; rerun controls on drift; then snapshot the pre-discovery worktree state, run bounded read-only discovery and blind-spot review, keep any spike in the declared private temporary path, record their bound evidence, and verify the worktree snapshot is unchanged.
4. Present the contract, Unknown evidence and routing for every candidate, at most three plan-changing questions, authority, rollback, and explicit bounds at CP1; start run attempt 1 at this first presentation while continuing the already-active task attention window, and enforce the 20-minute/two-presentation CP1 limits.
5. After approval, recompute and verify the package digest against the manifest and last calibrated digest, freeze the contract read-only, record schema/package/contract and current B-role runtime/main-model and distinct evaluator identity, enforcement identity, canonical lexical/resolved roots, read-side single-link and writable-path symlink/hard-link/protected-overlap controls, credential/environment/socket exposure, network enforcement, and brokered-tool operation/scope-selector/argument-shape allowlist digests, compare them with the last passing control, and rerun negative controls on any drift before launching fresh Session B with `/goal`; only `report.md`, approved worktree paths, and declared disposable paths are writable by the agent.
6. Require echo-back before editing. Treat missing information as a handoff gap and stop.
7. Route decisions through self-resolve, queue, or stop; record each implementation-time Unknown with the full mapping/routing/evidence/owner fields, plus permission/interruption events and bound compliance.
8. Reach `CP2_READY` only with a complete review packet, queued decisions, risk, rollback, time/turn compliance, and explicit `FAIL`/`UNVERIFIED` entries; these honest statuses do not claim ship success. Use `STOP_REQUIRED` for the policy truth-table conditions.
9. At `CP2_READY`, stop Session B, freeze `report.md` and Evidence Packet, build the canonical CP2 change snapshot, and have the operator record all component/aggregate digests plus the durable Goal/AC/invariant, authority, decision, Unknown, evidence/provenance, residual-risk, rollback, and final-behavior summaries in the scorecard. The frozen report is never reopened. A post-freeze fix uses the next attempt through Checkpoint 1 only when an unused run sequence remains; otherwise the task is blocked or abandoned.
10. Recompute the package digest against the last calibrated digest, compare the C-role runtime/main-model and distinct evaluator identity, enforcement identity, roots, read-side single-link control, credential/environment/socket exposure, network enforcement, and brokered-tool operation/scope-selector/argument-shape digests with its passing control, and rerun controls on any drift, then run fresh blind-first Session C with read-only inputs. Session C verifies snapshot completeness/digest before review. The operator records durable evidence of the fresh context and Goal/AC/snapshot/verification-before-Decision-Log order, plus findings, understanding questions, and every reviewer-discovered Unknown with the full mapping/routing/evidence/owner fields; Session C writes no worktree or pilot artifact.
11. Recheck live state against the frozen snapshot, present the packet and quiz, and start the CP2 timer. Resolve every quiz miss from evidence within at most two answer rounds and record `ship` only when the full ship gate passes, including snapshot identity, Session C freshness, and blind-first evidence; otherwise record `narrow`, `redirect`, or `block`. Recheck again before delivery. Unrelated interruptions pause the timer, 20 minutes is the qualification threshold, and 30 minutes without disposition forces `block`.
12. A same-intent `narrow`, `redirect`, or post-freeze fix loops through the next run attempt under the existing task id, subject to the two-attempt maximum counted from first CP1 presentation. Roll every attempt's A1/A2/used-spike/CP1 bounds plus started B and launched C bounds, all metrics, and all failures into the task scorecard; derive all-role-bound compliance and comfort qualification from the complete ledger, so a new attempt never resets or hides an earlier value.
13. Close or replace the runtime goal according to the calibrated lifecycle mapping before any normal delivery action.

The pilot pauses immediately for an information-boundary breach, ignored hard stop, suppressed required question, unauthorized operation, unverified pass claim, bound ignored after a required stop, or merge/deploy inside a pilot run. No later cohort task starts until the hard-pause state machine reaches explicit human resume approval.

### Phase 6 — Aggregate and decide

Tasks:

1. Verify that all four task scorecards use the same schema and package digest; mismatched results are never pooled.
2. Finalize the two Private task summaries locally.
3. After both Work tasks terminate, recompute the canonical package digest, verify both immutable fixed-slot task scorecards used it, derive and verify the single company-arm summary from exactly those two scorecards, derive approved-summary eligibility from Work-local prior-hard-failure history, and human-review the unchanged seven-field payload on Work including that non-sensitive digest. Keep all source and eligibility evidence Work-local; a prior Work hard failure keeps the payload unissued.
4. Choose exactly one cohort-record mode. In `approved-summary` mode, verify the Work-local receipt derives both fixed slots and no replacement from screening/scorecard digests and proves no prior Work hard failure; have Private issue a single-use current-schema/package challenge; atomically transfer the seven-field summary and canonical challenge-bound envelope through an authenticated permitted path; and require Private sender/channel, challenge, schema/package, payload-hash, atomicity, and replay checks before consuming the challenge. Any failure or prior Work hard failure requires `in-place-no-transfer`, where comparison stays in place and no Work-derived counts, coverage, gates, or combined evidence are copied to Private.
5. Derive the advancement gate from exactly two immutable Private terminal fixed-slot rollups and the verified two-task Work summary, derive any prior Private hard-failure acknowledgement from Private-local history, and require that acknowledgement plus all four hard safety gates to be clear.
6. Derive the total comfort count from the exact task predicate and require at least three qualifying tasks; reject a contradictory entered count or task result.
7. Derive runtime coverage and require at least one Codex task and one Claude Code task to have completed approved scope and reached `ship`.
8. Permit a human `advance` only when the full derived gate, including the applicable local prior-hard-failure acknowledgement, passes. Record `advance`, `revise and rerun`, or `stop` on Private only in eligible `approved-summary` mode; in `in-place-no-transfer` mode, derive the same gate and require Work-local retention, completed comparison, fixed-slot/no-replacement, any required prior-hard-failure acknowledgement, every gate predicate, and source consistency to pass before `advance`, retain the predicate results and decision receipt on Work, keep Private `awaiting_external_decision`, and do not authorize the shared Skill phase there without a separately approved decision artifact and channel. A generalized-learning statement remains independent and cannot serve as the decision or a proxy for it.
9. If the schema/package changed during the cohort, preserve the observations, repeat affected enforcement and end-to-end controls, recalibrate both runtimes, and begin a new four-task cohort rather than pooling versions.
10. If any earlier cohort hard-failed, a later `advance` additionally requires the explicit remediation and human-resume record from the hard-pause state machine; the new cohort alone does not erase the failure.
11. If advancing, continue safety observation through approximately the first ten eligible thick changes before treating the loop as established.

## Validation matrix

| Area | Positive control | Negative control / expected result |
|---|---|---|
| Eligibility | Observable local AC, rollback, non-emergency thick change is accepted | Mechanical, incident, irreversible, AC-less, or shared-state-dominated work is rejected |
| Candidate/cohort/baseline | First two eligible candidates irreversibly occupy slots; screening time is prospectively recorded, and every fixed class/scope/recency match includes same-boundary full-burden historical attention and confidence before discovery | Hidden pre-CP1 burden, silent exclusion, unmatched estimate counted as qualifying, or any post-outcome replacement invalidates the cohort |
| Pre-CP1 boundary | A1/A2 leave the worktree baseline unchanged and spike only in private temp | Any pre-approval worktree mutation blocks CP1 |
| Contract | Schema/package/contract identity remains unchanged for one run and every pre-/in-/post-implementation Unknown has mapping, route, evidence, and owner | Required contract edit uses an available next attempt or blocks/abandons; any unrouted or unsupported Unknown blocks CP1 or `ship` |
| Handoff | Fresh session echo-back matches Goal, AC, invariants, authority, and stops | Missing field records a handoff gap and no implementation starts |
| Decision routing | Local reversible evidence-backed choice self-resolves | Contract/security/data/authority boundary stops immediately |
| Bound compliance | Every attempt preserves A1/A2/used-spike/CP1 evidence and every started B/launched C bound; task compliance is their conjunction | Missing evidence is `UNVERIFIED`; one ignored stop or overrun remains visible and cannot be erased by a later attempt |
| Evidence | Every AC has command/result/provenance and frozen digest | Missing verification is `UNVERIFIED`; pass claim pauses pilot |
| Report and snapshot ownership | Operator freezes an identical pre-B/final reviewable snapshot; protected secret/Git/symlink paths remain content-free; Session B report freezes and Session C is read-only | Missing baseline, protected metadata change, secret disclosure, omitted path state, digest mismatch, or later live drift blocks use of the old review |
| Quiz | All misses are resolved from evidence before disposition | Unresolved miss blocks `ship`; foundational miss redirects to CP1 |
| Task/run accounting | Redirected runs accumulate attention/time/interruptions under one task | New run cannot erase a prior hard failure or replace a non-qualifying task |
| Task bound | One attempt or one permitted re-gate reaches terminal disposition within CP1/quiz/CP2 limits; pre-approval narrow consumes an attempt | Attempt 3, quiz round 3, or unresolved CP1/CP2 hard-cap overrun ends `block`/abandonment |
| Sandbox enforcement | A1/A2/B/C/spike runtime/evaluator identity, roots, single-link reads, symlink-free/single-link writes, five-operation protected-overlap controls, credential/environment/socket exposure, network and brokered operation/scope-selector/shape allowlists, and profile/config digests match evidence-backed controls before every session | Outside-root, symlink-alias, or hard-link-alias reads; protected write/delete/rename/link/replacement or aliased writes; link creation; credential reads; undeclared egress; brokered writes; and brokered reads using an unapproved value on any applicable selector axis or a disallowed shape are denied before disclosure/request/mutation; asserted pass or drift blocks the session |
| Independent review | Scorecard proves Session C recomputed the canonical exact-byte review-bundle digest for the complete reviewable snapshot plus aggregate protected-unchanged attestation, while the operator separately proves full local snapshot/protected-metadata equality; it also proves fresh context and Goal/AC/snapshot/verification review before the Decision Log | Protected detail exposure or missing/failed bundle, local equality, freshness, or order evidence blocks `ship` |
| Storage | Protected temp state plus a self-contained durable scorecard survives raw deletion through cohort decision | Shared/synchronized/unapproved path or digest-only scorecard blocks execution/cleanup |
| Information boundary | One allowlisted Work arm summary passes human and receive-side integrity/freshness/single-use review | Tampered, stale, replayed, unauthenticated, or reconstructable content falls back to in-place comparison |
| No-transfer mode | Private stores no Work-derived count, coverage, gate, or combined evidence | Subtracting Private values to reconstruct Work results is prohibited |
| Derived aggregation | Work derives its seven fields and approved-summary eligibility from exactly two terminal fixed slots plus Work-local prior-failure history; Private or Work-in-place derives the four-task gate from exact terminal inputs, fixed-slot/no-replacement, retention, comparison, applicable prior-hard-failure acknowledgement, and source-consistency evidence | Prior Work failure blocks summary issuance; any source-count, hard-gate, comfort-count, runtime-coverage, fixed-slot, acknowledgement, prerequisite, or entered-result contradiction blocks transfer and `advance` |
| Package identity | Covered hashes are recomputed before A/B/C, Work summary attests the canonical digest, and two plus two tasks match it | Manifest/calibrated-digest mismatch blocks the session or pooling and starts a new calibrated cohort |
| Pause/resume | Hard failure freezes evidence and requires control recheck, both-runtime calibration, and human approval | Starting a new cohort alone cannot clear the paused state |
| Prompt isolation | Invocation receives approved contract and `CP2_READY` target | Evaluation thresholds and company-arm fields are absent from invocation |

Document-only package verification includes:

- `git diff --check`
- confirmation that only the planned documentation paths changed
- link and schema-version consistency review
- reproducible per-file hashes and package digest from `manifest.md`
- manual ADR-to-package traceability review
- inspection that runtime invocation documents contain no advancement-only fields and do record any distinct goal-evaluator identity required for drift detection

## Definition of Done

The implementation plan is complete when this document is reviewed and accepted. Week 0 package implementation is complete when Phases 1–4 pass on both runtimes, including manifest agreement, default-deny negative controls, success/redirect end-to-end rehearsals, and calibrated goal lifecycle, without creating automation or real task artifacts in the repository. The pilot is complete only after Phases 5–6 reach a recorded decision under the ADR 0030 criteria.

No Skill implementation begins merely because the templates exist. It begins only after a passing pilot decision and a separate design/plan for the Skill phase.

## Environment-local prerequisites

The following are intentionally resolved on the Work machine and are not copied back as raw details:

- approved durable state location and retention/deletion policy
- approved route for bringing in the generic schema or a decision to recreate it locally
- ability to reproduce and attest the canonical package manifest
- an existing runtime/OS default-deny profile that passes the prohibited-write controls without installing a pilot adapter
- approved reviewer/runtime availability
- exact current Claude Code `/goal` lifecycle and effective distinct evaluator identity/configuration

On the Private machine, the exact current Codex `/goal` lifecycle is verified during calibration. The plan intentionally depends on observed runtime behavior and recorded version, not on an assumed permanent command syntax.

## Risks and rollback

| Risk | Response |
|---|---|
| The manual package becomes a proto-Skill with hidden automation | Keep all package files Markdown-only and reject executables/config/hooks during Week 0 |
| Separate files or machines drift | One versioned directory, explicit cross-links, per-file manifest, package digest, and exact pre-calibration comparison |
| Policy-only write boundaries fail under the same OS user | Require default-deny runtime/OS enforcement and safe negative controls before either pilot arm starts |
| Evaluator targets influence agent behavior | Do not copy them into contract or invocation; treat required-question suppression as a hard failure rather than relying on secrecy |
| Manual measurements are inconsistent | Fixed field definitions, cumulative task accounting, and rehearsed positive/negative controls |
| Work data becomes identifiable through timing or combinations | No run-level transfer; one delayed company-arm summary; human reconstructability check; in-place comparison fallback |
| No-transfer mode leaks Work results through combined values | Keep Work-derived counts/evidence and the decision receipt on Work; Private remains awaiting an independently approved decision artifact, and generalized learning is never a proxy |
| Runtime `/goal` behavior changes | Record runtime, main-model, distinct evaluator, and invocation identity; recalibrate after material changes |
| Temporary evidence disappears too early | Durable task scorecard remains self-contained; retention is confirmed before a task starts |
| The pilot feels comfortable but has not exercised success | Require at least one `ship` from each runtime before advancement |
| Baseline selection makes improvement look better than it is | Fixed class/scope/recency tie-break, historical attention/confidence anchors, and non-qualifying estimated baselines |
| Checkpoint loops recreate full-time supervision | Fixed CP1 presentations/time, quiz rounds, CP2 hard cap, and two-attempt task maximum that includes pre-approval narrowing |

Rollback for the Week 0 package is deletion or reversion of the tracked Markdown package and removal of local pilot state according to environment policy. Because Week 0 installs no runtime integration and performs no in-goal delivery operations, rollback does not require uninstalling a Skill, hook, workflow, or service.

## References

- [ADR 0030](../adr/0030-codex-claude-outer-loop-pilot.md)
- [Own the Outer Loop](https://addyo.substack.com/p/own-the-outer-loop)
- [A Field Guide to Fable: Finding Your Unknowns](https://x.com/trq212/article/2073100352921215386)
- [Getting started with loops](https://claude.com/ja/blog/getting-started-with-loops)
- [Codex: Follow a goal](https://learn.chatgpt.com/use-cases/follow-goals)
