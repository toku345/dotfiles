from __future__ import annotations

import plistlib
import shlex
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
    run_id: str,
    deadline: str,
) -> str:
    if not python_executable.is_absolute() or not calibrate.is_absolute() or not state_root.is_absolute():
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
                f"{shlex.quote(str(state_root))} cleanup {shlex.quote(run_id)} --cause deadline"
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
