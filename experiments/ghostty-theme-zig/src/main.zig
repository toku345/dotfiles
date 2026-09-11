const std = @import("std");
const Io = std.Io;
const Theme = struct { name: []const u8, path: []const u8 };
const Context = struct {
    a: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,

    fn fmt(c: Context, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(c.a, format, args);
    }
    fn diagnostic(c: Context, comptime format: []const u8, args: anytype) !void {
        try Io.File.stderr().writeStreamingAll(c.io, try c.fmt(format, args));
    }
    fn run(c: Context, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(c.a, c.io, .{ .argv = argv, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) }) catch |err| {
            try c.diagnostic("ghostty-theme: could not run '{s}': {s}\n", .{ argv[0], @errorName(err) });
            return if (err == error.FileNotFound) error.MissingCli else err;
        };
    }
};

fn status(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |rc| rc,
        .signal => |sig| @intCast(@min(255, 128 + @as(u32, @intFromEnum(sig)))),
        else => 1,
    };
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

// Quote only fixed arguments; fzf quotes its own {} replacement.
fn quote(c: Context, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.a);
    try out.writer.writeByte('\'');
    for (s) |ch| {
        if (ch == '\'') try out.writer.writeAll("'\\''") else try out.writer.writeByte(ch);
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

fn discover(c: Context, output: []const u8) ![]Theme {
    var themes: std.ArrayList(Theme) = .empty;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const r = std.mem.lastIndexOf(u8, line, " (resources) ");
        const u = std.mem.lastIndexOf(u8, line, " (user) ");
        const user = u != null and (r == null or u.? > r.?);
        const pos = (if (user) u else r) orelse continue;
        const name = line[0..pos];
        const path = line[pos + (if (user) @as(usize, 8) else 13) ..];
        if (name.len == 0) continue;
        var found = false;
        for (themes.items) |*theme| {
            if (std.mem.eql(u8, theme.name, name)) {
                if (user) theme.path = path;
                found = true;
                break;
            }
        }
        if (!found) try themes.append(c.a, .{ .name = name, .path = path });
    }
    return themes.toOwnedSlice(c.a);
}

fn render(c: Context, content: []const u8, name: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.a);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..eq]);
        var color = trim(line[eq + 1 ..]);
        var index: ?[]const u8 = null;
        if (std.mem.eql(u8, key, "palette")) {
            const peq = std.mem.indexOfScalar(u8, color, '=') orelse continue;
            const digits = trim(color[0..peq]);
            if (digits.len == 0) continue;
            var valid = true;
            for (digits) |ch| valid = valid and std.ascii.isDigit(ch);
            if (!valid) continue;
            index = digits;
            color = trim(color[peq + 1 ..]);
        }
        if (color.len != 7 or color[0] != '#') continue;
        var valid = true;
        for (color[1..]) |ch| valid = valid and std.ascii.isHex(ch);
        if (!valid) continue;
        if (index) |idx| {
            try out.writer.print("\x1b]4;{s};{s}\x1b\\", .{ idx, color });
        } else {
            const keys = [_][]const u8{ "background", "foreground", "cursor-color", "selection-background", "selection-foreground" };
            const codes = [_]u8{ 11, 10, 12, 17, 19 };
            for (keys, codes) |k, code| {
                if (std.mem.eql(u8, key, k)) {
                    try out.writer.print("\x1b]{d};{s}\x1b\\", .{ code, color });
                    break;
                }
            }
        }
    }
    try out.writer.print("ghostty-theme: applied '{s}'\n", .{name});
    return out.toOwnedSlice();
}

fn select(c: Context, themes: []Theme) !struct { rc: u8, name: ?[]const u8 } {
    // Private directory and regular stdin/stdout files avoid pipe deadlocks and
    // keep the map alive for every preview until fzf exits.
    var random: [16]u8 = undefined;
    try c.io.randomSecure(&random);
    const tmp_root = try std.fs.path.resolve(c.a, &.{ try std.process.currentPathAlloc(c.io, c.a), c.env.get("TMPDIR") orelse "/tmp" });
    const tmp = try c.fmt("{s}/ghostty-theme-{s}", .{ tmp_root, std.fmt.bytesToHex(random, .lower) });
    const cwd = Io.Dir.cwd();
    try cwd.createDir(c.io, tmp, .fromMode(0o700));
    defer cwd.deleteTree(c.io, tmp) catch |err| {
        c.diagnostic("ghostty-theme: temporary directory cleanup failed: {s}\n", .{@errorName(err)}) catch {};
    };
    var dir = try cwd.openDir(c.io, tmp, .{});
    defer dir.close(c.io);
    var names: Io.Writer.Allocating = .init(c.a);
    var map: Io.Writer.Allocating = .init(c.a);
    for (themes) |theme| {
        try names.writer.print("{s}\n", .{theme.name});
        try map.writer.print("{s}\t{s}\n", .{ theme.name, theme.path });
    }
    try dir.writeFile(c.io, .{ .sub_path = "names", .data = names.written() });
    try dir.writeFile(c.io, .{ .sub_path = "map", .data = map.written() });
    const input = try dir.openFile(c.io, "names", .{});
    defer input.close(c.io);
    const output = try dir.createFile(c.io, "output", .{});
    defer output.close(c.io);
    const errors = try dir.createFile(c.io, "errors", .{});
    defer errors.close(c.io);
    const preview = c.env.get("GHOSTTY_THEME_PREVIEW") orelse blk: {
        const exe_dir = try std.process.executableDirPathAlloc(c.io, c.a);
        const sibling = try std.fs.path.join(c.a, &.{ exe_dir, "ghostty-theme-preview" });
        const f = cwd.openFile(c.io, sibling, .{}) catch break :blk "ghostty-theme-preview";
        f.close(c.io);
        break :blk sibling;
    };
    const bash = c.env.get("BASH5_BIN") orelse "bash";
    const probe = try c.run(&.{ bash, "-c", "(( BASH_VERSINFO[0] >= 5 ))" });
    if (status(probe.term) != 0) {
        try c.diagnostic("ghostty-theme: preview requires Bash 5+\n", .{});
        return .{ .rc = 2, .name = null };
    }
    const expr = try c.fmt("{s} -- {s} --map {s} {{}}", .{ try quote(c, bash), try quote(c, preview), try quote(c, try std.fs.path.resolve(c.a, &.{ tmp, "map" })) });
    var child = std.process.spawn(c.io, .{
        .argv = &.{ "fzf", "--layout=reverse", "--preview", expr, "--preview-window", "right:50%" },
        .stdin = .{ .file = input },
        .stdout = .{ .file = output },
        .stderr = .{ .file = errors },
    }) catch |err| {
        try c.diagnostic("ghostty-theme: could not run 'fzf': {s}\n", .{@errorName(err)});
        return if (err == error.FileNotFound) error.MissingCli else err;
    };
    defer child.kill(c.io);
    const rc = status(try child.wait(c.io));
    if (rc == 1 or rc == 130) return .{ .rc = 0, .name = null };
    if (rc != 0) {
        const detail = try dir.readFileAlloc(c.io, "errors", c.a, .limited(1024 * 1024));
        try c.diagnostic("{s}ghostty-theme: fzf exited with status {d}\n", .{ detail, rc });
        return .{ .rc = rc, .name = null };
    }
    const selection = try dir.readFileAlloc(c.io, "output", c.a, .limited(1024 * 1024));
    return .{ .rc = 0, .name = std.mem.trimEnd(u8, selection, "\n") };
}

fn execute(c: Context, args: []const [:0]const u8) !u8 {
    if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try Io.File.stdout().writeStreamingAll(c.io, "Usage: ghostty-theme [theme-name]\n\nApply a theme via OSC; omit theme-name for fzf with live preview.\nEnvironment: GHOSTTY_THEME_PREVIEW, BASH5_BIN, TMPDIR;\nGHOSTTY_RESOURCES_DIR is honored by Ghostty.\n");
        return 0;
    }
    const listing = try c.run(&.{ "ghostty", "+list-themes", "--plain", "--path" });
    if (status(listing.term) != 0) {
        try c.diagnostic("{s}ghostty-theme: \"ghostty +list-themes\" failed (exit {d})\n", .{ listing.stderr, status(listing.term) });
        return status(listing.term);
    }
    const themes = try discover(c, listing.stdout);
    if (themes.len == 0) {
        try c.diagnostic("ghostty-theme: no themes reported by \"ghostty +list-themes\".\n", .{});
        return 1;
    }
    const name = if (args.len > 1 and args[1].len != 0) args[1] else blk: {
        const picked = try select(c, themes);
        break :blk picked.name orelse return picked.rc;
    };
    var path: ?[]const u8 = null;
    for (themes) |theme| {
        if (std.mem.eql(u8, theme.name, name)) {
            path = theme.path;
            break;
        }
    }
    const resolved = path orelse {
        try c.diagnostic("ghostty-theme: theme '{s}' not found.\n", .{name});
        return 1;
    };
    const file = Io.Dir.cwd().openFile(c.io, resolved, .{}) catch |err| {
        try c.diagnostic("ghostty-theme: resolved path for '{s}' is not readable: {s} ({s})\n", .{ name, resolved, @errorName(err) });
        return 1;
    };
    defer file.close(c.io);
    if ((try file.stat(c.io)).kind != .file) return error.NotRegularFile;
    const validated = try c.run(&.{ "ghostty", "+validate-config", try c.fmt("--config-file={s}", .{resolved}) });
    if (status(validated.term) != 0) {
        try c.diagnostic("ghostty-theme: theme '{s}' failed validation (exit {d}):\n{s}{s}", .{ name, status(validated.term), validated.stdout, validated.stderr });
        return status(validated.term);
    }
    const content = try Io.Dir.cwd().readFileAlloc(c.io, resolved, c.a, .limited(16 * 1024 * 1024));
    try Io.File.stdout().writeStreamingAll(c.io, try render(c, content, name));
    return 0;
}

pub fn main(init: std.process.Init) void {
    const c: Context = .{ .a = init.arena.allocator(), .io = init.io, .env = init.environ_map };
    const args = init.minimal.args.toSlice(c.a) catch std.process.exit(1);
    const rc = execute(c, args) catch |err| blk: {
        c.diagnostic("ghostty-theme: {s}\n", .{@errorName(err)}) catch {};
        break :blk @as(u8, if (err == error.MissingCli) 127 else 1);
    };
    std.process.exit(rc);
}
