from __future__ import annotations

import json
import io
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from contextlib import redirect_stderr
from unittest.mock import Mock, patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from calibrate import build_parser, dispatch, main as calibrate_main  # noqa: E402
from lib.model import (  # noqa: E402
    ContractError,
    ControlKey,
    ControlRecord,
    ControlResult,
    ObservationClass,
    TerminalState,
)
from lib.orchestrator import LimaDriver, Orchestrator, Phase, PhaseResult  # noqa: E402
from lib.probes import ProbeOutcome, ProbeTarget, required_probe_matrix  # noqa: E402


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


def complete_c03(run_id: str, occurrence: str) -> PhaseResult:
    controls: list[ControlRecord] = []
    observations: list[dict[str, object]] = []
    for target in required_probe_matrix():
        if target.occurrence != occurrence:
            continue
        if (
            target.destination_class == "host"
            and target.address_family in {"dns", "ipv4"}
            and target.protocol in {"tcp", "udp"}
        ):
            controls.append(passed(run_id, "C03", occurrence, target.target_id))
        else:
            observations.append(
                {
                    "control_id": "C03",
                    "target": target.target_id,
                    "observed_classification": ObservationClass.UNAVAILABLE_BASELINE,
                    "result": None,
                    "reason": "no operator-authority path in test fixture",
                }
            )
    return PhaseResult(tuple(controls), tuple(observations))


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
        return complete_c03(run_id, occurrence)

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
        c03 = complete_c03(run_id, "post_restart")
        return PhaseResult(
            (
                passed(run_id, "C02", "post_restart", "codex"),
                passed(run_id, "C02", "post_restart", "claude"),
                *c03.controls,
            ),
            c03.observations,
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

    def test_deadline_blocks_mutating_operation_without_launchagent(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        self.orchestrator._now = lambda: datetime(2030, 1, 2, tzinfo=UTC)
        with self.assertRaisesRegex(ContractError, "retention deadline reached"):
            self.orchestrator.preflight(run_id)
        state = self.orchestrator._load(self.orchestrator._paths(run_id))
        self.assertEqual(state["terminal_state"], TerminalState.BLOCKED)

    def test_retention_registration_writes_and_reads_back_launchagent(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T03:04:05Z")
        paths = self.orchestrator._paths(run_id)
        (paths.frozen_harness / "versions.lock.json").write_text(
            json.dumps({"artifacts": {"host_python": {"source": "/usr/bin/python3"}}})
        )

        def success(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=success) as runner:
            self.orchestrator._register_retention(paths)
        self.assertEqual(runner.call_count, 3)
        wrapper = (paths.cleanup / "deadline-cleanup.sh").read_text()
        self.assertIn("2030-01-02T03:04:05Z", wrapper)
        self.assertIn("cleanup run-0001 --cause deadline", wrapper)
        plist = paths.cleanup / "com.toku345.outer-loop-lima-cleanup.run-0001.plist"
        self.assertTrue(plist.is_file())

    def test_incomplete_c03_matrix_blocks_ready_path(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["phase"] = Phase.AUTHENTICATED
        self.orchestrator._save(paths, state)

        class IncompleteDriver(FakeDriver):
            def isolation(self, run_id: str, occurrence: str) -> PhaseResult:
                return PhaseResult((passed(run_id, "C03", occurrence, "host:tcp"),))

        self.orchestrator._driver_factory = lambda _paths: IncompleteDriver()
        with self.assertRaisesRegex(ContractError, "C03 matrix coverage mismatch"):
            self.orchestrator.isolation(run_id)
        self.assertEqual(self.orchestrator.status(run_id)["terminal_state"], TerminalState.BLOCKED)

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

    def test_cli_dispatches_fixed_state_changing_routes(self) -> None:
        parser = build_parser()
        cases = (
            (["init", "run-0001", "--retention-deadline", "2030-01-02T00:00:00Z"], "init", ("run-0001", "2030-01-02T00:00:00Z"), {}),
            (["preflight", "run-0001"], "preflight", ("run-0001",), {}),
            (["approve", "pre-vm", "run-0001"], "approve_pre_vm", ("run-0001",), {}),
            (["approve", "pre-auth", "run-0001", "--code-paste-feasibility", "confirmed"], "approve_pre_auth", ("run-0001",), {"code_paste_feasible": True}),
            (["approve", "pre-handoff", "run-0001", "forward"], "approve_pre_handoff", ("run-0001", "forward"), {}),
            (["approve", "final-seal", "run-0001"], "approve_final_seal", ("run-0001",), {}),
            (["provision", "run-0001"], "provision", ("run-0001",), {}),
            (["authenticate", "runtime", "run-0001", "codex"], "authenticate", ("run-0001", "codex"), {}),
            (["run", "isolation", "run-0001"], "isolation", ("run-0001",), {}),
            (["run", "sync-export", "run-0001"], "sync_export", ("run-0001",), {}),
            (["run", "handoff-forward", "run-0001"], "handoff", ("run-0001", "forward"), {}),
            (["run", "handoff-reverse", "run-0001"], "handoff", ("run-0001", "reverse"), {}),
            (["run", "restart", "run-0001"], "restart", ("run-0001",), {}),
            (["prepare-seal", "run-0001"], "prepare_seal", ("run-0001",), {}),
            (["seal", "run-0001"], "seal", ("run-0001",), {}),
            (["cleanup", "run-0001", "--cause", "abandonment"], "cleanup", ("run-0001",), {"cause": "abandonment"}),
            (["verify-cleanup", "run-0001", "--revoke-human-confirmed"], "verify_cleanup", ("run-0001",), {"revoke_human_confirmed": True}),
        )
        for argv, method_name, positional, keyword in cases:
            with self.subTest(argv=argv):
                orchestrator = Mock()
                getattr(orchestrator, method_name).return_value = {}
                self.assertEqual(dispatch(parser.parse_args(argv), orchestrator), {})
                getattr(orchestrator, method_name).assert_called_once_with(*positional, **keyword)

    def test_unexpected_cli_error_reports_sanitized_diagnostic(self) -> None:
        output = io.StringIO()
        with (
            patch("calibrate.dispatch", side_effect=RuntimeError("secret-bearing detail")),
            redirect_stderr(output),
        ):
            result = calibrate_main(
                ["--state-root", str(self.state_root), "status", "run-0001"]
            )
        self.assertEqual(result, 1)
        diagnostic = json.loads(output.getvalue())
        self.assertEqual(diagnostic["exception_class"], "builtins.RuntimeError")
        self.assertEqual(len(diagnostic["diagnostic_id"]), 16)
        self.assertNotIn("secret-bearing detail", output.getvalue())

    def test_cleanup_records_failed_destructive_attempts(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")

        def nonzero(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 9, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=nonzero):
            self.orchestrator.cleanup(run_id, cause="abandonment")
        attempts = json.loads(
            (self.orchestrator._paths(run_id).cleanup / "attempts.jsonl")
            .read_text()
            .splitlines()[-1]
        )
        self.assertEqual(
            attempts["destructive_attempts"]["delete:outer-loop-week0-codex"],
            "NONZERO",
        )
        self.assertEqual(
            attempts["destructive_attempts"]["launchagent:bootout"],
            "NONZERO",
        )


class PeerIsolationTests(unittest.TestCase):
    def driver(self) -> LimaDriver:
        return LimaDriver.__new__(LimaDriver)

    def test_peer_isolation_accepts_only_baseline_reachable_peer_denial(self) -> None:
        driver = self.driver()
        nonces = ("1" * 32, "2" * 32, "3" * 32, "4" * 32)
        with (
            patch.object(driver, "_guest_ipv4", return_value="192.0.2.10"),
            patch.object(driver, "_start_guest_canary"),
            patch.object(driver, "_guest_send", side_effect=(0, 1, 0, 1)),
            patch.object(driver, "_finish_guest_canary", side_effect=(nonces[0], None, nonces[2], None)),
            patch("lib.orchestrator.secrets.token_hex", side_effect=nonces),
        ):
            result = driver._verify_peer_isolation()
        self.assertEqual(len(result["directions"]), 2)
        self.assertTrue(all(not item["peer_ingress"] for item in result["directions"]))

    def test_peer_isolation_rejects_unreachable_baseline(self) -> None:
        driver = self.driver()
        with (
            patch.object(driver, "_guest_ipv4", return_value="192.0.2.10"),
            patch.object(driver, "_start_guest_canary"),
            patch.object(driver, "_guest_send", return_value=1),
            patch("lib.orchestrator.secrets.token_hex", return_value="1" * 32),
        ):
            with self.assertRaisesRegex(ContractError, "baseline was unreachable"):
                driver._verify_peer_isolation()

    def test_peer_isolation_rejects_peer_ingress(self) -> None:
        driver = self.driver()
        nonces = ("1" * 32, "2" * 32)
        with (
            patch.object(driver, "_guest_ipv4", return_value="192.0.2.10"),
            patch.object(driver, "_start_guest_canary"),
            patch.object(driver, "_guest_send", side_effect=(0, 0)),
            patch.object(driver, "_finish_guest_canary", side_effect=(nonces[0], nonces[1])),
            patch("lib.orchestrator.secrets.token_hex", side_effect=nonces),
        ):
            with self.assertRaisesRegex(ContractError, "guest-to-guest transport is reachable"):
                driver._verify_peer_isolation()


class C03DriverTests(unittest.TestCase):
    def test_host_probe_requires_guest_root_outside_baseline(self) -> None:
        driver = LimaDriver.__new__(LimaDriver)
        target = ProbeTarget("codex", "initial", "dns", "tcp", "host")
        nonce = "a" * 32
        canary = Mock(port=39001)
        canary.wait.return_value = nonce
        passed_outcome = ProbeOutcome("PAIRED_DENIAL_PROVED", ControlResult.PASS, True, "complete")
        with (
            patch("lib.orchestrator.secrets.token_hex", return_value=nonce),
            patch("lib.orchestrator.OneShotCanary", return_value=canary),
            patch.object(
                driver,
                "_shell",
                return_value=subprocess.CompletedProcess([], 0, stdout="", stderr=""),
            ) as guest_shell,
            patch.object(driver, "_run_probe_stage", return_value=(passed_outcome, {"ok": True})),
        ):
            record = driver._execute_host_probe("run-0001", target, Path("/tmp/listeners"))
        self.assertEqual(record.result, ControlResult.PASS)
        baseline_argv = guest_shell.call_args.args[1]
        self.assertEqual(baseline_argv[0], "sudo")
        self.assertEqual(baseline_argv[1], "/usr/bin/python3")
        self.assertIn("host.lima.internal", baseline_argv)

    def test_host_probe_blocks_when_guest_root_baseline_fails(self) -> None:
        driver = LimaDriver.__new__(LimaDriver)
        target = ProbeTarget("codex", "initial", "dns", "udp", "host")
        nonce = "a" * 32
        canary = Mock(port=39002)
        canary.wait.return_value = None
        with (
            patch("lib.orchestrator.secrets.token_hex", return_value=nonce),
            patch("lib.orchestrator.OneShotCanary", return_value=canary),
            patch.object(
                driver,
                "_shell",
                return_value=subprocess.CompletedProcess([], 1, stdout="", stderr=""),
            ),
            patch.object(driver, "_run_probe_stage") as inside_probe,
        ):
            record = driver._execute_host_probe("run-0001", target, Path("/tmp/listeners"))
        self.assertEqual(record.result, ControlResult.UNVERIFIED)
        inside_probe.assert_not_called()

if __name__ == "__main__":
    unittest.main()
