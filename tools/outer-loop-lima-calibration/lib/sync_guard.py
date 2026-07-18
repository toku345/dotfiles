from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from lib.model import ContractError
from lib.paths import ensure_no_symlink_ancestors, is_relative_to


FORBIDDEN_FLAGS = {"-y", "--yes", "--tty=false", "--tty=0"}


@dataclass(frozen=True, slots=True)
class GuardedSync:
    staging: Path
    registered_root: Path
    argv: tuple[str, ...]


def _canonical_existing_directory(path: Path, *, stop: Path) -> Path:
    ensure_no_symlink_ancestors(path, stop=stop)
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise ContractError(f"staging path does not exist: {path}") from exc
    info = resolved.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ContractError("staging must be a real directory")
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise ContractError("staging must use mode 0700")
    if info.st_uid != os.getuid():
        raise ContractError("staging must be operator-owned")
    return resolved


def _reject_mount_transition(staging: Path, registered_root: Path) -> None:
    root_device = registered_root.stat().st_dev
    current = staging
    while True:
        if current.stat().st_dev != root_device:
            raise ContractError(f"mount transition below registered root: {current}")
        if current == registered_root:
            break
        if current.parent == current:
            raise ContractError("registered root is not an ancestor")
        current = current.parent


def validate_sync_invocation(
    argv: Iterable[str],
    staging: Path,
    *,
    registered_roots: Iterable[Path],
    authoritative_roots: Iterable[Path],
    stdin_isatty: bool,
    stdout_isatty: bool,
) -> GuardedSync:
    arguments = tuple(argv)
    if any(argument in FORBIDDEN_FLAGS or argument.startswith("--tty=false") for argument in arguments):
        raise ContractError("non-interactive Lima flags are forbidden")
    if not stdin_isatty or not stdout_isatty:
        raise ContractError("sync requires real stdin and stdout TTYs")
    input_staging = staging.absolute()
    input_roots = tuple(root.absolute() for root in registered_roots)
    lexical_matches = [root for root in input_roots if is_relative_to(input_staging, root)]
    if len(lexical_matches) != 1:
        raise ContractError("staging must be below exactly one registered root")
    input_root = lexical_matches[0]
    registered_root = _canonical_existing_directory(input_root, stop=input_root)
    canonical_staging = _canonical_existing_directory(input_staging, stop=input_root)
    if not is_relative_to(canonical_staging, registered_root):
        raise ContractError("staging escaped its registered root")
    _reject_mount_transition(canonical_staging, registered_root)

    for root in authoritative_roots:
        try:
            authoritative = root.resolve(strict=True)
        except OSError as exc:
            raise ContractError(f"authoritative root cannot be verified: {root}") from exc
        if is_relative_to(canonical_staging, authoritative) or is_relative_to(authoritative, canonical_staging):
            raise ContractError("authoritative repository overlap rejected")
    return GuardedSync(canonical_staging, registered_root, arguments)
