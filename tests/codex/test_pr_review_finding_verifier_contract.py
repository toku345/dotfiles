#!/usr/bin/env python3
"""Executable contract tests for the pr-review finding-verifier stage."""

from __future__ import annotations

import dataclasses
import json
import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_PATH = (
    REPO_ROOT
    / "private_dot_codex/skills/pr-review/references/finding-verifier-contract.json"
)
CONTRACT = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
if CONTRACT.get("sentinel") != "PR_REVIEW_FINDING_VERIFIER_CONTRACT_V1":
    raise AssertionError(f"{CONTRACT_PATH}: unsupported finding-verifier contract")


@dataclasses.dataclass(frozen=True)
class Finding:
    root_cause: str
    severity: str
    specialist_order: int
    finding_order: int


def assign_candidate_ids(findings: list[Finding]) -> list[tuple[str, Finding]]:
    """Model the deterministic normalization order specified by the skill."""
    severity_order = {
        severity: index
        for index, severity in enumerate(CONTRACT["candidate"]["eligible_severities"])
    }
    deduplicated: dict[str, Finding] = {}
    for finding in findings:
        if finding.severity not in severity_order:
            continue
        key = (
            severity_order[finding.severity],
            finding.specialist_order,
            finding.finding_order,
        )
        current = deduplicated.get(finding.root_cause)
        current_key = (
            severity_order[current.severity],
            current.specialist_order,
            current.finding_order,
        ) if current else None
        if current_key is None or key < current_key:
            deduplicated[finding.root_cause] = finding
    ordered = sorted(
        deduplicated.values(),
        key=lambda finding: (
            severity_order[finding.severity],
            finding.specialist_order,
            finding.finding_order,
        ),
    )
    return [(f"f{index:03d}", finding) for index, finding in enumerate(ordered, 1)]


def validate_result(
    raw: str,
    *,
    candidate_id: str,
    base_commit: str,
    head_ref: str,
    packet_sha256: str,
) -> dict:
    lines = raw.splitlines()
    expected_sentinel = (
        f"VERIFICATION_OK finding-verifier {candidate_id} "
        f"{base_commit}...{head_ref} {packet_sha256}"
    )
    if not lines or lines[0] != expected_sentinel:
        raise ValueError("verification sentinel mismatch")
    try:
        result = json.loads("\n".join(lines[1:]))
    except json.JSONDecodeError as exc:
        raise ValueError("invalid verification JSON") from exc
    if not isinstance(result, dict):
        raise ValueError("verification body must be one JSON object")
    missing_fields = set(CONTRACT["output"]["required_fields"]) - set(result)
    if missing_fields:
        raise ValueError(f"missing verification fields: {sorted(missing_fields)}")
    if result["candidate_id"] != candidate_id:
        raise ValueError("candidate ID mismatch")
    verdict = result["verdict"]
    if verdict not in CONTRACT["output"]["verdicts"]:
        raise ValueError("unknown verdict")
    if not isinstance(result["summary"], str) or not result["summary"].strip():
        raise ValueError("summary must be non-empty")
    evidence = result["evidence"]
    missing_verification = result["missingVerification"]
    if not isinstance(evidence, list) or not isinstance(missing_verification, list):
        raise ValueError("evidence and missingVerification must be arrays")
    evidence_fields = set(CONTRACT["output"]["evidence_item_required_fields"])
    for item in evidence:
        if not isinstance(item, dict) or not evidence_fields.issubset(item):
            raise ValueError("invalid evidence item")
        if not all(item[field] not in (None, "") for field in evidence_fields):
            raise ValueError("evidence fields must be non-empty")
    if not all(isinstance(item, str) and item.strip() for item in missing_verification):
        raise ValueError("missingVerification items must be non-empty strings")
    if verdict in {"confirmed", "refuted"}:
        if not evidence or missing_verification:
            raise ValueError(f"invalid {verdict} evidence shape")
    elif not missing_verification:
        raise ValueError("needs-verification requires missingVerification")
    return result


def exact_candidate_results(
    expected_candidate_ids: set[str], results: list[dict]
) -> bool:
    actual = [result.get("candidate_id") for result in results]
    return (
        all(isinstance(candidate_id, str) for candidate_id in actual)
        and len(actual) == len(set(actual))
        and set(actual) == expected_candidate_ids
    )


class FindingVerifierContractTests(unittest.TestCase):
    base_commit = "a" * 40
    head_ref = "b" * 40
    packet_sha256 = "c" * 64

    def result(self, verdict: str, evidence: list[dict], missing: list[str]) -> str:
        sentinel = (
            "VERIFICATION_OK finding-verifier f001 "
            f"{self.base_commit}...{self.head_ref} {self.packet_sha256}"
        )
        body = {
            "candidate_id": "f001",
            "verdict": verdict,
            "summary": "Evidence-based disposition.",
            "evidence": evidence,
            "missingVerification": missing,
        }
        return f"{sentinel}\n{json.dumps(body)}"

    def evidence(self) -> list[dict]:
        return [
            {"path": "example.sh", "line": 12, "observation": "The guard exits 0."}
        ]

    def validate(self, raw: str) -> dict:
        return validate_result(
            raw,
            candidate_id="f001",
            base_commit=self.base_commit,
            head_ref=self.head_ref,
            packet_sha256=self.packet_sha256,
        )

    def test_candidate_order_deduplicates_and_excludes_suggestions(self) -> None:
        assigned = assign_candidate_ids(
            [
                Finding("important-late", "Important", 2, 0),
                Finding("same-root", "Important", 1, 2),
                Finding("critical", "Critical", 3, 0),
                Finding("same-root", "Important", 0, 4),
                Finding("suggestion", "Suggestion", 0, 0),
            ]
        )
        self.assertEqual(
            [(candidate_id, finding.root_cause) for candidate_id, finding in assigned],
            [("f001", "critical"), ("f002", "same-root"), ("f003", "important-late")],
        )
        self.assertTrue(
            all(re.fullmatch(CONTRACT["candidate"]["id_pattern"], item[0]) for item in assigned)
        )
        self.assertEqual(assign_candidate_ids([]), [])

    def test_accepts_each_valid_verdict_shape(self) -> None:
        confirmed = self.validate(self.result("confirmed", self.evidence(), []))
        refuted = self.validate(self.result("refuted", self.evidence(), []))
        self.assertEqual(confirmed["verdict"], "confirmed")
        self.assertEqual(refuted["verdict"], "refuted")
        self.assertEqual(
            self.validate(
                self.result(
                    "needs-verification", [], ["Run the production probe."]
                )
            )["verdict"],
            "needs-verification",
        )

    def test_rejects_invalid_verdict_shapes(self) -> None:
        for verdict in ("confirmed", "refuted"):
            with self.subTest(verdict=verdict), self.assertRaises(ValueError):
                self.validate(self.result(verdict, [], []))
        with self.assertRaises(ValueError):
            self.validate(self.result("needs-verification", [], []))
        with self.assertRaises(ValueError):
            self.validate(self.result("confirmed", self.evidence(), ["Unresolved."]))

    def test_rejects_scope_candidate_and_json_mismatch(self) -> None:
        valid = self.result("confirmed", self.evidence(), [])
        with self.assertRaises(ValueError):
            self.validate(valid.replace("f001", "f002", 1))
        with self.assertRaises(ValueError):
            self.validate(valid.replace(self.packet_sha256, "d" * 64, 1))
        with self.assertRaises(ValueError):
            self.validate(valid + "\n{}")

    def test_exact_candidate_set_rejects_partial_unknown_and_duplicate(self) -> None:
        expected = {"f001", "f002"}
        self.assertTrue(
            exact_candidate_results(
                expected, [{"candidate_id": "f001"}, {"candidate_id": "f002"}]
            )
        )
        self.assertFalse(exact_candidate_results(expected, [{"candidate_id": "f001"}]))
        self.assertFalse(
            exact_candidate_results(
                expected, [{"candidate_id": "f001"}, {"candidate_id": "f003"}]
            )
        )
        self.assertFalse(
            exact_candidate_results(
                expected, [{"candidate_id": "f001"}, {"candidate_id": "f001"}]
            )
        )


if __name__ == "__main__":
    unittest.main()
