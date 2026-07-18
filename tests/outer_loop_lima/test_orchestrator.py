from __future__ import annotations

import json
import io
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from contextlib import redirect_stderr
from unittest.mock import patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from calibrate import build_parser  # noqa: E402
from lib.model import (  # noqa: E402
    ContractError,
    ControlKey,
    ControlRecord,
    ControlResult,
    TerminalState,
)
from lib.orchestrator import Orchestrator, Phase, PhaseResult  # noqa: E402


def passed(run_id: str, control_id: str, occurrence: str, target: str) -> ControlRecord:
    return ControlRecord(
        ControlKey(run_id, control_id, occurrence, target),
        "VERIFIED",
        "VERIFIED",
        "a" * 64,
        ControlResult.PASS,
        "fake-driver",
        "ZERO",
    )


class FakeDriver:
    def provision(self, run_id: str, frozen_harness: Path) -> PhaseResult:
        del frozen_harness
        return PhaseResult(
            tuple(
                passed(run_id, control_id, occurrence, runtime)
                for runtime in ("codex", "claude")
                for control_id, occurrence in (("C00", "guest"), ("C01", "initial"))
            )
        )

    def authenticate(self, run_id: str, runtime: str, occurrence: str) -> PhaseResult:
        return PhaseResult((passed(run_id, "C02", occurrence, runtime),))

    def isolation(self, run_id: str, occurrence: str) -> PhaseResult:
        return PhaseResult((passed(run_id, "C03", occurrence, "host:tcp"),))

    def sync_export(self, run_id: str) -> PhaseResult:
        return PhaseResult(
            tuple(
                passed(run_id, control_id, "initial", target)
                for control_id, target in (
                    ("C04", "sync-guard"),
                    ("C05", "sync-semantics"),
                    ("C06", "export-quarantine"),
                )
            )
        )

    def handoff(self, run_id: str, direction: str) -> PhaseResult:
        return PhaseResult((passed(run_id, "C07", direction, direction),))

    def restart(self, run_id: str) -> PhaseResult:
        return PhaseResult(
            (
                passed(run_id, "C02", "post_restart", "codex"),
                passed(run_id, "C02", "post_restart", "claude"),
                passed(run_id, "C03", "post_restart", "host:tcp"),
            )
        )

    def stop_for_seal(self, run_id: str) -> dict[str, object]:
        return {"run_id": run_id, "codex": "Stopped", "claude": "Stopped"}


class OrchestratorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.harness = self.root / "harness"
        self.harness.mkdir()
        (self.harness / "versions.lock.json").write_text("{}")
        (self.harness / "manifest.json").write_text("{}")
        self.state_root = self.root / "state"

        def exact_input(prompt: str) -> str:
            return prompt.rsplit("(", 1)[1].split(")", 1)[0]

        self.orchestrator = Orchestrator(
            harness_root=self.harness,
            state_root=self.state_root,
            driver_factory=lambda _paths: FakeDriver(),
            stdin_isatty=lambda: True,
            stdout_isatty=lambda: True,
            input_fn=exact_input,
            now=lambda: datetime(2029, 1, 1, tzinfo=UTC),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_full_fixed_fsm_reaches_design_only_terminal(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        lock = {
            "artifacts": {
                name: {"source": f"/{name}", "sha256": "a" * 64, "version": "1"}
                for name in ("host_python", "host_limactl", "host_rsync")
            }
        }
        with (
            patch("lib.orchestrator.validate_versions_lock", return_value=lock),
            patch("lib.orchestrator.validate_manifest", return_value={}),
            patch("lib.orchestrator.verify_binary_identity", return_value={"verified": "yes"}),
            patch("lib.orchestrator.platform.system", return_value="Darwin"),
            patch("lib.orchestrator.platform.machine", return_value="arm64"),
            patch.object(self.orchestrator, "_freeze_harness"),
        ):
            self.orchestrator.preflight(run_id)
        self.orchestrator.approve_pre_vm(run_id)
        with patch.object(self.orchestrator, "_register_retention"):
            self.orchestrator.provision(run_id)
        self.orchestrator.approve_pre_auth(run_id, code_paste_feasible=True)
        self.orchestrator.authenticate(run_id, "codex")
        self.orchestrator.authenticate(run_id, "claude")
        self.orchestrator.isolation(run_id)
        self.orchestrator.sync_export(run_id)
        self.orchestrator.approve_pre_handoff(run_id, "forward")
        self.orchestrator.handoff(run_id, "forward")
        self.orchestrator.approve_pre_handoff(run_id, "reverse")
        self.orchestrator.handoff(run_id, "reverse")
        self.orchestrator.restart(run_id)
        self.orchestrator.prepare_seal(run_id)
        self.orchestrator.approve_final_seal(run_id)
        with patch("lib.evidence.sys.platform", "linux"):
            state = self.orchestrator.seal(run_id)
        self.assertEqual(state["terminal_state"], TerminalState.READY)
        self.assertFalse(state["real_task_allowed"])
        status = self.orchestrator.status(run_id)
        self.assertEqual(status["terminal_state"], TerminalState.READY)

    def test_phase_skip_and_same_run_retry_are_rejected(self) -> None:
        self.orchestrator.init("run-0001", "2030-01-02T00:00:00Z")
        with self.assertRaisesRegex(ContractError, "phase skip"):
            self.orchestrator.provision("run-0001")
        with self.assertRaisesRegex(ContractError, "already exists"):
            self.orchestrator.init("run-0001", "2030-01-02T00:00:00Z")

    def test_status_converts_orphaned_started_control_to_unverified_blocked(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["phase"] = Phase.AUTHENTICATED
        self.orchestrator._save(paths, state)
        self.orchestrator._begin(
            paths,
            state,
            "run isolation",
            Phase.AUTHENTICATED,
            control_id="C03",
            occurrence="initial",
            target="matrix",
        )
        status = self.orchestrator.status(run_id)
        self.assertEqual(status["terminal_state"], TerminalState.BLOCKED)
        control = json.loads((paths.evidence / "controls.jsonl").read_text().splitlines()[-1])
        self.assertEqual(control["result"], "UNVERIFIED")

    def test_cli_has_no_yes_skip_or_arbitrary_control_route(self) -> None:
        parser = build_parser()
        for argv in (
            ["--yes", "status", "run-0001"],
            ["run", "C03", "run-0001"],
            ["preflight", "run-0001", "--skip"],
        ):
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                parser.parse_args(argv)


if __name__ == "__main__":
    unittest.main()
