from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Iterable

from lib.identities import canonical_json
from lib.model import ContractError


SECRET_NAME = re.compile(
    r"(^|/)(\.env($|\.)|id_(rsa|ed25519)|.*\.(key|pem|p12)$|\.credentials\.json$|auth\.json$)",
    re.IGNORECASE,
)
SECRET_CONTENT = re.compile(
    rb"(-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:api[_-]?key|password|secret|token)\s*[:=]\s*[^\s]{8,})",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class InventoryNode:
    path: str
    node_type: str
    mode: str
    nlink: int
    sha256: str | None
    link_target_digest: str | None = None


def _safe_relative(path: Path, root: Path) -> str:
    relative = path.relative_to(root).as_posix()
    if relative.startswith("/") or ".." in Path(relative).parts or relative in {"", "."}:
        raise ContractError("unsafe export path")
    return relative


def _hash_regular(path: Path) -> tuple[str, bytes]:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ContractError("export node changed type")
        digest = hashlib.sha256()
        sample = bytearray()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
            if len(sample) < 1024 * 1024:
                sample.extend(chunk[: 1024 * 1024 - len(sample)])
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ContractError("export file changed while hashing")
        return digest.hexdigest(), bytes(sample)
    finally:
        os.close(descriptor)


def inventory(root: Path, *, read_only: bool = False) -> tuple[InventoryNode, ...]:
    root = root.resolve(strict=True)
    nodes: list[InventoryNode] = []
    for directory, directories, files in os.walk(root, topdown=True, followlinks=False):
        entries = sorted((*directories, *files))
        for name in entries:
            path = Path(directory) / name
            relative = _safe_relative(path, root)
            info = path.lstat()
            mode = f"{stat.S_IMODE(info.st_mode):04o}"
            if stat.S_ISREG(info.st_mode):
                digest, sample = _hash_regular(path)
                if SECRET_NAME.search(relative) or SECRET_CONTENT.search(sample):
                    raise ContractError(f"secret-shaped export rejected at {relative}")
                if info.st_nlink != 1:
                    raise ContractError(f"hard-linked export rejected at {relative}")
                allowed_file_modes = {0o400} if read_only else {0o600, 0o640, 0o644}
                if stat.S_IMODE(info.st_mode) not in allowed_file_modes:
                    raise ContractError(f"unsafe export file mode at {relative}")
                nodes.append(InventoryNode(relative, "file", mode, info.st_nlink, digest))
            elif stat.S_ISDIR(info.st_mode):
                allowed_directory_modes = {0o500} if read_only else {0o700, 0o750, 0o755}
                if info.st_nlink < 1 or stat.S_IMODE(info.st_mode) not in allowed_directory_modes:
                    raise ContractError(f"unsafe export directory at {relative}")
                nodes.append(InventoryNode(relative, "directory", mode, info.st_nlink, None))
            elif stat.S_ISLNK(info.st_mode):
                target = os.readlink(path).encode()
                nodes.append(
                    InventoryNode(
                        relative,
                        "symlink",
                        mode,
                        info.st_nlink,
                        None,
                        hashlib.sha256(target).hexdigest(),
                    )
                )
            else:
                nodes.append(InventoryNode(relative, "special", mode, info.st_nlink, None))
    return tuple(nodes)


def stable_inventory(
    root: Path,
    between: Callable[[], None] | None = None,
    *,
    read_only: bool = False,
) -> tuple[InventoryNode, ...]:
    first = inventory(root, read_only=read_only)
    if between:
        between()
    second = inventory(root, read_only=read_only)
    if first != second:
        raise ContractError("export inventory changed between stable passes")
    return second


def _copy_regular(source: Path, destination: Path) -> None:
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    destination_fd: int | None = None
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode):
            raise ContractError("quarantine source changed type")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            stat.S_IMODE(before.st_mode),
        )
        os.fchmod(destination_fd, stat.S_IMODE(before.st_mode))
        while chunk := os.read(source_fd, 1024 * 1024):
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
        os.fsync(destination_fd)
        after = os.fstat(source_fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise ContractError("quarantine source changed during copy")
    finally:
        os.close(source_fd)
        if destination_fd is not None:
            os.close(destination_fd)


def copy_preserving_nodes(source: Path, destination: Path) -> None:
    source = source.resolve(strict=True)
    if destination.exists() or destination.is_symlink():
        raise ContractError("quarantine destination must be fresh")
    destination.mkdir(mode=0o700, parents=False)
    for directory, directories, files in os.walk(source, topdown=True, followlinks=False):
        relative_dir = Path(directory).relative_to(source)
        destination_dir = destination / relative_dir
        for name in sorted(directories):
            source_path = Path(directory) / name
            destination_path = destination_dir / name
            if source_path.is_symlink():
                os.symlink(os.readlink(source_path), destination_path)
            else:
                source_mode = stat.S_IMODE(source_path.lstat().st_mode)
                destination_path.mkdir(mode=source_mode)
                os.chmod(destination_path, source_mode)
        for name in sorted(files):
            source_path = Path(directory) / name
            destination_path = destination_dir / name
            info = source_path.lstat()
            if stat.S_ISLNK(info.st_mode):
                os.symlink(os.readlink(source_path), destination_path)
            elif stat.S_ISREG(info.st_mode):
                _copy_regular(source_path, destination_path)
            else:
                raise ContractError("special source node cannot be quarantined")


def validate_quarantine(source: Path, quarantine: Path) -> tuple[InventoryNode, ...]:
    source_inventory = stable_inventory(source)
    copy_preserving_nodes(source, quarantine)
    quarantine_inventory = stable_inventory(quarantine)
    if source_inventory != quarantine_inventory:
        raise ContractError("source and quarantine inventories differ")
    hazards = [node.path for node in quarantine_inventory if node.node_type != "file" and node.node_type != "directory"]
    if hazards:
        raise ContractError(f"link or special nodes rejected: {hazards}")
    return quarantine_inventory


def freeze_bundle(quarantine: Path, frozen: Path, inventory_nodes: Iterable[InventoryNode]) -> str:
    if frozen.exists() or frozen.is_symlink():
        raise ContractError("frozen bundle destination must be fresh")
    copy_preserving_nodes(quarantine, frozen)
    final_inventory = stable_inventory(frozen)
    expected = tuple(inventory_nodes)
    if final_inventory != expected:
        raise ContractError("frozen bundle inventory drift")
    source_manifest = {
        "schema_version": 1,
        "source_inventory": [asdict(node) for node in final_inventory],
    }
    for directory, _, files in os.walk(frozen):
        for name in files:
            os.chmod(Path(directory) / name, 0o400)
        if Path(directory) != frozen:
            os.chmod(directory, 0o500)
    frozen_inventory = stable_inventory(frozen, read_only=True)
    manifest = {
        **source_manifest,
        "frozen_inventory": [asdict(node) for node in frozen_inventory],
    }
    manifest_path = frozen / "bundle-manifest.json"
    descriptor = os.open(
        manifest_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o400,
    )
    try:
        os.write(descriptor, canonical_json(manifest))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(frozen, 0o500)
    return hashlib.sha256(canonical_json(manifest)).hexdigest()
