from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.model import ContractError, ControlResult, ObservationClass  # noqa: E402
from lib.probes import (  # noqa: E402
    CanaryResult,
    ExecutionReceipt,
    OneShotCanary,
    ProbeEvidence,
    ProbeTarget,
    argv_digest,
    classify_claude_two_stage,
    classify_paired_probe,
    required_probe_matrix,
    send_canary,
)


class ProbeTests(unittest.TestCase):
    def evidence(self, **overrides) -> ProbeEvidence:
        target = ProbeTarget("codex", "initial", "ipv4", "tcp", "host")
        argv = ("probe", "host", "443")
        values = {
            "target": target,
            "nonce": "a" * 32,
            "intended_argv": argv,
            "runtime_observed_argv": argv,
            "outside_path_available": True,
            "outside_ingress_nonce": "a" * 32,
            "receipt": ExecutionReceipt(
                "a" * 32,
                "host",
                argv_digest(argv),
                ObservationClass.DENIED_BY_SANDBOX,
            ),
            "inside_ingress_nonce": None,
        }
        values.update(overrides)
        return ProbeEvidence(**values)

    def test_protocol_matrix_is_complete(self) -> None:
        matrix = required_probe_matrix()
        self.assertEqual(len(matrix), 100)
        self.assertEqual(len({target.target_id for target in matrix}), 100)

    def test_complete_paired_evidence_passes(self) -> None:
        outcome = classify_paired_probe(self.evidence())
        self.assertEqual(outcome.result, ControlResult.PASS)

    def test_inside_listener_error_is_unverified(self) -> None:
        outcome = classify_paired_probe(self.evidence(inside_canary_error="OSError"))
        self.assertEqual(outcome.result, ControlResult.UNVERIFIED)
        self.assertEqual(outcome.observation, "INSIDE_CANARY_ERROR")

    def test_unreachable_outside_is_not_a_passing_denial(self) -> None:
        outcome = classify_paired_probe(self.evidence(outside_path_available=False))
        self.assertFalse(outcome.applicable)
        self.assertIsNone(outcome.result)
        self.assertEqual(outcome.observation, ObservationClass.UNAVAILABLE_BASELINE)

    def test_missing_receipt_mutated_argv_and_false_ingress_fail_closed(self) -> None:
        self.assertEqual(
            classify_paired_probe(self.evidence(receipt=None)).result,
            ControlResult.UNVERIFIED,
        )
        self.assertEqual(
            classify_paired_probe(self.evidence(runtime_observed_argv=("changed",))).result,
            ControlResult.UNVERIFIED,
        )
        self.assertEqual(
            classify_paired_probe(self.evidence(inside_ingress_nonce="a" * 32)).result,
            ControlResult.FAIL,
        )

    def test_claude_stage_two_is_load_bearing(self) -> None:
        passed = classify_paired_probe(self.evidence())
        unverified = classify_paired_probe(self.evidence(runtime_observed_argv=None))
        self.assertEqual(classify_claude_two_stage(passed, passed), ControlResult.PASS)
        self.assertEqual(
            classify_claude_two_stage(passed, unverified),
            ControlResult.UNVERIFIED,
        )
        with self.assertRaises(ContractError):
            unavailable = classify_paired_probe(self.evidence(outside_path_available=False))
            classify_claude_two_stage(passed, unavailable)

    def test_one_shot_tcp_and_udp_canaries_record_nonce(self) -> None:
        for protocol in ("tcp", "udp"):
            try:
                listener = OneShotCanary(protocol, timeout=1)
            except PermissionError:
                self.skipTest("local socket creation is denied by the test sandbox")
            send_canary("127.0.0.1", listener.port, protocol, "b" * 32)
            self.assertEqual(listener.wait(2), CanaryResult("b" * 32, None))


if __name__ == "__main__":
    unittest.main()
