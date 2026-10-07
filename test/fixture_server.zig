//! The upstream server of the tests. It is a zig-sdk server of revision 2026-07-28 over stdio.
//! `test/fixture.zig` has its tools, its prompt and its completion handler. Each milestone adds
//! the tools that its tests need.
//!
//! Usage: `bridge-fixture-server [--many-tools N] [--close-stdout]`. With `--many-tools N`, the
//! server also has the generated tools `tool_0` to `tool_<N-1>`. The tool `crash` stops the
//! process with the exit code 3. The tool `shutdown` ends the listen streams as at the end of
//! the input, and then stops the process with the exit code 0.
//!
//! With `--close-stdout`, the process is a server that does not operate correctly. It closes
//! its stdout at once, and then it waits for `close_stdout_wait_s` seconds without a read. Thus
//! a test can examine that the bridge stops a child process that continues to run.
//!
//! Each log line of the server starts with `bridge-fixture-server: `. The server writes to the
//! stderr of the bridge, thus a test can tell the lines of the two processes apart.
const std = @import("std");
const mcp = @import("mcp");
const fixture = @import("fixture");

pub const std_options: std.Options = .{ .logFn = logFn };

/// The start of each log line.
const tag = "bridge-fixture-server: ";

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

const usage =
    \\Usage: bridge-fixture-server [--many-tools N] [--close-stdout]
    \\
;

/// The time that the process waits after `--close-stdout` closed its stdout. A test fails
/// earlier when the bridge does not stop the process.
const close_stdout_wait_s = 120;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: fixture.Options = .{ .crash = true };
    var close_stdout = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--many-tools") and i + 1 < args.len) {
            i += 1;
            options.many_tools = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("bridge-fixture-server: --many-tools needs a number, not '{s}'\n{s}", .{ args[i], usage });
                return 2;
            };
        } else if (std.mem.eql(u8, args[i], "--close-stdout")) {
            close_stdout = true;
        } else {
            std.debug.print("bridge-fixture-server: unknown argument '{s}'\n{s}", .{ args[i], usage });
            return 2;
        }
    }
    if (close_stdout) {
        std.Io.File.stdout().close(io);
        io.sleep(.fromSeconds(close_stdout_wait_s), .awake) catch {};
        return 0;
    }
    const server = try fixture.build(gpa, io, options);
    defer fixture.destroy(server);
    try mcp.transport.stdio.serve(io, gpa, server);
    return 0;
}
