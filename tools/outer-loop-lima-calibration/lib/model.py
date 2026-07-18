from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import StrEnum
from typing import Iterable, Mapping


class ContractError(ValueError):
    """A fail-closed calibration contract violation."""


class ControlResult(StrEnum):
    PASS = "PASS"
    FAIL = "FAIL"
    UNKNOWN = "UNKNOWN"
    UNVERIFIED = "UNVERIFIED"


class ObservationClass(StrEnum):
    OBSERVED = "OBSERVED"
    DENIED_BY_SANDBOX = "DENIED_BY_SANDBOX"
    INGRESS_RECEIVED = "INGRESS_RECEIVED"
    INGRESS_NOT_RECEIVED = "INGRESS_NOT_RECEIVED"
    UNAVAILABLE_BASELINE = "UNAVAILABLE_BASELINE"
    SANITIZED = "SANITIZED"


class RiskDisposition(StrEnum):
    NOT_PROVIDED_ACCEPTED_RISK = "NOT_PROVIDED_ACCEPTED_RISK"


class TerminalState(StrEnum):
    RUNNING = "CALIBRATION_RUNNING"
    READY = "LIMA_CALIBRATION_READY_FOR_V3_DESIGN"
    BLOCKED = "BLOCKED"


class CleanupDisposition(StrEnum):
    NOT_STARTED = "NOT_STARTED"
    CLEANUP_PENDING = "CLEANUP_PENDING"
    CLEANUP_VERIFIED = "CLEANUP_VERIFIED"


CONTROL_IDS = tuple(f"C{number:02d}" for number in range(9))
RISK_IDS = ("AR-01", "AR-02")


@dataclass(frozen=True, slots=True)
class ControlKey:
    run_id: str
    control_id: str
    occurrence: str
    target: str

    def __post_init__(self) -> None:
        if self.control_id not in CONTROL_IDS:
            raise ContractError(f"invalid control id: {self.control_id}")
        if not all((self.run_id, self.occurrence, self.target)):
            raise ContractError("control key fields must be non-empty")

    def stable_id(self) -> str:
        return ":".join((self.run_id, self.control_id, self.occurrence, self.target))


@dataclass(frozen=True, slots=True)
class ControlRecord:
    key: ControlKey
    expected_classification: str
    observed_classification: str
    evidence_digest: str
    result: ControlResult
    operator_step: str
    exit_classification: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.result, ControlResult):
            raise ContractError("control result must be a ControlResult")
        if self.observed_classification == ObservationClass.UNAVAILABLE_BASELINE:
            if self.result is ControlResult.PASS:
                raise ContractError("unavailable baseline cannot be a passing denial")
        if not all(
            (
                self.expected_classification,
                self.observed_classification,
                self.evidence_digest,
                self.operator_step,
            )
        ):
            raise ContractError("control record fields must be non-empty")

    def to_dict(self) -> dict[str, object]:
        data = asdict(self)
        data["record_type"] = "control"
        data["key"]["stable_id"] = self.key.stable_id()
        return data


@dataclass(frozen=True, slots=True)
class RiskAcceptanceRecord:
    run_id: str
    risk_id: str
    statement: str
    constraints_digest: str
    disposition: RiskDisposition

    def __post_init__(self) -> None:
        if self.risk_id not in RISK_IDS:
            raise ContractError(f"invalid accepted risk id: {self.risk_id}")
        if not isinstance(self.disposition, RiskDisposition):
            raise ContractError("risk disposition must be a RiskDisposition")
        if not all((self.run_id, self.statement, self.constraints_digest)):
            raise ContractError("risk acceptance fields must be non-empty")

    def to_dict(self) -> dict[str, object]:
        return {"record_type": "risk_acceptance", **asdict(self)}


@dataclass(frozen=True, slots=True)
class ApprovalRecord:
    run_id: str
    gate: str
    target_digest: str
    approved_at: str
    operator_input_digest: str

    def __post_init__(self) -> None:
        if not all(
            (self.run_id, self.gate, self.target_digest, self.approved_at, self.operator_input_digest)
        ):
            raise ContractError("approval fields must be non-empty")

    def to_dict(self) -> dict[str, object]:
        return {"record_type": "approval", **asdict(self)}


@dataclass(frozen=True, slots=True)
class CleanupRecord:
    run_id: str
    seal_digest: str
    disposition: CleanupDisposition
    cleanup_verified: bool
    account_revoke_required: bool
    observations: Mapping[str, str]

    def __post_init__(self) -> None:
        if not isinstance(self.disposition, CleanupDisposition):
            raise ContractError("cleanup disposition must be a CleanupDisposition")
        if self.cleanup_verified != (self.disposition is CleanupDisposition.CLEANUP_VERIFIED):
            raise ContractError("cleanup verification and disposition disagree")
        if not self.run_id or not self.seal_digest:
            raise ContractError("cleanup record must bind run and seal")

    def to_dict(self) -> dict[str, object]:
        return {"record_type": "cleanup", **asdict(self)}


@dataclass(frozen=True, slots=True)
class AggregateResult:
    terminal: TerminalState
    real_task_allowed: bool
    records: tuple[ControlRecord, ...]


def aggregate_controls(
    records: Iterable[ControlRecord], required_keys: Iterable[ControlKey]
) -> AggregateResult:
    materialized = tuple(records)
    for record in materialized:
        if type(record) is not ControlRecord:
            raise ContractError("control aggregator accepts only ControlRecord")

    by_id: dict[str, ControlRecord] = {}
    for record in materialized:
        stable_id = record.key.stable_id()
        if stable_id in by_id:
            raise ContractError(f"duplicate control record: {stable_id}")
        by_id[stable_id] = record

    required = tuple(required_keys)
    missing = [key.stable_id() for key in required if key.stable_id() not in by_id]
    unexpected = sorted(set(by_id).difference(key.stable_id() for key in required))
    all_pass = not missing and not unexpected and all(
        by_id[key.stable_id()].result is ControlResult.PASS for key in required
    )
    return AggregateResult(
        terminal=TerminalState.READY if all_pass else TerminalState.BLOCKED,
        real_task_allowed=False,
        records=materialized,
    )
