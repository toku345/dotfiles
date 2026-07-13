# Week 0 Artifact Templates

Schema: `outer-loop-week0/v1`

Copy these templates into approved environment-local state outside every repository. Replace every placeholder. Empty fields are invalid: use `NONE`, `N/A`, or `UNVERIFIED` explicitly. Digests use `sha256:<lowercase-hex>`.

The ownership and routing rules in [policy.md](policy.md) are authoritative. Agent agreement is never evidence. Evidence records include an observed fact or result summary in addition to a local reference or digest. When the operator transcribes another session's output, keep `reported_by` and `recorded_by` separate.

| Artifact | Sole writer |
|---|---|
| Screening, contract, scorecard, calibration, controls, company-arm summary, cohort, generalized learning, hard pause, canonical CP2 snapshot before freeze | Operator |
| Report before `CP2_READY` | Session B |
| Frozen report, Evidence Packet, and canonical CP2 snapshot | Nobody |
| Session C response | Session C response channel only; operator transcribes it into the scorecard |

## Screening log

Append one entry per candidate in arrival order. Do not delete, reorder, or silently omit excluded candidates.

```markdown
# Week 0 screening log

artifact_type: screening-log
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: operator
lifecycle_state: ACTIVE

## Candidate <sequence>

local_candidate_reference: <local-only reference>
originating_environment: <Private | Work>
originating_runtime_family: <Codex | Claude Code>
considered_at_local: <local-only value>
recorded_by: <operator>
provenance: <how this candidate entered the queue>
task_specific_screening_attention_minutes: <prospectively recorded value>
screening_attention_provenance: <timer/observation evidence>

### Thick-change indicators

user_visible_or_external_behavior: <yes | no> — <evidence>
cross_module_or_architecture: <yes | no> — <evidence>
security_data_or_invariant: <yes | no> — <evidence>
plan_changing_implementation_choice: <yes | no> — <evidence>

observable_locally_verifiable_acceptance_criteria: <yes | no> — <summary>
rollback_or_safe_abandonment_explainable: <yes | no> — <summary>
emergency: <yes | no>
mechanical_only: <yes | no>
irreversible_migration: <yes | no>
human_or_shared_state_dominated: <yes | no>
symlink_or_multiply_linked_file_mutation_required: <yes | no>

eligibility: <eligible | excluded>
exclusion_reason: <NONE | reason>
eligible_task_id: <opaque local id | N/A>
cohort_id: <opaque local cohort id | N/A-excluded>
cohort_arm: <Private-Codex | Work-Claude-Code | N/A-excluded>
cohort_slot: <1 | 2 | N/A-excluded-or-arm-full>
enrollment_candidate_sequence: <candidate sequence | N/A>
enrollment_recorded_at_local: <local-only value | N/A>
enrollment_irreversible: <yes | N/A>
replacement_prohibited: <yes | N/A>
dominant_class: <behavior-or-external-contract | architecture-or-cross-module | security-data-or-invariant | N/A>
scope_tier: <single-component | cross-component | N/A>
```

## Run contract

The operator owns this file. Hash the approved payload as exact UTF-8/LF text between the two marker lines, excluding both markers and including one terminal LF. Add the receipt after the end marker, make the whole file read-only, and store the final whole-file digest in the task scorecard. The whole-file digest MUST NOT be written into this file because that would be self-referential.

```markdown
# Week 0 run contract

<!-- BEGIN APPROVED CONTRACT PAYLOAD -->

artifact_type: run-contract
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: operator
lifecycle_state: CP1_APPROVED
task_id: <opaque machine-local id>
run_id: <opaque machine-local id>
run_sequence: <1 | 2>

## Identity and provenance

runtime_family: <Codex | Claude Code>
runtime_version: <version>
model: <model and version>
invocation_version: <document/package version>
operating_system: <local value>
driver_sources: <A1/A2/spike local records>
artifact_provenance: <sources used to form this contract>

enforcement_role: B-implementation
enforcement_profile_id: <id>
enforcement_config_digest: sha256:<digest>
passing_control_record_id: <local id>
approved_read_roots:
  - <path>
approved_write_roots:
  - <path>
credential_environment_socket_exposure: <passing control summary>
network_mode: <disabled | enforced-approved-read-only>
network_destination_allowlist_digest: <sha256:digest | N/A-disabled>
network_request_shape_allowlist_digest: <sha256:digest | N/A-disabled>
external_tool_surface_inventory_digest: sha256:<digest>
external_tool_read_only_operation_allowlist_digest: <sha256:digest | N/A-all-disabled>
approved_write_path_alias_preflight_digest: sha256:<symlink-free ancestors and single-link regular-file evidence>

human_approved_authority: <specific authority>
authority_scope: current-run-only
authority_expires_at: <CP2_READY, earlier stop, or interruption whose same-attempt continuity is not fully proven; transient interruption suspends use until proof>

## Goal

<one human-intent goal>

## Non-goals

- <explicit exclusion>

## Constraints and invariants

- <constraint or invariant>

## Acceptance Criteria

### AC-1 — <observable outcome>

verification_method: <command or probe>
required_provenance: <source/result requirements>

## Checkpoint 1 Unknowns

### U-1

origin: <A1 | A2 | spike>
claim_kind: <approved-assumption | risk-hypothesis | fact-gap | preference>
affected_behavior_or_interface: <value>
failure_if_false: <value>
related_goal_ac_invariant_or_authority: <mapping>
primary_evidence:
  source_kind: <code | primary-doc | baseline | command | other>
  local_source_reference: <local reference>
  observed_fact: <fact>
  provenance_or_digest: <value>
cheapest_falsification_probe: <probe>
discovery_action: <evidence-probe | bounded-exploration | throwaway-prototype | ask-human | accept-risk | block>
route: <resolved-before-cp1 | accepted-risk | block>
evidence_outcome: <supported | refuted | inconclusive>
status: <resolved | accepted-risk | blocked>
resolution_evidence: <observed fact and provenance>
accepted_risk_owner: <human owner | N/A>
human_answer: <answer | N/A>

## Authority and paths

read_only_contract_path: <path>
writable_report_path: <path>
writable_target_worktree_paths:
  - <path>
declared_disposable_temp_or_cache_paths:
  - <path>
permitted_commands:
  - <command and purpose>
approved_read_only_external_probes:
  - <probe | NONE>
explicitly_prohibited_operations:
  - stage, commit, push, draft PR, branch/worktree mutation, merge, deploy
  - Git metadata, other repositories, global configuration, credentials, persistent services/databases, external state
  - operator-owned pilot artifacts other than report.md

## Decision routing instantiated for this run

self_resolve: <contract-local, reversible, evidenced choices>
queue: <preferences safe to defer>
stop: <contract/security/data/shared-state/authority/evidence boundaries>
immediate_hard_stop_conditions:
  - <condition>

## Bounds

implementation_bound: <time or turn bound>
native_bound_enforcement: <yes | no>
bound_observation_method: <how report records it>

## CP2_READY conditions

`CP2_READY` is the complete-packet branch even when an Acceptance Criterion is honestly `FAIL` or `UNVERIFIED`; either value blocks `ship`. Use `STOP_REQUIRED` for a required stop, refuted approved assumption, exhausted bound, digest/echo failure, or inability to complete the packet safely. An unsupported pass claim is a hard failure.

- [ ] Echo-back matched and no handoff gap remains.
- [ ] Every Acceptance Criterion has PASS, FAIL, or explicit UNVERIFIED evidence.
- [ ] Every decision and implementation-time Unknown has complete mapping, route, evidence, and owner where required.
- [ ] Queued decisions and stop/re-gating events are visible.
- [ ] Bound compliance has observed evidence.
- [ ] Residual risk and rollback are recorded.
- [ ] Session B has not performed a prohibited delivery operation.
- [ ] The final report declares CP2_READY and Session B yields.

## Rollback or safe abandonment

<procedure>

## Checkpoint 1 packet

presentation_count: <1 | 2>
plan_changing_questions:
  - <question; maximum three | NONE>

<!-- END APPROVED CONTRACT PAYLOAD -->

## Operator approval receipt — excluded from approved payload digest

approval_result: approved
approved_by: <human>
approved_at_local: <local-only value>
approved_payload_sha256: sha256:<digest>
final_contract_file_sha256_location: task scorecard
contract_made_read_only: <yes | no>
```

If Checkpoint 1 chooses `narrow` or `block`, do not append this approval receipt or freeze the draft as an approved contract. Record that outcome in the task scorecard and create a new draft only when policy permits.

## Session B report

Only Session B writes this file. It does not contain independent-review findings, quiz records, final human disposition, company-arm fields, or advancement thresholds. At `CP2_READY`, the operator freezes it and records the digest elsewhere.

```markdown
# Week 0 Session B report

artifact_type: session-b-report
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: session-b
lifecycle_state: ACTIVE
task_id: <opaque machine-local id>
run_id: <opaque machine-local id>
approved_payload_sha256: sha256:<digest>
contract_file_sha256_observed: sha256:<digest>
contract_file_sha256_match: <yes | no>
runtime_family: <Codex | Claude Code>
runtime_version: <version>
model: <model and version>
invocation_version: <version>

## Contract echo-back

goal: <echo>
acceptance_criteria: <echo>
invariants: <echo>
authority_and_writable_paths: <echo>
bounds: <echo>
stop_conditions: <echo>
echo_back_result: <match | handoff-gap>
handoff_gap: <NONE | details>
implementation_started: <yes | no>

## Decision Log

### D-1

decision: <value>
related_goal_ac_invariant_or_authority: <mapping>
alternatives_considered: <values>
evidence:
  local_source_reference: <reference>
  observed_fact: <fact>
  provenance_or_digest: <value>
reversibility: <local and reversible | not reversible>
undo_path: <procedure>
route: <self-resolve | queue | stop>
resulting_change: <value | NONE>

## Implementation-time Unknowns

### IU-1

discovered_phase: <implementation | verification>
claim_kind: <approved-assumption | risk-hypothesis | fact-gap | preference>
affected_behavior_or_interface: <value>
failure_if_false: <value>
related_goal_ac_invariant_or_authority: <mapping>
current_evidence:
  local_source_reference: <reference>
  observed_fact: <fact>
  provenance_or_digest: <value>
cheapest_falsification_probe: <probe>
decision_route: <self-resolve | queue | stop>
evidence_outcome: <supported | refuted | inconclusive | UNVERIFIED>
status: <resolved | accepted-risk | blocked | UNVERIFIED>
resolution_evidence: <fact and provenance | UNVERIFIED>
accepted_risk_owner: <human owner | N/A | UNVERIFIED>

## Queued decisions and throwaway prototypes

### Q-1

preference_needed: <value>
safe_to_defer_because: <evidence>
prototype_path: <declared private temp path | N/A>
prototype_result: <evidence-only result | N/A>
production_wiring: none

## Operational event ledger

| Event | Kind | Request or observation | Agent route/result | Handling duration | Evidence |
|---|---|---|---|---:|---|
| E-1 | permission-prompt / interruption-request / stop / re-gating / prototype | <value> | <value> | <duration> | <fact/provenance> |

Session B does not classify interruption requests as genuine or false; that is an operator judgment after disposition.

## Evidence Packet

### AC-1 — <criterion>

verification_command_or_method: <value>
executed_by: <Session B or approved fixture>
result_or_exit_status: <value>
observed_result_summary: <fact>
output_provenance_or_digest: <value>
status: <PASS | FAIL | UNVERIFIED>

## Bound compliance

declared_bound: <value>
observed_result: <value>
observation_evidence: <value>
status: <compliant | overrun | N/A | UNVERIFIED>

## Explicit UNVERIFIED register

- <claim/check/Unknown and why it is unverified | NONE>

## Residual risk

- <risk, evidence, and proposed owner | NONE>

## Rollback

<validated or reasoned rollback procedure>

## Final Session B summary

changed_behavior: <summary>
key_decisions: <summary>
verification_summary: <summary>
remaining_items: <queued decisions and UNVERIFIED items>

## Run state

cp2_ready: <yes | no>
cp2_ready_reason: <evidence>
lifecycle_state: <ACTIVE | STOP_REQUIRED | CP2_READY>
```

## Task scorecard

The operator owns this durable record. Copy enough observed facts to keep it meaningful after every raw contract, report, path reference, and snapshot is removed. Pre-CP1 task-specific time, CP2 time, and permission handling are subsets of full-burden human attention; do not add them again when calculating attention.

```markdown
# Week 0 task scorecard

artifact_type: task-scorecard
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: operator
lifecycle_state: <ACTIVE | CP2_READY_WAIT | INTERRUPTED_NO_MARKER | TERMINAL | PAUSED_HARD>
task_id: <opaque machine-local id>
cohort_id: <opaque machine-local cohort id>
cohort_arm: <Private-Codex | Work-Claude-Code>
cohort_slot: <1 | 2>
enrollment_candidate_sequence: <screening sequence>
screening_log_sha256_at_enrollment: sha256:<digest>
screening_entry_sha256: sha256:<digest>
prior_eligible_entry_scan_sha256: sha256:<digest>
enrollment_derivation: <observed facts proving this is the next first-or-second eligible entry>
enrollment_gate: <pass | fail; derived from screening digests and sequence>
replacement_prohibited: yes

## Eligibility and baseline

screening_entry_reference: <local reference>
eligibility_evidence_summary: <self-contained facts>
dominant_class: <behavior-or-external-contract | architecture-or-cross-module | security-data-or-invariant>
scope_tier: <single-component | cross-component>
baseline_kind: <historical | estimated>
baseline_local_source: <local reference>
environment_runtime_workflow_match: <evidence>
recency_match: <within previous 10 eligible tasks or 90 days>
baseline_full_burden_attention_minutes: <number | estimated range under the same task boundary>
baseline_confidence_anchor: <1-5>
baseline_source_and_assumptions: <value>
baseline_frozen_before_task_specific_discovery: <yes | no>
comfort_eligible: <yes | no; estimated must be no>
pre_cp1_task_specific_attention_minutes: <included subset of task cumulative attention>
one_time_arm_setup_overhead_reference: <local arm-level record; not attributed to this task>
attempt_ledger:
  - run_id: <opaque local run id or draft-run id>
    run_sequence: <1 | 2>
    checkpoint_1_presentations:
      - presentation: <1 | 2>
        active_review_minutes: <value>
        evidence_or_reason: <self-contained value>
    checkpoint_1_outcome: <approved | narrow | block | abandonment>
    authority_status: <approved | not-approved>
    session_b_started: <yes | no>
    approved_run_ledger_reference: <run id below when authority_status is approved | N/A-CP1-not-approved>

## Self-contained task summary

goal: <summary>
non_goals: <summary>
invariants: <summary>
final_behavior: <current self-contained summary>

### Acceptance-Criterion outcomes

| AC | Observable criterion | Final status | Observed result | Provenance summary |
|---|---|---|---|---|
| AC-1 | <value> | PASS / FAIL / UNVERIFIED | <fact> | <provenance> |

### Major decisions and queued-decision outcomes

| Decision | Rationale and evidence | Human-reviewed final outcome | Reviewed by | Accepted-risk owner |
|---|---|---|---|---|
| <value> | <self-contained summary> | adopted / rejected / accepted-risk / superseded | <human> | <human owner / N/A> |

### All Unknown dispositions

#### Unknown <id>

origin: <CP1 | implementation | reviewer>
origin_run_id: <opaque local run id>
claim_kind: <approved-assumption | risk-hypothesis | fact-gap | preference>
affected_behavior_or_interface: <value>
failure_if_false: <value>
related_goal_ac_invariant_or_authority: <mapping>
current_primary_evidence:
  local_source_reference: <local reference or deleted-artifact provenance>
  observed_fact: <self-contained fact>
  provenance_or_digest: <value>
cheapest_falsification_probe: <probe>
route: <resolved-before-cp1 | accepted-risk | block | self-resolve | queue | stop>
evidence_outcome: <supported | refuted | inconclusive | UNVERIFIED>
status: <resolved | accepted-risk | blocked | UNVERIFIED>
resolution_evidence: <self-contained fact and provenance | UNVERIFIED>
accepted_risk_owner: <human owner | N/A | UNVERIFIED>

residual_risk_and_acceptance_owner: <value | NONE>
rollback: <self-contained procedure>
unresolved_or_unverified_items: <value | NONE>

## CP1-approved run ledger

Create exactly one variant below for every attempt whose Checkpoint 1 outcome was `approved`. CP1-only `narrow`, `block`, or abandonment remains in `attempt_ledger` and MUST NOT invent approved authority, contract, report, Evidence Packet, or snapshot fields.

### Variant A — approved but Session B not started

run_id: <opaque local id>
run_sequence: <1 | 2>
session_b_start_state: not-started-preflight-block
preflight_block_stage: <package | enforcement | canonical-baseline | other>
preflight_block_reason_and_evidence: <self-contained facts/provenance>
human_run_disposition: <narrow | redirect | block | abandonment>
human_approved_authority_summary: <self-contained authority granted for this run>
authority_scope: current-run-only
authority_expiry_or_end_condition: <preflight block>
approved_read_write_scope_summary: <self-contained roots/path classes>
permitted_command_and_probe_summary: <self-contained allowed operations>
prohibited_operation_summary: <self-contained boundaries used for hard-gate audit>
contract_payload_sha256: sha256:<digest>
contract_file_sha256: sha256:<digest>
session_b_artifacts: N/A-not-started

### Variant B — Session B started

For `CP2_READY`, every complete artifact and digest below is required. For `STOP_REQUIRED` or `INTERRUPTED_NO_MARKER`, preserve every actually observed artifact and collector result, use the exact value `N/A-not-created` for an absent artifact and `UNVERIFIED-collection-failed` for a failed observation, and never invent completeness. Both end states record no Session C and cannot support `ship`.

run_id: <opaque local id>
run_sequence: <1 | 2>
session_b_start_state: started
session_b_end_state: <CP2_READY | STOP_REQUIRED | INTERRUPTED_NO_MARKER>
terminal_marker_observed: <CP2_READY | STOP_REQUIRED | NONE>
terminal_marker_provenance: <conversation evidence | NONE-runtime-or-host-interruption>
operator_evidence_freeze_completeness: <complete | partial | UNVERIFIED>
observed_partial_evidence_summary: <self-contained list | NONE-complete>
runtime_host_interruption_events: <NONE | list of event, observed continuity properties, and resume/end result>
human_run_disposition: <ship | narrow | redirect | block | abandonment | N/A-pending>
human_approved_authority_summary: <self-contained authority granted for this run>
authority_scope: current-run-only
authority_expiry_or_end_condition: <CP2_READY, earlier stop, or interruption whose same-attempt continuity is not fully proven; transient interruption suspends use until proof>
approved_read_write_scope_summary: <self-contained roots/path classes>
permitted_command_and_probe_summary: <self-contained allowed operations>
prohibited_operation_summary: <self-contained boundaries used for hard-gate audit>
contract_payload_sha256: sha256:<digest>
contract_file_sha256: sha256:<digest>
report_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
evidence_packet_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
pre_session_b_canonical_baseline:
  head: <commit id or unborn>
  index_sha256: sha256:<digest>
  reviewable_worktree_manifest_sha256: sha256:<digest>
  reviewable_content_bundle_sha256: sha256:<digest>
  declared_disposable_exclusion_inventory_sha256: sha256:<digest>
  protected_exclusion_local_metadata_sha256: sha256:<digest>
  collector_provenance: <operator command/tool/version and local evidence>
  result: <pass | block>
canonical_cp2_change_snapshot:
  availability: <complete | partial | N/A-not-created | UNVERIFIED-collection-failed>
  baseline_snapshot_sha256: sha256:<digest of pre_session_b_canonical_baseline>
  final_head: <commit id or unborn | N/A-not-created | UNVERIFIED-collection-failed>
  final_index_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  final_reviewable_worktree_manifest_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  final_reviewable_content_bundle_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  declared_disposable_exclusion_inventory_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  final_protected_exclusion_local_metadata_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  protected_exclusions_unchanged_attestation_sha256: <sha256:digest exposed to Session C without paths/metadata | N/A-no-session-c | N/A-not-created | UNVERIFIED-collection-failed>
  changed_path_inventory_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  tracked_content_or_patch_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  non_disposable_untracked_or_ignored_content_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  file_modes_and_symlink_targets_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  pre_existing_change_attribution_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  canonical_snapshot_sha256: <sha256:digest | N/A-not-created | UNVERIFIED-collection-failed>
  all_changed_paths_covered: <yes | no | N/A-not-created | UNVERIFIED-collection-failed>
  protected_path_change_or_unreviewable_content: <NONE | STOP_REQUIRED | PAUSED_HARD | N/A-not-created | UNVERIFIED-collection-failed>
  session_c_review_bundle:
    result_state: <N/A-no-session-c | UNVERIFIED-no-session-c-result | complete-result>
    start_provenance: <N/A-no-session-c | local launch evidence>
    stable_logical_input_inventory_sha256: <sha256:digest | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
    required_logical_names_present: <yes | no | N/A-no-session-c | UNVERIFIED-no-session-c-result>
    expected_bundle_sha256: <sha256:digest | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
    session_c_recomputed_bundle_sha256: <sha256:digest | N/A-no-session-c | UNVERIFIED-no-session-c-result>
    every_input_hash_recomputed: <yes | no | N/A-no-session-c | UNVERIFIED-no-session-c-result>
    exact_match: <yes | no | N/A-no-session-c | UNVERIFIED-no-session-c-result>
    protected_path_or_metadata_details_absent: <yes | no | N/A-no-session-c | UNVERIFIED-no-session-c-result>
  pre_disposition_live_check:
    expected_canonical_snapshot_sha256: <sha256:digest | UNVERIFIED-no-complete-frozen-snapshot>
    observed_live_snapshot_sha256: <sha256:digest | UNVERIFIED-collection-failed>
    expected_protected_metadata_sha256: <sha256:digest | UNVERIFIED-no-complete-frozen-snapshot>
    observed_protected_metadata_sha256: <sha256:digest | UNVERIFIED-collection-failed>
    collector_provenance: <operator command/tool/version and local evidence | UNVERIFIED-collection-failed>
    exact_match: <yes | no | UNVERIFIED; derived from both digest pairs when present>
  pre_delivery_live_check:
    expected_canonical_snapshot_sha256: <sha256:digest | N/A-no-ship>
    observed_live_snapshot_sha256: <sha256:digest | N/A-no-ship>
    expected_protected_metadata_sha256: <sha256:digest | N/A-no-ship>
    observed_protected_metadata_sha256: <sha256:digest | N/A-no-ship>
    collector_provenance: <operator command/tool/version and local evidence | N/A-no-ship>
    exact_match: <yes | no | N/A-no-ship; derived from both digest pairs>
post_run_reconciliation:
  required: <yes-incomplete-final-collector | N/A-complete-final-collector>
  trigger: <STOP_REQUIRED-incomplete-final | INTERRUPTED_NO_MARKER | N/A-complete-final-collector>
  original_final_artifact_absence_preserved: <yes | no | N/A-complete-final-collector>
  completed_before_next_attempt_or_terminal_aggregation: <yes | no | N/A-complete-final-collector>
  frozen_pre_session_b_baseline_sha256: sha256:<digest>
  collector_identity_and_config_sha256: <sha256:digest | N/A-complete-final-collector>
  collection_status: <complete | UNVERIFIED-collection-failed | N/A-complete-final-collector>
  current_canonical_snapshot_sha256: <sha256:digest | UNVERIFIED-collection-failed | N/A-complete-final-collector>
  current_protected_metadata_sha256: <sha256:digest | UNVERIFIED-collection-failed | N/A-complete-final-collector>
  baseline_to_current_delta_inventory_sha256: <sha256:digest | UNVERIFIED-collection-failed | N/A-complete-final-collector>
  protected_metadata_exact_match: <yes | no | UNVERIFIED | N/A-complete-final-collector>
  every_delta_classified: <yes | no | UNVERIFIED | N/A-complete-final-collector>
  delta_attribution: <none-or-approved-session-b-only | session-b-unauthorized | proven-operator-or-external | ambiguous | UNVERIFIED | N/A-complete-final-collector>
  attribution_evidence: <self-contained facts/provenance | UNVERIFIED | N/A-complete-final-collector>
  outcome: <reconciled-clear | external-drift-restore-required | reconciliation-unverified | unauthorized-hard-failure | N/A-complete-final-collector>
  next_attempt_allowed: <yes | no | N/A-complete-final-collector>
  hard_gates_all_clear_effect: <no-change | force-no>
  task_qualification_effect: <no-change | non-qualifying>
  route: <next-attempt-if-unused | restore-and-reconcile-again | block-or-abandon | PAUSED_HARD | N/A>

Post-run reconciliation never replaces the original final-artifact values. `next_attempt_allowed: yes` requires `outcome: reconciled-clear` and an unused sequence. `reconciliation-unverified` or `unauthorized-hard-failure` forces hard gates `no` and task non-qualification; only the latter enters `PAUSED_HARD`. Top-level hard gates can be `yes` only when every started run has either a complete final collector or `reconciled-clear`.

package_checks:
  pre_discovery:
    observed_digest: sha256:<digest>
    manifest_match: <yes | no>
    last_calibration_match: <yes | no>
    evidence_or_control_reference: <local value>
  pre_session_b:
    observed_digest: sha256:<digest>
    manifest_match: <yes | no>
    last_calibration_match: <yes | no>
    evidence_or_control_reference: <local value>
  pre_session_c:
    observed_digest: <sha256:digest | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
    manifest_match: <yes | no | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
    last_calibration_match: <yes | no | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
    evidence_or_control_reference: <local value | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
pre_discovery_worktree_integrity:
  before:
    head: <commit id or unborn>
    status_sha256: sha256:<digest>
    index_sha256: sha256:<digest>
    diff_sha256: sha256:<digest>
  after_A1_A2_or_spike:
    head: <commit id or unborn>
    status_sha256: sha256:<digest>
    index_sha256: sha256:<digest>
    diff_sha256: sha256:<digest>
  exact_match: <yes | no>
  evidence_or_control_reference: <local value>
  checkpoint_1_gate: <pass | block>
role_bound_compliance:
  A1-discovery:
    declared_bound: 20 minutes
    observed_result: <value>
    status: <compliant | overrun | UNVERIFIED>
    evidence: <local timer/provenance>
  A2-blind-spot:
    declared_bound: 10 minutes
    observed_result: <value>
    status: <compliant | overrun | UNVERIFIED>
    evidence: <local timer/provenance>
  spike-temp:
    declared_bound: <20 minutes | N/A-not-used>
    observed_result: <value | N/A>
    status: <compliant | overrun | N/A | UNVERIFIED>
    evidence: <local timer/provenance | N/A>
  B-implementation:
    declared_bound: <CP1-approved time or turn bound>
    observed_result: <value>
    status: <compliant | overrun | UNVERIFIED>
    evidence: <report fact/provenance>
  C-review:
    declared_bound: <20 minutes | N/A-no-session-c>
    observed_result: <value | N/A-no-session-c>
    status: <compliant | overrun | UNVERIFIED | N/A-no-session-c>
    evidence: <local timer/provenance | N/A-no-session-c>
runtime_model_by_role:
  A1-discovery: <runtime/model>
  A2-blind-spot: <runtime/model>
  spike-temp: <runtime/model | N/A>
  B-implementation: <runtime/model>
  C-review: <runtime/model | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
enforcement_by_role:
  A1-discovery: <profile/config, roots, writable alias/link checks or N/A, credential/environment/socket exposure, network and external-tool allowlist digests, passing control id>
  A2-blind-spot: <profile/config, roots, writable alias/link checks or N/A, credential/environment/socket exposure, network and external-tool allowlist digests, passing control id>
  spike-temp: <profile/config, roots, writable alias/link checks, credential/environment/socket exposure, network and external-tool allowlist digests, passing control id | N/A>
  B-implementation: <profile/config, roots, writable alias/link checks, credential/environment/socket exposure, network and external-tool allowlist digests, passing control id>
  C-review: <profile/config, roots, writable alias/link checks N/A, credential/environment/socket exposure, network and external-tool allowlist digests, passing control id | N/A-no-session-c | UNVERIFIED-prelaunch-missing>
goal_lifecycle_observation: <ACTIVE -> CP2_READY_WAIT/terminal behavior | INTERRUPTED_NO_MARKER>
handoff_gap: <NONE | self-contained summary>
hard_failure: <NONE | trigger and local incident id>

Session C state is consistent across this scorecard. `N/A-no-session-c` means no launch and requires `N/A-no-session-c` in the pre-Session-C package check and C role fields. `UNVERIFIED-no-session-c-result` means launch occurred: package check, runtime, enforcement, start provenance, logical-input inventory, and expected bundle use observed values; the C bound is `overrun` or `UNVERIFIED`; and the independent-review record below is required. A missing required prelaunch value uses `UNVERIFIED-prelaunch-missing`, prohibits a valid launch, and forces hard gates `no` rather than inventing evidence. `complete-result` permits no N/A or no-result sentinel in required result fields. Any `overrun` or `UNVERIFIED` bound remains visible in terminal qualification. A C-review timeout blocks `ship`; do not convert it to a completed review.

## Independent review and understanding gate — repeat for every started Session C; omit only for `N/A-no-session-c`

If Session C starts but does not return a complete usable result, preserve any observed partial output and provenance, set `review_artifact_state: UNVERIFIED-no-session-c-result`, use the same sentinel for unreturned scalar values, set existing yes/no verification values to `UNVERIFIED`, and set `review_validity` and `quiz_gate` to `fail`. When a list availability field has that sentinel, omit its child list rather than inventing entries.

run_id: <opaque local run id>
review_mode: <same-model | cross-model | UNVERIFIED-prelaunch-missing>
reported_by: <Session C runtime/model | UNVERIFIED-prelaunch-missing>
recorded_by: <operator>
review_artifact_state: <UNVERIFIED-no-session-c-result | complete-result>
review_artifact_sha256: <sha256:digest of complete or partial observed output | UNVERIFIED-no-session-c-result>
result_or_no_result_provenance: <local evidence>
fresh_context:
  status: <pass | fail | UNVERIFIED>
  evidence: <new-session observation and provenance>
blind_first_order:
  goal_ac_snapshot_and_verification_reviewed_before_driver_decision_log: <yes | no | UNVERIFIED>
  evidence: <ordered observation and provenance>
  status: <pass | fail | UNVERIFIED>
snapshot_input_verification:
  expected_session_c_review_bundle_sha256: <sha256:digest | UNVERIFIED-prelaunch-missing>
  session_c_recomputed_review_bundle_sha256: <sha256:digest | UNVERIFIED-no-session-c-result>
  required_logical_names_present: <yes | no | UNVERIFIED>
  every_delivered_input_hash_recomputed: <yes | no | UNVERIFIED>
  complete_reviewable_path_inventory_observed: <yes | no | UNVERIFIED>
  protected_exclusion_unchanged_attestation_received: <yes | no | UNVERIFIED>
  protected_path_or_metadata_details_absent: <yes | no | UNVERIFIED>
  review_bundle_digest_match: <yes | no | UNVERIFIED>
review_validity: <pass | fail; no-result is fail; pass requires fresh context, blind-first order, exact required logical-name inventory, recomputed exact-byte bundle/input hashes, complete reviewable snapshot, protected unchanged attestation without protected detail, and digest match>
review_findings_availability: <complete | UNVERIFIED-no-session-c-result>
review_findings:
  - finding: <value>
    observed_evidence: <fact/provenance>
    disposition: <resolved | accepted-risk | blocks-ship>
    resolution_evidence: <value | UNVERIFIED>
    accepted_risk_owner: <human owner | N/A | UNVERIFIED>
reviewer_discovered_unknowns_availability: <complete | UNVERIFIED-no-session-c-result>
reviewer_discovered_unknowns:
  - unknown: <value>
    claim_kind: <approved-assumption | risk-hypothesis | fact-gap | preference>
    affected_behavior_or_interface: <value>
    failure_if_false: <value>
    related_goal_ac_invariant_or_authority: <mapping>
    current_evidence_and_provenance: <fact>
    cheapest_falsification_probe: <value>
    route: <self-resolve | queue | stop>
    evidence_outcome: <supported | refuted | inconclusive | UNVERIFIED>
    status: <resolved | accepted-risk | blocked | UNVERIFIED>
    resolution_evidence: <value | UNVERIFIED>
    accepted_risk_owner: <value | N/A | UNVERIFIED>
understanding_questions_availability: <complete | UNVERIFIED-no-session-c-result>
understanding_questions:
  - question_id: Q1
    question: <behavior/invariant/decision/risk/rollback question>
    answer_rounds:
      - round: 1
        human_answer: <value>
        cited_evidence: <value>
        result: <correct | miss | resolved-by-evidence>
    foundational_misunderstanding: <yes | no>
quiz_gate: <pass | fail>
wrong_queued_decisions: <NONE | self-contained summary | UNVERIFIED-no-session-c-result>
residual_risk_acceptance: <owner/evidence | NONE | UNVERIFIED-no-session-c-result>

## Per-run and cumulative measurements

| Metric | Run 1 | Run 2 | Task cumulative |
|---|---:|---:|---:|
| CP1 active-review minutes | <n> | <n/N/A> | <n> |
| CP1 packet presentations | <n> | <n/N/A> | <n> |
| Pre-CP1 task-specific attention minutes (included subset) | <n> | <n/N/A> | <n> |
| Full-burden active human attention minutes | <n> | <n/N/A> | <n> |
| CP2 active-review minutes | <n> | <n/N/A> | <n> |
| Permission prompts | <n> | <n/N/A> | <n> |
| Permission-handling minutes | <n> | <n/N/A> | <n> |
| Unscheduled interruption requests | <n> | <n/N/A> | <n> |
| Genuine / false / pending | <g/f/p> | <g/f/p> | <g/f/p> |
| Quiz-answer rounds | <n> | <n/N/A> | <n> |
| Re-gates | <n> | <n/N/A> | <n> |
| Handoff gaps | <n> | <n/N/A> | <n> |
| Wrong queued decisions | <n> | <n/N/A> | <n> |
| Unverified pass claims | <n> | <n/N/A> | <n> |
| Hard failure | <yes/no> | <yes/no/N/A> | <logical OR> |

At terminal disposition, pending interruption classification MUST be zero.

## Terminal disposition and qualification

terminal_disposition: <ship | block | abandonment | redirected-goal-replaced>
ship_gate:
  all_acceptance_criteria_pass: <pass | fail>
  all_unknowns_terminal_with_evidence_outcome_resolution_and_owner: <pass | fail>
  all_queued_decisions_human_reviewed_and_terminal: <pass | fail>
  session_c_result_state_complete: <pass | fail>
  session_c_review_bundle_complete_and_recomputed_digest_matched: <pass | fail>
  operator_local_canonical_snapshot_and_protected_metadata_match: <pass | fail; derived from pre-disposition canonical and protected-metadata digest pairs>
  session_c_fresh_context_and_blind_first: <pass | fail>
  session_c_review_complete_within_bound: <pass | fail>
  all_review_findings_resolved_or_human_owned_accepted_risk: <pass | fail; blocks-ship is fail>
  quiz_gate_pass: <pass | fail>
  overall: <pass | fail; terminal ship requires every component pass and top-level hard_gates_all_clear yes>
full_burden_attention_ratio_to_historical_baseline: <ratio | N/A>
full_burden_attention_delta: <lower | same | higher | diagnostic-only>
terminal_confidence_anchor: <1-5>
confidence_delta: <lower | same | higher>
all_started_runs_complete_final_or_reconciled_clear: <yes | no>
hard_gates_all_clear: <yes | no; yes requires every started run to have a complete final collector or reconciled-clear post-run reconciliation and no other hard failure>
all_role_bounds_compliant: <pass | fail; any overrun or UNVERIFIED is fail>
comfort_checks:
  historical_baseline: <pass | fail>
  all_role_bounds_compliant: <pass | fail>
  lower_full_burden_attention: <pass | fail>
  equal_or_higher_confidence: <pass | fail>
  cumulative_cp2_within_threshold: <pass | fail>
  quiz_gate: <pass | fail>
  unscheduled_interruptions_within_threshold: <pass | fail>
task_comfort_result: <qualifying | non-qualifying; hard_gates_all_clear no requires non-qualifying>
prior_hard_pause_acknowledgement: <NONE | local reference and effect>

## Retention and cleanup

raw_artifact_status: <retained-until | deleted-under-policy>
self_containment_check: <pass | fail and missing facts>
scorecard_retain_through_final_decision: <yes | no>
local_abstraction_candidates: <value | NONE>
cleanup_status: <pending | complete>
```

## Company-arm summary

This transfer payload contains exactly the seven allowlisted fields. Do not add headers, approval metadata, dates, ids, reasons, or comments to the transferred instance.

```yaml
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
runtime_family: Claude Code
completed_task_count: <integer>
all_hard_gates_clear: <true | false>
comfort_qualifying_task_count: <integer>
at_least_one_ship: <true | false>
```

Before transfer, Private creates a random non-identifying single-use challenge for the current schema/package decision. Work serializes this separate integrity envelope as exact UTF-8/LF text in the field order below with one terminal LF and no extra field, then transfers the envelope and seven-field payload atomically through the authenticated company-permitted path. The envelope contains no Work-derived result beyond values already present in the payload.

```yaml
envelope_version: outer-loop-week0-summary-envelope/v1
purpose: company-arm-summary
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
payload_sha256: sha256:<digest>
private_single_use_challenge: <random non-identifying challenge>
```

Keep this separate Work-local receipt out of the transfer payload:

```markdown
# Company-arm summary approval receipt — Work-local only

artifact_type: company-arm-summary-receipt
owner: Work operator
summary_payload_sha256: sha256:<digest>
cohort_local_id: <Work-local id>
screening_log_sha256: sha256:<digest>
fixed_slot_rollups:
  slot_1:
    screening_entry_sha256: sha256:<digest>
    enrolled_candidate_sequence: <Work-local sequence>
    terminal_scorecard_sha256: sha256:<digest>
    eligibility_and_terminal_facts: <Work-local observed facts/provenance>
  slot_2:
    screening_entry_sha256: sha256:<digest>
    enrolled_candidate_sequence: <Work-local sequence>
    terminal_scorecard_sha256: sha256:<digest>
    eligibility_and_terminal_facts: <Work-local observed facts/provenance>
enrollment_derivation: first two eligible screening entries map exactly to slots 1 and 2 and both terminal scorecards
replacement_scan_provenance: <screening/scorecard comparison evidence>
fixed_slot_gate: <pass | fail; derived from enrollment_derivation and replacement scan>
derived_from_terminal_task_rollups: <yes | no>
allowlist_exactly_matched: <yes | no>
reconstructability_check: <pass | fail>
prohibited_field_check: <pass | fail>
permitted_transfer_path_confirmed: <yes | no | N/A-no-transfer>
authenticated_integrity_preserving_path: <yes | no | N/A-no-transfer>
private_single_use_challenge_received: <random non-identifying challenge | N/A-no-transfer>
transport_envelope_sha256: <sha256:digest | N/A-no-transfer>
authenticated_channel_provenance: <local verified sender/channel record | N/A-no-transfer>
summary_issuance_state: <unissued | issued-once | revoked | N/A-no-transfer>
human_transfer_decision: <approved | remain-local>
```

## Generalized-learning statement

The transferable payload MUST be generally applicable and not associated by content or timing with a Work task or the company-arm summary. Keep approval metadata in a separate Work-local receipt.

```markdown
# Generalized learning

generally_applicable_phenomenon: <value>
applicability_conditions: <value>
proposed_shared_rule: <value>
```

```markdown
# Generalized-learning approval receipt — Work-local only

artifact_type: generalized-learning-receipt
owner: Work operator
payload_sha256: sha256:<digest>
task_or_summary_link_absent: <yes | no>
timing_association_absent: <yes | no>
internal_detail_absent: <yes | no>
raw_measurement_absent: <yes | no>
abstraction_check: <pass | fail>
reconstructability_check: <pass | fail>
human_transfer_decision: <approved | remain-local>
```

## Private cohort record

Choose one mode and delete the other blank template. Never combine their fields.

### Mode: approved-summary

```markdown
# Week 0 cohort decision — approved-summary

artifact_type: cohort-decision
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: Private operator
mode: approved-summary
lifecycle_state: <ACTIVE | TERMINAL | PAUSED_HARD>

private_task_records:
  - task_id: <local Private id>
    cohort_slot: 1
    screening_entry_sha256: sha256:<digest>
    enrollment_evidence: <first eligible candidate and no replacement, with local provenance>
    task_result: <self-contained local result>
  - task_id: <local Private id>
    cohort_slot: 2
    screening_entry_sha256: sha256:<digest>
    enrollment_evidence: <second eligible candidate and no replacement, with local provenance>
    task_result: <self-contained local result>

company_arm_summary_receive_verification:
  envelope_version_and_purpose_exact: <yes | no>
  authenticated_sender_and_channel_provenance: <Private-local evidence>
  expected_outstanding_private_challenge: <random non-identifying challenge>
  received_private_challenge: <value>
  challenge_was_outstanding_and_unconsumed: <yes | no>
  envelope_schema_and_package_match_current_decision: <yes | no>
  envelope_payload_sha256: sha256:<digest>
  private_received_payload_sha256: sha256:<digest>
  exact_payload_hash_match: <yes | no>
  atomic_envelope_and_payload_receive: <yes | no>
  replay_absent: <yes | no>
  challenge_consumption_recorded_atomically: <yes | no>
  result: <pass | fail; fail requires in-place-no-transfer>

approved_company_arm_summary:
  schema_version: outer-loop-week0/v1
  package_digest: sha256:<digest>
  runtime_family: Claude Code
  completed_task_count: <integer>
  all_hard_gates_clear: <true | false>
  comfort_qualifying_task_count: <integer>
  at_least_one_ship: <true | false>

combined_all_hard_gates_clear: <true | false>
total_comfort_qualifying_task_count: <integer>
codex_ship_coverage: <true | false>
claude_ship_coverage: <true | false>
private_local_prior_cohort_observations: <Private-local references | NONE>
private_local_prior_hard_failure_and_remediation_acknowledgement: <Private-local value | NONE>
human_decision: <advance | revise-and-rerun | stop>
approved_by: <human>
```

Do not place prior Work observations in either Private-local field. Do not use this mode when a prior Work hard failure requires acknowledgment, and do not record that Work-derived fact on Private. Use `in-place-no-transfer`; the Work-local decision record carries the acknowledgment.

### Mode: in-place-no-transfer

Do not record Work-derived counts, coverage, gates, reasons, combined evidence, or values reconstructed by subtraction. A generalized-learning statement is a separate artifact and MUST satisfy its non-association rule; it is not a cohort result or proxy decision.

```markdown
# Week 0 cohort decision — in-place-no-transfer

artifact_type: cohort-decision
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: Private operator
mode: in-place-no-transfer
lifecycle_state: <ACTIVE | TERMINAL | PAUSED_HARD>

private_task_records:
  - task_id: <local Private id>
    cohort_slot: 1
    screening_entry_sha256: sha256:<digest>
    enrollment_evidence: <first eligible candidate and no replacement, with local provenance>
    task_result: <self-contained local result>
  - task_id: <local Private id>
    cohort_slot: 2
    screening_entry_sha256: sha256:<digest>
    enrollment_evidence: <second eligible candidate and no replacement, with local provenance>
    task_result: <self-contained local result>

work_comparison: completed_in_place
work_derived_values_stored_on_private: false
decision_state: awaiting_external_decision
shared_skill_phase_authorized: false
```

Keep the actual in-place comparison decision in this Work-local receipt and never transfer it or copy its fields into the Private cohort record:

```markdown
# Week 0 in-place decision receipt — Work-local, never transfer

artifact_type: in-place-decision-receipt
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: Work operator
mode: in-place-no-transfer
retention_permitted_by_work_policy: <yes | no>
comparison_completed_in_place_without_copying_raw_results: <yes | no>
work_fixed_slot_rollups_verified_without_replacement: <yes | no>
prior_work_hard_failure_and_remediation_acknowledgement: <Work-local reference | NONE>
human_decision: <advance | revise-and-rerun | stop | undecided>
approved_by: <human | N/A-undecided>
remain_work_local: true
private_record_state: awaiting_external_decision
private_shared_skill_phase_authorized: false
```

If Work policy does not permit retaining this receipt, use `human_decision: undecided` only in transient review and treat the pilot as stopped or undecided; it cannot authorize advancement.

## Arm setup overhead record

Create one operator-owned record per arm. Keep it separate from every task total and historical baseline; it measures one-time adoption cost rather than recurring loop comfort.

```markdown
# Week 0 arm setup overhead

artifact_type: arm-setup-overhead
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: operator
cohort_arm: <Private-Codex | Work-Claude-Code>
one_time_package_setup_minutes: <value>
one_time_enforcement_setup_minutes: <value>
one_time_both_runtime_calibration_minutes: <value>
other_one_time_setup_minutes: <value | 0>
total_one_time_arm_setup_minutes: <derived sum>
timer_and_derivation_provenance: <local evidence>
excluded_from_task_attention_and_baselines: yes
```

## Local calibration record and comparison payload

Create one operator-owned passing-control record per role before referencing its id from a contract or scorecard:

```markdown
# Week 0 role enforcement control

artifact_type: role-enforcement-control
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: operator
control_record_id: <opaque local id>
role: <A1-discovery | A2-blind-spot | spike-temp | B-implementation | C-review>
runtime_model_invocation: <local values>
operating_system: <local value>
enforcement_profile_id: <id>
enforcement_config_digest: sha256:<digest>
approved_read_roots: <local values>
approved_write_roots: <local values | NONE>
writable_path_alias_preflight:
  canonical_lexical_and_resolved_write_roots: <paired local values | N/A-no-write-root>
  writable_entries_and_existing_ancestors_symlink_free: <yes | N/A-no-write-root | fail>
  writable_regular_files_single_link: <yes | N/A-no-existing-regular-file | N/A-no-write-root | fail>
  resolved_containment_enforced_per_operation: <yes | N/A-no-write-root | fail>
  multiply_linked_target_write_denied_per_operation: <yes | N/A-no-write-root | fail>
  symlink_and_hard_link_creation_denied: <yes | N/A-no-write-root | fail>
  evidence_digest: <sha256:digest | N/A-no-write-root>
credential_environment_socket_exposure:
  secret_bearing_environment_variables: <unavailable | fail>
  credential_keychain_agent_sockets: <unavailable | fail>
  runtime_internal_model_transport_outside_role_tool_boundary: <yes | no>
  evidence_without_secret_values: <operator observation/provenance>
network_mode: <disabled | enforced-approved-read-only>
network_destination_allowlist_digest: <sha256:digest | N/A-disabled>
network_request_shape_allowlist_digest: <sha256:digest | N/A-disabled>
external_tool_surface:
  inventory: <MCP/apps/browser/connectors and operation surfaces | NONE>
  inventory_digest: sha256:<digest>
  mode: <all-disabled | enforced-read-only-operation-allowlist>
  operation_allowlist_digest: <sha256:digest | N/A-all-disabled>
  otherwise_write_capable_channels_tested: <all | fail>
safe_negative_controls:
  - control_id: NC-outside-read-root
    fixture_or_sentinel_id: <harmless operator-state | other-repository | home-global-config | symlink-resolved-alias sentinel; repeat all four>
    attempted_operation: <read operation>
    pre_state_sha256: sha256:<digest>
    observed_result: <denied-before-disclosure | fail>
    exit_status: <value>
    denial_stage: <before-disclosure | fail>
    post_state_sha256: sha256:<digest>
    log_or_output_provenance: <local evidence without disclosed sentinel content>
    operator_verified: <yes | no>
  - control_id: <NC-outside-write-root | NC-write-symlink-alias | NC-write-hardlink-alias | NC-create-symlink | NC-create-hardlink | NC-git-metadata | NC-operator-artifact | NC-credential-source | NC-undeclared-egress | NC-external-state | NC-brokered-write-CHANNEL>
    fixture_or_sentinel_id: <harmless fixture>
    attempted_operation: <operation>
    pre_state_sha256: sha256:<digest>
    observed_result: <denied-before-mutation | denied-before-disclosure | denied-before-request | fail>
    exit_status: <value>
    denial_stage: <before-mutation | before-disclosure | before-request | fail>
    post_state_sha256: sha256:<digest>
    outside_target_pre_state_sha256: <sha256:digest | N/A-not-alias-control>
    outside_target_post_state_sha256: <sha256:digest | N/A-not-alias-control>
    log_or_output_provenance: <local evidence>
    operator_verified: <yes | no>
positive_controls:
  - control_id: <PC-approved-read | PC-approved-role-write>
    fixture_or_sentinel_id: <fixture>
    attempted_operation: <operation>
    pre_state_sha256: sha256:<digest>
    observed_result_and_exit_status: <value>
    post_state_sha256: sha256:<digest>
    log_or_output_provenance: <local evidence>
    operator_verified: <yes | no>
aggregate_derivation: every required control has complete evidence, expected pre/post state, and operator verification
result: <pass | fail; pass MUST be derived from aggregate_derivation, never entered independently>
recorded_by: <operator>
```

```markdown
# Week 0 local calibration record

artifact_type: calibration-record
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: operator
calibration_record_id: <opaque local id>
runtime_model_invocation: <local values>
routing_classifier_isolation:
  package_and_answer_key_inaccessible: <yes | no>
  only_classifier_briefing_and_scenario_inputs_provided: <yes | no>
  passing_isolation_record_id: <local id>
role_enforcement_records:
  A1-discovery: <profile/config, roots, writable alias/link checks or N/A, credential/environment/socket exposure, network/external-tool digests, derived-pass control id>
  A2-blind-spot: <profile/config, roots, writable alias/link checks or N/A, credential/environment/socket exposure, network/external-tool digests, derived-pass control id>
  spike-temp: <profile/config, roots, writable alias/link checks, credential/environment/socket exposure, network/external-tool digests, derived-pass control id>
  B-implementation: <profile/config, roots, writable alias/link checks, credential/environment/socket exposure, network/external-tool digests, derived-pass control id>
  C-review: <profile/config, roots, writable alias/link checks N/A, credential/environment/socket exposure, network/external-tool digests, derived-pass control id>

scenario_results:
  - scenario_id: CAL-01
    expected_route: <value>
    observed_route: <value>
    local_rationale_and_evidence: <value>
    result: <pass | fail>

goal_lifecycle_observation: <ACTIVE/CP2_READY_WAIT/terminal mapping>
success_rehearsal: <pass | fail and local evidence>
redirect_rehearsal: <pass | fail and local evidence>
restart_resume_rehearsal: <pass | fail and local evidence>
drift_or_remediation: <NONE | local record>
calibration_disposition: <ready | blocked>
```

Only this minimal payload may be compared across environments:

```yaml
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
routes:
  CAL-01: <self-resolve | queue | stop>
  CAL-02: <self-resolve | queue | stop>
  CAL-03: <self-resolve | queue | stop>
  CAL-04: <self-resolve | queue | stop>
  CAL-05: <self-resolve | queue | stop>
  CAL-06: <self-resolve | queue | stop>
```

## Hard-pause and remediation record

This record remains in the originating environment. Generalized remediation evidence does not bypass the normal Work abstraction and transfer gate.

```markdown
# Week 0 hard-pause and remediation record

artifact_type: hard-pause-remediation
schema_version: outer-loop-week0/v1
package_digest: sha256:<digest>
owner: operator
local_incident_id: <opaque local id>
originating_task_run_ids: <local-only values>
trigger_category: <information-boundary | ignored-stop | suppressed-question | weaker-route | unauthorized-operation | unverified-pass | frozen-evidence-mutation | merge-deploy>
detected_by: <value>
current_state: <PAUSED_HARD | DIAGNOSE | STOPPED | REVISED_POLICY | CONTROL_RECHECK_E2E | BOTH_RUNTIME_RECALIBRATION | HUMAN_RESUME_APPROVAL | NEW_COHORT>

state_transitions:
  - ACTIVE -> PAUSED_HARD: <local evidence>
  - PAUSED_HARD -> DIAGNOSE: <local evidence>
  - DIAGNOSE -> <STOPPED | REVISED_POLICY>: <decision>
  - REVISED_POLICY -> CONTROL_RECHECK_E2E: <evidence | N/A-stopped>
  - CONTROL_RECHECK_E2E -> BOTH_RUNTIME_RECALIBRATION: <evidence | N/A-stopped>
  - BOTH_RUNTIME_RECALIBRATION -> HUMAN_RESUME_APPROVAL: <minimal comparison evidence | N/A-stopped>
  - HUMAN_RESUME_APPROVAL -> <NEW_COHORT | STOPPED>: <human decision | N/A-stopped>

frozen_contract_report_diff_evidence_digests: <values>
cohort_stopped: <yes | no>
pilot_derived_transfers_stopped: <yes | no>
affected_roles_and_controls: <values>
local_root_cause: <value>
security_or_company_policy_reference: <local value | N/A>
diagnosis_outcome: <STOPPED | REVISED_POLICY>
final_state: <STOPPED | NEW_COHORT | pending>

revised_schema_package_policy_identity: <value | N/A>
affected_negative_controls: <pass/fail evidence | N/A>
end_to_end_rehearsal: <pass/fail evidence | N/A>
both_runtime_recalibration: <pass/fail minimal comparison | N/A>
generalized_remediation_evidence: <non-sensitive value | N/A>
human_resume_decision: <approved | denied | N/A>
new_cohort_identity: <local value | N/A>
prior_failure_acknowledged_in_later_decision: <yes | no | N/A>

direct_PAUSED_HARD_to_NEW_COHORT_transition: prohibited
```
