from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import StrEnum
from typing import Iterable, Mapping


RUNTIME_SCHEMA_VERSION = 2


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
    CLEANUP_MANUAL_REQUIRED = "CLEANUP_MANUAL_REQUIRED"
    CLEANUP_VERIFIED = "CLEANUP_VERIFIED"


class CleanupManualReason(StrEnum):
    ORPHANED_OPERATION = "ORPHANED_OPERATION"
    LIMA_LIST_UNKNOWN = "LIMA_LIST_UNKNOWN"
    LIMA_HOME_UNRELATED_ENTRIES = "LIMA_HOME_UNRELATED_ENTRIES"
    PROVISION_NOT_AUTOMATIC_CLEANUP_ELIGIBLE = (
        "PROVISION_NOT_AUTOMATIC_CLEANUP_ELIGIBLE"
    )
    INSTANCE_DIRECTORY_LIST_MISMATCH = "INSTANCE_DIRECTORY_LIST_MISMATCH"
    LIVE_IDENTITY_NOT_RECORDED = "LIVE_IDENTITY_NOT_RECORDED"
    PRE_STOP_IDENTITY_MISMATCH = "PRE_STOP_IDENTITY_MISMATCH"
    LIMA_STOP_FAILED = "LIMA_STOP_FAILED"
    POST_STOP_IDENTITY_MISMATCH = "POST_STOP_IDENTITY_MISMATCH"
    PRE_DELETE_IDENTITY_MISMATCH = "PRE_DELETE_IDENTITY_MISMATCH"
    LIMA_DELETE_FAILED = "LIMA_DELETE_FAILED"
    POST_DELETE_NAMESPACE_NOT_ABSENT = "POST_DELETE_NAMESPACE_NOT_ABSENT"
    POST_DELETE_FIXED_PATH_PRESENT = "POST_DELETE_FIXED_PATH_PRESENT"
    PHYSICAL_LIMA_HOME_NOT_EMPTY = "PHYSICAL_LIMA_HOME_NOT_EMPTY"
    PROVISIONED_HOME_REQUIRES_MANUAL_VERIFICATION = (
        "PROVISIONED_HOME_REQUIRES_MANUAL_VERIFICATION"
    )
    LIMA_HOME_RMDIR_FAILED = "LIMA_HOME_RMDIR_FAILED"
    LIMA_HOME_REMAINED = "LIMA_HOME_REMAINED"
    RETENTION_DISABLE_FAILED = "RETENTION_DISABLE_FAILED"
    OBSERVATION_INCONCLUSIVE = "OBSERVATION_INCONCLUSIVE"
    HUMAN_DISPOSITION_REQUIRED = "HUMAN_DISPOSITION_REQUIRED"
    ATTESTATION_NOT_VERIFIED = "ATTESTATION_NOT_VERIFIED"


class LimaListDisposition(StrEnum):
    ABSENT = "ABSENT"
    RECOGNIZED = "RECOGNIZED"
    UNKNOWN = "UNKNOWN"


class ProvisionAttemptEvent(StrEnum):
    STARTED = "STARTED"
    COMPLETED = "COMPLETED"


class ProvisionAttemptOutcome(StrEnum):
    SUCCESS = "SUCCESS"
    NONZERO = "NONZERO"
    TIMEOUT = "TIMEOUT"
    UNAVAILABLE = "UNAVAILABLE"
    IDENTITY_MISMATCH = "IDENTITY_MISMATCH"


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
        data["schema_version"] = RUNTIME_SCHEMA_VERSION
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
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "risk_acceptance",
            **asdict(self),
        }


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
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "approval",
            **asdict(self),
        }


@dataclass(frozen=True, slots=True)
class LimaIdentity:
    name: str
    status: str
    directory: str
    vm_type: str
    arch: str
    cpus: int
    memory: int
    disk: int

    def __post_init__(self) -> None:
        if not all((self.name, self.status, self.directory, self.vm_type, self.arch)):
            raise ContractError("Lima identity string fields must be non-empty")
        if self.status not in {"Stopped", "Running"}:
            raise ContractError("Lima identity status must be Stopped or Running")
        if type(self.cpus) is not int or type(self.memory) is not int or type(self.disk) is not int:
            raise ContractError("Lima identity resource fields must be exact integers")

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "lima_identity",
            **asdict(self),
        }


@dataclass(frozen=True, slots=True)
class LimaHomeBindingRecord:
    run_id: str
    state_root: str
    logical_run_root: str
    lima_pool_root: str
    token: str
    lima_home: str
    pool_device: int
    pool_inode: int
    home_device: int
    home_inode: int
    owner_uid: int
    mode: int
    binding_digest: str

    def __post_init__(self) -> None:
        if not all(
            type(value) is str
            for value in (
                self.run_id,
                self.state_root,
                self.logical_run_root,
                self.lima_pool_root,
                self.token,
                self.lima_home,
                self.binding_digest,
            )
        ):
            raise ContractError("Lima home binding string fields must be exact strings")
        if not all(
            type(value) is int
            for value in (
                self.pool_device,
                self.pool_inode,
                self.home_device,
                self.home_inode,
                self.owner_uid,
                self.mode,
            )
        ):
            raise ContractError("Lima home binding identity fields must be exact integers")
        if not all(
            (
                self.run_id,
                self.state_root,
                self.logical_run_root,
                self.lima_pool_root,
                self.token,
                self.lima_home,
                self.binding_digest,
            )
        ):
            raise ContractError("Lima home binding fields must be non-empty")
        if len(self.token) != 10 or len(self.binding_digest) != 64:
            raise ContractError("Lima home binding token or digest is invalid")
        if self.mode != 0o700:
            raise ContractError("Lima home binding mode must be 0700")

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "lima_home_binding",
            **asdict(self),
        }


@dataclass(frozen=True, slots=True)
class ProvisionAttemptRecord:
    run_id: str
    runtime: str
    action: str
    event: ProvisionAttemptEvent
    command_digest: str
    observed_at: str
    outcome: ProvisionAttemptOutcome | None = None

    def __post_init__(self) -> None:
        if self.runtime not in {"codex", "claude"} or self.action not in {"create", "start"}:
            raise ContractError("invalid provision attempt target")
        if not isinstance(self.event, ProvisionAttemptEvent):
            raise ContractError("invalid provision attempt event")
        if len(self.command_digest) != 64 or not self.run_id or not self.observed_at:
            raise ContractError("provision attempt fields must be non-empty")
        if self.event is ProvisionAttemptEvent.STARTED and self.outcome is not None:
            raise ContractError("STARTED provision attempt cannot have an outcome")
        if self.event is ProvisionAttemptEvent.COMPLETED and not isinstance(
            self.outcome, ProvisionAttemptOutcome
        ):
            raise ContractError("COMPLETED provision attempt requires an outcome")

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "provision_attempt",
            **asdict(self),
        }


@dataclass(frozen=True, slots=True)
class CleanupRecord:
    run_id: str
    seal_digest: str
    disposition: CleanupDisposition
    cleanup_verified: bool
    account_revoke_required: bool
    observations: Mapping[str, str]
    manual_reason_code: str | None = None
    diagnostics: Mapping[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not isinstance(self.disposition, CleanupDisposition):
            raise ContractError("cleanup disposition must be a CleanupDisposition")
        if self.cleanup_verified != (self.disposition is CleanupDisposition.CLEANUP_VERIFIED):
            raise ContractError("cleanup verification and disposition disagree")
        if not self.run_id or not self.seal_digest:
            raise ContractError("cleanup record must bind run and seal")
        if self.manual_reason_code is not None:
            if type(self.manual_reason_code) is not str:
                raise ContractError("cleanup manual reason code must be a string")
            try:
                CleanupManualReason(self.manual_reason_code)
            except ValueError as exc:
                raise ContractError("cleanup manual reason code is not allowlisted") from exc
            if self.cleanup_verified:
                raise ContractError("verified cleanup cannot retain a manual reason")
        if not set(self.diagnostics).issubset(self.observations):
            raise ContractError("cleanup diagnostics must identify observed checks")
        if any(not value for value in self.diagnostics.values()):
            raise ContractError("cleanup diagnostics must be non-empty")

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "cleanup",
            **asdict(self),
        }


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
