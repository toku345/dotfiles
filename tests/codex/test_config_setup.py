#!/usr/bin/env python3
"""Isolated setup checks; UV_CACHE_DIR must contain the prepared test cache."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / "scripts/codex-config/setup.sh"
PYTHON = Path(getattr(sys, "_base_executable", sys.executable)).resolve()


class SetupTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.home = self.base / "home"
        self.bin = self.base / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.venv = self.base / "data/codex-config-policy/venv"
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(("UV_", "ASDF_", "PYTHON")) or key == "VIRTUAL_ENV":
                self.env.pop(key)
        self.env.update(
            HOME=str(self.home), PATH=f"{self.bin}:/usr/bin:/bin",
            XDG_DATA_HOME=str(self.base / "data"),
            XDG_CONFIG_HOME=str(self.base / "config"),
            XDG_CACHE_HOME=str(self.base / "cache"),
            XDG_STATE_HOME=str(self.base / "state"),
            UV_CACHE_DIR=str(self.base / "uv-cache"), UV_OFFLINE="1",
            ASDF_TEST_PYTHON=str(PYTHON),
            UV_CALL_LOG=str(self.base / "uv.log"),
        )
        self.script(self.bin / "asdf", '''[ "$PWD" = "$HOME" ] || exit 8
[ "$1" = which ] && [ "$2" = python3 ] || exit 9
printf '%s\\n' "$ASDF_TEST_PYTHON"
''')
        self.script(self.bin / "uv", '''printf '%s\\n' "$@" > "$UV_CALL_LOG"
exit 91
''')

    def script(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_setup(self, *args, cwd=None):
        return subprocess.run(["/bin/sh", str(SETUP), *map(str, args)],
                              env=self.env, cwd=cwd or self.base,
                              capture_output=True, text=True)

    def assert_rejected_before_uv(self, result):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / "uv.log").exists())

    def python_probe_stub(self, path, assignment):
        # Change only the interpreter metadata; execute the real setup probe.
        code = f"import sys; {assignment}; exec(sys.argv[1])"
        self.script(path, f'exec {shlex.quote(str(PYTHON))} -I -c {shlex.quote(code)} "$3"\n')

    def test_default_resolves_from_home_not_invocation_directory(self):
        # A competing PATH Python must never be selected.
        self.script(self.bin / "python3", "exit 99\n")
        other = self.base / "another project"
        other.mkdir()
        (other / ".tool-versions").write_text("python 0.0.0\n")
        for cwd in (self.base, other):
            result = self.run_setup(cwd=cwd)
            self.assertEqual(result.returncode, 91, result.stderr)
            args = (self.base / "uv.log").read_text().splitlines()
            self.assertEqual(args[args.index("--python") + 1], str(PYTHON))
            self.assertIn("--locked", args)
            self.assertIn("--no-python-downloads", args)

    def test_asdf_absent_or_unconfigured_does_not_fall_back(self):
        (self.bin / "asdf").unlink()
        self.assert_rejected_before_uv(self.run_setup())
        self.script(self.bin / "asdf", "exit 7\n")
        self.assert_rejected_before_uv(self.run_setup())
        self.assertFalse(self.venv.exists())

    def test_invalid_selection_preserves_existing_environment(self):
        self.venv.mkdir(parents=True)
        marker = self.venv / "keep"
        marker.write_text("unchanged")
        old = self.bin / "old-python"
        self.python_probe_stub(old, "sys.version_info = (3, 10, 0)")
        cases = (("",), ("python3",), ("/does/not/exist",), (PYTHON, "extra"), (old,))
        for args in cases:
            with self.subTest(args=args):
                result = self.run_setup(*args)
                self.assert_rejected_before_uv(result)
                self.assertEqual(marker.read_text(), "unchanged")
                if args == (old,):
                    self.assertIn("3.11+", result.stderr)

    def test_different_or_broken_existing_python_is_preserved(self):
        old = self.venv / "bin/python"
        self.python_probe_stub(old, "sys._base_executable = '/other/python'")
        original = old.read_bytes()
        result = self.run_setup(PYTHON)
        self.assert_rejected_before_uv(result)
        self.assertIn("different Python", result.stderr)
        self.assertEqual(old.read_bytes(), original)
        old.unlink()
        old.symlink_to(self.base / "removed-python")
        result = self.run_setup(PYTHON)
        self.assert_rejected_before_uv(result)
        self.assertIn("cannot start", result.stderr)
        self.assertTrue(old.is_symlink())

    def test_real_uv_selection_repeat_and_restore(self):
        uv = shutil.which("uv")
        self.assertIsNotNone(uv, "uv is required")
        cache = os.environ.get("UV_CACHE_DIR")
        self.assertTrue(cache, "set UV_CACHE_DIR to the isolated, prepared dependency cache")
        shutil.copytree(cache, self.env["UV_CACHE_DIR"], symlinks=True)
        (self.bin / "uv").unlink()
        (self.bin / "uv").symlink_to(uv)
        alias = self.bin / "python with spaces"
        alias.symlink_to(PYTHON)
        for args in ((), (alias,), (self.venv / "bin/python",)):
            result = self.run_setup(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Subsequent calls must work without asdf, using explicit paths.
            (self.bin / "asdf").unlink(missing_ok=True)
        check = [str(self.venv / "bin/python"), "-I", "-c", "import tomlkit"]
        self.assertEqual(subprocess.run(check, env=self.env).returncode, 0)
        backup = self.venv.with_name("venv.backup")
        self.venv.rename(backup)
        result = self.run_setup(PYTHON)
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.rmtree(self.venv)
        backup.rename(self.venv)
        self.assertEqual(subprocess.run(check, env=self.env).returncode, 0)

    def test_post_sync_rejects_wrong_python(self):
        wrong = self.bin / "wrong-python"
        self.python_probe_stub(wrong, "sys._base_executable = '/wrong/python'")
        self.env["WRONG_PYTHON"] = str(wrong)
        self.script(self.bin / "uv", '''mkdir -p "$UV_PROJECT_ENVIRONMENT/bin"
cp "$WRONG_PYTHON" "$UV_PROJECT_ENVIRONMENT/bin/python"
''')
        result = self.run_setup(PYTHON)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different Python", result.stderr)


if __name__ == "__main__":
    unittest.main()
