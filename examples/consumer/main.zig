//! A consumer of zig-bridge-sdk through `b.dependency("bridge_sdk", ...)`. It imports the
//! `vscode` module and the `mcp` module from the package. `--check` writes the name of the
//! bridge and exits with 0 when the name is correct.
//!
//! This is the stub of milestone M0. In milestone M5, the consumer also serves its server
//! through `vscode.serveStdio`.
const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp");
const vscode = @import("vscode");

// A consumer that pins zig-sdk itself can get a different `mcp` module. Its `mcp.Server` is then
// not the `mcp.Server` of the bridge. This stops the build in that case.
comptime {
    if (vscode.mcp != mcp) @compileError("the mcp module of the consumer is not the mcp module of the bridge");
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2 or !std.mem.eql(u8, args[1], "--check")) {
        std.debug.print("usage: consumer --check\n", .{});
        return 2;
    }

    // A server of the consumer is a server of the bridge: the pointer types are the same.
    var server = try mcp.Server.init(init.gpa, io, .{ .info = .{ .name = "consumer", .version = "0.0.1" } });
    defer server.deinit();
    const bridge_server: *vscode.mcp.Server = &server;
    _ = bridge_server;

    var buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    try out.print("{s}\n", .{vscode.profile.name});
    try out.flush();
    return if (std.mem.eql(u8, vscode.profile.name, "mcp-bridge-vscode")) 0 else 1;
}
