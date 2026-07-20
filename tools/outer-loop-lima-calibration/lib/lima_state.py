from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Mapping

from lib.identities import canonical_json
from lib.model import (
    ContractError,
    LimaIdentity,
    LimaListDisposition,
    RUNTIME_SCHEMA_VERSION,
)


CODEX_INSTANCE = "outer-loop-week0-codex"
CLAUDE_INSTANCE = "outer-loop-week0-claude"
FIXED_INSTANCES = (CODEX_INSTANCE, CLAUDE_INSTANCE)
LIMA_ADMINISTRATIVE_DIRECTORIES = frozenset(
    {"_cache", "_config", "_disks", "_networks", "_templates"}
)
NO_INSTANCE_WARNING = (
    'level=warning msg="No instance found. Run `limactl create` to create an instance."'
)
LIMA_LOG_TIMESTAMP_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})"
)
EXPECTED_CPUS = 4
EXPECTED_MEMORY_BYTES = 8 * 1024 * 1024 * 1024
EXPECTED_DISK_BYTES = 40 * 1024 * 1024 * 1024


def is_pinned_no_instance_warning(line: str) -> bool:
    timestamp_prefix, separator, message = line.partition('" ')
    if separator != '" ' or not timestamp_prefix.startswith('time="') or message != NO_INSTANCE_WARNING:
        return False
    timestamp = timestamp_prefix.removeprefix('time="')
    if LIMA_LOG_TIMESTAMP_RE.fullmatch(timestamp) is None:
        return False
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


@dataclass(frozen=True, slots=True)
class LimaListSnapshot:
    disposition: LimaListDisposition
    identities: tuple[LimaIdentity, ...]
    stdout_digest: str
    stderr_digest: str
    record_count: int

    def to_evidence(self) -> dict[str, object]:
        fixed = sorted(
            identity.name for identity in self.identities if identity.name in FIXED_INSTANCES
        )
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "lima_list_snapshot",
            "disposition": self.disposition,
            "record_count": self.record_count,
            "fixed_instances": fixed,
            "unrelated_instance_count": self.record_count - len(fixed),
            "stdout_digest": self.stdout_digest,
            "stderr_digest": self.stderr_digest,
            "parser_contract_digest": parser_contract_digest(),
        }


def parser_contract_digest() -> str:
    return hashlib.sha256(
        canonical_json(
            {
                "contract_version": 1,
                "format": "lima-2.1.4-json-lines",
                "empty": "canonical-warning-only",
                "stderr_with_stdout": "UNKNOWN",
                "arrays": "UNKNOWN",
                "duplicates": "UNKNOWN",
            }
        )
    ).hexdigest()


def _unknown(stdout: str, stderr: str) -> LimaListSnapshot:
    return LimaListSnapshot(
        LimaListDisposition.UNKNOWN,
        (),
        hashlib.sha256(stdout.encode()).hexdigest(),
        hashlib.sha256(stderr.encode()).hexdigest(),
        0,
    )


def _identity_from_record(record: object) -> LimaIdentity:
    if type(record) is not dict:
        raise ContractError("Lima list record must be an object")
    required_strings = ("name", "status", "dir", "vmType", "arch")
    if any(type(record.get(key)) is not str or not str(record[key]).strip() for key in required_strings):
        raise ContractError("Lima list identity string fields are invalid")
    for key in ("cpus", "memory", "disk"):
        if type(record.get(key)) is not int:
            raise ContractError("Lima list identity resource fields are invalid")
    return LimaIdentity(
        name=record["name"],
        status=record["status"],
        directory=record["dir"],
        vm_type=record["vmType"],
        arch=record["arch"],
        cpus=record["cpus"],
        memory=record["memory"],
        disk=record["disk"],
    )


def parse_lima_list(returncode: int, stdout: str | None, stderr: str | None) -> LimaListSnapshot:
    output = stdout or ""
    diagnostic = stderr or ""
    output_digest = hashlib.sha256(output.encode()).hexdigest()
    diagnostic_digest = hashlib.sha256(diagnostic.encode()).hexdigest()
    if returncode != 0:
        return _unknown(output, diagnostic)
    lines = [line for line in output.splitlines() if line.strip()]
    stderr_lines = [line.strip() for line in diagnostic.splitlines() if line.strip()]
    if lines:
        if stderr_lines:
            return _unknown(output, diagnostic)
        identities: list[LimaIdentity] = []
        try:
            for line in lines:
                value = json.loads(line)
                if isinstance(value, list):
                    raise ContractError("Lima JSON arrays are outside the pinned contract")
                identities.append(_identity_from_record(value))
        except (json.JSONDecodeError, ContractError):
            return _unknown(output, diagnostic)
        names = [identity.name for identity in identities]
        if len(names) != len(set(names)):
            return _unknown(output, diagnostic)
        return LimaListSnapshot(
            LimaListDisposition.RECOGNIZED,
            tuple(identities),
            output_digest,
            diagnostic_digest,
            len(identities),
        )
    if len(stderr_lines) == 1 and is_pinned_no_instance_warning(stderr_lines[0]):
        return LimaListSnapshot(
            LimaListDisposition.ABSENT,
            (),
            output_digest,
            diagnostic_digest,
            0,
        )
    return _unknown(output, diagnostic)


def validate_expected_identity(
    identity: LimaIdentity,
    *,
    name: str,
    status: str,
    directory: Path,
) -> None:
    expected = {
        "name": name,
        "status": status,
        "directory": str(directory),
        "vm_type": "vz",
        "arch": "aarch64",
        "cpus": EXPECTED_CPUS,
        "memory": EXPECTED_MEMORY_BYTES,
        "disk": EXPECTED_DISK_BYTES,
    }
    actual = {
        "name": identity.name,
        "status": identity.status,
        "directory": identity.directory,
        "vm_type": identity.vm_type,
        "arch": identity.arch,
        "cpus": identity.cpus,
        "memory": identity.memory,
        "disk": identity.disk,
    }
    if actual != expected:
        raise ContractError("Lima instance identity does not match the frozen contract")


def fixed_identity_map(snapshot: LimaListSnapshot) -> dict[str, LimaIdentity]:
    if snapshot.disposition is not LimaListDisposition.RECOGNIZED:
        raise ContractError("recognized Lima identity snapshot required")
    values = {identity.name: identity for identity in snapshot.identities}
    if set(values).difference(FIXED_INSTANCES):
        raise ContractError("unrelated Lima instance rejected")
    return values


def path_disposition(path: Path) -> str:
    try:
        path.lstat()
    except FileNotFoundError:
        return "ABSENT"
    except OSError:
        return "UNKNOWN"
    return "PRESENT"


@dataclass(frozen=True, slots=True)
class TopLevelSnapshot:
    fixed_directories: tuple[str, ...]
    administrative_directories: tuple[str, ...]
    unknown_entries: tuple[str, ...]
    disposition: str

    def to_evidence(self) -> dict[str, object]:
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "lima_home_top_level",
            "fixed_directories": list(self.fixed_directories),
            "administrative_directory_count": len(self.administrative_directories),
            "unknown_entry_count": len(self.unknown_entries),
            "disposition": self.disposition,
        }


def inspect_top_level(home: Path) -> TopLevelSnapshot:
    try:
        entries = list(os.scandir(home))
    except OSError:
        return TopLevelSnapshot((), (), (), "UNKNOWN")
    fixed: list[str] = []
    administrative: list[str] = []
    unknown: list[str] = []
    for entry in sorted(entries, key=lambda item: os.fsencode(item.name)):
        try:
            info = entry.stat(follow_symlinks=False)
        except OSError:
            unknown.append(entry.name)
            continue
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            unknown.append(entry.name)
        elif entry.name in FIXED_INSTANCES:
            fixed.append(entry.name)
        elif entry.name in LIMA_ADMINISTRATIVE_DIRECTORIES:
            administrative.append(entry.name)
        else:
            unknown.append(entry.name)
    return TopLevelSnapshot(
        tuple(fixed),
        tuple(administrative),
        tuple(unknown),
        "CLEAN" if not unknown else "UNKNOWN",
    )


def identities_from_evidence(value: object) -> dict[str, LimaIdentity]:
    if type(value) is not dict:
        raise ContractError("Lima identity evidence is invalid")
    records = value.get("identities")
    if type(records) is not dict:
        raise ContractError("Lima identity evidence records are invalid")
    identities: dict[str, LimaIdentity] = {}
    for runtime, record in records.items():
        if runtime not in {"codex", "claude"} or type(record) is not dict:
            raise ContractError("Lima identity evidence target is invalid")
        identity = LimaIdentity(
            name=record.get("name", ""),
            status=record.get("status", ""),
            directory=record.get("directory", ""),
            vm_type=record.get("vm_type", ""),
            arch=record.get("arch", ""),
            cpus=record.get("cpus"),
            memory=record.get("memory"),
            disk=record.get("disk"),
        )
        identities[runtime] = identity
    return identities


def identity_digest(identities: Mapping[str, LimaIdentity]) -> str:
    return hashlib.sha256(
        canonical_json({key: value.to_dict() for key, value in sorted(identities.items())})
    ).hexdigest()
