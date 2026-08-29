#!/usr/bin/env python3
"""Validate the immutable observational baseline for finding verification."""

from __future__ import annotations

import json
import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE_PATH = (
    REPO_ROOT
    / "tests"
    / "codex"
    / "fixtures"
    / "pr_review_finding_verifier_baseline_v1.json"
)
OID_RE = re.compile(r"[0-9a-f]{40}\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
EXPECTED_PAIRS = {
    "pr304-week0-v2-supersession": {
        "source_pr": 304,
        "base_commit": "9f534c6d943bf0d3e1e7edb1da11765d9b6e3ba0",
        "merge_base": "769279caaa9de6bbd9c60092e76f145672b30fc2",
        "root_id": "week0_v2_supersession_notice",
        "heads": {
            "buggy": "da8bd6a8f9faa841b29ff2362a60b871d33a0ffa",
            "fixed": "b94eb436d5cbee635a133212d83510c73a45acee",
        },
    },
    "pr330-stop-hook-state-order": {
        "source_pr": 330,
        "base_commit": "e0493e9819e6db39c37c33c0051422c67b522d2a",
        "merge_base": "04d16ea1a4a7011e8103c2847b42a2efceaae11c",
        "root_id": "executing_gate_survives_reminder_persist_failure",
        "heads": {
            "buggy": "f0240bc38310f7772f7c6685f204f68c80c1c963",
            "fixed": "740d5d5219a302233b5f2d1ffce5269adfd5b054",
        },
    },
    "pr269-codex-hook-test-coverage": {
        "source_pr": 269,
        "base_commit": "51821bfea5f02d7b666af500cc5bda5e4b7744b2",
        "merge_base": "51821bfea5f02d7b666af500cc5bda5e4b7744b2",
        "root_id": "codex_hook_and_managed_rules_test_coverage",
        "heads": {
            "buggy": "d02740d1a7adac24421d15485e49e4d1050a5660",
            "fixed": "3dd546f5299b5689556158b11286b1557327a607",
        },
    },
}


class FindingVerifierBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))

    def test_schema_and_observational_policy_are_pinned(self) -> None:
        self.assertEqual(
            self.fixture["sentinel"], "PR_REVIEW_FINDING_VERIFIER_BASELINE_V1"
        )
        self.assertEqual(self.fixture["version"], 1)
        self.assertEqual(self.fixture["policy"]["attempts_per_case"], 1)
        self.assertIsNone(self.fixture["policy"]["hard_recall_threshold"])
        self.assertIsNone(self.fixture["policy"]["aborted_case_oracle_result"])
        self.assertIsNone(self.fixture["runner"]["model_id"])
        self.assertEqual(
            self.fixture["runner"]["model_identity_status"], "unverified"
        )

    def test_exact_historical_pairs_and_oids_are_pinned(self) -> None:
        pairs = {pair["pair_id"]: pair for pair in self.fixture["pairs"]}
        self.assertEqual(set(pairs), set(EXPECTED_PAIRS))
        for pair_id, expected in EXPECTED_PAIRS.items():
            with self.subTest(pair_id=pair_id):
                pair = pairs[pair_id]
                self.assertEqual(pair["source_pr"], expected["source_pr"])
                self.assertEqual(pair["base_commit"], expected["base_commit"])
                self.assertEqual(pair["merge_base"], expected["merge_base"])
                self.assertEqual(pair["oracle"]["root_id"], expected["root_id"])
                self.assertRegex(pair["base_commit"], OID_RE)
                self.assertRegex(pair["merge_base"], OID_RE)
                cases = {case["variant"]: case for case in pair["cases"]}
                self.assertEqual(set(cases), {"buggy", "fixed"})
                for variant, expected_head in expected["heads"].items():
                    case = cases[variant]
                    self.assertEqual(case["head_commit"], expected_head)
                    self.assertRegex(case["head_commit"], OID_RE)
                    self.assertGreater(case["packet_bytes"], 0)
                    self.assertRegex(case["packet_sha256"], SHA256_RE)

    def test_completed_buggy_cases_detect_each_known_root(self) -> None:
        for pair in self.fixture["pairs"]:
            cases = {case["variant"]: case for case in pair["cases"]}
            buggy = cases["buggy"]
            with self.subTest(pair_id=pair["pair_id"]):
                self.assertEqual(buggy["status"], "gate_complete")
                self.assertTrue(pair["oracle"]["expected_buggy"])
                self.assertTrue(buggy["oracle_detected"])

    def test_fixed_results_distinguish_absence_from_aborted_evaluation(self) -> None:
        allowed_statuses = {
            "gate_complete",
            "coverage_aborted",
            "environment_aborted",
        }
        for pair in self.fixture["pairs"]:
            cases = {case["variant"]: case for case in pair["cases"]}
            fixed = cases["fixed"]
            with self.subTest(pair_id=pair["pair_id"]):
                self.assertFalse(pair["oracle"]["expected_fixed"])
                self.assertIn(fixed["status"], allowed_statuses)
                if fixed["status"] == "gate_complete":
                    self.assertFalse(fixed["oracle_detected"])
                    self.assertIsInstance(fixed["counts"], dict)
                else:
                    self.assertIsNone(fixed["oracle_detected"])
                    self.assertIsNone(fixed["counts"])


if __name__ == "__main__":
    unittest.main()
