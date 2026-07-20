from __future__ import annotations

from typing import Callable, Iterable

from lib.model import CleanupDisposition, CleanupRecord, ContractError


REQUIRED_ABSENCE = (
    "codex_instance",
    "claude_instance",
    "codex_instance_directory",
    "claude_instance_directory",
    "codex_root_disk",
    "claude_root_disk",
    "lima_home",
    "staging",
    "quarantine",
    "raw_tmp",
    "listener",
    "launchagent_job",
)

def verify_cleanup(
    run_id: str,
    seal_digest: str,
    observations: dict[str, str],
    *,
    account_revoke_required: bool,
    revoke_human_confirmed: bool,
    manual_reason_code: str | None = None,
    diagnostics: dict[str, str] | None = None,
) -> CleanupRecord:
    missing = sorted(set(REQUIRED_ABSENCE).difference(observations))
    invalid = sorted(
        key for key in REQUIRED_ABSENCE if observations.get(key) not in {"ABSENT", "UNKNOWN", "PRESENT"}
    )
    if missing or invalid:
        raise ContractError(f"cleanup observations incomplete missing={missing} invalid={invalid}")
    all_absent = all(observations[key] == "ABSENT" for key in REQUIRED_ABSENCE)
    verified = (
        all_absent
        and manual_reason_code is None
        and (not account_revoke_required or revoke_human_confirmed)
    )
    return CleanupRecord(
        run_id=run_id,
        seal_digest=seal_digest,
        disposition=(
            CleanupDisposition.CLEANUP_VERIFIED
            if verified
            else CleanupDisposition.CLEANUP_MANUAL_REQUIRED
        ),
        cleanup_verified=verified,
        account_revoke_required=account_revoke_required,
        observations=observations,
        manual_reason_code=manual_reason_code,
        diagnostics=diagnostics or {},
    )


def collect_absence(
    checks: Iterable[tuple[str, Callable[[], bool | None]]],
    *,
    diagnostics: dict[str, str] | None = None,
) -> dict[str, str]:
    observations: dict[str, str] = {}
    for name, check in checks:
        try:
            result = check()
        except Exception as exc:
            if diagnostics is not None:
                diagnostics[name] = type(exc).__name__
            result = None
        observations[name] = "ABSENT" if result is True else "PRESENT" if result is False else "UNKNOWN"
    return observations
