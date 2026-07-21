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

from lib.identities import load_toml_flat  # noqa: E402
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

        provision = (HARNESS / "guest" / "provision-common.sh").read_text()
        orchestrator = (HARNESS / "lib" / "orchestrator.py").read_text()
        for source in (provision, orchestrator):
            self.assertIn("mount_targets=$(findmnt -rn -o TARGET)", source)
            self.assertIn("grep -Fvx '/mnt/lima-cidata'", source)
            self.assertIn(
                "grep -Eq '^/(Users|Volumes|mnt/lima-|home/lima-provision/.*share)'",
                source,
            )
        self.assertIn("if ! mount_targets=$(findmnt -rn -o TARGET); then", provision)
        self.assertIn("mount_targets=$(findmnt -rn -o TARGET) &&", orchestrator)

    def test_guest_provisioning_removes_unpinned_apt_sources(self) -> None:
        script = (HARNESS / "guest" / "provision-common.sh").read_text()
        self.assertIn("outer-loop-disabled-sources", script)
        self.assertIn("-exec mv -t", script)
        self.assertNotIn("-exec chmod 000", script)

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
        config_response = {
            "config": unflatten(expected_config),
            "origins": {
                key: {"name": {"type": "system", "file": "/etc/codex/config.toml"}}
                for key in expected_config
            },
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

    def test_codex_method_absence_is_blocking(self) -> None:
        output = "\n".join(
            (
                json.dumps({"id": 1, "result": {}}),
                json.dumps({"id": 2, "result": {}}),
            )
        )
        completed = subprocess.CompletedProcess([], 0, output, "")
        with patch("runtime.codex.subprocess.run", return_value=completed):
            with self.assertRaisesRegex(ContractError, "configRequirements/read"):
                codex.read_effective_config()

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
