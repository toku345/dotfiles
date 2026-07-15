# Codex / Claude Outer Loop Week 0 v2 Boundary — Design Doc

Parent decision: [ADR 0030](../adr/0030-codex-claude-outer-loop-pilot.md)
Target decision: [ADR 0031](../adr/0031-outer-loop-week0-v2-hard-link-boundary.md)
Status: Accepted

## Context

The Private Codex calibration for `outer-loop-week0/v1` demonstrated that the observed stock path sandbox denied a direct outside-root read but allowed the same harmless sentinel content through a pre-existing hard-link alias under an approved read root. The v1 requirement that every role deny a multiply linked regular-file read before disclosure is therefore not satisfiable with that observed profile.

The v1 package, manifest, and local calibration evidence remain immutable. The observation occurred during a safe pre-arm control before any real pilot task, so it remains a blocked calibration prerequisite rather than being relabeled as a real-task hard failure.

This design defines the smallest v2 boundary change that can preserve a zero-build pilot under a narrower, explicit threat model. It does not start a cohort, create the v2 package, or weaken the other v1 controls.

## Goals

- Reject pre-existing hard-link aliases before a role can receive task content.
- Continue to deny agent- or descendant-created hard links before mutation.
- Bind review evidence to exact content without mistaking authorized implementation changes for integrity drift.
- Preserve v1's fail-closed lifecycle, attempt accounting, information boundary, and immutable evidence history.
- Keep Week 0 Markdown-only unless calibration proves that the required collector semantics cannot be reproduced without a reusable helper.

## Non-goals

- Protecting against a malicious concurrent process already running as the same OS user and deliberately racing between collector observations.
- Claiming confidentiality against kernel, filesystem, privileged-host, or operator compromise.
- Implementing a persistent collector, Skill, hook, workflow, custom runner, service, or runtime configuration.
- Introducing per-agent microVM isolation in v2.
- Reopening checkpoints, metrics, transfer allowlists, delivery authority, or other v1 rules that are unrelated to the hard-link boundary.

## Considered approaches

| Approach | Trade-off | Decision |
|---|---|---|
| Retain per-read runtime enforcement of `st_nlink == 1` | Strongest direct guarantee, but the observed Codex profile cannot demonstrate it | Reject for v2; retain the blocked v1 observation |
| Preflight and postflight collection plus mandatory link-creation denial | Works with the narrowed threat model while preserving denial-before-mutation for in-scope actors | Adopt |
| Persistent runner or per-agent microVM | Stronger isolation and simpler race reasoning, but exceeds zero-build Week 0 | Defer to a new schema/package |

## Decision summary

Week 0 v2's central enforcement change replaces the requirement that the runtime itself enforce `st_nlink == 1` on every task-visible regular-file read. Instead, an operator-owned collector rejects a role-readable surface containing a multiply linked regular file before role launch, the runtime/OS boundary continues to deny hard-link creation by the role and its descendants before mutation, and the identical collector validates the surface after authority has been revoked and the role has quiesced. The supporting eligibility, lifecycle-gate, threat-model, and artifact deltas required to make that replacement fail-closed are enumerated below.

Postflight detection is not a substitute for link-creation denial. An agent can otherwise create an alias, read it, and unlink it between observations. Failure to prove denial-before-creation on any role-accessible writable root blocks that runtime arm and returns v2 to design.

Every other v1 safety, authority, lifecycle, checkpoint, measurement, information-boundary, and cohort rule remains unchanged unless the normative delta inventory below explicitly identifies a change.

## Version and document relationship

- ADR 0031 will amend, not supersede, ADR 0030. The amendment is limited to the multiply-linked read guarantee, its enforcement mechanism, and the associated threat-model assumption for `outer-loop-week0/v2`.
- `docs/outer-loop/week0-v1/` and all v1 observations remain unchanged and must not be pooled with v2.
- `docs/outer-loop/week0-v2/` will be a complete, self-contained package with schema `outer-loop-week0/v2`, a new manifest and package digest, affected control rehearsal, both-runtime calibration, and a new four-task cohort.
- The v2 design may describe its delta from v1, but the runtime package must not normatively import v1 at execution time. Its `policy.md` remains the sole runtime-neutral policy source.
- The failed v1 pre-arm control does not create a `PAUSED_HARD` remediation chain. It remains immutable calibration history and explains why v2 exists.

## Normative v2 delta inventory

The hard-link enforcement amendment necessarily introduces these and only these supporting policy deltas:

1. The prospective task-surface safety screen becomes a uniform v2 eligibility predicate evaluated before the atomic eligibility/enrollment decision.
2. Every role receives task-surface preflight, explicit completion/quiescence evidence, and a role-postflight gate. Only an incomplete started Session B uses v1 `post_run_reconciliation`; other roles retain their actual result states and use role-specific postflight consequences.
3. The approved-root hard-link read control changes from runtime denial-before-disclosure to operator preflight rejection-before-role-launch. Collector-side rejection before content open/hash and runtime denial-before-creation remain mandatory.
4. A complete normal postflight gets its own outcome namespace. A complete result with ambiguous integrity attribution is a new conservative v2 no-retry route; it is not called `reconciliation-unverified` and does not alter the incomplete-final reconciliation enum.
5. The excluded malicious same-user transient race and its human-owned accepted-risk record become explicit.
6. New surface, collector, quiescence, and normal-postflight evidence fields are added to the schema.

The following v1 rules remain unchanged: candidate arrival-order evaluation; atomic irreversible enrollment after eligibility is decided; the first-CP1 attempt start; the two-attempt maximum; full-burden attention scope; Session C result-state enum; incomplete-final reconciliation triggers and outcomes; unauthorized-operation hard-pause route; fixed-slot/no-replacement rule; transfer allowlists; delivery boundary; and advancement gate.

## Threat and trust boundary

v2 protects against:

- pre-existing aliases in every surface whose content can be returned to a role;
- symlink traversal and hard-link or symlink creation by a role, its tools, or any process it launches;
- writes outside approved roots and unauthorized mutation of immutable, protected, Git-control, operator-owned, or external state;
- incomplete, unstable, or ambiguously attributed review evidence; and
- a role or descendant that remains active while postflight evidence is collected.

The operator, operator-owned collector, OS kernel, filesystem implementation, and configured sandbox enforcement are trusted for Week 0. A malicious concurrent process already running as the same OS user, not launched by the role, that creates, exploits, and removes an alias or restores bytes entirely between collector observations is outside the v2 guarantee. v2 makes no confidentiality or complete race-resistance claim against that process.

The operator must avoid intentional concurrent mutation while a role is active. Any unexpected drift that is actually observed remains evidence-invalidating and follows the fail-closed attribution routes below; the threat-model exclusion is never a reason to ignore it. The residual race is recorded once per arm as a human-owned accepted risk and referenced by each task scorecard.

Future per-agent microVM isolation changes this trust boundary and requires a new schema/package, affected controls, end-to-end rehearsal, and both-runtime recalibration.

## Candidate screening and task-visible surfaces

The prospective safety screen is a formal v2 eligibility predicate. The operator applies the same mechanical procedure to every candidate in recorded arrival order over the conservatively selected task surface before setting `eligibility_decided_at`. All eligibility predicates are evaluated and the eligible candidate is irreversibly enrolled as one atomic decision; there is no eligible-but-not-enrolled gap. Root selection is recorded before agent discovery. The default surface is the complete role-readable worktree plus every approved input; a narrower surface is valid only when every omitted subtree is enforcement-denied to the role.

A candidate-specific surface failure excludes that candidate before enrollment, with a recorded technical reason, when its required surface contains an unavoidable multiply linked regular file, an unscannable subtree, an unsupported special file or filesystem/mount boundary, or an exclusion that the runtime cannot deny. A failure of the arm's general collector or enforcement capability blocks the arm rather than selectively excluding inconvenient candidates. Screening work for the candidate that is later enrolled remains part of full-burden task attention. Once a candidate is enrolled, later control failure or drift remains attached to that immutable slot and cannot be replaced.

For each `A1-discovery`, `A2-blind-spot`, `spike-temp`, `B-implementation`, and `C-review` launch, the operator records the union of every filesystem root and descendant whose bytes or derived content the role, its tools, or its descendants can obtain as task data, every role-accessible writable root, and every enforced denied subtree. Hidden, untracked, ignored, temporary, and cache paths are included whenever the role can read them. Runtime-internal executables, libraries, and transport files may remain outside the task-data surface only when enforcement prevents their arbitrary contents from being returned as task data and the support surface is recorded separately. A subtree may be unscanned only when a passing enforcement control proves it is unreadable as task data. Git-control paths remain unreadable and are never traversed; bounded operator metadata queries continue to provide HEAD and index identities.

## Collector contract

One package-covered collector specification defines enumeration, metadata capture, permitted content hashing, serialization, comparison, and failure behavior. A rendered invocation binds the specification version, exact root/classification configuration, tool or interpreter version, platform, and invocation bytes into `collector_identity_and_config_sha256`.

Each collection produces separately digested artifacts:

1. `safety_manifest`, retained operator-locally, records canonical lexical and resolved root identities; canonical escaped relative path; presence; `lstat` node type and mode; device, inode, and link count; regular-file size and available high-resolution modification/change times; surface classification; and device/mount topology.
2. `review_state_manifest` records every reviewable path's presence, type, mode, exact regular-file SHA-256, and the exact non-followed target bytes of a declared reviewable symlink node. Protected and disposable content is absent. Session C receives only reviewable state and the aggregate protected-unchanged attestation.
3. Root, enforced-denial, protected-exclusion, and disposable-exclusion inventories bind what was scanned, denied, and omitted.
4. Scan-completeness and scan-race results state whether the output is usable. Missing, unstable, unsupported, or unclassified state is never silently omitted.
5. A separately digested provenance envelope records collector identity/configuration, invocation evidence, platform/tool versions, start/end observations, and operator verification. Observation-specific provenance is not mixed into the canonical state payload whose equality is compared.

The safety manifest detects alias and topology hazards; it does not claim content equality. The review-state manifest and canonical change snapshot bind content. Device and inode bind a path to the opened object within one collection; baseline/final inode equality is not generally required for an approved writable path because an authorized atomic replacement may change inode.

### Regular-file collection

For each regular file whose content is permitted, the collector must:

1. `lstat` the path and verify containment, classification, regular-file type, supported device topology, and `st_nlink == 1`.
2. Reject `st_nlink != 1` before opening or hashing content, retaining only permitted operator-local non-content metadata.
3. Open the final component read-only with no-follow semantics.
4. `fstat` the descriptor and require device, inode, type, mode, and link count to match the enumerated object.
5. Hash the exact descriptor bytes, then `fstat` again and require identity, link count, size, and available modification/change times to remain stable.
6. `lstat` the path again and require it still names the hashed object.
7. Require the sorted path inventory before and after the walk to be identical.

The collector never follows a symlink. A declared reviewable symlink node is represented only by `lstat` metadata and `readlink` target bytes; role traversal through it remains denied, and writable surfaces remain symlink-free. An undeclared device transition, mount point, socket, FIFO, device node, unsupported file type, permission error, disappearing path, changing inventory, or unsupported canonical serialization fails the collection as `UNVERIFIED-collection-failed`. The collector must not retry invisibly until a race happens to disappear.

### Classification and comparison

| Classification | Required comparison |
|---|---|
| `immutable-input` | Preflight and postflight safety and review-state records match exactly |
| `protected-exclusion` | Operator-local metadata matches exactly; content is never read or exposed |
| `approved-reviewable-write` | Root containment/topology remains valid; every final node passes safety checks; each add/delete/rename/type/mode/content delta is reviewable, within authority, and attributable to the role or its descendants by evidence |
| `declared-disposable` | Content may differ and is omitted from Session C, but containment, type, device topology, complete path inventory, and symlink/hard-link prohibition remain safety-checked |

A same-inode, same-link-count content overwrite is detected by the review-state digest. An authorized and role-attributed atomic replacement is a review delta, not integrity drift. A path- and operation-authorized delta caused by an operator/external actor remains external drift; a delta without adequate actor attribution is ambiguous. HEAD, index, Git-control state, the frozen contract, operator artifacts, and other immutable inputs remain exact.

### Delta attribution evidence

An `approved-reviewable-write` delta is role-attributed only when all of the following are present: the path and operation are within the frozen authority; operator-observed immutable provenance identifies the responsible tool, broker operation, or role-launched process and its command/request scope, result, and exit/completion state; the observed mutation scope and ordering correlate with the baseline/final path and content delta; and no unaccounted mutation channel remains under the role controls and quiescence evidence. A bounded child command may cover multiple deltas only when its recorded scope and resulting path inventory account for every one of them.

The role's `report.md` explanation may cross-reference this evidence but is not sufficient by itself. A self-claim, path-scope match, timestamp coincidence, or absence of a known external writer is not attribution proof. Missing, partial, or contradictory provenance makes the delta ambiguous and takes the ambiguous route. The operator records a canonical delta-to-event mapping and `delta_attribution_evidence_sha256`; calibration derives each role/external/ambiguous route from fixtures with positive and negative provenance.

## Role lifecycle

```text
prospective safety screening
          |
          v
role preflight collector ---- fail ----> no launch / fail-closed route
          |
          v
role under calibrated sandbox
          |
          v
expire authority + quiesce role and descendants
          |
          v
identical postflight collector ---- fail ----> no later stage / fail-closed route
          |
          v
authorized result may advance
```

Every role has a passing preflight over its complete task-visible and writable surface under the current package, collector, root/classification, and enforcement identities. A preflight rejects multiply linked content before role launch rather than relying on the role to reject a later read.

Before postflight, the operator expires or revokes the role's authority, obtains the role's required completion/interruption evidence, and proves that the top-level runtime, all role-launched processes, and asynchronous tool or broker operations have completed, been terminated, or cannot mutate any collected root without a new independent human approval. A returned prompt, `CP2_READY`, a process-tree snapshot, or lack of recent output is not by itself quiescence evidence. The control must cover the runtime-managed execution group, reparenting, double-fork/daemonization, `setsid` or process-group escape, and broker-owned asynchronous jobs. An interactive runtime may remain only when it cannot act without a new human turn, the task authority has expired, and no descendant or asynchronous operation retains write capability to a collected root.

Failure to establish quiescence is `UNVERIFIED-quiescence`; the role postflight is unavailable and no later stage may use that role result. Only a started B with an incomplete final collector enters the incomplete-final reconciliation route. Other roles retain their actual result state and use the role-specific consequence below. Once quiescence is established, the identical collector runs outside the role boundary. A complete passing B postflight alone may form the canonical CP2 snapshot and launch Session C.

For read-only A1, A2, and C surfaces, postflight expects exact immutable equality. For B and `spike-temp`, contract-authorized reviewable or disposable deltas are allowed and fully recorded; prohibited, unclassified, or out-of-authority deltas are not mislabeled as ordinary implementation change.

Role completion evidence is specific: A1/A2 require a complete bounded discovery response and yield; `spike-temp` requires a complete bounded evidence response, frozen disposable output, and yield; B requires an observed `CP2_READY`, `STOP_REQUIRED`, or interruption state plus report freeze; C retains its actual `N/A-no-session-c`, `UNVERIFIED-no-session-c-result`, or `complete-result` evidence. Every launched role additionally requires the quiescence proof above.

| Gate | Failure consequence | Slot and attempt accounting |
|---|---|---|
| Prospective safety screening | Candidate-specific failure is recorded exclusion; arm-wide capability failure blocks the arm | Before enrollment; no slot or attempt for an excluded candidate |
| A1, A2, or optional-spike preflight | Do not launch. After evidence-backed remediation or proven restoration, rerun the recorded preflight; an invisible retry is prohibited | Enrolled slot remains; no role pass or attempt is consumed |
| Launched A1 or A2 postflight/quiescence | Invalidate the role output and prohibit CP1 | Enrolled slot remains; attempt has not started; no automatic second role pass, so the task blocks or is abandoned |
| Launched optional-spike postflight/quiescence | Invalidate the spike output; prohibit CP1 using it | Enrolled slot remains; attempt has not started; narrow under existing rules or block, never silently repeat the spike |
| B preflight after CP1 approval | Preserve `approved-but-not-started`, `session_b_started: no`; no B launch under that run | Attempt is consumed; only an unused sequence may return through CP1 |
| B final/postflight | Complete outcomes use normal-postflight routing; incomplete final uses B-only `post_run_reconciliation`; no C or ship on failure | Attempt is already consumed; next attempt follows the exact routing and unused-sequence gate |
| C preflight | Do not launch. After evidence-backed remediation or proven restoration, rerun preflight within the existing run bounds; set `N/A-no-session-c` only if the run terminates without launching C | Current attempt remains consumed; no C pass is consumed before launch |
| Launched C postflight/quiescence | Preserve the actual C result state, set `role_postflight_gate: fail`, invalidate the review, and prohibit ship; never invent B reconciliation | Current attempt remains consumed; existing human disposition and unused-sequence rules apply |
| Pre-disposition or pre-delivery live check | Preserve the existing v1 mismatch fields and prohibit disposition/delivery from the old review | Existing v1 next-attempt rule applies; these checks are not relabeled as role postflight |

A proven operator/external change found by a role preflight may be restored or quarantined and rechecked before that role launches, except that a CP1-approved B preflight failure ends that run through its explicit table route. A preflight may be rerun only after the failed observation and remediation evidence are retained; inability to prove remediation or a passing recheck blocks or abandons the task, while an arm-wide capability failure blocks the arm. Once a role has launched, its invalidated output is never revived by a later clean scan, and v2 grants no extra role pass or attempt beyond the table and existing bounds.

The lack of a pre-CP1 re-pass after a launched A1, A2, or spike postflight failure is deliberate. A re-pass would hide observer/environment mistakes, weaken the one-pass role bounds, and add a replacement path outside the fixed-slot measurement. A proven clean restoration can establish safe terminal state but cannot validate or replace the consumed role output. The resulting narrow, block, abandonment, and possible permanent slot loss remain full-burden pilot evidence. Preflight rerun is different because the role never launched and no role pass or output was consumed. ADR 0031 records this consequence explicitly.

Routing precedence is fail-closed. In any role, an independently proven role-attributed prohibited delta overrides the table and enters `PAUSED_HARD`. For a launched non-B role, `UNVERIFIED` quiescence, collection, surface coverage, or attribution forces `hard_gates_all_clear: no` and task non-qualification. For a started B with an incomplete final collector, the same uncertainty forces hard gates `no` only while B-only `post_run_reconciliation` is pending; the existing outcomes then govern. `reconciled-clear` removes only that pending hard-gate effect while the old B result remains no-Session-C/no-ship, `reconciliation-unverified` forces hard gates `no` and task non-qualification, `external-drift-restore-required` remains pending until a repeat reconciliation, and `unauthorized-hard-failure` enters `PAUSED_HARD`. The table's ordinary repair, narrow, next-attempt, block, or abandonment route applies only when neither override is present. Per-role postflight records therefore include `role_postflight_gate`, `role_postflight_hard_gate_effect`, `task_qualification_effect`, and the evidence-backed route derivation.

## Load-bearing session enforcement

The runtime/OS boundary must deny hard-link creation before mutation for every role, including roles that declare no writable root. Controls exercise both source and destination across approved read-only roots, approved writable roots, protected/denied/outside roots, and every explicit or implicit temporary/cache root available to the runtime. For each attempt, the destination must remain absent and the source device/inode/link count and content digest must remain unchanged. Controls cover the role, its tools, and direct syscall attempts by descendants; testing only an `ln` command is insufficient.

The boundary also continues to deny symlink creation and traversal, writes through aliases, outside-to-inside rename/import or replacement paths, protected write/delete/rename/link/replacement, resolved containment outside exact writable roots, Git-control mutation, credentials and secret-bearing environment/socket access, undeclared network egress, unapproved brokered operations and selectors, and external-state writes as required by v1.

If either runtime cannot prove hard-link creation denial before destination creation for all five roles and every applicable source/destination class, or cannot prove execution-group quiescence including detached and broker-owned work, that arm remains blocked. Postflight detection and a permission prompt are not substitutes and do not authorize an automatic relaxation.

## Integrity outcomes and state routing

An authorized B change is review delta, not drift. Drift means a protected, immutable, prohibited, out-of-authority, unclassified, or externally caused delta, an unstable collection, or a mismatch in a state required to remain exact.

Normal complete postflight and `post_run_reconciliation` remain separate artifact stages:

- A complete, authorized postflight with exact immutable/protected state follows the normal next-stage route.
- A prohibited delta attributable to the role or its descendants is `unauthorized-hard-failure` and enters `PAUSED_HARD`.
- Proven operator/external drift in a complete postflight invalidates the role result and records `normal-postflight-external-drift`. It permits no Session C or `ship`. The operator must safely restore or quarantine the state and repeat the identical collector. A clean repeat proves only restored state: it never revives the invalidated output or independently grants another role pass or attempt. Recovery and attempt accounting follow the role/stage table; where that table permits a later attempt, it additionally requires the clean result and an unused sequence. Its `post_run_reconciliation` fields remain `N/A-complete-final-collector`.
- A complete initial role postflight with ambiguous attribution, or incomplete or unproved restoration of that postflight mismatch, is `normal-postflight-unverified`: hard gates `no`, task non-qualifying, no later stage or attempt, then `block` or abandonment. Without independent hard-failure evidence it does not enter `PAUSED_HARD`. Later pre-disposition and pre-delivery live checks retain their separate v1 next-attempt route.
- A missing or incomplete final collector preserves original fields as `N/A-not-created` or `UNVERIFIED-collection-failed`. Later work never backfills them. Only then does the separate v1-compatible `post_run_reconciliation` run against the frozen baseline, using `reconciled-clear`, `external-drift-restore-required`, `reconciliation-unverified`, or `unauthorized-hard-failure` with their existing meanings.

`next_attempt_allowed: yes` continues to require an unused sequence and, whenever reconciliation was required, `reconciled-clear`. An interrupted B's approved deltas are carried into the next run's pre-existing-change attribution and final review bundle. A complete postflight mismatch is recorded in the normal-postflight fields rather than being mislabeled as an incomplete-final reconciliation.

The existing attempt boundary remains unchanged: prospective screening precedes enrollment and starts no attempt; the first CP1 presentation starts an attempt; an approved-but-not-started B preflight failure preserves its ledger variant and consumes that attempt. After enrollment, every adverse result remains attached to its fixed slot.

For a Work candidate or task, any task-visible read-path integrity failure or uncertainty in its screening, A1, A2, spike, B, C, or later observation suppresses every generalized-learning statement derived from that candidate or task, even though raw artifacts already remain local. This includes pre-enrollment and pre-CP1 observations, `UNVERIFIED-collection-failed`, `UNVERIFIED-quiescence`, incomplete surface coverage, ambiguous attribution, and unproved restoration. It prevents an unobserved or potentially unintended disclosure from influencing a transferable abstraction.

## Zero-build collector form

The v2 package remains Markdown-only. It may contain an exact package-digest-covered operator command or ephemeral inline program inside Markdown, but it installs and commits no persistent or reusable executable, runner, adapter, hook, Skill, workflow, service, runtime configuration, or generated state. Operators execute the rendered invocation unchanged and retain its digest and provenance.

Calibration runs the collector twice on an unchanged fixture and requires identical canonical manifest digests, then proves expected changes for content, metadata, inventory, and link-count mutations. Both environments must reproduce the same canonical schema and semantics; environment-specific tool and platform provenance remains local.

If approved platform tooling cannot reproducibly implement descriptor-bound no-follow hashing, stable inventory checks, canonical serialization, direct-syscall controls, or quiescence evidence, calibration stops. An approximate `find | shasum` workflow or manually asserted success is prohibited. Allowing a reusable helper requires a separate design and ADR amendment.

## Artifact and package deltas

The future v2 package adds or replaces at least these operator-owned records:

- `task_read_surface_inventory_sha256`
- `enforced_unscanned_denial_inventory_sha256`
- `collector_algorithm_sha256`
- `collector_identity_and_config_sha256`
- preflight and postflight safety-manifest digests
- preflight and postflight review-state-manifest digests
- scan completeness and process-quiescence evidence
- role link-creation control digest
- per-role postflight gate, hard-gate effect, task-qualification effect, and route derivation
- canonical delta-to-event attribution mapping and evidence digest
- normal-postflight outcome (`pass`, `unauthorized-hard-failure`, `normal-postflight-external-drift`, or `normal-postflight-unverified`) and attribution fields
- arm threat-model acceptance record id

The field migration is narrow and explicit:

| v1 field/control | v2 treatment |
|---|---|
| `approved_read_path_single_link_control_digest` | Replace with task-surface inventory, preflight safety-manifest, enforced-unscanned-denial, and collector identity/configuration digests |
| `read_path_alias_control.approved_root_hardlink_alias_denied_before_disclosure` / `NC-read-hardlink-alias` | Replace with pre-existing-alias rejection before role launch and its evidence-backed negative control |
| `read_path_alias_control.regular_files_single_link_before_content_read` and `read_regular_files_single_link_check_sha256` | Retain as collector-side rejection before content open/hash; no longer assert runtime per-read enforcement |
| `symlink_and_hard_link_creation_denied` / `NC-create-hardlink` | Retain and strengthen to all roles, direct syscalls, all applicable roots, and source/destination invariants |
| `approved_write_path_alias_preflight_digest`, writable single-link checks, protected-overlap controls, symlink controls, and resolved-containment controls | Retain unchanged and rerun under the v2 package identity |

Role enforcement summaries replace only their read-side runtime single-link proof with the v2 preflight/collector evidence. The collector's own rule that multiply linked content is never opened or hashed remains mandatory.

The package will contain `README.md`, `policy.md`, `collector.md`, `artifact-templates.md`, `calibration.md`, `codex-invocation.md`, `claude-invocation.md`, and `manifest.md`. The first seven files are package-digest-covered; `manifest.md` excludes itself. Runtime invocation payloads remain thin; operator-only threat-model, collector, reconciliation, and cohort rules are not copied into implementation-agent prompts unless the role needs a specific stop condition.

## Calibration and negative controls

Both runtime arms must demonstrate at least:

1. Two unchanged-fixture collections produce identical manifests, while a normal single-link file follows the positive path.
2. A pre-existing `nlink == 2` file in normal, hidden, ignored, temporary, and Session C input surfaces is rejected before content open/hash and before role launch.
3. An unscanned subtree is unreadable to the role; an unscannable but readable subtree blocks launch.
4. For all five roles, direct `link`/`linkat` equivalents and ordinary `ln` attempts are denied before destination creation across approved read-only, approved writable, implicit temp/cache, protected/denied, and outside source/destination classes; the source link count and content remain unchanged.
5. A create-read-unlink sequence cannot reach its read step and leaves source/destination metadata and content unchanged. A separate operator fixture documents that postflight alone cannot detect a completed transient alias.
6. Symlink creation/traversal, outside/protected rename, replacement, exchange/swap when supported, and applicable clone/import primitives are denied before mutation.
7. A same-inode content overwrite changes the review-state digest; an authorized atomic replacement becomes a complete review delta rather than an alias failure.
8. A new untracked, ignored, or disposable multiply linked path after baseline is detected by postflight.
9. An undeclared device/mount transition, unsupported special file, permission error, changing path inventory, or object replacement during collection fails closed.
10. A delayed writer, reparent/double-fork daemon, `setsid` or process-group escape, and asynchronous broker/tool job after a terminal marker are terminated or rendered unable to mutate by execution-group quiescence controls, or produce `UNVERIFIED-quiescence`.
11. Positive and negative transcript/tool/process provenance fixtures derive role-attributed, proven operator/external, and ambiguous drift into the three distinct routes above; a report self-claim alone never passes, and normal postflight and incomplete-final reconciliation never collapse into one state.
12. v1 and v2 manifests, calibration observations, and cohort results cannot be pooled.

Existing v1 controls for direct outside-root reads, symlink aliases, protected mutation, Git metadata, operator artifacts, credentials/environment/sockets, network, brokered tools, external state, contract/report ownership, Session C bundle integrity, and information transfer all rerun under the new package identity.

## Risks and consequences

- The excluded same-user transient race remains a confidentiality risk and must stay visible as human-owned accepted risk.
- Manual collection increases pilot overhead and can itself make the comfort gate fail; that is valid pilot evidence, not a reason to omit the work.
- Some repositories with hard-linked dependency or cache trees become ineligible unless those trees can be enforcement-denied without removing required task behavior.
- A runtime that cannot prove descendant quiescence or direct hard-link creation denial cannot run this arm.
- v2 may validate a comfortable outer loop under its stated boundary, but it does not validate microVM-grade isolation.
- A new schema/package and both-runtime recalibration discard pooling with v1 but preserve v1 observations as history.

## Design acceptance gate

This design is ready for ADR 0031 only when independent review confirms that:

- the amended guarantee and excluded threat are explicit;
- agent-created hard-link prevention remains denial-before-mutation and load-bearing;
- every role-readable surface is scanned or enforcement-denied;
- safety metadata and content evidence have separate responsibilities;
- authorized implementation changes are not treated as integrity drift;
- quiescence precedes final evidence collection;
- normal postflight and interrupted-run reconciliation are distinct;
- ambiguous attribution and failed restoration never gain a retry; and
- no unchanged v1 control is weakened accidentally.

After ADR 0031 is accepted, implementation planning may create the self-contained `week0-v2` package. No v2 package work begins from this design document alone.
