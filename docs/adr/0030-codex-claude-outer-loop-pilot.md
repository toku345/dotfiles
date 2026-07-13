# ADR 0030: Pilot a Shared Outer Loop for Codex and Claude Code

## Status

Accepted

## Context

Interactive coding-agent work currently requires frequent human supervision at several points: clarifying intent, reviewing implementation plans, answering implementation-time questions, reviewing code, and rebuilding enough understanding to decide whether to merge. Asking too little lets an agent silently guess and move in the wrong direction; asking too much turns the human into a full-time watcher.

The intended usage is environment-split: private work is primarily driven by Codex CLI, while company work is primarily driven by Claude Code. Maintaining two unrelated workflows would duplicate policy and prevent general lessons from improving both environments. At the same time, company-specific code, architecture, conventions, Skills, prompts, logs, and other repository-specific information must not leave the company environment.

Prompt-only guidance is not sufficient evidence that a comfortable loop exists. Building a Skill, Dynamic Workflow, hook system, or custom runner before observing real tasks would add another system to supervise and could encode the wrong workflow. A small, mechanism-backed pilot is needed first.

Both runtimes provide a `/goal` mechanism for pursuing a durable objective with a verifiable stopping condition. The shared design should therefore define one outer-loop contract schema and policy, create an environment-local contract instance for each run, and use runtime-specific adapters only where Codex and Claude Code semantics differ.

## Decision

Run a zero-build "Week 0" pilot before creating a reusable Skill or workflow. Week 0 means the next four eligible thick changes, not a literal calendar week: two private tasks driven by Codex `/goal` and two company tasks driven by Claude Code `/goal`. A task is eligible when its proposed scope contains at least one user-visible or external-contract behavior, cross-module or architectural choice, security/data/invariant concern, or implementation choice whose resolution could materially change the plan; its Acceptance Criteria describe observable outcomes that can be verified locally; a rollback or safe abandonment path can be explained before implementation; and the task is not an emergency. Typo-only, formatting-only, dependency-lock refresh, generated-file refresh, other predetermined mechanical changes, production or security incident response, irreversible data migration, Goal discovery without implementable Acceptance Criteria, and work dominated by human-only or shared-state operations are excluded. Week 0 uses manually supplied runtime-specific invocations or templates; it does not create a persistent adapter, Skill, hook, or workflow implementation.

### Shared outer-loop contract

Use one runtime-neutral contract schema and policy covering the Goal, Non-goals, Constraints and invariants, Acceptance Criteria and their verification methods, high-impact Unknowns, permitted authority, immediate-stop conditions, queued decisions, and the `CP2_READY` stopping state. Each machine creates an environment-local per-run instance from that schema. Every pilot task receives a machine-local task id, and every initial or redirected run under the same human-intent change records that task id plus its own run id, schema version, non-sensitive package digest, runtime and model version, adapter or invocation version, artifact provenance, and the human-approved authority for that run. Runtime and model versions are recorded instead of being embedded into the shared policy. When a runtime does not enforce a required time or turn bound natively, the contract and manual invocation template state the bound and the report records compliance. Reaching a runtime's self-judged completion state does not satisfy an Acceptance Criterion without the verification evidence required by the contract.

The first Checkpoint 1 starts the task-level measurement window. A `narrow` or `redirect` that still pursues the same human-intent change creates a new run under the same task id; its prior runs are never discarded. The task-level scorecard sums human attention, Checkpoint 2 review time, permission prompts, unscheduled interruptions, quiz attempts, and re-gating across every run until terminal `ship`, `block`, or abandonment, and any hard failure in any run makes the task a hard failure. If the human materially replaces the Goal rather than re-gating the same change, the original task ends as redirected and remains in the cohort as non-qualifying; the replacement receives a new task id and cannot overwrite it.

Use two scheduled human checkpoints:

1. Checkpoint 1 approves the contract after bounded exploration and Unknown discovery.
2. Checkpoint 2 reviews evidence, queued decisions, residual risk, rollback, and an understanding quiz before the human chooses `ship`, `narrow`, `redirect`, or `block`.

Implementation runs in a fresh session after Checkpoint 1. The session starts with an echo-back of the approved contract; ambiguity-free handoffs continue without another human turn, while missing contract information stops and is recorded as a handoff gap. Independent review also uses a fresh context within the same information boundary and is blind-first: it inspects the Goal, Acceptance Criteria, diff, and verification results before reading the driver's Decision Log. The independent reviewer prepares three to five questions about behavior, invariants, major implementation decisions, residual risk, and rollback rather than code trivia. The human answers them at Checkpoint 2. Every miss blocks `ship` until the cited evidence is reviewed and the question is answered correctly or the human provides an evidence-backed explanation that resolves the misunderstanding. The quiz gate passes only when every miss is resolved; an unresolved miss requires `narrow`, `redirect`, or `block`. If the miss exposes a wrong Goal, Acceptance Criterion, invariant, or external-behavior assumption, the run is redirected to Checkpoint 1 under a new run id.

### Pilot artifacts

Keep the run and task artifacts local to the machine on which the task originated and outside the target repository:

- `contract.md`: the self-contained, human-approved instruction source in each run's temporary directory; immutable after that run's Checkpoint 1.
- `report.md`: the echo-back, non-trivial Decision Log, implementation-time Unknown delta, and Evidence Packet in the same per-run temporary directory.
- `scorecard.md`: one task-level observer record that lists all associated run ids and aggregates their pilot measurements, final disposition, independent reviewers' runtimes and models, same-model or cross-model review modes, and abstraction candidates in durable environment-local pilot state; numerical targets and advancement thresholds are not copied into the implementation-agent contract.

The artifacts are pilot state, not project deliverables, and are not committed. Store company artifacts only in company-approved, non-shared, non-synchronized local state. Create each per-run directory with an OS-provided private temporary-directory mechanism and permissions equivalent to `0700`, create artifact files with permissions equivalent to `0600`, and apply equivalent protection to durable scorecard state. Retain each local scorecard at least until the four-task pilot decision, retain raw evidence only as long as local policy permits, and remove expired artifacts according to that policy. A scorecard may refer to its associated local run ids but must not depend on a temporary artifact remaining available. If the repository already requires a durable implementation note or ADR for the actual change, that existing convention remains separate and authoritative.

### Unknown discovery

Treat Unknown discovery as bounded risk sampling, not a claim of exhaustive coverage. Before Checkpoint 1, the driver inventories concrete assumptions and probes code, primary documentation, and baseline behavior. One fresh-context blind-spot pass independently inspects the Goal, Constraints, Acceptance Criteria, and primary artifacts without seeing the driver's inventory or plan. The initial blind-spot pass is limited to 10 minutes; unresolved candidates are reported at Checkpoint 1 instead of extending the pass or spawning more reviewers. Agent agreement is not evidence.

If the blind-spot pass produces two or more high-impact `block` or `ask-human` candidates, narrow the scope or run a pre-approval throwaway spike before forming the Checkpoint 1 question batch. The spike is limited to one 20-minute attempt and produces evidence only, not production code. After that risk reduction, keep at most five specific candidates that identify an affected behavior or interface, the failure if the assumption is false, the related Acceptance Criterion, current primary-source evidence, and the cheapest falsification probe. Route each candidate to evidence-backed support or refutation, bounded exploration, a throwaway prototype, human clarification, accepted risk, or block. Human questions are batched at Checkpoint 1, limited to answers that could change the plan, architecture, contract, or authority boundary, and capped at three. If more than three such questions remain, narrow the task instead of asking them piecemeal.

The Checkpoint 1 Unknown list is frozen in `contract.md`; Unknowns discovered during implementation are appended to `report.md`. A zero count is not treated as success.

### Decision and interruption policy

Route implementation-time decisions as follows:

- Self-resolve when the choice remains inside the contract, is local and reversible, has accessible evidence, and has a known undo path.
- Queue when the choice depends on implicit human preference but can safely wait until Checkpoint 2; any prototype is throwaway-only, not wired into production code, and initially limited to one 20-minute attempt.
- Stop when the work requires a contract change; crosses a security, data-loss, irreversible, shared-state, or authority boundary; conflicts with authoritative evidence or provenance; cannot map the evidence and justification for an implementation decision to the Goal, an Acceptance Criterion, an invariant, or the authority boundary; or reaches the third evidence-free repetition of the same failure.

Unrun verification is labeled `UNVERIFIED` and is never implied to pass. Suppressing a question or self-resolving a decision that the policy requires to queue or stop is a hard task failure, even if the resulting implementation happens to work. If Checkpoint 2 finds a wrong queued decision or another post-freeze defect, any implementation fix starts a new run because the report, diff, and Evidence Packet are already frozen. The same human-intent Goal keeps the task id and returns through Checkpoint 1 with a new contract and run id; a material Goal replacement terminates the old task as non-qualifying and receives a new task id.

### Authority boundary

During Week 0, `/goal` may write only to the target worktree, its designated private pilot-state directories, and temporary or cache paths explicitly declared for the approved verification commands. The target worktree allowance excludes the Git index, refs, stash, branch or worktree metadata, and direct writes under Git control metadata. Tool-visible credential sources, secret-bearing inherited environment variables, and credential, keychain, or agent sockets must be unavailable; controls use harmless sentinels rather than real secrets. Tool-visible network access must be disabled unless enforcement restricts destinations and request shapes to approved read-only probes and denies undeclared egress before disclosure. The run must not read credentials or write to another repository, home or global configuration, a credential store, a persistent local service or database, or external network state, even when such a change appears locally reversible or is requested in the contract. A disposable test database or fixture is allowed only inside an explicitly declared temporary verification path. Other external dependencies must be replaced with fixtures or limited to the enforced read-only probes. The run must not commit, stage, push, create a draft pull request, change branches or worktrees, merge, deploy, or perform other shared or external state changes. Any operation outside this boundary, including a local commit, is an unauthorized-operation hard failure. `ship` at Checkpoint 2 records the human's disposition and ends the `/goal` run; any ordinary delivery work occurs afterward, outside the pilot run and under the repository's existing workflow and approvals.

If the pilot advances to Skill packaging, the Skill will make feature-branch commits, non-force pushes, and draft pull-request creation available as bounded capabilities. Capability does not grant authority for a particular run: the per-run contract or a live human turn must explicitly approve each operation and identify the intended repository, remote, and feature branch. Repository guidance, branch-safety and remote-divergence checks, and verified read-back of created shared resources remain mandatory. The Skill will continue to prohibit default-branch commits or pushes, force pushes, merge, deploy, destructive operations, irreversible migrations, and unapproved security-, data-, or shared-state-affecting operations.

### Environment and information boundary

Private and company runs are expected to occur on separate machines without a shared filesystem or shared pilot-state store. The shared element is the versioned contract schema and policy, not a shared per-run contract or artifact directory. Each machine keeps its runtime adapter or manual invocation and all run instances locally. Distribution of a schema or policy update is transport-agnostic and must use a method permitted in each environment; the ADR does not assume that both machines clone the same configuration repository.

Raw company artifacts and observations remain on the company machine. Company repository architecture, internal conventions, internal Skills and prompts, code, diffs, paths, logs, tickets, exact timestamps, and identifiable combinations of metrics must not be transferred to the private machine. Independent review of a company task also remains in the company environment. `agmsg` may be used within one environment but is not used for automatic cross-machine or cross-environment transfer.

Only two human-approved run-derived artifact types may cross from the company environment: a generalized learning statement and one company-arm pilot summary created after both company tasks reach terminal disposition. The abstraction gate must confirm that neither contains reconstructable company or repository detail. A generalized learning statement records only a generally applicable phenomenon, its applicability conditions, and a proposed shared rule; it is not linked to a run or to the company-arm summary and is transferred only when its timing and content cannot associate it with a company task. The company-arm summary is derived only from task-level rollups and contains `schema_version`, the non-sensitive canonical `package_digest`, runtime family, completed-task count, whether all company hard gates remained clear, the count of company tasks that satisfied every comfort criterion, and whether at least one company task reached `ship`. It contains no run-level fields, run id, task or repository identifier, path, date, timestamp, order, raw metric, failure reason tied to company context, or exact combination that could identify the work. Ambiguous cases remain local.

There is no automatic four-run aggregation and no company run-level transfer. After both company tasks reach terminal disposition, the human evaluates them on the company machine and approves the single company-arm summary. The summary may be transferred manually only through a company-permitted path; if no permitted path exists, it remains local and the human performs the final comparison without copying it. A private-side aggregate ledger may store the approved company-arm summary and private-task summaries but never separate company-run records. Raw company scorecards remain on the company machine. If schema versions differ, the outcomes are not pooled until the mismatch is reconciled and calibration is repeated.

### Pilot decision

Before real tasks, run the same small, generalized tabletop calibration on both machines so Codex and Claude Code agree on hard `self-resolve`, `queue`, and `stop` boundaries. Only the schema version, non-sensitive package digest, scenario identifiers, and classifications need to be compared across environments. If any hard-route classification or package identity differs, revise the shared policy and repeat calibration before the first real task. Repeat calibration after a material runtime, model, schema, package, or adapter change, or after a live hard-route mismatch. The advancement cohort must contain two Codex tasks and two Claude Code tasks evaluated under the same schema version and package digest. If the schema or package changes after a cohort task starts, retain all existing task results as pilot observations, recalibrate, and begin a new four-task advancement cohort under the new identity; do not pool or silently replace mismatched tasks. A hard failure in an earlier cohort remains a paused-pilot result and cannot be cleared merely by starting a new cohort.

Before the first Checkpoint 1 of each task, the human records a local comparison baseline by naming a comparable recent thick change or describing how the same task would normally be supervised. At terminal disposition, the human records whether cumulative active attention across all runs was `lower`, `same`, or `higher` than that baseline and whether disposition confidence was `lower`, `same`, or `higher` than it would have been under the baseline workflow. Checkpoint 2 active review time starts when a run's complete Evidence Packet and quiz are presented and ends when that run's `ship`, `narrow`, `redirect`, or `block` is recorded; unrelated interruptions pause the timer, and the task metric sums every Checkpoint 2 attempt. An unscheduled decision interruption is any human decision request between the task's first Checkpoint 1 approval and terminal disposition, including a justified hard stop, but excluding execution-permission prompts for operations already authorized by the contract. Count those permission prompts separately and include their handling time in cumulative human attention. During the cohort, also measure handoff gaps, genuine and false interruptions, wrong queued decisions and re-gating, unverified completion claims, independent-review findings, and quiz misses. The human alone evaluates these measurements and advancement thresholds; withholding them from per-run contracts, prompts, and agent instructions is a best-effort context boundary, not a file-secrecy control. Continuous autonomous step count and Unknown count are diagnostic only, never optimization targets.

Pause the pilot immediately for an information-boundary breach, ignored hard-stop condition, suppressed required question, unauthorized operation, unverified pass claim, or any merge or deploy during a pilot run. Advance to Skill design only if all four cohort tasks clear every hard safety gate; at least three cohort tasks each have lower cumulative human attention than their recorded baseline, equal or higher confidence than their baseline, cumulative task-level Checkpoint 2 active review time of 20 minutes or less, a passed quiz gate, and no more than one cumulative unscheduled decision interruption; and at least one Codex task and one Claude Code task complete their approved scope and reach `ship`. The human records the four-task decision from the two private summaries and the single approved company-arm summary, or compares the company result in place when transfer is not permitted. Four tasks validate comfort, not rare-event safety; continue safety observation through approximately the first ten eligible thick changes.

## Consequences

### Positive

- Human attention is concentrated into two planned checkpoints and genuine high-impact exceptions rather than phase-transition menus and repeated low-value questions.
- Codex and Claude Code share one observable contract schema and policy while retaining environment-local instances and runtime-specific adapters, so general learning improves both without pretending their `/goal` semantics are identical.
- Evidence, provenance, Unknown handling, rollback, and human understanding become explicit merge inputs without requiring a full line-by-line human read by default.
- The company/private boundary permits useful generalized learning while keeping raw company context local.
- The pilot produces evidence about whether a Skill is worthwhile before adding maintenance and enforcement machinery.

### Negative

- Each thick task gains upfront contract work, a bounded blind-spot pass, two temporary per-run artifacts, one durable local scorecard, and an independent review step.
- Fresh-session handoff can still omit information; echo-back detects but does not eliminate this risk.
- Company review may be Claude reviewing Claude, so model-prior correlation remains despite fresh context and blind-first ordering.
- Raw temporary artifacts may disappear before later diagnosis, so the durable scorecard must remain independently interpretable without them.

### Risks

| Risk | Mitigation |
|---|---|
| Unknown discovery becomes a checklist ritual or inflates human questions | One timeboxed blind-spot pass, at most five specific candidates, and at most three plan-changing human questions; narrow or spike if more remain |
| Agents converge on the same unsupported assumption | Independent blind-first extraction, agent consensus explicitly excluded as evidence, and primary-source falsification probes |
| The pilot creates false confidence by freezing Unknowns at Checkpoint 1 | Record implementation-time Unknown deltas and reviewer-discovered Unknowns in `report.md`; do not optimize for a zero count |
| Agents suppress necessary questions to meet attention targets | Keep `scorecard.md` and advancement thresholds outside the implementation-agent contract; treat suppression of a required question as a hard task failure |
| Runtime or model updates change `/goal` behavior | Record runtime/model versions and rerun the small tabletop calibration after material upgrades |
| Company-specific details leak into shared learning or pilot aggregation | Separate-machine local raw artifacts, no automatic or run-level transfer, one company-arm summary after both tasks, and a human abstraction gate with reconstructability as the rejection test |
| Schema, package, or policy versions drift between machines | Record schema/adapter versions and the canonical package digest, do not pool mismatched outcomes, and recalibrate after reconciliation |
| Skill packaging broadens authority beyond the approved boundary | Allow only feature-branch commit, non-force push, and draft PR creation; keep merge, deploy, force/default-branch, destructive, irreversible, and unapproved shared operations prohibited |

## References

- [Own the Outer Loop](https://addyo.substack.com/p/own-the-outer-loop)
- [A Field Guide to Fable: Finding Your Unknowns](https://x.com/trq212/article/2073100352921215386)
- [Getting started with loops](https://claude.com/ja/blog/getting-started-with-loops)
- [Codex: Follow a goal](https://learn.chatgpt.com/use-cases/follow-goals)
- [ADR 0029 (Claude-side PR Review via Dynamic Workflow)](0029-claude-pr-review-dynamic-workflow.md) — precedent for a shared policy with environment-specific runtime implementations
