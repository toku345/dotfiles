from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.identities import (  # noqa: E402
    EffectiveValue,
    compare_effective_seed,
    sha256_file,
    validate_manifest,
    validate_versions_lock,
)
from lib.model import ContractError  # noqa: E402


class IdentityTests(unittest.TestCase):
    def test_repository_versions_lock_is_valid(self) -> None:
        lock = validate_versions_lock(HARNESS / "versions.lock.json")
        self.assertEqual(lock["schema_version"], 1)
        self.assertEqual(lock["artifacts"]["sandbox_runtime"]["version"], "0.0.65")

    def test_provisioned_remote_artifacts_are_all_lock_sources(self) -> None:
        lock = validate_versions_lock(HARNESS / "versions.lock.json")
        locked_sources = {artifact["source"] for artifact in lock["artifacts"].values()}
        locked_sources.add(lock["guest_apt"]["snapshot"])
        provisioned_sources: set[str] = set()
        for script in (HARNESS / "guest").glob("provision-*.sh"):
            provisioned_sources.update(
                re.findall(r"https://[^'\s]+", script.read_text(encoding="utf-8"))
            )
        self.assertEqual(sorted(provisioned_sources.difference(locked_sources)), [])

    def test_repository_manifest_is_complete(self) -> None:
        manifest = validate_manifest(HARNESS)
        self.assertGreater(len(manifest["files"]), 30)
        self.assertIn("lib/lima_state.py", {record["path"] for record in manifest["files"]})

    def test_cli_init_does_not_write_bytecode_into_harness(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            tempfile.TemporaryDirectory(prefix="ol-", dir="/private/tmp") as pool_temporary,
        ):
            root = Path(temporary).resolve()
            harness = root / "harness"
            shutil.copytree(
                HARNESS,
                harness,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )
            environment = os.environ.copy()
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            environment.pop("PYTHONPYCACHEPREFIX", None)
            pool = Path(pool_temporary)

            result = subprocess.run(
                [
                    sys.executable,
                    str(harness / "calibrate.py"),
                    "--state-root",
                    str(root / "state"),
                    "--lima-pool-root",
                    str(pool),
                    "init",
                    "run-0001",
                    "--retention-deadline",
                    "2030-01-02T00:00:00Z",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(harness.rglob("*.pyc")), [])
            self.assertEqual(list(harness.rglob("__pycache__")), [])
            validate_manifest(harness)

    def test_lock_rejects_artifact_without_integrity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifacts": {"floating": {"version": "1", "source": "https://invalid"}},
                    }
                )
            )
            with self.assertRaisesRegex(ContractError, "independent integrity"):
                validate_versions_lock(path)

    def test_manifest_rejects_missing_extra_and_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "payload.txt"
            payload.write_text("fixed")
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "files": [{"path": "payload.txt", "sha256": sha256_file(payload)}],
                    }
                )
            )
            validate_manifest(root)
            extra = root / "extra.txt"
            extra.write_text("extra")
            with self.assertRaisesRegex(ContractError, "extra"):
                validate_manifest(root)
            extra.unlink()
            payload.write_text("drift")
            with self.assertRaisesRegex(ContractError, "drifted"):
                validate_manifest(root)
            payload.unlink()
            with self.assertRaisesRegex(ContractError, "missing"):
                validate_manifest(root)

    def test_hash_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.write_text("value")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaises((ContractError, OSError)):
                sha256_file(link)

    def test_effective_seed_requires_all_values_and_origins(self) -> None:
        expected = {"sandbox_mode": "workspace-write", "web_search": "disabled"}
        observed = {
            key: EffectiveValue(value, "system:/etc/codex/config.toml")
            for key, value in expected.items()
        }
        compare_effective_seed(expected, observed, expected_origin="system:/etc/codex/config.toml")
        observed["web_search"] = EffectiveValue("live", "cloud")
        with self.assertRaisesRegex(ContractError, "values=.*web_search.*origins"):
            compare_effective_seed(expected, observed, expected_origin="system:/etc/codex/config.toml")


if __name__ == "__main__":
    unittest.main()
