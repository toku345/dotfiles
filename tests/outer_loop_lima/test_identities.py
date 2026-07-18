from __future__ import annotations

import hashlib
import json
import os
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

    def test_repository_manifest_is_complete(self) -> None:
        manifest = validate_manifest(HARNESS)
        self.assertGreater(len(manifest["files"]), 30)

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
