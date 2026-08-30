#!/usr/bin/env python3
"""Validate finding-verifier evidence against one immutable Git commit."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
from typing import Any


HEAD_OID_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
CANDIDATE_ID_RE = re.compile(r"f[0-9]{3,}\Z")
LINE_RE = re.compile(r"[1-9][0-9]*(?:-[1-9][0-9]*)?\Z")
EVIDENCE_FIELDS = {"path", "line", "observation"}
REGULAR_FILE_MODES = {"100644", "100755"}


class EvidenceValidationError(ValueError):
    """A verifier citation cannot be proven against the immutable commit."""


def _git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["GIT_LITERAL_PATHSPECS"] = "1"
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    return environment


def _run_git(
    repo_root: pathlib.Path,
    *args: str,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=_git_environment(),
        )
    except OSError as exc:
        raise EvidenceValidationError("git evidence lookup could not start") from exc
    if result.returncode != 0:
        raise EvidenceValidationError("git evidence lookup failed")
    return result


def _validate_path_shape(path: Any) -> str:
    if (
        not isinstance(path, str)
        or not path.strip()
        or path != path.strip()
        or path.startswith("/")
        or "\\" in path
        or any(part in {"", ".", ".."} for part in path.split("/"))
        or any(ord(character) < 32 or ord(character) == 127 for character in path)
    ):
        raise EvidenceValidationError("evidence path is not a safe repository path")
    return path


def _line_bounds(line: Any) -> tuple[int, int]:
    if isinstance(line, bool):
        raise EvidenceValidationError("evidence line is not a positive line or range")
    if isinstance(line, int):
        if line <= 0:
            raise EvidenceValidationError("evidence line is not positive")
        return line, line
    if not isinstance(line, str) or not LINE_RE.fullmatch(line):
        raise EvidenceValidationError("evidence line is not a positive line or range")
    start_text, separator, end_text = line.partition("-")
    start = int(start_text)
    end = int(end_text) if separator else start
    if start > end:
        raise EvidenceValidationError("evidence line range is reversed")
    return start, end


def _immutable_blob_oid(
    repo_root: pathlib.Path,
    head_ref: str,
    path: str,
) -> str:
    result = _run_git(
        repo_root,
        "ls-tree",
        "-z",
        "--full-tree",
        head_ref,
        "--",
        path,
    )
    records = [record for record in result.stdout.split(b"\0") if record]
    expected_path = os.fsencode(path)
    matches: list[tuple[bytes, bytes]] = []
    for record in records:
        metadata, separator, raw_path = record.partition(b"\t")
        if separator and raw_path == expected_path:
            matches.append((metadata, raw_path))
    if len(matches) != 1:
        raise EvidenceValidationError("evidence path is absent from HEAD_REF")
    metadata = matches[0][0].decode("ascii", errors="strict").split()
    if len(metadata) != 3:
        raise EvidenceValidationError("evidence tree entry is malformed")
    mode, object_type, object_id = metadata
    if mode not in REGULAR_FILE_MODES or object_type != "blob":
        raise EvidenceValidationError("evidence path is not a tracked regular file")
    return object_id


def _immutable_blob_line_count(repo_root: pathlib.Path, object_id: str) -> int:
    try:
        process = subprocess.Popen(
            ["git", "-C", str(repo_root), "cat-file", "blob", object_id],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_git_environment(),
        )
    except OSError as exc:
        raise EvidenceValidationError("git blob lookup could not start") from exc
    if process.stdout is None:
        process.kill()
        process.wait()
        raise EvidenceValidationError("git blob lookup has no output stream")

    byte_count = 0
    newline_count = 0
    last_byte = b""
    binary = False
    try:
        while chunk := process.stdout.read(65536):
            byte_count += len(chunk)
            newline_count += chunk.count(b"\n")
            last_byte = chunk[-1:]
            binary = binary or b"\0" in chunk
    finally:
        process.stdout.close()
        returncode = process.wait()
    if returncode != 0:
        raise EvidenceValidationError("git blob lookup failed")
    if binary:
        raise EvidenceValidationError("evidence path is not a text file")
    if byte_count == 0:
        return 0
    return newline_count + (0 if last_byte == b"\n" else 1)


def validate_evidence(
    repo_root: pathlib.Path,
    head_ref: str,
    result: dict[str, Any],
) -> int:
    """Validate every evidence item and return the validated item count."""
    if not HEAD_OID_RE.fullmatch(head_ref):
        raise EvidenceValidationError("HEAD_REF is not an immutable commit OID")
    object_type = _run_git(repo_root, "cat-file", "-t", head_ref).stdout.strip()
    if object_type != b"commit":
        raise EvidenceValidationError("HEAD_REF does not identify a commit")

    candidate_id = result.get("candidate_id")
    if not isinstance(candidate_id, str) or not CANDIDATE_ID_RE.fullmatch(candidate_id):
        raise EvidenceValidationError("candidate ID is invalid")
    evidence = result.get("evidence")
    if not isinstance(evidence, list):
        raise EvidenceValidationError("evidence is not an array")

    for item in evidence:
        if not isinstance(item, dict) or set(item) != EVIDENCE_FIELDS:
            raise EvidenceValidationError("evidence item fields are invalid")
        path = _validate_path_shape(item["path"])
        _, end_line = _line_bounds(item["line"])
        observation = item["observation"]
        if not isinstance(observation, str) or not observation.strip():
            raise EvidenceValidationError("evidence observation is empty")
        object_id = _immutable_blob_oid(repo_root, head_ref, path)
        line_count = _immutable_blob_line_count(repo_root, object_id)
        if end_line > line_count:
            raise EvidenceValidationError("evidence line exceeds the immutable blob")
    return len(evidence)


def _load_result(path: pathlib.Path) -> dict[str, Any]:
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EvidenceValidationError("result file is not valid UTF-8 JSON") from exc
    if not isinstance(result, dict):
        raise EvidenceValidationError("result file must contain one JSON object")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=pathlib.Path)
    parser.add_argument("--head-ref", required=True)
    parser.add_argument("--result-file", required=True, type=pathlib.Path)
    args = parser.parse_args()

    try:
        result = _load_result(args.result_file)
        evidence_count = validate_evidence(args.repo_root, args.head_ref, result)
    except EvidenceValidationError as exc:
        print(f"EVIDENCE_INVALID finding-verifier: {exc}", file=sys.stderr)
        return 1

    print(
        "EVIDENCE_OK finding-verifier "
        f"{result['candidate_id']} {args.head_ref} {evidence_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
