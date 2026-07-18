from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from lib.model import ContractError


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
INTEGRITY_RE = re.compile(r"^sha512-[A-Za-z0-9+/]+={0,2}$")


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ContractError(f"identity target is not a regular file: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ContractError(f"identity target changed while hashing: {path}")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot load JSON: {path}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"expected JSON object: {path}")
    return value


def validate_versions_lock(path: Path) -> dict[str, Any]:
    lock = load_json(path)
    if lock.get("schema_version") != 1:
        raise ContractError("unsupported versions lock schema")
    artifacts = lock.get("artifacts")
    if not isinstance(artifacts, dict) or not artifacts:
        raise ContractError("versions lock must contain artifacts")
    for name, artifact in artifacts.items():
        if not isinstance(artifact, dict):
            raise ContractError(f"invalid artifact entry: {name}")
        if not artifact.get("version") or not artifact.get("source"):
            raise ContractError(f"artifact lacks version/source: {name}")
        sha256 = artifact.get("sha256")
        integrity = artifact.get("integrity")
        if not ((isinstance(sha256, str) and SHA256_RE.fullmatch(sha256)) or (
            isinstance(integrity, str) and INTEGRITY_RE.fullmatch(integrity)
        )):
            raise ContractError(f"artifact lacks independent integrity: {name}")
    return lock


def _runtime_files(root: Path) -> dict[str, Path]:
    files: dict[str, Path] = {}
    for candidate in root.rglob("*"):
        relative = candidate.relative_to(root)
        if candidate.name == "manifest.json" and candidate.parent == root:
            continue
        if candidate.is_symlink():
            raise ContractError(f"harness symlink rejected: {relative}")
        if candidate.is_file():
            files[relative.as_posix()] = candidate
        elif not candidate.is_dir():
            raise ContractError(f"non-regular harness node rejected: {relative}")
    return files


def validate_manifest(root: Path, manifest_path: Path | None = None) -> dict[str, Any]:
    manifest_path = manifest_path or root / "manifest.json"
    manifest = load_json(manifest_path)
    if manifest.get("schema_version") != 1:
        raise ContractError("unsupported manifest schema")
    records = manifest.get("files")
    if not isinstance(records, list):
        raise ContractError("manifest files must be a list")

    expected: dict[str, str] = {}
    for record in records:
        if not isinstance(record, dict):
            raise ContractError("invalid manifest file record")
        name, digest = record.get("path"), record.get("sha256")
        if not isinstance(name, str) or name.startswith("/") or ".." in Path(name).parts:
            raise ContractError(f"unsafe manifest path: {name!r}")
        if name in expected:
            raise ContractError(f"duplicate manifest path: {name}")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise ContractError(f"invalid manifest digest: {name}")
        expected[name] = digest

    actual = _runtime_files(root)
    missing = sorted(set(expected).difference(actual))
    extra = sorted(set(actual).difference(expected))
    drifted = sorted(name for name in set(expected).intersection(actual) if sha256_file(actual[name]) != expected[name])
    if missing or extra or drifted:
        raise ContractError(
            f"harness manifest mismatch missing={missing} extra={extra} drifted={drifted}"
        )
    return manifest


def verify_binary_identity(
    path: Path, expected_sha256: str, version_argv: list[str], expected_version: str
) -> dict[str, str]:
    actual_digest = sha256_file(path.resolve())
    if actual_digest != expected_sha256:
        raise ContractError(f"binary digest drift: {path}")
    try:
        result = subprocess.run(
            version_argv,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ContractError(f"cannot identify binary: {path}") from exc
    output = (result.stdout + result.stderr).strip()
    if expected_version not in output:
        raise ContractError(f"binary version drift: {path}: {output}")
    return {"path": str(path.resolve()), "sha256": actual_digest, "version_output": output}


def flatten_mapping(value: Mapping[str, Any], prefix: str = "") -> dict[str, Any]:
    flattened: dict[str, Any] = {}
    for key in sorted(value):
        path = f"{prefix}.{key}" if prefix else key
        child = value[key]
        if isinstance(child, dict):
            flattened.update(flatten_mapping(child, path))
        else:
            flattened[path] = child
    return flattened


def load_toml_flat(path: Path) -> dict[str, Any]:
    try:
        return flatten_mapping(tomllib.loads(path.read_text(encoding="utf-8")))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ContractError(f"cannot load TOML seed: {path}") from exc


@dataclass(frozen=True, slots=True)
class EffectiveValue:
    value: Any
    origin: str


def compare_effective_seed(
    expected: Mapping[str, Any],
    observed: Mapping[str, EffectiveValue],
    *,
    expected_origin: str,
) -> None:
    missing = sorted(set(expected).difference(observed))
    mismatched: list[str] = []
    origin_drift: list[str] = []
    for key in sorted(set(expected).intersection(observed)):
        if observed[key].value != expected[key]:
            mismatched.append(key)
        if observed[key].origin != expected_origin:
            origin_drift.append(key)
    if missing or mismatched or origin_drift:
        raise ContractError(
            f"effective config mismatch missing={missing} values={mismatched} origins={origin_drift}"
        )
