# Outer Loop Week 0 Policy v1

Schema: `outer-loop-week0/v1`

This file is the sole normative runtime-neutral policy for the Week 0 pilot selected by [ADR 0030](../../adr/0030-codex-claude-outer-loop-pilot.md). `MUST`, `MUST NOT`, `SHOULD`, and `MAY` are normative. Other package documents provide procedures, blank artifacts, runtime-specific handoffs, or fixtures and MUST NOT broaden this policy.

## Package identity

- The six files listed in [manifest.md](manifest.md) MUST be hashed as exact UTF-8 bytes. Their sorted `digest<two spaces>path` records define the canonical package digest; `manifest.md` excludes itself.
- The operator MUST recompute the covered-file hashes and package digest before calibration and before every A1/A2 discovery pair, Session B, and Session C. They MUST match both `manifest.md` and the last passing cross-runtime calibration.
- A mismatch MUST block the session and pooling. Once either environment calibrates or begins a cohort task, a covered-file change MUST create a new versioned directory, package identity, both-runtime calibration, and four-task advancement cohort. Older observations remain history and MUST NOT be rewritten or pooled.

## Eligibility

Week 0 consists of two Private Codex tasks and two Work Claude Code tasks under one schema and package digest.

A task is eligible only when all of these hold:

- Its scope contains a user-visible or external-contract behavior, cross-module or architectural choice, security/data/invariant concern, or implementation choice whose resolution could materially change the plan.
- Its Acceptance Criteria state observable outcomes verifiable locally.
- A rollback or safe abandonment path can be explained before implementation.
- It is not emergency work.

Typo-only, formatting-only, lockfile-only or generated-file refreshes, other predetermined mechanical changes, production or security incident response, irreversible data migration, Goal discovery without implementable Acceptance Criteria, and work dominated by human-only or shared-state operations MUST be excluded. Every considered candidate and exclusion reason MUST remain in the local screening log in arrival order.

After an arm has passed its prerequisites and calibration, its first two eligible candidates in recorded arrival order MUST be irreversibly enrolled as `cohort_slot: 1` and `cohort_slot: 2` when eligibility is decided. Every terminal or non-qualifying outcome remains attached to that slot. A blocked or abandoned task, material Goal replacement, estimated baseline, overrun, hard failure, or any other adverse result MUST NOT be replaced by a later candidate. Excluded candidates do not occupy a slot. A package change or hard-pause remediation starts a new cohort only through the versioning or resume rules below; it never rewrites an existing enrollment record.

## Identity and provenance

- Each task and run MUST have opaque machine-local identifiers. Work identifiers MUST NOT cross to Private.
- A run attempt begins when its first Checkpoint 1 packet is presented and immediately receives `run_sequence: 1` or `2`, even if approval and Session B never occur. A same-intent `narrow`, `redirect`, retry, or post-freeze fix may create the next run attempt under the same task only when an unused sequence remains. A material Goal replacement terminates the old task as redirected and non-qualifying, then creates a new task.
- A new run MUST NOT erase prior cost, evidence, quiz attempts, re-gating, interruptions, or hard failures.
- Every task MUST record its local arm, immutable cohort slot, enrollment sequence/evidence, and replacement prohibition. Every run attempt MUST record schema version, package digest, task/run ids, sequence, Checkpoint 1 provenance/outcome, and whether authority was approved and Session B started. Every CP1-approved attempt MUST additionally retain the approved contract and authority plus package/enforcement preflight outcome. Only a started Session B run records report, Evidence Packet, and canonical snapshot fields. An unapproved or approved-but-not-started attempt uses its explicit ledger variant rather than fabricating authority or Session B artifacts.

## Artifact ownership

- All pilot state MUST remain outside repositories in approved local, non-shared, non-synchronized state. Durable task scorecards MUST be retained through the final cohort decision. If this cannot be permitted, that arm MUST NOT start.
- Directories and files MUST use protections equivalent to `0700` and `0600`. These modes are OS-user protection and MUST NOT be treated as the agent enforcement boundary.
- The operator alone MAY create or modify `screening.md`, draft contracts and their approval receipts, scorecards, calibration/control records, company-arm summaries, generalized-learning records, cohort decisions, hard-pause/remediation records, and the canonical CP2 snapshot before it is frozen.
- The contract's approved payload MUST be human-approved at Checkpoint 1 and digest-recorded using the template's non-self-referential procedure. The operator's contract-writing authority ends when the completed receipt is appended and the whole contract is frozen; from then on it is immutable and read-only with no writer. A required contract change creates the next attempt only when an unused sequence remains; otherwise the task blocks or is abandoned.
- Immediately before Session B, the operator MUST freeze a canonical baseline snapshot. At `CP2_READY`, the operator MUST stop Session B, freeze the report and Evidence Packet, run the identical collector for final state, and bind baseline and final into one canonical CP2 change snapshot. The pair MUST bind baseline/final `HEAD` and index identities; sorted non-disposable, disposable-exclusion, and protected-exclusion inventories; every reviewable tracked, untracked, or ignored path's baseline/final presence, attribution, type, mode, content digest, and symlink target; and the content or patch needed to review every changed path. Session B MAY modify only `report.md` among pilot artifacts. The operator MUST record every component and aggregate digest before review.
- The canonical collector MUST walk the declared worktree surface directly rather than rely only on `git diff`, `git status`, or the index. It MUST never traverse `.git`, a linked-worktree gitdir, or another Git-control path; Git identities are obtained only through bounded operator metadata queries. It MUST NOT follow symlinks. Before reading any content, it MUST resolve lexical/real containment and apply the Session C approved-read roots plus credential/secret and global deny rules. A denied or secret-bearing path is a protected exclusion: the operator records only an opaque path digest and non-content stat metadata locally, never reads or bundles its content, and never exposes its path or metadata to Session C. Every protected exclusion MUST have identical baseline, final, pre-disposition, and pre-delivery metadata. A change attributable to Session B is an unauthorized operation and triggers `PAUSED_HARD`; other drift, classification failure, or required review content behind that boundary yields `STOP_REQUIRED` and no Session C handoff. For reviewable paths, the collector excludes only digest-recorded declared disposable roots, sorts escaped relative paths bytewise, serializes exact UTF-8/LF records, and preserves reviewable content for every changed path without staging. Manifest and content-bundle digests are bound by the canonical snapshot digest.
- Session C MUST receive only the reviewable read-only snapshots and the aggregate protected-exclusion unchanged attestation, verify that the canonical CP2 snapshot is complete and digest-identical to its input, and MUST NOT modify the target worktree or any pilot artifact. Immediately before human disposition and again before any post-`ship` delivery, the operator MUST rerun the same collector and compare the observed canonical digest and protected-exclusion metadata digest with the frozen expected values. Match results MUST be derived from those digests and recorded with collector provenance; a mismatch blocks use of the old review and requires the next attempt when available, otherwise `block` or abandonment. The operator records reviewer output with separate `reported_by` and `recorded_by` provenance.
- A task scorecard MUST be self-contained enough to explain Goal, Non-goals, Acceptance Criteria, invariants, every run's approved authority/scope/expiry and prohibited boundaries, decisions, Unknown dispositions, key evidence and provenance, residual risk, rollback, final behavior, and terminal disposition after raw run artifacts are deleted.

## Enforcement boundary

Every role MUST run under a demonstrated default-deny runtime or OS sandbox/approval profile with explicit read roots, write roots, credential/environment/socket exposure, and network enforcement.

| Role | Required boundary |
|---|---|
| `A1-discovery` | Target worktree and approved inputs read-only; no pilot-artifact write |
| `A2-blind-spot` | Same as A1; A1 inventory/plan absent |
| `spike-temp` | Target worktree read-only; write only inside one declared private temporary root |
| `B-implementation` | Read frozen contract and approved inputs; write only approved target-worktree paths, `report.md`, and declared disposable temp/cache paths |
| `C-review` | Frozen inputs and target snapshot read-only; no worktree or pilot-artifact write |

Before an arm starts, safe disposable controls MUST demonstrate denial before mutation or disclosure for harmless outside-approved-read-root sentinel reads representing operator state, another repository, home/global configuration, and a symlink-resolved alias; an outside-root write; fixture Git-metadata mutation; operator-artifact write; harmless credential-source sentinel read; undeclared-egress request; and mock external-state write. The launch record MUST also confirm, without recording secret values, that no secret-bearing inherited environment variable or credential, keychain, or agent socket is available to role tools. Each distinct host-brokered tool surface available to the role, including MCP servers, apps, browser control, and connectors, MUST be inventoried and digest-bound; it MUST be disabled or restricted to an explicit read-only operation allowlist, with a safe denial-before-request control for every otherwise write-capable channel. A permission prompt or post-request/mutation/disclosure detection is not a passing denial. Every individual control MUST record its fixture/sentinel, attempted operation, pre-state digest, observed result and exit status, denial stage, post-state digest, log/output provenance, and operator verification. Aggregate `pass` MUST be derived only when every required evidence-backed control passes. Before every role session, the operator MUST compare current profile/config digest, roots, credential/environment/socket exposure, network enforcement, external-tool surface/allowlist digest, and invocation version with that role's passing record.

Tool-visible network access MUST be disabled unless enforcement restricts destinations and request shapes to an approved read-only allowlist and denies undeclared egress before any request or disclosure. If that distinction cannot be enforced, the operator MUST provide approved primary-source material or fixtures.

During a Week 0 run, the agent MUST NOT read credentials; access undeclared egress; write Git index, refs, stash, branch/worktree metadata, or `.git`; stage, commit, push, create a draft PR, change branches/worktrees, merge, deploy, or mutate external state; or write another repository, home/global configuration, credential store, persistent service/database, or undeclared path. A fixture database is allowed only inside a declared disposable root. A permission request MUST NOT override this boundary. Ordinary delivery happens only after a terminal human `ship` disposition, outside the pilot run and under normal repository approvals. `narrow` and `redirect` require the next attempt when available, otherwise `block` or abandonment; neither permits delivery.

## Unknown discovery and routing

Unknown discovery is bounded risk sampling, not exhaustive coverage, and Unknown count MUST NOT be optimized.

- Session A1 gets one bounded pass to inventory assumptions and probe code, primary documentation, and baseline behavior.
- Fresh Session A2 independently inspects Goal, Constraints, Acceptance Criteria, code, primary documentation, and baseline behavior without seeing A1's inventory or plan. Agent agreement is not evidence.
- If A2 produces at least two high-impact `block` or `ask-human` candidates, the operator MUST narrow scope or permit one evidence-only spike before Checkpoint 1.
- After risk reduction, the contract MAY retain at most five specific candidates and at most three questions whose answers could change plan, architecture, contract, or authority. If more remain, the task MUST narrow instead of asking piecemeal.

Every Checkpoint 1, implementation-time, and reviewer-discovered Unknown MUST record:

- claim kind (`approved-assumption`, `risk-hypothesis`, `fact-gap`, or `preference`);
- affected behavior or interface;
- failure if the assumption is false;
- related Goal, Acceptance Criterion, invariant, or authority boundary;
- current primary evidence and provenance;
- cheapest falsification probe;
- route, evidence outcome (`supported`, `refuted`, or `inconclusive`), and status;
- resolution evidence; and
- accepted-risk owner when applicable.

A missing route, evidence outcome, resolution, or required owner is `UNVERIFIED` and blocks Checkpoint 1 approval or `ship`, as applicable. Terminal Unknown status is `resolved` or `accepted-risk`; `blocked` and `UNVERIFIED` are non-terminal. `supported` and `refuted` are evidence outcomes, not terminal statuses. At Checkpoint 1, every retained Unknown MUST be `resolved` or `accepted-risk` with resolution evidence and an explicit human owner; `blocked` or unresolved retained Unknowns prevent approval. If Session B finds evidence refuting a human-approved assumption in the frozen contract, it MUST use `stop` and surface `STOP_REQUIRED`. If Session C finds the refutation after `CP2_READY`, it MUST report `blocks-ship`. For the same Goal, either path uses the next attempt through Checkpoint 1 when available; otherwise the human blocks or abandons. Neither path may relabel the contradiction as resolved inside the frozen run. Refuting a risk hypothesis or closing a fact gap MAY support `resolved` when its impact is fully evidenced. A zero Unknown count is not success.

## Decision routes

An implementation-time decision MUST use exactly one route:

- `self-resolve`: the choice stays inside the contract, is local and reversible, has accessible evidence, and has a known undo path. Record the evidence and mapping.
- `queue`: the choice depends on implicit human preference but can safely wait until Checkpoint 2. Any prototype remains throwaway-only in a declared temporary root and uses at most one 20-minute attempt; it MUST NOT be wired into production code. Before `ship`, the human MUST review the choice and record its terminal outcome, evidence, and an explicit owner for any accepted risk.
- `stop`: the choice requires a contract change; crosses security, data-loss, irreversible, shared-state, or authority boundaries; conflicts with authoritative evidence/provenance; cannot map evidence and justification to Goal, Acceptance Criterion, invariant, or authority; or reaches the third evidence-free repetition of the same failure.

Suppressing a required question or using a weaker route than required is a hard task failure even if the implementation works.

## Checkpoints and evidence gate

- Checkpoint 1 MUST approve Goal, Non-goals, constraints/invariants, observable Acceptance Criteria and verification methods, every retained Unknown route, authority, rollback/safe abandonment, and explicit run bounds. Approval freezes the contract.
- Fresh Session B MUST echo back Goal, Acceptance Criteria, invariants, authority, writable paths, verification, stop conditions, and bounds before editing. Missing or conflicting information is a handoff gap and MUST stop the run.
- Runtime self-declared completion is not Acceptance-Criterion evidence. Every Acceptance Criterion MUST have command/probe, observed result, and provenance. Unrun or unsupported checks MUST be labeled `UNVERIFIED`; an unverified pass claim is a hard task failure.
- Session B reaches `CP2_READY` only when the frozen contract's review packet is complete in `report.md`, all bounds have observed compliance status, queued decisions and explicit Acceptance-Criterion `FAIL` or `UNVERIFIED` items are visible without a pass claim, and risk and rollback are recorded. `CP2_READY` is a scheduled evidence-review handoff and does not mean the ship gate passed.
- Fresh Session C MUST review Goal, Acceptance Criteria, the canonical change snapshot, and verification before the driver Decision Log. It returns blocking findings, evidence gaps, reviewer-discovered Unknowns, and three to five questions about behavior, invariants, major decisions, residual risk, and rollback rather than code trivia.
- Checkpoint 2 MUST review frozen evidence, queued decisions, residual risk, rollback, and the questions before human disposition. Every quiz miss blocks `ship` until evidence resolves it. A foundational miss about Goal, Acceptance Criteria, invariant, or external behavior requires the next attempt through Checkpoint 1 when available, otherwise `block` or abandonment. Any other unresolved miss requires `narrow`, `redirect`, or `block` under the same attempt cap.
- A human MAY record `ship` only when every Acceptance Criterion is `PASS`; every retained, implementation-time, and reviewer-discovered Unknown has a complete evidence outcome and resolution record and is `resolved`, or is `accepted-risk` with that evidence and an explicit human owner; every queued decision has a human-reviewed terminal outcome with evidence and an explicit owner for accepted risk; the scorecard proves the canonical CP2 snapshot is complete, Session C received its exact digest in a fresh context, reviewed Goal, Acceptance Criteria, snapshot, and verification before the driver Decision Log, and completed within its bound; the live worktree still equals the frozen snapshot; every review finding is `resolved` or is `accepted-risk` with resolution evidence and an explicit human owner, leaving no `blocks-ship` finding unresolved; and the quiz gate is `pass`. Any failed condition requires `narrow`, `redirect`, or `block`; it MUST NOT be overridden by runtime completion or a permission prompt.
- `ship`, `narrow`, `redirect`, and `block` are human dispositions recorded in the operator scorecard. An agent MUST NOT infer or record them as final.

Terminal routing is determined by this table:

| Condition | Session B marker | Human consequence |
|---|---|---|
| Complete review packet; every AC result is honestly `PASS`, `FAIL`, or `UNVERIFIED`; no immediate-stop condition | `CP2_READY` | Review proceeds; any `FAIL` or `UNVERIFIED` blocks `ship` |
| Contract/authority/safety/invariant conflict, Session B refutes an approved assumption, required stop, exhausted implementation bound, digest/echo failure, or inability to complete the review packet safely | `STOP_REQUIRED` | Freeze available evidence; disposition, then use the next attempt through CP1 when available or block/abandon |
| A pass is claimed without supporting verification | `STOP_REQUIRED` then `PAUSED_HARD` | Apply hard-failure and resume rules |

## Bounds and lifecycle

- A1: one 20-minute discovery pass.
- A2: one 10-minute blind-spot pass.
- Optional pre-CP1 spike: one 20-minute evidence-only attempt.
- Session B: an explicit CP1-approved time or turn bound; an unbounded contract MUST NOT be approved.
- Session C: one 20-minute pass per run; timeout leaves review incomplete and blocks `ship`.
- Task: at most two run attempts from first Checkpoint 1 presentation, whether or not an attempt reaches approval or Session B. This permits at most one same-intent re-gate. A third attempt is prohibited; failure to reach terminal disposition by the end of attempt 2 ends in `block` or abandonment and remains non-qualifying.
- Checkpoint 1: at most 20 active-review minutes and two packet presentations per run. Failure to approve, narrow, or block ends the task in `block` or abandonment.
- Checkpoint 2: at most two quiz-answer rounds and 30 active-review minutes. Twenty cumulative task-level CP2 minutes is the comfort threshold; reaching 30 minutes without disposition forces `block`. Unrelated interruptions pause timers.

Every role bound MUST have observed `compliant`, `overrun`, or allowed `N/A` evidence. An `overrun` or `UNVERIFIED` bound for any role makes the task non-qualifying; a Session C timeout additionally blocks `ship`. A bound failure is not automatically a hard failure unless the agent ignores a required stop or another hard-failure trigger occurs.

Each runtime MUST have an observed local mapping to `ACTIVE`, `CP2_READY_WAIT`, and terminal task disposition. At `CP2_READY_WAIT`, Session B MUST yield and MUST NOT continue without a new human turn. If safe waiting is unavailable, its narrowly scoped run goal MAY complete as “produce a frozen CP2-ready packet” while the task stays active in the operator scorecard. Restart/resume behavior MUST be rehearsed; a failed or ambiguous resume may create a new run attempt only when an unused sequence remains and prior evidence is preserved. Otherwise the task MUST end in `block` or abandonment; restart MUST NOT create attempt 3.

## Measurement

- The attention window starts when the first Checkpoint 1 packet is presented and ends at terminal task disposition. It includes CP1, post-CP1 handoffs, permission handling, all scheduled and unscheduled human turns, every CP2 attempt, and re-gating across runs. Unrelated interruptions pause active time.
- Pre-CP1 operator/admin effort is recorded separately as diagnostic time.
- CP2 active review starts when the complete frozen Evidence Packet and quiz are presented and ends at `ship`, `narrow`, `redirect`, or `block`; task-level CP2 time sums every attempt.
- An unscheduled decision interruption is a human decision request between first CP1 approval and terminal disposition, including a justified hard stop. Contract-authorized execution-permission prompts are counted separately, but handling time remains human attention. Every interruption is classified locally after disposition as genuine or false.
- All measurements are recorded per run and cumulatively per task. A new run MUST NOT reset them.

Before CP1, the operator MUST assign one dominant class (`behavior-or-external-contract`, `architecture-or-cross-module`, or `security-data-or-invariant`) and one scope tier (`single-component` or `cross-component`). The baseline is the most recently completed eligible thick task in the same environment/runtime, class, scope tier, and normal review/delivery workflow among the previous ten eligible tasks or 90 days. There is no discretionary choice among matches.

The baseline record MUST fix its source, measured attention under this definition, assumptions, and confidence from 1 to 5: `1` cannot dispose; `2` low confidence; `3` can dispose with material uncertainty; `4` can explain behavior/invariants/decisions/risk/rollback with minor uncertainty; `5` can defend those claims from evidence. With no historical match, record a prospective attention range and confidence before CP1; the task is diagnostic and non-qualifying.

At terminal disposition, attention is `lower` at no more than 90% of historical baseline, `same` above 90% and below 110%, and `higher` at or above 110%. Confidence compares terminal and fixed baseline anchors. Unknown and autonomous-step counts are diagnostic only.

## Information boundary

Private and Work run on separate machines with no shared pilot-state store. Raw Work artifacts and review MUST stay on Work. Work architecture, code, diffs, repository paths, internal conventions, internal Skills/prompts, logs, tickets, exact timestamps, task order, raw measurements, and identifiable combinations MUST NOT move to Private. `agmsg` MUST NOT automate cross-boundary transfer.

Only these human-reviewed run-derived artifact types MAY cross through a company-permitted path:

1. One company-arm summary after both Work tasks terminate, containing exactly `schema_version`, canonical non-sensitive `package_digest`, runtime family, completed-task count, whether all Work hard gates remained clear, count of Work tasks satisfying every comfort criterion, and whether at least one Work task reached `ship`.
2. A generalized-learning statement containing only a generally applicable phenomenon, applicability conditions, and proposed shared rule. Its approval and abstraction/reconstructability results MUST remain in a separate Work-local receipt. The transferable statement MUST NOT be linked by content or timing to a Work task, run, or company-arm summary.

Neither may contain task/run/repository identifiers, paths, dates/timestamps/order, raw metrics, context-linked reasons, internal details, or reconstructable combinations. Ambiguity remains local.

For `approved-summary`, Private MUST first generate one random non-identifying single-use challenge for the current schema/package decision and record it as outstanding. Work MUST send the seven-field payload and a separate canonical transport envelope atomically through the authenticated integrity-preserving company-permitted path. The envelope contains exactly envelope version, purpose, schema version, package digest, canonical payload hash, and the Private challenge; it contains no Work-derived fact beyond values already in the payload. Private MUST verify authenticated sender/channel provenance, exact envelope schema, outstanding challenge, schema/package equality, recomputed payload hash, and absence of prior consumption, then atomically mark the challenge consumed. The envelope is integrity metadata, not a third run-derived artifact. Missing, stale, altered, replayed, or non-atomic input MUST NOT be accepted.

Use exactly one final-comparison mode:

- `approved-summary`: Private may store the approved allowlisted company-arm summary and compute the combined human decision only after the challenge/envelope verification above passes. The Work-local receipt, which never transfers, MUST prove from screening and terminal scorecard digests that fixed slots 1 and 2 were the first eligible candidates and were not replaced. A failed or unavailable local or receive-side check requires `in-place-no-transfer`.
- `in-place-no-transfer`: compare in place; Private MUST NOT persist Work-derived counts, coverage, gate results, reasons, or combined evidence and MUST NOT reconstruct Work values by subtracting Private values. A separately timed generalized-learning statement MAY cross only if it independently satisfies the non-association and reconstructability rules above; it is not a cohort result or proxy decision. If no Work outcome may cross, Private remains `awaiting_external_decision` and the shared Skill phase MUST NOT start there.

`approved-summary` is insufficient when a prior Work hard failure or its remediation must be acknowledged in the advancement decision because those facts are outside the seven-field allowlist. That comparison MUST remain in place and use a never-transfer Work-local decision receipt; no Work failure/remediation detail is copied to Private. The Private record remains `awaiting_external_decision` unless a separately approved policy and channel explicitly permit the required decision artifact. If Work policy cannot retain even the local receipt, the comparison cannot authorize advancement and the pilot MUST stop or remain undecided.

## Advancement decision

Only the human sees and evaluates cohort thresholds. They MUST NOT be copied into a run contract or runtime invocation.

Advance to Skill design only when:

- all four tasks clear every hard safety gate;
- at least three tasks individually have all role bounds compliant, lower cumulative human attention than historical baseline, equal or higher confidence, cumulative CP2 time at most 20 minutes, a passed quiz gate, and at most one cumulative unscheduled decision interruption; and
- at least one Codex task and one Claude Code task complete approved scope and reach `ship`.

Four tasks measure comfort, not rare-event safety. Continue safety observation through approximately the first ten eligible thick changes. Every fixed slot counts toward the four-task result regardless of disposition or qualification. No enrolled task—including one with a schema/package mismatch discovered after enrollment, estimated baseline, overrun, block, abandonment, Goal replacement, or hard failure—may be silently replaced or counted as qualifying.

## Hard failure and resume

The pilot MUST immediately enter `PAUSED_HARD`, freeze/digest local evidence, and stop the cohort and pilot-derived transfers for an information-boundary breach, ignored hard-stop condition, suppressed required question or weaker route, unauthorized operation, unverified pass claim, frozen-evidence mutation, or merge/deploy during a pilot run.

```text
ACTIVE
  -> PAUSED_HARD
  -> DIAGNOSE
  -> STOPPED
     or
  -> REVISED_POLICY
  -> CONTROL_RECHECK + END-TO-END REHEARSAL
  -> BOTH-RUNTIME RECALIBRATION
  -> HUMAN RESUME APPROVAL
  -> NEW COHORT
```

The originating environment MUST handle security/incidents locally. Resume requires an explicit operator record of cause, remediation, affected passing controls, successful rehearsal/calibration, and human approval. The prior failure remains history and MUST be acknowledged by any later `advance`; starting a new cohort alone does not clear it.

## Drift and recalibration

Material runtime, model, schema, package, or adapter/invocation changes, plus any live hard-route mismatch, require affected role controls and end-to-end rehearsal plus both-runtime calibration. Enforcement profile/configuration, roots, credential/environment/socket exposure, network mode or allowlists, or host-brokered external-tool inventory/operation allowlists require affected role controls and end-to-end rehearsal; they also require both-runtime calibration when runtime routing or lifecycle behavior may change. Until required checks pass, affected sessions and the cohort remain blocked.

Calibration compares across environments only schema version, package digest, scenario id, and route classification. Raw rationale, runtime/profile/path details, timing, and local evidence remain in the originating environment. Every hard route MUST match before a real task starts.

## Deferred Skill constraint

Week 0 MUST NOT implement or exercise delivery capabilities inside a run. If the pilot later advances, a separate Skill design MAY expose feature-branch commit, non-force push, and draft-PR creation only as bounded capabilities. Every run still requires explicit human authority naming the repository, remote, and feature branch plus repository safety/divergence checks and verified read-back. The future Skill MUST continue to prohibit default-branch commit/push, force push, merge, deploy, destructive operations, irreversible migrations, and unapproved security-, data-, or shared-state-affecting operations.
