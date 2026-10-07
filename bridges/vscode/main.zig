//! The `mcp-bridge-vscode` executable. Visual Studio Code (VS Code) starts it as a stdio
//! server. The bridge then starts the upstream server and translates between the two protocol
//! revisions.
const std = @import("std");
const Io = std.Io;
const vscode = @import("vscode");

const usage =
    \\Usage: mcp-bridge-vscode [options] -- <command> [args...]
    \\
    \\Connects VS Code (MCP revision 2025-11-25) to an MCP server of revision 2026-07-28.
    \\
    \\Options:
    \\  --help      Show this text.
    \\  --version   Show the version.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try out.print("{s} {s}\n", .{ vscode.profile.name, vscode.bridge.version });
        try out.flush();
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try out.writeAll(usage);
        try out.flush();
        return 0;
    }
    // The runtime of the bridge arrives with milestone M1. Until then the executable only
    // tells its version and its usage, and stdout stays empty.
    std.debug.print("{s}: this version cannot connect to a server yet\n\n{s}", .{ vscode.profile.name, usage });
    return 2;
}
