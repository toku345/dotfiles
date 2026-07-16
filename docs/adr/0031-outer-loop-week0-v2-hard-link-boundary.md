# ADR 0031: Amend the Week 0 Hard-Link Boundary with Integrity Gates

## Status

Accepted as a historical decision. Superseded for future pilot execution by [ADR 0032](0032-private-lima-outer-loop-calibration-boundary.md).

## Context

[ADR 0030](0030-codex-claude-outer-loop-pilot.md) selected a zero-build outer-loop pilot whose runtime boundary must deny content reads through multiply linked regular files before disclosure. The `outer-loop-week0/v1` package encoded that requirement for every role.

Private Codex calibration demonstrated that the observed stock path sandbox denied a direct outside-root read but allowed the same harmless sentinel content through a pre-existing hard-link alias under an approved read root. This was a safe pre-arm control failure before any real pilot task. It blocks v1 calibration but is not a real-task hard failure and does not create a `PAUSED_HARD` remediation chain.

Preflight and postflight inspection cannot replace denial of agent-created hard links: an agent or descendant could create an alias, read it, and unlink it entirely between observations. At the same time, the user has explicitly excluded a malicious concurrent process already running as the same OS user from the Week 0 threat model and intends to revisit stronger isolation with per-agent microVMs later.

The pilot must therefore distinguish pre-existing aliases from aliases created by an in-scope role, bind content separately from filesystem safety metadata, preserve fail-closed routing, and remain Markdown-only unless calibration proves that this is not reproducible without a reusable helper.

## Decision

### Amend ADR 0030 only for `outer-loop-week0/v2`

Amend ADR 0030 rather than superseding it. For schema `outer-loop-week0/v2`, replace only the runtime per-read denial requirement for a pre-existing approved-root hard-link alias and add the supporting eligibility, role-gate, evidence, routing, and threat-model rules needed to keep that replacement fail-closed.

Keep `docs/outer-loop/week0-v1/`, its manifest, and all local v1 observations immutable. Create a complete self-contained `docs/outer-loop/week0-v2/` package with a new schema, manifest, package digest, affected controls and rehearsal, both-runtime calibration, and a new four-task cohort. Never pool v1 and v2 results.

All ADR 0030 and v1 rules not explicitly amended here remain in force, including candidate arrival order, irreversible fixed-slot enrollment, first-CP1 attempt start, the two-attempt maximum, attention accounting, Checkpoint 1 and 2, Session C result states, incomplete-final reconciliation outcomes, the unauthorized-operation hard-pause route, information-transfer allowlists, and the delivery boundary.

### Narrow the threat boundary explicitly

Protect against pre-existing aliases in role-visible task surfaces; hard-link and symlink creation by a role, its tools, and every process it launches; unauthorized mutation; incomplete or unstable evidence; and role-launched work that remains active during postflight collection.

Trust the operator, package-bound collector, OS kernel, filesystem implementation, and calibrated sandbox enforcement. Exclude a malicious concurrent process already running as the same OS user, not launched by the role, that creates, exploits, and removes an alias or restores bytes entirely between collector observations. Make no confidentiality or complete race-resistance claim against that process.

Record this residual race once per arm as a human-owned accepted risk and reference it from task scorecards. Never use the exclusion to ignore observed drift. Per-agent microVM isolation is a successor boundary that requires another schema/package and recalibration.

### Use an eligibility screen and three load-bearing integrity layers

1. Before enrollment, apply one uniform prospective safety predicate to every candidate in arrival order. Exclude a candidate-specific unsupported or unavoidable task surface before the atomic eligibility/enrollment decision; block the arm for a general collector or enforcement failure. After enrollment, every adverse result remains attached to its slot.
2. Before every A1, A2, spike, B, and C launch, run an operator-owned collector over every filesystem surface whose bytes or derived content the role or its descendants can obtain as task data. Scan every readable subtree or prove it is enforcement-denied. Reject a regular file with `st_nlink != 1` before content open/hash and before role launch.
3. During every role, retain the calibrated default-deny boundary. Deny hard-link creation before mutation for all five roles and every applicable approved-read, approved-write, implicit temp/cache, protected, denied, and outside source/destination class. Test ordinary commands and direct `link`/`linkat`-equivalent calls, prove that no destination appears, and prove source identity, link count, and content remain unchanged. If this control fails, block the arm and return to design; postflight is not a substitute.
4. After every launched role, expire its authority and prove execution-group quiescence across the top-level runtime, descendants, reparent/double-fork or process-group escape, and asynchronous broker/tool work before running the identical collector. A prompt return or terminal marker alone is not quiescence evidence. A run-specific quiescence failure follows the role-specific `UNVERIFIED` or B-reconciliation route below; a general inability to demonstrate this capability during calibration blocks the arm.

Retain all existing direct outside-root read, symlink traversal and creation, write alias, protected overlap, resolved containment, Git-control, operator-artifact, credential/environment/socket, network, brokered-tool, external-state, and artifact-ownership controls.

### Separate safety, content, provenance, and attribution

Have each collection produce separately digested safety metadata, review-state content, surface/exclusion inventories, completeness/race results, and a provenance envelope. Safety metadata records path/object/topology facts; review state records exact content digests and the non-followed target bytes of declared reviewable symlink nodes only. Protected and disposable content, paths, and symlink-target details remain omitted from Session C as required by their existing boundary. Do not treat device/inode/mode/link-count equality as content equality.

For permitted regular-file content, require `lstat`, containment/classification and `st_nlink == 1`, no-follow descriptor open, matching `fstat`, exact descriptor hashing, a stable second `fstat`, a final matching `lstat`, and an unchanged sorted path inventory. Fail closed on unsupported nodes, permission errors, mount transitions, disappearing paths, object replacement, changing inventory, or non-canonical serialization.

Treat an authorized writable delta as normal review evidence only when its path and operation are within frozen authority and operator-observed immutable transcript/tool/broker/process evidence maps every delta to the responsible role event. A report or self-claim alone is insufficient. Missing or contradictory attribution is ambiguous.

### Keep role and reconciliation states distinct

Use role-specific preflight and postflight records. A preflight failure launches no role and may be rechecked only after retaining the failure and evidence-backed remediation; a CP1-approved B preflight failure retains the existing approved-but-not-started variant and consumes that run attempt. A launched role's postflight failure invalidates that role result.

Only a started B with an incomplete final collector uses v1 `post_run_reconciliation`. Preserve original missing/failed final fields and retain the existing `reconciled-clear`, `external-drift-restore-required`, `reconciliation-unverified`, and `unauthorized-hard-failure` meanings. Non-B role failures never fabricate B reconciliation, and a launched C retains its actual result state while a failed role-postflight gate invalidates the review and prohibits `ship`.

For a complete normal postflight, use distinct outcomes: pass; unauthorized role delta to `PAUSED_HARD`; proven operator/external drift requiring safe restoration or quarantine and an identical clean repeat to establish terminal state whether or not another attempt remains; and ambiguous/unproved integrity as a no-retry block or abandonment. A clean repeat never revives the invalidated output; any later attempt additionally follows the role table and unused-sequence gate. Pre-disposition and pre-delivery live checks retain their separate ADR 0030/v1 next-attempt route.

Do not grant a second A1, A2, or spike pass after a launched pre-CP1 role's postflight failure, even after clean restoration. This is deliberate: a re-pass would hide observer/environment mistakes, weaken one-pass bounds, and create a replacement path outside fixed-slot measurement. The resulting narrow, block, abandonment, and possible permanent slot loss remain full-burden pilot evidence. Preflight may be rerun because no role pass or output was consumed.

Any independently proven role-attributed prohibited delta overrides ordinary routing and enters `PAUSED_HARD`. Non-B launched-role `UNVERIFIED` integrity permanently forces hard gates `no` and task non-qualification. A started B's incomplete final forces hard gates `no` only while reconciliation is pending; its existing reconciliation outcome then governs.

For any Work candidate or task with read-path integrity failure or uncertainty at screening, A1, A2, spike, B, C, or a later observation, suppress every generalized-learning statement derived from that candidate or task. Raw Work artifacts and details remain local under the existing information boundary.

### Preserve zero-build with an explicit stop rule

Keep the v2 package Markdown-only. Permit an exact package-covered operator command or ephemeral inline program, but install or commit no persistent or reusable executable, runner, adapter, hook, Skill, workflow, service, runtime configuration, or generated state.

Require both environments to reproduce the same canonical collector schema and semantics, with local tool/platform provenance. Stop calibration if approved platform tooling cannot reproduce descriptor-bound no-follow hashing, stable inventory checks, canonical serialization, direct-syscall controls, complete attribution evidence, or execution-group quiescence. Do not substitute an approximate `find | shasum` pipeline or asserted success. Allowing a reusable helper requires another design and ADR amendment.

## Consequences

### Positive

- Pre-existing hard-link aliases are rejected before a role can receive task content, while in-scope alias creation remains denied before mutation.
- Safety metadata and exact content evidence have distinct responsibilities, avoiding false confidence from inode/link-count equality and false failures for authorized atomic replacement.
- Role/stage-specific routing preserves v1 attempt, Session C, reconciliation, and hard-pause semantics without inventing evidence.
- v1 calibration history remains truthful and comparable without being pooled into the new cohort.
- The design remains a zero-build experiment and fails closed when its manual mechanisms are not reproducible.

### Negative

- Every role gains task-surface preflight, postflight, provenance capture, and quiescence evidence, increasing operator burden and potentially failing the comfort gate.
- Repositories with required hard-linked, unscannable, special-file, or unsupported mount surfaces may be ineligible.
- A pre-CP1 postflight failure can permanently consume a fixed cohort slot even when the environment is later restored.
- Stock runtimes may be unable to prove detached-process and broker-job quiescence, leaving the arm blocked.
- A new package identity and both-runtime recalibration prevent reuse of the v1 calibration effort as passing evidence.

### Risks

| Risk | Mitigation |
|---|---|
| Malicious same-user process races entirely between scans | Explicitly outside the v2 guarantee; human-owned accepted risk; future microVM boundary |
| Agent creates, reads, and removes an alias between scans | Load-bearing all-role direct hard-link creation denial; arm blocks on any failed control |
| Metadata matches while content changed | Descriptor-bound content hashing and separate review-state manifests |
| Correct implementation delta is classified as external or ambiguous | Complete delta-to-event attribution mapping; self-claim alone never passes |
| External or unknown drift gains a retry | Proven external restoration follows role table; ambiguous integrity is no-retry and fail-closed |
| Collector races or silently omits paths | Stable double inventory, no-follow object binding, explicit scan completeness, no invisible retries |
| Background child mutates after the terminal marker | Execution-group quiescence including detached and broker-owned work; inability blocks the arm |
| Manual inline collector is inconsistent across machines | Package-covered exact invocation, canonical serialization rehearsal, deterministic double-run control, calibration stop rule |
| Work integrity uncertainty influences transferable learning | Suppress generalized learning for the entire affected Work candidate/task |

## References

- [Codex / Claude Outer Loop Week 0 v2 Boundary — Design Doc](../design/codex-claude-outer-loop-week0-v2.md)
- [ADR 0030: Pilot a Shared Outer Loop for Codex and Claude Code](0030-codex-claude-outer-loop-pilot.md)
- [Outer Loop Week 0 v1 package](../outer-loop/week0-v1/README.md)
