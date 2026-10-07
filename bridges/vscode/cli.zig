//! The command line of `mcp-bridge-vscode`. The options come first. The argument `--` comes
//! next, and then the upstream command and its arguments:
//!
//! ```
//! mcp-bridge-vscode [options] -- <command> [args...]
//! ```
//!
//! An option takes its value from the next argument (`--name x`) or after an equals sign
//! (`--name=x`). When an option occurs two times, the last value applies. The parser examines
//! no argument after `--`, thus the options of the upstream command go to the upstream
//! command without a change.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bridge = @import("bridge");
const vscode = @import("vscode");

/// The default of `--discover-timeout`, in seconds.
pub const default_discover_timeout_s: u32 = bridge.Frontend.default_discover_timeout_s;
/// The default of `--max-line-bytes`: 64 MiB. VS Code reads lines of all lengths.
pub const default_max_line_bytes: usize = bridge.Upstream.default_max_line_bytes;
/// The largest value of `--max-line-bytes`: 1 GiB. The line reader of zig-sdk adds one to the
/// limit, thus the limit cannot be the maximum of `usize`.
pub const max_line_bytes_limit: usize = 1 << 30;

/// The text of `--help`. The usage also goes to stderr after an error in the arguments.
pub const usage = std.fmt.comptimePrint(
    \\Usage: mcp-bridge-vscode [options] -- <command> [args...]
    \\
    \\Connects VS Code (MCP revision 2025-11-25) to an MCP server of revision 2026-07-28.
    \\The bridge starts <command> as the upstream server and translates the messages.
    \\
    \\Options:
    \\  --name <name>           The server name for VS Code when the upstream server sends
    \\                          no name. The default is the file name of <command> without
    \\                          its extension.
    \\  --log-level <level>     The level of the log lines on stderr: err, warn, info or
    \\                          debug. The default is info.
    \\  --discover-timeout <s>  The time in seconds for the first response of the upstream
    \\                          server. The default is {d}.
    \\  --max-line-bytes <n>    The maximum length of one message in bytes, from 1 to {d}.
    \\                          The default is {d} (64 MiB).
    \\  --help                  Show this text.
    \\  --version               Show the version.
    \\
, .{ default_discover_timeout_s, max_line_bytes_limit, default_max_line_bytes });

/// What the executable does with the arguments.
pub const Action = enum {
    /// Start the upstream command and serve VS Code.
    serve,
    /// Show the usage on stdout.
    help,
    /// Show the version on stdout.
    version,
};

/// The result of `parse`. For `.help` and `.version`, the other fields have their defaults.
pub const Options = struct {
    action: Action = .serve,
    /// The `serverInfo.name` when the upstream server sends no `serverInfo`. It is never
    /// empty for `.serve`. The default is the file name of the upstream command without its
    /// extension.
    name: []const u8 = "",
    /// The level of the log lines at run time.
    log_level: std.log.Level = bridge.log.default_level,
    /// The time limit of `server/discover`.
    discover_timeout: Io.Duration = .fromSeconds(default_discover_timeout_s),
    /// The maximum length of one line of JSON-RPC, on the side of VS Code and on the
    /// upstream side.
    max_line_bytes: usize = default_max_line_bytes,
    /// The upstream command and its arguments. For `.serve` the list has at least one item,
    /// and the first item is not empty.
    command: []const []const u8 = &.{},
};

/// The errors of `parse`. The executable exits with code 2 for each of them.
pub const Error = error{
    /// There is no `--`, or no command after `--`, or the command is an empty string.
    MissingCommand,
    /// An argument before `--` is not an option.
    UnexpectedArgument,
    /// The parser does not know the option.
    UnknownOption,
    /// The option has no value.
    MissingValue,
    /// The value of the option is not valid, or the option takes no value.
    InvalidValue,
    OutOfMemory,
};

/// The data of a parse error. It holds the name of an option, but never a value from the
/// command line, because a value can hold a secret.
pub const Diagnostic = struct {
    /// The option with the error, without its value. Empty when the error has no option.
    option: []const u8 = "",
    /// What a valid value is. Empty when the error has no value.
    hint: []const u8 = "",

    /// Writes one line of text about `err` to `w`, without a newline.
    pub fn write(d: Diagnostic, err: Error, w: *Io.Writer) Io.Writer.Error!void {
        switch (err) {
            error.MissingCommand => try w.writeAll("the upstream command is missing: put it after \"--\""),
            error.UnexpectedArgument => try w.writeAll("an argument is not an option: put the upstream command after \"--\""),
            error.UnknownOption => try w.print("the option {s} is not known", .{d.option}),
            error.MissingValue => try w.print("the option {s} needs a value", .{d.option}),
            error.InvalidValue => try w.print("the value of {s} is not valid: {s}", .{ d.option, d.hint }),
            error.OutOfMemory => try w.writeAll("not enough memory"),
        }
    }
};

const Option = enum { name, @"log-level", @"discover-timeout", @"max-line-bytes", help, version };

/// Parses the arguments of the executable. `args` does not contain the name of the program.
/// The slices of the result point into `args`. `arena` holds the list of the upstream command.
pub fn parse(arena: Allocator, args: []const []const u8) Error!Options {
    var diag: Diagnostic = .{};
    return parseDiagnostic(arena, args, &diag);
}

/// Same as `parse`. On an error, `diag` tells the option and a valid value.
pub fn parseDiagnostic(arena: Allocator, args: []const []const u8, diag: *Diagnostic) Error!Options {
    diag.* = .{};
    var options: Options = .{};
    var name: ?[]const u8 = null;
    var i: usize = 0;
    const command: []const []const u8 = while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break args[i + 1 ..];
        if (arg.len < 2 or arg[0] != '-') return error.UnexpectedArgument;

        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const key = if (eq) |e| arg[0..e] else arg;
        const inline_value: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
        diag.option = key;
        const known: ?Option = if (std.mem.startsWith(u8, key, "--")) std.meta.stringToEnum(Option, key[2..]) else null;
        const option = known orelse return error.UnknownOption;

        switch (option) {
            .help, .version => {
                if (inline_value != null) {
                    diag.hint = "the option takes no value";
                    return error.InvalidValue;
                }
                return .{ .action = if (option == .help) .help else .version };
            },
            else => {},
        }

        const value = inline_value orelse value: {
            // A separate value cannot start with "--". Thus `--name -- cmd` is an error and
            // not the name "--".
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) return error.MissingValue;
            i += 1;
            break :value args[i];
        };
        switch (option) {
            .help, .version => unreachable,
            .name => {
                if (value.len == 0) {
                    diag.hint = "the name cannot be empty";
                    return error.InvalidValue;
                }
                name = value;
            },
            .@"log-level" => {
                options.log_level = bridge.log.parseLevel(value) orelse {
                    diag.hint = "use err, warn, info or debug";
                    return error.InvalidValue;
                };
            },
            .@"discover-timeout" => {
                const seconds = parseNumber(u32, value, 1, std.math.maxInt(u32)) orelse {
                    diag.hint = std.fmt.comptimePrint("use a number of seconds from 1 to {d}", .{std.math.maxInt(u32)});
                    return error.InvalidValue;
                };
                options.discover_timeout = .fromSeconds(seconds);
            },
            .@"max-line-bytes" => {
                options.max_line_bytes = parseNumber(usize, value, 1, max_line_bytes_limit) orelse {
                    diag.hint = std.fmt.comptimePrint("use a number of bytes from 1 to {d}", .{max_line_bytes_limit});
                    return error.InvalidValue;
                };
            },
        }
    } else {
        diag.* = .{};
        return error.MissingCommand;
    };

    diag.* = .{};
    if (command.len == 0 or command[0].len == 0) return error.MissingCommand;
    options.command = try arena.dupe([]const u8, command);
    options.name = name orelse vscode.defaultName(command[0]);
    return options;
}

/// Parses a decimal number from `min` to `max`. Only the digits 0 to 9 are valid: no sign,
/// no space and no underscore. Returns null for a different text.
fn parseNumber(comptime T: type, text: []const u8, min: T, max: T) ?T {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseUnsigned(T, text, 10) catch return null;
    if (n < min or n > max) return null;
    return n;
}

const testing = std.testing;

fn testParse(args: []const []const u8) Error!Options {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The tests examine only the scalar fields and the slices of `args`. The list of the
    // command is in the arena, thus `expectCommand` parses again with its own arena.
    var options = try parse(arena.allocator(), args);
    options.command = &.{};
    return options;
}

fn expectCommand(expected: []const []const u8, args: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options = try parse(arena.allocator(), args);
    try testing.expectEqual(expected.len, options.command.len);
    for (expected, options.command) |e, a| try testing.expectEqualStrings(e, a);
}

fn expectError(expected: Error, option: []const u8, args: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(expected, parseDiagnostic(arena.allocator(), args, &diag));
    try testing.expectEqualStrings(option, diag.option);
}

test "the defaults" {
    const options = try testParse(&.{ "--", "server" });
    try testing.expectEqual(Action.serve, options.action);
    try testing.expectEqualStrings("server", options.name);
    try testing.expectEqual(std.log.Level.info, options.log_level);
    try testing.expectEqual(@as(i64, 60), options.discover_timeout.toSeconds());
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), options.max_line_bytes);
    try expectCommand(&.{"server"}, &.{ "--", "server" });
}

test "the options and the upstream command" {
    const args: []const []const u8 = &.{
        "--name",             "files",
        "--log-level",        "debug",
        "--discover-timeout", "120",
        "--max-line-bytes",   "4096",
        "--",                 "node",
        "server.js",          "--stdio",
    };
    const options = try testParse(args);
    try testing.expectEqual(Action.serve, options.action);
    try testing.expectEqualStrings("files", options.name);
    try testing.expectEqual(std.log.Level.debug, options.log_level);
    try testing.expectEqual(@as(i64, 120), options.discover_timeout.toSeconds());
    try testing.expectEqual(@as(usize, 4096), options.max_line_bytes);
    try expectCommand(&.{ "node", "server.js", "--stdio" }, args);
}

test "the value after an equals sign" {
    const options = try testParse(&.{ "--name=a=b", "--log-level=warn", "--discover-timeout=5", "--max-line-bytes=1", "--", "x" });
    try testing.expectEqualStrings("a=b", options.name);
    try testing.expectEqual(std.log.Level.warn, options.log_level);
    try testing.expectEqual(@as(i64, 5), options.discover_timeout.toSeconds());
    try testing.expectEqual(@as(usize, 1), options.max_line_bytes);
}

test "the last value of an option applies" {
    const options = try testParse(&.{ "--log-level", "err", "--log-level", "warn", "--", "x" });
    try testing.expectEqual(std.log.Level.warn, options.log_level);
}

test "the arguments after -- go to the upstream command" {
    try expectCommand(&.{ "server", "--help", "--name", "--" }, &.{ "--", "server", "--help", "--name", "--" });
    const options = try testParse(&.{ "--", "server", "--version" });
    try testing.expectEqual(Action.serve, options.action);
}

test "help and version" {
    try testing.expectEqual(Action.help, (try testParse(&.{"--help"})).action);
    try testing.expectEqual(Action.version, (try testParse(&.{"--version"})).action);
    // The first of the two options applies, and no command is necessary.
    try testing.expectEqual(Action.help, (try testParse(&.{ "--log-level", "debug", "--help", "--version" })).action);
    try expectError(error.InvalidValue, "--help", &.{"--help=yes"});
    try expectError(error.InvalidValue, "--version", &.{"--version="});
}

test "a missing -- or a missing command" {
    try expectError(error.MissingCommand, "", &.{});
    try expectError(error.MissingCommand, "", &.{ "--name", "x" });
    try expectError(error.MissingCommand, "", &.{"--"});
    try expectError(error.MissingCommand, "", &.{ "--", "" });
    try expectError(error.UnexpectedArgument, "", &.{"server"});
    try expectError(error.UnexpectedArgument, "", &.{ "server", "--", "x" });
    try expectError(error.UnexpectedArgument, "", &.{ "-", "--", "x" });
}

test "an unknown option" {
    try expectError(error.UnknownOption, "--verbose", &.{ "--verbose", "--", "x" });
    try expectError(error.UnknownOption, "-h", &.{ "-h", "--", "x" });
    try expectError(error.UnknownOption, "-", &.{ "-=x", "--", "x" });
    // The diagnostic has the name of the option, but not the value.
    try expectError(error.UnknownOption, "--token", &.{ "--token=secret", "--", "x" });
    try expectError(error.UnknownOption, "--", &.{ "--=x", "--", "x" });
    try expectError(error.UnknownOption, "---name", &.{ "---name", "x", "--", "x" });
}

test "a missing value" {
    try expectError(error.MissingValue, "--name", &.{"--name"});
    try expectError(error.MissingValue, "--name", &.{ "--name", "--", "x" });
    try expectError(error.MissingValue, "--log-level", &.{ "--log-level", "--name", "x", "--", "x" });
    try expectError(error.MissingValue, "--max-line-bytes", &.{"--max-line-bytes"});
}

test "a name that is not valid" {
    try expectError(error.InvalidValue, "--name", &.{ "--name=", "--", "x" });
    try expectError(error.InvalidValue, "--name", &.{ "--name", "", "--", "x" });
}

test "a log level that is not valid" {
    try expectError(error.InvalidValue, "--log-level", &.{ "--log-level", "error", "--", "x" });
    try expectError(error.InvalidValue, "--log-level", &.{ "--log-level", "trace", "--", "x" });
    try expectError(error.InvalidValue, "--log-level", &.{ "--log-level", "DEBUG", "--", "x" });
}

test "numbers that are not valid" {
    const bad: []const []const u8 = &.{ "", "0", "-1", "+1", " 1", "1 ", "1_000", "0x10", "1.5", "abc", "4294967296", "99999999999999999999999" };
    for (bad) |text| {
        try expectError(error.InvalidValue, "--discover-timeout", &.{ "--discover-timeout", text, "--", "x" });
    }
    for (bad) |text| {
        try expectError(error.InvalidValue, "--max-line-bytes", &.{ "--max-line-bytes", text, "--", "x" });
    }
    try expectError(error.InvalidValue, "--max-line-bytes", &.{ "--max-line-bytes", "1073741825", "--", "x" });

    const options = try testParse(&.{ "--discover-timeout", "4294967295", "--max-line-bytes", "1073741824", "--", "x" });
    try testing.expectEqual(@as(i64, std.math.maxInt(u32)), options.discover_timeout.toSeconds());
    try testing.expectEqual(max_line_bytes_limit, options.max_line_bytes);
}

test "the default name is the file name of the command without its extension" {
    try testing.expectEqualStrings("server", (try testParse(&.{ "--", "server" })).name);
    try testing.expectEqualStrings("server", (try testParse(&.{ "--", "/opt/mcp/bin/server.exe" })).name);
    try testing.expectEqualStrings("my.server", (try testParse(&.{ "--", "./my.server.py", "arg" })).name);
    try testing.expectEqualStrings("explicit", (try testParse(&.{ "--name", "explicit", "--", "/bin/server" })).name);
}

test "the diagnostic text has the option but no value" {
    var buf: [256]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { args: []const []const u8, text: []const u8 }{
        .{ .args = &.{"server"}, .text = "an argument is not an option: put the upstream command after \"--\"" },
        .{ .args = &.{}, .text = "the upstream command is missing: put it after \"--\"" },
        .{ .args = &.{ "--token=s3cr3t", "--", "x" }, .text = "the option --token is not known" },
        .{ .args = &.{"--name"}, .text = "the option --name needs a value" },
        .{ .args = &.{ "--log-level=s3cr3t", "--", "x" }, .text = "the value of --log-level is not valid: use err, warn, info or debug" },
        .{ .args = &.{ "--max-line-bytes", "0", "--", "x" }, .text = "the value of --max-line-bytes is not valid: use a number of bytes from 1 to 1073741824" },
    };
    for (cases) |case| {
        var diag: Diagnostic = .{};
        const err = if (parseDiagnostic(arena.allocator(), case.args, &diag)) |_| return error.TestExpectedError else |e| e;
        var w: Io.Writer = .fixed(&buf);
        try diag.write(err, &w);
        try testing.expectEqualStrings(case.text, w.buffered());
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "s3cr3t") == null);
    }
}

test "the usage has the defaults" {
    try testing.expect(std.mem.indexOf(u8, usage, "The default is 60.") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "The default is 67108864 (64 MiB).") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "-- <command> [args...]") != null);
}
