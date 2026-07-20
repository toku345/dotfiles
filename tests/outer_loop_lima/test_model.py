from __future__ import annotations

import sys
import unittest
from pathlib import Path


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.model import (  # noqa: E402
    CleanupDisposition,
    ContractError,
    ControlKey,
    ControlRecord,
    ControlResult,
    ObservationClass,
    LimaHomeBindingRecord,
    LimaIdentity,
    ProvisionAttemptEvent,
    ProvisionAttemptOutcome,
    ProvisionAttemptRecord,
    RiskAcceptanceRecord,
    RiskDisposition,
    TerminalState,
    aggregate_controls,
)


def passing(key: ControlKey) -> ControlRecord:
    return ControlRecord(key, "expected", "observed", "a" * 64, ControlResult.PASS, "test")


class ModelTests(unittest.TestCase):
    def test_risk_cannot_enter_control_aggregator(self) -> None:
        risk = RiskAcceptanceRecord(
            "run-0001",
            "AR-02",
            "runtime-main-process-egress-not-enforced",
            "a" * 64,
            RiskDisposition.NOT_PROVIDED_ACCEPTED_RISK,
        )
        with self.assertRaisesRegex(ContractError, "only ControlRecord"):
            aggregate_controls([risk], [])  # type: ignore[list-item]

    def test_unavailable_baseline_cannot_be_pass(self) -> None:
        with self.assertRaisesRegex(ContractError, "unavailable baseline"):
            ControlRecord(
                ControlKey("run-0001", "C03", "initial", "host"),
                "denied",
                ObservationClass.UNAVAILABLE_BASELINE,
                "a" * 64,
                ControlResult.PASS,
                "test",
            )

    def test_aggregate_requires_exact_keys_and_all_pass(self) -> None:
        key = ControlKey("run-0001", "C00", "host", "expected")
        result = aggregate_controls([passing(key)], [key])
        self.assertEqual(result.terminal, TerminalState.READY)
        self.assertFalse(result.real_task_allowed)
        missing = aggregate_controls([], [key])
        self.assertEqual(missing.terminal, TerminalState.BLOCKED)

    def test_duplicate_control_is_rejected(self) -> None:
        key = ControlKey("run-0001", "C01", "initial", "codex")
        with self.assertRaisesRegex(ContractError, "duplicate"):
            aggregate_controls([passing(key), passing(key)], [key])

    def test_lima_identity_rejects_bool_resource_and_unknown_status(self) -> None:
        with self.assertRaisesRegex(ContractError, "exact integers"):
            LimaIdentity("name", "Stopped", "/dir", "vz", "aarch64", True, 8, 40)
        with self.assertRaisesRegex(ContractError, "Stopped or Running"):
            LimaIdentity("name", "Broken", "/dir", "vz", "aarch64", 4, 8, 40)

    def test_lima_home_binding_rejects_coerced_identity_fields(self) -> None:
        with self.assertRaisesRegex(ContractError, "exact integers"):
            LimaHomeBindingRecord(
                "run-0001",
                "/state",
                "/state/runs/run-0001",
                "/pool",
                "abcdefghij",
                "/pool/abcdefghij",
                True,
                2,
                3,
                4,
                501,
                0o700,
                "a" * 64,
            )

    def test_provision_attempt_event_and_outcome_are_consistent(self) -> None:
        started = ProvisionAttemptRecord(
            "run-0001",
            "codex",
            "create",
            ProvisionAttemptEvent.STARTED,
            "a" * 64,
            "2030-01-01T00:00:00Z",
        )
        self.assertEqual(started.to_dict()["schema_version"], 2)
        with self.assertRaisesRegex(ContractError, "cannot have an outcome"):
            ProvisionAttemptRecord(
                "run-0001",
                "codex",
                "create",
                ProvisionAttemptEvent.STARTED,
                "a" * 64,
                "2030-01-01T00:00:00Z",
                ProvisionAttemptOutcome.SUCCESS,
            )
        with self.assertRaisesRegex(ContractError, "requires an outcome"):
            ProvisionAttemptRecord(
                "run-0001",
                "codex",
                "start",
                ProvisionAttemptEvent.COMPLETED,
                "a" * 64,
                "2030-01-01T00:00:01Z",
            )

    def test_manual_cleanup_is_distinct_from_verified(self) -> None:
        self.assertNotEqual(
            CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
            CleanupDisposition.CLEANUP_VERIFIED,
        )


if __name__ == "__main__":
    unittest.main()
