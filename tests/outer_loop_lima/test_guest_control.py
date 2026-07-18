from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import subprocess
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"


def load_guest_control():
    path = HARNESS / "guest" / "control.py"
    spec = importlib.util.spec_from_file_location("outer_loop_guest_control", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load guest control wrapper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GuestControlTests(unittest.TestCase):
    @staticmethod
    def receipts(control, output: str) -> tuple[dict[str, object], dict[str, object]]:
        lines = output.splitlines()
        started = [
            json.loads(line.removeprefix(control.STARTED_PREFIX))
            for line in lines
            if line.startswith(control.STARTED_PREFIX)
        ]
        complete = [
            json.loads(line.removeprefix(control.COMPLETE_PREFIX))
            for line in lines
            if line.startswith(control.COMPLETE_PREFIX)
        ]
        if len(started) != 1 or len(complete) != 1:
            raise AssertionError("wrapper did not emit exactly one receipt pair")
        return started[0], complete[0]

    def test_receipt_binds_nonce_destination_argv_and_denial(self) -> None:
        control = load_guest_control()
        nonce = "a" * 32
        argv = ["probe", "host.lima.internal", "443"]
        completed = subprocess.CompletedProcess(
            argv,
            control.NETWORK_DENIED_EXIT,
            stdout="",
            stderr=control.NETWORK_DENIED_MARKER + "\n",
        )
        output = io.StringIO()
        with (
            patch.object(control.subprocess, "run", return_value=completed),
            patch.object(
                control.sys,
                "argv",
                ["control.py", "--nonce", nonce, "--destination", "host", "--", *argv],
            ),
            redirect_stdout(output),
        ):
            self.assertEqual(control.main(), 77)
        started, complete = self.receipts(control, output.getvalue())
        expected_digest = hashlib.sha256(
            control.canonical(
                [
                    "/usr/local/libexec/outer-loop/control.py",
                    "--nonce",
                    nonce,
                    "--destination",
                    "host",
                    "--",
                    *argv,
                ]
            )
        ).hexdigest()
        self.assertEqual(started["classification"], "STARTED")
        self.assertEqual(complete["classification"], "DENIED_BY_SANDBOX")
        self.assertEqual(complete["nonce"], nonce)
        self.assertEqual(complete["destination"], "host")
        self.assertEqual(complete["argv_digest"], expected_digest)
        self.assertEqual(complete["exit_classification"], "NONZERO")

    def test_generic_stderr_never_becomes_sandbox_denial(self) -> None:
        control = load_guest_control()
        for returncode, stderr in (
            (1, "operation not permitted"),
            (1, "permission denied opening an unrelated local file"),
            (control.NETWORK_DENIED_EXIT, "permission denied"),
        ):
            with self.subTest(returncode=returncode, stderr=stderr):
                self.assertEqual(
                    control.classify(returncode, stderr),
                    "COMMAND_FAILED_AMBIGUOUS",
                )

    def test_timeout_still_emits_terminal_receipt(self) -> None:
        control = load_guest_control()
        nonce = "b" * 32
        argv = ["probe", "203.0.113.10", "443"]
        output = io.StringIO()
        with (
            patch.object(
                control.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired(argv, 30),
            ),
            patch.object(
                control.sys,
                "argv",
                ["control.py", "--nonce", nonce, "--destination", "public", "--", *argv],
            ),
            redirect_stdout(output),
        ):
            self.assertEqual(control.main(), 124)
        _, complete = self.receipts(control, output.getvalue())
        self.assertEqual(complete["classification"], "COMMAND_TIMEOUT")
        self.assertEqual(complete["exit_classification"], "NONZERO")

    def test_wrapper_has_no_runtime_writable_receipt_file_channel(self) -> None:
        control = load_guest_control()
        self.assertFalse(hasattr(control, "RECEIPT_ROOT"))
        self.assertNotIn("/run/outer-loop-probe", (HARNESS / "guest" / "control.py").read_text())


if __name__ == "__main__":
    unittest.main()
