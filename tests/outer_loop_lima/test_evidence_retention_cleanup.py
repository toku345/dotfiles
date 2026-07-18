from __future__ import annotations

import hashlib
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.cleanup import REQUIRED_ABSENCE, attempt_logout_once, collect_absence, verify_cleanup  # noqa: E402
from lib.evidence import (  # noqa: E402
    append_jsonl,
    record_control,
    record_decision,
    seal,
    seal_input_digest,
    write_once,
)
from lib.model import (  # noqa: E402
    ApprovalRecord,
    CleanupDisposition,
    ContractError,
    ControlKey,
    ControlRecord,
    ControlResult,
    TerminalState,
)
from lib.paths import RunPaths  # noqa: E402
from lib.retention import cleanup_due, launch_agent_payload, render_deadline_wrapper  # noqa: E402


def record(control_id: str) -> ControlRecord:
    return ControlRecord(
        ControlKey("run-0001", control_id, "initial" if control_id != "C08" else "seal", "target"),
        "expected",
        "observed",
        "a" * 64,
        ControlResult.PASS,
        "test",
    )


class EvidenceTests(unittest.TestCase):
    def test_forbidden_raw_fields_are_rejected_recursively(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ContractError, "forbidden evidence"):
                append_jsonl(
                    Path(temporary) / "evidence.jsonl",
                    {"nested": [{"raw_jsonl": "must-not-land"}]},
                )

    def test_final_approval_and_c08_do_not_change_approved_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = RunPaths.for_run("run-0001", Path(temporary))
            paths.create()
            write_once(paths.evidence / "identity.json", {"schema_version": 1, "run_id": "run-0001"})
            c00 = record("C00")
            record_control(paths, c00)
            prepared = seal_input_digest(paths)
            record_decision(
                paths,
                ApprovalRecord("run-0001", "final-seal", prepared, "2030-01-01T00:00:00Z", "b" * 64),
            )
            c08 = record("C08")
            record_control(paths, c08)
            self.assertEqual(seal_input_digest(paths), prepared)
            with patch("lib.evidence.sys.platform", "linux"):
                digest = seal(
                    paths,
                    terminal=TerminalState.READY,
                    approved_digest=prepared,
                    retention_deadline="2030-01-02T00:00:00Z",
                    control_records=(c00, c08),
                )
            self.assertEqual(len(digest), 64)
            summary = (paths.evidence / "summary.md").read_text()
            self.assertIn("LIMA_CALIBRATION_READY_FOR_V3_DESIGN", summary)
            self.assertIn("real_task_allowed: no", summary)

    def test_seal_rejects_digest_mismatch_and_nonpassing_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = RunPaths.for_run("run-0001", Path(temporary))
            paths.create()
            write_once(paths.evidence / "identity.json", {"run_id": "run-0001"})
            with self.assertRaisesRegex(ContractError, "does not match"):
                seal(
                    paths,
                    terminal=TerminalState.READY,
                    approved_digest="0" * 64,
                    retention_deadline="2030-01-02T00:00:00Z",
                    control_records=(record("C00"),),
                )

    def test_ready_summary_is_removed_when_final_immutability_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = RunPaths.for_run("run-0001", Path(temporary))
            paths.create()
            write_once(paths.evidence / "identity.json", {"run_id": "run-0001"})
            c00 = record("C00")
            record_control(paths, c00)
            prepared = seal_input_digest(paths)
            record_decision(
                paths,
                ApprovalRecord("run-0001", "final-seal", prepared, "2030-01-01T00:00:00Z", "b" * 64),
            )
            c08 = record("C08")
            record_control(paths, c08)

            def chflags(argv, **_kwargs):
                if argv[1] == "uchg" and argv[-1].endswith("summary.md"):
                    raise subprocess.CalledProcessError(1, argv)
                return subprocess.CompletedProcess(argv, 0)

            with (
                patch("lib.evidence.sys.platform", "darwin"),
                patch("lib.evidence.subprocess.run", side_effect=chflags),
                self.assertRaises(subprocess.CalledProcessError),
            ):
                seal(
                    paths,
                    terminal=TerminalState.READY,
                    approved_digest=prepared,
                    retention_deadline="2030-01-02T00:00:00Z",
                    control_records=(c00, c08),
                )
            self.assertFalse((paths.evidence / "summary.md").exists())
            self.assertFalse((paths.work / ".summary.pending").exists())
            self.assertEqual(
                stat.S_IMODE((paths.evidence / "controls.jsonl").stat().st_mode),
                0o600,
            )


class RetentionCleanupTests(unittest.TestCase):
    def test_deadline_wrapper_has_fixed_public_cleanup_route_and_not_due_check(self) -> None:
        wrapper = render_deadline_wrapper(
            Path("/usr/bin/python3"),
            Path("/private/run/frozen/calibrate.py"),
            Path("/private/run/state"),
            "run-0001",
            "2030-01-02T03:04:05Z",
        )
        self.assertIn("now_epoch", wrapper)
        self.assertIn("cleanup run-0001 --cause deadline", wrapper)
        self.assertNotIn("retention-check", wrapper)

    def test_launch_agent_has_run_at_load_calendar_and_hourly_catchup(self) -> None:
        payload = launch_agent_payload(
            "run-0001",
            "2030-01-02T03:04:05Z",
            Path("/private/run/deadline-cleanup.sh"),
        )
        self.assertIs(payload["RunAtLoad"], True)
        self.assertEqual(payload["StartInterval"], 3600)
        self.assertIn("StartCalendarInterval", payload)
        self.assertEqual(payload["ProgramArguments"], ["/private/run/deadline-cleanup.sh"])
        self.assertFalse(
            cleanup_due("2030-01-02T03:04:05Z", datetime(2030, 1, 2, 3, 4, 4, tzinfo=UTC))
        )
        self.assertTrue(
            cleanup_due("2030-01-02T03:04:05Z", datetime(2030, 1, 2, 3, 4, 5, tzinfo=UTC))
        )

    def test_logout_timeout_is_classified(self) -> None:
        from subprocess import TimeoutExpired

        with patch("lib.cleanup.subprocess.run", side_effect=TimeoutExpired(["logout"], 60)):
            result = attempt_logout_once("codex", ["logout"])
        self.assertEqual(result.classification, "TIMEOUT")

    def test_cleanup_unknown_or_unconfirmed_revoke_remains_pending(self) -> None:
        absent = {name: "ABSENT" for name in REQUIRED_ABSENCE}
        verified = verify_cleanup(
            "run-0001",
            "a" * 64,
            absent,
            account_revoke_required=False,
            revoke_human_confirmed=False,
        )
        self.assertEqual(verified.disposition, CleanupDisposition.CLEANUP_VERIFIED)
        absent["listener"] = "UNKNOWN"
        pending = verify_cleanup(
            "run-0001",
            "a" * 64,
            absent,
            account_revoke_required=False,
            revoke_human_confirmed=False,
        )
        self.assertFalse(pending.cleanup_verified)
        absent["listener"] = "ABSENT"
        revoke = verify_cleanup(
            "run-0001",
            "a" * 64,
            absent,
            account_revoke_required=True,
            revoke_human_confirmed=False,
        )
        self.assertFalse(revoke.cleanup_verified)

    def test_cleanup_readback_exception_becomes_unknown(self) -> None:
        diagnostics: dict[str, str] = {}
        observations = collect_absence(
            (("listener", lambda: (_ for _ in ()).throw(OSError())),),
            diagnostics=diagnostics,
        )
        self.assertEqual(observations["listener"], "UNKNOWN")
        self.assertEqual(diagnostics, {"listener": "OSError"})

    def test_cleanup_attestation_preserves_sanitized_diagnostics(self) -> None:
        absent = {name: "ABSENT" for name in REQUIRED_ABSENCE}
        absent["listener"] = "UNKNOWN"
        record = verify_cleanup(
            "run-0001",
            "a" * 64,
            absent,
            account_revoke_required=False,
            revoke_human_confirmed=False,
            diagnostics={"listener": "OSError"},
        )
        self.assertEqual(record.diagnostics, {"listener": "OSError"})
        self.assertEqual(record.to_dict()["diagnostics"], {"listener": "OSError"})


if __name__ == "__main__":
    unittest.main()
