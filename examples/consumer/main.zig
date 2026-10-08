//! A consumer of zig-bridge-sdk through `b.dependency("bridge_sdk", ...)`. It imports the
//! `vscode` module and the `mcp` module from the package.
//!
//! The program is a zig-sdk server with two tools. It serves them with `vscode.serveStdio` in
//! place of `mcp.transport.stdio.serve`. Thus VS Code and a client of revision 2026-07-28 can
//! use the same executable:
//!
//! - `greet` greets a person.
//! - `ask_name` asks the user for a name in a form, and then greets the person. VS Code gets
//!   the form as an `elicitation/create` request of revision 2025-11-25.
//!
//! Usage: `consumer` serves stdin and stdout until the end of stdin. `consumer --check` writes
//! the name of the bridge and exits with 0 when the name is correct.
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const mcp = @import("mcp");
const vscode = @import("vscode");

// A consumer that pins zig-sdk itself can get a different `mcp` module. Its `mcp.Server` is then
// not the `mcp.Server` of the bridge. This stops the build in that case.
comptime {
    if (vscode.mcp != mcp) @compileError("the mcp module of the consumer is not the mcp module of the bridge");
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--check")) return check(io);
    if (args.len > 1) {
        std.debug.print("usage: consumer [--check]\n", .{});
        return 2;
    }

    var server = try mcp.Server.init(gpa, io, .{
        .info = .{ .name = "consumer", .version = "0.1.0" },
        // The tool `ask_name` asks for a form.
        .mrtr = .{ .elicitation = true },
    });
    defer server.deinit();
    try server.addTool(.{ .name = "greet", .description = "Greet a person" }, greet);
    try server.addToolJson(.{ .name = "ask_name", .description = "Ask for a name in a form, then greet the person" }, askName);
    // The server of the consumer is a server of the bridge: the pointer types are the same.
    try vscode.serveStdio(io, gpa, &server, .{});
    return 0;
}

/// Write the name of the bridge. Returns 0 when the name is correct.
fn check(io: Io) !u8 {
    var buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    try out.print("{s}\n", .{vscode.profile.name});
    try out.flush();
    return if (std.mem.eql(u8, vscode.profile.name, "mcp-bridge-vscode")) 0 else 1;
}

const GreetArgs = struct {
    name: []const u8,
    pub const json_schema = .{
        .description = "Greet a person.",
        .fields = .{ .name = .{ .description = "The name of the person" } },
    };
};

fn greet(ctx: *mcp.RequestContext, args: GreetArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "Hello, {s}.", .{args.name}) };
}

/// Round 1 asks for the name in a form. Round 2 has the answer of the user.
fn askName(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.elicitResponse("name")) |answer| {
        if (answer.action != .accept) return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "No name: {t}.", .{answer.action}) };
        const name = mcp.json.getString(answer.content orelse .null, "name") orelse "nobody";
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "Hello, {s}.", .{name}) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitForm("name", "What is your name?", try mcp.InputRequired.stringSchema(ctx.arena, "name", null, true));
    return .{ .input_required = ir };
}
