from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
SHORT_TEMP_ROOT = Path("/tmp").resolve()
sys.path.insert(0, str(HARNESS))

from lib.lima_state import (  # noqa: E402
    CLAUDE_INSTANCE,
    CODEX_INSTANCE,
    inspect_top_level,
    parse_lima_list,
    path_disposition,
    validate_expected_identity,
)
from lib.model import ContractError, LimaListDisposition  # noqa: E402
from lib.paths import RunPaths, derive_lima_home_token  # noqa: E402


WARNING = (
    'time="2026-07-18T22:09:00+09:00" level=warning '
    'msg="No instance found. Run `limactl create` to create an instance."'
)
WARNING_Z = (
    'time="2026-07-18T13:09:00Z" level=warning '
    'msg="No instance found. Run `limactl create` to create an instance."'
)
WARNING_WITHOUT_TIMESTAMP = (
    'level=warning msg="No instance found. Run `limactl create` to create an instance."'
)


def identity(name: str, directory: str, *, status: str = "Stopped") -> dict[str, object]:
    return {
        "name": name,
        "status": status,
        "dir": directory,
        "vmType": "vz",
        "arch": "aarch64",
        "cpus": 4,
        "memory": 8589934592,
        "disk": 42949672960,
    }


class LimaListParserTests(unittest.TestCase):
    def test_canonical_warning_with_offset_or_z_is_absent(self) -> None:
        for warning in (WARNING, WARNING_Z):
            with self.subTest(warning=warning):
                snapshot = parse_lima_list(0, "", warning)
                self.assertEqual(snapshot.disposition, LimaListDisposition.ABSENT)
                self.assertEqual(snapshot.record_count, 0)

    def test_unpinned_no_instance_warning_variants_are_unknown(self) -> None:
        variants = (
            WARNING_WITHOUT_TIMESTAMP,
            'level=warning msg="No instance found for current filter."',
            WARNING + "\nlevel=error msg=unexpected",
            f"unexpected-prefix {WARNING_WITHOUT_TIMESTAMP}",
            f'time="not-a-timestamp" {WARNING_WITHOUT_TIMESTAMP}',
            f'time="2026-07-18T22:09:00" {WARNING_WITHOUT_TIMESTAMP}',
            f'time="2026-07-18 22:09:00+09:00" {WARNING_WITHOUT_TIMESTAMP}',
        )
        for warning in variants:
            with self.subTest(warning=warning):
                self.assertEqual(
                    parse_lima_list(0, "", warning).disposition,
                    LimaListDisposition.UNKNOWN,
                )

    def test_one_and_multiple_json_lines_are_recognized(self) -> None:
        codex = identity(CODEX_INSTANCE, "/private/tmp/ol/codex")
        claude = identity(CLAUDE_INSTANCE, "/private/tmp/ol/claude", status="Running")
        one = parse_lima_list(0, json.dumps(codex) + "\n", "")
        multiple = parse_lima_list(
            0,
            json.dumps(codex) + "\n" + json.dumps(claude) + "\n",
            "",
        )
        self.assertEqual(one.disposition, LimaListDisposition.RECOGNIZED)
        self.assertEqual([item.name for item in multiple.identities], [CODEX_INSTANCE, CLAUDE_INSTANCE])

    def test_arrays_malformed_mixed_stderr_duplicate_and_bool_are_unknown(self) -> None:
        record = identity(CODEX_INSTANCE, "/private/tmp/ol/codex")
        bool_record = dict(record, cpus=True)
        cases = (
            (0, json.dumps([record]), ""),
            (0, "{", ""),
            (0, json.dumps(record), "extra warning"),
            (0, json.dumps(record) + "\n" + json.dumps(record), ""),
            (0, json.dumps(bool_record), ""),
            (9, "", WARNING),
            (0, "", WARNING + "\nextra"),
        )
        for returncode, stdout, stderr in cases:
            with self.subTest(stdout=stdout, stderr=stderr):
                self.assertEqual(
                    parse_lima_list(returncode, stdout, stderr).disposition,
                    LimaListDisposition.UNKNOWN,
                )

    def test_expected_identity_requires_exact_path_status_and_resources(self) -> None:
        expected_dir = Path("/private/tmp/ol/codex")
        snapshot = parse_lima_list(
            0,
            json.dumps(identity(CODEX_INSTANCE, str(expected_dir), status="Running")),
            "",
        )
        validate_expected_identity(
            snapshot.identities[0],
            name=CODEX_INSTANCE,
            status="Running",
            directory=expected_dir,
        )
        with self.assertRaisesRegex(ContractError, "frozen contract"):
            validate_expected_identity(
                snapshot.identities[0],
                name=CODEX_INSTANCE,
                status="Stopped",
                directory=expected_dir,
            )


class LimaHomeTests(unittest.TestCase):
    def test_top_level_is_no_follow_and_strict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / "_cache").mkdir()
            (home / CODEX_INSTANCE).mkdir()
            clean = inspect_top_level(home)
            self.assertEqual(clean.disposition, "CLEAN")
            self.assertEqual(clean.fixed_directories, (CODEX_INSTANCE,))
            (home / "unknown").mkdir()
            self.assertEqual(inspect_top_level(home).disposition, "UNKNOWN")
            (home / "unknown").rmdir()
            (home / "link").symlink_to(home / CODEX_INSTANCE)
            self.assertEqual(inspect_top_level(home).disposition, "UNKNOWN")

    def test_path_disposition_counts_broken_symlink_as_present(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            missing = root / "missing"
            self.assertEqual(path_disposition(missing), "ABSENT")
            missing.symlink_to(root / "does-not-exist")
            self.assertEqual(path_disposition(missing), "PRESENT")

    def test_token_is_deterministic_and_fixed_length(self) -> None:
        first = derive_lima_home_token(Path("/private/state"), "run-0001")
        second = derive_lima_home_token(Path("/private/state"), "run-0001")
        self.assertEqual(first, second)
        self.assertEqual(len(first), 10)
        self.assertNotEqual(first, derive_lima_home_token(Path("/private/state"), "run-0002"))

    def test_socket_budget_uses_bytes_and_enforces_internal_95_limit(self) -> None:
        private_mac = RunPaths.for_run(
            "run-0001",
            Path("/private/state"),
            Path("/Users/toku345/.local/state/ol"),
        )
        self.assertEqual(
            private_mac.socket_path_lengths((CODEX_INSTANCE, CLAUDE_INSTANCE)),
            {CODEX_INSTANCE: 90, CLAUDE_INSTANCE: 91},
        )
        pool_95 = Path("/" + "a" * 33)
        pool_96 = Path("/" + "a" * 34)
        RunPaths.for_run("run-0001", Path("/state"), pool_95).validate_socket_budget(
            (CLAUDE_INSTANCE,)
        )
        with self.assertRaisesRegex(ContractError, "budget exceeded"):
            RunPaths.for_run("run-0001", Path("/state"), pool_96).validate_socket_budget(
                (CLAUDE_INSTANCE,)
            )
        non_ascii = RunPaths.for_run("run-0001", Path("/state"), Path("/private/tmp/あ"))
        self.assertEqual(
            non_ascii.socket_path_lengths((CLAUDE_INSTANCE,))[CLAUDE_INSTANCE],
            len(os.fsencode(non_ascii.lima_home / CLAUDE_INSTANCE / "ssh.sock.1234567890123456")),
        )

    def test_custom_state_requires_explicit_pool_and_allocation_is_write_once(self) -> None:
        with self.assertRaisesRegex(ContractError, "explicit Lima pool"):
            RunPaths.for_run("run-0001", Path("/private/custom"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            pool = root / "pool"
            pool.mkdir(mode=0o700)
            paths = RunPaths.for_run("run-0001", root / "state", pool)
            binding = paths.create(instance_names=())
            self.assertEqual(binding.token, paths.lima_home_token)
            self.assertTrue(paths.binding_registry.is_file())
            with self.assertRaisesRegex(ContractError, "already allocated"):
                RunPaths.for_run("run-0001", root / "state", pool).create(
                    instance_names=()
                )

    def test_relative_and_symlinked_roots_are_rejected(self) -> None:
        with self.assertRaisesRegex(ContractError, "absolute"):
            RunPaths.for_run("run-0001", Path("relative-state"), Path("/private/tmp/pool"))
        with tempfile.TemporaryDirectory(dir=SHORT_TEMP_ROOT) as temporary:
            root = Path(temporary)
            real = root / "real"
            real.mkdir()
            alias = root / "alias"
            alias.symlink_to(real, target_is_directory=True)
            with self.assertRaisesRegex(ContractError, "symlink ancestor"):
                RunPaths.for_run("run-0001", alias / "state", root / "pool")


if __name__ == "__main__":
    unittest.main()
