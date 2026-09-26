#!/usr/bin/env python3
"""Setup regressions; run with the prepared policy venv and UV_CACHE_DIR."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / "scripts/codex-config/setup.sh"
PYTHON = Path(getattr(sys, "_base_executable", sys.executable)).resolve()
SERIES = (SETUP.parent / ".python-version").read_text().strip()


class SetupTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name).resolve()
        self.home = self.base / "home"
        self.bin = self.base / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.state = self.base / "data/codex-config-policy"
        self.venv = self.state / "venv"
        self.backup = self.state / "venv.backup"
        self.lock = self.state / "setup.lock"
        self.log = self.base / "uv.log"
        self.old_python = self.state / "python/old/bin/python"
        self.new_python = self.state / "python/new/bin/python"
        self.payload = self.base / "venv-python"
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
            TEST_SELECTED_PYTHON=str(self.new_python),
            TEST_VENV_PAYLOAD=str(self.payload),
            TEST_UV_LOG=str(self.log),
        )
        self.python_stub(self.old_python, self.old_python)
        self.python_stub(self.new_python, self.new_python)
        self.python_stub(self.payload, self.new_python, venv=True)
        # Execute the real Python probes/merge, replacing only interpreter metadata.
        self.script(self.bin / "uv", f"#!{sys.executable}\n" + '''
import json, os, pathlib, shutil, signal, sys, time
args = sys.argv[1:]
with open(os.environ["TEST_UV_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["python", "install"]:
    sys.exit(int(os.environ.get("TEST_INSTALL_FAILURE", "0")))
if args[:2] == ["python", "find"]:
    print(os.environ["TEST_SELECTED_PYTHON"])
    sys.exit(0)
if not args or args[0] != "sync":
    sys.exit(98)
venv = pathlib.Path(os.environ["UV_PROJECT_ENVIRONMENT"])
(venv / "bin").mkdir(parents=True, exist_ok=True)
shutil.copyfile(os.environ["TEST_VENV_PAYLOAD"], venv / "bin/python")
(venv / "bin/python").chmod(0o755)
if os.environ.get("TEST_SYNC_FAILURE"):
    (venv / "partial").write_text("incomplete sync")
    sys.exit(73)
if os.environ.get("TEST_SIGNAL"):
    os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(0)
if os.environ.get("TEST_WAIT"):
    ready = pathlib.Path(os.environ["TEST_WAIT"])
    ready.write_text("ready")
    for _ in range(1000):
        if ready.with_suffix(".release").exists():
            break
        time.sleep(0.01)
    else:
        sys.exit(97)
''')

    def script(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)

    def python_stub(self, path, base, *, venv=False, series=SERIES):
        code = f'''
import os, sys
args = sys.argv[1:]
index = args.index("-c")
source = args[index + 1]
sys.argv = ["-c", *args[index + 2:]]
sys._base_executable = {str(base)!r}
sys.version_info = {tuple(map(int, series.split("."))) + (1 if base == self.new_python else 0,)!r}
sys.prefix = {str(self.venv) if venv else str(self.state / "python")!r}
sys.base_prefix = {str(self.state / "python")!r}
if os.environ.get("TEST_SMOKE_FAILURE") and "from merge import main" in source:
    raise SystemExit(85)
exec(source)
'''
        self.script(path, "#!/bin/sh\nexec " + shlex.quote(sys.executable) +
                    " -I -B -c " + shlex.quote(code) + ' "$@"\n')

    def existing(self, base=None, series=SERIES):
        base = base or self.old_python
        self.python_stub(self.venv / "bin/python", base, venv=True, series=series)
        (self.venv / "keep").write_text("previous environment")
        return (self.venv / "bin/python").read_bytes()

    def run_setup(self, *args, cwd=None):
        return subprocess.run(["/bin/sh", str(SETUP), *map(str, args)],
                              env=self.env, cwd=cwd or self.base,
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_smoke_check_covers_every_policy(self):
        project = self.base / "project"
        shutil.copytree(SETUP.parent, project, ignore=shutil.ignore_patterns("__pycache__", ".venv"))
        intact = subprocess.run(["/bin/sh", str(project / "setup.sh")], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(intact.returncode, 0, intact.stderr)
        (project / "policy-fugu.toml").write_text("[pin]\n[seed]\n")
        broken = subprocess.run(["/bin/sh", str(project / "setup.sh")], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(broken.returncode, 0)
        self.assertIn("codex-config", broken.stderr)

    def assert_restored(self, result, original):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.venv / "bin/python").read_bytes(), original)
        self.assertEqual((self.venv / "keep").read_text(), "previous environment")
        self.assertFalse((self.venv / "partial").exists())
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.lock.exists())

    def test_bootstrap_ignores_caller_python_and_project(self):
        for name in ("asdf", "python", "python3"):
            self.script(self.bin / name, "#!/bin/sh\nexit 99\n")
        other = self.base / "another project"
        other.mkdir()
        (other / ".python-version").write_text("0.0.0\n")
        self.env.update(UV_PYTHON="/unrelated/python", VIRTUAL_ENV="/unrelated/venv",
                        UV_PROJECT="/unrelated/project", UV_PYTHON_INSTALL_DIR="/unrelated")
        result = self.run_setup(cwd=other)
        self.assertEqual(result.returncode, 0, result.stderr)
        install, find, sync = self.calls()
        self.assertEqual(install, ["python", "install", "--no-config", "--no-bin", SERIES])
        self.assertIn("--managed-python", find)
        self.assertIn("--resolve-links", find)
        self.assertIn("--locked", sync)
        self.assertIn("--no-python-downloads", sync)
        self.assertIn("--managed-python", sync)
        self.assertEqual(sync[sync.index("--python") + 1], SERIES + ".1")
        self.assertFalse(self.lock.exists())

    def test_repeat_sync_keeps_existing_patch_and_environment(self):
        self.existing()
        self.python_stub(self.payload, self.old_python, venv=True)
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][-1], SERIES + ".0")
        self.assertTrue((self.venv / "keep").exists())
        self.assertFalse(self.backup.exists())

    def test_invalid_arguments_and_missing_uv_preserve_existing_environment(self):
        original = self.existing()
        old = self.bin / "old-python"
        self.python_stub(old, old, series="3.10")
        for args in (("",), ("python3",), ("/does/not/exist",),
                     ("--upgrade-python", str(PYTHON)), (old,), (self.new_python,)):
            with self.subTest(args=args):
                result = self.run_setup(*args)
                self.assert_restored(result, original)
                self.assertEqual(self.calls(), [])
        (self.bin / "uv").unlink()
        result = self.run_setup()
        self.assert_restored(result, original)
        self.assertIn("install uv", result.stderr)

    def test_external_broken_and_wrong_series_require_explicit_upgrade(self):
        for kind in ("external", "broken", "wrong-series"):
            with self.subTest(kind=kind):
                if self.venv.exists():
                    shutil.rmtree(self.venv)
                self.existing(base=PYTHON if kind == "external" else None,
                              series="3.11" if kind == "wrong-series" else SERIES)
                if kind == "broken":
                    (self.venv / "bin/python").unlink()
                    (self.venv / "bin/python").symlink_to(self.base / "removed")
                result = self.run_setup()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("--upgrade-python", result.stderr)
                self.assertTrue((self.venv / "keep").exists())
                self.assertEqual(self.calls(), [])
                result = self.run_setup("--upgrade-python")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.venv / "keep").exists())
                self.assertFalse(self.backup.exists())
                self.log.unlink()

    def test_upgrade_rebuilds_only_when_python_changes(self):
        self.existing()
        result = self.run_setup("--upgrade-python")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--upgrade", self.calls()[0])
        self.assertFalse((self.venv / "keep").exists())
        self.assertTrue(self.old_python.exists())
        self.assertFalse(self.backup.exists())
        (self.venv / "keep").write_text("retained on same Python")
        result = self.run_setup("--upgrade-python")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.venv / "keep").read_text(), "retained on same Python")

    def test_download_failure_does_not_move_old_venv(self):
        original = self.existing()
        self.env["TEST_INSTALL_FAILURE"] = "71"
        result = self.run_setup("--upgrade-python")
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assert_restored(result, original)
        self.assertEqual(len(self.calls()), 1)

    def test_sync_and_validation_failure_restore_old_venv(self):
        for stage in ("sync", "smoke", "wrong-python"):
            with self.subTest(stage=stage):
                original = self.existing()
                self.env.pop("TEST_SYNC_FAILURE", None)
                self.env.pop("TEST_SMOKE_FAILURE", None)
                self.python_stub(self.payload, self.new_python, venv=True)
                if stage == "sync":
                    self.env["TEST_SYNC_FAILURE"] = "1"
                elif stage == "smoke":
                    self.env["TEST_SMOKE_FAILURE"] = "1"
                else:
                    self.python_stub(self.payload, self.old_python, venv=True)
                result = self.run_setup("--upgrade-python")
                self.assertEqual(result.returncode, {"sync": 73, "smoke": 85, "wrong-python": 1}[stage])
                self.assert_restored(result, original)
                self.assertIn("restored", result.stderr)

    def test_normal_sync_failure_is_reported_without_rebuild_or_rollback(self):
        self.existing()
        self.python_stub(self.payload, self.old_python, venv=True)
        self.env["TEST_SYNC_FAILURE"] = "1"
        result = self.run_setup()
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertTrue((self.venv / "keep").exists())
        self.assertTrue((self.venv / "partial").exists())
        self.assertNotIn("restored", result.stderr)
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.lock.exists())

    def test_caught_signal_restores_old_venv(self):
        original = self.existing()
        self.env["TEST_SIGNAL"] = "1"
        result = self.run_setup("--upgrade-python")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assert_restored(result, original)

    def test_stale_lock_and_backup_are_preserved(self):
        original = self.existing()
        self.lock.mkdir()
        result = self.run_setup()
        self.assertEqual(result.returncode, 1)
        self.assertIn("lock", result.stderr)
        self.assertEqual(self.calls(), [])
        self.lock.rmdir()
        self.backup.mkdir()
        (self.backup / "keep").write_text("do not delete")
        result = self.run_setup()
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.backup / "keep").read_text(), "do not delete")
        self.assertEqual((self.venv / "bin/python").read_bytes(), original)
        self.assertTrue(self.lock.exists())
        self.assertEqual(self.calls(), [])

    def test_concurrent_setup_is_rejected(self):
        ready = self.base / "ready"
        self.env["TEST_WAIT"] = str(ready)
        process = subprocess.Popen(["/bin/sh", str(SETUP)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "first setup did not reach sync")
            result = self.run_setup()
            self.assertEqual(result.returncode, 1)
            self.assertIn("lock", result.stderr)
            ready.with_suffix(".release").touch()
            _, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_restore_failure_keeps_backup_and_lock(self):
        original = self.existing()
        self.script(self.bin / "mv", "#!/bin/sh\n" +
                    f'[ "$2" != {shlex.quote(str(self.backup))} ] || exit 42\n' +
                    'exec /bin/mv "$@"\n')
        self.env["TEST_SYNC_FAILURE"] = "1"
        result = self.run_setup("--upgrade-python")
        self.assertEqual(result.returncode, 1)
        self.assertIn("restore failed", result.stderr)
        self.assertEqual((self.backup / "bin/python").read_bytes(), original)
        self.assertTrue(self.lock.exists())

    def use_real_uv(self):
        uv = shutil.which("uv")
        self.assertIsNotNone(uv, "uv is required")
        cache = os.environ.get("UV_CACHE_DIR")
        self.assertTrue(cache, "set UV_CACHE_DIR to the prepared dependency cache")
        shutil.copytree(cache, self.env["UV_CACHE_DIR"], symlinks=True)
        (self.bin / "uv").unlink()
        (self.bin / "uv").symlink_to(uv)

    def test_real_uv_managed_migration_rollback_and_patch_binding(self):
        distribution = PYTHON.parent.parent
        if not distribution.name.startswith("cpython-") or "%s.%s" % sys.version_info[:2] != SERIES:
            self.skipTest("explicit-Python compatibility run; managed runtime coverage runs in the default CI jobs")
        self.use_real_uv()
        shutil.copytree(distribution, self.state / "python" / distribution.name, symlinks=True)
        result = self.run_setup(PYTHON)
        self.assertEqual(result.returncode, 0, result.stderr)
        original = (self.venv / "pyvenv.cfg").read_bytes()
        project = self.base / "project"
        shutil.copytree(SETUP.parent, project, ignore=shutil.ignore_patterns("__pycache__"))
        (project / "uv.lock").write_text("invalid = [\n")
        result = subprocess.run(["/bin/sh", str(project / "setup.sh"), "--upgrade-python"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restored", result.stderr)
        self.assertEqual((self.venv / "pyvenv.cfg").read_bytes(), original)
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.lock.exists())
        result = self.run_setup("--upgrade-python")
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = subprocess.check_output([str(self.venv / "bin/python"), "-I", "-c",
                                          "import sys; print(sys._base_executable)"], text=True).strip()
        # uv must not silently bind the venv to its upgradable minor-version link.
        self.assertEqual(actual, str(self.state / "python" / distribution.name / "bin" / PYTHON.name))
        config = (self.venv / "pyvenv.cfg").read_bytes()
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.venv / "pyvenv.cfg").read_bytes(), config)

    def test_real_uv_explicit_path_repeat_and_dependency_failure(self):
        self.use_real_uv()
        alias = self.bin / "python with spaces"
        alias.symlink_to(PYTHON)
        for args in ((alias,), (self.venv / "bin/python",)):
            result = self.run_setup(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
        check = [str(self.venv / "bin/python"), "-I", "-c", "import tomlkit"]
        self.assertEqual(subprocess.run(check, env=self.env).returncode, 0)
        (self.venv / "keep").write_text("retain")
        # Invalid lock is detected by real uv, without the setup replacing venv.
        project = self.base / "project"
        shutil.copytree(SETUP.parent, project, ignore=shutil.ignore_patterns("__pycache__"))
        lock = project / "uv.lock"
        lock.write_text("invalid = [\n")
        result = subprocess.run(["/bin/sh", str(project / "setup.sh"), str(PYTHON)],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.venv / "keep").exists())
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.lock.exists())


if __name__ == "__main__":
    unittest.main()
