#!/usr/bin/env python3
"""Validate the sanitized one-shot post-change finding-verifier comparison."""

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
    / "pr_review_finding_verifier_post_v1.json"
)
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
THREAD_RE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
EXPECTED_CASES = {
    ("pr304-week0-v2-supersession", "buggy"): "gate_complete",
    ("pr304-week0-v2-supersession", "fixed"): "coverage_aborted",
    ("pr330-stop-hook-state-order", "buggy"): "gate_complete",
    ("pr330-stop-hook-state-order", "fixed"): "gate_complete",
    ("pr269-codex-hook-test-coverage", "buggy"): "environment_aborted",
    ("pr269-codex-hook-test-coverage", "fixed"): "gate_complete",
}
USAGE_FIELDS = {
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
}
EXPECTED_ARTIFACTS = {
    "skill_sha256": "5dc2fd5417230d36317cb601fab0c612e4927f375a262d1378b7fd848ceae3e9",
    "agent_sha256": "d0feb56f9c19af7d4ed1421dce87130e446c22a564d80982f6f340baadee1e62",
    "contract_sha256": "5016560e23d570eca12ca836beeb8db45e9ae67f7d2efa29037adf2eca42b30d",
}


class FindingVerifierComparisonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))

    def test_schema_policy_and_candidate_identity_are_pinned(self) -> None:
        self.assertEqual(
            self.fixture["sentinel"], "PR_REVIEW_FINDING_VERIFIER_POST_V1"
        )
        self.assertEqual(self.fixture["version"], 1)
        self.assertEqual(self.fixture["policy"]["attempts_per_case"], 1)
        self.assertEqual(self.fixture["policy"]["retries"], 0)
        self.assertIsNone(self.fixture["policy"]["hard_recall_threshold"])
        self.assertIsNone(self.fixture["policy"]["aborted_case_oracle_result"])
        self.assertIsNone(self.fixture["runner"]["model_id"])
        self.assertEqual(
            self.fixture["runner"]["model_identity_status"], "unverified"
        )
        self.assertRegex(
            self.fixture["runner"]["implementation_commit"], re.compile(r"[0-9a-f]{40}\Z")
        )
        self.assertEqual(
            self.fixture["runner"]["candidate_artifacts"], EXPECTED_ARTIFACTS
        )
        for digest in EXPECTED_ARTIFACTS.values():
            self.assertRegex(digest, SHA256_RE)

    def test_exact_one_shot_case_matrix_is_retained(self) -> None:
        cases = {
            (case["pair_id"], case["variant"]): case
            for case in self.fixture["cases"]
        }
        self.assertEqual(set(cases), set(EXPECTED_CASES))
        for case_key, expected_status in EXPECTED_CASES.items():
            with self.subTest(case=case_key):
                case = cases[case_key]
                self.assertEqual(case["status"], expected_status)
                self.assertRegex(case["thread_id"], THREAD_RE)
                self.assertEqual(set(case["usage"]), USAGE_FIELDS)
                self.assertTrue(all(value >= 0 for value in case["usage"].values()))
                if expected_status == "gate_complete":
                    self.assertIsInstance(case["oracle_detected"], bool)
                    self.assertIsInstance(case["counts"], dict)
                    self.assertIsInstance(case["verifier"], dict)
                else:
                    self.assertIsNone(case["oracle_detected"])
                    self.assertIsNone(case["counts"])
                    self.assertIsNone(case["verifier"])

    def test_verifier_and_usage_aggregates_match_completed_cases(self) -> None:
        completed = [
            case for case in self.fixture["cases"] if case["status"] == "gate_complete"
        ]
        aggregate = self.fixture["aggregate"]
        self.assertEqual(aggregate["gate_complete"], len(completed))
        for field in ("verifier_candidates", "confirmed", "needs_verification", "refuted"):
            case_field = "candidates" if field == "verifier_candidates" else field
            self.assertEqual(
                aggregate[field],
                sum(case["verifier"][case_field] for case in completed),
            )
        for case in completed:
            verifier = case["verifier"]
            self.assertEqual(
                verifier["candidates"],
                verifier["confirmed"]
                + verifier["needs_verification"]
                + verifier["refuted"],
            )
        for field in USAGE_FIELDS:
            self.assertEqual(
                aggregate["usage"][field],
                sum(case["usage"][field] for case in self.fixture["cases"]),
            )

    def test_aborts_are_unscored_and_recall_claim_remains_observational(self) -> None:
        evaluable_buggy = [
            case
            for case in self.fixture["cases"]
            if case["variant"] == "buggy" and case["status"] == "gate_complete"
        ]
        aggregate = self.fixture["aggregate"]
        self.assertEqual(aggregate["evaluable_buggy_oracles"], len(evaluable_buggy))
        self.assertEqual(
            aggregate["detected_buggy_oracles"],
            sum(case["oracle_detected"] for case in evaluable_buggy),
        )
        self.assertIn("does not demonstrate", aggregate["conclusion"])
        self.assertIn("Stage 1", aggregate["conclusion"])


if __name__ == "__main__":
    unittest.main()
