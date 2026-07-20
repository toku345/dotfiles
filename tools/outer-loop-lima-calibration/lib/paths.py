from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from lib.model import ContractError, LimaHomeBindingRecord, RUNTIME_SCHEMA_VERSION


RUN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{7,63}$")
STATE_ROOT = Path.home() / ".local/state/outer-loop/lima-prearm/v1"
DEFAULT_LIMA_POOL_ROOT = Path.home() / ".local/state/ol"
POOL_BINDING_DOMAIN = b"outer-loop-lima-pool-binding-v1\0"
TOKEN_LENGTH = 10


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


def _lstat(path: Path) -> os.stat_result | None:
    try:
        return path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ContractError(f"path identity unavailable: {path}") from exc


def ensure_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ContractError(f"not a real directory: {path}")
    if stat.S_IMODE(info.st_mode) != 0o700:
        os.chmod(path, 0o700)


def validate_private_directory(path: Path) -> os.stat_result:
    info = _lstat(path)
    if info is None or not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ContractError(f"private directory is missing or unsafe: {path}")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ContractError(f"private directory owner or mode drifted: {path}")
    return info


def ensure_no_symlink_ancestors(path: Path, *, stop: Path | None = None) -> None:
    if not path.is_absolute():
        raise ContractError(f"path must be absolute: {path}")
    absolute = Path(os.path.abspath(path))
    limit = Path(os.path.abspath(stop)) if stop else Path(absolute.anchor)
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
        info = _lstat(candidate)
        if info is not None and stat.S_ISLNK(info.st_mode):
            raise ContractError(f"symlink ancestor rejected: {candidate}")


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def derive_lima_home_token(state_root: Path, run_id: str) -> str:
    validate_run_id(run_id)
    state_path = Path(state_root)
    if not state_path.is_absolute():
        raise ContractError("state root must be absolute")
    state_bytes = os.fsencode(Path(os.path.abspath(state_path)))
    digest = hashlib.sha256(POOL_BINDING_DOMAIN + state_bytes + b"\0" + run_id.encode("ascii"))
    encoded = base64.b32encode(digest.digest()).decode("ascii").lower().rstrip("=")
    return encoded[:TOKEN_LENGTH]


def _canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"


def _write_exclusive(path: Path, payload: object, mode: int = 0o600) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        os.write(descriptor, _canonical_json(payload))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@dataclass(frozen=True, slots=True)
class RunPaths:
    root: Path
    run_id: str
    state_root: Path
    lima_pool_root: Path
    lima_home_token: str

    @classmethod
    def for_run(
        cls,
        run_id: str,
        state_root: Path = STATE_ROOT,
        lima_pool_root: Path | None = None,
    ) -> "RunPaths":
        validate_run_id(run_id)
        state_path = Path(state_root)
        if not state_path.is_absolute():
            raise ContractError("state root must be absolute")
        ensure_no_symlink_ancestors(state_path)
        canonical_state = Path(os.path.abspath(state_path))
        if lima_pool_root is None:
            if canonical_state != Path(os.path.abspath(STATE_ROOT)):
                raise ContractError("custom state root requires explicit Lima pool root")
            lima_pool_root = DEFAULT_LIMA_POOL_ROOT
        pool_path = Path(lima_pool_root)
        if not pool_path.is_absolute():
            raise ContractError("Lima pool root must be absolute")
        ensure_no_symlink_ancestors(pool_path)
        canonical_pool = Path(os.path.abspath(pool_path))
        token = derive_lima_home_token(canonical_state, run_id)
        return cls(
            root=canonical_state / "runs" / run_id,
            run_id=run_id,
            state_root=canonical_state,
            lima_pool_root=canonical_pool,
            lima_home_token=token,
        )

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

    @property
    def lima_home(self) -> Path:
        return self.lima_pool_root / self.lima_home_token

    @property
    def binding_registry(self) -> Path:
        return self.lima_pool_root / ".bindings" / f"{self.lima_home_token}.json"

    def socket_path_lengths(self, instance_names: tuple[str, ...]) -> dict[str, int]:
        longest_socket = "ssh.sock.1234567890123456"
        return {
            name: len(os.fsencode(self.lima_home / name / longest_socket))
            for name in instance_names
        }

    def validate_socket_budget(self, instance_names: tuple[str, ...]) -> dict[str, int]:
        lengths = self.socket_path_lengths(instance_names)
        invalid = {name: size for name, size in lengths.items() if size > 95 or size >= 104}
        if invalid:
            raise ContractError(f"Lima socket path budget exceeded: {invalid}")
        return lengths

    def _prepare_pool(self, *, allow_pool_create: bool) -> None:
        ensure_no_symlink_ancestors(self.lima_pool_root)
        if _lstat(self.lima_pool_root) is None:
            if not allow_pool_create:
                raise ContractError("explicit Lima pool root must already exist")
            self.lima_pool_root.mkdir(mode=0o700, parents=True, exist_ok=False)
        validate_private_directory(self.lima_pool_root)
        bindings = self.lima_pool_root / ".bindings"
        if _lstat(bindings) is None:
            bindings.mkdir(mode=0o700)
        validate_private_directory(bindings)

    def allocate_lima_home(
        self,
        *,
        allow_pool_create: bool,
        instance_names: tuple[str, ...],
    ) -> LimaHomeBindingRecord:
        self.validate_socket_budget(instance_names)
        self._prepare_pool(allow_pool_create=allow_pool_create)
        lock_path = self.lima_pool_root / ".pool.lock"
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            lock_info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(lock_info.st_mode)
                or lock_info.st_uid != os.getuid()
                or stat.S_IMODE(lock_info.st_mode) != 0o600
                or lock_info.st_nlink != 1
            ):
                raise ContractError("Lima pool lock identity is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            if _lstat(self.binding_registry) is not None or _lstat(self.lima_home) is not None:
                raise ContractError("Lima home token is already allocated and cannot be reused")
            self.lima_home.mkdir(mode=0o700)
            pool_info = validate_private_directory(self.lima_pool_root)
            home_info = validate_private_directory(self.lima_home)
            binding_fields = {
                "run_id": self.run_id,
                "state_root": str(self.state_root),
                "logical_run_root": str(self.root),
                "lima_pool_root": str(self.lima_pool_root),
                "token": self.lima_home_token,
                "lima_home": str(self.lima_home),
                "pool_device": pool_info.st_dev,
                "pool_inode": pool_info.st_ino,
                "home_device": home_info.st_dev,
                "home_inode": home_info.st_ino,
                "owner_uid": home_info.st_uid,
                "mode": stat.S_IMODE(home_info.st_mode),
            }
            digest_input = {"schema_version": RUNTIME_SCHEMA_VERSION, **binding_fields}
            binding = LimaHomeBindingRecord(
                **(
                    binding_fields
                    | {
                        "binding_digest": hashlib.sha256(
                            _canonical_json(digest_input)
                        ).hexdigest()
                    }
                )
            )
            _write_exclusive(self.binding_registry, binding.to_dict())
            return binding
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def read_binding_registry(self, expected: dict[str, object]) -> dict[str, object]:
        info = _lstat(self.binding_registry)
        if (
            info is None
            or not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            raise ContractError("Lima home binding registry identity is unsafe")
        try:
            descriptor = os.open(self.binding_registry, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                before = os.fstat(descriptor)
                data = bytearray()
                while chunk := os.read(descriptor, 65536):
                    data.extend(chunk)
                after = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            if (
                (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                or (before.st_dev, before.st_ino) != (info.st_dev, info.st_ino)
            ):
                raise ContractError("Lima home binding registry changed during read")
            registry = json.loads(data)
        except (OSError, json.JSONDecodeError) as exc:
            raise ContractError("Lima home binding registry is unavailable") from exc
        if not isinstance(registry, dict) or registry != expected:
            raise ContractError("Lima home binding registry drifted")
        return registry

    def validate_lima_home_binding(self, expected: dict[str, object]) -> LimaHomeBindingRecord:
        registry = self.read_binding_registry(expected)
        pool_info = validate_private_directory(self.lima_pool_root)
        home_info = validate_private_directory(self.lima_home)
        binding = LimaHomeBindingRecord(
            run_id=registry.get("run_id", ""),
            state_root=registry.get("state_root", ""),
            logical_run_root=registry.get("logical_run_root", ""),
            lima_pool_root=registry.get("lima_pool_root", ""),
            token=registry.get("token", ""),
            lima_home=registry.get("lima_home", ""),
            pool_device=registry.get("pool_device", -1),
            pool_inode=registry.get("pool_inode", -1),
            home_device=registry.get("home_device", -1),
            home_inode=registry.get("home_inode", -1),
            owner_uid=registry.get("owner_uid", -1),
            mode=registry.get("mode", -1),
            binding_digest=registry.get("binding_digest", ""),
        )
        if (
            binding.run_id != self.run_id
            or binding.state_root != str(self.state_root)
            or binding.logical_run_root != str(self.root)
            or binding.lima_pool_root != str(self.lima_pool_root)
            or binding.token != self.lima_home_token
            or binding.lima_home != str(self.lima_home)
            or binding.pool_device != pool_info.st_dev
            or binding.pool_inode != pool_info.st_ino
            or binding.home_device != home_info.st_dev
            or binding.home_inode != home_info.st_ino
            or binding.owner_uid != os.getuid()
            or binding.mode != 0o700
        ):
            raise ContractError("Lima home binding identity drifted")
        return binding

    def create_logical_run(self) -> None:
        ensure_no_symlink_ancestors(self.root)
        if _lstat(self.root) is not None:
            raise ContractError("run id already exists and cannot be retried")
        ensure_private_directory(self.state_root)
        runs = self.state_root / "runs"
        ensure_private_directory(runs)
        self.root.mkdir(mode=0o700)
        for directory in (
            self.work,
            self.frozen_harness,
            self.evidence,
            self.fixture_bundles,
            self.cleanup,
        ):
            directory.mkdir(mode=0o700, parents=True, exist_ok=False)

    def create(
        self,
        *,
        allow_pool_create: bool | None = None,
        instance_names: tuple[str, ...] = (),
    ) -> LimaHomeBindingRecord:
        if allow_pool_create is None:
            allow_pool_create = self.lima_pool_root == Path(os.path.abspath(DEFAULT_LIMA_POOL_ROOT))
        binding = self.allocate_lima_home(
            allow_pool_create=allow_pool_create,
            instance_names=instance_names,
        )
        self.create_logical_run()
        return binding
