from __future__ import annotations

import sys
import unittest
from pathlib import Path


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.model import (  # noqa: E402
    ContractError,
    ControlKey,
    ControlRecord,
    ControlResult,
    ObservationClass,
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


if __name__ == "__main__":
    unittest.main()
