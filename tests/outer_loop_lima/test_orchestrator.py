from __future__ import annotations

import errno
import hashlib
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
from lib.paths import RunPaths  # noqa: E402
from lib.probes import (  # noqa: E402
    CanaryResult,
    ExecutionReceipt,
    ProbeOutcome,
    ProbeTarget,
    argv_digest,
    required_probe_matrix,
)


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
                passed(run_id, control_id, direction, f"{direction}:{target}")
                for direction in ("forward", "reverse")
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
        self.assertEqual(
            self.orchestrator._load(self.orchestrator._paths(run_id))["authentication_attempts"],
            ["codex", "claude"],
        )
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

    def test_provision_registers_retention_before_guest_creation(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["phase"] = Phase.PRE_VM_APPROVED
        self.orchestrator._save(paths, state)
        events: list[str] = []

        class OrderedDriver(FakeDriver):
            def provision(self, run_id: str, frozen_harness: Path) -> PhaseResult:
                events.append("provision")
                return super().provision(run_id, frozen_harness)

        self.orchestrator._driver_factory = lambda _paths: OrderedDriver()
        with patch.object(
            self.orchestrator,
            "_register_retention",
            side_effect=lambda _paths: events.append("retention"),
        ):
            self.orchestrator.provision(run_id)
        self.assertEqual(events, ["retention", "provision"])

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

    def test_incomplete_sync_export_directions_block(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["phase"] = Phase.ISOLATION_COMPLETE
        self.orchestrator._save(paths, state)

        class ForwardOnlyDriver(FakeDriver):
            def sync_export(self, run_id: str) -> PhaseResult:
                result = super().sync_export(run_id)
                return PhaseResult(
                    tuple(record for record in result.controls if record.key.occurrence == "forward")
                )

        self.orchestrator._driver_factory = lambda _paths: ForwardOnlyDriver()
        with self.assertRaisesRegex(ContractError, "sync/export direction coverage mismatch"):
            self.orchestrator.sync_export(run_id)
        self.assertEqual(self.orchestrator.status(run_id)["terminal_state"], TerminalState.BLOCKED)

    def test_status_converts_orphaned_started_control_to_unverified_blocked(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        current = dict(state)
        current["phase"] = Phase.AUTHENTICATED
        self.orchestrator._save(paths, current)
        self.orchestrator._begin(
            paths,
            state,
            "run isolation",
            Phase.AUTHENTICATED,
            control_id="C03",
            occurrence="initial",
            target="matrix",
        )
        self.orchestrator._release_operation_lock(paths)
        status = self.orchestrator.status(run_id)
        self.assertEqual(status["terminal_state"], TerminalState.BLOCKED)
        self.assertEqual(status["operation_state"], "ORPHANED_BLOCKED")
        control = json.loads((paths.evidence / "controls.jsonl").read_text().splitlines()[-1])
        self.assertEqual(control["result"], "UNVERIFIED")

    def test_status_reports_lock_held_operation_without_blocking_it(self) -> None:
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
        watcher = Orchestrator(
            harness_root=self.harness,
            state_root=self.state_root,
            driver_factory=lambda _paths: FakeDriver(),
            now=lambda: datetime(2029, 1, 1, tzinfo=UTC),
        )
        with self.assertRaisesRegex(ContractError, "still in progress"):
            watcher._begin(
                paths,
                watcher._load(paths),
                "run isolation",
                Phase.AUTHENTICATED,
            )
        status = watcher.status(run_id)
        self.assertEqual(status["terminal_state"], TerminalState.RUNNING)
        self.assertEqual(status["operation_state"], "IN_PROGRESS")
        self.assertEqual(status["active_operation"], "run isolation")
        self.assertEqual(self.orchestrator._load(paths)["phase"], Phase.AUTHENTICATED)
        self.assertFalse((paths.evidence / "controls.jsonl").exists())
        self.orchestrator._release_operation_lock(paths)

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

    def test_failed_authentication_attempt_requires_logout_or_revoke(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["phase"] = Phase.PRE_AUTH_APPROVED
        self.orchestrator._save(paths, state)

        class FailedAuthDriver(FakeDriver):
            def authenticate(self, run_id: str, runtime: str, occurrence: str) -> PhaseResult:
                raise ContractError("sanitized classification failed")

        self.orchestrator._driver_factory = lambda _paths: FailedAuthDriver()
        with self.assertRaises(ContractError):
            self.orchestrator.authenticate(run_id, "codex")
        state = self.orchestrator._load(paths)
        self.assertEqual(state["authentication_attempts"], ["codex"])

        def nonzero(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 7, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=nonzero) as runner:
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        logout_calls = [
            call.args[0]
            for call in runner.call_args_list
            if "logout" in call.args[0]
        ]
        self.assertEqual(len(logout_calls), 1)
        self.assertIn("codex", logout_calls[0])
        self.assertTrue(state["account_revoke_required"])


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
    def test_probe_client_marks_only_expected_network_denial_errno(self) -> None:
        argv = LimaDriver._probe_client_argv("192.0.2.1", 443, "tcp", "a" * 32)
        fake_socket = Mock()
        fake_socket.create_connection.side_effect = PermissionError(errno.EPERM, "denied")
        stderr = io.StringIO()
        with (
            patch.dict(sys.modules, {"socket": fake_socket}),
            patch.object(sys, "argv", ["-c", *argv[3:]]),
            redirect_stderr(stderr),
            self.assertRaises(SystemExit) as stopped,
        ):
            exec(argv[2], {})
        self.assertEqual(stopped.exception.code, 77)
        self.assertEqual(stderr.getvalue(), "OUTER_LOOP_NETWORK_DENIED\n")

        fake_socket.create_connection.side_effect = OSError(errno.EIO, "unrelated failure")
        with (
            patch.dict(sys.modules, {"socket": fake_socket}),
            patch.object(sys, "argv", ["-c", *argv[3:]]),
            redirect_stderr(io.StringIO()),
            self.assertRaises(OSError),
        ):
            exec(argv[2], {})

    def test_host_probe_requires_guest_root_outside_baseline(self) -> None:
        driver = LimaDriver.__new__(LimaDriver)
        target = ProbeTarget("codex", "initial", "dns", "tcp", "host")
        nonce = "a" * 32
        canary = Mock(port=39001)
        canary.wait.return_value = CanaryResult(nonce, None)
        passed_outcome = ProbeOutcome("PAIRED_DENIAL_PROVED", ControlResult.PASS, True, "complete")
        with (
            patch("lib.orchestrator.secrets.token_hex", return_value=nonce),
            patch("lib.orchestrator.OneShotCanary", return_value=canary) as canary_factory,
            patch.object(driver, "_guest_host_ipv4", return_value="192.0.2.1"),
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
        canary_factory.assert_called_once_with("tcp", bind_host="192.0.2.1", timeout=30)

    def test_host_probe_blocks_when_guest_root_baseline_fails(self) -> None:
        driver = LimaDriver.__new__(LimaDriver)
        target = ProbeTarget("codex", "initial", "dns", "udp", "host")
        nonce = "a" * 32
        canary = Mock(port=39002)
        canary.wait.return_value = CanaryResult(None, None)
        with (
            patch("lib.orchestrator.secrets.token_hex", return_value=nonce),
            patch("lib.orchestrator.OneShotCanary", return_value=canary),
            patch.object(driver, "_guest_host_ipv4", return_value="192.0.2.1"),
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

    def test_host_probe_claude_runs_both_stages_with_stage_two_load_bearing(self) -> None:
        driver = LimaDriver.__new__(LimaDriver)
        target = ProbeTarget("claude", "initial", "dns", "tcp", "host")
        nonce = "c" * 32
        canary = Mock(port=39003)
        canary.wait.return_value = CanaryResult(nonce, None)
        passed_outcome = ProbeOutcome("PAIRED_DENIAL_PROVED", ControlResult.PASS, True, "complete")
        with (
            patch("lib.orchestrator.secrets.token_hex", return_value=nonce),
            patch("lib.orchestrator.OneShotCanary", return_value=canary),
            patch.object(driver, "_guest_host_ipv4", return_value="192.0.2.1"),
            patch.object(
                driver,
                "_shell",
                return_value=subprocess.CompletedProcess([], 0, stdout="", stderr=""),
            ),
            patch.object(
                driver,
                "_run_probe_stage",
                side_effect=((passed_outcome, {"stage": 1}), (passed_outcome, {"stage": 2})),
            ) as stages,
        ):
            record = driver._execute_host_probe("run-0001", target, Path("/tmp/listeners"))
        self.assertEqual(record.result, ControlResult.PASS)
        self.assertEqual([call.kwargs["stage"] for call in stages.call_args_list], ["srt-direct", "claude-bash"])
        self.assertEqual(stages.call_args_list[0].args[1], stages.call_args_list[1].args[1])
        self.assertTrue(all(call.kwargs["bind_host"] == "192.0.2.1" for call in stages.call_args_list))

    def test_probe_stage_listener_error_is_unverified(self) -> None:
        driver = LimaDriver.__new__(LimaDriver)
        target = ProbeTarget("codex", "initial", "dns", "tcp", "host")
        nonce = "d" * 32
        intended = driver._probe_argv("host.lima.internal", 39004, "tcp", nonce)
        receipt = ExecutionReceipt(
            nonce,
            "host",
            argv_digest(intended),
            ObservationClass.DENIED_BY_SANDBOX,
        )
        canary = Mock()
        canary.wait.return_value = CanaryResult(None, "OSError")
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch("lib.orchestrator.OneShotCanary", return_value=canary),
            patch.object(driver, "_run_agent_probe", return_value=(True, receipt)),
        ):
            outcome, log = driver._run_probe_stage(
                target,
                nonce,
                intended,
                39004,
                bind_host="192.0.2.1",
                stage="codex-command",
                outside_ingress_nonce=nonce,
                listeners=Path(temporary),
            )
        self.assertEqual(outcome.result, ControlResult.UNVERIFIED)
        self.assertEqual(outcome.observation, "INSIDE_CANARY_ERROR")
        self.assertEqual(log["inside_canary_error"], "OSError")
        self.assertEqual(log["canary_bind_host"], "192.0.2.1")

    def test_guest_host_ipv4_rejects_unspecified_and_loopback_addresses(self) -> None:
        driver = LimaDriver.__new__(LimaDriver)
        with patch.object(
            driver,
            "_shell",
            return_value=subprocess.CompletedProcess(
                [],
                0,
                stdout="0.0.0.0 STREAM host.lima.internal\n127.0.0.1 STREAM host.lima.internal\n192.0.2.1 STREAM host.lima.internal\n",
                stderr="",
            ),
        ):
            self.assertEqual(driver._guest_host_ipv4("codex"), "192.0.2.1")


class HandoffDriverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.paths = RunPaths.for_run("run-0001", self.root / "state")
        self.paths.create()
        self.bundle = self.paths.fixture_bundles / "forward"
        self.bundle.mkdir()
        self.manifest = self.bundle / "bundle-manifest.json"
        self.manifest.write_text('{"schema_version":1,"frozen_inventory":[]}')
        self.expected_digest = hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.driver = LimaDriver(self.paths, self.root / "state", HARNESS)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _result(
        self,
        argv,
        *,
        reviewer_digest: str | None = None,
        driver_status: str = "stopped",
        **_kwargs,
    ):
        if "--all-fields" in argv and argv[-1] == "outer-loop-week0-codex":
            value = [{"name": argv[-1], "status": driver_status, "dir": "driver", "vmType": "vz", "arch": "aarch64"}]
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(value), stderr="")
        if "--all-fields" in argv:
            value = [{"name": argv[-1], "status": "running", "dir": "reviewer", "vmType": "vz", "arch": "aarch64"}]
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(value), stderr="")
        if "python3" in argv:
            return subprocess.CompletedProcess(
                argv,
                0,
                stdout=(reviewer_digest or self.expected_digest) + "\n",
                stderr="",
            )
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    def test_handoff_uses_direction_bundle_and_accepts_matching_reviewer_digest(self) -> None:
        with patch.object(self.driver.runner, "run", side_effect=self._result) as runner:
            result = self.driver.handoff("run-0001", "forward")
        self.assertEqual(result.controls[0].result, ControlResult.PASS)
        copy_call = next(call.args[0] for call in runner.call_args_list if "copy" in call.args[0])
        self.assertIn(str(self.bundle), copy_call)

    def test_handoff_rejects_reviewer_digest_mismatch(self) -> None:
        with patch.object(
            self.driver.runner,
            "run",
            side_effect=lambda argv, **kwargs: self._result(argv, reviewer_digest="0" * 64),
        ):
            with self.assertRaisesRegex(ContractError, "reviewer digest mismatch"):
                self.driver.handoff("run-0001", "forward")

    def test_handoff_rejects_driver_stop_identity_mismatch_before_copy(self) -> None:
        with patch.object(
            self.driver.runner,
            "run",
            side_effect=lambda argv, **kwargs: self._result(argv, driver_status="running"),
        ) as runner:
            with self.assertRaisesRegex(ContractError, "driver stop identity mismatch"):
                self.driver.handoff("run-0001", "forward")
        self.assertFalse(any("copy" in call.args[0] for call in runner.call_args_list))

if __name__ == "__main__":
    unittest.main()
