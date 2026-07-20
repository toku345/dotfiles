from __future__ import annotations

import errno
import fcntl
import hashlib
import ipaddress
import json
import os
import platform
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Callable, Iterable, Protocol, Sequence

from lib.evidence import (
    append_jsonl,
    record_control,
    record_decision,
    record_provision_attempt,
    seal,
    seal_input_digest,
    write_once,
)
from lib.export_validator import freeze_bundle, stable_inventory, validate_quarantine
from lib.cleanup import REQUIRED_ABSENCE, collect_absence, verify_cleanup
from lib.identities import (
    canonical_json,
    load_json,
    sha256_file,
    validate_manifest,
    validate_versions_lock,
    verify_binary_identity,
)
from lib.lima_state import (
    CLAUDE_INSTANCE,
    CODEX_INSTANCE,
    FIXED_INSTANCES,
    LimaListSnapshot,
    fixed_identity_map,
    inspect_top_level,
    parse_lima_list,
    parser_contract_digest,
    path_disposition,
    validate_expected_identity,
)
from lib.model import (
    ApprovalRecord,
    ContractError,
    ControlKey,
    ControlRecord,
    ControlResult,
    ObservationClass,
    CleanupDisposition,
    LimaIdentity,
    LimaListDisposition,
    ProvisionAttemptEvent,
    ProvisionAttemptOutcome,
    ProvisionAttemptRecord,
    RiskAcceptanceRecord,
    RiskDisposition,
    RUNTIME_SCHEMA_VERSION,
    TerminalState,
    aggregate_controls,
)
from lib.paths import (
    DEFAULT_LIMA_POOL_ROOT,
    RunPaths,
    ensure_private_directory,
    parse_utc_deadline,
    validate_run_id,
)
from lib.probes import (
    ExecutionReceipt,
    OneShotCanary,
    ProbeEvidence,
    ProbeOutcome,
    classify_claude_two_stage,
    classify_paired_probe,
    required_probe_matrix,
)
from lib.retention import (
    LABEL_PREFIX,
    launchctl_commands,
    render_deadline_wrapper,
    render_launch_agent,
    validate_launchctl_print_readback,
    validate_wrapper_readback,
)
from lib.sync_guard import validate_sync_invocation


RUNTIMES = ("codex", "claude")
HANDOFF_DIRECTIONS = ("forward", "reverse")
COMPLETE_RECEIPT_PREFIX = "OUTER_LOOP_RECEIPT_COMPLETE:"
NETWORK_DENIED_EXIT = 77
NETWORK_DENIED_MARKER = "OUTER_LOOP_NETWORK_DENIED"
OPERATION_LOCK_NAME = "operation.lock"
class Phase:
    INITIALIZED = "INITIALIZED"
    PREFLIGHTED = "PREFLIGHTED"
    PRE_VM_APPROVED = "PRE_VM_APPROVED"
    PROVISIONED = "PROVISIONED"
    PRE_AUTH_APPROVED = "PRE_AUTH_APPROVED"
    CODEX_AUTHENTICATED = "CODEX_AUTHENTICATED"
    AUTHENTICATED = "AUTHENTICATED"
    ISOLATION_COMPLETE = "ISOLATION_COMPLETE"
    SYNC_EXPORT_COMPLETE = "SYNC_EXPORT_COMPLETE"
    FORWARD_APPROVED = "FORWARD_APPROVED"
    FORWARD_COMPLETE = "FORWARD_COMPLETE"
    REVERSE_APPROVED = "REVERSE_APPROVED"
    REVERSE_COMPLETE = "REVERSE_COMPLETE"
    RESTART_COMPLETE = "RESTART_COMPLETE"
    SEAL_PREPARED = "SEAL_PREPARED"
    FINAL_SEAL_APPROVED = "FINAL_SEAL_APPROVED"
    SEALED = "SEALED"
    BLOCKED = "BLOCKED"


@dataclass(frozen=True, slots=True)
class PhaseResult:
    controls: tuple[ControlRecord, ...]
    observations: tuple[dict[str, object], ...] = ()


class CalibrationDriver(Protocol):
    def provision(self, run_id: str, frozen_harness: Path) -> PhaseResult: ...

    def authenticate(self, run_id: str, runtime: str, occurrence: str) -> PhaseResult: ...

    def isolation(self, run_id: str, occurrence: str) -> PhaseResult: ...

    def sync_export(self, run_id: str) -> PhaseResult: ...

    def handoff(self, run_id: str, direction: str) -> PhaseResult: ...

    def restart(self, run_id: str) -> PhaseResult: ...

    def stop_for_seal(self, run_id: str) -> dict[str, object]: ...


class BoundedCommandError(ContractError):
    def __init__(self, command: str, classification: str) -> None:
        super().__init__(f"bounded command failed: {command}")
        self.classification = classification


class CommandRunner:
    def __init__(self, lima_home: Path) -> None:
        self.lima_home = lima_home

    def run(
        self,
        argv: Sequence[str],
        *,
        timeout: int,
        capture_output: bool = True,
        check: bool = True,
        cwd_fd: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["LIMA_HOME"] = str(self.lima_home)
        enter_pinned_directory: Callable[[], None] | None = None
        pass_fds: tuple[int, ...] = ()
        if cwd_fd is not None:
            pass_fds = (cwd_fd,)

            def enter_pinned_directory() -> None:
                os.fchdir(cwd_fd)

        try:
            return subprocess.run(
                list(argv),
                check=check,
                capture_output=capture_output,
                text=True,
                timeout=timeout,
                env=environment,
                pass_fds=pass_fds,
                preexec_fn=enter_pinned_directory,
            )
        except subprocess.TimeoutExpired as exc:
            raise BoundedCommandError(str(argv[0]), "TIMEOUT") from exc
        except OSError as exc:
            raise BoundedCommandError(str(argv[0]), "UNAVAILABLE") from exc
        except subprocess.SubprocessError as exc:
            raise BoundedCommandError(str(argv[0]), "UNAVAILABLE") from exc


class LimaDriver:
    """Live driver with fixed command construction and sanitized phase inputs.

    The live cycle supplies only endpoint addresses and TTY decisions. Raw login and
    model streams remain in guest tmpfs. Isolation and sync/export are delegated to
    fixed, manifest-bound phase documents produced by the guest and host helpers;
    this driver never accepts an arbitrary control ID.
    """

    def __init__(self, paths: RunPaths, harness_root: Path) -> None:
        self.paths = paths
        self.harness_root = harness_root
        self.repository_root = next(
            (candidate for candidate in (harness_root, *harness_root.parents) if (candidate / ".git").exists()),
            harness_root,
        )
        self.runner = CommandRunner(paths.lima_home)

    @staticmethod
    def _record(
        run_id: str,
        control_id: str,
        occurrence: str,
        target: str,
        evidence: object,
        operator_step: str,
    ) -> ControlRecord:
        return ControlRecord(
            key=ControlKey(run_id, control_id, occurrence, target),
            expected_classification="VERIFIED",
            observed_classification="VERIFIED",
            evidence_digest=hashlib.sha256(canonical_json(evidence)).hexdigest(),
            result=ControlResult.PASS,
            operator_step=operator_step,
            exit_classification="ZERO",
        )

    @staticmethod
    def _instance(runtime: str) -> str:
        if runtime == "codex":
            return CODEX_INSTANCE
        if runtime == "claude":
            return CLAUDE_INSTANCE
        raise ContractError("unknown runtime")

    def _profile(self, runtime: str) -> Path:
        return self.paths.frozen_harness / "profiles" / f"week0-{runtime}.yaml"

    def _shell(
        self,
        instance: str,
        argv: Sequence[str],
        *,
        timeout: int = 120,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return self.runner.run(
            ("limactl", "--tty=false", "shell", instance, *argv),
            timeout=timeout,
            check=check,
        )

    def _install_harness(self, runtime: str) -> None:
        instance = self._instance(runtime)
        guest_root = "/tmp/outer-loop-harness"
        self.runner.run(
            (
                "limactl",
                "--tty=false",
                "copy",
                "--backend=scp",
                "--recursive",
                str(self.paths.frozen_harness),
                f"{instance}:{guest_root}",
            ),
            timeout=300,
        )
        setup = "\n".join(
            (
                "set -eu",
                "install -d -m 0755 /usr/local/share/outer-loop/seeds /usr/local/libexec/outer-loop /etc/apparmor.d",
                "install -d -m 0755 /usr/local/share/outer-loop/harness",
                f"cp -R {guest_root}/. /usr/local/share/outer-loop/harness/",
                "chown -R root:root /usr/local/share/outer-loop/harness",
                "find /usr/local/share/outer-loop/harness -type d -exec chmod 0755 {} +",
                "find /usr/local/share/outer-loop/harness -type f -exec chmod 0644 {} +",
                "readonly H=/usr/local/share/outer-loop/harness",
                "install -m 0644 $H/versions.lock.json /usr/local/share/outer-loop/versions.lock.json",
                "install -m 0755 $H/guest/control.py /usr/local/libexec/outer-loop/control.py",
                "install -m 0755 $H/guest/sanitize-auth.py /usr/local/libexec/outer-loop/sanitize-auth.py",
                "install -m 0755 $H/guest/inspect-export.py /usr/local/libexec/outer-loop/inspect-export.py",
                "install -m 0644 $H/guest/apparmor/bwrap /etc/apparmor.d/outer-loop-bwrap",
                "install -m 0644 $H/seeds/codex/config.toml /usr/local/share/outer-loop/seeds/codex-config.toml",
                "install -m 0644 $H/seeds/codex/requirements.toml /usr/local/share/outer-loop/seeds/codex-requirements.toml",
                "install -m 0644 $H/seeds/claude/managed-settings.json /usr/local/share/outer-loop/seeds/claude-managed-settings.json",
                "install -m 0644 $H/seeds/claude/managed-mcp.json /usr/local/share/outer-loop/seeds/claude-managed-mcp.json",
                "install -m 0644 $H/seeds/claude/srt-settings.json /usr/local/share/outer-loop/seeds/claude-srt-settings.json",
                "sh $H/guest/provision-common.sh",
                f"sh $H/guest/provision-{runtime}.sh",
            )
        )
        self._shell(instance, ("sudo", "/bin/sh", "-ceu", setup), timeout=1800)

    def _list_identity(
        self,
        runtime: str,
        *,
        expected_status: str,
        stage: str,
    ) -> LimaIdentity:
        instance = self._instance(runtime)
        result = self.runner.run(
            ("limactl", "--tty=false", "list", "--all-fields", "--format=json", instance),
            timeout=30,
            check=False,
        )
        snapshot = parse_lima_list(result.returncode, result.stdout, result.stderr)
        if snapshot.disposition is not LimaListDisposition.RECOGNIZED or len(snapshot.identities) != 1:
            raise ContractError("Lima identity read-back was not exactly one recognized instance")
        identity = snapshot.identities[0]
        validate_expected_identity(
            identity,
            name=instance,
            status=expected_status,
            directory=self.paths.lima_home / instance,
        )
        append_jsonl(
            self.paths.evidence / "lima-identities.jsonl",
            identity.to_dict() | {"runtime": runtime, "stage": stage},
        )
        return identity

    def _provision_attempt(
        self,
        run_id: str,
        runtime: str,
        action: str,
        argv: tuple[str, ...],
        *,
        expected_status: str,
    ) -> LimaIdentity:
        attempt_path = self.paths.evidence / "provision-attempts.jsonl"
        if attempt_path.exists():
            try:
                for line in attempt_path.read_text(encoding="utf-8").splitlines():
                    value = json.loads(line)
                    if (
                        value.get("schema_version") != RUNTIME_SCHEMA_VERSION
                        or value.get("record_type") != "provision_attempt"
                    ):
                        raise ContractError("provision attempt evidence schema drifted")
                    if value.get("runtime") == runtime and value.get("action") == action:
                        raise ContractError("same-run provision attempt retry rejected")
            except (OSError, json.JSONDecodeError) as exc:
                raise ContractError("provision attempt evidence is unreadable") from exc
        observed_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        command_digest = hashlib.sha256(
            canonical_json(
                {
                    "argv": argv,
                    "lima_home": str(self.paths.lima_home),
                    "expected_status": expected_status,
                }
            )
        ).hexdigest()
        record_provision_attempt(
            self.paths,
            ProvisionAttemptRecord(
                run_id,
                runtime,
                action,
                ProvisionAttemptEvent.STARTED,
                command_digest,
                observed_at,
            ),
        )
        try:
            result = self.runner.run(argv, timeout=1500 if action == "create" else 720, check=False)
        except BoundedCommandError as exc:
            outcome = (
                ProvisionAttemptOutcome.TIMEOUT
                if exc.classification == "TIMEOUT"
                else ProvisionAttemptOutcome.UNAVAILABLE
            )
            record_provision_attempt(
                self.paths,
                ProvisionAttemptRecord(
                    run_id,
                    runtime,
                    action,
                    ProvisionAttemptEvent.COMPLETED,
                    command_digest,
                    datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                    outcome,
                ),
            )
            raise
        if result.returncode != 0:
            record_provision_attempt(
                self.paths,
                ProvisionAttemptRecord(
                    run_id,
                    runtime,
                    action,
                    ProvisionAttemptEvent.COMPLETED,
                    command_digest,
                    datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                    ProvisionAttemptOutcome.NONZERO,
                ),
            )
            raise ContractError(f"Lima {action} returned nonzero")
        try:
            identity = self._list_identity(
                runtime,
                expected_status=expected_status,
                stage=f"post-{action}",
            )
        except ContractError:
            record_provision_attempt(
                self.paths,
                ProvisionAttemptRecord(
                    run_id,
                    runtime,
                    action,
                    ProvisionAttemptEvent.COMPLETED,
                    command_digest,
                    datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                    ProvisionAttemptOutcome.IDENTITY_MISMATCH,
                ),
            )
            raise
        record_provision_attempt(
            self.paths,
            ProvisionAttemptRecord(
                run_id,
                runtime,
                action,
                ProvisionAttemptEvent.COMPLETED,
                command_digest,
                datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                ProvisionAttemptOutcome.SUCCESS,
            ),
        )
        return identity

    def _guest_policy_check(self, runtime: str) -> dict[str, object]:
        instance = self._instance(runtime)
        common = (
            "test \"$(id -u calibration)\" = 2000 && "
            "test -z \"$(id -nG calibration | tr ' ' '\\n' | grep -E '^(sudo|adm)$' || true)\" && "
            "! sudo -u calibration sudo -n true 2>/dev/null && "
            "sudo -u calibration test ! -w /usr/local/share/outer-loop && "
            "sudo -u calibration test ! -w /etc && "
            "! findmnt -rn -o TARGET | grep -Eq '^/(Users|Volumes|mnt/lima-|home/lima-provision/.*share)'"
        )
        runtime_check = (
            "CODEX_HOME=/home/calibration/.codex codex --version | grep -qx 'codex-cli 0.144.5' && "
            "sudo -u calibration env CODEX_HOME=/home/calibration/.codex "
            "PYTHONPATH=/usr/local/share/outer-loop/harness "
            "python3 -c \"from pathlib import Path; from runtime.codex import read_effective_config,validate_effective_policy; "
            "c,r=read_effective_config(); validate_effective_policy(c,r,Path('/etc/codex/config.toml'),Path('/etc/codex/requirements.toml'))\""
            if runtime == "codex"
            else "CLAUDE_CONFIG_DIR=/home/calibration/.claude claude --version | grep -q '2.1.211' && "
            "srt --version | grep -q '0.0.65' && "
            "cmp -s /etc/claude-code/managed-settings.json /usr/local/share/outer-loop/harness/seeds/claude/managed-settings.json && "
            "cmp -s /etc/claude-code/managed-mcp.json /usr/local/share/outer-loop/harness/seeds/claude/managed-mcp.json && "
            "cmp -s /etc/claude-code/srt-settings.json /usr/local/share/outer-loop/harness/seeds/claude/srt-settings.json && "
            "test \"$(stat -c '%U:%G:%a' /etc/claude-code/managed-settings.json)\" = root:root:644"
        )
        self._shell(instance, ("sudo", "/bin/sh", "-ceu", f"{common} && {runtime_check}"), timeout=60)
        common_paths = (
            "/usr/bin/bwrap",
            "/usr/bin/rsync",
            "/usr/bin/socat",
            "/usr/local/libexec/outer-loop/control.py",
            "/usr/local/libexec/outer-loop/sanitize-auth.py",
            "/etc/apparmor.d/outer-loop-bwrap",
            "/usr/local/share/outer-loop/versions.lock.json",
            "/var/cache/outer-loop-debs/index-dists_noble_InRelease",
            "/var/cache/outer-loop-debs/index-dists_noble_main_binary-arm64_Packages.xz",
            "/var/cache/outer-loop-debs/index-dists_noble_universe_binary-arm64_Packages.xz",
            "/var/cache/outer-loop-debs/index-dists_noble-updates_InRelease",
            "/var/cache/outer-loop-debs/index-dists_noble-updates_main_binary-arm64_Packages.xz",
            "/var/cache/outer-loop-debs/index-dists_noble-updates_universe_binary-arm64_Packages.xz",
            "/var/cache/outer-loop-debs/index-dists_noble-security_InRelease",
            "/var/cache/outer-loop-debs/index-dists_noble-security_main_binary-arm64_Packages.xz",
            "/var/cache/outer-loop-debs/index-dists_noble-security_universe_binary-arm64_Packages.xz",
        )
        runtime_paths = (
            (
                "/usr/local/bin/codex",
                "/etc/codex/config.toml",
                "/etc/codex/requirements.toml",
                "/var/lib/outer-loop/install-codex/node.tar.xz",
                "/var/lib/outer-loop/install-codex/codex-base.tgz",
                "/var/lib/outer-loop/install-codex/codex-platform.tgz",
            )
            if runtime == "codex"
            else (
                "/opt/claude-2.1.211/claude",
                "/usr/local/bin/srt",
                "/etc/claude-code/managed-settings.json",
                "/etc/claude-code/managed-mcp.json",
                "/etc/claude-code/srt-settings.json",
                "/var/lib/outer-loop/install-claude/node.tar.xz",
                "/var/lib/outer-loop/install-claude/claude-base.tgz",
                "/var/lib/outer-loop/install-claude/claude.tgz",
                "/var/lib/outer-loop/install-claude/srt.tgz",
                "/var/lib/outer-loop/install-claude/socks.tgz",
                "/var/lib/outer-loop/install-claude/commander.tgz",
                "/var/lib/outer-loop/install-claude/node-forge.tgz",
                "/var/lib/outer-loop/install-claude/zod.tgz",
            )
        )
        digest_output = self._shell(
            instance,
            ("sudo", "sha256sum", *common_paths, *runtime_paths),
            timeout=60,
        ).stdout
        digests: dict[str, str] = {}
        for line in digest_output.splitlines():
            digest, separator, path = line.partition("  ")
            if not separator or len(digest) != 64 or not path.startswith("/"):
                raise ContractError("guest identity digest output malformed")
            digests[path] = digest
        if len(digests) != len(common_paths) + len(runtime_paths):
            raise ContractError("guest identity digest output incomplete")
        packages = self._shell(
            instance,
            (
                "dpkg-query",
                "-W",
                "-f=${Package}=${Version}\\n",
                "apparmor",
                "bubblewrap",
                "libseccomp2",
                "python3",
                "ripgrep",
                "rsync",
                "seccomp",
                "socat",
            ),
            timeout=30,
        ).stdout.splitlines()
        return {
            "runtime": runtime,
            "account_uid": 2000,
            "policy_owner": "root",
            "mounts": "none",
            "file_digests": digests,
            "packages": sorted(packages),
            "bundled_sandbox_runtime_identity": (
                "NOT_APPLICABLE"
                if runtime == "codex"
                else ObservationClass.UNAVAILABLE_BASELINE
            ),
        }

    def provision(self, run_id: str, frozen_harness: Path) -> PhaseResult:
        del frozen_harness
        stopped_identities: dict[str, LimaIdentity] = {}
        for runtime in RUNTIMES:
            instance = self._instance(runtime)
            stopped_identities[runtime] = self._provision_attempt(
                run_id,
                runtime,
                "create",
                (
                    "limactl",
                    "--tty=false",
                    "create",
                    f"--name={instance}",
                    "--plain",
                    "--mount-none",
                    "--containerd=none",
                    "--arch=aarch64",
                    "--vm-type=vz",
                    "--cpus=4",
                    "--memory=8",
                    "--disk=40",
                    str(self._profile(runtime)),
                ),
                expected_status="Stopped",
            )
        identities: dict[str, object] = {}
        for runtime in RUNTIMES:
            instance = self._instance(runtime)
            identity = self._provision_attempt(
                run_id,
                runtime,
                "start",
                ("limactl", "--tty=false", "start", "--timeout=20m", instance),
                expected_status="Running",
            )
            self._install_harness(runtime)
            policy = self._guest_policy_check(runtime)
            identities[runtime] = {
                "created_instance": stopped_identities[runtime].to_dict(),
                "instance": identity.to_dict(),
                "policy": policy,
            }
        if (
            stopped_identities["codex"].directory
            == stopped_identities["claude"].directory
        ):
            raise ContractError("guest disk identity is shared")
        peer_isolation = self._verify_peer_isolation()
        controls: list[ControlRecord] = []
        for runtime in RUNTIMES:
            controls.extend(
                (
                    self._record(run_id, "C00", "guest", runtime, identities[runtime], "provision"),
                    self._record(
                        run_id,
                        "C01",
                        "initial",
                        runtime,
                        {"identity": identities[runtime], "peer_isolation": peer_isolation},
                        "provision",
                    ),
                )
            )
        return PhaseResult(tuple(controls))

    def _guest_ipv4(self, instance: str) -> str:
        output = self._shell(instance, ("hostname", "-I"), timeout=20).stdout
        for token in output.split():
            try:
                address = ipaddress.ip_address(token)
            except ValueError:
                continue
            if address.version == 4 and not address.is_loopback:
                return str(address)
        raise ContractError("guest IPv4 identity unavailable for peer-isolation control")

    def _start_guest_canary(self, instance: str, port: int, nonce: str) -> None:
        listener = (
            "import socket,sys;"
            "s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);"
            "s.bind(('0.0.0.0',int(sys.argv[1])));s.listen(1);"
            "open(sys.argv[3],'x').write('READY\\n');s.settimeout(8);"
            "c,_=s.accept();d=c.recv(128);open(sys.argv[2],'xb').write(d);c.close();s.close()"
        )
        marker = f"/var/lib/outer-loop/peer-{port}.marker"
        ready = f"/var/lib/outer-loop/peer-{port}.ready"
        pid = f"/var/lib/outer-loop/peer-{port}.pid"
        script = (
            f"rm -f {marker} {ready} {pid}; "
            f"nohup python3 -c {shlex.quote(listener)} {port} {marker} {ready} "
            f">/dev/null 2>&1 & echo $! > {pid}; "
            f"i=0; while [ ! -f {ready} ]; do i=$((i+1)); [ $i -lt 50 ] || exit 1; sleep 0.1; done"
        )
        del nonce
        self._shell(instance, ("sudo", "/bin/sh", "-ceu", script), timeout=20)

    def _finish_guest_canary(self, instance: str, port: int) -> str | None:
        marker = f"/var/lib/outer-loop/peer-{port}.marker"
        pid = f"/var/lib/outer-loop/peer-{port}.pid"
        result = self._shell(
            instance,
            (
                "sudo",
                "/bin/sh",
                "-ceu",
                f"p=$(cat {pid}); i=0; while kill -0 \"$p\" 2>/dev/null; do i=$((i+1)); [ $i -lt 100 ] || break; sleep 0.1; done; "
                f"if [ -f {marker} ]; then cat {marker}; fi; kill \"$p\" 2>/dev/null || true; wait \"$p\" 2>/dev/null || true",
            ),
            timeout=20,
        )
        value = result.stdout.strip()
        return value or None

    def _guest_send(self, source: str, destination: str, port: int, nonce: str) -> int:
        code = (
            "import socket,sys;"
            "s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=3);"
            "s.sendall(sys.argv[3].encode('ascii'));s.close()"
        )
        result = self.runner.run(
            (
                "limactl",
                "--tty=false",
                "shell",
                source,
                "sudo",
                "python3",
                "-c",
                code,
                destination,
                str(port),
                nonce,
            ),
            timeout=10,
            check=False,
        )
        return result.returncode

    def _verify_peer_isolation(self) -> dict[str, object]:
        results: list[dict[str, object]] = []
        pairs = (
            (CODEX_INSTANCE, CLAUDE_INSTANCE, 39101),
            (CLAUDE_INSTANCE, CODEX_INSTANCE, 39102),
        )
        for source, target, port in pairs:
            target_ip = self._guest_ipv4(target)
            baseline_nonce = secrets.token_hex(16)
            self._start_guest_canary(target, port, baseline_nonce)
            if self._guest_send(target, "127.0.0.1", port, baseline_nonce) != 0:
                raise ContractError("peer-isolation listener baseline was unreachable")
            if self._finish_guest_canary(target, port) != baseline_nonce:
                raise ContractError("peer-isolation listener baseline nonce was not received")

            peer_nonce = secrets.token_hex(16)
            self._start_guest_canary(target, port, peer_nonce)
            peer_returncode = self._guest_send(source, target_ip, port, peer_nonce)
            peer_ingress = self._finish_guest_canary(target, port)
            if peer_returncode == 0 or peer_ingress is not None:
                raise ContractError("direct guest-to-guest transport is reachable")
            results.append(
                {
                    "source": source,
                    "target": target,
                    "target_ip_class": "private-ipv4",
                    "outside_baseline": "REACHABLE_FROM_TARGET_ROOT",
                    "peer_result": "UNREACHABLE",
                    "peer_ingress": False,
                }
            )
        return {"directions": results}

    def _auth_commands(self, runtime: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
        if runtime == "codex":
            login = (
                "sudo",
                "-u",
                "calibration",
                "env",
                "CODEX_HOME=/home/calibration/.codex",
                "codex",
                "login",
                "--device-auth",
            )
            check = (
                "sudo -u calibration env CODEX_HOME=/home/calibration/.codex "
                "codex login status > /dev/shm/outer-loop/auth.raw 2>&1; "
                "/usr/local/libexec/outer-loop/sanitize-auth.py "
                "--kind auth --runtime codex --input /dev/shm/outer-loop/auth.raw "
                "--output /dev/shm/outer-loop/auth.safe --credential /home/calibration/.codex/auth.json"
            )
        else:
            login = (
                "sudo",
                "-u",
                "calibration",
                "env",
                "CLAUDE_CONFIG_DIR=/home/calibration/.claude",
                "claude",
                "auth",
                "login",
                "--claudeai",
            )
            check = (
                "sudo -u calibration env CLAUDE_CONFIG_DIR=/home/calibration/.claude "
                "claude auth status > /dev/shm/outer-loop/auth.raw 2>&1; "
                "/usr/local/libexec/outer-loop/sanitize-auth.py "
                "--kind auth --runtime claude --input /dev/shm/outer-loop/auth.raw "
                "--output /dev/shm/outer-loop/auth.safe --credential /home/calibration/.claude/.credentials.json"
            )
        return login, ("sudo", "/bin/sh", "-ceu", check)

    @staticmethod
    def _smoke_script(runtime: str) -> str:
        if runtime == "codex":
            return (
                "rc=0; sudo -u calibration env CODEX_HOME=/home/calibration/.codex "
                "codex exec --json --ephemeral --skip-git-repo-check --cd /home/calibration/workspace/harmless "
                "'Reply with exactly CALIBRATION_SMOKE_OK. Do not call any tool.' "
                "> /dev/shm/outer-loop/smoke.raw || rc=$?; "
                "/usr/local/libexec/outer-loop/sanitize-auth.py "
                "--kind smoke --runtime codex --input /dev/shm/outer-loop/smoke.raw "
                "--output /dev/shm/outer-loop/smoke.safe; test \"$rc\" = 0"
            )
        if runtime == "claude":
            return (
                "rc=0; sudo -u calibration env CLAUDE_CONFIG_DIR=/home/calibration/.claude "
                "claude --print --safe-mode --tools '' --strict-mcp-config --no-chrome "
                "--disable-slash-commands --no-session-persistence --output-format stream-json --verbose "
                "'Reply with exactly CALIBRATION_SMOKE_OK. Do not call any tool.' "
                "> /dev/shm/outer-loop/smoke.raw || rc=$?; "
                "/usr/local/libexec/outer-loop/sanitize-auth.py "
                "--kind smoke --runtime claude --input /dev/shm/outer-loop/smoke.raw "
                "--output /dev/shm/outer-loop/smoke.safe; test \"$rc\" = 0"
            )
        raise ContractError("unknown runtime smoke")

    def _collect_runtime_classification(self, runtime: str, occurrence: str) -> dict[str, object]:
        instance = self._instance(runtime)
        _, check = self._auth_commands(runtime)
        self._shell(instance, ("sudo", "install", "-d", "-m", "0700", "-o", "root", "-g", "root", "/dev/shm/outer-loop"))
        self._shell(instance, check, timeout=60)
        self._shell(instance, ("sudo", "/bin/sh", "-ceu", self._smoke_script(runtime)), timeout=300)
        try:
            value = json.loads(
                self._shell(instance, ("sudo", "cat", "/dev/shm/outer-loop/auth.safe"), timeout=20).stdout
            )
            smoke_value = json.loads(
                self._shell(instance, ("sudo", "cat", "/dev/shm/outer-loop/smoke.safe"), timeout=20).stdout
            )
        except json.JSONDecodeError as exc:
            raise ContractError("sanitized runtime classification was invalid") from exc
        finally:
            self._shell(
                instance,
                ("sudo", "rm", "-f", "/dev/shm/outer-loop/auth.safe", "/dev/shm/outer-loop/smoke.safe"),
                check=False,
            )
        expected_method = "chatgpt_device" if runtime == "codex" else "claudeai_oauth"
        if value.get("authentication_method") != expected_method or value.get("authenticated") is not True:
            raise ContractError("authentication method classification mismatch")
        if smoke_value.get("smoke") != "CALIBRATION_SMOKE_OK" or smoke_value.get("tool_calls") != 0:
            raise ContractError("tool-free smoke classification mismatch")
        return {"auth": value, "smoke": smoke_value}

    def authenticate(self, run_id: str, runtime: str, occurrence: str) -> PhaseResult:
        if occurrence != "initial":
            raise ContractError("interactive authentication is only valid initially")
        instance = self._instance(runtime)
        login, _ = self._auth_commands(runtime)
        self.runner.run(
            ("limactl", "--tty=true", "shell", instance, *login),
            timeout=900,
            capture_output=False,
        )
        classification = self._collect_runtime_classification(runtime, occurrence)
        return PhaseResult(
            (
                self._record(
                    run_id,
                    "C02",
                    occurrence,
                    runtime,
                    classification,
                    "authenticate runtime",
                ),
            )
        )

    def isolation(self, run_id: str, occurrence: str) -> PhaseResult:
        if occurrence not in {"initial", "post_restart"}:
            raise ContractError("invalid isolation occurrence")
        listeners = self.paths.work / "listeners"
        listeners.mkdir(mode=0o700, exist_ok=True)
        os.chmod(listeners, 0o700)
        controls: list[ControlRecord] = []
        observations: list[dict[str, object]] = []
        scheduled = {
            target.target_id: target
            for target in required_probe_matrix()
            if target.occurrence == occurrence
            and target.destination_class == "host"
            and target.address_family in {"dns", "ipv4"}
            and target.protocol in {"tcp", "udp"}
        }
        for target in required_probe_matrix():
            if target.occurrence != occurrence:
                continue
            if target.target_id not in scheduled:
                observations.append(
                    {
                        "control_id": "C03",
                        "target": target.target_id,
                        "observed_classification": ObservationClass.UNAVAILABLE_BASELINE,
                        "result": None,
                        "reason": "no operator-authority path exists under the static no-network profile",
                    }
                )
                continue
            control = self._execute_host_probe(run_id, target, listeners)
            controls.append(control)
        if not controls:
            raise ContractError("C03 produced no reachable paired probes")
        return PhaseResult(tuple(controls), tuple(observations))

    def _guest_host_ipv4(self, runtime: str) -> str:
        output = self._shell(
            self._instance(runtime),
            ("getent", "ahostsv4", "host.lima.internal"),
            timeout=20,
        ).stdout
        for token in output.split():
            try:
                address = ipaddress.ip_address(token)
            except ValueError:
                continue
            if address.version == 4 and not address.is_unspecified and not address.is_loopback:
                return str(address)
        raise ContractError("guest could not resolve the host IPv4 address")

    @staticmethod
    def _probe_client_argv(host: str, port: int, protocol: str, nonce: str) -> tuple[str, ...]:
        if protocol == "tcp":
            operation = (
                "s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5)\n"
                "    s.sendall(sys.argv[3].encode('ascii'))\n"
                "    s.close()"
            )
        else:
            operation = (
                "a = socket.getaddrinfo(sys.argv[1], int(sys.argv[2]), type=socket.SOCK_DGRAM)[0]\n"
                "    s = socket.socket(a[0], a[1], a[2])\n"
                "    s.sendto(sys.argv[3].encode('ascii'), a[4])\n"
                "    s.close()"
            )
        denial_errnos = (
            errno.EACCES,
            errno.EPERM,
            errno.ENETUNREACH,
            errno.EHOSTUNREACH,
        )
        code = (
            "import errno\n"
            "import socket\n"
            "import sys\n"
            "try:\n"
            f"    {operation}\n"
            "except OSError as exc:\n"
            f"    if exc.errno in {denial_errnos!r}:\n"
            f"        sys.stderr.write({NETWORK_DENIED_MARKER!r} + '\\n')\n"
            f"        raise SystemExit({NETWORK_DENIED_EXIT})\n"
            "    raise\n"
        )
        return ("/usr/bin/python3", "-c", code, host, str(port), nonce)

    @classmethod
    def _probe_argv(cls, host: str, port: int, protocol: str, nonce: str) -> tuple[str, ...]:
        return (
            "/usr/local/libexec/outer-loop/control.py",
            "--nonce",
            nonce,
            "--destination",
            "host",
            "--",
            *cls._probe_client_argv(host, port, protocol, nonce),
        )

    @staticmethod
    def _receipt_from_value(
        value: object,
        *,
        nonce: str,
        destination: str,
    ) -> ExecutionReceipt | None:
        try:
            if not isinstance(value, dict):
                return None
            receipt = ExecutionReceipt(
                nonce=str(value["nonce"]),
                destination_class=str(value["destination"]),
                argv_digest=str(value["argv_digest"]),
                classification=str(value["classification"]),
            )
        except KeyError:
            return None
        if receipt.nonce != nonce or receipt.destination_class != destination:
            return None
        return receipt

    @classmethod
    def _receipt_from_output(
        cls,
        output: str,
        *,
        nonce: str,
        destination: str,
    ) -> ExecutionReceipt | None:
        values: list[object] = []
        for line in output.splitlines():
            marker = line.find(COMPLETE_RECEIPT_PREFIX)
            if marker < 0:
                continue
            try:
                values.append(json.loads(line[marker + len(COMPLETE_RECEIPT_PREFIX):]))
            except json.JSONDecodeError:
                return None
        if len(values) != 1:
            return None
        return cls._receipt_from_value(values[0], nonce=nonce, destination=destination)

    def _run_agent_probe(
        self,
        runtime: str,
        command: str,
        nonce: str,
        destination: str,
    ) -> tuple[bool, ExecutionReceipt | None]:
        instance = self._instance(runtime)
        raw = f"/dev/shm/outer-loop/probe-{nonce}.raw"
        safe = f"/dev/shm/outer-loop/probe-{nonce}.safe"
        prompt = f"Run this exact Bash command once and use no other tool: {command}"
        if runtime == "codex":
            runtime_command = (
                "sudo -u calibration env CODEX_HOME=/home/calibration/.codex "
                "codex exec --json --ephemeral --skip-git-repo-check --cd /home/calibration/workspace/harmless "
                f"{shlex.quote(prompt)}"
            )
        else:
            runtime_command = (
                "sudo -u calibration env CLAUDE_CONFIG_DIR=/home/calibration/.claude "
                "claude --print --safe-mode --tools Bash --strict-mcp-config --no-chrome "
                "--disable-slash-commands --no-session-persistence --output-format stream-json --verbose "
                f"{shlex.quote(prompt)}"
            )
        script = (
            f"rc=0; {runtime_command} > {shlex.quote(raw)} || rc=$?; "
            "/usr/local/libexec/outer-loop/sanitize-auth.py "
            f"--kind probe --runtime {runtime} --input {shlex.quote(raw)} --output {shlex.quote(safe)} "
            f"--intended-command {shlex.quote(command)} --expected-nonce {nonce} "
            f"--expected-destination {destination}; test \"$rc\" = 0"
        )
        self._shell(instance, ("sudo", "/bin/sh", "-ceu", script), timeout=300)
        try:
            result = self._shell(instance, ("sudo", "cat", safe), timeout=20)
            value = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError) as exc:
            raise ContractError("sanitized probe classification was invalid") from exc
        finally:
            self._shell(instance, ("sudo", "rm", "-f", safe), check=False)
        exact = (
            isinstance(value, dict)
            and value.get("exact_command") is True
            and value.get("command_digest") == hashlib.sha256(command.encode()).hexdigest()
        )
        receipt = self._receipt_from_value(
            value.get("receipt") if isinstance(value, dict) else None,
            nonce=nonce,
            destination=destination,
        )
        return exact, receipt

    def _run_probe_stage(
        self,
        target,
        nonce: str,
        intended_argv: tuple[str, ...],
        port: int,
        *,
        bind_host: str,
        stage: str,
        outside_ingress_nonce: str,
        listeners: Path,
    ) -> tuple[ProbeOutcome, dict[str, object]]:
        canary = OneShotCanary(
            target.protocol,
            bind_host=bind_host,
            port=port,
            timeout=30,
        )
        command = shlex.join(intended_argv)
        runtime_argv: tuple[str, ...] | None = intended_argv
        receipt: ExecutionReceipt | None = None
        try:
            if stage == "srt-direct":
                result = self._shell(
                    self._instance(target.runtime),
                    (
                        "sudo",
                        "-u",
                        "calibration",
                        "srt",
                        "--settings",
                        "/etc/claude-code/srt-settings.json",
                        *intended_argv,
                    ),
                    timeout=60,
                    check=False,
                )
                receipt = self._receipt_from_output(
                    result.stdout,
                    nonce=nonce,
                    destination=target.destination_class,
                )
            else:
                exact, receipt = self._run_agent_probe(
                    target.runtime,
                    command,
                    nonce,
                    target.destination_class,
                )
                if not exact:
                    runtime_argv = None
        except ContractError:
            if stage == "srt-direct":
                pass
            else:
                runtime_argv = None
        canary_result = canary.wait()
        ingress = canary_result.received
        evidence = ProbeEvidence(
            target=target,
            nonce=nonce,
            intended_argv=intended_argv,
            runtime_observed_argv=runtime_argv,
            outside_path_available=True,
            outside_ingress_nonce=outside_ingress_nonce,
            receipt=receipt,
            inside_ingress_nonce=ingress,
            inside_canary_error=canary_result.error,
        )
        outcome = classify_paired_probe(evidence)
        log = {
            "schema_version": 1,
            "target": target.target_id,
            "stage": stage,
            "nonce": nonce,
            "canary_bind_host": bind_host,
            "outside_ingress_nonce": outside_ingress_nonce,
            "inside_ingress_nonce": ingress,
            "inside_canary_error": canary_result.error,
            "receipt": asdict(receipt) if receipt else None,
            "runtime_argv_exact": runtime_argv == intended_argv,
            "outcome": asdict(outcome),
        }
        write_once(listeners / f"{hashlib.sha256((target.target_id + stage).encode()).hexdigest()}.json", log)
        return outcome, log

    def _execute_host_probe(self, run_id: str, target, listeners: Path) -> ControlRecord:
        nonce = secrets.token_hex(16)
        bind_host = self._guest_host_ipv4(target.runtime)
        outside = OneShotCanary(target.protocol, bind_host=bind_host, timeout=30)
        port = outside.port
        host = "host.lima.internal" if target.address_family == "dns" else bind_host
        outside_result = self._shell(
            self._instance(target.runtime),
            ("sudo", *self._probe_client_argv(host, port, target.protocol, nonce)),
            timeout=20,
            check=False,
        )
        outside_canary = outside.wait()
        outside_ingress = outside_canary.received
        if outside_result.returncode != 0 or outside_canary.error is not None or outside_ingress != nonce:
            return ControlRecord(
                ControlKey(run_id, "C03", target.occurrence, target.target_id),
                "PAIRED_DENIAL_PROVED",
                "OUTSIDE_INGRESS_MISSING",
                hashlib.sha256(
                    canonical_json(
                        {
                            "target": target.target_id,
                            "nonce": nonce,
                            "canary_bind_host": bind_host,
                            "canary_error": outside_canary.error,
                        }
                    )
                ).hexdigest(),
                ControlResult.UNVERIFIED,
                "run isolation",
                "CANARY_LISTENER_ERROR" if outside_canary.error is not None else "CANARY_UNREACHABLE",
            )
        intended_argv = self._probe_argv(host, port, target.protocol, nonce)
        if target.runtime == "claude":
            stage_one, stage_one_log = self._run_probe_stage(
                target,
                nonce,
                intended_argv,
                port,
                bind_host=bind_host,
                stage="srt-direct",
                outside_ingress_nonce=outside_ingress,
                listeners=listeners,
            )
            stage_two, stage_two_log = self._run_probe_stage(
                target,
                nonce,
                intended_argv,
                port,
                bind_host=bind_host,
                stage="claude-bash",
                outside_ingress_nonce=outside_ingress,
                listeners=listeners,
            )
            result = classify_claude_two_stage(stage_one, stage_two)
            observed = stage_two.observation
            evidence = {"stage_one": stage_one_log, "stage_two": stage_two_log}
        else:
            outcome, log = self._run_probe_stage(
                target,
                nonce,
                intended_argv,
                port,
                bind_host=bind_host,
                stage="codex-command",
                outside_ingress_nonce=outside_ingress,
                listeners=listeners,
            )
            result = outcome.result or ControlResult.UNVERIFIED
            observed = outcome.observation
            evidence = {"stage": log}
        return ControlRecord(
            key=ControlKey(run_id, "C03", target.occurrence, target.target_id),
            expected_classification="PAIRED_DENIAL_PROVED",
            observed_classification=observed,
            evidence_digest=hashlib.sha256(canonical_json(evidence)).hexdigest(),
            result=result,
            operator_step="run isolation",
            exit_classification="SANITIZED",
        )

    def _sync_export_direction(
        self,
        run_id: str,
        direction: str,
        driver_instance: str,
        fixture: Path,
        fixture_before: tuple[object, ...],
        staging_parent: Path,
        sentinels: Path,
    ) -> tuple[ControlRecord, ...]:
        staging_root = staging_parent / direction
        staging_root.mkdir(mode=0o700, exist_ok=False)
        os.chmod(staging_root, 0o700)
        outside_sentinel = sentinels / f"{direction}-outside-sync.txt"
        write_once(outside_sentinel, {"nonce": secrets.token_hex(16)})
        sentinel_digest = sha256_file(outside_sentinel)
        diagnostic_root = f"/dev/shm/outer-loop-sync-{direction}"
        cases: dict[str, tuple[Path, tuple[object, ...]]] = {}
        for name in ("no", "nonzero", "yes"):
            staging = staging_root / name
            shutil.copytree(fixture, staging, symlinks=True)
            os.chmod(staging, 0o700)
            cases[name] = (staging, stable_inventory(staging))

        commands = {
            "no": "printf 'must-not-sync\\n' > keep.txt",
            "nonzero": "printf 'must-not-sync\\n' > keep.txt; exit 7",
            "yes": (
                "printf 'accepted-change\\n' > keep.txt; "
                "rm delete.txt; mv rename-from.txt rename-to.txt; "
                "mkdir created; printf 'new-file\\n' > created/new.txt; "
                "printf 'guest-escape-attempt\\n' > ../outside-sentinel; "
                f"mkdir -m 0700 -p {diagnostic_root}; "
                "/usr/local/libexec/outer-loop/inspect-export.py . "
                f"> {diagnostic_root}/export-diagnostic.json"
            ),
        }
        guard_evidence: list[dict[str, object]] = []
        for name in ("no", "nonzero", "yes"):
            staging, baseline = cases[name]
            argv = (
                "limactl",
                "shell",
                f"--sync={staging}",
                driver_instance,
                "/bin/sh",
                "-ceu",
                commands[name],
            )
            guarded = validate_sync_invocation(
                argv,
                staging,
                registered_roots=(staging_parent,),
                authoritative_roots=(self.repository_root,),
                stdin_isatty=os.isatty(0),
                stdout_isatty=os.isatty(1),
            )
            print(
                f"sync {direction} case {name}: choose {'Yes' if name == 'yes' else 'No'} at the Lima prompt",
                flush=True,
            )
            try:
                guarded.verify_path_identity()
                result = self.runner.run(
                    guarded.argv,
                    timeout=300,
                    capture_output=False,
                    check=False,
                    cwd_fd=guarded.directory_fd,
                )
                guarded.verify_path_identity()
            finally:
                guarded.close()
            if name == "nonzero":
                if result.returncode == 0:
                    raise ContractError("nonzero sync case unexpectedly returned zero")
            elif result.returncode != 0:
                raise ContractError(f"sync case failed: {direction}:{name}")
            observed = stable_inventory(staging)
            if name in {"no", "nonzero"} and observed != baseline:
                raise ContractError(f"sync-back occurred for rejected case: {direction}:{name}")
            guard_evidence.append(
                {
                    "case": name,
                    "direction": direction,
                    "driver": driver_instance,
                    "staging": str(guarded.staging),
                    "registered_root": str(guarded.registered_root),
                    "returncode": result.returncode,
                    "inventory_digest": hashlib.sha256(
                        canonical_json([asdict(node) for node in observed])
                    ).hexdigest(),
                }
            )
            if sha256_file(outside_sentinel) != sentinel_digest:
                raise ContractError("outside sync sentinel changed")

        yes_staging = cases["yes"][0]
        diagnostic_result = self._shell(
            driver_instance,
            ("sudo", "cat", f"{diagnostic_root}/export-diagnostic.json"),
            timeout=20,
        )
        self._shell(driver_instance, ("sudo", "rm", "-rf", diagnostic_root))
        try:
            guest_diagnostic = json.loads(diagnostic_result.stdout)
        except json.JSONDecodeError as exc:
            raise ContractError("guest export diagnostic was not valid JSON") from exc
        if guest_diagnostic.get("schema_version") != 1 or guest_diagnostic.get("hazard") is not False:
            raise ContractError("guest export diagnostic reported a hazard")
        expected_names = {
            "created",
            "created/new.txt",
            "keep.txt",
            "nested",
            "nested/item.txt",
            "rename-to.txt",
        }
        yes_inventory = stable_inventory(yes_staging)
        if {node.path for node in yes_inventory} != expected_names:
            raise ContractError("accepted sync inventory did not match the fixed mutation")
        if stable_inventory(fixture) != fixture_before:
            raise ContractError("immutable fixture changed during sync calibration")

        quarantine = self.paths.work / "quarantine" / direction
        quarantine.parent.mkdir(mode=0o700, exist_ok=True)
        quarantine_inventory = validate_quarantine(yes_staging, quarantine)
        frozen = self.paths.fixture_bundles / direction
        bundle_digest = freeze_bundle(quarantine, frozen, quarantine_inventory)
        c04_evidence = {"direction": direction, "driver": driver_instance, "guards": guard_evidence, "tty": True}
        c05_evidence = {
            "direction": direction,
            "driver": driver_instance,
            "fixture_digest": hashlib.sha256(
                canonical_json([asdict(node) for node in fixture_before])
            ).hexdigest(),
            "accepted_inventory": [asdict(node) for node in yes_inventory],
            "outside_sentinel_digest": sentinel_digest,
        }
        c06_evidence = {
            "direction": direction,
            "driver": driver_instance,
            "guest_diagnostic_digest": hashlib.sha256(canonical_json(guest_diagnostic)).hexdigest(),
            "quarantine_inventory": [asdict(node) for node in quarantine_inventory],
            "bundle_digest": bundle_digest,
        }
        return (
            self._record(run_id, "C04", direction, f"{direction}:sync-guard", c04_evidence, "run sync-export"),
            self._record(run_id, "C05", direction, f"{direction}:sync-semantics", c05_evidence, "run sync-export"),
            self._record(run_id, "C06", direction, f"{direction}:export-quarantine", c06_evidence, "run sync-export"),
        )

    def sync_export(self, run_id: str) -> PhaseResult:
        fixture = self.paths.frozen_harness / "fixtures" / "sync-positive"
        fixture_before = stable_inventory(fixture)
        staging_root = self.paths.work / "staging"
        staging_root.mkdir(mode=0o700, exist_ok=False)
        os.chmod(staging_root, 0o700)
        sentinels = self.paths.work / "sentinels"
        sentinels.mkdir(mode=0o700, exist_ok=False)
        controls: list[ControlRecord] = []
        for direction, driver_instance in (
            ("forward", CODEX_INSTANCE),
            ("reverse", CLAUDE_INSTANCE),
        ):
            controls.extend(
                self._sync_export_direction(
                    run_id,
                    direction,
                    driver_instance,
                    fixture,
                    fixture_before,
                    staging_root,
                    sentinels,
                )
            )
        return PhaseResult(tuple(controls))

    def handoff(self, run_id: str, direction: str) -> PhaseResult:
        if direction not in HANDOFF_DIRECTIONS:
            raise ContractError("invalid handoff direction")
        driver_instance, reviewer_instance = (
            (CODEX_INSTANCE, CLAUDE_INSTANCE)
            if direction == "forward"
            else (CLAUDE_INSTANCE, CODEX_INSTANCE)
        )
        self.runner.run(("limactl", "--tty=false", "stop", driver_instance), timeout=180)
        stopped_result = self.runner.run(
            ("limactl", "--tty=false", "list", "--all-fields", "--format=json", driver_instance),
            timeout=30,
            check=False,
        )
        stopped_snapshot = parse_lima_list(
            stopped_result.returncode,
            stopped_result.stdout,
            stopped_result.stderr,
        )
        if (
            stopped_snapshot.disposition is not LimaListDisposition.RECOGNIZED
            or len(stopped_snapshot.identities) != 1
        ):
            raise ContractError("handoff driver stop identity mismatch")
        stopped = stopped_snapshot.identities[0]
        try:
            validate_expected_identity(
                stopped,
                name=driver_instance,
                status="Stopped",
                directory=self.paths.lima_home / driver_instance,
            )
        except ContractError as exc:
            raise ContractError("handoff driver stop identity mismatch") from exc
        reviewer_identity = self.runner.run(
            ("limactl", "--tty=false", "list", "--all-fields", "--format=json", reviewer_instance),
            timeout=30,
            check=False,
        )
        reviewer_snapshot = parse_lima_list(
            reviewer_identity.returncode,
            reviewer_identity.stdout,
            reviewer_identity.stderr,
        )
        if (
            reviewer_snapshot.disposition is not LimaListDisposition.RECOGNIZED
            or len(reviewer_snapshot.identities) != 1
        ):
            raise ContractError("handoff reviewer identity unavailable")
        reviewer = reviewer_snapshot.identities[0]
        if reviewer.status == "Stopped":
            self.runner.run(
                ("limactl", "--tty=false", "start", "--timeout=10m", reviewer_instance),
                timeout=720,
            )
            reviewer_runtime = "codex" if reviewer_instance == CODEX_INSTANCE else "claude"
            reviewer = self._list_identity(
                reviewer_runtime,
                expected_status="Running",
                stage=f"handoff-{direction}-reviewer",
            )
        elif reviewer.status != "Running":
            raise ContractError("handoff reviewer identity unavailable")
        validate_expected_identity(
            reviewer,
            name=reviewer_instance,
            status="Running",
            directory=self.paths.lima_home / reviewer_instance,
        )
        bundle = self.paths.fixture_bundles / direction
        manifest = bundle / "bundle-manifest.json"
        expected_digest = sha256_file(manifest)
        guest_bundle = f"/tmp/outer-loop-handoff-{direction}"
        self._shell(reviewer_instance, ("sudo", "rm", "-rf", guest_bundle))
        self.runner.run(
            (
                "limactl",
                "--tty=false",
                "copy",
                "--backend=scp",
                "--recursive",
                str(bundle),
                f"{reviewer_instance}:{guest_bundle}",
            ),
            timeout=120,
        )
        verify_script = "\n".join(
            (
                "import hashlib, json, os, stat, sys",
                "from pathlib import Path",
                "root = Path(sys.argv[1]).resolve(strict=True)",
                "mfd = os.open(root / 'bundle-manifest.json', os.O_RDONLY | os.O_NOFOLLOW)",
                "mbefore = os.fstat(mfd); manifest_bytes = bytearray()",
                "while chunk := os.read(mfd, 1048576): manifest_bytes.extend(chunk)",
                "mafter = os.fstat(mfd); os.close(mfd)",
                "if (mbefore.st_dev,mbefore.st_ino,mbefore.st_size,mbefore.st_mtime_ns) != (mafter.st_dev,mafter.st_ino,mafter.st_size,mafter.st_mtime_ns): raise SystemExit(2)",
                "manifest = json.loads(manifest_bytes)",
                "for node in manifest['frozen_inventory']:",
                "    if node['node_type'] != 'file': continue",
                "    path = root / node['path']",
                "    info = path.lstat()",
                "    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode): raise SystemExit(2)",
                "    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)",
                "    before = os.fstat(fd); digest = hashlib.sha256()",
                "    while chunk := os.read(fd, 1048576): digest.update(chunk)",
                "    after = os.fstat(fd); os.close(fd)",
                "    if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) != (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns): raise SystemExit(3)",
                "    if digest.hexdigest() != node['sha256']: raise SystemExit(4)",
                "print(hashlib.sha256(manifest_bytes).hexdigest())",
            )
        )
        verified = self._shell(
            reviewer_instance,
            ("python3", "-c", verify_script, guest_bundle),
            timeout=60,
        ).stdout.strip()
        if verified != expected_digest:
            raise ContractError("handoff reviewer digest mismatch")
        evidence = {
            "direction": direction,
            "driver": stopped.to_dict(),
            "reviewer": reviewer_instance,
            "bundle_manifest_digest": expected_digest,
            "reviewer_digest": verified,
        }
        return PhaseResult(
            (self._record(run_id, "C07", direction, direction, evidence, f"run handoff-{direction}"),)
        )

    def restart(self, run_id: str) -> PhaseResult:
        for runtime in RUNTIMES:
            instance = self._instance(runtime)
            listed = self.runner.run(
                ("limactl", "--tty=false", "list", "--all-fields", "--format=json", instance),
                timeout=30,
                check=False,
            )
            snapshot = parse_lima_list(listed.returncode, listed.stdout, listed.stderr)
            if snapshot.disposition is not LimaListDisposition.RECOGNIZED or len(snapshot.identities) != 1:
                raise ContractError("restart identity unavailable")
            identity = snapshot.identities[0]
            if identity.status == "Running":
                self.runner.run(("limactl", "--tty=false", "stop", instance), timeout=180)
            elif identity.status != "Stopped":
                raise ContractError("restart identity status is not safe")
            self.runner.run(("limactl", "--tty=false", "start", "--timeout=10m", instance), timeout=720)
        controls: list[ControlRecord] = []
        for runtime in RUNTIMES:
            identity = self._list_identity(
                runtime,
                expected_status="Running",
                stage="post-restart",
            )
            policy = self._guest_policy_check(runtime)
            classification = self._collect_runtime_classification(runtime, "post_restart")
            controls.append(
                self._record(
                    run_id,
                    "C02",
                    "post_restart",
                    runtime,
                    {"identity": identity.to_dict(), "policy": policy, **classification},
                    "run restart",
                )
            )
        isolation = self.isolation(run_id, "post_restart")
        controls.extend(isolation.controls)
        return PhaseResult(tuple(controls), isolation.observations)

    def stop_for_seal(self, run_id: str) -> dict[str, object]:
        del run_id
        identities: dict[str, object] = {}
        for runtime in RUNTIMES:
            instance = self._instance(runtime)
            self.runner.run(("limactl", "--tty=false", "stop", instance), timeout=180)
            identity = self._list_identity(
                runtime,
                expected_status="Stopped",
                stage="pre-seal-stopped",
            )
            identities[instance] = identity.to_dict()
        return identities


class Orchestrator:
    def __init__(
        self,
        *,
        harness_root: Path,
        state_root: Path,
        lima_pool_root: Path,
        driver_factory: Callable[[RunPaths], CalibrationDriver] | None = None,
        stdin_isatty: Callable[[], bool] | None = None,
        stdout_isatty: Callable[[], bool] | None = None,
        input_fn: Callable[[str], str] = input,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.harness_root = harness_root.resolve(strict=True)
        if not Path(state_root).is_absolute() or not Path(lima_pool_root).is_absolute():
            raise ContractError("state and Lima pool roots must be absolute")
        self.state_root = Path(os.path.abspath(state_root))
        self.lima_pool_root = Path(os.path.abspath(lima_pool_root))
        self._driver_factory = driver_factory or (
            lambda paths: LimaDriver(paths, self.harness_root)
        )
        self._stdin_isatty = stdin_isatty or sys.stdin.isatty
        self._stdout_isatty = stdout_isatty or sys.stdout.isatty
        self._input = input_fn
        self._now = now or (lambda: datetime.now(UTC))
        self._operation_locks: dict[str, int] = {}

    def _paths(self, run_id: str) -> RunPaths:
        return RunPaths.for_run(
            validate_run_id(run_id),
            self.state_root,
            self.lima_pool_root,
        )

    @staticmethod
    def _state_template(
        run_id: str,
        deadline: str,
        binding: dict[str, object],
    ) -> dict[str, object]:
        return {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "run_id": run_id,
            "retention_deadline": deadline,
            "phase": Phase.INITIALIZED,
            "terminal_state": TerminalState.RUNNING,
            "real_task_allowed": False,
            "active_operation": None,
            "completed_operations": ["init"],
            "authentication_attempts": [],
            "required_control_keys": [],
            "approval_targets": {},
            "seal_input_digest": None,
            "seal_digest": None,
            "preflight_snapshot_digest": None,
            "cleanup_started": False,
            "cleanup_cause": None,
            "cleanup_disposition": CleanupDisposition.NOT_STARTED,
            "account_revoke_required": False,
            "cleanup_verified": False,
            "lima_home_binding": binding,
            "pre_cleanup_terminal_state": None,
            "pre_cleanup_phase": None,
        }

    def _assert_new_run_allowed(self) -> None:
        runs = self.state_root / "runs"
        if runs.exists():
            try:
                candidates = tuple(runs.iterdir())
            except OSError as exc:
                raise ContractError("existing run state cannot be inspected") from exc
            for candidate in candidates:
                state_file = candidate / "work" / "state.json"
                if not state_file.exists():
                    continue
                try:
                    existing = load_json(state_file)
                except Exception as exc:
                    raise ContractError("existing run state is unreadable") from exc
                if (
                    existing.get("schema_version") == RUNTIME_SCHEMA_VERSION
                    and existing.get("cleanup_disposition")
                    == CleanupDisposition.CLEANUP_MANUAL_REQUIRED
                    and existing.get("cleanup_verified") is not True
                ):
                    raise ContractError("unresolved manual cleanup blocks a new live run")
        if self.lima_pool_root.exists():
            try:
                entries = tuple(self.lima_pool_root.iterdir())
            except OSError as exc:
                raise ContractError("Lima pool cannot be inspected") from exc
            unexpected = [entry.name for entry in entries if entry.name not in {".bindings", ".pool.lock"}]
            if unexpected:
                raise ContractError("existing physical Lima home blocks a new live run")

    def init(self, run_id: str, deadline: str) -> dict[str, object]:
        validate_run_id(run_id)
        parsed = parse_utc_deadline(deadline)
        if parsed <= self._now().astimezone(UTC):
            raise ContractError("retention deadline must be in the future")
        paths = self._paths(run_id)
        if paths.root.exists() or paths.root.is_symlink():
            raise ContractError("run id already exists and cannot be retried")
        self._assert_new_run_allowed()
        binding = paths.create(
            allow_pool_create=self.lima_pool_root == Path(os.path.abspath(DEFAULT_LIMA_POOL_ROOT)),
            instance_names=FIXED_INSTANCES,
        )
        binding_value = binding.to_dict()
        state = self._state_template(run_id, deadline, binding_value)
        write_once(paths.evidence / "lima-home-binding.json", binding_value)
        write_once(
            paths.evidence / "retention.json",
            {
                "schema_version": RUNTIME_SCHEMA_VERSION,
                "run_id": run_id,
                "retention_deadline": deadline,
                "state_root": str(self.state_root),
                "lima_pool_root": str(self.lima_pool_root),
            },
        )
        self._save(paths, state)
        return state

    def _load(self, paths: RunPaths, *, allow_legacy: bool = False) -> dict[str, object]:
        state = load_json(paths.state_file)
        if state.get("run_id") != paths.run_id:
            raise ContractError("run state identity mismatch")
        if state.get("schema_version") == 1:
            if not allow_legacy:
                raise ContractError("runtime schema 1 is read-only; start a new run")
            if state.get("real_task_allowed") is not False:
                raise ContractError("run state attempted to grant real-task authority")
            return state
        if state.get("schema_version") != RUNTIME_SCHEMA_VERSION:
            raise ContractError("run state schema is unsupported")
        parse_utc_deadline(str(state.get("retention_deadline", "")))
        retention = load_json(paths.evidence / "retention.json")
        if (
            retention.get("schema_version") != RUNTIME_SCHEMA_VERSION
            or retention.get("run_id") != paths.run_id
            or retention.get("retention_deadline") != state.get("retention_deadline")
            or retention.get("state_root") != str(self.state_root)
            or retention.get("lima_pool_root") != str(self.lima_pool_root)
        ):
            raise ContractError("immutable retention deadline drift")
        binding = state.get("lima_home_binding")
        if type(binding) is not dict or binding.get("schema_version") != RUNTIME_SCHEMA_VERSION:
            raise ContractError("Lima home binding state is invalid")
        if state.get("real_task_allowed") is not False:
            raise ContractError("run state attempted to grant real-task authority")
        return state

    @staticmethod
    def _save(paths: RunPaths, state: dict[str, object]) -> None:
        if state.get("schema_version") != RUNTIME_SCHEMA_VERSION:
            raise ContractError("legacy or unknown runtime state cannot be mutated")
        ensure_private_directory(paths.work)
        temporary = paths.work / f".state.{os.getpid()}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(descriptor, canonical_json(state))
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, paths.state_file)
        os.chmod(paths.state_file, 0o600)

    @staticmethod
    def _try_operation_lock(paths: RunPaths, *, blocking: bool = False) -> int | None:
        ensure_private_directory(paths.work)
        lock_path = paths.work / OPERATION_LOCK_NAME
        try:
            descriptor = os.open(
                lock_path,
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600,
            )
        except OSError as exc:
            raise ContractError("operation lock cannot be opened safely") from exc
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_uid != os.getuid()
                or info.st_nlink != 1
            ):
                raise ContractError("operation lock identity or mode is unsafe")
            try:
                flags = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
                fcntl.flock(descriptor, flags)
            except BlockingIOError:
                if blocking:
                    raise ContractError("blocking operation lock acquisition failed")
                os.close(descriptor)
                return None
            return descriptor
        except Exception:
            os.close(descriptor)
            raise

    def _acquire_operation_lock(self, paths: RunPaths, *, blocking: bool = False) -> None:
        if paths.run_id in self._operation_locks:
            raise ContractError("operation lock is already held by this orchestrator")
        descriptor = self._try_operation_lock(paths, blocking=blocking)
        if descriptor is None:
            raise ContractError("another operation is still in progress")
        self._operation_locks[paths.run_id] = descriptor

    def _release_operation_lock(self, paths: RunPaths) -> None:
        descriptor = self._operation_locks.pop(paths.run_id, None)
        if descriptor is None:
            return
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)

    def _enforce_deadline(self, paths: RunPaths, state: dict[str, object]) -> None:
        if state.get("terminal_state") is not TerminalState.RUNNING and state.get("terminal_state") != TerminalState.RUNNING:
            raise ContractError("terminal run allows only status and cleanup")
        deadline = parse_utc_deadline(str(state.get("retention_deadline", "")))
        if self._now().astimezone(UTC) >= deadline:
            self._block(paths, state, "retention deadline reached before operation start")
            raise ContractError("retention deadline reached; only status and cleanup are allowed")

    def _begin(
        self,
        paths: RunPaths,
        state: dict[str, object],
        operation: str,
        expected_phase: str,
        *,
        control_id: str | None = None,
        occurrence: str = "phase",
        target: str = "aggregate",
    ) -> None:
        self._acquire_operation_lock(paths)
        try:
            current = self._load(paths)
            state.clear()
            state.update(current)
            self._enforce_deadline(paths, state)
            if state.get("phase") != expected_phase:
                raise ContractError(f"phase skip or retry rejected: expected {expected_phase}")
            if state.get("active_operation") is not None or operation in state.get("completed_operations", []):
                raise ContractError("operation is already started or completed")
            state["active_operation"] = {
                "name": operation,
                "control_id": control_id,
                "occurrence": occurrence,
                "target": target,
                "started_at": self._now().astimezone(UTC).isoformat().replace("+00:00", "Z"),
            }
            self._save(paths, state)
        except Exception:
            self._release_operation_lock(paths)
            raise

    def _finish(self, paths: RunPaths, state: dict[str, object], operation: str, phase: str) -> None:
        active = state.get("active_operation")
        if not isinstance(active, dict) or active.get("name") != operation:
            raise ContractError("operation completion does not match start")
        completed = state.get("completed_operations")
        if not isinstance(completed, list):
            raise ContractError("invalid completed operation state")
        completed.append(operation)
        state["active_operation"] = None
        state["phase"] = phase
        self._save(paths, state)
        self._release_operation_lock(paths)

    def _block(
        self,
        paths: RunPaths,
        state: dict[str, object],
        reason: str,
        *,
        release_lock: bool = True,
    ) -> None:
        try:
            active = state.get("active_operation")
            if isinstance(active, dict) and isinstance(active.get("control_id"), str):
                record = ControlRecord(
                    key=ControlKey(
                        paths.run_id,
                        active["control_id"],
                        str(active.get("occurrence", "phase")),
                        str(active.get("target", "aggregate")),
                    ),
                    expected_classification="COMPLETED",
                    observed_classification="OPERATION_INTERRUPTED",
                    evidence_digest=hashlib.sha256(reason.encode()).hexdigest(),
                    result=ControlResult.UNVERIFIED,
                    operator_step=str(active.get("name", "unknown")),
                    exit_classification="BLOCKED",
                )
                record_control(paths, record)
            record_decision(
                paths,
                {
                    "record_type": "terminal",
                    "run_id": paths.run_id,
                    "terminal_state": TerminalState.BLOCKED,
                    "real_task_allowed": False,
                    "reason_digest": hashlib.sha256(reason.encode()).hexdigest(),
                },
            )
            state["terminal_state"] = TerminalState.BLOCKED
            state["phase"] = Phase.BLOCKED
            state["active_operation"] = None
            self._save(paths, state)
        finally:
            if release_lock:
                self._release_operation_lock(paths)

    def _run_phase(
        self,
        run_id: str,
        operation: str,
        expected_phase: str,
        next_phase: str,
        action: Callable[[CalibrationDriver], PhaseResult],
        *,
        allowed_controls: set[str],
        control_id: str,
        occurrence: str,
        target: str,
        required_probe_occurrence: str | None = None,
        require_sync_export_coverage: bool = False,
    ) -> dict[str, object]:
        paths = self._paths(run_id)
        state = self._load(paths)
        self._begin(
            paths,
            state,
            operation,
            expected_phase,
            control_id=control_id,
            occurrence=occurrence,
            target=target,
        )
        try:
            result = action(self._driver_factory(paths))
            state = self._load(paths)
            if require_sync_export_coverage:
                self._validate_sync_export_coverage(result)
            self._accept_phase_result(
                paths,
                state,
                result,
                allowed_controls,
                required_probe_occurrence=required_probe_occurrence,
            )
            self._finish(paths, state, operation, next_phase)
            return state
        except Exception as exc:
            self._block(paths, self._load(paths), str(exc))
            raise

    @staticmethod
    def _validate_c03_coverage(result: PhaseResult, occurrence: str) -> None:
        expected = {
            target.target_id
            for target in required_probe_matrix()
            if target.occurrence == occurrence
        }
        control_targets = [
            record.key.target
            for record in result.controls
            if record.key.control_id == "C03"
        ]
        observation_targets: list[str] = []
        for observation in result.observations:
            if type(observation) is not dict or observation.get("control_id") != "C03":
                raise ContractError("C03 phase returned an invalid observation")
            target = observation.get("target")
            reason = observation.get("reason")
            if (
                not isinstance(target, str)
                or observation.get("observed_classification") != ObservationClass.UNAVAILABLE_BASELINE
                or observation.get("result") is not None
                or not isinstance(reason, str)
                or not reason
            ):
                raise ContractError("C03 unavailable baseline observation is invalid")
            observation_targets.append(target)
        coverage = control_targets + observation_targets
        duplicates = sorted({target for target in coverage if coverage.count(target) > 1})
        missing = sorted(expected.difference(coverage))
        unexpected = sorted(set(coverage).difference(expected))
        if duplicates or missing or unexpected:
            raise ContractError(
                "C03 matrix coverage mismatch "
                f"duplicates={duplicates} missing={missing} unexpected={unexpected}"
            )
        if not control_targets:
            raise ContractError("C03 produced no applicable paired-probe controls")

    @staticmethod
    def _validate_sync_export_coverage(result: PhaseResult) -> None:
        expected = {
            (control_id, direction, f"{direction}:{target}")
            for direction in HANDOFF_DIRECTIONS
            for control_id, target in (
                ("C04", "sync-guard"),
                ("C05", "sync-semantics"),
                ("C06", "export-quarantine"),
            )
        }
        actual = [
            (record.key.control_id, record.key.occurrence, record.key.target)
            for record in result.controls
            if record.key.control_id in {"C04", "C05", "C06"}
        ]
        duplicates = sorted({key for key in actual if actual.count(key) > 1})
        missing = sorted(expected.difference(actual))
        unexpected = sorted(set(actual).difference(expected))
        if duplicates or missing or unexpected:
            raise ContractError(
                "sync/export direction coverage mismatch "
                f"duplicates={duplicates} missing={missing} unexpected={unexpected}"
            )

    def _accept_phase_result(
        self,
        paths: RunPaths,
        state: dict[str, object],
        result: PhaseResult,
        allowed_controls: set[str],
        *,
        required_probe_occurrence: str | None = None,
    ) -> None:
        if not result.controls:
            raise ContractError("phase produced no control records")
        if required_probe_occurrence is not None:
            self._validate_c03_coverage(result, required_probe_occurrence)
        required = state.get("required_control_keys")
        if not isinstance(required, list):
            raise ContractError("invalid required control state")
        existing = set(required)
        accepted: list[tuple[ControlRecord, str]] = []
        failures: list[str] = []
        for record in result.controls:
            if type(record) is not ControlRecord or record.key.run_id != paths.run_id:
                raise ContractError("phase returned an invalid control record")
            if record.key.control_id not in allowed_controls:
                raise ContractError("phase returned an arbitrary control ID")
            stable_id = record.key.stable_id()
            if stable_id in existing:
                raise ContractError("same-run control retry rejected")
            accepted.append((record, stable_id))
            existing.add(stable_id)
        for record, stable_id in accepted:
            record_control(paths, record)
            required.append(stable_id)
            if record.result is not ControlResult.PASS:
                failures.append(stable_id)
        for observation in result.observations:
            record_decision(paths, {"record_type": "observation", "run_id": paths.run_id, **observation})
        if failures:
            raise ContractError(f"controls did not pass: {failures}")

    def _validate_lima_binding(
        self,
        paths: RunPaths,
        state: dict[str, object],
    ) -> dict[str, object]:
        binding = state.get("lima_home_binding")
        if type(binding) is not dict:
            raise ContractError("Lima home binding is missing")
        paths.validate_lima_home_binding(binding)
        evidence = load_json(paths.evidence / "lima-home-binding.json")
        if evidence != binding:
            raise ContractError("Lima home binding evidence drifted")
        return binding

    def _capture_lima_snapshot(self, paths: RunPaths) -> LimaListSnapshot:
        result = CommandRunner(paths.lima_home).run(
            ("limactl", "--tty=false", "list", "--all-fields", "--format=json"),
            timeout=30,
            check=False,
        )
        return parse_lima_list(result.returncode, result.stdout, result.stderr)

    def _freshness_evidence(
        self,
        paths: RunPaths,
        state: dict[str, object],
        *,
        stage: str,
    ) -> dict[str, object]:
        binding = self._validate_lima_binding(paths, state)
        socket_lengths = paths.validate_socket_budget(FIXED_INSTANCES)
        snapshot = self._capture_lima_snapshot(paths)
        top_level = inspect_top_level(paths.lima_home)
        path_states = {
            "codex_instance_directory": path_disposition(paths.lima_home / CODEX_INSTANCE),
            "codex_root_disk": path_disposition(paths.lima_home / CODEX_INSTANCE / "disk"),
            "claude_instance_directory": path_disposition(paths.lima_home / CLAUDE_INSTANCE),
            "claude_root_disk": path_disposition(paths.lima_home / CLAUDE_INSTANCE / "disk"),
        }
        evidence = {
            "schema_version": RUNTIME_SCHEMA_VERSION,
            "record_type": "lima_freshness_snapshot",
            "stage": stage,
            "binding_digest": binding.get("binding_digest"),
            "parser_contract_digest": parser_contract_digest(),
            "socket_path_bytes": socket_lengths,
            "list": snapshot.to_evidence(),
            "top_level": top_level.to_evidence(),
            "paths": path_states,
        }
        if snapshot.disposition is not LimaListDisposition.ABSENT:
            raise ContractError("fresh Lima namespace was not strictly absent")
        if (
            top_level.disposition != "CLEAN"
            or top_level.fixed_directories
            or top_level.administrative_directories
            or top_level.unknown_entries
        ):
            raise ContractError("fresh Lima home was not empty")
        if any(value != "ABSENT" for value in path_states.values()):
            raise ContractError("fresh Lima instance or disk path was not absent")
        evidence["snapshot_digest"] = hashlib.sha256(canonical_json(evidence)).hexdigest()
        return evidence

    def preflight(self, run_id: str) -> dict[str, object]:
        paths = self._paths(run_id)
        state = self._load(paths)
        self._begin(paths, state, "preflight", Phase.INITIALIZED, control_id="C00", occurrence="host", target="expected")
        try:
            lock_path = self.harness_root / "versions.lock.json"
            manifest_path = self.harness_root / "manifest.json"
            lock = validate_versions_lock(lock_path)
            validate_manifest(self.harness_root, manifest_path)
            artifacts = lock["artifacts"]
            host = {
                "os": platform.system(),
                "release": platform.release(),
                "machine": platform.machine(),
                "python": verify_binary_identity(
                    Path(artifacts["host_python"]["source"]),
                    artifacts["host_python"]["sha256"],
                    [artifacts["host_python"]["source"], "--version"],
                    artifacts["host_python"]["version"],
                ),
                "limactl": verify_binary_identity(
                    Path(artifacts["host_limactl"]["source"]),
                    artifacts["host_limactl"]["sha256"],
                    [artifacts["host_limactl"]["source"], "--version"],
                    artifacts["host_limactl"]["version"],
                ),
                "rsync": verify_binary_identity(
                    Path("/usr/bin/rsync"),
                    artifacts["host_rsync"]["sha256"],
                    ["/usr/bin/rsync", "--version"],
                    "protocol version 29",
                ),
            }
            if host["os"] != "Darwin" or host["machine"] != "arm64":
                raise ContractError("preflight requires Private Mac arm64 host")
            self._freeze_harness(paths, manifest_path)
            freshness = self._freshness_evidence(paths, state, stage="preflight")
            write_once(paths.evidence / "lima-preflight-snapshot.json", freshness)
            lock_digest = sha256_file(lock_path)
            manifest_digest = sha256_file(manifest_path)
            constraints = {
                "data": "non-sensitive-only",
                "auxiliary_tools": "disabled",
                "policy_owner": "root",
                "human_approval": "required",
                "real_task_allowed": False,
            }
            constraints_digest = hashlib.sha256(canonical_json(constraints)).hexdigest()
            risks = (
                RiskAcceptanceRecord(
                    run_id,
                    "AR-01",
                    "runtime-may-read-own-guest-credential",
                    constraints_digest,
                    RiskDisposition.NOT_PROVIDED_ACCEPTED_RISK,
                ),
                RiskAcceptanceRecord(
                    run_id,
                    "AR-02",
                    "runtime-main-process-egress-not-enforced",
                    constraints_digest,
                    RiskDisposition.NOT_PROVIDED_ACCEPTED_RISK,
                ),
            )
            for risk in risks:
                record_decision(paths, risk)
            identity = {
                "schema_version": RUNTIME_SCHEMA_VERSION,
                "run_id": run_id,
                "objective": "calibrate Private Lima guests before v3 design",
                "prohibitions": [
                    "real tasks",
                    "host credential copy",
                    "API key fallback",
                    "authoritative repository sync",
                    "main-process egress safety claim",
                ],
                "terminal_states": [TerminalState.READY, TerminalState.BLOCKED],
                "real_task_allowed": False,
                "retention_deadline": state["retention_deadline"],
                "lock_digest": lock_digest,
                "manifest_digest": manifest_digest,
                "parser_contract_digest": parser_contract_digest(),
                "lima_home_binding": state["lima_home_binding"],
                "lima_freshness_snapshot_digest": freshness["snapshot_digest"],
                "host": host,
                "accepted_risks": [risk.to_dict() for risk in risks],
            }
            write_once(paths.evidence / "identity.json", identity)
            record = LimaDriver._record(run_id, "C00", "host", "expected", identity, "preflight")
            self._accept_phase_result(paths, state, PhaseResult((record,)), {"C00"})
            target = hashlib.sha256(
                canonical_json(
                    {
                        "lock_digest": lock_digest,
                        "manifest_digest": manifest_digest,
                        "retention_deadline": state["retention_deadline"],
                        "accepted_risks": [risk.to_dict() for risk in risks],
                        "lima_home_binding": state["lima_home_binding"],
                        "parser_contract_digest": parser_contract_digest(),
                        "lima_freshness_snapshot_digest": freshness["snapshot_digest"],
                    }
                )
            ).hexdigest()
            state["approval_targets"]["pre-vm"] = target
            state["preflight_snapshot_digest"] = freshness["snapshot_digest"]
            self._finish(paths, state, "preflight", Phase.PREFLIGHTED)
            return state
        except Exception as exc:
            self._block(paths, state, str(exc))
            raise

    def _freeze_harness(self, paths: RunPaths, manifest_path: Path) -> None:
        if any(paths.frozen_harness.iterdir()):
            raise ContractError("frozen harness must be empty")
        manifest = load_json(manifest_path)
        records = manifest.get("files")
        if not isinstance(records, list):
            raise ContractError("invalid harness manifest")
        sources = ["manifest.json", *(str(record["path"]) for record in records)]
        for relative in sources:
            source = self.harness_root / relative
            destination = paths.frozen_harness / relative
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copyfile(source, destination, follow_symlinks=False)
            os.chmod(destination, 0o400)
        for directory in sorted(
            (item for item in paths.frozen_harness.rglob("*") if item.is_dir()),
            key=lambda item: len(item.parts),
            reverse=True,
        ):
            os.chmod(directory, 0o500)
        os.chmod(paths.frozen_harness, 0o500)
        validate_manifest(paths.frozen_harness)

    def _approve(self, run_id: str, gate: str, expected_phase: str, next_phase: str) -> dict[str, object]:
        paths = self._paths(run_id)
        state = self._load(paths)
        operation = f"approve {gate}"
        self._begin(paths, state, operation, expected_phase)
        try:
            targets = state.get("approval_targets")
            target = targets.get(gate) if isinstance(targets, dict) else None
            if not isinstance(target, str) or len(target) != 64:
                raise ContractError("approval target is not prepared")
            if not self._stdin_isatty() or not self._stdout_isatty():
                raise ContractError("approval requires real stdin and stdout TTYs")
            entered_gate = self._input(f"Retype gate name ({gate}): ")
            entered_digest = self._input(f"Retype target digest ({target}): ")
            if entered_gate != gate or entered_digest != target:
                raise ContractError("human approval did not exactly match gate and digest")
            record = ApprovalRecord(
                run_id,
                gate,
                target,
                self._now().astimezone(UTC).isoformat().replace("+00:00", "Z"),
                hashlib.sha256(canonical_json([entered_gate, entered_digest])).hexdigest(),
            )
            record_decision(paths, record)
            if gate == "pre-vm":
                os.chmod(paths.evidence / "retention.json", 0o400)
            self._finish(paths, state, operation, next_phase)
            return state
        except Exception as exc:
            self._block(paths, state, str(exc))
            raise

    def approve_pre_vm(self, run_id: str) -> dict[str, object]:
        return self._approve(run_id, "pre-vm", Phase.PREFLIGHTED, Phase.PRE_VM_APPROVED)

    def provision(self, run_id: str) -> dict[str, object]:
        paths = self._paths(run_id)

        def action(driver: CalibrationDriver) -> PhaseResult:
            self._register_retention(paths)
            validate_manifest(self.harness_root)
            validate_manifest(paths.frozen_harness)
            current = self._load(paths)
            if not isinstance(current.get("preflight_snapshot_digest"), str):
                raise ContractError("preflight freshness snapshot is not bound to H1")
            self._validate_h1_binding(paths, current)
            freshness = self._freshness_evidence(paths, current, stage="pre-create")
            append_jsonl(paths.evidence / "lima-provision-snapshots.jsonl", freshness)
            return driver.provision(run_id, paths.frozen_harness)

        state = self._run_phase(
            run_id,
            "provision",
            Phase.PRE_VM_APPROVED,
            Phase.PROVISIONED,
            action,
            allowed_controls={"C00", "C01"},
            control_id="C00",
            occurrence="guest",
            target="aggregate",
        )
        target = self._controls_digest(self._paths(run_id), {"C00", "C01"})
        state["approval_targets"]["pre-auth"] = target
        self._save(self._paths(run_id), state)
        return state

    def _validate_h1_binding(self, paths: RunPaths, state: dict[str, object]) -> None:
        identity = load_json(paths.evidence / "identity.json")
        if (
            identity.get("schema_version") != RUNTIME_SCHEMA_VERSION
            or identity.get("manifest_digest")
            != sha256_file(self.harness_root / "manifest.json")
            or identity.get("manifest_digest")
            != sha256_file(paths.frozen_harness / "manifest.json")
            or identity.get("parser_contract_digest") != parser_contract_digest()
            or identity.get("lima_freshness_snapshot_digest")
            != state.get("preflight_snapshot_digest")
        ):
            raise ContractError("H1 harness, parser, or freshness binding drifted")

    def _register_retention(self, paths: RunPaths) -> None:
        state = self._load(paths)
        lock = load_json(paths.frozen_harness / "versions.lock.json")
        python_path = Path(lock["artifacts"]["host_python"]["source"])
        wrapper = paths.cleanup / "deadline-cleanup.sh"
        plist = paths.cleanup / f"{LABEL_PREFIX}.{paths.run_id}.plist"
        wrapper_text = render_deadline_wrapper(
            python_path,
            paths.frozen_harness / "calibrate.py",
            self.state_root,
            self.lima_pool_root,
            paths.run_id,
            str(state["retention_deadline"]),
        )
        descriptor = os.open(wrapper, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
        try:
            os.write(descriptor, wrapper_text.encode())
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        plist_bytes = render_launch_agent(
            paths.run_id,
            str(state["retention_deadline"]),
            wrapper,
        )
        descriptor = os.open(plist, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(descriptor, plist_bytes)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        runner = CommandRunner(paths.lima_home)
        bootstrap, print_job, kickstart = launchctl_commands(
            paths.run_id,
            plist,
            os.getuid(),
        )
        runner.run(bootstrap, timeout=30)
        readback = runner.run(print_job, timeout=30)
        validate_launchctl_print_readback(
            readback.stdout,
            target=print_job[-1],
            plist=plist,
            wrapper=wrapper,
        )
        validate_wrapper_readback(wrapper, wrapper_text)
        runner.run(kickstart, timeout=30)

    def approve_pre_auth(self, run_id: str, *, code_paste_feasible: bool) -> dict[str, object]:
        if not code_paste_feasible:
            paths = self._paths(run_id)
            state = self._load(paths)
            self._block(paths, state, "Claude code-paste login unavailable without forwarding")
            raise ContractError("code-paste feasibility is required; boundary will not be relaxed")
        paths = self._paths(run_id)
        state = self._load(paths)
        self._enforce_deadline(paths, state)
        state["approval_targets"]["pre-auth"] = hashlib.sha256(
            canonical_json(
                {
                    "controls_digest": self._controls_digest(paths, {"C00", "C01"}),
                    "claude_code_paste_feasible_without_forwarding": True,
                }
            )
        ).hexdigest()
        self._save(paths, state)
        return self._approve(run_id, "pre-auth", Phase.PROVISIONED, Phase.PRE_AUTH_APPROVED)

    def authenticate(self, run_id: str, runtime: str) -> dict[str, object]:
        if runtime not in RUNTIMES:
            raise ContractError("runtime must be codex or claude")
        expected = Phase.PRE_AUTH_APPROVED if runtime == "codex" else Phase.CODEX_AUTHENTICATED
        next_phase = Phase.CODEX_AUTHENTICATED if runtime == "codex" else Phase.AUTHENTICATED
        paths = self._paths(run_id)

        def action(driver: CalibrationDriver) -> PhaseResult:
            state = self._load(paths)
            active = state.get("active_operation")
            if not isinstance(active, dict) or active.get("name") != f"authenticate {runtime}":
                raise ContractError("authentication attempt state does not match active operation")
            attempts = state.get("authentication_attempts")
            if not isinstance(attempts, list) or runtime in attempts:
                raise ContractError("authentication attempt state is invalid")
            attempts.append(runtime)
            self._save(paths, state)
            return driver.authenticate(run_id, runtime, "initial")

        return self._run_phase(
            run_id,
            f"authenticate {runtime}",
            expected,
            next_phase,
            action,
            allowed_controls={"C02"},
            control_id="C02",
            occurrence="initial",
            target=runtime,
        )

    def isolation(self, run_id: str) -> dict[str, object]:
        return self._run_phase(
            run_id,
            "run isolation",
            Phase.AUTHENTICATED,
            Phase.ISOLATION_COMPLETE,
            lambda driver: driver.isolation(run_id, "initial"),
            allowed_controls={"C03"},
            control_id="C03",
            occurrence="initial",
            target="matrix",
            required_probe_occurrence="initial",
        )

    def sync_export(self, run_id: str) -> dict[str, object]:
        return self._run_phase(
            run_id,
            "run sync-export",
            Phase.ISOLATION_COMPLETE,
            Phase.SYNC_EXPORT_COMPLETE,
            lambda driver: driver.sync_export(run_id),
            allowed_controls={"C04", "C05", "C06"},
            control_id="C04",
            occurrence="initial",
            target="sync-export",
            require_sync_export_coverage=True,
        )

    def approve_pre_handoff(self, run_id: str, direction: str) -> dict[str, object]:
        if direction not in HANDOFF_DIRECTIONS:
            raise ContractError("handoff direction must be forward or reverse")
        paths = self._paths(run_id)
        state = self._load(paths)
        self._enforce_deadline(paths, state)
        expected = Phase.SYNC_EXPORT_COMPLETE if direction == "forward" else Phase.FORWARD_COMPLETE
        gate = f"pre-handoff-{direction}"
        state["approval_targets"][gate] = self._controls_digest(paths, {"C04", "C05", "C06", "C07"})
        self._save(paths, state)
        next_phase = Phase.FORWARD_APPROVED if direction == "forward" else Phase.REVERSE_APPROVED
        return self._approve(run_id, gate, expected, next_phase)

    def handoff(self, run_id: str, direction: str) -> dict[str, object]:
        if direction not in HANDOFF_DIRECTIONS:
            raise ContractError("handoff direction must be forward or reverse")
        expected = Phase.FORWARD_APPROVED if direction == "forward" else Phase.REVERSE_APPROVED
        next_phase = Phase.FORWARD_COMPLETE if direction == "forward" else Phase.REVERSE_COMPLETE
        return self._run_phase(
            run_id,
            f"run handoff-{direction}",
            expected,
            next_phase,
            lambda driver: driver.handoff(run_id, direction),
            allowed_controls={"C07"},
            control_id="C07",
            occurrence=direction,
            target=direction,
        )

    def restart(self, run_id: str) -> dict[str, object]:
        return self._run_phase(
            run_id,
            "run restart",
            Phase.REVERSE_COMPLETE,
            Phase.RESTART_COMPLETE,
            lambda driver: driver.restart(run_id),
            allowed_controls={"C02", "C03"},
            control_id="C08",
            occurrence="post_restart",
            target="aggregate",
            required_probe_occurrence="post_restart",
        )

    def prepare_seal(self, run_id: str) -> dict[str, object]:
        paths = self._paths(run_id)
        state = self._load(paths)
        self._begin(paths, state, "prepare-seal", Phase.RESTART_COMPLETE, control_id="C08", occurrence="seal", target="aggregate")
        try:
            digest = seal_input_digest(paths)
            state["seal_input_digest"] = digest
            state["approval_targets"]["final-seal"] = digest
            self._finish(paths, state, "prepare-seal", Phase.SEAL_PREPARED)
            return state
        except Exception as exc:
            self._block(paths, state, str(exc))
            raise

    def approve_final_seal(self, run_id: str) -> dict[str, object]:
        return self._approve(run_id, "final-seal", Phase.SEAL_PREPARED, Phase.FINAL_SEAL_APPROVED)

    def seal(self, run_id: str) -> dict[str, object]:
        paths = self._paths(run_id)
        state = self._load(paths)
        self._begin(paths, state, "seal", Phase.FINAL_SEAL_APPROVED, control_id="C08", occurrence="seal", target="aggregate")
        try:
            stopped = self._driver_factory(paths).stop_for_seal(run_id)
            c08 = LimaDriver._record(run_id, "C08", "seal", "aggregate", stopped, "seal")
            self._accept_phase_result(paths, state, PhaseResult((c08,)), {"C08"})
            records = self._read_controls(paths)
            required = tuple(self._parse_control_key(value) for value in state["required_control_keys"])
            aggregate = aggregate_controls(records, required)
            if aggregate.terminal is not TerminalState.READY:
                raise ContractError("control aggregation did not reach ready")
            approved = state.get("seal_input_digest")
            if not isinstance(approved, str):
                raise ContractError("seal input was not prepared")
            seal_digest = seal(
                paths,
                terminal=TerminalState.READY,
                approved_digest=approved,
                retention_deadline=str(state["retention_deadline"]),
                control_records=records,
            )
            state["seal_digest"] = seal_digest
            state["terminal_state"] = TerminalState.READY
            self._finish(paths, state, "seal", Phase.SEALED)
            return state
        except Exception as exc:
            self._block(paths, state, str(exc))
            raise

    def status(self, run_id: str) -> dict[str, object]:
        paths = self._paths(run_id)
        state = self._load(paths, allow_legacy=True)
        if state.get("schema_version") == 1:
            return {
                "run_id": run_id,
                "schema_version": 1,
                "phase": state.get("phase"),
                "terminal_state": state.get("terminal_state"),
                "operation_state": "LEGACY_READ_ONLY",
                "active_operation": None,
                "real_task_allowed": False,
                "retention_deadline": state.get("retention_deadline"),
                "seal_digest": state.get("seal_digest"),
                "cleanup_started": state.get("cleanup_started", False),
                "cleanup_verified": state.get("cleanup_verified", False),
                "cleanup_disposition": "LEGACY_READ_ONLY",
            }
        active = state.get("active_operation")
        operation_state = "IDLE"
        active_name: str | None = None
        if active is not None:
            if not isinstance(active, dict) or not isinstance(active.get("name"), str):
                raise ContractError("active operation state is invalid")
            descriptor = self._try_operation_lock(paths)
            if descriptor is None:
                operation_state = "IN_PROGRESS"
                active_name = active["name"]
            else:
                try:
                    state = self._load(paths)
                    active = state.get("active_operation")
                    if active is not None:
                        self._block(paths, state, "started operation lacked a completion record")
                        operation_state = "ORPHANED_BLOCKED"
                finally:
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
                    os.close(descriptor)
        return {
            "run_id": run_id,
            "schema_version": state["schema_version"],
            "phase": state["phase"],
            "terminal_state": state["terminal_state"],
            "operation_state": operation_state,
            "active_operation": active_name,
            "real_task_allowed": False,
            "retention_deadline": state["retention_deadline"],
            "seal_digest": state.get("seal_digest"),
            "cleanup_started": state.get("cleanup_started", False),
            "cleanup_verified": state.get("cleanup_verified", False),
            "cleanup_disposition": state.get("cleanup_disposition"),
        }

    def cleanup(self, run_id: str, *, cause: str) -> dict[str, object]:
        if cause not in {"deadline", "abandonment", "exposure", "cohort-completion"}:
            raise ContractError("invalid cleanup cause")
        paths = self._paths(run_id)
        self._load(paths)
        self._acquire_operation_lock(paths, blocking=True)
        try:
            return self._cleanup_locked(paths, cause=cause)
        finally:
            self._release_operation_lock(paths)

    def _cleanup_locked(self, paths: RunPaths, *, cause: str) -> dict[str, object]:
        run_id = paths.run_id
        state = self._load(paths)
        if state.get("cleanup_started") is True:
            raise ContractError("same-run cleanup retry is prohibited")
        attempts = state.get("authentication_attempts", [])
        if not isinstance(attempts, list) or any(runtime not in RUNTIMES for runtime in attempts):
            raise ContractError("authentication attempt state is invalid")
        revoke_required = cause == "exposure" or bool(attempts)
        had_active_operation = state.get("active_operation") is not None
        prior_terminal = state.get("terminal_state")
        prior_phase = state.get("phase")
        state["cleanup_started"] = True
        state["cleanup_cause"] = cause
        state["cleanup_disposition"] = CleanupDisposition.CLEANUP_MANUAL_REQUIRED
        state["account_revoke_required"] = revoke_required
        state["pre_cleanup_terminal_state"] = prior_terminal
        state["pre_cleanup_phase"] = prior_phase
        state["terminal_state"] = TerminalState.BLOCKED
        state["phase"] = Phase.BLOCKED
        state["active_operation"] = None
        self._save(paths, state)
        append_jsonl(
            paths.cleanup / "attempts.jsonl",
            {
                "schema_version": RUNTIME_SCHEMA_VERSION,
                "record_type": "cleanup_attempt",
                "event": "STARTED",
                "run_id": run_id,
                "cause": cause,
                "account_revoke_required": revoke_required,
            },
        )
        if had_active_operation:
            return self._manual_cleanup(paths, state, "orphaned operation")
        try:
            self._validate_lima_binding(paths, state)
            snapshot = self._capture_lima_snapshot(paths)
            top_level = inspect_top_level(paths.lima_home)
            if snapshot.disposition is LimaListDisposition.UNKNOWN:
                return self._manual_cleanup(paths, state, "Lima list was UNKNOWN")
            if top_level.disposition != "CLEAN" or top_level.unknown_entries:
                return self._manual_cleanup(paths, state, "Lima home contained unrelated entries")
            history = self._read_lima_identity_history(paths)
            if not self._provision_evidence_is_coherent(paths, snapshot):
                return self._manual_cleanup(paths, state, "provision evidence was incomplete")
            live = fixed_identity_map(snapshot) if snapshot.disposition is LimaListDisposition.RECOGNIZED else {}
            if set(top_level.fixed_directories) != set(live):
                return self._manual_cleanup(paths, state, "instance directory and list identity disagreed")
            for identity in live.values():
                if not any(self._same_lima_identity(identity, recorded) for recorded in history):
                    return self._manual_cleanup(paths, state, "live Lima identity was not recorded")
            runner = CommandRunner(paths.lima_home)
            for runtime, instance in (("codex", CODEX_INSTANCE), ("claude", CLAUDE_INSTANCE)):
                identity = live.get(instance)
                if identity is None:
                    continue
                if identity.status == "Running":
                    if not self._cleanup_recheck(paths, identity):
                        return self._manual_cleanup(paths, state, "pre-stop identity recheck failed")
                    result = runner.run(
                        ("limactl", "--tty=false", "stop", instance),
                        timeout=180,
                        check=False,
                    )
                    if result.returncode != 0:
                        return self._manual_cleanup(paths, state, "Lima stop failed")
                    stopped = self._recognized_identity(paths, instance, "Stopped")
                    if stopped is None or not self._same_lima_identity(identity, stopped, ignore_status=True):
                        return self._manual_cleanup(paths, state, "post-stop identity recheck failed")
                    identity = stopped
                if identity.status != "Stopped" or not self._cleanup_recheck(paths, identity):
                    return self._manual_cleanup(paths, state, "pre-delete identity recheck failed")
                result = runner.run(
                    ("limactl", "--tty=false", "delete", instance),
                    timeout=180,
                    check=False,
                )
                if result.returncode != 0:
                    return self._manual_cleanup(paths, state, "Lima delete failed")
            after = self._capture_lima_snapshot(paths)
            if after.disposition is not LimaListDisposition.ABSENT:
                return self._manual_cleanup(paths, state, "post-delete namespace was not absent")
            fixed_paths = tuple(
                paths.lima_home / instance / suffix
                for instance in FIXED_INSTANCES
                for suffix in (Path(), Path("disk"))
            )
            if any(path_disposition(path) != "ABSENT" for path in fixed_paths):
                return self._manual_cleanup(paths, state, "post-delete fixed path remained")
            top_after = inspect_top_level(paths.lima_home)
            if (
                top_after.disposition != "CLEAN"
                or top_after.fixed_directories
                or top_after.administrative_directories
                or top_after.unknown_entries
            ):
                return self._manual_cleanup(paths, state, "physical Lima home was not empty")
            self._validate_lima_binding(paths, state)
            try:
                paths.lima_home.rmdir()
            except OSError:
                return self._manual_cleanup(paths, state, "one-shot Lima home rmdir failed")
            if path_disposition(paths.lima_home) != "ABSENT":
                return self._manual_cleanup(paths, state, "physical Lima home remained after rmdir")
            if not self._disable_retention_job(paths):
                return self._manual_cleanup(paths, state, "retention job could not be disabled")
        except ContractError:
            return self._manual_cleanup(paths, state, "cleanup observation was inconclusive")
        if revoke_required or any(
            path_disposition(path) != "ABSENT"
            for path in (
                paths.work / "staging",
                paths.work / "quarantine",
                paths.work / "raw-tmp",
                paths.work / "listeners",
            )
        ):
            return self._manual_cleanup(paths, state, "human disposition is still required")
        state["cleanup_disposition"] = CleanupDisposition.CLEANUP_VERIFIED
        state["cleanup_verified"] = True
        if prior_terminal == TerminalState.READY and cause != "exposure":
            state["terminal_state"] = TerminalState.READY
            state["phase"] = prior_phase
        append_jsonl(
            paths.cleanup / "attempts.jsonl",
            {
                "schema_version": RUNTIME_SCHEMA_VERSION,
                "record_type": "cleanup_attempt",
                "event": "COMPLETED",
                "run_id": run_id,
                "outcome": "CLEANUP_VERIFIED",
            },
        )
        self._append_cleanup_attestation(paths, state, verified=True)
        self._save(paths, state)
        return state

    @staticmethod
    def _same_lima_identity(
        left: LimaIdentity,
        right: LimaIdentity,
        *,
        ignore_status: bool = False,
    ) -> bool:
        return (
            left.name == right.name
            and (ignore_status or left.status == right.status)
            and left.directory == right.directory
            and left.vm_type == right.vm_type
            and left.arch == right.arch
            and left.cpus == right.cpus
            and left.memory == right.memory
            and left.disk == right.disk
        )

    @staticmethod
    def _read_lima_identity_history(paths: RunPaths) -> tuple[LimaIdentity, ...]:
        path = paths.evidence / "lima-identities.jsonl"
        if not path.exists():
            return ()
        identities: list[LimaIdentity] = []
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
            for line in lines:
                value = json.loads(line)
                if value.get("schema_version") != RUNTIME_SCHEMA_VERSION:
                    raise ContractError("Lima identity evidence schema drifted")
                identities.append(
                    LimaIdentity(
                        name=value.get("name", ""),
                        status=value.get("status", ""),
                        directory=value.get("directory", ""),
                        vm_type=value.get("vm_type", ""),
                        arch=value.get("arch", ""),
                        cpus=value.get("cpus"),
                        memory=value.get("memory"),
                        disk=value.get("disk"),
                    )
                )
        except (OSError, json.JSONDecodeError) as exc:
            raise ContractError("Lima identity evidence is unreadable") from exc
        return tuple(identities)

    @staticmethod
    def _provision_evidence_is_coherent(paths: RunPaths, snapshot: LimaListSnapshot) -> bool:
        path = paths.evidence / "provision-attempts.jsonl"
        if not path.exists():
            return snapshot.disposition is LimaListDisposition.ABSENT
        try:
            records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        except (OSError, json.JSONDecodeError):
            return False
        grouped: dict[tuple[str, str], list[dict[str, object]]] = {}
        for record in records:
            if record.get("schema_version") != RUNTIME_SCHEMA_VERSION:
                return False
            key = (str(record.get("runtime")), str(record.get("action")))
            if key[0] not in RUNTIMES or key[1] not in {"create", "start"}:
                return False
            grouped.setdefault(key, []).append(record)
        for values in grouped.values():
            if (
                len(values) != 2
                or values[0].get("event") != ProvisionAttemptEvent.STARTED
                or values[1].get("event") != ProvisionAttemptEvent.COMPLETED
                or values[1].get("outcome") != ProvisionAttemptOutcome.SUCCESS
            ):
                return False
        present_names = {identity.name for identity in snapshot.identities}
        for runtime, instance in (("codex", CODEX_INSTANCE), ("claude", CLAUDE_INSTANCE)):
            has_create = (runtime, "create") in grouped
            has_start = (runtime, "start") in grouped
            if has_create != (instance in present_names) or (has_start and not has_create):
                return False
        if snapshot.disposition is LimaListDisposition.RECOGNIZED:
            for identity in snapshot.identities:
                runtime = "codex" if identity.name == CODEX_INSTANCE else "claude" if identity.name == CLAUDE_INSTANCE else ""
                if not runtime or (runtime, "create") not in grouped:
                    return False
                if identity.status == "Running" and (runtime, "start") not in grouped:
                    return False
        return True

    def _recognized_identity(
        self,
        paths: RunPaths,
        instance: str,
        status: str,
    ) -> LimaIdentity | None:
        snapshot = self._capture_lima_snapshot(paths)
        if snapshot.disposition is not LimaListDisposition.RECOGNIZED:
            return None
        try:
            identity = fixed_identity_map(snapshot).get(instance)
        except ContractError:
            return None
        return identity if identity is not None and identity.status == status else None

    def _cleanup_recheck(self, paths: RunPaths, expected: LimaIdentity) -> bool:
        current = self._recognized_identity(paths, expected.name, expected.status)
        return current is not None and self._same_lima_identity(expected, current)

    def _manual_cleanup(
        self,
        paths: RunPaths,
        state: dict[str, object],
        reason: str,
    ) -> dict[str, object]:
        state["cleanup_disposition"] = CleanupDisposition.CLEANUP_MANUAL_REQUIRED
        state["cleanup_verified"] = False
        state["terminal_state"] = TerminalState.BLOCKED
        state["phase"] = Phase.BLOCKED
        append_jsonl(
            paths.cleanup / "attempts.jsonl",
            {
                "schema_version": RUNTIME_SCHEMA_VERSION,
                "record_type": "cleanup_attempt",
                "event": "COMPLETED",
                "run_id": paths.run_id,
                "outcome": CleanupDisposition.CLEANUP_MANUAL_REQUIRED,
                "reason_digest": hashlib.sha256(reason.encode()).hexdigest(),
            },
        )
        self._append_cleanup_attestation(paths, state, verified=False)
        self._save(paths, state)
        return state

    @staticmethod
    def _cleanup_seal_binding(paths: RunPaths, state: dict[str, object]) -> str:
        binding = state.get("seal_digest")
        if isinstance(binding, str):
            return binding
        return hashlib.sha256(
            canonical_json(
                {
                    "run_id": paths.run_id,
                    "retention_deadline": state["retention_deadline"],
                    "preseal_cleanup": True,
                    "schema_version": RUNTIME_SCHEMA_VERSION,
                }
            )
        ).hexdigest()

    def _append_cleanup_attestation(
        self,
        paths: RunPaths,
        state: dict[str, object],
        *,
        verified: bool,
    ) -> None:
        observations = {
            name: "ABSENT" if verified else "UNKNOWN"
            for name in REQUIRED_ABSENCE
        }
        record = verify_cleanup(
            paths.run_id,
            self._cleanup_seal_binding(paths, state),
            observations,
            account_revoke_required=bool(state.get("account_revoke_required")),
            revoke_human_confirmed=verified,
        )
        append_jsonl(paths.cleanup / "attestations.jsonl", record.to_dict())

    def _disable_retention_job(self, paths: RunPaths) -> bool:
        runner = CommandRunner(paths.lima_home)
        target = f"gui/{os.getuid()}/{LABEL_PREFIX}.{paths.run_id}"
        try:
            current = runner.run(("launchctl", "print", target), timeout=30, check=False)
        except ContractError:
            return False
        if current.returncode != 0:
            diagnostic = f"{current.stdout}\n{current.stderr}".lower()
            return "could not find service" in diagnostic or "service not found" in diagnostic
        try:
            stopped = runner.run(("launchctl", "bootout", target), timeout=30, check=False)
            readback = runner.run(("launchctl", "print", target), timeout=30, check=False)
        except ContractError:
            return False
        if stopped.returncode != 0 or readback.returncode == 0:
            return False
        diagnostic = f"{readback.stdout}\n{readback.stderr}".lower()
        return "could not find service" in diagnostic or "service not found" in diagnostic

    def verify_cleanup(self, run_id: str, *, revoke_human_confirmed: bool) -> dict[str, object]:
        paths = self._paths(run_id)
        state = self._load(paths)
        if state.get("cleanup_started") is not True:
            raise ContractError("cleanup has not started")
        if revoke_human_confirmed:
            phrase = f"account-revoke-confirmed:{run_id}"
            if not self._stdin_isatty() or not self._stdout_isatty():
                raise ContractError("account revoke confirmation requires real TTYs")
            if self._input(f"Retype revoke confirmation ({phrase}): ") != phrase:
                raise ContractError("account revoke confirmation did not exactly match")
            append_jsonl(
                paths.cleanup / "decisions.jsonl",
                {
                    "schema_version": RUNTIME_SCHEMA_VERSION,
                    "record_type": "revoke_confirmation",
                    "run_id": run_id,
                    "confirmed": True,
                    "confirmed_at": self._now().astimezone(UTC).isoformat().replace("+00:00", "Z"),
                },
            )
        snapshot = self._capture_lima_snapshot(paths)
        list_absent = snapshot.disposition is LimaListDisposition.ABSENT
        list_unknown = snapshot.disposition is LimaListDisposition.UNKNOWN
        listed_names: set[str] | None = None
        if snapshot.disposition is LimaListDisposition.RECOGNIZED:
            try:
                listed_names = set(fixed_identity_map(snapshot))
            except ContractError:
                list_unknown = True

        def instance_absent(instance: str) -> bool | None:
            if list_absent:
                return True
            if list_unknown or listed_names is None:
                return None
            return instance not in listed_names

        def path_absent(path: Path) -> bool | None:
            value = path_disposition(path)
            return True if value == "ABSENT" else False if value == "PRESENT" else None

        runner = CommandRunner(paths.lima_home)

        def launchagent_absent() -> bool | None:
            result = runner.run(
                (
                    "launchctl",
                    "print",
                    f"gui/{os.getuid()}/{LABEL_PREFIX}.{run_id}",
                ),
                timeout=30,
                check=False,
            )
            if result.returncode == 0:
                return False
            diagnostic = f"{result.stdout}\n{result.stderr}".lower()
            if "could not find service" in diagnostic or "service not found" in diagnostic:
                return True
            raise ContractError("launchagent read-back was inconclusive")

        try:
            binding = state.get("lima_home_binding")
            if type(binding) is not dict:
                raise ContractError("Lima binding state is invalid")
            paths.read_binding_registry(binding)
            binding_valid = True
        except ContractError:
            binding_valid = False
        diagnostics: dict[str, str] = {}
        observations = collect_absence(
            (
                ("codex_instance", lambda: instance_absent(CODEX_INSTANCE)),
                ("claude_instance", lambda: instance_absent(CLAUDE_INSTANCE)),
                ("codex_instance_directory", lambda: path_absent(paths.lima_home / CODEX_INSTANCE)),
                ("claude_instance_directory", lambda: path_absent(paths.lima_home / CLAUDE_INSTANCE)),
                ("codex_root_disk", lambda: path_absent(paths.lima_home / CODEX_INSTANCE / "disk")),
                ("claude_root_disk", lambda: path_absent(paths.lima_home / CLAUDE_INSTANCE / "disk")),
                ("lima_home", lambda: path_absent(paths.lima_home) if binding_valid else None),
                ("staging", lambda: path_absent(paths.work / "staging")),
                ("quarantine", lambda: path_absent(paths.work / "quarantine")),
                ("raw_tmp", lambda: path_absent(paths.work / "raw-tmp")),
                ("listener", lambda: path_absent(paths.work / "listeners")),
                ("launchagent_job", launchagent_absent),
            ),
            diagnostics=diagnostics,
        )
        if set(observations) != set(REQUIRED_ABSENCE):
            raise ContractError("cleanup read-back set drifted")
        binding = self._cleanup_seal_binding(paths, state)
        record = verify_cleanup(
            run_id,
            binding,
            observations,
            account_revoke_required=bool(state.get("account_revoke_required")),
            revoke_human_confirmed=revoke_human_confirmed,
            diagnostics=diagnostics,
        )
        append_jsonl(paths.cleanup / "attestations.jsonl", record.to_dict())
        state["cleanup_verified"] = record.cleanup_verified
        state["cleanup_disposition"] = record.disposition
        if not record.cleanup_verified:
            state["terminal_state"] = TerminalState.BLOCKED
            state["phase"] = Phase.BLOCKED
        self._save(paths, state)
        return state

    @staticmethod
    def _parse_control_key(value: str) -> ControlKey:
        pieces = value.split(":", 3)
        if len(pieces) != 4:
            raise ContractError("stored control key is invalid")
        return ControlKey(*pieces)

    @staticmethod
    def _read_controls(paths: RunPaths) -> tuple[ControlRecord, ...]:
        path = paths.evidence / "controls.jsonl"
        records: list[ControlRecord] = []
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            raise ContractError("cannot read control evidence") from exc
        for line in lines:
            value = json.loads(line)
            key = value.get("key")
            if (
                value.get("schema_version") != RUNTIME_SCHEMA_VERSION
                or value.get("record_type") != "control"
                or not isinstance(key, dict)
            ):
                raise ContractError("non-control record found in control evidence")
            records.append(
                ControlRecord(
                    key=ControlKey(key["run_id"], key["control_id"], key["occurrence"], key["target"]),
                    expected_classification=value["expected_classification"],
                    observed_classification=value["observed_classification"],
                    evidence_digest=value["evidence_digest"],
                    result=ControlResult(value["result"]),
                    operator_step=value["operator_step"],
                    exit_classification=value.get("exit_classification"),
                )
            )
        return tuple(records)

    @staticmethod
    def _controls_digest(paths: RunPaths, ids: set[str]) -> str:
        selected = [record.to_dict() for record in Orchestrator._read_controls(paths) if record.key.control_id in ids]
        if not selected:
            raise ContractError("approval control set is empty")
        return hashlib.sha256(canonical_json(selected)).hexdigest()
