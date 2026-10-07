//! The bridge for Visual Studio Code (VS Code). VS Code speaks MCP revision 2025-11-25. This
//! bridge lets it use a server of revision 2026-07-28.
//!
//! Visual Studio Code and VS Code are trademarks of Microsoft Corporation. This project has no
//! affiliation with Microsoft, and Microsoft does not endorse it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The zig-sdk module of this package. An embedder takes `mcp` from here, so that it uses the
/// same types as the bridge.
pub const mcp = @import("mcp");
/// The core of the bridges.
pub const bridge = @import("bridge");

/// The settings of the VS Code bridge.
pub const profile: bridge.Profile = .{
    .name = "mcp-bridge-vscode",
    .meta_passthrough = .{
        .keys = &.{ "traceparent", "tracestate" },
        .prefixes = &.{"vscode."},
    },
    .quirks = .{
        // The Copilot extension stops each request when an array schema has no `items`.
        .normalize_array_items = true,
        // VS Code does not read the output schema. The TypeScript SDK 1.x refuses a
        // `tools/list` result with an output schema that is not an object schema.
        .drop_non_object_output_schema = true,
        // VS Code reads the results of revision 2026-07-28. The MCP Apps need them unchanged.
        .strict_legacy_results = false,
    },
};

/// The settings of `serve`.
pub const ServeOptions = struct {
    /// The upstream command and its arguments. The list has at least one item.
    command: []const []const u8,
    /// The `serverInfo.name` when the upstream server sends none. Empty uses `defaultName` of
    /// the command. VS Code makes the ids of the tools from this name. Thus each upstream
    /// server gets its own name, and never the fixed name of the bridge.
    name: []const u8 = "",
    /// The time limit of `server/discover`.
    discover_timeout: Io.Duration = .fromSeconds(bridge.Frontend.default_discover_timeout_s),
    /// The maximum length of one line, on the side of VS Code and on the upstream side.
    max_line_bytes: usize = bridge.Upstream.default_max_line_bytes,
    /// The functions of the executable for the end of the input and for the loss of the
    /// upstream server.
    hooks: bridge.Frontend.Hooks = .{},
};

/// The size of the read buffer of stdin.
const stdin_buffer_bytes = 64 << 10;

/// Serve VS Code over the stdin and the stdout of the process until the end of stdin. The
/// first `initialize` of VS Code starts the upstream command. Stdout carries only JSON-RPC
/// messages.
///
/// The function returns `.eof` after the end of stdin and a bounded stop. It returns
/// `.upstream_exited` when the upstream server stopped first. The reader can then wait for
/// the next line, thus an executable exits in `hooks.on_upstream_exit`.
pub fn serve(io: Io, gpa: Allocator, options: ServeOptions) !bridge.Frontend.RunResult {
    const upstream = try bridge.Upstream.init(io, gpa, .{ .stdio = .{
        .argv = options.command,
        .max_line_bytes = options.max_line_bytes,
    } });
    defer upstream.deinit();
    const in_buf = try gpa.alloc(u8, stdin_buffer_bytes);
    defer gpa.free(in_buf);
    var out_buf: [64 << 10]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, in_buf);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    var frontend: bridge.Frontend = .init(io, gpa, upstream, &profile, .writer(&stdout.interface), frontendOptions(options));
    defer frontend.deinit();
    return frontend.run(&stdin.interface);
}

/// The settings of the front end that `serve` makes from `options`. Without a name, the
/// fallback name is `defaultName` of the command.
pub fn frontendOptions(options: ServeOptions) bridge.Frontend.Options {
    return .{
        .max_line_bytes = options.max_line_bytes,
        .discover_timeout = options.discover_timeout,
        .fallback_name = if (options.name.len != 0) options.name else defaultName(options.command[0]),
        .hooks = options.hooks,
    };
}

/// Returns the default server name of the upstream command: the file name of `command`
/// without its extension. The result is not empty when `command` is not empty. For an empty
/// result, the `initialize` result has the name of the profile.
pub fn defaultName(command: []const u8) []const u8 {
    return nameOf(command, std.fs.path.basename(command));
}

/// The file name `base` of `command` without its extension, or `command` when `base` is
/// empty. The tests give the base name with the path rules of Windows, also on Linux.
fn nameOf(command: []const u8, base: []const u8) []const u8 {
    if (base.len == 0) return command;
    // The name of a file such as ".server" has no extension.
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

test "the default name is the file name of the command without its extension" {
    try std.testing.expectEqualStrings("npx", defaultName("npx"));
    try std.testing.expectEqualStrings("node", defaultName("/usr/local/bin/node"));
    try std.testing.expectEqualStrings("server", defaultName("/opt/mcp/bin/server.exe"));
    try std.testing.expectEqualStrings("my.server", defaultName("./my.server.py"));
    try std.testing.expectEqualStrings(".server", defaultName("/srv/.server"));
    try std.testing.expectEqualStrings("server", defaultName("server."));
    try std.testing.expectEqualStrings("server", defaultName("bin/server/"));
    try std.testing.expectEqualStrings("/", defaultName("/"));
    try std.testing.expectEqualStrings("", defaultName(""));
}

test "the default name of a Windows path" {
    // The test uses the path rules of Windows on all platforms.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "C:\\Program Files\\nodejs\\npx.cmd", "npx" },
        .{ "C:/tools/server.EXE", "server" },
        .{ "tools\\server.exe", "server" },
        .{ "\\\\host\\share\\my.server.py", "my.server" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], nameOf(c[0], std.fs.path.basenameWindows(c[0])));
        if (@import("builtin").os.tag == .windows) try std.testing.expectEqualStrings(c[1], defaultName(c[0]));
    }
}

test "serve takes the fallback name from the option, else from the command" {
    const command: []const []const u8 = &.{ "/opt/mcp/bin/files-server.exe", "--stdio" };
    try std.testing.expectEqualStrings("files-server", frontendOptions(.{ .command = command }).fallback_name);
    try std.testing.expectEqualStrings("files", frontendOptions(.{ .command = command, .name = "files" }).fallback_name);
    const options = frontendOptions(.{ .command = command, .max_line_bytes = 4096, .discover_timeout = .fromSeconds(5) });
    try std.testing.expectEqual(@as(usize, 4096), options.max_line_bytes);
    try std.testing.expectEqual(@as(i64, 5), options.discover_timeout.toSeconds());
}

test "the VS Code profile passes the trace keys and the vscode keys" {
    try std.testing.expect(profile.meta_passthrough.allows("traceparent"));
    try std.testing.expect(profile.meta_passthrough.allows("vscode.conversationId"));
    try std.testing.expect(!profile.meta_passthrough.allows("progressToken"));
    try std.testing.expect(profile.quirks.normalize_array_items);
    try std.testing.expect(profile.quirks.drop_non_object_output_schema);
    try std.testing.expect(!profile.quirks.strict_legacy_results);
}
