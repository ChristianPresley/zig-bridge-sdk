//! The server of the tests with the `vscode` bridge in its own process. It serves the server of
//! `test/fixture.zig` with `vscode.serveStdio`, in place of `mcp.transport.stdio.serve`. Thus
//! it answers VS Code on the legacy path and a client of revision 2026-07-28 on the modern
//! path. The process tests and the interop job of CI start it.
//!
//! Usage: `bridge-embedded-server [--refuse-discover] [--many-tools N]`. With
//! `--refuse-discover`, a `server/discover` before the first other request gets -32601
//! (`Discover.refuse`). With `--many-tools N`, the server also has the generated tools
//! `tool_0` to `tool_<N-1>`, as `bridge-fixture-server` has.
//!
//! The process exits with code 0 at the end of stdin, and with code 2 for an argument that is
//! not valid. Each log line starts with `bridge-embedded-server: `.
const std = @import("std");
const vscode = @import("vscode");
const fixture = @import("fixture");

pub const std_options: std.Options = .{ .log_level = .info, .logFn = logFn };

/// The start of each log line.
const tag = "bridge-embedded-server: ";

/// Writes one log line with the tag in one write under the stderr lock.
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const prefix = tag ++ comptime level.asText() ++ "(" ++ @tagName(scope) ++ "): ";
    const line = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch line: {
        // The message is too long for the buffer. Keep its start.
        buf[buf.len - 1] = '\n';
        break :line &buf;
    };
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    const stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.writeAll(line) catch {};
}

const usage = "Usage: bridge-embedded-server [--refuse-discover] [--many-tools N]\n";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: vscode.StdioOptions = .{};
    var server_options: fixture.Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "--refuse-discover")) {
            options.discover = .refuse;
        } else if (std.mem.eql(u8, arg, "--many-tools") and value != null) {
            i += 1;
            server_options.many_tools = std.fmt.parseInt(u32, value.?, 10) catch {
                std.debug.print(tag ++ "--many-tools needs a number, not '{s}'\n" ++ usage, .{value.?});
                return 2;
            };
        } else {
            std.debug.print(tag ++ "unknown argument '{s}'\n" ++ usage, .{arg});
            return 2;
        }
    }
    // The fixture module and the bridge use the same `mcp` module of the package.
    const server = try fixture.build(gpa, io, server_options);
    defer fixture.destroy(server);
    try vscode.serveStdio(io, gpa, server, options);
    return 0;
}
