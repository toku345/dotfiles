from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from lib.model import ContractError
from lib.paths import ensure_no_symlink_ancestors, is_relative_to


FORBIDDEN_FLAGS = {"-y", "--yes", "--tty=false", "--tty=0"}


@dataclass(slots=True)
class GuardedSync:
    staging: Path
    registered_root: Path
    argv: tuple[str, ...]
    directory_fd: int
    _closed: bool = False

    def verify_path_identity(self) -> None:
        if self._closed:
            raise ContractError("guarded staging descriptor is closed")
        try:
            pinned = os.fstat(self.directory_fd)
            current = self.staging.lstat()
        except OSError as exc:
            raise ContractError("guarded staging identity cannot be verified") from exc
        if (
            not stat.S_ISDIR(current.st_mode)
            or stat.S_ISLNK(current.st_mode)
            or (current.st_dev, current.st_ino) != (pinned.st_dev, pinned.st_ino)
            or stat.S_IMODE(current.st_mode) != 0o700
            or current.st_uid != os.getuid()
        ):
            raise ContractError("guarded staging path identity changed")

    def close(self) -> None:
        if not self._closed:
            os.close(self.directory_fd)
            self._closed = True


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
    sync_arguments = [
        (index, argument.removeprefix("--sync="))
        for index, argument in enumerate(arguments)
        if argument.startswith("--sync=")
    ]
    if len(sync_arguments) != 1 or not sync_arguments[0][1]:
        raise ContractError("exactly one explicit Lima --sync path is required")
    sync_index, sync_value = sync_arguments[0]
    if Path(sync_value).absolute() != input_staging:
        raise ContractError("Lima --sync path does not match validated staging")
    guarded_arguments = list(arguments)
    guarded_arguments[sync_index] = "--sync=."
    try:
        directory_fd = os.open(
            canonical_staging,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        )
    except OSError as exc:
        raise ContractError("staging directory cannot be pinned") from exc
    guarded = GuardedSync(
        canonical_staging,
        registered_root,
        tuple(guarded_arguments),
        directory_fd,
    )
    try:
        guarded.verify_path_identity()
    except Exception:
        guarded.close()
        raise
    return guarded
