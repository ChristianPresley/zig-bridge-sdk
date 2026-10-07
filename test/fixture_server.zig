//! The upstream server of the tests. It is a zig-sdk server of revision 2026-07-28 over stdio.
//! Each milestone adds the tools that its tests need.
const std = @import("std");
const mcp = @import("mcp");

const EchoArgs = struct {
    text: []const u8,
    pub const json_schema = .{
        .description = "The text to send back.",
        .fields = .{ .text = .{ .description = "Any text" } },
    };
};

fn echo(ctx: *mcp.RequestContext, args: EchoArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    try ctx.checkCancel();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{s}", .{args.text}) };
}

const AddArgs = struct {
    a: i64,
    b: i64,
    pub const json_schema = .{
        .description = "Add two integers.",
        .fields = .{ .a = .{ .description = "Left operand" }, .b = .{ .description = "Right operand" } },
    };
};

fn add(ctx: *mcp.RequestContext, args: AddArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    try ctx.checkCancel();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{d}", .{args.a + args.b}) };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var server = try mcp.Server.init(gpa, io, .{
        .info = .{ .name = "bridge-fixture-server", .version = "0.0.0" },
        .instructions = "The upstream server of the zig-bridge-sdk tests.",
    });
    defer server.deinit();
    try server.addTool(.{ .name = "echo", .description = "Send the text back", .annotations = .{ .readOnlyHint = true } }, echo);
    try server.addTool(.{ .name = "add", .description = "Add two integers", .annotations = .{ .readOnlyHint = true } }, add);
    try mcp.transport.stdio.serve(io, gpa, &server);
}
