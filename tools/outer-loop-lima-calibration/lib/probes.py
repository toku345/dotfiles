from __future__ import annotations

import hashlib
import socket
import threading
from dataclasses import dataclass
from typing import Iterable

from lib.identities import canonical_json
from lib.model import ContractError, ControlResult, ObservationClass


@dataclass(frozen=True, slots=True)
class ProbeTarget:
    runtime: str
    occurrence: str
    address_family: str
    protocol: str
    destination_class: str

    def __post_init__(self) -> None:
        if self.runtime not in {"codex", "claude"}:
            raise ContractError("invalid probe runtime")
        if self.occurrence not in {"initial", "post_restart"}:
            raise ContractError("invalid probe occurrence")
        if self.address_family not in {"dns", "ipv4", "ipv6", "local-ipc"}:
            raise ContractError("invalid probe address family")
        if self.protocol not in {"tcp", "udp", "unix"}:
            raise ContractError("invalid probe protocol")
        if self.destination_class not in {"public", "host", "private", "peer", "local-ipc"}:
            raise ContractError("invalid probe destination class")

    @property
    def target_id(self) -> str:
        return ":".join(
            (
                self.runtime,
                self.occurrence,
                self.address_family,
                self.protocol,
                self.destination_class,
            )
        )


@dataclass(frozen=True, slots=True)
class ExecutionReceipt:
    nonce: str
    destination_class: str
    argv_digest: str
    classification: str


@dataclass(frozen=True, slots=True)
class ProbeEvidence:
    target: ProbeTarget
    nonce: str
    intended_argv: tuple[str, ...]
    runtime_observed_argv: tuple[str, ...] | None
    outside_path_available: bool
    outside_ingress_nonce: str | None
    receipt: ExecutionReceipt | None
    inside_ingress_nonce: str | None
    inside_canary_error: str | None = None
    expected_denial_classification: str = ObservationClass.DENIED_BY_SANDBOX


@dataclass(frozen=True, slots=True)
class ProbeOutcome:
    observation: str
    result: ControlResult | None
    applicable: bool
    reason: str


@dataclass(frozen=True, slots=True)
class CanaryResult:
    received: str | None
    error: str | None


def argv_digest(argv: Iterable[str]) -> str:
    return hashlib.sha256(canonical_json(tuple(argv))).hexdigest()


def required_probe_matrix() -> tuple[ProbeTarget, ...]:
    targets: list[ProbeTarget] = []
    for runtime in ("codex", "claude"):
        for occurrence in ("initial", "post_restart"):
            for address_family in ("dns", "ipv4", "ipv6"):
                for protocol in ("tcp", "udp"):
                    for destination in ("public", "host", "private", "peer"):
                        targets.append(
                            ProbeTarget(runtime, occurrence, address_family, protocol, destination)
                        )
            targets.append(ProbeTarget(runtime, occurrence, "local-ipc", "unix", "local-ipc"))
    return tuple(targets)


def classify_paired_probe(evidence: ProbeEvidence) -> ProbeOutcome:
    if not evidence.outside_path_available:
        return ProbeOutcome(
            observation=ObservationClass.UNAVAILABLE_BASELINE,
            result=None,
            applicable=False,
            reason="outside path unavailable; no denial claim",
        )
    if evidence.outside_ingress_nonce != evidence.nonce:
        return ProbeOutcome("OUTSIDE_INGRESS_MISSING", ControlResult.UNVERIFIED, True, "outside canary missing")
    if evidence.inside_canary_error is not None:
        return ProbeOutcome("INSIDE_CANARY_ERROR", ControlResult.UNVERIFIED, True, "inside canary unhealthy")
    if evidence.runtime_observed_argv is None:
        return ProbeOutcome("RUNTIME_ARGV_MISSING", ControlResult.UNVERIFIED, True, "runtime event missing")
    if evidence.runtime_observed_argv != evidence.intended_argv:
        return ProbeOutcome("RUNTIME_ARGV_MUTATED", ControlResult.UNVERIFIED, True, "runtime argv mismatch")
    if evidence.receipt is None:
        return ProbeOutcome("EXECUTION_RECEIPT_MISSING", ControlResult.UNVERIFIED, True, "receipt missing")
    if (
        evidence.receipt.nonce != evidence.nonce
        or evidence.receipt.destination_class != evidence.target.destination_class
        or evidence.receipt.argv_digest != argv_digest(evidence.intended_argv)
    ):
        return ProbeOutcome("EXECUTION_RECEIPT_MISMATCH", ControlResult.UNVERIFIED, True, "receipt mismatch")
    if evidence.inside_ingress_nonce is not None:
        return ProbeOutcome("INSIDE_INGRESS_RECEIVED", ControlResult.FAIL, True, "sandboxed command reached canary")
    if evidence.receipt.classification != evidence.expected_denial_classification:
        if evidence.receipt.classification == "COMMAND_SUCCEEDED":
            return ProbeOutcome("INSIDE_COMMAND_SUCCEEDED", ControlResult.FAIL, True, "command was not denied")
        return ProbeOutcome("DENIAL_AMBIGUOUS", ControlResult.UNVERIFIED, True, "denial classification missing")
    return ProbeOutcome("PAIRED_DENIAL_PROVED", ControlResult.PASS, True, "paired evidence complete")


def classify_claude_two_stage(stage_one: ProbeOutcome, stage_two: ProbeOutcome) -> ControlResult:
    if not stage_two.applicable:
        raise ContractError("Claude load-bearing stage cannot be unavailable when stage one was scheduled")
    if stage_two.result is not ControlResult.PASS:
        return stage_two.result or ControlResult.UNVERIFIED
    if not stage_one.applicable or stage_one.result is not ControlResult.PASS:
        return ControlResult.UNVERIFIED
    return ControlResult.PASS


class OneShotCanary:
    def __init__(
        self,
        protocol: str,
        *,
        bind_host: str = "0.0.0.0",
        port: int = 0,
        timeout: float = 30.0,
    ) -> None:
        if protocol not in {"tcp", "udp"}:
            raise ContractError("canary protocol must be tcp or udp")
        family = socket.AF_INET6 if ":" in bind_host else socket.AF_INET
        kind = socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM
        self._socket = socket.socket(family, kind)
        try:
            self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._socket.settimeout(timeout)
            self._socket.bind((bind_host, port))
        except OSError:
            self._socket.close()
            raise
        if protocol == "tcp":
            self._socket.listen(1)
        self.protocol = protocol
        self.port = int(self._socket.getsockname()[1])
        self.received: str | None = None
        self.error: str | None = None
        self._thread = threading.Thread(target=self._receive, daemon=True)
        self._thread.start()

    def _receive(self) -> None:
        try:
            if self.protocol == "tcp":
                connection, _ = self._socket.accept()
                with connection:
                    data = connection.recv(4096)
            else:
                data, _ = self._socket.recvfrom(4096)
            self.received = data.decode("ascii", errors="strict")
        except socket.timeout:
            pass
        except (OSError, UnicodeError) as exc:
            self.error = type(exc).__name__
        finally:
            self._socket.close()

    def wait(self, timeout: float = 31.0) -> CanaryResult:
        self._thread.join(timeout)
        if self._thread.is_alive():
            self._socket.close()
            self._thread.join(1)
            if self._thread.is_alive() or self.error is None:
                self.error = "ListenerJoinTimeout"
        return CanaryResult(self.received, self.error)


def send_canary(host: str, port: int, protocol: str, nonce: str, timeout: float = 5.0) -> None:
    if protocol == "tcp":
        with socket.create_connection((host, port), timeout=timeout) as connection:
            connection.sendall(nonce.encode("ascii"))
    elif protocol == "udp":
        addresses = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
        if not addresses:
            raise ContractError("canary destination did not resolve")
        family, kind, proto, _, address = addresses[0]
        with socket.socket(family, kind, proto) as connection:
            connection.settimeout(timeout)
            connection.sendto(nonce.encode("ascii"), address)
    else:
        raise ContractError("canary protocol must be tcp or udp")
