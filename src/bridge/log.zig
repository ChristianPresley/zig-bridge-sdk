//! The log function of the bridge executables. VS Code shows the stderr lines of a stdio
//! server in its Output channel, together with the stderr lines of the upstream child process.
//! Thus each line of the bridge starts with a fixed tag:
//!
//! ```
//! mcp-bridge-vscode: bridge: info: the upstream server is ready
//! ```
//!
//! The line has the tag, the scope, the level and the message. The function formats the line
//! in one buffer and writes it to stderr with one write under the stderr lock. Thus the lines
//! of concurrent tasks do not mix. A control character in the message becomes a space, so
//! that one call always gives one line.
//!
//! The executable sets `std_options` like this. Then the compiler keeps all levels, and the
//! level at run time filters the lines:
//!
//! ```
//! pub const std_options: std.Options = .{
//!     .log_level = .debug,
//!     .logFn = bridge.log.tagged(vscode.profile.name),
//! };
//! ```
//!
//! The same function also writes the lines of the zig-sdk scopes (`mcp_client`, `mcp_stdio`
//! and the other scopes). Do not log argument values, header values or tokens.
const std = @import("std");
const Level = std.log.Level;

/// The type of `std.Options.logFn`.
pub const LogFn = @FieldType(std.Options, "logFn");

/// The level at start. `setLevel` changes it.
pub const default_level: Level = .info;

/// The maximum length of one line, with the newline. A longer message gets the end marker
/// `truncation_marker`.
pub const max_line_bytes = 4096;

/// The text at the end of a message that is too long for one line.
pub const truncation_marker = " [truncated]";

/// The level at run time. The atomic value holds the integer of a `Level`, because
/// `std.atomic.Value` cannot hold an enum without an explicit tag type.
var current_level: std.atomic.Value(u8) = .init(@intFromEnum(default_level));

/// Sets the level at run time. A line with a less important level does not go to stderr.
pub fn setLevel(new_level: Level) void {
    current_level.store(@intFromEnum(new_level), .monotonic);
}

/// Returns the level at run time.
pub fn currentLevel() Level {
    return @enumFromInt(current_level.load(.monotonic));
}

/// Returns true when a line of level `message_level` goes to stderr.
pub fn isEnabled(message_level: Level) bool {
    return @intFromEnum(message_level) <= current_level.load(.monotonic);
}

/// Returns the level of the text `err`, `warn`, `info` or `debug`, or null for a different
/// text.
pub fn parseLevel(text: []const u8) ?Level {
    return std.meta.stringToEnum(Level, text);
}

/// Returns a log function for `std.Options.logFn`. Each line starts with `tag`, the scope and
/// the level. The function writes nothing when the level is less important than the level at
/// run time.
pub fn tagged(comptime tag: []const u8) LogFn {
    return struct {
        fn logFn(
            comptime message_level: Level,
            comptime scope: @EnumLiteral(),
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (!isEnabled(message_level)) return;
            var buf: [max_line_bytes]u8 = undefined;
            writeLine(formatLine(&buf, tag, message_level, scope, format, args));
        }
    }.logFn;
}

/// Writes `line` to stderr with one write under the stderr lock. The cancel protection of the
/// task stays on during the write, as in `std.log.defaultLog`. Errors of the write have no
/// effect.
fn writeLine(line: []const u8) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    // An empty buffer: the writer sends `line` to the file in one write.
    const stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.writeAll(line) catch {};
}

/// Formats one log line into `buf` and returns it. The line is
/// `<tag>: <scope>: <level>: <message>` and a newline. A control character of the message
/// becomes a space. When the message is too long, the line ends with `truncation_marker`.
/// The line does not end in the middle of a UTF-8 sequence.
pub fn formatLine(
    buf: []u8,
    comptime tag: []const u8,
    comptime message_level: Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    const prefix = tag ++ ": " ++ @tagName(scope) ++ ": " ++ comptime message_level.asText() ++ ": ";
    std.debug.assert(buf.len >= prefix.len + truncation_marker.len + 1);
    // The last byte of `buf` is for the newline.
    const body = buf[0 .. buf.len - 1];
    @memcpy(body[0..prefix.len], prefix);
    var w: std.Io.Writer = .fixed(body[prefix.len..]);
    var len = prefix.len;
    if (w.print(format, args)) |_| {
        len += w.end;
    } else |_| {
        // The fixed writer is full. Cut the message at the start of a UTF-8 sequence, and put
        // the marker in the free space.
        var cut = body.len - truncation_marker.len;
        while (cut > prefix.len and isContinuationByte(body[cut])) cut -= 1;
        @memcpy(body[cut..][0..truncation_marker.len], truncation_marker);
        len = cut + truncation_marker.len;
    }
    for (body[prefix.len..len]) |*c| {
        if ((c.* < 0x20 and c.* != '\t') or c.* == 0x7f) c.* = ' ';
    }
    buf[len] = '\n';
    return buf[0 .. len + 1];
}

fn isContinuationByte(c: u8) bool {
    return c & 0xc0 == 0x80;
}

test "the line has the tag, the scope, the level and one newline" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = formatLine(&buf, "mcp-bridge-vscode", .info, .bridge, "ready after {d} ms", .{12});
    try std.testing.expectEqualStrings("mcp-bridge-vscode: bridge: info: ready after 12 ms\n", line);

    const warn_line = formatLine(&buf, "t", .warn, .mcp_stdio, "x", .{});
    try std.testing.expectEqualStrings("t: mcp_stdio: warning: x\n", warn_line);

    const default_line = formatLine(&buf, "t", .err, .default, "y", .{});
    try std.testing.expectEqualStrings("t: default: error: y\n", default_line);
}

test "a control character in the message becomes a space" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = formatLine(&buf, "t", .debug, .vscode, "a{s}b", .{"\n\r\x1b[31m\x00\x7f\tc"});
    try std.testing.expectEqualStrings("t: vscode: debug: a   [31m  \tcb\n", line);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

test "a long message gets the end marker and stays in the buffer" {
    var buf: [64]u8 = undefined;
    const long = "x" ** 100;
    const line = formatLine(&buf, "t", .info, .bridge, "{s}", .{long});
    try std.testing.expectEqual(buf.len, line.len);
    try std.testing.expect(std.mem.startsWith(u8, line, "t: bridge: info: xxx"));
    try std.testing.expect(std.mem.endsWith(u8, line, truncation_marker ++ "\n"));
}

test "a message that fills the buffer exactly has no end marker" {
    var buf: [32]u8 = undefined;
    const prefix = "t: bridge: info: ";
    const fill = "y" ** (buf.len - 1 - prefix.len);
    const line = formatLine(&buf, "t", .info, .bridge, "{s}", .{fill});
    try std.testing.expectEqualStrings(prefix ++ fill ++ "\n", line);
}

test "the end marker does not cut a UTF-8 sequence" {
    var buf: [48]u8 = undefined;
    // Each "é" has two bytes. The cut point is in the middle of a sequence for one of the two
    // parities, so test both.
    for ([_][]const u8{ "", "a" }) |pad| {
        const line = formatLine(&buf, "t", .info, .bridge, "{s}{s}", .{ pad, "é" ** 40 });
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(std.mem.endsWith(u8, line, truncation_marker ++ "\n"));
        try std.testing.expect(line.len <= buf.len);
    }
}

test "the level at run time filters the lines" {
    const saved = currentLevel();
    defer setLevel(saved);

    setLevel(.warn);
    try std.testing.expectEqual(Level.warn, currentLevel());
    try std.testing.expect(isEnabled(.err));
    try std.testing.expect(isEnabled(.warn));
    try std.testing.expect(!isEnabled(.info));
    try std.testing.expect(!isEnabled(.debug));

    setLevel(.debug);
    try std.testing.expect(isEnabled(.debug));

    setLevel(.err);
    try std.testing.expect(!isEnabled(.warn));
}

test "parseLevel accepts the four level names only" {
    try std.testing.expectEqual(Level.err, parseLevel("err").?);
    try std.testing.expectEqual(Level.warn, parseLevel("warn").?);
    try std.testing.expectEqual(Level.info, parseLevel("info").?);
    try std.testing.expectEqual(Level.debug, parseLevel("debug").?);
    try std.testing.expectEqual(@as(?Level, null), parseLevel("error"));
    try std.testing.expectEqual(@as(?Level, null), parseLevel("INFO"));
    try std.testing.expectEqual(@as(?Level, null), parseLevel(""));
}

test "tagged gives a function of the type of std.Options.logFn" {
    const f: LogFn = tagged("mcp-bridge-test");
    _ = f;
}
