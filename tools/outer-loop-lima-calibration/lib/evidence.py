from __future__ import annotations

import fcntl
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path
from typing import Iterable, Mapping

from lib.identities import canonical_json, sha256_file
from lib.model import ApprovalRecord, ContractError, ControlRecord, RiskAcceptanceRecord, TerminalState
from lib.paths import RunPaths


FORBIDDEN_EVIDENCE_KEYS = {
    "credential_bytes",
    "credential_hash",
    "credential_size",
    "device_code",
    "email",
    "login_url",
    "raw_environment",
    "raw_jsonl",
    "raw_output",
    "workspace_id",
}


def _validate_sanitized(value: object) -> None:
    if isinstance(value, dict):
        forbidden = FORBIDDEN_EVIDENCE_KEYS.intersection(value)
        if forbidden:
            raise ContractError(f"forbidden evidence fields: {sorted(forbidden)}")
        for child in value.values():
            _validate_sanitized(child)
    elif isinstance(value, list | tuple):
        for child in value:
            _validate_sanitized(child)


def write_once(path: Path, value: object) -> None:
    _validate_sanitized(value)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(descriptor, canonical_json(value))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def append_jsonl(path: Path, value: object) -> None:
    _validate_sanitized(value)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ContractError("evidence log is not a single regular file")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.write(descriptor, canonical_json(value))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def record_control(paths: RunPaths, record: ControlRecord) -> None:
    append_jsonl(paths.evidence / "controls.jsonl", record.to_dict())


def record_decision(
    paths: RunPaths, record: RiskAcceptanceRecord | ApprovalRecord | Mapping[str, object]
) -> None:
    value = record.to_dict() if hasattr(record, "to_dict") else dict(record)
    append_jsonl(paths.evidence / "decisions.jsonl", value)


def seal_input_digest(paths: RunPaths) -> str:
    entries: list[dict[str, str]] = []
    for path in sorted(paths.evidence.rglob("*")):
        if not path.is_file() or path.name in {"summary.md", "controls.jsonl", "decisions.jsonl"}:
            continue
        entries.append(
            {"path": path.relative_to(paths.evidence).as_posix(), "sha256": sha256_file(path)}
        )
    for name in ("controls.jsonl", "decisions.jsonl"):
        path = paths.evidence / name
        if not path.exists():
            continue
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ContractError(f"invalid evidence JSONL: {name}:{index}") from exc
            if not isinstance(value, dict):
                raise ContractError(f"invalid evidence record: {name}:{index}")
            if value.get("record_type") == "control":
                key = value.get("key")
                if isinstance(key, dict) and key.get("control_id") == "C08":
                    continue
            if value.get("record_type") == "approval" and value.get("gate") == "final-seal":
                continue
            entries.append(
                {
                    "path": f"{name}#{index}",
                    "sha256": hashlib.sha256(canonical_json(value)).hexdigest(),
                }
            )
    if not entries:
        raise ContractError("cannot prepare an empty evidence seal")
    return hashlib.sha256(canonical_json({"schema_version": 1, "entries": entries})).hexdigest()


def seal(
    paths: RunPaths,
    *,
    terminal: TerminalState,
    approved_digest: str,
    retention_deadline: str,
    control_records: Iterable[ControlRecord],
) -> str:
    current_digest = seal_input_digest(paths)
    if approved_digest != current_digest:
        raise ContractError("final approval digest does not match seal input")
    records = tuple(control_records)
    if terminal is TerminalState.READY and (
        not records or any(record.result.value != "PASS" for record in records)
    ):
        raise ContractError("ready seal requires all applicable controls to pass")
    summary = (
        f"terminal_state: {terminal.value}\n"
        "real_task_allowed: no\n"
        f"seal_input_digest: {current_digest}\n"
        f"retention_deadline: {retention_deadline}\n"
    )
    terminal_entries = [
        {
            "path": path.relative_to(paths.evidence).as_posix(),
            "sha256": sha256_file(path),
        }
        for path in sorted(paths.evidence.rglob("*"))
        if path.is_file() and path.name != "summary.md"
    ]
    terminal_digest = hashlib.sha256(
        canonical_json({"schema_version": 1, "entries": terminal_entries})
    ).hexdigest()
    summary += f"terminal_evidence_digest: {terminal_digest}\n"
    summary_path = paths.evidence / "summary.md"
    descriptor = os.open(summary_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    try:
        os.write(descriptor, summary.encode())
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    seal_digest = hashlib.sha256((current_digest + "\n" + summary).encode()).hexdigest()
    for path in paths.evidence.rglob("*"):
        if path.is_file():
            os.chmod(path, 0o400)
            if sys.platform == "darwin":
                subprocess.run(["chflags", "uchg", str(path)], check=True, timeout=10)
    return seal_digest
