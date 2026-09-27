#!/usr/bin/env python3
"""Regression and isolated chezmoi integration tests for config ownership."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "scripts" / "codex-config"
sys.path.insert(0, str(PROJECT))
import merge
from config_policy import PolicyError, load_policy


FUGU_BLOCK = """# >>> fugu:model_providers.sakana >>>
[model_providers.sakana]
name = "Sakana API"
base_url = "https://api.sakana.ai/v1"
# <<< fugu:model_providers.sakana <<<
"""

FUGU_RUNTIME = """[projects."/tmp/repo"]
trust_level = "trusted"

[hooks.state."/tmp/repo/.codex/hooks.json:stop:0:0"]
trusted_hash = "sha256:deadbeef"
enabled = true
"""


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_policy(PROJECT / "policy.toml")

    def update(self, source):
        result, warnings = merge.merge(source, self.policy)
        # Independent TOML parser, also checking compatibility with TOML 1.0.
        return result, tomllib.loads(result), warnings

    def test_bracket_comment_preserves_free_keys(self):
        source = '''sandbox_mode = "danger-full-access" # [temporary
service_tier = "fast"
notify = ["/x"]
[sandbox_workspace_write]
network_access = true # [network policy
writable_roots = ["/important"]
'''
        _, data, _ = self.update(source)
        self.assertEqual(data["sandbox_mode"], "workspace-write")
        self.assertEqual(data["service_tier"], "fast")
        self.assertEqual(data["notify"], ["/x"])
        self.assertEqual(data["sandbox_workspace_write"]["writable_roots"], ["/important"])

    def test_headers_quoted_and_dotted_keys(self):
        for source in (
            '[features] # local settings\napps = false\n',
            '["features"]\n"apps" = false\n',
            'features.apps = false\n',
            'features.apps = false\nfree = "keep"\n',
            'features = { apps = false, custom = true }\nfree = "keep"\n',
            "'model' = 'custom'\n[ features ] # spaced\napps = false\n",
        ):
            with self.subTest(source=source):
                _, data, _ = self.update(source)
                self.assertIs(data["features"]["apps"], True)
                self.assertEqual(data["sandbox_mode"], "workspace-write")
                self.assertNotIn("sandbox_mode", data["features"])
                if "free =" in source:
                    self.assertEqual(data["free"], "keep")
                if "'model'" in source:
                    self.assertEqual(data["model"], "custom")

    def test_free_values_comments_and_installer_block(self):
        block = '''# >>> fugu:model_providers.sakana >>>
[model_providers.sakana]
name = "Sakana API"
# <<< fugu:model_providers.sakana <<<
'''
        source = '''# free values include multiline strings and inline tables
custom = """first [ line
[not.a.table]
last"""
service_tier = "fast"
[projects."/path.with.dots"]
trust_level = "trusted"
custom = { nested = [1, true, "value"] }
''' + block
        output, data, _ = self.update(source)
        original = tomllib.loads(source)
        for key, value in original.items():
            self.assertTrue(merge.equal(value, data[key]), key)
        self.assertIn(block, output)
        self.assertIn("# free values include multiline strings and inline tables", output)

    def test_seed_warnings_do_not_include_live_value(self):
        _, data, warnings = self.update('model = "private-provider-value"\n')
        self.assertEqual(data["model"], "private-provider-value")
        self.assertEqual(len(warnings), 1)
        self.assertNotIn("private-provider-value", warnings[0])
        self.assertIn("seed model differs", warnings[0])

    def test_free_arrays_of_tables(self):
        source = '''[[custom.providers]]
name = "first"
[custom.providers.options]
enabled = true
[[custom.providers]]
name = "second"
'''
        output, data, _ = self.update(source)
        self.assertEqual(data["custom"], tomllib.loads(source)["custom"])
        self.assertEqual(self.update(output)[0], output)

    def test_type_sensitive_pins(self):
        _, data, _ = self.update('[features]\napps = 1\n')
        self.assertIs(data["features"]["apps"], True)

    def test_no_change_returns_exact_input(self):
        first, _, _ = self.update("")
        for source in (first, first.replace("\n", "\r\n")):
            second, warnings = merge.merge(source, self.policy)
            self.assertEqual(second, source)
            self.assertFalse(warnings)

    def test_array_format_and_second_run(self):
        values = self.policy["pin"][("tui", "status_line")]
        array = "status_line = [\n" + "".join(f'  "{v}",\n' for v in values) + "]\n"
        first, _, _ = self.update("[tui]\n" + array)
        self.assertIn(array, first)
        second, _, _ = self.update(first)
        self.assertEqual(first, second)

    def test_structure_conflicts(self):
        for source in ('features = false', '[model]\ncustom = true', '[[features]]\napps = false'):
            with self.subTest(source=source), self.assertRaises(PolicyError):
                merge.merge(source, self.policy)

    def test_installer_block_cannot_be_modified(self):
        with self.assertRaisesRegex(PolicyError, "installer-owned"):
            self.update('# >>> owner >>>\n[features]\napps = false\n# <<< owner <<<\n')

    def test_invalid_policy(self):
        cases = (
            '[pin]\napps = true\n[seed]\napps = false',
            '[pin]\napps = true\n[seed.apps]\nnested = false',
            '[pin]\napps = true\napps = false\n[seed]\nmodel = "x"',
            '[pins]\napps = true\n[seed]\nmodel = "x"',
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.toml"
            for source in cases:
                path.write_text(source)
                with self.subTest(source=source), self.assertRaises(PolicyError):
                    load_policy(path)


class RootInsertionTests(unittest.TestCase):
    """New root-level rows must not be written inside an installer block."""

    def setUp(self):
        self.policy = load_policy(PROJECT / "policy.toml")

    def test_new_root_keys_are_prefixed_above_an_installer_block(self):
        source = FUGU_BLOCK + "\n" + FUGU_RUNTIME
        output, warnings = merge.merge(source, self.policy)
        self.assertFalse(warnings)
        self.assertIn(FUGU_BLOCK, output)
        lines = output.splitlines()
        opener = lines.index("# >>> fugu:model_providers.sakana >>>")
        for key in ('sandbox_mode = "workspace-write"', 'approval_policy = "on-request"'):
            self.assertLess(lines.index(key), opener)
        data = tomllib.loads(output)
        self.assertEqual(data["sandbox_mode"], "workspace-write")
        self.assertEqual(data["projects"]["/tmp/repo"]["trust_level"], "trusted")

    def test_new_root_keys_stay_above_the_first_table(self):
        output, _ = merge.merge('service_tier = "fast"\n\n[features]\napps = false\n', self.policy)
        lines = output.splitlines()
        self.assertLess(
            lines.index('sandbox_mode = "workspace-write"'),
            lines.index("[features]"),
        )
        self.assertEqual(tomllib.loads(output)["service_tier"], "fast")


class FuguPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_policy(PROJECT / "policy-fugu.toml")

    def update(self, source):
        result, warnings = merge.merge(source, self.policy)
        return result, tomllib.loads(result), warnings

    def test_new_home_gets_only_the_pin(self):
        output, data, warnings = self.update("")
        self.assertEqual(output, 'plan_mode_reasoning_effort = "xhigh"\n')
        self.assertEqual(data, {"plan_mode_reasoning_effort": "xhigh"})
        self.assertFalse(warnings)

    def test_pin_is_placed_above_the_installer_block(self):
        output, data, warnings = self.update(FUGU_BLOCK)
        self.assertIn(FUGU_BLOCK, output)
        lines = output.splitlines()
        self.assertLess(
            lines.index('plan_mode_reasoning_effort = "xhigh"'),
            lines.index("# >>> fugu:model_providers.sakana >>>"),
        )
        self.assertEqual(set(data), {"plan_mode_reasoning_effort", "model_providers"})
        self.assertFalse(warnings)

    def test_pin_reasserts_a_stored_plan_effort(self):
        _, data, warnings = self.update(
            'plan_mode_reasoning_effort = "medium"\n\n[tui]\nstatus_line_use_colors = true\n'
        )
        self.assertEqual(data["plan_mode_reasoning_effort"], "xhigh")
        self.assertIs(data["tui"]["status_line_use_colors"], True)
        # Pins re-assert silently; only seed divergence is reported.
        self.assertFalse(warnings)

    def test_runtime_state_is_preserved(self):
        output, data, _ = self.update(FUGU_BLOCK + "\n" + FUGU_RUNTIME)
        self.assertIn(FUGU_BLOCK, output)
        self.assertEqual(data["projects"]["/tmp/repo"]["trust_level"], "trusted")
        self.assertIs(
            data["hooks"]["state"]["/tmp/repo/.codex/hooks.json:stop:0:0"]["enabled"], True
        )

    def test_converges_and_does_not_import_vanilla_pins(self):
        first, data, _ = self.update(FUGU_BLOCK + "\n" + FUGU_RUNTIME)
        second, warnings = merge.merge(first, self.policy)
        self.assertEqual(first, second)
        self.assertFalse(warnings)
        for absent in ("sandbox_mode", "features", "tui"):
            self.assertNotIn(absent, data)


class PolicySelectionTests(unittest.TestCase):
    def test_default_policy(self):
        self.assertEqual(merge.select_policy([]), "policy.toml")

    def test_explicit_policy(self):
        self.assertEqual(merge.select_policy(["--policy", "policy-fugu.toml"]), "policy-fugu.toml")

    def test_rejects_unsafe_or_unknown_arguments(self):
        cases = (
            ["extra"],
            ["--policy"],
            ["--policy", "../policy.toml"],
            ["--policy", "/etc/policy.toml"],
            ["--policy", "policy.txt"],
            ["--policy", "policy.toml", "extra"],
        )
        for argv in cases:
            with self.subTest(argv=argv), self.assertRaises(PolicyError):
                merge.select_policy(argv)

    def test_rejects_a_missing_policy_file(self):
        with self.assertRaisesRegex(PolicyError, "not found"):
            merge.select_policy(["--policy", "policy-missing.toml"])

    def test_policy_may_leave_one_table_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.toml"
            path.write_text('[pin]\napps = true\n[seed]\n')
            self.assertEqual(load_policy(path), {"pin": {("apps",): True}, "seed": {}})
            path.write_text('[pin]\n[seed]\nmodel = "x"\n')
            self.assertEqual(load_policy(path), {"pin": {}, "seed": {("model",): "x"}})
            path.write_text("[pin]\n[seed]\n")
            with self.assertRaisesRegex(PolicyError, "at least one value"):
                load_policy(path)

    def test_policy_rejects_empty_nested_tables(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.toml"
            path.write_text('[pin]\napps = true\n[pin.features]\n[seed]\nmodel = "x"\n')
            with self.assertRaisesRegex(PolicyError, "nested policy tables"):
                load_policy(path)
            path.write_text(
                "[pin]\napps = true\n[pin.features.memories]\nenabled = true\n[seed]\n"
            )
            self.assertEqual(
                load_policy(path),
                {"pin": {("apps",): True, ("features", "memories", "enabled"): True}, "seed": {}},
            )


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "source"
        self.project = self.source / "scripts" / "codex-config"
        shutil.copytree(PROJECT, self.project, ignore=shutil.ignore_patterns("__pycache__", ".venv"))
        for directory in ("private_dot_codex", "private_dot_codex-fugu"):
            source_dir = self.source / directory
            source_dir.mkdir()
            shutil.copy2(
                ROOT / directory / "modify_private_config.toml",
                source_dir / "modify_private_config.toml",
            )
        self.wrapper = self.source / "private_dot_codex" / "modify_private_config.toml"
        self.fugu_wrapper = (
            self.source / "private_dot_codex-fugu" / "modify_private_config.toml"
        )
        # The real ignore file carries the codexFugu opt-in gate; the temp
        # source only holds the two Codex trees and the shared scripts.
        shutil.copy2(ROOT / ".chezmoiignore", self.source / ".chezmoiignore")
        self.home = self.base / "home"
        self.home.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home),
                        XDG_DATA_HOME=str(self.base / "data"),
                        XDG_CONFIG_HOME=str(self.base / "config"),
                        XDG_CACHE_HOME=str(self.base / "cache"),
                        XDG_STATE_HOME=str(self.base / "state"),
                        UV_CACHE_DIR=str(self.base / "uv-cache"),
                        PYTHONDONTWRITEBYTECODE="1")
        self.env.pop("CHEZMOI_SOURCE_DIR", None)
        self.env.pop("PYTHONPATH", None)
        self.env.pop("PYTHONHOME", None)
        self.venv = self.base / "data" / "codex-config-policy" / "venv"
        self.venv.parent.mkdir(parents=True)
        # Tests must be launched by the separately prepared test venv.
        self.assertNotEqual(sys.prefix, sys.base_prefix, "run tests with the isolated policy venv")
        self.venv.symlink_to(sys.prefix, target_is_directory=True)

    def wrapper_run(self, source):
        env = self.env.copy()
        env["CHEZMOI_SOURCE_DIR"] = str(self.source)
        return subprocess.run(["/bin/sh", str(self.wrapper)], input=source, text=True,
                              capture_output=True, env=env, cwd=self.base)

    def fugu_wrapper_run(self, source):
        env = self.env.copy()
        env["CHEZMOI_SOURCE_DIR"] = str(self.source)
        return subprocess.run(["/bin/sh", str(self.fugu_wrapper)], input=source, text=True,
                              capture_output=True, env=env, cwd=self.base)

    def chezmoi_run(self, config, destination, state, *args):
        chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(chezmoi, "chezmoi is required for integration coverage")
        command = [chezmoi, "--source", str(self.source), "--destination", str(destination),
                   "--config", str(config), "--persistent-state", str(state),
                   "--no-tty", "--force"]
        return subprocess.run([*command, *args], env=self.env, capture_output=True, text=True)

    def test_wrapper_from_other_cwd(self):
        result = self.wrapper_run("")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(tomllib.loads(result.stdout)["sandbox_mode"], "workspace-write")

    def test_failures_have_no_stdout_or_live_values(self):
        for source in ('model = "SECRET', 'features = "SECRET"'):
            result = self.wrapper_run(source)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertNotIn("SECRET", result.stderr)

    def test_missing_environment(self):
        self.venv.unlink()
        result = self.wrapper_run("")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("setup.sh", result.stderr)

    def test_lock_and_environment_mismatch(self):
        manifest = self.project / "pyproject.toml"
        version = tomllib.loads(manifest.read_text())["project"]["dependencies"][0].split("==")[1]
        manifest.write_text(manifest.read_text().replace(f"tomlkit=={version}", "tomlkit==0.0.0"))
        result = self.wrapper_run("")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        manifest.write_text(manifest.read_text().replace("tomlkit==0.0.0", f"tomlkit=={version}"))
        lock = self.project / "uv.lock"
        lock.write_text(lock.read_text().replace(f'version = "{version}"', 'version = "0.0.0"'))
        manifest.write_text(manifest.read_text().replace(f"tomlkit=={version}", "tomlkit==0.0.0"))
        result = self.wrapper_run("")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")

    def test_fugu_wrapper_selects_its_own_policy(self):
        result = self.fugu_wrapper_run(FUGU_BLOCK)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('plan_mode_reasoning_effort = "xhigh"', result.stdout)
        self.assertIn("# <<< fugu:model_providers.sakana <<<", result.stdout)
        self.assertNotIn("sandbox_mode", result.stdout)
        self.assertEqual(
            tomllib.loads(result.stdout)["model_providers"]["sakana"]["name"], "Sakana API"
        )

    def test_fugu_gate_off_leaves_the_isolated_home_alone(self):
        config = self.base / "gate-off.toml"
        config.write_text("")
        result = self.chezmoi_run(config, self.home, self.base / "gate-off.db", "apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".codex" / "config.toml").exists())
        self.assertFalse((self.home / ".codex-fugu").exists())

    def test_fugu_gate_on_manages_the_base_config(self):
        config = self.base / "gate-on.toml"
        config.write_text("[data]\ncodexFugu = true\n")
        home = self.base / "fugu-home"
        home.mkdir()
        state = self.base / "gate-on.db"

        def call(*args):
            return self.chezmoi_run(config, home, state, *args)

        result = call("apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        fugu_dir = home / ".codex-fugu"
        live = fugu_dir / "config.toml"
        self.assertEqual(fugu_dir.stat().st_mode & 0o777, 0o700)
        self.assertEqual(live.stat().st_mode & 0o777, 0o600)
        self.assertEqual(tomllib.loads(live.read_text()), {"plan_mode_reasoning_effort": "xhigh"})
        self.assertTrue((home / ".codex" / "config.toml").exists())
        diff = call("diff")
        self.assertEqual(diff.returncode, 0, diff.stderr)
        self.assertEqual(diff.stdout, "")
        self.assertEqual(call("status").stdout, "")

        # The installer-owned block and Codex runtime state survive, and the
        # pin is written above the block.
        live.write_text(FUGU_BLOCK + "\n" + FUGU_RUNTIME)
        result = call("apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = live.read_text()
        self.assertTrue(content.startswith('plan_mode_reasoning_effort = "xhigh"'))
        self.assertIn(FUGU_BLOCK, content)
        self.assertIn('trust_level = "trusted"', content)
        self.assertIn('trusted_hash = "sha256:deadbeef"', content)
        self.assertEqual(live.stat().st_mode & 0o777, 0o600)
        self.assertEqual(call("status").stdout, "")

    def test_chezmoi_lifecycle(self):
        # The real chezmoi invocation must provide the modifier's source directory.
        self.assertNotIn("CHEZMOI_SOURCE_DIR", self.env)
        config = self.base / "chezmoi.toml"
        config.write_text("")

        def call(*args):
            return self.chezmoi_run(config, self.home, self.base / "chezmoi.db", *args)

        result = call("apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        live = self.home / ".codex" / "config.toml"
        self.assertEqual(live.stat().st_mode & 0o777, 0o600)
        first = live.read_bytes()
        result = call("diff")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(call("apply").returncode, 0)
        self.assertEqual(live.read_bytes(), first)
        self.assertFalse((self.home / "scripts").exists())

        # Verify the wrapper also protects an already deployed file on failure.
        broken = b'model = "SECRET'
        live.write_bytes(broken)
        result = call("apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(live.read_bytes(), broken)
        self.assertNotIn("SECRET", result.stderr)

        live.write_bytes(first)
        self.venv.unlink()
        result = call("apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(live.read_bytes(), first)
        self.assertIn("setup.sh", result.stderr)


if __name__ == "__main__":
    unittest.main()
