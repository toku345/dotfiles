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


@dataclasses.dataclass(frozen=True)
class Candidate:
    candidate_id: str
    severity: str
    summary: str


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
    evidence_constraints = CONTRACT["output"]["evidence_item_constraints"]
    for item in evidence:
        if not isinstance(item, dict) or set(item) != evidence_fields:
            raise ValueError("invalid evidence item")
        path = item["path"]
        if (
            not isinstance(path, str)
            or not path.strip()
            or path != path.strip()
            or path.startswith("/")
            or "\\" in path
            or any(part in {"", ".", ".."} for part in path.split("/"))
        ):
            raise ValueError("evidence path must be repository-relative")
        line = item["line"]
        line_pattern = evidence_constraints["line"]["line_range_pattern"]
        if isinstance(line, bool):
            raise ValueError("evidence line must be a positive line or range")
        if isinstance(line, int):
            if line <= 0:
                raise ValueError("evidence line must be positive")
        elif isinstance(line, str) and re.fullmatch(line_pattern, line):
            start, _, end = line.partition("-")
            if end and int(start) > int(end):
                raise ValueError("evidence line range must be ordered")
        else:
            raise ValueError("evidence line must be a positive line or range")
        observation = item["observation"]
        if not isinstance(observation, str) or not observation.strip():
            raise ValueError("evidence observation must be non-empty")
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


def aggregate_verified_candidates(
    candidates: list[Candidate],
    results: list[dict],
    *,
    important_cap: int = 5,
) -> dict:
    """Model Stage 3 verdict application and final fix-queue budgeting."""
    candidate_ids = [candidate.candidate_id for candidate in candidates]
    if len(candidate_ids) != len(set(candidate_ids)):
        raise ValueError("duplicate candidate ID")
    expected = set(candidate_ids)
    if not exact_candidate_results(expected, results):
        raise ValueError("verification result set mismatch")
    result_by_id = {result["candidate_id"]: result for result in results}
    critical: list[Candidate] = []
    important: list[Candidate] = []
    refuted: list[tuple[Candidate, str]] = []
    verdict_counts = {verdict: 0 for verdict in CONTRACT["output"]["verdicts"]}

    for candidate in candidates:
        if candidate.severity not in CONTRACT["candidate"]["eligible_severities"]:
            raise ValueError("unknown candidate severity")
        result = result_by_id[candidate.candidate_id]
        verdict = result.get("verdict")
        if verdict not in verdict_counts:
            raise ValueError("unknown verifier verdict")
        verdict_counts[verdict] += 1
        if verdict == "refuted":
            refuted.append((candidate, result["summary"]))
        elif verdict == "needs-verification" or candidate.severity == "Important":
            important.append(candidate)
        else:
            critical.append(candidate)

    return {
        "verification_summary": verdict_counts,
        "critical": critical,
        "important_total": len(important),
        "important_shown": important[:important_cap],
        "refuted": refuted,
    }


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

    def test_rejects_structurally_meaningless_evidence_values(self) -> None:
        invalid_items = [
            {"path": "", "line": 12, "observation": "Observed."},
            {"path": "/tmp/file", "line": 12, "observation": "Observed."},
            {"path": "../file", "line": 12, "observation": "Observed."},
            {"path": "src/./file", "line": 12, "observation": "Observed."},
            {"path": "src/file", "line": 0, "observation": "Observed."},
            {"path": "src/file", "line": True, "observation": "Observed."},
            {"path": "src/file", "line": "18-12", "observation": "Observed."},
            {"path": "src/file", "line": "line 12", "observation": "Observed."},
            {"path": "src/file", "line": 12, "observation": "   "},
            {
                "path": "src/file",
                "line": 12,
                "observation": "Observed.",
                "extra": "not allowed",
            },
        ]
        for item in invalid_items:
            with self.subTest(item=item), self.assertRaises(ValueError):
                self.validate(self.result("confirmed", [item], []))

    def test_accepts_positive_line_and_ordered_line_range(self) -> None:
        for line in (1, "12", "12-18"):
            with self.subTest(line=line):
                result = self.result(
                    "confirmed",
                    [
                        {
                            "path": "src/example.sh",
                            "line": line,
                            "observation": "The guard exits 0.",
                        }
                    ],
                    [],
                )
                self.assertEqual(self.validate(result)["verdict"], "confirmed")

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

    def test_aggregation_applies_verdicts_caps_and_refuted_visibility(self) -> None:
        candidates = [
            Candidate("f001", "Critical", "Confirmed blocker"),
            Candidate("f002", "Critical", "Unproven blocker"),
            *[
                Candidate(f"f{index:03d}", "Important", f"Important {index}")
                for index in range(3, 9)
            ],
            Candidate("f009", "Important", "Refuted concern"),
        ]
        results = [
            {
                "candidate_id": candidate.candidate_id,
                "verdict": (
                    "needs-verification"
                    if candidate.candidate_id == "f002"
                    else "refuted"
                    if candidate.candidate_id == "f009"
                    else "confirmed"
                ),
                "summary": f"Disposition for {candidate.candidate_id}",
            }
            for candidate in candidates
        ]
        aggregation = aggregate_verified_candidates(candidates, results)
        self.assertEqual(
            aggregation["verification_summary"],
            {"confirmed": 7, "refuted": 1, "needs-verification": 1},
        )
        self.assertEqual(
            [candidate.candidate_id for candidate in aggregation["critical"]],
            ["f001"],
        )
        self.assertEqual(aggregation["important_total"], 7)
        self.assertEqual(
            [candidate.candidate_id for candidate in aggregation["important_shown"]],
            ["f002", "f003", "f004", "f005", "f006"],
        )
        self.assertEqual(
            [(candidate.candidate_id, summary) for candidate, summary in aggregation["refuted"]],
            [("f009", "Disposition for f009")],
        )

    def test_aggregation_handles_zero_candidates_and_rejects_partial_results(self) -> None:
        empty = aggregate_verified_candidates([], [])
        self.assertEqual(empty["critical"], [])
        self.assertEqual(empty["important_total"], 0)
        self.assertEqual(empty["refuted"], [])

        candidates = [
            Candidate("f001", "Critical", "First"),
            Candidate("f002", "Important", "Second"),
        ]
        with self.assertRaises(ValueError):
            aggregate_verified_candidates(
                candidates,
                [{"candidate_id": "f001", "verdict": "confirmed", "summary": "ok"}],
            )


if __name__ == "__main__":
    unittest.main()
