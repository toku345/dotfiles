from __future__ import annotations

import os
import re
import stat
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from lib.model import ContractError


RUN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{7,63}$")
STATE_ROOT = Path.home() / ".local/state/outer-loop/lima-prearm/v1"


def parse_utc_deadline(value: str) -> datetime:
    if not value.endswith("Z"):
        raise ContractError("retention deadline must use RFC 3339 UTC with Z")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise ContractError("invalid RFC 3339 retention deadline") from exc
    if parsed.tzinfo != UTC or parsed.microsecond:
        raise ContractError("retention deadline must be whole-second UTC")
    return parsed


def validate_run_id(run_id: str) -> str:
    if not RUN_ID_RE.fullmatch(run_id):
        raise ContractError("run id must be 8-64 lowercase alphanumeric/hyphen characters")
    return run_id


def ensure_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ContractError(f"not a real directory: {path}")
    if stat.S_IMODE(info.st_mode) != 0o700:
        os.chmod(path, 0o700)


def ensure_no_symlink_ancestors(path: Path, *, stop: Path | None = None) -> None:
    absolute = path.absolute()
    limit = stop.absolute() if stop else Path(absolute.anchor)
    current = absolute
    checked: list[Path] = []
    while True:
        checked.append(current)
        if current == limit or current.parent == current:
            break
        current = current.parent
    if limit not in checked:
        raise ContractError(f"path is not below required root: {path}")
    for candidate in reversed(checked):
        if candidate.exists() and stat.S_ISLNK(candidate.lstat().st_mode):
            raise ContractError(f"symlink ancestor rejected: {candidate}")


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


@dataclass(frozen=True, slots=True)
class RunPaths:
    root: Path
    run_id: str

    @classmethod
    def for_run(cls, run_id: str, state_root: Path = STATE_ROOT) -> "RunPaths":
        validate_run_id(run_id)
        return cls(root=state_root.resolve(strict=False) / "runs" / run_id, run_id=run_id)

    @property
    def work(self) -> Path:
        return self.root / "work"

    @property
    def frozen_harness(self) -> Path:
        return self.root / "frozen-harness"

    @property
    def evidence(self) -> Path:
        return self.root / "evidence"

    @property
    def fixture_bundles(self) -> Path:
        return self.evidence / "fixture-bundles"

    @property
    def cleanup(self) -> Path:
        return self.root / "cleanup"

    @property
    def state_file(self) -> Path:
        return self.work / "state.json"

    def create(self) -> None:
        ensure_no_symlink_ancestors(self.root)
        for directory in (
            self.root,
            self.work,
            self.frozen_harness,
            self.evidence,
            self.fixture_bundles,
            self.cleanup,
        ):
            ensure_private_directory(directory)
