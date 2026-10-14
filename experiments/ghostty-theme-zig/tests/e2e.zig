//! End-to-end tests: spawn the built `ghostty-theme` binary against stub
//! `ghostty` / `fzf` commands inside a private temp tree whose path contains
//! spaces, quotes and a literal `$HOME`.
//!
//! * Existing fixtures, snapshots and stubs under `tests/bats/` are used
//!   read-only; expectations are never regenerated from this implementation.
//! * A differential test runs the Bash reference
//!   (`dot_local/bin/executable_ghostty-theme`) and the Zig binary on the same
//!   scenarios and requires identical exit status, stdout and stderr bytes.
//! * Preview tests use `tests/stubs/fzf`, which really executes the
//!   `--preview` expression through `$SHELL -c` like fzf does.
//!
//! Requires Bash 5+ (reference implementation, preview script and stubs).
//! Set BASH5_BIN to an absolute path to pick a specific interpreter.

const std = @import("std");
const opts = @import("build_options");

const testing = std.testing;
const io = testing.io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

const expected_preview_expr = "\"$_GHOSTTY_THEME_PREVIEW_CMD\" --map \"$_GHOSTTY_THEME_PREVIEW_MAP\" {}";
const expected_usage =
    \\Usage: ghostty-theme [theme-name]
    \\
    \\Apply a Ghostty theme to the current surface using OSC escape sequences.
    \\
    \\Positional argument:
    \\  theme-name    Name of a theme reported by `ghostty +list-themes --plain`.
    \\                Omit to launch an fzf picker with live preview.
    \\
    \\Environment:
    \\  GHOSTTY_RESOURCES_DIR  Honored by Ghostty itself to locate bundled themes.
    \\
;
const list_failed_msg = "ghostty-theme: \"ghostty +list-themes\" failed (exit {d}). Is Ghostty installed?\n";

const Result = struct {
    /// Exit status, or 128+N when terminated by signal N.
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    /// Absolute root of this test's private tree (spaces, quotes, `$HOME`).
    root: []const u8,
    stub_bin: []const u8,
    tmpdir: []const u8,
    bash: []const u8,
    env: std.process.Environ.Map,

    fn create() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.arena_state = .init(testing.allocator);
        errdefer self.arena_state.deinit();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const a = self.arena_state.allocator();

        const tmp_abs = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        self.root = try std.fs.path.join(a, &.{ tmp_abs, "work dir 'q' $HOME" });
        try Dir.cwd().createDirPath(io, self.root);
        self.stub_bin = try self.mkdir("stub bin");
        self.tmpdir = try self.mkdir("tmp dir");
        const home = try self.mkdir("home");
        self.bash = try resolveBash5(a);

        try self.writeWrapper(try self.join(&.{ self.stub_bin, "ghostty" }), &.{ self.bash, try experimentPath(a, "tests/stubs/ghostty") });
        try self.writeWrapper(try self.join(&.{ self.stub_bin, "fzf" }), &.{ self.bash, try repoPath(a, "tests/bats/bin/fzf") });
        // `#!/usr/bin/env bash` scripts (the preview script) must get Bash 5
        // even where /usr/bin/bash is older (macOS ships 3.2).
        try self.writeWrapper(try self.join(&.{ self.stub_bin, "bash" }), &.{self.bash});

        self.env = .init(a);
        try self.env.put("PATH", try std.fmt.allocPrint(a, "{s}:/usr/bin:/bin", .{self.stub_bin}));
        try self.env.put("HOME", home);
        try self.env.put("TMPDIR", self.tmpdir);
        try self.env.put("SHELL", "/bin/sh");
        try self.env.put("LC_ALL", "C");
        try self.env.put("GHOSTTY_TEST_THEMES_DIR", try repoPath(a, "tests/bats/fixtures/themes"));
        try self.env.put("GHOSTTY_BASE_STUB", try repoPath(a, "tests/bats/bin/ghostty"));
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
        testing.allocator.destroy(self);
    }

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    fn join(self: *Fixture, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(self.arena(), parts);
    }

    fn mkdir(self: *Fixture, rel: []const u8) ![]const u8 {
        const p = try self.join(&.{ self.root, rel });
        try Dir.cwd().createDirPath(io, p);
        return p;
    }

    fn set(self: *Fixture, key: []const u8, value: []const u8) !void {
        try self.env.put(key, value);
    }

    fn unset(self: *Fixture, key: []const u8) void {
        _ = self.env.swapRemove(key);
    }

    fn writeFile(self: *Fixture, path: []const u8, data: []const u8, executable: bool) !void {
        _ = self;
        try Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = data,
            .flags = .{ .permissions = if (executable) .executable_file else .default_file },
        });
    }

    /// `#!/bin/sh` wrapper that execs `argv` with the wrapper's arguments.
    fn writeWrapper(self: *Fixture, path: []const u8, argv: []const []const u8) !void {
        var script: std.Io.Writer.Allocating = .init(self.arena());
        try script.writer.writeAll("#!/bin/sh\nexec");
        for (argv) |arg| {
            try script.writer.writeAll(" '");
            for (arg) |c| {
                if (c == '\'') try script.writer.writeAll("'\\''") else try script.writer.writeByte(c);
            }
            try script.writer.writeAll("'");
        }
        try script.writer.writeAll(" \"$@\"\n");
        try self.writeFile(path, script.written(), true);
    }

    fn read(self: *Fixture, path: []const u8) ![]u8 {
        return Dir.cwd().readFileAlloc(io, path, self.arena(), .limited(1 << 20));
    }

    fn run(self: *Fixture, argv: []const []const u8) !Result {
        return self.runIn(argv, .inherit);
    }

    fn runIn(self: *Fixture, argv: []const []const u8, cwd: std.process.Child.Cwd) !Result {
        const child_argv = try self.arena().dupe([]const u8, argv);
        if (!std.fs.path.isAbsolute(argv[0]) and std.mem.indexOfScalar(u8, argv[0], '/') != null) {
            const parent_cwd = try std.process.currentPathAlloc(io, self.arena());
            child_argv[0] = try self.join(&.{ parent_cwd, argv[0] });
        }
        const r = try std.process.run(self.arena(), io, .{
            .argv = child_argv,
            .environ_map = &self.env,
            .cwd = cwd,
            // In particular, a regression in pipe handling must fail rather
            // than hang the entire test suite.
            .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
        });
        const code: u8 = switch (r.term) {
            .exited => |c| c,
            .signal, .stopped => |s| 128 +| @as(u8, @truncate(@intFromEnum(s))),
            .unknown => 255,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }

    fn runZig(self: *Fixture, args: []const []const u8) !Result {
        return self.runWith(opts.exe_path, args);
    }

    fn runWith(self: *Fixture, exe: []const u8, args: []const []const u8) !Result {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena(), exe);
        try argv.appendSlice(self.arena(), args);
        return self.run(argv.items);
    }

    fn runBashReference(self: *Fixture, args: []const []const u8) !Result {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena(), self.bash);
        try argv.append(self.arena(), try repoPath(self.arena(), "dot_local/bin/executable_ghostty-theme"));
        try argv.appendSlice(self.arena(), args);
        return self.run(argv.items);
    }

    /// Switches `fzf` on PATH to tests/stubs/fzf (executes --preview).
    fn usePreviewFzf(self: *Fixture) !void {
        try self.writeWrapper(try self.join(&.{ self.stub_bin, "fzf" }), &.{ self.bash, try experimentPath(self.arena(), "tests/stubs/fzf") });
    }

    /// Names of leftover `ghostty-theme.*` map files in TMPDIR.
    fn leftoverMapFiles(self: *Fixture) !usize {
        var dir = try Dir.cwd().openDir(io, self.tmpdir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "ghostty-theme.")) count += 1;
        }
        return count;
    }
};

fn repoPath(a: Allocator, rel: []const u8) ![]const u8 {
    return std.fs.path.resolve(a, &.{ opts.repo_root, rel });
}

fn experimentPath(a: Allocator, rel: []const u8) ![]const u8 {
    return std.fs.path.resolve(a, &.{ opts.experiment_root, rel });
}

fn hostEnv(key: []const u8) ?[]const u8 {
    const value = testing.environ.getPosix(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn findOnHostPath(a: Allocator, name: []const u8) !?[]const u8 {
    const path_env = hostEnv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(a, &.{ dir, name });
        Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    return null;
}

fn resolveBash5(a: Allocator) ![]const u8 {
    const candidate = hostEnv("BASH5_BIN") orelse (try findOnHostPath(a, "bash")) orelse {
        std.debug.print("e2e: Bash 5+ is required (bash not found on PATH; set BASH5_BIN)\n", .{});
        return error.Bash5Required;
    };
    const r = try std.process.run(a, io, .{ .argv = &.{ candidate, "-c", "printf %s \"${BASH_VERSINFO[0]}\"" } });
    const major = std.fmt.parseInt(u32, r.stdout, 10) catch 0;
    if (major < 5) {
        std.debug.print("e2e: Bash 5+ is required, {s} reports major version '{s}' (set BASH5_BIN)\n", .{ candidate, r.stdout });
        return error.Bash5Required;
    }
    return candidate;
}

fn readSnapshot(fx: *Fixture, name: []const u8) ![]const u8 {
    const path = try repoPath(fx.arena(), try std.fmt.allocPrint(fx.arena(), "tests/bats/snapshots/ghostty-theme/{s}.expected", .{name}));
    const raw = try fx.read(path);
    // Bats compares `$(cat snapshot)` with the captured output, both without
    // trailing newlines; the real stdout ends with exactly one newline.
    return std.fmt.allocPrint(fx.arena(), "{s}\n", .{std.mem.trimEnd(u8, raw, "\n")});
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find {f} in {f}\n", .{ std.zig.fmtString(needle), std.zig.fmtString(haystack) });
        return error.TestExpectedContains;
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("did not expect {f} in {f}\n", .{ std.zig.fmtString(needle), std.zig.fmtString(haystack) });
        return error.TestUnexpectedContains;
    }
}

fn expectResult(r: Result, code: u8, stdout: []const u8, stderr: []const u8) !void {
    testing.expectEqual(code, r.code) catch |err| {
        std.debug.print("stdout: {f}\nstderr: {f}\n", .{ std.zig.fmtString(r.stdout), std.zig.fmtString(r.stderr) });
        return err;
    };
    try testing.expectEqualStrings(stdout, r.stdout);
    try testing.expectEqualStrings(stderr, r.stderr);
}

// --- success snapshots ------------------------------------------------------

test "snapshots: OSC bytes and applied message match tests/bats snapshots" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const cases = [_][2][]const u8{
        .{ "TestDark", "TestDark" },
        .{ "TestMinimal", "TestMinimal" },
        .{ "TestMixed", "TestMixed" },
        .{ "Test Spaces", "TestSpaces" },
    };
    for (cases) |c| {
        const r = try fx.runZig(&.{c[0]});
        try expectResult(r, 0, try readSnapshot(fx, c[1]), "");
    }
}

test "TestMixed: invalid 5-digit palette entry is not emitted" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const r = try fx.runZig(&.{"TestMixed"});
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectNotContains(r.stdout, "\x1b]4;2;#");
}

test "TestDark: cursor-text is not applied" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const r = try fx.runZig(&.{"TestDark"});
    try testing.expectEqual(@as(u8, 0), r.code);
    // cursor-text = #1d1f21 would need an OSC code; only background has it.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, r.stdout, "#1d1f21"));
}

test "theme size has no arbitrary 16 MiB cutoff" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const themes = try fx.mkdir("large themes");
    const tail = "\nbackground = #abcdef";
    const content = try fx.arena().alloc(u8, 16 * 1024 * 1024 + tail.len);
    @memset(content[0 .. content.len - tail.len], '#');
    @memcpy(content[content.len - tail.len ..], tail);
    try fx.writeFile(try fx.join(&.{ themes, "Large Comment" }), content, false);
    try fx.set("GHOSTTY_TEST_THEMES_DIR", themes);
    try expectResult(try fx.runZig(&.{"Large Comment"}), 0, "\x1b]11;#abcdef\x1b\\ghostty-theme: applied 'Large Comment'\n", "");
}

// --- precedence -------------------------------------------------------------

test "duplicate name: resources path without user dir, user path with it" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const r1 = try fx.runZig(&.{"TestDuplicate"});
    try expectResult(r1, 0, "\x1b]11;#111111\x1b\\ghostty-theme: applied 'TestDuplicate'\n", "");

    try fx.set("GHOSTTY_TEST_USER_THEMES_DIR", try repoPath(fx.arena(), "tests/bats/fixtures/user_themes"));
    const r2 = try fx.runZig(&.{"TestDuplicate"});
    try expectResult(r2, 0, "\x1b]11;#222222\x1b\\ghostty-theme: applied 'TestDuplicate'\n", "");
}

test "fzf: duplicate listed once in emission order, user path applied" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const log = try fx.join(&.{ fx.root, "fzf stdin.log" });
    try fx.set("GHOSTTY_TEST_USER_THEMES_DIR", try repoPath(fx.arena(), "tests/bats/fixtures/user_themes"));
    try fx.set("FAKE_FZF_STDIN_LOG", log);
    try fx.set("FAKE_FZF_SELECT", "TestDuplicate");
    try fx.set("FAKE_FZF_EXIT", "0");
    const r = try fx.runZig(&.{});
    try expectResult(r, 0, "\x1b]11;#222222\x1b\\ghostty-theme: applied 'TestDuplicate'\n", "");
    try testing.expectEqualStrings(
        "Test Spaces\nTestDark\nTestDuplicate\nTestMinimal\nTestMixed\n",
        try fx.read(log),
    );
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

// --- names with spaces ---------------------------------------------------------

test "fzf: selecting a name with spaces applies it" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("FAKE_FZF_SELECT", "Test Spaces");
    const r = try fx.runZig(&.{});
    try expectResult(r, 0, try readSnapshot(fx, "TestSpaces"), "");
}

test "validate-config receives --config-file=<path> as one argument" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const themes = try fx.mkdir("themes with space");
    const theme_path = try fx.join(&.{ themes, "My 'Odd' $Theme" });
    try fx.writeFile(theme_path, "background = #abcdef\n", false);
    try fx.set("GHOSTTY_TEST_THEMES_DIR", themes);
    const log = try fx.join(&.{ fx.root, "validate.log" });
    try fx.set("GHOSTTY_STUB_VALIDATE_LOG", log);
    const r = try fx.runZig(&.{"My 'Odd' $Theme"});
    try expectResult(r, 0, "\x1b]11;#abcdef\x1b\\ghostty-theme: applied 'My 'Odd' $Theme'\n", "");
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(fx.arena(), "+validate-config\n--config-file={s}\n", .{theme_path}),
        try fx.read(log),
    );
}

// --- cancel / fzf failures --------------------------------------------------

test "fzf cancel (130) and no-match (1): exit 0 without any output" {
    const fx = try Fixture.create();
    defer fx.destroy();
    for ([_][]const u8{ "130", "1" }) |code| {
        try fx.set("FAKE_FZF_EXIT", code);
        const r = try fx.runZig(&.{});
        try expectResult(r, 0, "", "");
    }
    // An empty first argument behaves like no argument (Bash `-n "$1"`).
    try fx.set("FAKE_FZF_EXIT", "130");
    try expectResult(try fx.runZig(&.{""}), 0, "", "");
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

test "fzf killed by SIGINT counts as cancel; other signals are failures" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    try fx.set("FAKE_FZF_SIGNAL", "INT");
    try expectResult(try fx.runZig(&.{}), 0, "", "");
    try fx.set("FAKE_FZF_SIGNAL", "TERM");
    try expectResult(try fx.runZig(&.{}), 143, "", "ghostty-theme: fzf exited with status 143\n");
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

test "fzf other failure: diagnostic and the same non-zero status" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("FAKE_FZF_SELECT", "TestDark");
    try fx.set("FAKE_FZF_EXIT", "2");
    try expectResult(try fx.runZig(&.{}), 2, "", "ghostty-theme: fzf exited with status 2\n");
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

test "fzf: output before reading a large candidate list cannot deadlock" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const list = try fx.join(&.{ fx.root, "large list.txt" });
    const log = try fx.join(&.{ fx.root, "large fzf stdin.log" });
    const theme_path = try repoPath(fx.arena(), "tests/bats/fixtures/themes/TestDark");
    var rows: std.Io.Writer.Allocating = .init(fx.arena());
    var names: std.Io.Writer.Allocating = .init(fx.arena());
    // Both the candidate list and the stub's stdout exceed pipe capacity.
    for (0..20000) |n| {
        try rows.writer.print("Theme {d:0>6} (resources) {s}\n", .{ n, theme_path });
        try names.writer.print("Theme {d:0>6}\n", .{n});
    }
    try fx.writeFile(list, rows.written(), false);
    try fx.set("GHOSTTY_STUB_LIST_FILE", list);
    try fx.set("FAKE_FZF_STDIN_LOG", log);
    try fx.writeFile(
        try fx.join(&.{ fx.stub_bin, "fzf" }),
        "#!/bin/sh\nhead -c 1048576 /dev/zero\ncat > \"$FAKE_FZF_STDIN_LOG\"\nexit \"$FAKE_FZF_EXIT\"\n",
        true,
    );
    for ([_]struct { raw: []const u8, status: u8, stderr: []const u8 }{
        .{ .raw = "130", .status = 0, .stderr = "" },
        .{ .raw = "1", .status = 0, .stderr = "" },
        .{ .raw = "2", .status = 2, .stderr = "ghostty-theme: fzf exited with status 2\n" },
    }) |case| {
        try fx.set("FAKE_FZF_EXIT", case.raw);
        try expectResult(try fx.runZig(&.{}), case.status, "", case.stderr);
        try testing.expectEqualStrings(names.written(), try fx.read(log));
        try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
    }
}

test "fzf: immediate cancellation does not require consuming candidates" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.writeFile(try fx.join(&.{ fx.stub_bin, "fzf" }), "#!/bin/sh\nexit 130\n", true);
    try expectResult(try fx.runZig(&.{}), 0, "", "");
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

test "preview map failure is non-zero and does not launch fzf" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    const missing_tmp = try fx.join(&.{ fx.root, "missing tmp directory" });
    const log = try fx.join(&.{ fx.root, "fzf should not run.log" });
    try fx.set("TMPDIR", missing_tmp);
    try fx.set("FAKE_FZF_ARGS_LOG", log);
    try expectResult(
        try fx.runZig(&.{}),
        1,
        "",
        "ghostty-theme: cannot create the preview map file: FileNotFound\n",
    );
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, log, .{}));
    // A positional selection never needs a preview map or a writable TMPDIR.
    try expectResult(try fx.runZig(&.{"TestDark"}), 0, try readSnapshot(fx, "TestDark"), "");
}

test "fzf: empty selection with status 0 is reported as not found" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("FAKE_FZF_SELECT", "");
    try expectResult(try fx.runZig(&.{}), 1, "", "ghostty-theme: theme '' not found. Run 'ghostty +list-themes --plain' for the list.\n");
}

// --- missing commands ---------------------------------------------------------

test "missing fzf: exit 127 with diagnostic, positional use still works" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const bin = try fx.mkdir("only ghostty");
    try fx.writeWrapper(try fx.join(&.{ bin, "ghostty" }), &.{ fx.bash, try experimentPath(fx.arena(), "tests/stubs/ghostty") });
    try fx.set("PATH", try std.fmt.allocPrint(fx.arena(), "{s}:/usr/bin:/bin", .{bin}));
    try expectResult(try fx.runZig(&.{}), 127, "", "ghostty-theme: fzf not found; pass a theme name as argument.\n");
    try expectResult(try fx.runZig(&.{"TestMinimal"}), 0, try readSnapshot(fx, "TestMinimal"), "");
}

test "missing ghostty: exit 127 with diagnostic, before any listing" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const empty = try fx.mkdir("empty bin");
    try fx.set("PATH", try std.fmt.allocPrint(fx.arena(), "{s}:/usr/bin:/bin", .{empty}));
    const r = try fx.runZig(&.{"TestDark"});
    try testing.expectEqual(@as(u8, 127), r.code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expect(std.mem.startsWith(u8, r.stderr, "ghostty-theme: `ghostty` CLI not found on PATH.\n"));
    // The fzf path checks ghostty first, too.
    try testing.expectEqual(@as(u8, 127), (try fx.runZig(&.{})).code);
}

test "non-executable ghostty on PATH is skipped like `command -v`" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const bin = try fx.mkdir("noexec bin");
    try fx.writeFile(try fx.join(&.{ bin, "ghostty" }), "#!/bin/sh\nexit 0\n", false);
    try fx.set("PATH", try std.fmt.allocPrint(fx.arena(), "{s}:/usr/bin:/bin", .{bin}));
    try testing.expectEqual(@as(u8, 127), (try fx.runZig(&.{"TestDark"})).code);
}

test "PATH: relative and empty entries resolve commands in the current directory" {
    const fx = try Fixture.create();
    defer fx.destroy();
    for ([_][]const u8{ ".:/usr/bin:/bin", ":/usr/bin:/bin" }) |path| {
        try fx.set("PATH", path);
        try expectResult(
            try fx.runIn(&.{ opts.exe_path, "TestDark" }, .{ .path = fx.stub_bin }),
            0,
            try readSnapshot(fx, "TestDark"),
            "",
        );
        try fx.set("FAKE_FZF_SELECT", "Test Spaces");
        try expectResult(
            try fx.runIn(&.{opts.exe_path}, .{ .path = fx.stub_bin }),
            0,
            try readSnapshot(fx, "TestSpaces"),
            "",
        );
    }
}

// --- listing failures ----------------------------------------------------------

test "list-themes failure: Ghostty stderr, diagnostic, its exit status" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("GHOSTTY_STUB_FAIL", "1");
    const msg1 = try std.fmt.allocPrint(fx.arena(), "stub ghostty: simulated failure\n" ++ list_failed_msg, .{1});
    try expectResult(try fx.runZig(&.{"TestDark"}), 1, "", msg1);

    // The interactive path fails the same way and never starts fzf.
    try fx.usePreviewFzf();
    const args_log = try fx.join(&.{ fx.root, "fzf args.log" });
    try fx.set("FAKE_FZF_ARGS_LOG", args_log);
    try expectResult(try fx.runZig(&.{}), 1, "", msg1);
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, args_log, .{}));

    fx.unset("GHOSTTY_STUB_FAIL");
    try fx.set("GHOSTTY_STUB_LIST_EXIT", "3");
    try fx.set("GHOSTTY_STUB_LIST_STDERR", "boom");
    const msg3 = try std.fmt.allocPrint(fx.arena(), "boom\n" ++ list_failed_msg, .{3});
    try expectResult(try fx.runZig(&.{"TestDark"}), 3, "", msg3);
}

test "list-themes killed by a signal is a failure (128+N)" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("GHOSTTY_STUB_LIST_SIGNAL", "TERM");
    const r = try fx.runZig(&.{"TestDark"});
    try expectResult(r, 143, "", try std.fmt.allocPrint(fx.arena(), list_failed_msg, .{143}));
}

test "list-themes success with partial output but non-zero exit is not trusted" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const list = try fx.join(&.{ fx.root, "list.txt" });
    const theme_file = try repoPath(fx.arena(), "tests/bats/fixtures/themes/TestDark");
    try fx.writeFile(list, try std.fmt.allocPrint(fx.arena(), "TestDark (resources) {s}\n", .{theme_file}), false);
    try fx.set("GHOSTTY_STUB_LIST_FILE", list);
    try fx.set("GHOSTTY_STUB_LIST_EXIT", "4");
    const r = try fx.runZig(&.{"TestDark"});
    try expectResult(r, 4, "", try std.fmt.allocPrint(fx.arena(), list_failed_msg, .{4}));
}

test "no usable themes: exit 1" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const list = try fx.join(&.{ fx.root, "list.txt" });
    try fx.writeFile(list, "garbage without marker\n\n (user) /empty/name\n", false);
    try fx.set("GHOSTTY_STUB_LIST_FILE", list);
    try expectResult(try fx.runZig(&.{"TestDark"}), 1, "", "ghostty-theme: no themes reported by \"ghostty +list-themes\".\n");
}

test "listing: user before resources wins, stable dedup order, no final newline" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const list = try fx.join(&.{ fx.root, "out of order list.txt" });
    const log = try fx.join(&.{ fx.root, "ordered fzf stdin.log" });
    const user = try repoPath(fx.arena(), "tests/bats/fixtures/user_themes/TestDuplicate");
    const resource = try repoPath(fx.arena(), "tests/bats/fixtures/themes/TestDuplicate");
    try fx.writeFile(list, try std.fmt.allocPrint(
        fx.arena(),
        "First (user) {0s}\ninvalid\nSecond (resources) {1s}\nFirst (resources) {1s}\nSecond (resources) /ignored\nLast (resources) {1s}",
        .{ user, resource },
    ), false);
    try fx.set("GHOSTTY_STUB_LIST_FILE", list);
    try fx.set("FAKE_FZF_STDIN_LOG", log);
    try fx.set("FAKE_FZF_SELECT", "First");
    try expectResult(try fx.runZig(&.{}), 0, "\x1b]11;#222222\x1b\\ghostty-theme: applied 'First'\n", "");
    try testing.expectEqualStrings("First\nSecond\nLast\n", try fx.read(log));
    try expectResult(try fx.runZig(&.{"Last"}), 0, "\x1b]11;#111111\x1b\\ghostty-theme: applied 'Last'\n", "");
}

test "listed path that is a directory or empty is rejected" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const list = try fx.join(&.{ fx.root, "list.txt" });
    try fx.writeFile(list, try std.fmt.allocPrint(fx.arena(), "Dir Theme (resources) {s}\nEmpty Path (resources) \n", .{fx.root}), false);
    try fx.set("GHOSTTY_STUB_LIST_FILE", list);
    try expectResult(
        try fx.runZig(&.{"Dir Theme"}),
        1,
        "",
        try std.fmt.allocPrint(fx.arena(), "ghostty-theme: resolved path for 'Dir Theme' is not a file: {s}\n", .{fx.root}),
    );
    try expectResult(try fx.runZig(&.{"Empty Path"}), 1, "", "ghostty-theme: theme 'Empty Path' not found. Run 'ghostty +list-themes --plain' for the list.\n");
}

test "missing theme: exit 1 with diagnostic" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try expectResult(try fx.runZig(&.{"NoSuch"}), 1, "", "ghostty-theme: theme 'NoSuch' not found. Run 'ghostty +list-themes --plain' for the list.\n");
}

// --- validation failures -------------------------------------------------------

test "validate-config failure: no OSC at all, diagnostic, its exit status" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("GHOSTTY_STUB_VALIDATE_FAIL", "1");
    try expectResult(
        try fx.runZig(&.{"TestDark"}),
        1,
        "",
        "ghostty-theme: theme 'TestDark' failed validation (exit 1):\nstub ghostty: simulated validation failure\n",
    );
    // Also through fzf.
    try fx.set("FAKE_FZF_SELECT", "Test Spaces");
    const r = try fx.runZig(&.{});
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("", r.stdout);
}

test "validate-config failure keeps interleaved stdout/stderr order" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("GHOSTTY_STUB_VALIDATE_EXIT", "3");
    try expectResult(
        try fx.runZig(&.{"TestDark"}),
        3,
        "",
        "ghostty-theme: theme 'TestDark' failed validation (exit 3):\nout-1\nerr-2\nout-3\n",
    );
}

test "validation: success output is suppressed, signal failure emits no OSC" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("GHOSTTY_STUB_VALIDATE_EXIT", "0");
    try expectResult(try fx.runZig(&.{"TestDark"}), 0, try readSnapshot(fx, "TestDark"), "");
    fx.unset("GHOSTTY_STUB_VALIDATE_EXIT");
    try fx.set("GHOSTTY_STUB_VALIDATE_SIGNAL", "TERM");
    try expectResult(
        try fx.runZig(&.{"TestDark"}),
        143,
        "",
        "ghostty-theme: theme 'TestDark' failed validation (exit 143):\n\n",
    );
}

test "theme removed after successful validation: read failure without OSC" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const themes = try fx.mkdir("vanishing themes");
    const theme_path = try fx.join(&.{ themes, "Vanishing" });
    try fx.writeFile(theme_path, "background = #123456\n", false);
    try fx.set("GHOSTTY_TEST_THEMES_DIR", themes);
    try fx.set("GHOSTTY_STUB_REMOVE_AFTER_VALIDATE", "1");
    const r = try fx.runZig(&.{"Vanishing"});
    try expectResult(
        r,
        1,
        "",
        try std.fmt.allocPrint(fx.arena(), "ghostty-theme: cannot read theme file '{s}': FileNotFound\n", .{theme_path}),
    );
}

// --- help -----------------------------------------------------------------------

test "--help and -h print usage on stdout without needing ghostty" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.set("PATH", "/nonexistent");
    try expectResult(try fx.runZig(&.{"--help"}), 0, expected_usage, "");
    try expectResult(try fx.runZig(&.{ "-h", "ignored" }), 0, expected_usage, "");
}

// --- differential: Bash reference vs Zig ---------------------------------------

const Scenario = struct {
    name: []const u8,
    args: []const []const u8,
    env: []const [2][]const u8 = &.{},
};

test "differential: Bash reference and Zig agree byte-for-byte" {
    const fx = try Fixture.create();
    defer fx.destroy();
    const a = fx.arena();

    const themes = try fx.mkdir("diff themes");
    const user_themes = try fx.mkdir("diff user themes");
    const empty_themes = try fx.mkdir("diff empty themes");
    const files = [_][2][]const u8{
        .{ "CRLF Theme", "palette = 0=#010101\r\nbackground = #020202\r\n" },
        .{ "No Final Newline", "palette = 5=#0a0b0c\nforeground = #0d0e0f" },
        .{ "Whitespace", " \t palette\t=\t9\t=\t#AbCdEf \t\n\x0bbackground\x0c=\x0b#123abc\x0c\n   selection-foreground   =   #fedcba   \n" },
        .{ "Invalid Colors", "palette = 1=#12345\npalette = 2=#1234567\npalette = x=#123456\n" ++
            "palette = 3 = #123456 extra\npalette=16=#ffffff\npalette = 007=#070707\n" ++
            "background=#123456\nbackground-image = #654321\n  # foreground = #111111\n" ++
            "foreground = #12345g\ncursor-color = 123456\ncursor-color = #ABCDEF # c\n" ++
            "cursor-text = #222222\nselection-background = #333333\nselection-background==#444444\n" ++
            "palette = 4=#123456=#654321\n" },
        .{ "Name 'q' $HOME", "cursor-color = #333333\n" },
        .{ "A (user) B", "background = #444444\n" },
        .{ "Empty", "" },
        .{ "Comments Only", "# palette = 0=#000000\n\n" },
        .{ "INVALID theme", "background = #555555\n" },
    };
    for (files) |f| try fx.writeFile(try fx.join(&.{ themes, f[0] }), f[1], false);
    try fx.writeFile(try fx.join(&.{ user_themes, "CRLF Theme" }), "background = #999999\n", false);

    const list = try fx.join(&.{ fx.root, "custom list.txt" });
    try fx.writeFile(list, try std.fmt.allocPrint(a, "Dir Theme (resources) {s}\nEmpty Path (resources) \nNo (marker) here\n", .{fx.root}), false);
    const no_fzf_bin = try fx.mkdir("diff no fzf bin");
    try fx.writeWrapper(try fx.join(&.{ no_fzf_bin, "ghostty" }), &.{ fx.bash, try experimentPath(a, "tests/stubs/ghostty") });
    const no_fzf_path = try std.fmt.allocPrint(a, "{s}:/usr/bin:/bin", .{no_fzf_bin});
    const no_ghostty_path = try std.fmt.allocPrint(a, "{s}:/usr/bin:/bin", .{try fx.mkdir("diff empty bin")});

    var scenarios: std.ArrayList(Scenario) = .empty;
    for (files) |f| try scenarios.append(a, .{ .name = f[0], .args = try a.dupe([]const u8, &.{f[0]}) });
    const more = [_]Scenario{
        .{ .name = "user override", .args = &.{"CRLF Theme"}, .env = &.{.{ "GHOSTTY_TEST_USER_THEMES_DIR", user_themes }} },
        .{ .name = "greedy parse full name", .args = &.{try std.fmt.allocPrint(a, "A (user) B (resources) {s}/A", .{themes})} },
        .{ .name = "not found", .args = &.{"NoSuch"} },
        .{ .name = "extra args ignored", .args = &.{ "Empty", "extra", "--help" } },
        .{ .name = "help", .args = &.{"--help"} },
        .{ .name = "short help", .args = &.{"-h"} },
        .{ .name = "list failure", .args = &.{"Empty"}, .env = &.{.{ "GHOSTTY_STUB_FAIL", "1" }} },
        .{ .name = "list exit 3", .args = &.{"Empty"}, .env = &.{ .{ "GHOSTTY_STUB_LIST_EXIT", "3" }, .{ "GHOSTTY_STUB_LIST_STDERR", "boom" } } },
        .{ .name = "validate failure", .args = &.{"Whitespace"}, .env = &.{.{ "GHOSTTY_STUB_VALIDATE_FAIL", "1" }} },
        .{ .name = "validate interleaved", .args = &.{"Whitespace"}, .env = &.{.{ "GHOSTTY_STUB_VALIDATE_EXIT", "5" }} },
        .{ .name = "no themes", .args = &.{"Empty"}, .env = &.{.{ "GHOSTTY_TEST_THEMES_DIR", empty_themes }} },
        .{ .name = "custom list dir", .args = &.{"Dir Theme"}, .env = &.{.{ "GHOSTTY_STUB_LIST_FILE", list }} },
        .{ .name = "custom list empty path", .args = &.{"Empty Path"}, .env = &.{.{ "GHOSTTY_STUB_LIST_FILE", list }} },
        .{ .name = "fzf select quoted", .args = &.{}, .env = &.{.{ "FAKE_FZF_SELECT", "Name 'q' $HOME" }} },
        .{ .name = "fzf select with user", .args = &.{}, .env = &.{ .{ "FAKE_FZF_SELECT", "CRLF Theme" }, .{ "GHOSTTY_TEST_USER_THEMES_DIR", user_themes } } },
        .{ .name = "fzf empty arg", .args = &.{""}, .env = &.{.{ "FAKE_FZF_SELECT", "Empty" }} },
        .{ .name = "fzf no match", .args = &.{}, .env = &.{.{ "FAKE_FZF_EXIT", "1" }} },
        .{ .name = "fzf cancel", .args = &.{}, .env = &.{.{ "FAKE_FZF_EXIT", "130" }} },
        .{ .name = "fzf failure", .args = &.{}, .env = &.{.{ "FAKE_FZF_EXIT", "2" }} },
        .{ .name = "fzf unknown selection", .args = &.{}, .env = &.{.{ "FAKE_FZF_SELECT", "Nope" }} },
        .{ .name = "fzf missing", .args = &.{}, .env = &.{.{ "PATH", no_fzf_path }} },
        .{ .name = "ghostty missing", .args = &.{"Empty"}, .env = &.{.{ "PATH", no_ghostty_path }} },
    };
    try scenarios.appendSlice(a, &more);

    const base_env = try fx.env.clone(a);
    var failures: usize = 0;
    for (scenarios.items) |s| {
        fx.env = try base_env.clone(a);
        try fx.set("GHOSTTY_TEST_THEMES_DIR", themes);
        for (s.env) |kv| try fx.set(kv[0], kv[1]);
        const bash_r = try fx.runBashReference(s.args);
        const zig_r = try fx.runZig(s.args);
        if (bash_r.code != zig_r.code or !std.mem.eql(u8, bash_r.stdout, zig_r.stdout) or !std.mem.eql(u8, bash_r.stderr, zig_r.stderr)) {
            failures += 1;
            std.debug.print(
                "differential mismatch in '{s}':\n  bash: code={d} stdout={f} stderr={f}\n  zig:  code={d} stdout={f} stderr={f}\n",
                .{ s.name, bash_r.code, std.zig.fmtString(bash_r.stdout), std.zig.fmtString(bash_r.stderr), zig_r.code, std.zig.fmtString(zig_r.stdout), std.zig.fmtString(zig_r.stderr) },
            );
        }
    }
    fx.env = base_env;
    try testing.expectEqual(@as(usize, 0), failures);
}

// --- live preview ----------------------------------------------------------------

/// Copies the binary into `<root>/<dir>/` (optionally with a sibling copy of
/// the real preview script) and returns the copied binary's path.
fn installCopy(fx: *Fixture, dir_rel: []const u8, with_preview: bool) ![]const u8 {
    const dir = try fx.mkdir(dir_rel);
    const exe = try fx.join(&.{ dir, "ghostty-theme" });
    try Dir.copyFile(Dir.cwd(), opts.exe_path, Dir.cwd(), exe, io, .{});
    if (with_preview) {
        try Dir.copyFile(Dir.cwd(), try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview"), Dir.cwd(), try fx.join(&.{ dir, "ghostty-theme-preview" }), io, .{ .permissions = .executable_file });
    }
    return exe;
}

/// What `ghostty-theme-preview <file>` prints for the "Test Spaces" fixture.
fn expectedPreview(fx: *Fixture) ![]const u8 {
    const r = try fx.run(&.{ fx.bash, try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview"), try repoPath(fx.arena(), "tests/bats/fixtures/themes/Test Spaces") });
    try testing.expectEqual(@as(u8, 0), r.code);
    try expectContains(r.stdout, "#ff0000");
    try expectContains(r.stdout, "#00ff00");
    return r.stdout;
}

fn expectPreviewRan(fx: *Fixture, out_path: []const u8, expected: []const u8) !void {
    const rc = try fx.read(try std.fmt.allocPrint(fx.arena(), "{s}.rc", .{out_path}));
    const out = try fx.read(out_path);
    testing.expectEqualStrings("0\n", rc) catch |err| {
        std.debug.print("preview output: {f}\n", .{std.zig.fmtString(out)});
        return err;
    };
    try testing.expectEqualStrings(expected, out);
}

test "preview: sibling script under paths with spaces/quotes runs via sh, bash, zsh, fish" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    const expected = try expectedPreview(fx);
    const exe = try installCopy(fx, "install dir 'x' $PATH/bin", true);

    var shells: std.ArrayList([]const u8) = .empty;
    try shells.appendSlice(fx.arena(), &.{ "/bin/sh", fx.bash });
    for ([_][]const u8{ "zsh", "fish" }) |name| {
        if (try findOnHostPath(fx.arena(), name)) |p| try shells.append(fx.arena(), p);
    }
    const out_path = try fx.join(&.{ fx.root, "preview out" });
    const args_log = try fx.join(&.{ fx.root, "fzf args.log" });
    try fx.set("FAKE_FZF_PREVIEW_OUT", out_path);
    try fx.set("FAKE_FZF_ARGS_LOG", args_log);
    try fx.set("FAKE_FZF_SELECT", "Test Spaces");
    for (shells.items) |shell| {
        try fx.set("SHELL", shell);
        const r = try fx.runWith(exe, &.{});
        try expectResult(r, 0, try readSnapshot(fx, "TestSpaces"), "");
        expectPreviewRan(fx, out_path, expected) catch |err| {
            std.debug.print("preview failed with SHELL={s}\n", .{shell});
            return err;
        };
        try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
    }
    try testing.expectEqualStrings(
        "--layout=reverse\n--preview\n" ++ expected_preview_expr ++ "\n--preview-window\nright:50%\n",
        try fx.read(args_log),
    );
}

test "preview: exported paths point at the sibling script and a private map" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    const exe = try installCopy(fx, "env dir", true);
    const env_log = try fx.join(&.{ fx.root, "fzf env.log" });
    try fx.set("FAKE_FZF_ENV_LOG", env_log);
    try fx.set("FAKE_FZF_EXIT", "130");
    try expectResult(try fx.runWith(exe, &.{}), 0, "", "");
    const env_text = try fx.read(env_log);
    try expectContains(env_text, try std.fmt.allocPrint(fx.arena(), "\n_GHOSTTY_THEME_PREVIEW_CMD={s}/env dir/ghostty-theme-preview\n", .{fx.root}));
    try expectContains(env_text, try std.fmt.allocPrint(fx.arena(), "\n_GHOSTTY_THEME_PREVIEW_MAP={s}/ghostty-theme.", .{fx.tmpdir}));
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

test "preview: map file is private and lists name<TAB>path with user override" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    // A fake preview that copies the map and reports its permissions.
    const fake = try fx.join(&.{ fx.root, "fake preview" });
    try fx.writeFile(fake, "#!/bin/sh\n[ \"$1\" = --map ] || exit 9\ncp \"$2\" \"$MAP_COPY\"\nls -l \"$2\" | cut -c1-10 > \"$MAP_COPY.mode\"\nprintf 'name=%s\\n' \"$3\"\n", true);
    const map_copy = try fx.join(&.{ fx.root, "map copy" });
    const out_path = try fx.join(&.{ fx.root, "preview out" });
    try fx.set("GHOSTTY_THEME_PREVIEW", fake);
    try fx.set("MAP_COPY", map_copy);
    try fx.set("FAKE_FZF_PREVIEW_OUT", out_path);
    try fx.set("FAKE_FZF_SELECT", "Test Spaces");
    try fx.set("GHOSTTY_TEST_USER_THEMES_DIR", try repoPath(fx.arena(), "tests/bats/fixtures/user_themes"));
    try expectResult(try fx.runZig(&.{}), 0, try readSnapshot(fx, "TestSpaces"), "");
    try expectPreviewRan(fx, out_path, "name=Test Spaces\n");
    const themes = try repoPath(fx.arena(), "tests/bats/fixtures/themes");
    const user = try repoPath(fx.arena(), "tests/bats/fixtures/user_themes");
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(fx.arena(), "Test Spaces\t{0s}/Test Spaces\nTestDark\t{0s}/TestDark\nTestDuplicate\t{1s}/TestDuplicate\nTestMinimal\t{0s}/TestMinimal\nTestMixed\t{0s}/TestMixed\n", .{ themes, user }),
        try fx.read(map_copy),
    );
    try testing.expectEqualStrings("-rw-------\n", try fx.read(try std.fmt.allocPrint(fx.arena(), "{s}.mode", .{map_copy})));
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

test "preview: GHOSTTY_THEME_PREVIEW and GHOSTTY_THEME_PREVIEW_BASH overrides" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    const expected = try expectedPreview(fx);
    const dir = try fx.mkdir("override 'dir' $SHELL");
    // Non-executable copy: only works when run through the given interpreter.
    const script = try fx.join(&.{ dir, "preview script.bash" });
    try Dir.copyFile(Dir.cwd(), try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview"), Dir.cwd(), script, io, .{ .permissions = .default_file });
    const out_path = try fx.join(&.{ fx.root, "preview out" });
    try fx.set("FAKE_FZF_PREVIEW_OUT", out_path);
    try fx.set("FAKE_FZF_SELECT", "Test Spaces");
    try fx.set("GHOSTTY_THEME_PREVIEW", script);
    try fx.set("GHOSTTY_THEME_PREVIEW_BASH", fx.bash);
    try expectResult(try fx.runZig(&.{}), 0, try readSnapshot(fx, "TestSpaces"), "");
    try expectPreviewRan(fx, out_path, expected);

    // An executable override is run directly (shebang) without the interpreter.
    const exec_script = try fx.join(&.{ dir, "ghostty-theme-preview" });
    try Dir.copyFile(Dir.cwd(), try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview"), Dir.cwd(), exec_script, io, .{ .permissions = .executable_file });
    fx.unset("GHOSTTY_THEME_PREVIEW_BASH");
    try fx.set("GHOSTTY_THEME_PREVIEW", exec_script);
    // The shebang uses `env bash`, which finds the Bash 5 wrapper in stub_bin.
    try expectResult(try fx.runZig(&.{}), 0, try readSnapshot(fx, "TestSpaces"), "");
    try expectPreviewRan(fx, out_path, expected);
}

test "preview: quoted candidate and paths are data, not shell expressions" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    const themes = try fx.mkdir("theme dir \"double\" \\ backslash");
    const name = "Name 'single' \"double\" $(touch INJECTED) \\ backslash";
    const theme_path = try fx.join(&.{ themes, name });
    try fx.writeFile(theme_path, "background = #2468Ac", false);
    try fx.set("GHOSTTY_TEST_THEMES_DIR", themes);
    try fx.set("FAKE_FZF_SELECT", name);
    const out_path = try fx.join(&.{ fx.root, "quoted preview.out" });
    try fx.set("FAKE_FZF_PREVIEW_OUT", out_path);
    try fx.set("GHOSTTY_THEME_PREVIEW", try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview"));
    try fx.set("GHOSTTY_THEME_PREVIEW_BASH", fx.bash);
    const reference = try fx.run(&.{
        fx.bash,
        try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview"),
        theme_path,
    });
    try testing.expectEqual(@as(u8, 0), reference.code);
    // Run the preview shell in the private root so the injection sentinel can
    // only be created there, even if escaping is accidentally broken.
    try expectResult(
        try fx.runIn(&.{opts.exe_path}, .{ .path = fx.root }),
        0,
        try std.fmt.allocPrint(fx.arena(), "\x1b]11;#2468Ac\x1b\\ghostty-theme: applied '{s}'\n", .{name}),
        "",
    );
    try expectPreviewRan(fx, out_path, reference.stdout);
    const sentinel = try fx.join(&.{ fx.root, "INJECTED" });
    try testing.expectError(error.FileNotFound, Dir.cwd().access(io, sentinel, .{}));
}

test "preview: relative TMPDIR preserves symlink followed by parent traversal" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    const target = try fx.mkdir("physical/child");
    const tmp = try fx.mkdir("physical/actual tmp");
    const link = try fx.join(&.{ fx.root, "tmp link" });
    try Dir.cwd().symLink(io, target, link, .{ .is_directory = true });
    // Lexically collapsing `tmp link/..` would incorrectly use <root>/actual
    // tmp instead of <root>/physical/actual tmp.
    try fx.set("TMPDIR", "tmp link/../actual tmp");
    try fx.set("FAKE_FZF_SELECT", "Test Spaces");
    try fx.set("GHOSTTY_THEME_PREVIEW", try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview"));
    try fx.set("GHOSTTY_THEME_PREVIEW_BASH", fx.bash);
    const out_path = try fx.join(&.{ fx.root, "relative preview.out" });
    try fx.set("FAKE_FZF_PREVIEW_OUT", out_path);
    try expectResult(
        try fx.runIn(&.{opts.exe_path}, .{ .path = fx.root }),
        0,
        try readSnapshot(fx, "TestSpaces"),
        "",
    );
    try expectPreviewRan(fx, out_path, try expectedPreview(fx));
    fx.tmpdir = tmp;
    try testing.expectEqual(@as(usize, 0), try fx.leftoverMapFiles());
}

test "preview: lookup via invoked path, real executable, then PATH" {
    const fx = try Fixture.create();
    defer fx.destroy();
    try fx.usePreviewFzf();
    const expected = try expectedPreview(fx);
    const out_path = try fx.join(&.{ fx.root, "preview out" });
    const env_log = try fx.join(&.{ fx.root, "fzf env.log" });
    try fx.set("FAKE_FZF_PREVIEW_OUT", out_path);
    try fx.set("FAKE_FZF_ENV_LOG", env_log);
    try fx.set("FAKE_FZF_SELECT", "Test Spaces");

    // (a) Invoked by bare name through PATH: sibling of the PATH entry.
    const real = try installCopy(fx, "real dir", true);
    const real_dir = std.fs.path.dirname(real).?;
    const saved_path = try fx.arena().dupe(u8, fx.env.get("PATH").?);
    try fx.set("PATH", try std.fmt.allocPrint(fx.arena(), "{s}:{s}", .{ real_dir, saved_path }));
    try expectResult(try fx.run(&.{ "/bin/sh", "-c", "exec ghostty-theme" }), 0, try readSnapshot(fx, "TestSpaces"), "");
    try expectPreviewRan(fx, out_path, expected);
    try expectContains(try fx.read(env_log), try std.fmt.allocPrint(fx.arena(), "\n_GHOSTTY_THEME_PREVIEW_CMD={s}/ghostty-theme-preview\n", .{real_dir}));
    try fx.set("PATH", saved_path);

    // (b) Invoked through a symlink whose directory has its own preview:
    //     the invoked directory wins (Bash `$0` semantics).
    const link_dir = try fx.mkdir("link dir");
    const link = try fx.join(&.{ link_dir, "ghostty-theme" });
    try Dir.cwd().symLink(io, real, link, .{});
    const link_preview = try fx.join(&.{ link_dir, "ghostty-theme-preview" });
    try fx.writeWrapper(link_preview, &.{ fx.bash, try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview") });
    try expectResult(try fx.runWith(link, &.{}), 0, try readSnapshot(fx, "TestSpaces"), "");
    try expectPreviewRan(fx, out_path, expected);
    try expectContains(try fx.read(env_log), try std.fmt.allocPrint(fx.arena(), "\n_GHOSTTY_THEME_PREVIEW_CMD={s}\n", .{link_preview}));

    // (c) Symlink directory without a preview: falls back to the real binary's directory.
    try Dir.cwd().deleteFile(io, link_preview);
    try expectResult(try fx.runWith(link, &.{}), 0, try readSnapshot(fx, "TestSpaces"), "");
    try expectPreviewRan(fx, out_path, expected);
    try expectContains(try fx.read(env_log), try std.fmt.allocPrint(fx.arena(), "\n_GHOSTTY_THEME_PREVIEW_CMD={s}/ghostty-theme-preview\n", .{real_dir}));

    // (d) No sibling anywhere: bare `ghostty-theme-preview` resolved via PATH.
    const lonely = try installCopy(fx, "lonely dir", false);
    try fx.writeWrapper(try fx.join(&.{ fx.stub_bin, "ghostty-theme-preview" }), &.{ fx.bash, try repoPath(fx.arena(), "dot_local/bin/executable_ghostty-theme-preview") });
    try expectResult(try fx.runWith(lonely, &.{}), 0, try readSnapshot(fx, "TestSpaces"), "");
    try expectPreviewRan(fx, out_path, expected);
    try expectContains(try fx.read(env_log), "\n_GHOSTTY_THEME_PREVIEW_CMD=ghostty-theme-preview\n");
}
