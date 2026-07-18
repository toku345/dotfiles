from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.export_validator import (  # noqa: E402
    copy_preserving_nodes,
    freeze_bundle,
    stable_inventory,
    validate_quarantine,
)
from lib.model import ContractError  # noqa: E402
from lib.sync_guard import validate_sync_invocation  # noqa: E402


class SyncGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.registered = self.root / "registered"
        self.registered.mkdir(mode=0o700)
        os.chmod(self.registered, 0o700)
        self.staging = self.registered / "staging"
        self.staging.mkdir(mode=0o700)
        os.chmod(self.staging, 0o700)
        self.authoritative = self.root / "repo"
        self.authoritative.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def validate(self, argv=("limactl", "shell", "--sync=staging"), **overrides):
        values = {
            "registered_roots": (self.registered,),
            "authoritative_roots": (self.authoritative,),
            "stdin_isatty": True,
            "stdout_isatty": True,
        }
        values.update(overrides)
        return validate_sync_invocation(argv, self.staging, **values)

    def test_valid_operator_staging_passes(self) -> None:
        guarded = self.validate()
        self.assertEqual(guarded.staging, self.staging.resolve())

    def test_non_tty_and_automation_flags_are_rejected(self) -> None:
        with self.assertRaisesRegex(ContractError, "TTY"):
            self.validate(stdin_isatty=False)
        for flag in ("-y", "--yes", "--tty=false", "--tty=0"):
            with self.assertRaisesRegex(ContractError, "forbidden"):
                self.validate(("limactl", flag, "shell"))

    def test_symlink_unregistered_and_repository_targets_are_rejected(self) -> None:
        link = self.registered / "link"
        link.symlink_to(self.staging, target_is_directory=True)
        with self.assertRaisesRegex(ContractError, "symlink"):
            validate_sync_invocation(
                ("limactl", "shell"),
                link,
                registered_roots=(self.registered,),
                authoritative_roots=(self.authoritative,),
                stdin_isatty=True,
                stdout_isatty=True,
            )
        with self.assertRaisesRegex(ContractError, "exactly one"):
            self.validate(registered_roots=())
        os.chmod(self.authoritative, 0o700)
        with self.assertRaisesRegex(ContractError, "overlap"):
            validate_sync_invocation(
                ("limactl", "shell"),
                self.authoritative,
                registered_roots=(self.authoritative,),
                authoritative_roots=(self.authoritative,),
                stdin_isatty=True,
                stdout_isatty=True,
            )


class ExportTests(unittest.TestCase):
    def make_source(self, root: Path) -> Path:
        source = root / "source"
        source.mkdir(mode=0o700)
        file = source / "safe.txt"
        file.write_text("safe content\n")
        os.chmod(file, 0o644)
        nested = source / "nested"
        nested.mkdir(mode=0o750)
        item = nested / "item.txt"
        item.write_text("nested\n")
        os.chmod(item, 0o600)
        return source

    def test_positive_quarantine_preserves_modes_and_freezes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)
            quarantine = root / "quarantine"
            inventory = validate_quarantine(source, quarantine)
            self.assertEqual(stable_inventory(source), stable_inventory(quarantine))
            frozen = root / "frozen"
            digest = freeze_bundle(quarantine, frozen, inventory)
            self.assertEqual(len(digest), 64)
            self.assertEqual(stat.S_IMODE(frozen.stat().st_mode), 0o500)
            self.assertEqual(stat.S_IMODE((frozen / "safe.txt").stat().st_mode), 0o400)
            self.assertTrue((frozen / "bundle-manifest.json").is_file())

    def test_link_hardlink_secret_mode_and_special_nodes_are_rejected(self) -> None:
        cases = ("symlink", "hardlink", "secret", "mode", "fifo")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = self.make_source(root)
                if case == "symlink":
                    (source / "link").symlink_to("safe.txt")
                elif case == "hardlink":
                    os.link(source / "safe.txt", source / "hard")
                elif case == "secret":
                    (source / ".env").write_text("token=supersecretvalue\n")
                elif case == "mode":
                    os.chmod(source / "safe.txt", 0o666)
                else:
                    os.mkfifo(source / "pipe")
                with self.assertRaises(ContractError):
                    validate_quarantine(source, root / "quarantine")

    def test_inventory_race_and_silent_drop_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)
            with self.assertRaisesRegex(ContractError, "changed between"):
                stable_inventory(source, between=lambda: (source / "safe.txt").write_text("changed"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self.make_source(root)

            def silent_drop(_source: Path, destination: Path) -> None:
                destination.mkdir(mode=0o700)

            with patch("lib.export_validator.copy_preserving_nodes", side_effect=silent_drop):
                with self.assertRaisesRegex(ContractError, "differ"):
                    validate_quarantine(source, root / "quarantine")


if __name__ == "__main__":
    unittest.main()
