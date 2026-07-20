from __future__ import annotations

import os
import plistlib
import shlex
import stat
from datetime import UTC, datetime, timedelta
from pathlib import Path

from lib.model import ContractError
from lib.paths import parse_utc_deadline, validate_run_id


LABEL_PREFIX = "com.toku345.outer-loop-lima-cleanup"


def cleanup_due(deadline: str, now: datetime | None = None) -> bool:
    parsed = parse_utc_deadline(deadline)
    current = now or datetime.now(UTC)
    if current.tzinfo is None:
        raise ContractError("cleanup clock must be timezone-aware")
    return current.astimezone(UTC) >= parsed


def launch_agent_payload(run_id: str, deadline: str, script: Path) -> dict[str, object]:
    validate_run_id(run_id)
    parsed = parse_utc_deadline(deadline).astimezone()
    scheduled = parsed if parsed.second == 0 else parsed.replace(second=0) + timedelta(minutes=1)
    if not script.is_absolute():
        raise ContractError("cleanup script path must be absolute")
    return {
        "Label": f"{LABEL_PREFIX}.{run_id}",
        "ProgramArguments": [str(script)],
        "RunAtLoad": True,
        "StartCalendarInterval": {
            "Month": scheduled.month,
            "Day": scheduled.day,
            "Hour": scheduled.hour,
            "Minute": scheduled.minute,
        },
        "StartInterval": 3600,
        "ProcessType": "Background",
    }


def render_launch_agent(run_id: str, deadline: str, script: Path) -> bytes:
    return plistlib.dumps(launch_agent_payload(run_id, deadline, script), sort_keys=True)


def render_deadline_wrapper(
    python_executable: Path,
    calibrate: Path,
    state_root: Path,
    lima_pool_root: Path,
    run_id: str,
    deadline: str,
) -> str:
    if (
        not python_executable.is_absolute()
        or not calibrate.is_absolute()
        or not state_root.is_absolute()
        or not lima_pool_root.is_absolute()
    ):
        raise ContractError("retention wrapper paths must be absolute")
    validate_run_id(run_id)
    parse_utc_deadline(deadline)
    return "\n".join(
        (
            "#!/bin/sh",
            "set -eu",
            f"readonly DEADLINE={shlex.quote(deadline)}",
            "deadline_epoch=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \"$DEADLINE\" '+%s')",
            "now_epoch=$(/bin/date -u '+%s')",
            '[ "$now_epoch" -lt "$deadline_epoch" ] && exit 0',
            (
                f"exec {shlex.quote(str(python_executable))} {shlex.quote(str(calibrate))} --state-root "
                f"{shlex.quote(str(state_root))} --lima-pool-root "
                f"{shlex.quote(str(lima_pool_root))} cleanup {shlex.quote(run_id)} --cause deadline"
            ),
            "",
        )
    )


def launchctl_commands(run_id: str, plist: Path, uid: int) -> tuple[tuple[str, ...], ...]:
    label = f"{LABEL_PREFIX}.{validate_run_id(run_id)}"
    domain = f"gui/{uid}"
    return (
        ("launchctl", "bootstrap", domain, str(plist)),
        ("launchctl", "print", f"{domain}/{label}"),
        ("launchctl", "kickstart", f"{domain}/{label}"),
    )


def validate_wrapper_readback(path: Path, expected: str) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(descriptor)
            data = bytearray()
            while chunk := os.read(descriptor, 65536):
                data.extend(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except OSError as exc:
        raise ContractError("retention wrapper read-back failed") from exc
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or stat.S_IMODE(before.st_mode) != 0o700
        or before.st_nlink != 1
        or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        or bytes(data) != expected.encode()
    ):
        raise ContractError("retention wrapper read-back drifted")


def validate_launchctl_print_readback(
    output: str,
    *,
    target: str,
    plist: Path,
    wrapper: Path,
) -> None:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    required_lines = (
        f"{target} = {{",
        f"path = {plist}",
        f"program = {wrapper}",
    )
    if any(lines.count(line) != 1 for line in required_lines):
        raise ContractError("LaunchAgent identity read-back drifted")
    argument_markers = [index for index, line in enumerate(lines) if line == "arguments = {"]
    if len(argument_markers) != 1:
        raise ContractError("LaunchAgent arguments read-back was missing")
    start = argument_markers[0] + 1
    try:
        end = lines.index("}", start)
    except ValueError as exc:
        raise ContractError("LaunchAgent arguments read-back was incomplete") from exc
    if lines[start:end] != [str(wrapper)]:
        raise ContractError("LaunchAgent program arguments drifted")
