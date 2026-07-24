#!/usr/bin/env python3
"""Executable contract tests for the pr-review V2 scheduler.

The orchestrator is defined by SKILL.md rather than an importable runtime
module. This harness models its externally observable state transitions so the
abnormal ordering and ownership rules are exercised deterministically in CI.
It does not claim to replace live Codex runtime smoke testing.
"""

from __future__ import annotations

import dataclasses
import enum
import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL = REPO_ROOT / "private_dot_codex" / "skills" / "pr-review" / "SKILL.md"
CONTRACT_PATH = (
    REPO_ROOT
    / "private_dot_codex"
    / "skills"
    / "pr-review"
    / "references"
    / "v2-runtime-contract.json"
)
RETENTION_FIXTURE_PATH = (
    REPO_ROOT
    / "tests"
    / "codex"
    / "fixtures"
    / "pr_review_v2_retention_refill.json"
)
CONTRACT = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
if CONTRACT.get("sentinel") != "PR_REVIEW_V2_SCHEDULER_CONTRACT_V2":
    raise AssertionError(f"{CONTRACT_PATH}: unsupported scheduler contract")
DELIVERY_GRACE_MS = CONTRACT["delivery_grace_ms"]
STAGE_DEADLINES_MS = CONTRACT["stage_deadline_ms"]
MAX_CONCURRENCY = CONTRACT["max_concurrency"]


class TaskState(enum.Enum):
    WAITING = "waiting"
    USABLE = "usable"
    FATAL = "fatal"


@dataclasses.dataclass
class TaskEvidence:
    canonical_path: str
    role: str = ""
    stage_deadline_ms: int = STAGE_DEADLINES_MS["stage1"]
    final_payload: str | None = None
    final_at_ms: int | None = None
    seen_running: bool = False
    completed_at_ms: int | None = None
    retired_at_ms: int | None = None
    parent_interrupted: bool = False
    fatal_reason: str | None = None

    def receive_final(
        self,
        sender: str,
        payload: str,
        now_ms: int,
        *,
        valid: bool = True,
        cleanup_started: bool = False,
    ) -> None:
        if sender != self.canonical_path:
            return
        if cleanup_started:
            self.fatal_reason = "final arrived after cleanup started"
        elif not valid or not payload:
            self.fatal_reason = "invalid final payload"
        elif self.final_payload is None:
            self.final_payload = payload
            self.final_at_ms = now_ms
        elif self.final_payload != payload:
            self.fatal_reason = "conflicting duplicate final"

    def observe_status(
        self,
        status: str,
        now_ms: int,
        *,
        present: bool = True,
        full_snapshot: bool = True,
        unexpected_descendant: bool = False,
    ) -> None:
        if unexpected_descendant:
            self.fatal_reason = "unexpected descendant"
        elif not present:
            if not full_snapshot:
                self.fatal_reason = "task missing from incomplete snapshot"
            elif self.parent_interrupted:
                self.fatal_reason = "parent-interrupted task cannot retire successfully"
            elif self.completed_at_ms is not None:
                return
            elif self.seen_running:
                if self.retired_at_ms is None:
                    self.retired_at_ms = now_ms
            else:
                self.fatal_reason = "task disappeared before observed running"
        elif status in {"error", "interrupted"}:
            self.fatal_reason = f"terminal failure status: {status}"
        elif status == "running":
            self.seen_running = True
        elif status == "completed" and self.completed_at_ms is None:
            self.completed_at_ms = now_ms

    def mark_parent_interrupted(self) -> None:
        self.parent_interrupted = True

    @property
    def lifecycle_at_ms(self) -> int | None:
        candidates = [
            value
            for value in (self.completed_at_ms, self.retired_at_ms)
            if value is not None
        ]
        return min(candidates) if candidates else None

    def state(self, now_ms: int) -> TaskState:
        if self.fatal_reason is not None:
            return TaskState.FATAL
        lifecycle_at_ms = self.lifecycle_at_ms
        if (
            self.final_payload is not None
            and self.final_at_ms is not None
            and lifecycle_at_ms is not None
        ):
            if self.final_at_ms >= lifecycle_at_ms + DELIVERY_GRACE_MS:
                self.fatal_reason = "final delivered after grace"
                return TaskState.FATAL
            if max(self.final_at_ms, lifecycle_at_ms) >= self.stage_deadline_ms:
                self.fatal_reason = "evidence completed after stage deadline"
                return TaskState.FATAL
            return TaskState.USABLE
        if (
            lifecycle_at_ms is not None
            and now_ms >= lifecycle_at_ms + DELIVERY_GRACE_MS
        ):
            self.fatal_reason = "final delivery grace expired"
            return TaskState.FATAL
        if now_ms >= self.stage_deadline_ms:
            self.fatal_reason = "stage deadline expired"
            return TaskState.FATAL
        return TaskState.WAITING


class SpawnDecision(enum.Enum):
    ADOPT = "adopt"
    WAIT_FOR_SLOT = "wait-for-slot"
    RETRY = "retry"
    FATAL = "fatal"


def reconcile_spawn_error(
    requested_name: str,
    names_before: list[str],
    names_after: list[str],
    *,
    explicit_capacity_error: bool,
    attempt: int,
    running_count: int,
    proposed_retry_name: str | None = None,
) -> SpawnDecision:
    if requested_name in names_before:
        return SpawnDecision.FATAL
    matches = [name for name in names_after if name == requested_name]
    if len(matches) == 1:
        return SpawnDecision.ADOPT
    if len(matches) > 1:
        return SpawnDecision.FATAL
    spawn_contract = CONTRACT["spawn"]
    if (
        explicit_capacity_error
        and spawn_contract["retry_only_on_explicit_capacity_error"]
        and attempt <= spawn_contract["max_retries"]
    ):
        if (
            spawn_contract["retry_requires_available_slot"]
            and running_count >= MAX_CONCURRENCY
        ):
            return SpawnDecision.WAIT_FOR_SLOT
        if spawn_contract["require_new_attempt_name"] and (
            proposed_retry_name is None or proposed_retry_name == requested_name
        ):
            return SpawnDecision.FATAL
        return SpawnDecision.RETRY
    return SpawnDecision.FATAL


def cleanup_targets(
    statuses: dict[str, str],
    owned_top_level: set[str],
) -> set[str]:
    targets = set()
    for path, status in statuses.items():
        if status != "running":
            continue
        is_owned_top_level = path in owned_top_level
        is_owned_descendant = any(
            path.startswith(f"{owner}/") for owner in owned_top_level
        )
        cleanup_contract = CONTRACT["cleanup"]
        if (
            is_owned_top_level
            and cleanup_contract["interrupt_running_owned_top_level"]
        ) or (
            is_owned_descendant
            and cleanup_contract["interrupt_running_owned_descendants"]
        ):
            targets.add(path)
    return targets


def cleanup_confirmed(
    statuses: dict[str, str],
    owned_top_level: set[str],
) -> bool:
    return not cleanup_targets(statuses, owned_top_level)


def aggregation_allowed(
    tasks: list[TaskEvidence],
    expected_roles: set[str],
    now_ms: int,
) -> bool:
    aggregation_contract = CONTRACT["aggregation"]
    roles = {task.role for task in tasks}
    canonical_paths = {task.canonical_path for task in tasks}
    if aggregation_contract["require_exact_expected_roles"] and (
        roles != expected_roles or len(roles) != len(tasks)
    ):
        return False
    if (
        aggregation_contract["require_unique_canonical_tasks"]
        and len(canonical_paths) != len(tasks)
    ):
        return False
    return not aggregation_contract["require_all_usable"] or all(
        task.state(now_ms) is TaskState.USABLE for task in tasks
    )


class TaskEvidenceTests(unittest.TestCase):
    canonical = "/root/prr_token_s1_code_reviewer_a1"

    def test_model_constants_match_skill_contract(self) -> None:
        skill = SKILL.read_text(encoding="utf-8")
        self.assertIn("references/v2-runtime-contract.json", skill)
        self.assertIn(CONTRACT["sentinel"], skill)

    def test_completed_first_accepts_final_within_delivery_grace(self) -> None:
        for stage, deadline in STAGE_DEADLINES_MS.items():
            with self.subTest(stage=stage):
                task = TaskEvidence(self.canonical, stage_deadline_ms=deadline)
                task.observe_status("completed", 1_000)
                self.assertIs(task.state(60_999), TaskState.WAITING)
                task.receive_final(self.canonical, "COVERAGE_OK", 60_999)
                self.assertIs(task.state(60_999), TaskState.USABLE)

    def test_completed_first_fails_at_delivery_grace_boundary(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("completed", 1_000)
        self.assertIs(task.state(61_000), TaskState.FATAL)
        self.assertEqual(task.fatal_reason, "final delivery grace expired")

    def test_late_final_cannot_bypass_expired_delivery_grace(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("completed", 1_000)
        task.receive_final(self.canonical, "COVERAGE_OK", 61_000)
        self.assertIs(task.state(61_000), TaskState.FATAL)
        self.assertEqual(task.fatal_reason, "final delivered after grace")

    def test_final_first_qualified_retirement_is_usable(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("running", 500)
        task.receive_final(self.canonical, "COVERAGE_OK", 1_000)
        self.assertIs(task.state(1_000), TaskState.WAITING)
        task.observe_status("", 1_100, present=False, full_snapshot=True)
        self.assertIs(task.state(1_100), TaskState.USABLE)

    def test_retirement_first_accepts_final_within_delivery_grace(self) -> None:
        for stage, deadline in STAGE_DEADLINES_MS.items():
            with self.subTest(stage=stage):
                task = TaskEvidence(self.canonical, stage_deadline_ms=deadline)
                task.observe_status("running", 500)
                task.observe_status("", 1_000, present=False, full_snapshot=True)
                self.assertIs(task.state(60_999), TaskState.WAITING)
                task.receive_final(self.canonical, "COVERAGE_OK", 60_999)
                self.assertIs(task.state(60_999), TaskState.USABLE)

    def test_retirement_without_final_expires_at_delivery_grace(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("running", 500)
        task.observe_status("", 1_000, present=False, full_snapshot=True)
        self.assertIs(task.state(61_000), TaskState.FATAL)
        self.assertEqual(task.fatal_reason, "final delivery grace expired")

    def test_running_and_final_alone_remain_waiting(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("running", 500)
        task.receive_final(self.canonical, "COVERAGE_OK", 1_000)
        self.assertIs(task.state(1_000), TaskState.WAITING)

    def test_unobserved_disappearance_is_fatal(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("", 2_000, present=False, full_snapshot=True)
        self.assertIs(task.state(2_000), TaskState.FATAL)
        self.assertEqual(
            task.fatal_reason,
            "task disappeared before observed running",
        )

    def test_incomplete_snapshot_cannot_prove_retirement(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("running", 1_000)
        task.observe_status("", 2_000, present=False, full_snapshot=False)
        self.assertIs(task.state(2_000), TaskState.FATAL)

    def test_parent_interrupted_task_cannot_retire_successfully(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("running", 1_000)
        task.mark_parent_interrupted()
        task.observe_status("", 2_000, present=False, full_snapshot=True)
        self.assertIs(task.state(2_000), TaskState.FATAL)

    def test_identical_duplicate_final_is_idempotent(self) -> None:
        task = TaskEvidence(self.canonical)
        task.receive_final(self.canonical, "COVERAGE_OK", 1_000)
        task.receive_final(self.canonical, "COVERAGE_OK", 1_500)
        task.observe_status("completed", 2_000)
        self.assertIs(task.state(2_000), TaskState.USABLE)

    def test_conflicting_duplicate_final_is_fatal(self) -> None:
        task = TaskEvidence(self.canonical)
        task.receive_final(self.canonical, "COVERAGE_OK", 1_000)
        task.observe_status("completed", 1_100)
        self.assertIs(task.state(1_100), TaskState.USABLE)
        task.receive_final(self.canonical, "different result", 1_500)
        self.assertIs(task.state(2_000), TaskState.FATAL)

    def test_later_error_overrides_usable_evidence(self) -> None:
        task = TaskEvidence(self.canonical)
        task.receive_final(self.canonical, "COVERAGE_OK", 1_000)
        task.observe_status("completed", 1_100)
        self.assertIs(task.state(1_100), TaskState.USABLE)
        task.observe_status("error", 1_200)
        self.assertIs(task.state(1_200), TaskState.FATAL)

    def test_cleanup_start_is_monotonic_fatal(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status("completed", 1_000)
        task.receive_final(
            self.canonical,
            "COVERAGE_OK",
            1_100,
            cleanup_started=True,
        )
        self.assertIs(task.state(1_100), TaskState.FATAL)

    def test_unknown_sender_cannot_make_task_usable(self) -> None:
        task = TaskEvidence(self.canonical)
        task.receive_final("/root/unrelated", "COVERAGE_OK", 1_000)
        task.observe_status("completed", 2_000)
        self.assertIs(task.state(2_000), TaskState.WAITING)

    def test_evidence_completed_at_stage_deadline_is_fatal(self) -> None:
        for stage, deadline in STAGE_DEADLINES_MS.items():
            with self.subTest(stage=stage):
                task = TaskEvidence(self.canonical, stage_deadline_ms=deadline)
                task.receive_final(self.canonical, "COVERAGE_OK", deadline - 1)
                task.observe_status("completed", deadline)
                self.assertIs(task.state(deadline), TaskState.FATAL)

    def test_unexpected_descendant_is_fatal(self) -> None:
        task = TaskEvidence(self.canonical)
        task.observe_status(
            "running",
            2_000,
            unexpected_descendant=True,
        )
        self.assertIs(task.state(2_000), TaskState.FATAL)


class RetentionReplay:
    def __init__(self, stage: str) -> None:
        deadline = STAGE_DEADLINES_MS[stage]
        self.tasks = {
            "/root/prr_token_s1_code_reviewer_a1": TaskEvidence(
                "/root/prr_token_s1_code_reviewer_a1",
                role="code-reviewer",
                stage_deadline_ms=deadline,
            ),
            "/root/prr_token_s1_security_reviewer_a1": TaskEvidence(
                "/root/prr_token_s1_security_reviewer_a1",
                role="security-reviewer",
                stage_deadline_ms=deadline,
            ),
            "/root/prr_token_s1_adversarial_reviewer_a1": TaskEvidence(
                "/root/prr_token_s1_adversarial_reviewer_a1",
                role="adversarial-reviewer",
                stage_deadline_ms=deadline,
            ),
        }
        self.deadline = deadline
        self.actions: list[str] = []
        self.usable_roles: set[str] = set()
        self.fatal_reason: str | None = None

    def record_new_usable(self, now_ms: int) -> None:
        for task in self.tasks.values():
            state = task.state(now_ms)
            if state is TaskState.FATAL and self.fatal_reason is None:
                self.fatal_reason = task.fatal_reason
            elif state is TaskState.USABLE and task.role not in self.usable_roles:
                self.usable_roles.add(task.role)
                self.actions.append(f"usable:{task.role}")

    def process(self, event: dict) -> None:
        if self.fatal_reason is not None:
            return
        now_ms = event["now_ms"]
        if event["type"] == "final":
            task = self.tasks.get(event["sender"])
            if task is None:
                self.fatal_reason = "unknown final sender"
                return
            task.receive_final(
                event["sender"],
                event["payload"],
                now_ms,
                valid=event["valid"],
            )
            self.actions.append(f"record-final:{task.role}")
            self.record_new_usable(now_ms)
            return

        if event["type"] == "refill":
            if not self.usable_roles:
                self.fatal_reason = "refill before usable task"
                return
            path = event["canonical_path"]
            if path in self.tasks:
                self.fatal_reason = "duplicate refill identity"
                return
            self.tasks[path] = TaskEvidence(
                path,
                role=event["role"],
                stage_deadline_ms=self.deadline,
            )
            self.actions.append(f"refill:{event['role']}")
            return

        if event["type"] != "snapshot" or not event["full_tree"]:
            self.fatal_reason = "missing successful full-tree snapshot"
            return

        statuses = event["statuses"]
        for path, task in self.tasks.items():
            was_running = task.seen_running
            was_completed = task.completed_at_ms is not None
            was_retired = task.retired_at_ms is not None
            if path in statuses:
                task.observe_status(statuses[path], now_ms, full_snapshot=True)
            else:
                task.observe_status("", now_ms, present=False, full_snapshot=True)
            if task.seen_running and not was_running:
                self.actions.append(f"observed-running:{task.role}")
            if task.completed_at_ms is not None and not was_completed:
                self.actions.append(f"observed-completed:{task.role}")
            if task.retired_at_ms is not None and not was_retired:
                self.actions.append(f"retired:{task.role}")
        self.record_new_usable(now_ms)

    def finish(self) -> None:
        if self.fatal_reason is None:
            self.actions.append("continue-dispatch")


class RunLevelRetentionReplayTests(unittest.TestCase):
    def test_sanitized_refill_retention_trace_continues_dispatch(self) -> None:
        fixture = json.loads(RETENTION_FIXTURE_PATH.read_text(encoding="utf-8"))
        replay = RetentionReplay(fixture["stage"])
        for event in fixture["events"]:
            replay.process(event)
        replay.finish()
        self.assertIsNone(replay.fatal_reason)
        self.assertEqual(replay.actions, fixture["expected_actions"])
        self.assertIn("code-reviewer", replay.usable_roles)
        self.assertIn("security-reviewer", replay.usable_roles)

    def test_incomplete_snapshot_trace_fails_closed(self) -> None:
        fixture = json.loads(RETENTION_FIXTURE_PATH.read_text(encoding="utf-8"))
        fixture["events"][-1]["full_tree"] = False
        replay = RetentionReplay(fixture["stage"])
        for event in fixture["events"]:
            replay.process(event)
        replay.finish()
        self.assertEqual(
            replay.fatal_reason,
            "missing successful full-tree snapshot",
        )
        self.assertNotIn("continue-dispatch", replay.actions)


class SpawnReconciliationTests(unittest.TestCase):
    requested = "prr_token_s1_code_reviewer_a1"

    def test_partial_success_is_adopted_by_exact_name(self) -> None:
        decision = reconcile_spawn_error(
            self.requested,
            [],
            [self.requested],
            explicit_capacity_error=False,
            attempt=1,
            running_count=0,
        )
        self.assertIs(decision, SpawnDecision.ADOPT)

    def test_explicit_capacity_error_waits_for_slot_then_retries_once(self) -> None:
        full = reconcile_spawn_error(
            self.requested,
            [],
            [],
            explicit_capacity_error=True,
            attempt=1,
            running_count=MAX_CONCURRENCY,
            proposed_retry_name="prr_token_s1_code_reviewer_a2",
        )
        after_slot_frees = reconcile_spawn_error(
            self.requested,
            [],
            [],
            explicit_capacity_error=True,
            attempt=1,
            running_count=MAX_CONCURRENCY - 1,
            proposed_retry_name="prr_token_s1_code_reviewer_a2",
        )
        second = reconcile_spawn_error(
            "prr_token_s1_code_reviewer_a2",
            [],
            [],
            explicit_capacity_error=True,
            attempt=2,
            running_count=MAX_CONCURRENCY - 1,
        )
        self.assertIs(full, SpawnDecision.WAIT_FOR_SLOT)
        self.assertIs(after_slot_frees, SpawnDecision.RETRY)
        self.assertIs(second, SpawnDecision.FATAL)

    def test_capacity_retry_rejects_same_attempt_name(self) -> None:
        decision = reconcile_spawn_error(
            self.requested,
            [],
            [],
            explicit_capacity_error=True,
            attempt=1,
            running_count=MAX_CONCURRENCY - 1,
            proposed_retry_name=self.requested,
        )
        self.assertIs(decision, SpawnDecision.FATAL)

    def test_absent_ambiguous_error_is_fatal(self) -> None:
        decision = reconcile_spawn_error(
            self.requested,
            [],
            [],
            explicit_capacity_error=False,
            attempt=1,
            running_count=0,
        )
        self.assertIs(decision, SpawnDecision.FATAL)

    def test_preexisting_requested_name_is_fatal(self) -> None:
        decision = reconcile_spawn_error(
            self.requested,
            [self.requested],
            [self.requested],
            explicit_capacity_error=False,
            attempt=1,
            running_count=0,
        )
        self.assertIs(decision, SpawnDecision.FATAL)


class CleanupAndAggregationTests(unittest.TestCase):
    owned = {"/root/prr_token_s1_code_reviewer_a1"}

    def test_cleanup_targets_only_running_owned_tree(self) -> None:
        statuses = {
            "/root": "running",
            "/root/prr_token_s1_code_reviewer_a1": "running",
            "/root/prr_token_s1_code_reviewer_a1/nested": "running",
            "/root/unrelated": "running",
            "/root/prr_token_s1_old_completed": "completed",
        }
        self.assertEqual(
            cleanup_targets(statuses, self.owned),
            {
                "/root/prr_token_s1_code_reviewer_a1",
                "/root/prr_token_s1_code_reviewer_a1/nested",
            },
        )

    def test_cleanup_confirmation_fails_if_owned_task_remains_running(self) -> None:
        self.assertFalse(
            cleanup_confirmed(
                {"/root/prr_token_s1_code_reviewer_a1": "running"},
                self.owned,
            )
        )
        self.assertTrue(
            cleanup_confirmed(
                {
                    "/root/prr_token_s1_code_reviewer_a1": "interrupted",
                    "/root/unrelated": "running",
                },
                self.owned,
            )
        )

    def test_partial_aggregation_is_forbidden(self) -> None:
        expected_roles = {"code-reviewer", "security-reviewer"}
        usable = TaskEvidence(
            "/root/prr_token_s1_code_reviewer_a1",
            role="code-reviewer",
        )
        usable.receive_final(usable.canonical_path, "COVERAGE_OK", 500)
        usable.observe_status("completed", 1_000)
        waiting = TaskEvidence(
            "/root/prr_token_s1_security_reviewer_a1",
            role="security-reviewer",
        )
        self.assertFalse(
            aggregation_allowed([usable, waiting], expected_roles, 1_000)
        )
        waiting.receive_final(waiting.canonical_path, "COVERAGE_OK", 500)
        waiting.observe_status("completed", 1_000)
        self.assertTrue(
            aggregation_allowed([usable, waiting], expected_roles, 1_000)
        )

    def test_aggregation_rejects_duplicate_or_missing_role(self) -> None:
        expected_roles = {"code-reviewer", "security-reviewer"}
        task = TaskEvidence(
            "/root/prr_token_s1_code_reviewer_a1",
            role="code-reviewer",
        )
        task.receive_final(task.canonical_path, "COVERAGE_OK", 500)
        task.observe_status("completed", 1_000)
        duplicate = dataclasses.replace(task)
        self.assertFalse(
            aggregation_allowed([task, duplicate], expected_roles, 1_000)
        )


def main() -> None:
    suite = unittest.TestSuite(
        unittest.defaultTestLoader.loadTestsFromTestCase(test_case)
        for test_case in (
            TaskEvidenceTests,
            RunLevelRetentionReplayTests,
            SpawnReconciliationTests,
            CleanupAndAggregationTests,
        )
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    print("OK: pr-review V2 scheduler abnormal-path tests passed")


if __name__ == "__main__":
    main()
