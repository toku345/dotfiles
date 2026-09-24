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


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / "source"
        self.project = self.source / "scripts" / "codex-config"
        shutil.copytree(PROJECT, self.project, ignore=shutil.ignore_patterns("__pycache__", ".venv"))
        source_codex = self.source / "private_dot_codex"
        source_codex.mkdir()
        self.wrapper = source_codex / "modify_private_config.toml"
        shutil.copy2(ROOT / "private_dot_codex" / self.wrapper.name, self.wrapper)
        (self.source / ".chezmoiignore").write_text("scripts\n")
        self.home = self.base / "home"
        self.home.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), CHEZMOI_SOURCE_DIR=str(self.source),
                        XDG_DATA_HOME=str(self.base / "data"),
                        XDG_CONFIG_HOME=str(self.base / "config"),
                        XDG_CACHE_HOME=str(self.base / "cache"),
                        XDG_STATE_HOME=str(self.base / "state"),
                        UV_CACHE_DIR=str(self.base / "uv-cache"),
                        PYTHONDONTWRITEBYTECODE="1")
        self.env.pop("PYTHONPATH", None)
        self.env.pop("PYTHONHOME", None)
        self.venv = self.base / "data" / "codex-config-policy" / "venv"
        self.venv.parent.mkdir(parents=True)
        # Tests must be launched by the separately prepared test venv.
        self.assertNotEqual(sys.prefix, sys.base_prefix, "run tests with the isolated policy venv")
        self.venv.symlink_to(sys.prefix, target_is_directory=True)

    def wrapper_run(self, source):
        return subprocess.run(["/bin/sh", str(self.wrapper)], input=source, text=True,
                              capture_output=True, env=self.env, cwd=self.base)

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

    def test_chezmoi_lifecycle(self):
        chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(chezmoi, "chezmoi is required for integration coverage")
        config = self.base / "chezmoi.toml"
        config.write_text("")
        command = [chezmoi, "--source", str(self.source), "--destination", str(self.home),
                   "--config", str(config), "--persistent-state", str(self.base / "chezmoi.db"),
                   "--no-tty", "--force"]

        def call(*args):
            return subprocess.run([*command, *args], env=self.env, capture_output=True, text=True)

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
