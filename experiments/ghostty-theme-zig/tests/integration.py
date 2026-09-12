"""Exercise the compiled Zig binary; never write terminal escape bytes to the console."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


BINARY = Path(sys.argv.pop(1)).resolve()
REPO = Path(__file__).resolve().parents[3]
REFERENCE = REPO / "tests/bats"
BASH = shutil.which(os.environ.get("BASH5_BIN", "bash"))
if not BASH or subprocess.run(
    [BASH, "-c", "(( BASH_VERSINFO[0] >= 5 ))"], capture_output=True
).returncode:
    raise SystemExit("Tests require Bash 5+ (set BASH5_BIN)")


class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ghostty zig ' ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.scratch = self.root / "tmp space '"
        self.scratch.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.preview = self.root / "preview space ' helper"
        shutil.copyfile(REPO / "dot_local/bin/executable_ghostty-theme-preview", self.preview)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("GHOSTTY_", "FAKE_FZF_", "FZF_", "BASH_FUNC_"))}
        for key in ("BASH_ENV", "ENV"):
            self.env.pop(key, None)
        self.env.update(
            HOME=str(self.home), TMPDIR=str(self.scratch),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            BASH5_BIN=BASH, SHELL="/bin/sh",
            GHOSTTY_TEST_THEMES_DIR=str(REFERENCE / "fixtures/themes"),
            GHOSTTY_THEME_PREVIEW=str(self.preview),
        )
        for command in ("ghostty", "fzf"):
            self.script(command, f"#!/bin/sh\nexec {shlex.quote(BASH)} "
                        f"{shlex.quote(str(REFERENCE / 'bin' / command))} \"$@\"\n")

    def script(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)
        return path

    def run_binary(self, *args, rc=0, **env):
        result = subprocess.run([str(BINARY), *args], env=self.env | env,
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, rc, repr(result.stderr))
        self.assertEqual(list(self.scratch.iterdir()), [], "temporary files leaked")
        return result

    def assert_snapshot(self, result, filename):
        # Bats command substitution strips the final newline from snapshots.
        expected = (REFERENCE / "snapshots/ghostty-theme" / filename).read_bytes() + b"\n"
        self.assertEqual(result.stdout, expected)
        self.assertEqual(result.stderr, b"")

    def test_snapshots(self):
        for name, snapshot in [("TestDark", "TestDark"), ("TestMinimal", "TestMinimal"),
                               ("TestMixed", "TestMixed"), ("Test Spaces", "TestSpaces")]:
            with self.subTest(name=name):
                self.assert_snapshot(self.run_binary(name), snapshot + ".expected")

    def test_duplicates(self):
        self.assertIn(b"\x1b]11;#111111\x1b\\", self.run_binary("TestDuplicate").stdout)
        log = self.root / "names"
        result = self.run_binary(
            FAKE_FZF_SELECT="TestDuplicate", FAKE_FZF_STDIN_LOG=str(log),
            GHOSTTY_TEST_USER_THEMES_DIR=str(REFERENCE / "fixtures/user_themes"))
        self.assertIn(b"\x1b]11;#222222\x1b\\", result.stdout)
        self.assertNotIn(b"#111111", result.stdout)
        self.assertEqual(log.read_text().splitlines().count("TestDuplicate"), 1)

    def test_selection(self):
        self.assert_snapshot(self.run_binary(FAKE_FZF_SELECT="Test Spaces"), "TestSpaces.expected")

    def test_cancel(self):
        for code in (1, 130):
            with self.subTest(code=code):
                self.script("fzf", f"#!/bin/sh\necho discard\necho discard >&2\nexit {code}\n")
                result = self.run_binary()
                self.assertEqual((result.stdout, result.stderr), (b"", b""))

    def test_fzf_failure(self):
        result = self.run_binary(rc=42, FAKE_FZF_EXIT="42")
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"fzf exited with status 42", result.stderr)

    def test_discovery_failure(self):
        result = self.run_binary("TestDark", rc=1, GHOSTTY_STUB_FAIL="1")
        self.assertEqual(result.stdout, b"")
        self.assertIn(b'"ghostty +list-themes" failed', result.stderr)
        self.assertIn(b"simulated failure", result.stderr)

    def test_validate_failure(self):
        result = self.run_binary("TestDark", rc=1, GHOSTTY_STUB_VALIDATE_FAIL="1")
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"failed validation", result.stderr)
        self.assertNotIn(b"\x1b", result.stderr)

    def test_status_propagation(self):
        self.script("ghostty", '#!/bin/sh\necho partial\necho failed >&2\nexit 23\n')
        result = self.run_binary("TestDark", rc=23)
        self.assertEqual(result.stdout, b"")
        theme = REFERENCE / "fixtures/themes/TestDark"
        self.script("ghostty", '#!/bin/sh\ncase "$1" in\n+list-themes) printf "%s\\n" '
                    + shlex.quote(f"TestDark (resources) {theme}")
                    + ';;\n*) echo invalid; exit 29;;\nesac\n')
        self.assertEqual(self.run_binary("TestDark", rc=29).stdout, b"")

    def test_empty_list(self):
        self.script("ghostty", '#!/bin/sh\necho "unrecognized line"\n')
        result = self.run_binary("TestDark", rc=1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"no themes", result.stderr)

    def test_missing_theme(self):
        result = self.run_binary("NoSuch", rc=1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"not found", result.stderr)

    def test_missing_ghostty_and_help(self):
        (self.bin / "ghostty").unlink()
        result = self.run_binary("TestDark", rc=127, PATH=str(self.bin))
        self.assertEqual(result.stdout, b"")
        self.assertTrue(result.stderr)
        for flag in ("-h", "--help"):
            self.assertIn(b"Usage: ghostty-theme", self.run_binary(flag, PATH=str(self.bin)).stdout)

    def test_missing_fzf_and_bash(self):
        # Self-contained ghostty stub does not need basename or an inherited PATH.
        theme = REFERENCE / "fixtures/themes/TestDark"
        self.script("ghostty", "#!/bin/sh\nprintf '%s\\n' " +
                    shlex.quote(f"TestDark (resources) {theme}") + "\n")
        (self.bin / "fzf").unlink()
        self.assertEqual(self.run_binary(rc=127, PATH=str(self.bin)).stdout, b"")
        self.assertEqual(self.run_binary(rc=127, BASH5_BIN="missing-bash").stdout, b"")

    def test_old_bash(self):
        old = self.script("old-bash", "#!/bin/sh\nexit 1\n")
        self.assertIn(b"Bash 5+", self.run_binary(rc=2, BASH5_BIN=str(old)).stderr)

    def test_final_line_and_whitespace(self):
        theme_dir = self.root / "themes"
        theme_dir.mkdir()
        (theme_dir / "Last").write_bytes(
            b"# comment\n \tpalette \t= 0002 = #AbCdEf \r\n"
            b"palette=3=#12345\nbackground=#123456 # inline ignored\n"
            b"cursor-text=#ffffff\nforeground = #ABCDEF")
        result = self.run_binary("Last", GHOSTTY_TEST_THEMES_DIR=str(theme_dir))
        self.assertEqual(result.stdout,
                         b"\x1b]4;0002;#AbCdEf\x1b\\\x1b]10;#ABCDEF\x1b\\"
                         b"ghostty-theme: applied 'Last'\n")

    def test_user_first_and_no_list_newline(self):
        user = REFERENCE / "fixtures/user_themes/TestDuplicate"
        resource = REFERENCE / "fixtures/themes/TestDuplicate"
        self.script("ghostty", '#!/bin/sh\nif [ "$1" = +list-themes ]; then\nprintf "%s\\n%s" '
                    + shlex.quote(f"TestDuplicate (user) {user}") + " "
                    + shlex.quote(f"TestDuplicate (resources) {resource}") + "\nfi\n")
        self.assertIn(b"#222222", self.run_binary("TestDuplicate").stdout)

    def test_real_preview_with_quoted_paths(self):
        # Existing fzf stub never runs --preview. This one substitutes the name
        # with shell quoting, runs the actual helper, and logs its bytes separately.
        self.script("fzf", f"#!{sys.executable}\n" + r'''
import os, pathlib, shlex, subprocess, sys
names = sys.stdin.read().splitlines()
name = os.environ.get("PREVIEW_SELECT", "TestDuplicate")
assert names.count(name) == 1
expr = sys.argv[sys.argv.index("--preview") + 1]
args = shlex.split(expr)
assert args[-1] == "{}" and args[-3] == "--map"
assert pathlib.Path(args[-2]).is_file()
p = subprocess.run([os.environ["SHELL"], "-c", expr.replace("{}", shlex.quote(name))],
                   cwd=os.environ["HOME"], capture_output=True)
assert p.returncode == 0, repr(p.stderr)
pathlib.Path(os.environ["PREVIEW_LOG"]).write_bytes(p.stdout)
print(name)
''')
        log = self.root / "preview-output"
        result = self.run_binary(PREVIEW_LOG=str(log),
                                 GHOSTTY_TEST_USER_THEMES_DIR=str(REFERENCE / "fixtures/user_themes"))
        self.assertIn(b"#222222", result.stdout)
        self.assertIn(b"#222222", log.read_bytes())
        self.assertNotIn(b"#111111", log.read_bytes())
        # Include shell syntax in both the name and file path; it must remain data.
        theme_dir = self.root / "quoted themes"
        theme_dir.mkdir()
        name = "Space ' $(touch POISONED); theme"
        (theme_dir / name).write_text("background=#123456\n")
        result = self.run_binary(PREVIEW_LOG=str(log), PREVIEW_SELECT=name,
                                 GHOSTTY_TEST_THEMES_DIR=str(theme_dir))
        self.assertIn(b"#123456", result.stdout)
        self.assertIn(b"#123456", log.read_bytes())
        self.assertFalse((self.home / "POISONED").exists())

    def test_preview_sibling_and_path_fallback(self):
        # Reuse the preview-executing fzf, then test the default lookup paths.
        self.test_real_preview_with_quoted_paths()
        copied = self.bin / "ghostty-theme"
        shutil.copyfile(BINARY, copied)
        copied.chmod(0o755)
        helper = self.bin / "ghostty-theme-preview"
        shutil.copyfile(self.preview, helper)
        env = self.env | {"PREVIEW_LOG": str(self.root / "preview-output")}
        del env["GHOSTTY_THEME_PREVIEW"]
        for executable in (copied, BINARY):
            with self.subTest(executable=str(executable)):
                result = subprocess.run([str(executable)], env=env, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, repr(result.stderr))
                self.assertIn(b"#111111", (self.root / "preview-output").read_bytes())
                self.assertEqual(list(self.scratch.iterdir()), [])

    def test_missing_resolved_file(self):
        self.script("ghostty", "#!/bin/sh\nprintf '%s\\n' 'Gone (resources) /missing/theme'\n")
        result = self.run_binary("Gone", rc=1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"not readable", result.stderr)

    def test_relative_tmpdir(self):
        tmp = os.path.relpath(self.scratch)
        self.assert_snapshot(self.run_binary(TMPDIR=tmp, FAKE_FZF_SELECT="TestDark"), "TestDark.expected")


if __name__ == "__main__":
    unittest.main(verbosity=2)
