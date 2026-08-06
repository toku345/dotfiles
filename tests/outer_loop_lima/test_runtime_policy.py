from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.identities import compare_effective_seed, load_toml_flat  # noqa: E402
from lib.model import ContractError  # noqa: E402
from runtime import claude, codex  # noqa: E402


HOST_STYLE_MOUNT_FILTER = (
    "grep -Fvx '/mnt/lima-cidata' | "
    "grep -Eq '^/(Users|Volumes|mnt/lima-|home/lima-provision/.*share)'"
)


def load_sanitizer():
    path = HARNESS / "guest" / "sanitize-auth.py"
    spec = importlib.util.spec_from_file_location("sanitize_auth", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load sanitizer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def unflatten(flattened: dict[str, object]) -> dict[str, object]:
    root: dict[str, object] = {}
    for path, value in flattened.items():
        current = root
        pieces = path.split(".")
        for piece in pieces[:-1]:
            child = current.setdefault(piece, {})
            if not isinstance(child, dict):
                raise AssertionError("invalid test mapping")
            current = child
        current[pieces[-1]] = value
    return root


class RuntimePolicyTests(unittest.TestCase):
    @staticmethod
    def codex_seed_contract(
        root: Path,
        *,
        approval_policy: object = "never",
        sandbox_mode: object = "workspace-write",
        web_search: object = "disabled",
        allowed_approval_policies: object = ("never",),
        allowed_sandbox_modes: object = ("read-only", "workspace-write"),
        allowed_web_search_modes: object = ("disabled",),
    ) -> tuple[Path, Path]:
        def toml_value(value: object) -> str:
            if isinstance(value, str):
                return json.dumps(value)
            if isinstance(value, tuple):
                return "[" + ", ".join(toml_value(item) for item in value) + "]"
            if isinstance(value, bool):
                return str(value).lower()
            raise AssertionError(f"unsupported TOML fixture value: {value!r}")

        config = root / "config.toml"
        requirements = root / "requirements.toml"
        config.write_text(
            "\n".join(
                (
                    f"approval_policy = {toml_value(approval_policy)}",
                    f"sandbox_mode = {toml_value(sandbox_mode)}",
                    f"web_search = {toml_value(web_search)}",
                    "",
                )
            ),
            encoding="utf-8",
        )
        requirements.write_text(
            "\n".join(
                (
                    "allowed_approval_policies = "
                    f"{toml_value(allowed_approval_policies)}",
                    "allowed_sandbox_modes = "
                    f"{toml_value(allowed_sandbox_modes)}",
                    "allowed_web_search_modes = "
                    f"{toml_value(allowed_web_search_modes)}",
                    "",
                )
            ),
            encoding="utf-8",
        )
        return config, requirements

    @staticmethod
    def codex_0144_lock() -> dict[str, object]:
        return {
            "artifacts": {
                "codex_base": {"version": "0.144.5"},
                "codex_linux_arm64": {"version": "0.144.5-linux-arm64"},
            }
        }

    def test_codex_0144_seed_contract_accepts_exact_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config, requirements = self.codex_seed_contract(Path(temporary))
            codex.validate_codex_0144_seed_contract(
                config,
                requirements,
                self.codex_0144_lock(),
            )

    def test_repository_codex_0144_seed_contract_is_valid(self) -> None:
        lock = json.loads((HARNESS / "versions.lock.json").read_text(encoding="utf-8"))
        codex.validate_codex_0144_seed_contract(
            HARNESS / "seeds/codex/config.toml",
            HARNESS / "seeds/codex/requirements.toml",
            lock,
        )

    def test_codex_0144_seed_contract_rejects_active_value_mismatch(self) -> None:
        cases = {
            "approval_policy": "on-request",
            "sandbox_mode": "read-only",
            "web_search": "live",
        }
        for field, value in cases.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                config, requirements = self.codex_seed_contract(
                    Path(temporary),
                    **{field: value},
                )
                with self.assertRaisesRegex(ContractError, field):
                    codex.validate_codex_0144_seed_contract(
                        config,
                        requirements,
                        self.codex_0144_lock(),
                    )

    def test_codex_0144_seed_contract_rejects_missing_or_extra_allowed_values(self) -> None:
        cases = (
            {"allowed_approval_policies": ()},
            {"allowed_approval_policies": ("never", "on-request")},
            {"allowed_sandbox_modes": ("workspace-write",)},
            {
                "allowed_sandbox_modes": (
                    "read-only",
                    "workspace-write",
                    "danger-full-access",
                )
            },
            {"allowed_web_search_modes": ()},
            {"allowed_web_search_modes": ("disabled", "live")},
        )
        for overrides in cases:
            field = next(iter(overrides))
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory() as temporary:
                config, requirements = self.codex_seed_contract(
                    Path(temporary),
                    **overrides,
                )
                with self.assertRaisesRegex(ContractError, field):
                    codex.validate_codex_0144_seed_contract(
                        config,
                        requirements,
                        self.codex_0144_lock(),
                    )

    def test_codex_0144_seed_contract_rejects_duplicate_allowed_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config, requirements = self.codex_seed_contract(
                Path(temporary),
                allowed_sandbox_modes=("read-only", "workspace-write", "read-only"),
            )
            with self.assertRaisesRegex(ContractError, "duplicates"):
                codex.validate_codex_0144_seed_contract(
                    config,
                    requirements,
                    self.codex_0144_lock(),
                )

    def test_codex_0144_seed_contract_rejects_wrong_types(self) -> None:
        cases = (
            {"sandbox_mode": True},
            {"allowed_sandbox_modes": "workspace-write"},
            {"allowed_sandbox_modes": ("read-only", True)},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory() as temporary:
                config, requirements = self.codex_seed_contract(
                    Path(temporary),
                    **overrides,
                )
                with self.assertRaises(ContractError):
                    codex.validate_codex_0144_seed_contract(
                        config,
                        requirements,
                        self.codex_0144_lock(),
                    )

    def test_codex_0144_seed_contract_rejects_pinned_version_mismatch(self) -> None:
        for artifact_name in ("codex_base", "codex_linux_arm64"):
            with self.subTest(artifact=artifact_name), tempfile.TemporaryDirectory() as temporary:
                config, requirements = self.codex_seed_contract(Path(temporary))
                lock = self.codex_0144_lock()
                lock["artifacts"][artifact_name]["version"] = "drifted"
                with self.assertRaisesRegex(ContractError, artifact_name):
                    codex.validate_codex_0144_seed_contract(config, requirements, lock)

    def test_lima_cidata_is_the_only_allowed_lima_mount(self) -> None:
        allowed = ("/", "/tmp", "/mnt/lima-cidata")
        rejected = (
            "/mnt/lima-9p",
            "/mnt/lima-cidata/subdir",
            "/mnt/lima-cidata-extra",
            "/Users",
            "/Users/example",
            "/Volumes/example",
            "/home/lima-provision/example/share",
        )

        allowed_result = subprocess.run(
            ("/bin/sh", "-c", HOST_STYLE_MOUNT_FILTER),
            input="\n".join(allowed) + "\n",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(allowed_result.returncode, 0)
        for target in rejected:
            with self.subTest(target=target):
                result = subprocess.run(
                    ("/bin/sh", "-c", HOST_STYLE_MOUNT_FILTER),
                    input=f"/\n/mnt/lima-cidata\n{target}\n",
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0)

        mount_policy = (HARNESS / "guest" / "check-mount-policy.sh").read_text()
        provision = (HARNESS / "guest" / "provision-common.sh").read_text()
        orchestrator = (HARNESS / "lib" / "orchestrator.py").read_text()
        self.assertIn("if ! mount_targets=$(findmnt -rn -o TARGET); then", mount_policy)
        self.assertIn("grep -Fvx '/mnt/lima-cidata'", mount_policy)
        self.assertIn(
            "grep -Eq '^/(Users|Volumes|mnt/lima-|home/lima-provision/.*share)'",
            mount_policy,
        )
        self.assertNotIn("findmnt", provision)
        self.assertEqual(orchestrator.count("guest/check-mount-policy.sh"), 2)

    def test_mount_policy_script_fails_closed(self) -> None:
        script = HARNESS / "guest" / "check-mount-policy.sh"
        with tempfile.TemporaryDirectory() as temporary:
            fake_bin = Path(temporary)
            fake_id = fake_bin / "id"
            fake_id.write_text("#!/bin/sh\nprintf '0\\n'\n")
            fake_id.chmod(0o755)
            fake_findmnt = fake_bin / "findmnt"
            fake_findmnt.write_text(
                "#!/bin/sh\n"
                "if [ \"${FAKE_FINDMNT_RC:-0}\" -ne 0 ]; then\n"
                "  exit \"$FAKE_FINDMNT_RC\"\n"
                "fi\n"
                "printf '%s\\n' \"$FAKE_MOUNT_TARGETS\"\n"
            )
            fake_findmnt.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "FAKE_MOUNT_TARGETS": "/\n/mnt/lima-cidata",
            }

            allowed = subprocess.run(
                ("/bin/sh", str(script)),
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(allowed.returncode, 0)

            rejected = subprocess.run(
                ("/bin/sh", str(script)),
                env={**environment, "FAKE_MOUNT_TARGETS": "/\n/mnt/lima-cidata-extra"},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)

            unavailable = subprocess.run(
                ("/bin/sh", str(script)),
                env={**environment, "FAKE_FINDMNT_RC": "1"},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(unavailable.returncode, 0)

    def test_guest_provisioning_removes_unpinned_apt_sources(self) -> None:
        script = (HARNESS / "guest" / "provision-common.sh").read_text()
        self.assertIn("outer-loop-disabled-sources", script)
        self.assertIn("-exec mv -t", script)
        self.assertNotIn("-exec chmod 000", script)

    def test_codex_install_tree_permissions_are_deterministic(self) -> None:
        script = (HARNESS / "guest" / "provision-codex.sh").read_text()
        roots = "/opt/node-24.18.0 /opt/codex-0.144.5"
        config_directory = "install -d -m 0755 -o root -g root /etc/codex"
        self.assertIn(
            f"find {roots} -type d -exec chmod 0755 {{}} +",
            script,
        )
        self.assertIn(
            f"find {roots} -type f -perm /111 -exec chmod 0755 {{}} +",
            script,
        )
        self.assertIn(
            f"find {roots} -type f ! -perm /111 -exec chmod 0644 {{}} +",
            script,
        )
        self.assertNotIn("-exec chmod go-w", script)
        self.assertIn(config_directory, script)
        self.assertLess(
            script.index(config_directory),
            script.index("/etc/codex/config.toml"),
        )

    def test_claude_install_tree_permissions_are_deterministic(self) -> None:
        script = (HARNESS / "guest" / "provision-claude.sh").read_text()
        roots = "/opt/node-24.18.0 /opt/claude-2.1.211 /opt/srt-0.0.65"
        self.assertIn(
            f"find {roots} -type d -exec chmod 0755 {{}} +",
            script,
        )
        self.assertIn(
            f"find {roots} -type f -perm /111 -exec chmod 0755 {{}} +",
            script,
        )
        self.assertIn(
            f"find {roots} -type f ! -perm /111 -exec chmod 0644 {{}} +",
            script,
        )
        self.assertNotIn("-exec chmod go-w", script)

    def test_runtime_policy_has_no_writable_receipt_channel(self) -> None:
        policy_files = (
            HARNESS / "seeds" / "codex" / "config.toml",
            HARNESS / "seeds" / "claude" / "managed-settings.json",
            HARNESS / "seeds" / "claude" / "srt-settings.json",
            HARNESS / "guest" / "provision-common.sh",
        )
        for path in policy_files:
            with self.subTest(path=path):
                self.assertNotIn("/run/outer-loop-probe/receipts", path.read_text())
        orchestrator = (HARNESS / "lib" / "orchestrator.py").read_text()
        self.assertIn('"-o", "root", "-g", "root", "/dev/shm/outer-loop"', orchestrator)
        self.assertNotIn("sudo -u calibration /usr/local/libexec/outer-loop/sanitize-auth.py", orchestrator)

    def test_codex_commands_are_subscription_and_tool_free(self) -> None:
        self.assertEqual(codex.login_command(), ["codex", "login", "--device-auth"])
        command = codex.smoke_command()
        self.assertIn("--json", command)
        self.assertIn("--ephemeral", command)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", command)

    def test_claude_commands_use_required_fail_closed_flags(self) -> None:
        self.assertEqual(claude.login_command(), ["claude", "auth", "login", "--claudeai"])
        command = claude.smoke_command()
        for flag in (
            "--safe-mode",
            "--strict-mcp-config",
            "--no-chrome",
            "--disable-slash-commands",
            "--no-session-persistence",
        ):
            self.assertIn(flag, command)
        self.assertNotIn("--mcp-config", command)
        self.assertNotIn("--bare", command)

    def test_codex_effective_policy_maps_every_seed_key(self) -> None:
        config_seed = HARNESS / "seeds" / "codex" / "config.toml"
        requirements_seed = HARNESS / "seeds" / "codex" / "requirements.toml"
        expected_config = load_toml_flat(config_seed)
        origins = {}
        for key, value in expected_config.items():
            if isinstance(value, list):
                for index in range(len(value)):
                    origins[f"{key}.{index}"] = {
                        "name": {"type": "system", "file": "/etc/codex/config.toml"}
                    }
            else:
                origins[key] = {
                    "name": {"type": "system", "file": "/etc/codex/config.toml"}
                }
        config_response = {
            "config": unflatten(expected_config),
            "origins": origins,
            "layers": [{"name": {"type": "system", "file": "/etc/codex/config.toml"}}],
        }
        requirements = unflatten(
            codex.normalize_requirements_seed(load_toml_flat(requirements_seed))
        )
        codex.validate_effective_policy(
            config_response,
            {"requirements": requirements},
            config_seed,
            requirements_seed,
        )
        config_response["config"]["web_search"] = "live"
        with self.assertRaises(ContractError):
            codex.validate_effective_policy(
                config_response,
                {"requirements": requirements},
                config_seed,
                requirements_seed,
            )

    def test_codex_indexed_list_origins_fail_closed(self) -> None:
        key = "sandbox_workspace_write.writable_roots"
        value = ["/home/calibration/workspace", "/home/calibration/other"]
        system_origin = {"name": {"type": "system", "file": "/etc/codex/config.toml"}}
        response = {
            "config": {"sandbox_workspace_write": {"writable_roots": value}},
            "origins": {f"{key}.0": system_origin, f"{key}.1": system_origin},
            "layers": [],
        }

        observed = codex.normalize_config_response(response)
        compare_effective_seed(
            {key: value},
            observed,
            expected_origin="system:/etc/codex/config.toml",
        )

        del response["origins"][f"{key}.1"]
        with self.assertRaisesRegex(ContractError, "missing=.*writable_roots"):
            compare_effective_seed(
                {key: value},
                codex.normalize_config_response(response),
                expected_origin="system:/etc/codex/config.toml",
            )

        response["origins"][f"{key}.1"] = {"name": {"type": "user"}}
        with self.assertRaisesRegex(ContractError, "origins=.*writable_roots"):
            compare_effective_seed(
                {key: value},
                codex.normalize_config_response(response),
                expected_origin="system:/etc/codex/config.toml",
            )

        response["origins"] = {key: system_origin}
        with self.assertRaisesRegex(ContractError, "missing=.*writable_roots"):
            compare_effective_seed(
                {key: value},
                codex.normalize_config_response(response),
                expected_origin="system:/etc/codex/config.toml",
            )

    def test_codex_app_server_requests_match_pinned_wire_contract(self) -> None:
        requests = [
            json.loads(line)
            for line in codex._request_lines(codex.FIXED_HARMLESS_CWD).splitlines()
        ]
        self.assertEqual(
            requests[-1],
            {"id": 3, "method": "configRequirements/read"},
        )
        self.assertNotIn("params", requests[-1])

    def test_codex_effective_config_uses_jsonl_subprocess_lifecycle(self) -> None:
        config_result = {
            "config": {"approval_policy": "never"},
            "origins": {},
            "layers": [],
        }
        requirements_result = {
            "requirements": {"allowedApprovalPolicies": ["never"]}
        }
        with tempfile.TemporaryDirectory() as temporary:
            server = Path(temporary) / "fake-codex"
            server.write_text(
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import select\n"
                "import sys\n"
                "def receive(expected):\n"
                "    message = json.loads(sys.stdin.readline())\n"
                "    if message != expected:\n"
                "        raise SystemExit(64)\n"
                "def require_no_pending_request():\n"
                "    if select.select([sys.stdin], [], [], 0)[0]:\n"
                "        raise SystemExit(65)\n"
                "receive({'id': 1, 'method': 'initialize', 'params': "
                "{'clientInfo': {'name': 'outer_loop_lima_calibration', "
                "'title': 'Private Lima calibration', 'version': '1'}, "
                "'capabilities': {'experimentalApi': True}}})\n"
                "require_no_pending_request()\n"
                "print(json.dumps({'id': 1, 'result': {}}), flush=True)\n"
                "receive({'method': 'initialized', 'params': {}})\n"
                f"receive({{'id': 2, 'method': 'config/read', 'params': "
                f"{{'cwd': {codex.FIXED_HARMLESS_CWD!r}, 'includeLayers': True}}}})\n"
                "require_no_pending_request()\n"
                f"print(json.dumps({{'id': 2, 'result': {config_result!r}}}), flush=True)\n"
                "receive({'id': 3, 'method': 'configRequirements/read'})\n"
                f"print(json.dumps({{'id': 3, 'result': {requirements_result!r}}}), flush=True)\n",
                encoding="utf-8",
            )
            server.chmod(0o755)

            observed_config, observed_requirements = codex.read_effective_config(
                binary=str(server),
                timeout=5,
            )

        self.assertEqual(observed_config, config_result)
        self.assertEqual(observed_requirements, requirements_result)

    def test_codex_method_absence_is_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            server = Path(temporary) / "fake-codex"
            server.write_text(
                "#!/usr/bin/env python3\n"
                "import json\n"
                "import sys\n"
                "json.loads(sys.stdin.readline())\n"
                "print(json.dumps({'id': 1, 'result': {}}), flush=True)\n"
                "json.loads(sys.stdin.readline())\n"
                "json.loads(sys.stdin.readline())\n"
                "print(json.dumps({'id': 2, 'result': {}}), flush=True)\n"
                "json.loads(sys.stdin.readline())\n",
                encoding="utf-8",
            )
            server.chmod(0o755)
            with self.assertRaisesRegex(ContractError, "configRequirements/read"):
                codex.read_effective_config(binary=str(server), timeout=5)

    def test_smoke_event_validators_reject_tools(self) -> None:
        codex.validate_tool_free_events(
            [json.dumps({"item": {"type": "agent_message", "text": "CALIBRATION_SMOKE_OK"}})]
        )
        with self.assertRaisesRegex(ContractError, "used a tool"):
            codex.validate_tool_free_events(
                [json.dumps({"item": {"type": "command_execution"}})]
            )
        claude.validate_tool_free_events([json.dumps({"message": {"text": "CALIBRATION_SMOKE_OK"}})])
        with self.assertRaisesRegex(ContractError, "used a tool"):
            claude.validate_tool_free_events(
                [json.dumps({"type": "tool_use", "name": "Bash", "input": {"command": "true"}})]
            )

    def test_guest_sanitizer_rejects_probe_mutation_and_smoke_tools(self) -> None:
        sanitizer = load_sanitizer()
        nonce = "a" * 32
        intended_argv = [
            "/usr/local/libexec/outer-loop/control.py",
            "--nonce",
            nonce,
            "--destination",
            "host",
            "--",
            "probe",
        ]
        intended = shlex.join(intended_argv)
        receipt_base = {
            "schema_version": 1,
            "nonce": nonce,
            "destination": "host",
            "argv_digest": hashlib.sha256(
                (json.dumps(intended_argv, sort_keys=True, separators=(",", ":")) + "\n").encode()
            ).hexdigest(),
        }
        receipt_output = "\n".join(
            (
                sanitizer.STARTED_PREFIX
                + json.dumps({**receipt_base, "classification": "STARTED"}),
                sanitizer.COMPLETE_PREFIX
                + json.dumps(
                    {
                        **receipt_base,
                        "classification": "DENIED_BY_SANDBOX",
                        "exit_classification": "NONZERO",
                    }
                ),
            )
        )
        tool_id = "toolu_calibration"
        probe = "\n".join(
            (
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "id": tool_id,
                                    "name": "Bash",
                                    "input": {"command": intended},
                                }
                            ]
                        },
                        "parent_tool_use_id": None,
                    }
                ),
                json.dumps(
                    {
                        "type": "user",
                        "message": {
                            "content": [
                                {
                                    "type": "tool_result",
                                    "tool_use_id": tool_id,
                                    "content": receipt_output,
                                    "is_error": True,
                                }
                            ]
                        },
                        "parent_tool_use_id": None,
                    }
                ),
            )
        )
        safe = sanitizer.probe_classification("claude", probe, intended, nonce, "host")
        self.assertTrue(safe["exact_command"])
        self.assertEqual(safe["receipt"]["nonce"], nonce)
        self.assertEqual(safe["receipt_source"], "cli_completed_tool_event")
        with self.assertRaisesRegex(ValueError, "mutated"):
            sanitizer.probe_classification("claude", probe, intended + " changed", nonce, "host")
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            sanitizer.probe_classification("claude", probe, intended, "c" * 32, "host")
        with self.assertRaisesRegex(ValueError, "tool-free"):
            sanitizer.smoke_classification("claude", probe)

        forged_agent_text = "\n".join(
            (
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {
                            "content": [
                                {"type": "text", "text": receipt_output},
                                {
                                    "type": "tool_use",
                                    "id": tool_id,
                                    "name": "Bash",
                                    "input": {"command": intended},
                                },
                            ]
                        },
                        "parent_tool_use_id": None,
                    }
                ),
                json.dumps(
                    {
                        "type": "user",
                        "message": {
                            "content": [
                                {
                                    "type": "tool_result",
                                    "tool_use_id": tool_id,
                                    "content": "unrelated command failure",
                                    "is_error": True,
                                }
                            ]
                        },
                        "parent_tool_use_id": None,
                    }
                ),
            )
        )
        with self.assertRaisesRegex(ValueError, "completed tool result"):
            sanitizer.probe_classification(
                "claude",
                forged_agent_text,
                intended,
                nonce,
                "host",
            )

        codex_probe = "\n".join(
            (
                json.dumps(
                    {
                        "type": "item.started",
                        "item": {
                            "id": "item_1",
                            "type": "command_execution",
                            "command": intended,
                            "status": "in_progress",
                        },
                    }
                ),
                json.dumps(
                    {
                        "type": "item.completed",
                        "item": {
                            "id": "item_1",
                            "type": "command_execution",
                            "command": intended,
                            "status": "failed",
                            "aggregated_output": receipt_output,
                            "exit_code": 77,
                        },
                    }
                ),
            )
        )
        codex_safe = sanitizer.probe_classification("codex", codex_probe, intended, nonce, "host")
        self.assertEqual(codex_safe["receipt"]["classification"], "DENIED_BY_SANDBOX")
        codex_forged_agent_text = "\n".join(
            (
                json.dumps(
                    {
                        "type": "item.completed",
                        "item": {
                            "id": "message_1",
                            "type": "agent_message",
                            "text": receipt_output,
                        },
                    }
                ),
                json.dumps(
                    {
                        "type": "item.completed",
                        "item": {
                            "id": "item_1",
                            "type": "command_execution",
                            "command": intended,
                            "status": "failed",
                            "aggregated_output": "unrelated command failure",
                            "exit_code": 77,
                        },
                    }
                ),
            )
        )
        with self.assertRaisesRegex(ValueError, "completed tool result"):
            sanitizer.probe_classification(
                "codex",
                codex_forged_agent_text,
                intended,
                nonce,
                "host",
            )

    def test_auth_sanitizer_allows_only_safe_credential_metadata_and_tmpfs(self) -> None:
        sanitizer = load_sanitizer()
        self.assertTrue(sanitizer.within_tmpfs(Path("/dev/shm/outer-loop/auth.raw")))
        self.assertFalse(sanitizer.within_tmpfs(Path("/tmp/auth.raw")))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            credential = root / "credential.json"
            credential.write_text("opaque")
            os.chmod(credential, 0o600)
            codex = sanitizer.auth_classification(
                "codex",
                "Logged in with ChatGPT",
                credential,
            )
            self.assertEqual(codex["authentication_method"], "chatgpt_device")
            self.assertNotIn("opaque", json.dumps(codex))
            hardlink = root / "credential-hardlink"
            os.link(credential, hardlink)
            with self.assertRaisesRegex(ValueError, "mode or link count"):
                sanitizer.credential_metadata(credential)


if __name__ == "__main__":
    unittest.main()
