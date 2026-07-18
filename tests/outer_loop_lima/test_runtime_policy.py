from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


HARNESS = Path(__file__).parents[2] / "tools" / "outer-loop-lima-calibration"
sys.path.insert(0, str(HARNESS))

from lib.identities import load_toml_flat  # noqa: E402
from lib.model import ContractError  # noqa: E402
from runtime import claude, codex  # noqa: E402


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
    def test_guest_provisioning_removes_unpinned_apt_sources(self) -> None:
        script = (HARNESS / "guest" / "provision-common.sh").read_text()
        self.assertIn("outer-loop-disabled-sources", script)
        self.assertIn("-exec mv -t", script)
        self.assertNotIn("-exec chmod 000", script)

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
        intended = "/usr/local/libexec/outer-loop/control.py --nonce fixed"
        probe = json.dumps(
            {"type": "tool_use", "name": "Bash", "input": {"command": intended}}
        )
        safe = sanitizer.probe_classification("claude", probe, intended)
        self.assertTrue(safe["exact_command"])
        with self.assertRaisesRegex(ValueError, "mutated"):
            sanitizer.probe_classification("claude", probe, intended + " changed")
        with self.assertRaisesRegex(ValueError, "tool-free"):
            sanitizer.smoke_classification("claude", probe)


if __name__ == "__main__":
    unittest.main()
