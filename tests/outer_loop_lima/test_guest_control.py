from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
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
    def test_receipt_binds_nonce_destination_argv_and_denial(self) -> None:
        control = load_guest_control()
        nonce = "a" * 32
        argv = ["probe", "host.lima.internal", "443"]
        completed = subprocess.CompletedProcess(
            argv,
            77,
            stdout="",
            stderr="operation not permitted",
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (
                patch.object(control, "RECEIPT_ROOT", root),
                patch.object(control.subprocess, "run", return_value=completed),
                patch.object(
                    control.sys,
                    "argv",
                    ["control.py", "--nonce", nonce, "--destination", "host", "--", *argv],
                ),
            ):
                self.assertEqual(control.main(), 77)
            started = json.loads((root / f"{nonce}.started.json").read_text())
            complete = json.loads((root / f"{nonce}.complete.json").read_text())
        expected_digest = hashlib.sha256(control.canonical(argv)).hexdigest()
        self.assertEqual(started["classification"], "STARTED")
        self.assertEqual(complete["classification"], "DENIED_BY_SANDBOX")
        self.assertEqual(complete["nonce"], nonce)
        self.assertEqual(complete["destination"], "host")
        self.assertEqual(complete["argv_digest"], expected_digest)
        self.assertEqual(complete["exit_classification"], "NONZERO")

    def test_timeout_still_writes_terminal_receipt(self) -> None:
        control = load_guest_control()
        nonce = "b" * 32
        argv = ["probe", "203.0.113.10", "443"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (
                patch.object(control, "RECEIPT_ROOT", root),
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
            ):
                self.assertEqual(control.main(), 124)
            complete = json.loads((root / f"{nonce}.complete.json").read_text())
        self.assertEqual(complete["classification"], "COMMAND_TIMEOUT")
        self.assertEqual(complete["exit_classification"], "NONZERO")


if __name__ == "__main__":
    unittest.main()
