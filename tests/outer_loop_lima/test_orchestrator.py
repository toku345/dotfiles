from __future__ import annotations

import errno
import hashlib
import json
import io
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import UTC, datetime
from pathlib import Path
from contextlib import redirect_stderr
from unittest.mock import Mock, patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
SHORT_TEMP_ROOT = Path("/tmp").resolve()
sys.path.insert(0, str(HARNESS))

from calibrate import build_parser, dispatch, main as calibrate_main  # noqa: E402
from lib.evidence import append_jsonl  # noqa: E402
from lib.model import (  # noqa: E402
    CleanupDisposition,
    CleanupManualReason,
    ContractError,
    ControlKey,
    ControlRecord,
    ControlResult,
    ObservationClass,
    TerminalState,
    LimaIdentity,
    LimaListDisposition,
    ProvisionAttemptOutcome,
    RUNTIME_SCHEMA_VERSION,
)
from lib.lima_state import (  # noqa: E402
    CODEX_INSTANCE,
    LimaListSnapshot,
    parser_contract_digest,
)
from lib.orchestrator import (  # noqa: E402
    BoundedCommandError,
    BoundedCommandStage,
    LimaDriver,
    Orchestrator,
    Phase,
    PhaseResult,
)
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


def absent_snapshot() -> LimaListSnapshot:
    return LimaListSnapshot(
        LimaListDisposition.ABSENT,
        (),
        "a" * 64,
        "b" * 64,
        0,
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
        self.root = Path(self.temporary.name).resolve()
        self.harness = self.root / "harness"
        self.harness.mkdir()
        (self.harness / "versions.lock.json").write_text("{}")
        (self.harness / "manifest.json").write_text("{}")
        self.state_root = self.root / "state"
        self.pool_temporary = tempfile.TemporaryDirectory(prefix="ol-", dir=SHORT_TEMP_ROOT)
        self.lima_pool_root = Path(self.pool_temporary.name)

        def exact_input(prompt: str) -> str:
            return prompt.rsplit("(", 1)[1].split(")", 1)[0]

        self.orchestrator = Orchestrator(
            harness_root=self.harness,
            state_root=self.state_root,
            lima_pool_root=self.lima_pool_root,
            driver_factory=lambda _paths: FakeDriver(),
            stdin_isatty=lambda: True,
            stdout_isatty=lambda: True,
            input_fn=exact_input,
            now=lambda: datetime(2029, 1, 1, tzinfo=UTC),
        )

    def tearDown(self) -> None:
        self.pool_temporary.cleanup()
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
            patch.object(self.orchestrator, "_capture_lima_snapshot", return_value=absent_snapshot()),
        ):
            preflight = self.orchestrator.preflight(run_id)
        paths = self.orchestrator._paths(run_id)
        freshness = json.loads(
            (paths.evidence / "lima-preflight-snapshot.json").read_text()
        )
        self.assertEqual(freshness["schema_version"], 2)
        self.assertEqual(
            preflight["preflight_snapshot_digest"], freshness["snapshot_digest"]
        )
        self.assertEqual(len(preflight["approval_targets"]["pre-vm"]), 64)
        self.orchestrator.approve_pre_vm(run_id)
        with (
            patch.object(self.orchestrator, "_register_retention"),
            patch("lib.orchestrator.validate_manifest", return_value={}),
            patch.object(self.orchestrator, "_validate_h1_binding"),
            patch.object(self.orchestrator, "_capture_lima_snapshot", return_value=absent_snapshot()),
        ):
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

    def test_init_writes_schema_two_state_and_write_once_home_binding(self) -> None:
        state = self.orchestrator.init("run-0001", "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths("run-0001")
        self.assertEqual(state["schema_version"], 2)
        self.assertEqual(state["lima_home_binding"]["schema_version"], 2)
        self.assertEqual(
            json.loads((paths.evidence / "retention.json").read_text())["schema_version"],
            2,
        )
        self.assertEqual(
            json.loads((paths.evidence / "lima-home-binding.json").read_text()),
            state["lima_home_binding"],
        )

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

        wrapper_path = paths.cleanup / "deadline-cleanup.sh"
        plist = paths.cleanup / "com.toku345.outer-loop-lima-cleanup.run-0001.plist"

        def success(argv, **_kwargs):
            output = ""
            if "print" in argv:
                target = argv[-1]
                output = "\n".join(
                    (
                        f"{target} = {{",
                        f"\tpath = {plist}",
                        f"\tprogram = {wrapper_path}",
                        "\targuments = {",
                        f"\t\t{wrapper_path}",
                        "\t}",
                        "}",
                    )
                )
            return subprocess.CompletedProcess(argv, 0, stdout=output, stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=success) as runner:
            self.orchestrator._register_retention(paths)
        self.assertEqual(runner.call_count, 3)
        wrapper = wrapper_path.read_text()
        self.assertIn("2030-01-02T03:04:05Z", wrapper)
        self.assertIn("cleanup run-0001 --cause deadline", wrapper)
        self.assertIn(f"--lima-pool-root {self.lima_pool_root}", wrapper)
        self.assertTrue(plist.is_file())

    def test_retention_readback_mismatch_blocks_before_guest_creation(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T03:04:05Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["phase"] = Phase.PRE_VM_APPROVED
        state["preflight_snapshot_digest"] = "a" * 64
        self.orchestrator._save(paths, state)
        (paths.frozen_harness / "versions.lock.json").write_text(
            json.dumps({"artifacts": {"host_python": {"source": "/usr/bin/python3"}}})
        )
        driver = Mock()
        self.orchestrator._driver_factory = lambda _paths: driver

        def mismatched(argv, **_kwargs):
            output = "gui/501/wrong = {\n\tprogram = /wrong\n\targuments = {\n\t\t/wrong\n\t}\n}\n" if "print" in argv else ""
            return subprocess.CompletedProcess(argv, 0, stdout=output, stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=mismatched), self.assertRaisesRegex(
            ContractError, "read-back"
        ):
            self.orchestrator.provision(run_id)
        driver.provision.assert_not_called()

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
        ), patch("lib.orchestrator.validate_manifest", return_value={}), patch.object(
            self.orchestrator, "_validate_h1_binding"
        ), patch.object(
            self.orchestrator,
            "_freshness_evidence",
            side_effect=lambda *_args, **_kwargs: {
                "schema_version": 2,
                "snapshot_digest": "a" * 64,
            },
        ):
            state["preflight_snapshot_digest"] = "b" * 64
            self.orchestrator._save(paths, state)
            self.orchestrator.provision(run_id)
        self.assertEqual(events, ["retention", "provision"])

    def test_pre_create_freshness_failure_never_calls_driver(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["phase"] = Phase.PRE_VM_APPROVED
        state["preflight_snapshot_digest"] = "a" * 64
        self.orchestrator._save(paths, state)
        driver = Mock()
        self.orchestrator._driver_factory = lambda _paths: driver
        with (
            patch.object(self.orchestrator, "_register_retention"),
            patch("lib.orchestrator.validate_manifest", return_value={}),
            patch.object(self.orchestrator, "_validate_h1_binding"),
            patch.object(
                self.orchestrator,
                "_freshness_evidence",
                side_effect=ContractError("namespace appeared"),
            ),
            self.assertRaisesRegex(ContractError, "namespace appeared"),
        ):
            self.orchestrator.provision(run_id)
        driver.provision.assert_not_called()
        self.assertFalse((paths.evidence / "provision-attempts.jsonl").exists())

    def test_h1_binding_accepts_exact_identity_and_rejects_drift(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["preflight_snapshot_digest"] = "c" * 64
        source_manifest = self.harness / "manifest.json"
        frozen_manifest = paths.frozen_harness / "manifest.json"
        manifest_bytes = source_manifest.read_bytes()
        frozen_manifest.write_bytes(manifest_bytes)
        valid_identity = {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "manifest_digest": hashlib.sha256(manifest_bytes).hexdigest(),
            "parser_contract_digest": parser_contract_digest(),
            "lima_home_binding": state["lima_home_binding"],
            "lima_freshness_snapshot_digest": state["preflight_snapshot_digest"],
        }
        identity_path = paths.evidence / "identity.json"
        identity_path.write_text(json.dumps(valid_identity))

        self.orchestrator._validate_h1_binding(paths, state)

        drift_cases = (
            ("runtime schema", {"schema_version": 1}, None),
            ("manifest identity", {"manifest_digest": "0" * 64}, None),
            ("parser contract", {"parser_contract_digest": "0" * 64}, None),
            (
                "Lima home binding",
                {
                    "lima_home_binding": dict(state["lima_home_binding"])
                    | {"binding_digest": "0" * 64}
                },
                None,
            ),
            ("freshness snapshot", {"lima_freshness_snapshot_digest": "0" * 64}, None),
            ("source manifest", {}, source_manifest),
            ("frozen manifest", {}, frozen_manifest),
        )
        for name, identity_drift, manifest_to_drift in drift_cases:
            with self.subTest(name=name):
                source_manifest.write_bytes(manifest_bytes)
                frozen_manifest.write_bytes(manifest_bytes)
                identity_path.write_text(json.dumps(valid_identity | identity_drift))
                if manifest_to_drift is not None:
                    manifest_to_drift.write_text('{"drifted":true}')
                with self.assertRaisesRegex(ContractError, "H1 harness, parser, or freshness"):
                    self.orchestrator._validate_h1_binding(paths, state)

        source_manifest.write_bytes(manifest_bytes)
        frozen_manifest.write_bytes(manifest_bytes)
        identity_path.write_text(json.dumps(valid_identity))

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
            lima_pool_root=self.lima_pool_root,
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
                [
                    "--state-root",
                    str(self.state_root),
                    "--lima-pool-root",
                    str(self.lima_pool_root),
                    "status",
                    "run-0001",
                ]
            )
        self.assertEqual(result, 1)
        diagnostic = json.loads(output.getvalue())
        self.assertEqual(diagnostic["exception_class"], "builtins.RuntimeError")
        self.assertEqual(len(diagnostic["diagnostic_id"]), 16)
        self.assertNotIn("secret-bearing detail", output.getvalue())

    def test_bounded_cli_error_reports_only_allowlisted_failure_stage(self) -> None:
        output = io.StringIO()
        error = BoundedCommandError(
            "limactl",
            "UNAVAILABLE",
            BoundedCommandStage.POST_START_MOUNT_POLICY_CHECK,
        )
        with (
            patch("calibrate.dispatch", side_effect=error),
            redirect_stderr(output),
        ):
            result = calibrate_main(
                [
                    "--state-root",
                    str(self.state_root),
                    "--lima-pool-root",
                    str(self.lima_pool_root),
                    "status",
                    "run-0001",
                ]
            )
        self.assertEqual(result, 1)
        self.assertEqual(
            json.loads(output.getvalue()),
            {
                "error": "bounded command failed: limactl",
                "failure_stage": "POST_START_MOUNT_POLICY_CHECK",
                "real_task_allowed": False,
                "terminal_state": "BLOCKED",
            },
        )

    def test_generic_contract_error_has_no_failure_stage(self) -> None:
        output = io.StringIO()
        with (
            patch("calibrate.dispatch", side_effect=ContractError("safe contract failure")),
            redirect_stderr(output),
        ):
            result = calibrate_main(
                [
                    "--state-root",
                    str(self.state_root),
                    "--lima-pool-root",
                    str(self.lima_pool_root),
                    "status",
                    "run-0001",
                ]
            )
        self.assertEqual(result, 1)
        self.assertNotIn("failure_stage", json.loads(output.getvalue()))

    def test_custom_state_root_without_pool_is_rejected_before_write(self) -> None:
        output = io.StringIO()
        state_root = self.root / "custom-state"
        with redirect_stderr(output):
            result = calibrate_main(
                [
                    "--state-root",
                    str(state_root),
                    "init",
                    "run-0001",
                    "--retention-deadline",
                    "2030-01-02T00:00:00Z",
                ]
            )
        self.assertEqual(result, 1)
        self.assertIn("requires --lima-pool-root", output.getvalue())
        self.assertFalse(state_root.exists())

    def test_legacy_schema_status_is_read_only_and_mutation_is_rejected(self) -> None:
        run_id = "run-legacy"
        paths = self.orchestrator._paths(run_id)
        paths.root.mkdir(mode=0o700, parents=True)
        paths.work.mkdir(mode=0o700)
        paths.evidence.mkdir(mode=0o700)
        legacy = {
            "schema_version": 1,
            "run_id": run_id,
            "retention_deadline": "2030-01-02T00:00:00Z",
            "phase": Phase.INITIALIZED,
            "terminal_state": TerminalState.RUNNING,
            "real_task_allowed": False,
            "active_operation": {"name": "legacy-operation"},
        }
        paths.state_file.write_text(json.dumps(legacy))
        before = paths.state_file.read_bytes()
        status = self.orchestrator.status(run_id)
        self.assertEqual(status["operation_state"], "LEGACY_READ_ONLY")
        self.assertEqual(paths.state_file.read_bytes(), before)
        self.assertFalse((paths.work / "operation.lock").exists())
        with self.assertRaisesRegex(ContractError, "schema 1 is read-only"):
            self.orchestrator.preflight(run_id)
        with self.assertRaisesRegex(ContractError, "schema 1 is read-only"):
            self.orchestrator.cleanup(run_id, cause="abandonment")

    def test_cleanup_unknown_is_manual_required_without_destructive_calls(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)

        def unknown(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 0, stdout="null\n", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=unknown) as runner:
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertFalse(any("stop" in argv or "delete" in argv for argv in calls))
        self.assertTrue(paths.lima_home.is_dir())
        self.assertEqual(
            state["cleanup_disposition"],
            CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
        )
        reason_code = CleanupManualReason.LIMA_LIST_UNKNOWN.value
        self.assertEqual(state["cleanup_manual_reason_code"], reason_code)
        completed_attempt = json.loads(
            (paths.cleanup / "attempts.jsonl").read_text().splitlines()[-1]
        )
        self.assertEqual(completed_attempt["reason_code"], reason_code)
        self.assertIn(reason_code, paths.state_file.read_text())
        self.assertIn(reason_code, (paths.cleanup / "attempts.jsonl").read_text())
        attestation = json.loads(
            (paths.cleanup / "attestations.jsonl").read_text().splitlines()[-1]
        )
        self.assertEqual(attestation["manual_reason_code"], reason_code)
        self.assertEqual(attestation["observations"]["codex_instance"], "UNKNOWN")
        self.assertEqual(attestation["observations"]["claude_instance"], "UNKNOWN")
        self.assertEqual(attestation["observations"]["lima_home"], "PRESENT")
        self.assertEqual(attestation["observations"]["staging"], "ABSENT")

        before_status = {
            path: path.read_bytes()
            for path in (
                paths.state_file,
                paths.cleanup / "attempts.jsonl",
                paths.cleanup / "attestations.jsonl",
            )
        }
        with patch("lib.orchestrator.CommandRunner.run") as status_runner:
            status = self.orchestrator.status(run_id)
        status_runner.assert_not_called()
        self.assertEqual(status["cleanup_manual_reason_code"], reason_code)
        self.assertEqual(status["cleanup_diagnostics"]["reason_code"], reason_code)
        self.assertEqual(
            status["cleanup_diagnostics"]["binding_registry"],
            str(paths.binding_registry),
        )
        self.assertEqual(
            {path: path.read_bytes() for path in before_status},
            before_status,
        )
        with patch("lib.orchestrator.CommandRunner.run") as retry_runner, self.assertRaisesRegex(
            ContractError, "retry is prohibited"
        ):
            self.orchestrator.cleanup(run_id, cause="abandonment")
        retry_runner.assert_not_called()
        with self.assertRaisesRegex(ContractError, "unresolved manual cleanup"):
            self.orchestrator.init("run-0002", "2030-01-02T00:00:00Z")

        prior_home = paths.lima_home
        prior_home.rmdir()
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )

        def verified_absence(argv, **_kwargs):
            if "list" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)
            if "print" in argv:
                return subprocess.CompletedProcess(
                    argv, 1, stdout="", stderr="Could not find service"
                )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=verified_absence):
            verified = self.orchestrator.verify_cleanup(
                run_id,
                revoke_human_confirmed=False,
            )
        self.assertTrue(verified["cleanup_verified"])
        self.assertEqual(
            verified["cleanup_disposition"],
            CleanupDisposition.CLEANUP_VERIFIED,
        )
        self.assertIsNone(verified["cleanup_manual_reason_code"])
        next_run = self.orchestrator.init("run-0002", "2030-01-02T00:00:00Z")
        self.assertEqual(next_run["terminal_state"], TerminalState.RUNNING)
        self.assertNotEqual(self.orchestrator._paths("run-0002").lima_home, prior_home)

    def test_cleanup_and_verify_accept_strict_absence(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )

        def absent(argv, **_kwargs):
            if "list" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)
            if "print" in argv:
                return subprocess.CompletedProcess(
                    argv, 1, stdout="", stderr="Could not find service"
                )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=absent):
            cleaned = self.orchestrator.cleanup(run_id, cause="abandonment")
            state = self.orchestrator.verify_cleanup(run_id, revoke_human_confirmed=False)
        self.assertTrue(cleaned["cleanup_verified"])
        self.assertEqual(cleaned["terminal_state"], TerminalState.BLOCKED)
        self.assertEqual(cleaned["phase"], Phase.BLOCKED)
        self.assertTrue(state["cleanup_verified"])
        self.assertEqual(state["terminal_state"], TerminalState.BLOCKED)
        self.assertEqual(state["phase"], Phase.BLOCKED)
        self.assertFalse(self.orchestrator._paths(run_id).lima_home.exists())

    def test_cleanup_restores_ready_terminal_and_phase(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["terminal_state"] = TerminalState.READY
        state["phase"] = Phase.SEALED
        self.orchestrator._save(paths, state)
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )

        def absent(argv, **_kwargs):
            if "list" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)
            if "print" in argv:
                return subprocess.CompletedProcess(
                    argv, 1, stdout="", stderr="Could not find service"
                )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=absent):
            cleaned = self.orchestrator.cleanup(run_id, cause="cohort-completion")
        self.assertTrue(cleaned["cleanup_verified"])
        self.assertEqual(cleaned["terminal_state"], TerminalState.READY)
        self.assertEqual(cleaned["phase"], Phase.SEALED)

    def test_cleanup_exposure_does_not_restore_ready_terminal(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        state = self.orchestrator._load(paths)
        state["terminal_state"] = TerminalState.READY
        state["phase"] = Phase.SEALED
        self.orchestrator._save(paths, state)
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )

        def absent(argv, **_kwargs):
            if "list" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)
            if "print" in argv:
                return subprocess.CompletedProcess(
                    argv, 1, stdout="", stderr="Could not find service"
                )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=absent):
            cleaned = self.orchestrator.cleanup(run_id, cause="exposure")
        self.assertFalse(cleaned["cleanup_verified"])
        self.assertTrue(cleaned["account_revoke_required"])
        self.assertEqual(
            cleaned["cleanup_disposition"],
            CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
        )
        self.assertEqual(cleaned["terminal_state"], TerminalState.BLOCKED)
        self.assertEqual(cleaned["phase"], Phase.BLOCKED)

    def test_non_success_provision_attempt_is_not_automatic_cleanup_eligible(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        for event, outcome in (
            ("STARTED", None),
            ("COMPLETED", ProvisionAttemptOutcome.NONZERO),
        ):
            record = {
                "schema_version": RUNTIME_SCHEMA_VERSION,
                "record_type": "provision_attempt",
                "run_id": run_id,
                "runtime": "codex",
                "action": "create",
                "event": event,
                "command_digest": "a" * 64,
                "observed_at": "2029-01-01T00:00:00Z",
            }
            if outcome is not None:
                record["outcome"] = outcome
            append_jsonl(paths.evidence / "provision-attempts.jsonl", record)
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )

        def absent(argv, **_kwargs):
            if "list" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)
            if "print" in argv:
                return subprocess.CompletedProcess(
                    argv, 1, stdout="", stderr="Could not find service"
                )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with (
            patch("lib.orchestrator.CommandRunner.run", side_effect=absent) as runner,
            patch.object(Path, "rmdir") as rmdir,
        ):
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertFalse(any("stop" in argv or "delete" in argv for argv in calls))
        rmdir.assert_not_called()
        self.assertTrue(paths.lima_home.is_dir())
        self.assertEqual(
            state["cleanup_disposition"],
            CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
        )
        self.assertEqual(
            state["cleanup_manual_reason_code"],
            CleanupManualReason.PROVISION_NOT_AUTOMATIC_CLEANUP_ELIGIBLE.value,
        )

    def test_administrative_residue_stops_retention_without_automatic_retry(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        residue = paths.lima_home / "_config"
        residue.mkdir()
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )
        job_active = True

        def observed(argv, **_kwargs):
            nonlocal job_active
            if "list" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)
            if "bootout" in argv:
                job_active = False
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
            if "print" in argv:
                if job_active:
                    return subprocess.CompletedProcess(
                        argv, 0, stdout="service active", stderr=""
                    )
                return subprocess.CompletedProcess(
                    argv, 1, stdout="", stderr="Could not find service"
                )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with (
            patch("lib.orchestrator.CommandRunner.run", side_effect=observed) as runner,
            patch.object(Path, "rmdir") as rmdir,
        ):
            state = self.orchestrator.cleanup(run_id, cause="deadline")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertFalse(any("stop" in argv or "delete" in argv for argv in calls))
        rmdir.assert_not_called()
        self.assertEqual(sum("bootout" in argv for argv in calls), 1)
        self.assertTrue(state["retention_job_inactive"])
        self.assertEqual(
            state["cleanup_manual_reason_code"],
            CleanupManualReason.PHYSICAL_LIMA_HOME_NOT_EMPTY.value,
        )
        self.assertTrue(residue.is_dir())
        self.assertTrue(paths.lima_home.is_dir())

        with patch("lib.orchestrator.CommandRunner.run") as retry_runner, self.assertRaisesRegex(
            ContractError, "retry is prohibited"
        ):
            self.orchestrator.cleanup(run_id, cause="deadline")
        retry_runner.assert_not_called()

    def test_cleanup_recognized_running_guest_uses_lima_then_requires_manual_verification(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        instance_dir = paths.lima_home / CODEX_INSTANCE
        instance_dir.mkdir()
        identity = LimaIdentity(
            CODEX_INSTANCE,
            "Running",
            str(instance_dir),
            "vz",
            "aarch64",
            4,
            8589934592,
            42949672960,
        )
        append_jsonl(
            paths.evidence / "lima-identities.jsonl",
            identity.to_dict() | {"runtime": "codex", "stage": "post-start"},
        )
        for action in ("create", "start"):
            for event, outcome in (("STARTED", None), ("COMPLETED", "SUCCESS")):
                record = {
                    "schema_version": 2,
                    "record_type": "provision_attempt",
                    "run_id": run_id,
                    "runtime": "codex",
                    "action": action,
                    "event": event,
                    "command_digest": "a" * 64,
                    "observed_at": "2029-01-01T00:00:00Z",
                }
                if outcome is not None:
                    record["outcome"] = outcome
                append_jsonl(paths.evidence / "provision-attempts.jsonl", record)
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )
        status = "Running"
        present = True

        def recognized(argv, **_kwargs):
            nonlocal status, present
            if "list" in argv:
                if not present:
                    return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)
                value = {
                    "name": CODEX_INSTANCE,
                    "status": status,
                    "dir": str(instance_dir),
                    "vmType": "vz",
                    "arch": "aarch64",
                    "cpus": 4,
                    "memory": 8589934592,
                    "disk": 42949672960,
                }
                return subprocess.CompletedProcess(
                    argv, 0, stdout=json.dumps(value) + "\n", stderr=""
                )
            if "stop" in argv:
                status = "Stopped"
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
            if "delete" in argv:
                instance_dir.rmdir()
                present = False
                return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
            if "print" in argv:
                return subprocess.CompletedProcess(
                    argv, 1, stdout="", stderr="Could not find service"
                )
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=recognized) as runner:
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertEqual(
            [argv for argv in calls if "stop" in argv],
            [("limactl", "--tty=false", "stop", CODEX_INSTANCE)],
        )
        self.assertEqual(
            [argv for argv in calls if "delete" in argv],
            [("limactl", "--tty=false", "delete", CODEX_INSTANCE)],
        )
        self.assertFalse(any("--force" in argv for argv in calls))
        self.assertEqual(
            state["cleanup_disposition"],
            CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
        )
        self.assertEqual(
            state["cleanup_manual_reason_code"],
            CleanupManualReason.PROVISIONED_HOME_REQUIRES_MANUAL_VERIFICATION.value,
        )
        self.assertTrue(state["retention_job_inactive"])
        self.assertTrue(paths.lima_home.is_dir())
        self.assertEqual(tuple(paths.lima_home.iterdir()), ())

    def test_cleanup_partial_directory_is_manual_without_destructive_calls(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        (paths.lima_home / CODEX_INSTANCE).mkdir()
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )

        def absent(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)

        with patch("lib.orchestrator.CommandRunner.run", side_effect=absent) as runner:
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertFalse(any("stop" in argv or "delete" in argv for argv in calls))
        self.assertTrue(paths.lima_home.is_dir())
        self.assertEqual(state["cleanup_disposition"], CleanupDisposition.CLEANUP_MANUAL_REQUIRED)

    def test_cleanup_identity_drift_is_manual_without_destructive_calls(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        instance_dir = paths.lima_home / CODEX_INSTANCE
        instance_dir.mkdir()
        recorded = LimaIdentity(
            CODEX_INSTANCE,
            "Stopped",
            str(instance_dir),
            "vz",
            "aarch64",
            4,
            8589934592,
            42949672959,
        )
        append_jsonl(
            paths.evidence / "lima-identities.jsonl",
            recorded.to_dict() | {"runtime": "codex", "stage": "post-create"},
        )
        for event, outcome in (("STARTED", None), ("COMPLETED", "SUCCESS")):
            record = {
                "schema_version": 2,
                "record_type": "provision_attempt",
                "run_id": run_id,
                "runtime": "codex",
                "action": "create",
                "event": event,
                "command_digest": "a" * 64,
                "observed_at": "2029-01-01T00:00:00Z",
            }
            if outcome is not None:
                record["outcome"] = outcome
            append_jsonl(paths.evidence / "provision-attempts.jsonl", record)
        live = json.dumps(
            {
                "name": CODEX_INSTANCE,
                "status": "Stopped",
                "dir": str(instance_dir),
                "vmType": "vz",
                "arch": "aarch64",
                "cpus": 4,
                "memory": 8589934592,
                "disk": 42949672960,
            }
        )

        def listed(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 0, stdout=live + "\n", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=listed) as runner:
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertFalse(any("stop" in argv or "delete" in argv for argv in calls))
        self.assertTrue(paths.lima_home.is_dir())
        self.assertEqual(state["cleanup_disposition"], CleanupDisposition.CLEANUP_MANUAL_REQUIRED)

    def test_cleanup_orphan_attempt_is_manual_without_destructive_calls(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        append_jsonl(
            paths.evidence / "provision-attempts.jsonl",
            {
                "schema_version": 2,
                "record_type": "provision_attempt",
                "run_id": run_id,
                "runtime": "codex",
                "action": "create",
                "event": "STARTED",
                "command_digest": "a" * 64,
                "observed_at": "2029-01-01T00:00:00Z",
            },
        )
        warning = (
            'time="2026-07-18T22:09:00+09:00" level=warning '
            'msg="No instance found. Run `limactl create` to create an instance."'
        )

        def absent(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr=warning)

        with patch("lib.orchestrator.CommandRunner.run", side_effect=absent) as runner:
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertFalse(any("stop" in argv or "delete" in argv for argv in calls))
        self.assertTrue(paths.lima_home.is_dir())
        self.assertEqual(state["cleanup_disposition"], CleanupDisposition.CLEANUP_MANUAL_REQUIRED)

    def test_cleanup_rejects_unrelated_instance_without_destructive_calls(self) -> None:
        run_id = "run-0001"
        self.orchestrator.init(run_id, "2030-01-02T00:00:00Z")
        paths = self.orchestrator._paths(run_id)
        unrelated = json.dumps(
            {
                "name": "unrelated-lima-instance",
                "status": "Stopped",
                "dir": str(paths.lima_home / "unrelated-lima-instance"),
                "vmType": "vz",
                "arch": "aarch64",
                "cpus": 4,
                "memory": 8589934592,
                "disk": 42949672960,
            }
        )

        def listed(argv, **_kwargs):
            if "list" in argv:
                return subprocess.CompletedProcess(argv, 0, stdout=unrelated + "\n", stderr="")
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with patch("lib.orchestrator.CommandRunner.run", side_effect=listed) as runner:
            state = self.orchestrator.cleanup(run_id, cause="abandonment")
        calls = [call.args[0] for call in runner.call_args_list]
        self.assertFalse(any("stop" in argv or "delete" in argv for argv in calls))
        self.assertEqual(
            state["cleanup_disposition"],
            CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
        )

    def test_cleanup_waits_for_live_operation_without_false_unverified_record(self) -> None:
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
            lima_pool_root=self.lima_pool_root,
            driver_factory=lambda _paths: FakeDriver(),
            now=lambda: datetime(2029, 1, 1, tzinfo=UTC),
        )
        lock_attempted = threading.Event()
        original_try_lock = watcher._try_operation_lock

        def observed_try_lock(lock_paths, *, blocking=False):
            if blocking:
                lock_attempted.set()
            return original_try_lock(lock_paths, blocking=blocking)

        watcher._try_operation_lock = observed_try_lock
        failures: list[BaseException] = []

        def run_cleanup() -> None:
            try:
                watcher.cleanup(run_id, cause="abandonment")
            except BaseException as exc:  # pragma: no cover - asserted below
                failures.append(exc)

        result = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch("lib.orchestrator.CommandRunner.run", return_value=result):
            thread = threading.Thread(target=run_cleanup)
            thread.start()
            self.assertTrue(lock_attempted.wait(timeout=2))
            self.assertTrue(thread.is_alive())
            self.orchestrator._finish(
                paths,
                state,
                "run isolation",
                Phase.ISOLATION_COMPLETE,
            )
            thread.join(timeout=2)

        self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        final_state = watcher._load(paths)
        self.assertTrue(final_state["cleanup_started"])
        self.assertEqual(final_state["terminal_state"], TerminalState.BLOCKED)
        self.assertFalse((paths.evidence / "controls.jsonl").exists())

    def test_failed_authentication_attempt_requires_revoke_without_guest_logout(self) -> None:
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
        self.assertEqual(logout_calls, [])
        self.assertTrue(state["account_revoke_required"])
        self.assertEqual(
            state["cleanup_disposition"],
            CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
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


class LimaDriverProvisionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.pool_temporary = tempfile.TemporaryDirectory(prefix="ol-", dir=SHORT_TEMP_ROOT)
        root = Path(self.temporary.name).resolve()
        self.paths = RunPaths.for_run(
            "run-0001",
            root / "state",
            Path(self.pool_temporary.name),
        )
        self.paths.create(instance_names=("outer-loop-week0-codex", "outer-loop-week0-claude"))
        profiles = self.paths.frozen_harness / "profiles"
        profiles.mkdir()
        (profiles / "week0-codex.yaml").write_text("arch: aarch64\n")
        (profiles / "week0-claude.yaml").write_text("arch: aarch64\n")
        self.driver = LimaDriver(self.paths, HARNESS)

    def tearDown(self) -> None:
        self.pool_temporary.cleanup()
        self.temporary.cleanup()

    def test_create_both_stopped_before_start_and_record_attempts(self) -> None:
        events: list[tuple[str, ...]] = []

        def result(argv, **_kwargs):
            command = tuple(argv)
            events.append(command)
            if "list" in command:
                instance = command[-1]
                action_commands = [item for item in events if "create" in item or "start" in item]
                status = "Running" if any("start" in item and item[-1] == instance for item in action_commands) else "Stopped"
                record = {
                    "name": instance,
                    "status": status,
                    "dir": str(self.paths.lima_home / instance),
                    "vmType": "vz",
                    "arch": "aarch64",
                    "cpus": 4,
                    "memory": 8589934592,
                    "disk": 42949672960,
                }
                return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(record) + "\n", stderr="")
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

        with (
            patch.object(self.driver.runner, "run", side_effect=result),
            patch.object(self.driver, "_install_harness"),
            patch.object(self.driver, "_guest_policy_check", return_value={"verified": True}),
            patch.object(self.driver, "_verify_peer_isolation", return_value={"verified": True}),
        ):
            phase = self.driver.provision("run-0001", self.paths.frozen_harness)

        lifecycle = [argv for argv in events if "create" in argv or "start" in argv]
        self.assertEqual([next(value for value in argv if value in {"create", "start"}) for argv in lifecycle], ["create", "create", "start", "start"])
        for argv in lifecycle[:2]:
            self.assertIn("--plain", argv)
            self.assertIn("--mount-none", argv)
            self.assertNotIn("start", argv)
        for argv in lifecycle[2:]:
            self.assertEqual(argv[:4], ("limactl", "--tty=false", "start", "--timeout=20m"))
            self.assertEqual(len(argv), 5)
        records = [
            json.loads(line)
            for line in (self.paths.evidence / "provision-attempts.jsonl")
            .read_text()
            .splitlines()
        ]
        self.assertEqual(len(records), 8)
        self.assertEqual([record["event"] for record in records[::2]], ["STARTED"] * 4)
        self.assertTrue(all(record["outcome"] == "SUCCESS" for record in records[1::2]))
        self.assertEqual(len(phase.controls), 4)

    def test_post_start_harness_commands_use_fixed_failure_stages(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.object(self.driver.runner, "run", return_value=completed) as runner:
            self.driver._install_harness("codex")
        self.assertEqual(
            [call.kwargs["failure_stage"] for call in runner.call_args_list],
            [
                BoundedCommandStage.POST_START_HARNESS_COPY,
                BoundedCommandStage.POST_START_MOUNT_POLICY_CHECK,
                BoundedCommandStage.POST_START_HARNESS_SETUP,
            ],
        )
        mount_command = runner.call_args_list[1].args[0]
        self.assertEqual(
            mount_command[-3:],
            ("sudo", "/bin/sh", "/tmp/outer-loop-harness/guest/check-mount-policy.sh"),
        )

    def test_mount_policy_failure_stops_before_harness_setup(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        failure = BoundedCommandError(
            "limactl",
            "UNAVAILABLE",
            BoundedCommandStage.POST_START_MOUNT_POLICY_CHECK,
        )
        with patch.object(
            self.driver.runner,
            "run",
            side_effect=(completed, failure),
        ) as runner, self.assertRaises(BoundedCommandError) as caught:
            self.driver._install_harness("codex")
        self.assertEqual(runner.call_count, 2)
        self.assertEqual(
            caught.exception.failure_stage,
            BoundedCommandStage.POST_START_MOUNT_POLICY_CHECK,
        )

    def test_post_start_policy_commands_use_fixed_failure_stages(self) -> None:
        def result(_instance, argv, **_kwargs):
            if "sha256sum" in argv:
                paths = argv[argv.index("sha256sum") + 1 :]
                output = "\n".join(f"{'a' * 64}  {path}" for path in paths) + "\n"
            elif argv[0] == "dpkg-query":
                output = "python3=3.12.3-0ubuntu2\n"
            else:
                output = ""
            return subprocess.CompletedProcess(argv, 0, stdout=output, stderr="")

        with patch.object(self.driver, "_shell", side_effect=result) as shell:
            policy = self.driver._guest_policy_check("codex")
        self.assertEqual(
            [call.kwargs["failure_stage"] for call in shell.call_args_list],
            [
                BoundedCommandStage.POST_START_POLICY_CHECK,
                BoundedCommandStage.POST_START_IDENTITY_DIGEST,
                BoundedCommandStage.POST_START_PACKAGE_QUERY,
            ],
        )
        policy_command = shell.call_args_list[0].args[1][-1]
        self.assertIn("guest/check-mount-policy.sh", policy_command)
        self.assertEqual(
            policy["mounts"],
            "no-host-mounts;exact-lima-cidata-allowed",
        )

    def test_timeout_is_durably_classified_and_same_action_retry_is_rejected(self) -> None:
        argv = (
            "limactl",
            "--tty=false",
            "create",
            "--name=outer-loop-week0-codex",
        )
        with patch.object(
            self.driver.runner,
            "run",
            side_effect=BoundedCommandError("limactl", "TIMEOUT"),
        ), self.assertRaises(BoundedCommandError):
            self.driver._provision_attempt(
                "run-0001",
                "codex",
                "create",
                argv,
                expected_status="Stopped",
            )
        records = [
            json.loads(line)
            for line in (self.paths.evidence / "provision-attempts.jsonl")
            .read_text()
            .splitlines()
        ]
        self.assertEqual(records[-1]["outcome"], "TIMEOUT")
        with patch.object(self.driver.runner, "run") as runner, self.assertRaisesRegex(
            ContractError, "retry rejected"
        ):
            self.driver._provision_attempt(
                "run-0001",
                "codex",
                "create",
                argv,
                expected_status="Stopped",
            )
        runner.assert_not_called()


class HandoffDriverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        pool = self.root / "pool"
        pool.mkdir(mode=0o700)
        self.paths = RunPaths.for_run("run-0001", self.root / "state", pool)
        self.paths.create()
        self.bundle = self.paths.fixture_bundles / "forward"
        self.bundle.mkdir()
        self.manifest = self.bundle / "bundle-manifest.json"
        self.manifest.write_text('{"schema_version":1,"frozen_inventory":[]}')
        self.expected_digest = hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.driver = LimaDriver(self.paths, HARNESS)

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
            value = {
                "name": argv[-1],
                "status": driver_status.title(),
                "dir": str(self.paths.lima_home / argv[-1]),
                "vmType": "vz",
                "arch": "aarch64",
                "cpus": 4,
                "memory": 8589934592,
                "disk": 42949672960,
            }
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(value) + "\n", stderr="")
        if "--all-fields" in argv:
            value = {
                "name": argv[-1],
                "status": "Running",
                "dir": str(self.paths.lima_home / argv[-1]),
                "vmType": "vz",
                "arch": "aarch64",
                "cpus": 4,
                "memory": 8589934592,
                "disk": 42949672960,
            }
            return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(value) + "\n", stderr="")
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
