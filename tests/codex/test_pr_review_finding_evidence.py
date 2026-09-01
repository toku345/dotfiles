#!/usr/bin/env python3
"""Behavioral tests for immutable finding-verifier evidence validation."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR_PATH = (
    REPO_ROOT
    / "private_dot_codex"
    / "skills"
    / "pr-review"
    / "scripts"
    / "validate_finding_evidence.py"
)
SPEC = importlib.util.spec_from_file_location("validate_finding_evidence", VALIDATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise AssertionError(f"could not load {VALIDATOR_PATH}")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class FindingEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="pr-review-evidence-")
        self.repo = pathlib.Path(self.tempdir.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Evidence Test")
        self.git("config", "user.email", "evidence@example.invalid")
        self.git("config", "commit.gpgsign", "false")

        (self.repo / "source.txt").write_text("alpha\nbeta\n", encoding="utf-8")
        (self.repo / "single.txt").write_text("single", encoding="utf-8")
        (self.repo / "empty.txt").write_bytes(b"")
        (self.repo / "binary.bin").write_bytes(b"binary\0payload\n")
        executable = self.repo / "tool.sh"
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        (self.repo / "nested").mkdir()
        (self.repo / "nested" / "file.txt").write_text("nested\n", encoding="utf-8")
        os.symlink("source.txt", self.repo / "source-link.txt")
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", "fixture")
        self.head_ref = self.git("rev-parse", "HEAD").stdout.strip()

        # These changes prove validation reads the immutable tree, not the worktree.
        (self.repo / "source.txt").write_text(
            "".join(f"line {index}\n" for index in range(1, 101)),
            encoding="utf-8",
        )
        (self.repo / "worktree-only.txt").write_text("local\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    @staticmethod
    def result(*evidence: dict) -> dict:
        return {
            "candidate_id": "f001",
            "verdict": "refuted",
            "summary": "Evidence-based disposition.",
            "evidence": list(evidence),
            "missingVerification": [],
        }

    @staticmethod
    def evidence(path: str, line: int | str) -> dict:
        return {
            "path": path,
            "line": line,
            "observation": "The immutable blob proves the claim.",
        }

    def validate(self, *evidence: dict) -> int:
        return VALIDATOR.validate_evidence(
            self.repo,
            self.head_ref,
            self.result(*evidence),
        )

    def test_accepts_regular_text_blob_lines_and_ranges(self) -> None:
        self.assertEqual(
            self.validate(
                self.evidence("source.txt", 2),
                self.evidence("source.txt", "1-2"),
                self.evidence("single.txt", 1),
                self.evidence("tool.sh", "1-2"),
            ),
            4,
        )

    def test_rejects_missing_and_worktree_only_paths(self) -> None:
        for path in ("does/not/exist.txt", "worktree-only.txt"):
            with self.subTest(path=path), self.assertRaisesRegex(
                VALIDATOR.EvidenceValidationError,
                "absent from HEAD_REF",
            ):
                self.validate(self.evidence(path, 1))

    def test_rejects_lines_outside_the_immutable_blob(self) -> None:
        for line in (3, "1-3", 100):
            with self.subTest(line=line), self.assertRaisesRegex(
                VALIDATOR.EvidenceValidationError,
                "exceeds the immutable blob",
            ):
                self.validate(self.evidence("source.txt", line))
        with self.assertRaisesRegex(
            VALIDATOR.EvidenceValidationError,
            "exceeds the immutable blob",
        ):
            self.validate(self.evidence("empty.txt", 1))

    def test_rejects_nonregular_binary_and_control_character_paths(self) -> None:
        invalid = (
            (self.evidence("source-link.txt", 1), "not a tracked regular file"),
            (self.evidence("nested", 1), "not a tracked regular file"),
            (self.evidence("binary.bin", 1), "not a text file"),
            (self.evidence("source.txt\nignored", 1), "safe repository path"),
        )
        for evidence, expected in invalid:
            with self.subTest(evidence=evidence), self.assertRaisesRegex(
                VALIDATOR.EvidenceValidationError,
                expected,
            ):
                self.validate(evidence)

    def test_cli_reports_exact_success_and_fails_closed(self) -> None:
        result_file = self.repo / "result.json"
        result_file.write_text(
            json.dumps(self.result(self.evidence("source.txt", 2))),
            encoding="utf-8",
        )
        command = [
            sys.executable,
            str(VALIDATOR_PATH),
            "--repo-root",
            str(self.repo),
            "--head-ref",
            self.head_ref,
            "--result-file",
            str(result_file),
        ]
        success = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(
            success.stdout.strip(),
            f"EVIDENCE_OK finding-verifier f001 {self.head_ref} 1",
        )

        result_file.write_text(
            json.dumps(self.result(self.evidence("source.txt", 3))),
            encoding="utf-8",
        )
        failure = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(failure.returncode, 1)
        self.assertFalse(failure.stdout)
        self.assertIn("EVIDENCE_INVALID finding-verifier", failure.stderr)


if __name__ == "__main__":
    unittest.main()
