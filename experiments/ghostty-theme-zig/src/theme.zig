//! Pure (I/O-free) logic shared by the ghostty-theme CLI and its unit tests:
//!
//! * parsing `ghostty +list-themes --plain --path` output into a de-duplicated,
//!   emission-ordered theme index where `user` entries override `resources`;
//! * translating a Ghostty theme file into the OSC escape sequences emitted by
//!   the Bash reference implementation (`dot_local/bin/executable_ghostty-theme`).
//!
//! Byte-level compatibility with the Bash version is the goal, so the matching
//! rules below intentionally mirror its regular expressions instead of
//! implementing the Ghostty configuration language.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Source = enum { resources, user };

pub const Entry = struct {
    name: []const u8,
    source: Source,
    path: []const u8,
};

const resources_marker = " (resources) ";
const user_marker = " (user) ";

/// Parses one `+list-themes --plain --path` line.
///
/// Mirrors the Bash ERE `^(.*)\ \((resources|user)\)\ (.*)$`. POSIX
/// leftmost-longest semantics make the first group as long as possible, so
/// the *last* ` (resources) ` / ` (user) ` marker in the line wins. Lines that
/// do not contain a marker yield `null`.
pub fn parseListLine(line: []const u8) ?Entry {
    const r = std.mem.lastIndexOf(u8, line, resources_marker);
    const u = std.mem.lastIndexOf(u8, line, user_marker);
    var start: usize = undefined;
    var marker_len: usize = undefined;
    var source: Source = undefined;
    if (r != null and (u == null or r.? > u.?)) {
        start = r.?;
        marker_len = resources_marker.len;
        source = .resources;
    } else if (u) |idx| {
        start = idx;
        marker_len = user_marker.len;
        source = .user;
    } else {
        return null;
    }
    return .{
        .name = line[0..start],
        .source = source,
        .path = line[start + marker_len ..],
    };
}

/// Emission-ordered, de-duplicated theme index. Slices borrow from the text
/// passed to `parse`, which must outlive the index.
pub const ThemeIndex = struct {
    /// Unique theme names in first-seen order (the fzf input order).
    names: std.ArrayList([]const u8) = .empty,
    /// name -> resolved path. The path may be empty when Ghostty printed an
    /// empty path; `lookup` treats that as "not found" like the Bash version.
    paths: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn parse(gpa: Allocator, text: []const u8) Allocator.Error!ThemeIndex {
        var index: ThemeIndex = .{};
        errdefer index.deinit(gpa);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const entry = parseListLine(line) orelse continue;
            // The Bash version aborts with "bad array subscript" on an empty
            // name. Such an entry can never be selected, so skip it instead.
            if (entry.name.len == 0) continue;
            const gop = try index.paths.getOrPut(gpa, entry.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = entry.path;
                try index.names.append(gpa, entry.name);
            } else if (entry.source == .user) {
                // Ghostty emits resources first, then user; user overrides.
                gop.value_ptr.* = entry.path;
            }
        }
        return index;
    }

    pub fn deinit(self: *ThemeIndex, gpa: Allocator) void {
        self.names.deinit(gpa);
        self.paths.deinit(gpa);
        self.* = .{};
    }

    /// Returns the resolved path for `name`, or null when the theme is unknown
    /// or its path is empty.
    pub fn lookup(self: *const ThemeIndex, name: []const u8) ?[]const u8 {
        const path = self.paths.get(name) orelse return null;
        if (path.len == 0) return null;
        return path;
    }

    /// Writes the fzf preview map (`name<TAB>path<LF>` per theme) consumed by
    /// `ghostty-theme-preview --map`.
    pub fn writeMap(self: *const ThemeIndex, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.names.items) |name| {
            try w.print("{s}\t{s}\n", .{ name, self.paths.get(name).? });
        }
    }

    /// Writes the fzf candidate list (`name<LF>` per theme).
    pub fn writeNames(self: *const ThemeIndex, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.names.items) |name| {
            try w.print("{s}\n", .{name});
        }
    }
};

/// Theme keys applied via OSC, with their OSC codes. `cursor-text` is
/// intentionally absent: no standard OSC sets the cursor text color.
pub const osc_keys = [_]struct { key: []const u8, code: []const u8 }{
    .{ .key = "background", .code = "11" },
    .{ .key = "foreground", .code = "10" },
    .{ .key = "cursor-color", .code = "12" },
    .{ .key = "selection-background", .code = "17" },
    .{ .key = "selection-foreground", .code = "19" },
};

/// `[[:space:]]` as seen inside a Bash `read` line (a newline never appears
/// inside a line). Only ASCII whitespace is recognized.
fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', 0x0b, 0x0c, '\r' => true,
        else => false,
    };
}

fn skipSpace(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and isSpace(s[i])) : (i += 1) {}
    return i;
}

/// Matches `(#[0-9a-fA-F]{6})[[:space:]]*$` at the start of `s`.
fn matchColorTail(s: []const u8) ?[]const u8 {
    if (s.len < 7 or s[0] != '#') return null;
    for (s[1..7]) |c| if (!std.ascii.isHex(c)) return null;
    for (s[7..]) |c| if (!isSpace(c)) return null;
    return s[0..7];
}

/// Matches `^[[:space:]]*<word>[[:space:]]*=[[:space:]]*` and returns the
/// index just past it.
fn matchAssignPrefix(line: []const u8, word: []const u8) ?usize {
    var i = skipSpace(line, 0);
    if (!std.mem.startsWith(u8, line[i..], word)) return null;
    i = skipSpace(line, i + word.len);
    if (i >= line.len or line[i] != '=') return null;
    return skipSpace(line, i + 1);
}

pub const PaletteEntry = struct { index: []const u8, color: []const u8 };

/// `^ws*palette ws*= ws*([0-9]+) ws*= ws*(#hex{6}) ws*$`
pub fn matchPalette(line: []const u8) ?PaletteEntry {
    var i = matchAssignPrefix(line, "palette") orelse return null;
    const idx_start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == idx_start) return null;
    const index = line[idx_start..i];
    i = skipSpace(line, i);
    if (i >= line.len or line[i] != '=') return null;
    i = skipSpace(line, i + 1);
    const color = matchColorTail(line[i..]) orelse return null;
    return .{ .index = index, .color = color };
}

/// `^ws*<key> ws*= ws*(#hex{6}) ws*$`
pub fn matchKey(line: []const u8, key: []const u8) ?[]const u8 {
    const i = matchAssignPrefix(line, key) orelse return null;
    return matchColorTail(line[i..]);
}

/// Writes the OSC sequences for `content` in file order:
/// palette lines as `ESC ] 4 ; N ; #RRGGBB ESC \` and the five color keys as
/// `ESC ] <code> ; #RRGGBB ESC \`. Lines that do not match exactly (comments,
/// unknown keys, malformed or 5/7-digit colors, trailing garbage) are ignored.
/// A final line without a trailing newline is processed too.
pub fn writeOsc(w: *std.Io.Writer, content: []const u8) std.Io.Writer.Error!void {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (matchPalette(line)) |p| {
            try w.print("\x1b]4;{s};{s}\x1b\\", .{ p.index, p.color });
            continue;
        }
        for (osc_keys) |k| {
            if (matchKey(line, k.key)) |color| {
                try w.print("\x1b]{s};{s}\x1b\\", .{ k.code, color });
                break;
            }
        }
    }
}

/// Equivalent of Bash command substitution's trailing-newline stripping.
pub fn trimTrailingNewlines(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\n");
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn renderAlloc(content: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeOsc(&aw.writer, content);
    return aw.toOwnedSlice();
}

test "parseListLine: basic and name with spaces" {
    const e = parseListLine("Test Spaces (resources) /a b/Test Spaces").?;
    try testing.expectEqualStrings("Test Spaces", e.name);
    try testing.expectEqual(Source.resources, e.source);
    try testing.expectEqualStrings("/a b/Test Spaces", e.path);

    const u = parseListLine("Dark (user) /home/x/.config/ghostty/themes/Dark").?;
    try testing.expectEqual(Source.user, u.source);
    try testing.expectEqualStrings("Dark", u.name);

    try testing.expect(parseListLine("no marker here") == null);
    try testing.expect(parseListLine("Name (resources)") == null);
}

test "parseListLine: last marker wins like the greedy Bash regex" {
    const e = parseListLine("A (user) B (resources) /d/A (user) B").?;
    try testing.expectEqualStrings("A (user) B (resources) /d/A", e.name);
    try testing.expectEqual(Source.user, e.source);
    try testing.expectEqualStrings("B", e.path);

    const empty_path = parseListLine("X (resources) ").?;
    try testing.expectEqualStrings("X", empty_path.name);
    try testing.expectEqualStrings("", empty_path.path);
}

test "ThemeIndex: dedup keeps first order and user overrides resources" {
    const text = "Alpha (resources) /r/Alpha\n" ++
        "Dup (resources) /r/Dup\n" ++
        "garbage line\n" ++
        "\n" ++
        "Beta Gamma (resources) /r/Beta Gamma\n" ++
        "Dup (user) /u/Dup\n" ++
        "Alpha (resources) /r2/Alpha\n" ++
        " (user) /u/empty-name\n" ++
        "Empty (resources) \n";
    var index = try ThemeIndex.parse(testing.allocator, text);
    defer index.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), index.names.items.len);
    try testing.expectEqualStrings("Alpha", index.names.items[0]);
    try testing.expectEqualStrings("Dup", index.names.items[1]);
    try testing.expectEqualStrings("Beta Gamma", index.names.items[2]);
    try testing.expectEqualStrings("Empty", index.names.items[3]);
    try testing.expectEqualStrings("/u/Dup", index.lookup("Dup").?);
    // A later resources entry does not override the first one.
    try testing.expectEqualStrings("/r/Alpha", index.lookup("Alpha").?);
    try testing.expectEqualStrings("/r/Beta Gamma", index.lookup("Beta Gamma").?);
    try testing.expect(index.lookup("Empty") == null);
    try testing.expect(index.lookup("") == null);
    try testing.expect(index.lookup("Missing") == null);
}

test "ThemeIndex: user before resources still wins" {
    var index = try ThemeIndex.parse(testing.allocator, "T (user) /u/T\nT (resources) /r/T\n");
    defer index.deinit(testing.allocator);
    try testing.expectEqualStrings("/u/T", index.lookup("T").?);
    try testing.expectEqual(@as(usize, 1), index.names.items.len);
}

test "ThemeIndex: map and names output" {
    var index = try ThemeIndex.parse(testing.allocator, "A B (resources) /x y/A B\nC (user) /c\n");
    defer index.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try index.writeMap(&aw.writer);
    try testing.expectEqualStrings("A B\t/x y/A B\nC\t/c\n", aw.written());
    aw.clearRetainingCapacity();
    try index.writeNames(&aw.writer);
    try testing.expectEqualStrings("A B\nC\n", aw.written());
}

test "writeOsc: order, keys, palette, cursor-text excluded" {
    const out = try renderAlloc("palette = 0=#1d1f21\n" ++
        "background = #1d1f21\n" ++
        "foreground = #c5c8c6\n" ++
        "cursor-color = #c5c8c6\n" ++
        "cursor-text = #1d1f21\n" ++
        "selection-background = #373b41\n" ++
        "selection-foreground = #c5c8c6\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "\x1b]4;0;#1d1f21\x1b\\\x1b]11;#1d1f21\x1b\\\x1b]10;#c5c8c6\x1b\\" ++
            "\x1b]12;#c5c8c6\x1b\\\x1b]17;#373b41\x1b\\\x1b]19;#c5c8c6\x1b\\",
        out,
    );
}

test "writeOsc: whitespace, CRLF, comments, invalid colors, no final newline" {
    const out = try renderAlloc("# comment\n\n  palette = 1=#AaBbCc\r\n" ++
        "\tpalette\t=\t007\t=\t#0a0B0c\x0b\x0c\n" ++
        "palette = 2=#12345\n" ++
        "palette = 3=#1234567\n" ++
        "palette = x=#123456\n" ++
        "palette = 4 = #123456 extra\n" ++
        "palette=16=#ffffff\n" ++
        "background=#123456\n" ++
        "background-image = #123456\n" ++
        "  # background = #654321\n" ++
        "foreground = #12345g\n" ++
        "cursor-color = 123456\n" ++
        "selection-background = #abcdef # trailing comment\n" ++
        "invalid = not-a-color\n" ++
        "foreground =   #778899");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "\x1b]4;1;#AaBbCc\x1b\\\x1b]4;007;#0a0B0c\x1b\\\x1b]4;16;#ffffff\x1b\\" ++
            "\x1b]11;#123456\x1b\\\x1b]10;#778899\x1b\\",
        out,
    );
}

test "writeOsc: empty input produces nothing" {
    const out = try renderAlloc("");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "writeOsc: repeated keys and large palette indices retain file order and spelling" {
    const out = try renderAlloc(
        "foreground=#ABCDEF\nbackground=#123456\nforeground=#fedcba\n" ++
            "palette=0002=#112233\npalette=999999999999999999999999999999=#445566\n" ++
            "cursor-text=#010203\nbackground=#654321",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "\x1b]10;#ABCDEF\x1b\\\x1b]11;#123456\x1b\\\x1b]10;#fedcba\x1b\\" ++
            "\x1b]4;0002;#112233\x1b\\\x1b]4;999999999999999999999999999999;#445566\x1b\\" ++
            "\x1b]11;#654321\x1b\\",
        out,
    );
}

test "trimTrailingNewlines" {
    try testing.expectEqualStrings("Test Spaces", trimTrailingNewlines("Test Spaces\n\n"));
    try testing.expectEqualStrings("a\nb", trimTrailingNewlines("a\nb\n"));
    try testing.expectEqualStrings("", trimTrailingNewlines("\n"));
}
