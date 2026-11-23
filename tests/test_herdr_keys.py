import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "dot_local/bin/executable_herdr-keys"
MODULE = runpy.run_path(str(SCRIPT))["main"].__globals__
DEFAULTS = {"global": {"cmd-n": "space.new", "cmd-w": "tab.close", "cmd-t": "tab.new"}}


class HerdrKeysTest(unittest.TestCase):
    def run_command(self, root, *, apply=False, interactive=False, answers=(), defaults=DEFAULTS):
        argv = ["herdr-keys", "--apply"] if apply else ["herdr-keys"]
        output = io.StringIO()
        data = json.dumps(defaults).encode() if isinstance(defaults, dict) else defaults
        fetch = Mock(side_effect=data) if isinstance(data, OSError) else Mock(return_value=io.BytesIO(data))
        with (
            patch.dict(MODULE, {"installed_version": lambda: "0.1.17"}),
            patch.dict("os.environ", {"HERDR_APP_HOME": str(root)}),
            patch("sys.argv", argv),
            patch("sys.stdout", output),
            patch("sys.stderr", output),
            patch.object(output, "isatty", return_value=interactive),
            patch("sys.stdin.isatty", return_value=interactive),
            patch("builtins.input", side_effect=answers),
            patch.dict(MODULE, {"urlopen": fetch}),
        ):
            code = MODULE["main"]()
            self.assertIn("/v0.1.17/defaults/keys.macos.json", fetch.call_args.args[0])
        return code, output.getvalue()

    def test_preview_and_noninteractive_apply_preserve_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "keys.json"
            path.write_text(json.dumps(DEFAULTS))
            before = path.read_bytes()
            for apply in (False, True):
                code, output = self.run_command(root, apply=apply)
                self.assertEqual(code, 0)
                self.assertIn("cmd-shift-n", output)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(list(root.iterdir()), [path])

    def test_apply_preserves_selected_custom_bindings_and_backs_up(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "keys.json"
            current = {"global": {**DEFAULTS["global"], "cmd-p": "mod.open:custom"}}
            path.write_text(json.dumps(current))
            original = path.read_bytes()
            path.chmod(0o600)
            code, _ = self.run_command(root, apply=True, interactive=True, answers=["k", "y"])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(path.read_text())["global"], {
                "cmd-t": "tab.new", "cmd-shift-n": "space.new", "cmd-p": "mod.open:custom"
            })
            backups = list(root.glob("keys.json.backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), original)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)

    def test_custom_space_binding_keeps_both_keys_when_declined(self):
        current = {"global": {"cmd-n": "space.new", "cmd-shift-n": "mod.open:custom"}}
        candidate = {"global": {"cmd-shift-n": "space.new"}}
        changes = list(MODULE["keymap_changes"](current, candidate))
        with patch("builtins.input", return_value="k"):
            self.assertTrue(MODULE["resolve_changes"](candidate, changes))
        self.assertEqual(candidate, current)

    def test_absent_file_is_created_only_after_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code, _ = self.run_command(root, apply=True, interactive=True, answers=["y"])
            self.assertEqual(code, 0)
            expected = {"global": {"cmd-t": "tab.new", "cmd-shift-n": "space.new"}}
            self.assertEqual(json.loads((root / "keys.json").read_text()), expected)
            self.assertFalse(list(root.glob("keys.json.backup-*")))

    def test_invalid_release_stops_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for defaults in (OSError("unavailable"), b"{", {
                "global": {"cmd-n": "space.new", "cmd-shift-n": "tab.new"}
            }):
                code, _ = self.run_command(root, apply=True, interactive=True, defaults=defaults)
                self.assertEqual(code, 1)
                self.assertEqual(list(root.iterdir()), [])

    def test_cancel_keeps_original_and_new_choice_imports_default(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "keys.json"
            current = {"global": {"cmd-shift-n": "space.new", "cmd-t": "tab.prev"}}
            path.write_text(json.dumps(current))
            code, _ = self.run_command(root, apply=True, interactive=True, answers=["q"])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(path.read_text()), current)
            self.assertFalse(list(root.glob("keys.json.backup-*")))
            code, _ = self.run_command(root, apply=True, interactive=True, answers=["n", "y"])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(path.read_text())["global"]["cmd-t"], "tab.new")

    def test_same_keymap_does_not_rewrite_formatting_or_object_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "keys.json"
            original = '{"global":{"cmd-t":{"args":{},"command":"tab.new"},"cmd-shift-n":"space.new"}}'
            path.write_text(original)
            defaults = {"global": {**DEFAULTS["global"], "cmd-t": {"command": "tab.new", "args": {}}}}
            code, output = self.run_command(root, apply=True, interactive=True, defaults=defaults)
            self.assertEqual(code, 0)
            self.assertIn("No keymap changes.", output)
            self.assertEqual(path.read_text(), original)
            self.assertFalse(list(root.glob("keys.json.backup-*")))

    def test_concurrent_edit_is_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "keys.json"
            path.write_text("{}")
            before = MODULE["snapshot"](path)
            path.write_text('{"global": {}}')
            with patch.dict(MODULE, {"installed_version": lambda: "0.1.17"}):
                with self.assertRaisesRegex(ValueError, "changed during review"):
                    MODULE["apply_keymap"](path, before, DEFAULTS, "0.1.17")
            self.assertEqual(path.read_text(), '{"global": {}}')
            self.assertFalse(list(path.parent.glob("keys.json.backup-*")))

    def test_apply_reports_write_without_inferring_reload_from_old_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            error = root / "keys.error"
            error.write_text("older invalid binding")
            with patch("subprocess.run", side_effect=AssertionError("unexpected status probe")):
                code, output = self.run_command(root, apply=True, interactive=True, answers=["y"])
            self.assertEqual(code, 0)
            self.assertTrue((root / "keys.json").exists())
            self.assertEqual(error.read_text(), "older invalid binding")
            self.assertIn("Wrote ", output)
            self.assertIn("Check the reload", output)
