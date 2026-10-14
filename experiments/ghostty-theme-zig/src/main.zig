//! ghostty-theme (Zig port): apply a Ghostty bundled/user theme to the current
//! surface via OSC escape sequences.
//!
//! Behavior mirrors `dot_local/bin/executable_ghostty-theme` (Bash):
//!   * themes are discovered with `ghostty +list-themes --plain --path`
//!     (de-duplicated, user overrides resources);
//!   * the chosen theme is validated with
//!     `ghostty +validate-config --config-file=<path>` before any OSC output;
//!   * without an argument, fzf is launched with the existing Bash
//!     `ghostty-theme-preview` as live preview.
//! Intentional differences are documented in README.md.

const std = @import("std");
const theme = @import("theme.zig");

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const posix = std.posix;

const usage_text =
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

/// Used when PATH is unset (Bash falls back to a compiled-in default, too).
const default_path = "/usr/local/bin:/usr/bin:/bin";
const mac_app_cli = "/Applications/Ghostty.app/Contents/MacOS/ghostty";
const preview_name = "ghostty-theme-preview";

/// User-facing overrides for the preview command (documented in README.md).
const env_preview_override = "GHOSTTY_THEME_PREVIEW";
const env_preview_bash_override = "GHOSTTY_THEME_PREVIEW_BASH";
/// Internal variables exported to fzf so the --preview expression only needs
/// `"$VAR"` expansions, which are valid in sh/bash/zsh/fish alike and keep
/// arbitrary path bytes (spaces, quotes, `$`, backslashes) intact.
const env_preview_cmd = "_GHOSTTY_THEME_PREVIEW_CMD";
const env_preview_map = "_GHOSTTY_THEME_PREVIEW_MAP";
const env_preview_bash = "_GHOSTTY_THEME_PREVIEW_BASH";

const preview_expr_plain =
    "\"$" ++ env_preview_cmd ++ "\" --map \"$" ++ env_preview_map ++ "\" {}";
const preview_expr_with_bash =
    "\"$" ++ env_preview_bash ++ "\" " ++ preview_expr_plain;

const App = struct {
    io: Io,
    arena: Allocator,
    env: *const std.process.Environ.Map,

    fn printErr(app: *const App, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(app.arena, fmt, args) catch return;
        writeErr(app, msg);
    }

    fn writeErr(app: *const App, bytes: []const u8) void {
        File.stderr().writeStreamingAll(app.io, bytes) catch {};
    }

    fn getEnv(app: *const App, key: []const u8) ?[]const u8 {
        const value = app.env.get(key) orelse return null;
        return if (value.len == 0) null else value;
    }

    /// `command -v <name>` restricted to PATH executables.
    fn findExecutable(app: *const App, name: []const u8) ?[]const u8 {
        const path_env = app.env.get("PATH") orelse default_path;
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const candidate = std.fs.path.join(app.arena, &.{ if (dir.len == 0) "." else dir, name }) catch return null;
            if (app.isExecutableFile(candidate)) return candidate;
        }
        return null;
    }

    fn isRegularFile(app: *const App, path: []const u8) bool {
        const st = Dir.cwd().statFile(app.io, path, .{}) catch return false;
        return st.kind == .file;
    }

    fn isExecutableFile(app: *const App, path: []const u8) bool {
        if (!app.isRegularFile(path)) return false;
        Dir.cwd().access(app.io, path, .{ .execute = true }) catch return false;
        return true;
    }

    fn absolutize(app: *const App, path: []const u8) []const u8 {
        if (std.fs.path.isAbsolute(path)) return path;
        const cwd = std.process.currentPathAlloc(app.io, app.arena) catch return path;
        // Do not lexically collapse `..`: a preceding symlink changes which
        // parent directory it names. Leave that resolution to the filesystem.
        return std.fs.path.join(app.arena, &.{ cwd, path }) catch path;
    }
};

pub fn main(init: std.process.Init) u8 {
    const app: App = .{
        .io = init.io,
        .arena = init.arena.allocator(),
        .env = init.environ_map,
    };
    const args = init.minimal.args.toSlice(app.arena) catch {
        app.writeErr("ghostty-theme: out of memory\n");
        return 1;
    };
    return run(&app, args) catch |err| {
        app.printErr("ghostty-theme: unexpected error: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(app: *const App, args: []const [:0]const u8) !u8 {
    const first: []const u8 = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        File.stdout().writeStreamingAll(app.io, usage_text) catch return 1;
        return 0;
    }

    const ghostty = app.findExecutable("ghostty") orelse {
        app.writeErr("ghostty-theme: `ghostty` CLI not found on PATH.\n");
        if (app.isExecutableFile(mac_app_cli)) {
            app.writeErr("Ghostty.app is installed but its CLI is not on PATH.\n" ++
                "Either enable Ghostty shell integration, or add:\n" ++
                "  export PATH=\"/Applications/Ghostty.app/Contents/MacOS:$PATH\"\n");
        } else {
            app.writeErr("Install Ghostty from https://ghostty.org/.\n");
        }
        return 127;
    };

    // --- Discover themes ---------------------------------------------------
    const list = runCaptured(app, &.{ ghostty, "+list-themes", "--plain", "--path" });
    if (list.rc != 0) {
        // Surface Ghostty's own diagnostic, then ours (same order as Bash).
        app.writeErr(list.stderr);
        app.printErr("ghostty-theme: \"ghostty +list-themes\" failed (exit {d}). Is Ghostty installed?\n", .{list.rc});
        return list.rc;
    }

    var index = try theme.ThemeIndex.parse(app.arena, list.stdout);
    if (index.names.items.len == 0) {
        app.writeErr("ghostty-theme: no themes reported by \"ghostty +list-themes\".\n");
        return 1;
    }

    // --- Resolve theme name ------------------------------------------------
    var theme_name: []const u8 = first;
    if (theme_name.len == 0) {
        switch (try pickWithFzf(app, &index, if (args.len > 0) args[0] else "")) {
            .selected => |name| theme_name = name,
            .exit => |code| return code,
        }
    }

    const theme_path = index.lookup(theme_name) orelse {
        app.printErr("ghostty-theme: theme '{s}' not found. Run 'ghostty +list-themes --plain' for the list.\n", .{theme_name});
        return 1;
    };
    if (!app.isRegularFile(theme_path)) {
        app.printErr("ghostty-theme: resolved path for '{s}' is not a file: {s}\n", .{ theme_name, theme_path });
        return 1;
    }

    // --- Validate before applying ------------------------------------------
    const config_arg = try std.fmt.allocPrint(app.arena, "--config-file={s}", .{theme_path});
    const validation = try runMerged(app, &.{ ghostty, "+validate-config", config_arg });
    if (validation.rc != 0) {
        app.printErr("ghostty-theme: theme '{s}' failed validation (exit {d}):\n{s}\n", .{
            theme_name,
            validation.rc,
            theme.trimTrailingNewlines(validation.output),
        });
        return validation.rc;
    }

    // --- Emit OSC ----------------------------------------------------------
    // The whole file is read before anything is written so that a read error
    // never leaves a partially applied theme.
    const content = Dir.cwd().readFileAlloc(app.io, theme_path, app.arena, .unlimited) catch |err| {
        app.printErr("ghostty-theme: cannot read theme file '{s}': {s}\n", .{ theme_path, @errorName(err) });
        return 1;
    };
    var out: Io.Writer.Allocating = .init(app.arena);
    try theme.writeOsc(&out.writer, content);
    try out.writer.print("ghostty-theme: applied '{s}'\n", .{theme_name});
    File.stdout().writeStreamingAll(app.io, out.written()) catch |err| {
        app.printErr("ghostty-theme: write to stdout failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

// --- Child processes ----------------------------------------------------------

/// Shell-style exit status: exit code, or 128+N when killed by signal N.
fn termToRc(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 +| @as(u8, @truncate(@intFromEnum(sig))),
        .unknown => 1,
    };
}

/// Shell-style status for a command that could not be executed.
fn spawnErrorRc(err: anyerror) u8 {
    return if (err == error.FileNotFound) 127 else 126;
}

const Captured = struct { rc: u8, stdout: []const u8, stderr: []const u8 };

/// Runs `argv`, capturing stdout and stderr separately.
fn runCaptured(app: *const App, argv: []const []const u8) Captured {
    const result = std.process.run(app.arena, app.io, .{ .argv = argv }) catch |err| {
        const msg = std.fmt.allocPrint(app.arena, "ghostty-theme: failed to run '{s}': {s}\n", .{ argv[0], @errorName(err) }) catch "";
        return .{ .rc = spawnErrorRc(err), .stdout = "", .stderr = msg };
    };
    return .{ .rc = termToRc(result.term), .stdout = result.stdout, .stderr = result.stderr };
}

const Merged = struct { rc: u8, output: []const u8 };

/// Runs `argv` with stdout and stderr sharing one pipe (Bash `2>&1`), so the
/// diagnostic keeps the child's interleaving.
fn runMerged(app: *const App, argv: []const []const u8) !Merged {
    const io = app.io;
    const fds = Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch |err| {
        return .{ .rc = 126, .output = try std.fmt.allocPrint(app.arena, "ghostty-theme: cannot create pipe: {s}", .{@errorName(err)}) };
    };
    const read_end: File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer read_end.close(io);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .{ .file = write_end },
        .stderr = .{ .file = write_end },
    }) catch |err| {
        write_end.close(io);
        return .{ .rc = spawnErrorRc(err), .output = try std.fmt.allocPrint(app.arena, "ghostty-theme: failed to run '{s}': {s}", .{ argv[0], @errorName(err) }) };
    };
    // Only the child may hold the write end, otherwise EOF never arrives.
    write_end.close(io);

    var buf: [4096]u8 = undefined;
    var reader = read_end.readerStreaming(io, &buf);
    const output = reader.interface.allocRemaining(app.arena, .unlimited) catch |err| {
        child.kill(io);
        return .{ .rc = 1, .output = try std.fmt.allocPrint(app.arena, "ghostty-theme: reading '{s}' output failed: {s}", .{ argv[0], @errorName(err) }) };
    };
    const term = try child.wait(io);
    return .{ .rc = termToRc(term), .output = output };
}

// --- fzf picker ----------------------------------------------------------------

const Pick = union(enum) {
    selected: []const u8,
    exit: u8,
};

fn pickWithFzf(app: *const App, index: *const theme.ThemeIndex, argv0: []const u8) !Pick {
    const io = app.io;
    const fzf = app.findExecutable("fzf") orelse {
        app.writeErr("ghostty-theme: fzf not found; pass a theme name as argument.\n");
        return .{ .exit = 127 };
    };

    const preview_cmd = resolvePreviewCommand(app, argv0);
    const map_path = createMapFile(app, index) catch |err| {
        app.printErr("ghostty-theme: cannot create the preview map file: {s}\n", .{@errorName(err)});
        return .{ .exit = 1 };
    };
    defer Dir.cwd().deleteFile(io, map_path) catch {};

    var fzf_env = try app.env.clone(app.arena);
    try fzf_env.put(env_preview_cmd, preview_cmd);
    try fzf_env.put(env_preview_map, map_path);
    var preview_expr: []const u8 = preview_expr_plain;
    if (app.getEnv(env_preview_bash_override)) |bash| {
        try fzf_env.put(env_preview_bash, bash);
        preview_expr = preview_expr_with_bash;
    }

    var names: Io.Writer.Allocating = .init(app.arena);
    try index.writeNames(&names.writer);
    // A synchronous stdin-pipe write followed by a stdout read can deadlock
    // when fzf produces output before consuming every candidate. A private,
    // already-unlinked file provides the same bytes without pipe backpressure.
    const input = createCandidateInput(app, names.written()) catch |err| {
        app.printErr("ghostty-theme: cannot prepare fzf input: {s}\n", .{@errorName(err)});
        return .{ .exit = 1 };
    };
    defer input.close(io);

    // Keep the parent alive (and the map file cleaned up) if SIGINT/SIGQUIT
    // reaches the whole process group while fzf runs; fzf decides the outcome.
    const guard = SignalGuard.install();
    defer guard.restore();

    var child = std.process.spawn(io, .{
        .argv = &.{ fzf, "--layout=reverse", "--preview", preview_expr, "--preview-window", "right:50%" },
        .environ_map = &fzf_env,
        .stdin = .{ .file = input },
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        app.printErr("ghostty-theme: failed to run '{s}': {s}\n", .{ fzf, @errorName(err) });
        const rc = spawnErrorRc(err);
        app.printErr("ghostty-theme: fzf exited with status {d}\n", .{rc});
        return .{ .exit = rc };
    };

    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const selection = reader.interface.allocRemaining(app.arena, .unlimited) catch |err| {
        child.kill(io);
        app.printErr("ghostty-theme: reading fzf output failed: {s}\n", .{@errorName(err)});
        return .{ .exit = 1 };
    };
    const rc = termToRc(try child.wait(io));
    switch (rc) {
        0 => return .{ .selected = theme.trimTrailingNewlines(selection) },
        // No match (1) or Esc/Ctrl-C (130): silent success.
        1, 130 => return .{ .exit = 0 },
        else => {
            app.printErr("ghostty-theme: fzf exited with status {d}\n", .{rc});
            return .{ .exit = rc };
        },
    }
}

/// Preview command lookup order:
///   1. $GHOSTTY_THEME_PREVIEW (explicit override);
///   2. `ghostty-theme-preview` next to the invoked path (Bash `$0` semantics);
///   3. `ghostty-theme-preview` next to the real executable (symlinks resolved);
///   4. bare `ghostty-theme-preview`, resolved via PATH by fzf's shell.
fn resolvePreviewCommand(app: *const App, argv0: []const u8) []const u8 {
    if (app.getEnv(env_preview_override)) |cmd| return cmd;

    if (invokedDir(app, argv0)) |dir| {
        if (siblingPreview(app, dir)) |p| return p;
    }
    if (std.process.executableDirPathAlloc(app.io, app.arena)) |dir| {
        if (siblingPreview(app, dir)) |p| return p;
    } else |_| {}
    return preview_name;
}

fn invokedDir(app: *const App, argv0: []const u8) ?[]const u8 {
    if (argv0.len == 0) return null;
    const invoked = if (std.mem.indexOfScalar(u8, argv0, '/') != null)
        argv0
    else
        app.findExecutable(argv0) orelse return null;
    return app.absolutize(std.fs.path.dirname(invoked) orelse ".");
}

fn siblingPreview(app: *const App, dir: []const u8) ?[]const u8 {
    const candidate = std.fs.path.join(app.arena, &.{ dir, preview_name }) catch return null;
    return if (app.isExecutableFile(candidate)) candidate else null;
}

/// Creates a private (0600) `name<TAB>path` map for the preview, like
/// `mktemp` in the Bash version. Returns its absolute path.
fn createMapFile(app: *const App, index: *const theme.ThemeIndex) ![]const u8 {
    var content: Io.Writer.Allocating = .init(app.arena);
    try index.writeMap(&content.writer);

    const tmp = try createPrivateTempFile(app);
    defer tmp.file.close(app.io);
    errdefer Dir.cwd().deleteFile(app.io, tmp.path) catch {};
    try tmp.file.writeStreamingAll(app.io, content.written());
    return tmp.path;
}

/// The descriptor starts at offset zero because positional writes do not move
/// its stream offset. Unlinking before spawn also prevents cancellation from
/// leaving candidate-list files behind.
fn createCandidateInput(app: *const App, content: []const u8) !File {
    const tmp = try createPrivateTempFile(app);
    errdefer tmp.file.close(app.io);
    errdefer Dir.cwd().deleteFile(app.io, tmp.path) catch {};
    try Dir.cwd().deleteFile(app.io, tmp.path);
    try tmp.file.writePositionalAll(app.io, content, 0);
    return tmp.file;
}

const PrivateTempFile = struct { path: []const u8, file: File };

fn createPrivateTempFile(app: *const App) !PrivateTempFile {
    const io = app.io;
    const base = app.absolutize(app.getEnv("TMPDIR") orelse "/tmp");
    var attempt: usize = 0;
    while (attempt < 64) : (attempt += 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const hex = std.fmt.bytesToHex(random_bytes, .lower);
        const name = try std.fmt.allocPrint(app.arena, "ghostty-theme.{s}", .{&hex});
        const path = try std.fs.path.join(app.arena, &.{ base, name });
        const file = Dir.cwd().createFile(io, path, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return .{ .path = path, .file = file };
    }
    return error.PathAlreadyExists;
}

const SignalGuard = struct {
    const signals = [_]posix.SIG{ .INT, .QUIT };
    installed: [signals.len]bool = @splat(false),
    old: [signals.len]posix.Sigaction = undefined,

    fn noop(_: posix.SIG) callconv(.c) void {}

    /// Installs a no-op handler (reset to default in children on exec) unless
    /// the signal is already ignored, in which case it is left untouched.
    fn install() SignalGuard {
        var guard: SignalGuard = .{};
        if (posix.Sigaction == void) return guard;
        const act: posix.Sigaction = .{
            .handler = .{ .handler = noop },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        for (signals, 0..) |sig, i| {
            posix.sigaction(sig, null, &guard.old[i]);
            if (guard.old[i].handler.handler) |h| {
                if (@intFromPtr(h) == 1) continue; // SIG_IGN
            }
            posix.sigaction(sig, &act, null);
            guard.installed[i] = true;
        }
        return guard;
    }

    fn restore(guard: *const SignalGuard) void {
        if (posix.Sigaction == void) return;
        for (signals, 0..) |sig, i| {
            if (guard.installed[i]) posix.sigaction(sig, &guard.old[i], null);
        }
    }
};

test {
    _ = theme;
}
