//! The tools, the prompt and the completion handler of the upstream server of the tests. The
//! executable `bridge-fixture-server` serves them over stdio. A test can also make the server in
//! its own process with `build` and connect to it through `mcp.transport.memory`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");

/// The name in the `serverInfo` of the server.
pub const server_name = "bridge-fixture-server";

/// The exit code of the process after a call of the tool `crash`.
pub const crash_exit_code: u8 = 3;

/// The input schema of the tool `crash`. Without `after_ms`, the process stops at once and
/// the call gets no response. With `after_ms`, the call gets a result, and the process stops
/// after that time while it has no request.
pub const crash_schema =
    \\{"type":"object","properties":{"after_ms":{"type":"integer","minimum":1,"maximum":60000,"description":"The time in milliseconds from the result to the stop"}},"additionalProperties":false}
;

/// The values of each completion result.
pub const completion_values = [_][]const u8{ "alpha", "beta" };

/// The input schema of the tool `bare_array`. Three properties are arrays that the derived
/// schemas of zig-sdk never have. `values` has no `items`. `pair` has `prefixItems` and
/// `items: false`. `choice` has an array without `items` in `anyOf`.
pub const bare_array_schema =
    \\{"type":"object","properties":{"values":{"type":"array","description":"Any values"},"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":false},"choice":{"anyOf":[{"type":"array"},{"type":"string"}]}},"required":["values"],"additionalProperties":false}
;

/// The output schema of the tool `structured`.
pub const structured_output_schema =
    \\{"type":"object","properties":{"text":{"type":"string"},"length":{"type":"integer"}},"required":["text","length"]}
;

/// The output schema of the tool `array_output`: an array of integers. Revision 2026-07-28
/// allows an output schema that is not an object schema. Revision 2025-11-25 does not.
pub const array_output_schema =
    \\{"type":"array","items":{"type":"integer"}}
;

/// The structured content of the tool `array_output`.
pub const array_output_values = [_]i64{ 1, 2, 3 };

pub const Options = struct {
    /// The number of generated tools. Their names are `tool_0` to `tool_<N-1>`. With more tools
    /// than `limits.page_size`, the result of `tools/list` has more than one page.
    many_tools: u32 = 0,
    /// Register the completion handler. Without it, the server does not declare the
    /// `completions` capability, and `completion/complete` gives the error -32601.
    completion: bool = true,
    /// Register the tool `crash`. A call of it stops the process with `crash_exit_code`. Only
    /// the executable sets this option, because the tool also stops a test process.
    crash: bool = false,
    /// Register the tool `array_output`. Its output schema and its structured content are
    /// arrays. The TypeScript SDK 1.x refuses such a result, thus the executable does not set
    /// this option.
    array_output: bool = false,
    /// The limits of the server. A test can set a small `page_size`.
    limits: mcp.Limits = .{},
};

pub const BuildError = mcp.Server.InitError || mcp.Server.RegisterError;

/// Make the server with all tools of `options`. Release it with `destroy`.
pub fn build(gpa: Allocator, io: Io, options: Options) BuildError!*mcp.Server {
    const server = try gpa.create(mcp.Server);
    errdefer gpa.destroy(server);
    server.* = try mcp.Server.init(gpa, io, .{
        .info = .{ .name = server_name, .version = "0.0.0" },
        .instructions = "The upstream server of the zig-bridge-sdk tests.",
        .limits = options.limits,
    });
    errdefer server.deinit();
    try register(server, options);
    return server;
}

/// Release a server from `build`.
pub fn destroy(server: *mcp.Server) void {
    const gpa = server.gpa;
    server.deinit();
    gpa.destroy(server);
}

fn register(server: *mcp.Server, options: Options) mcp.Server.RegisterError!void {
    const read_only: mcp.types.ToolAnnotations = .{ .readOnlyHint = true };
    try server.addTool(.{ .name = "echo", .description = "Send the text back", .annotations = read_only }, echo);
    try server.addTool(.{ .name = "add", .description = "Add two integers", .annotations = read_only }, add);
    try server.addTool(.{ .name = "slow", .description = "Wait for a time, then send the time back", .annotations = read_only }, slow);
    try server.addTool(.{ .name = "progress", .description = "Send progress notifications, then a result", .annotations = read_only }, progress);
    try server.addToolJson(.{
        .name = "bare_array",
        .description = "Count the values of an array that has no item schema",
        .annotations = read_only,
        .input_schema = bare_array_schema,
    }, bareArray);
    try server.addTool(.{
        .name = "structured",
        .description = "Send the text back as structured content",
        .annotations = read_only,
        .output_schema = structured_output_schema,
    }, structured);
    if (options.array_output) {
        try server.addToolJson(.{
            .name = "array_output",
            .description = "Send an array of integers as structured content",
            .annotations = read_only,
            .output_schema = array_output_schema,
        }, arrayOutput);
    }
    if (options.crash) {
        try server.addToolJson(.{ .name = "crash", .description = "Stop the server process with exit code 3", .input_schema = crash_schema }, crash);
    }
    var i: u32 = 0;
    while (i < options.many_tools) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "tool_{d}", .{i}) catch unreachable; // 15 bytes at most
        try server.addToolJson(.{ .name = name, .description = "A generated tool for the tests of the list pages", .annotations = read_only }, generated);
    }
    try server.addPrompt(.{ .name = "greet", .description = "Greet a person", .arguments = &greet_arguments }, greet);
    if (options.completion) server.setCompletionHandler(complete);
}

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

const SlowArgs = struct {
    ms: u32,
    pub const json_schema = .{
        .description = "Wait for a time.",
        .fields = .{ .ms = .{ .description = "The time in milliseconds" } },
    };
};

/// The tool waits in steps of this time. After each step it examines the cancellation.
const slow_step_ms = 10;

fn slow(ctx: *mcp.RequestContext, args: SlowArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    var left: u32 = args.ms;
    while (left > 0) {
        try ctx.checkCancel();
        const step = @min(left, slow_step_ms);
        try ctx.io.sleep(.fromMilliseconds(step), .awake);
        left -= step;
    }
    try ctx.checkCancel();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "slept {d} ms", .{args.ms}) };
}

const ProgressArgs = struct {
    count: u32,
    ms: u32 = 0,
    pub const json_schema = .{
        .description = "Send progress notifications.",
        .fields = .{
            .count = .{ .description = "The number of progress notifications" },
            .ms = .{ .description = "The time in milliseconds between two notifications" },
        },
    };
};

/// The server sends a progress notification only when the request has a progress token. It
/// sends at most `limits.max_progress_rate_per_s` notifications each second for a request.
fn progress(ctx: *mcp.RequestContext, args: ProgressArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    var i: u32 = 0;
    while (i < args.count) : (i += 1) {
        if (i > 0 and args.ms > 0) try ctx.io.sleep(.fromMilliseconds(args.ms), .awake);
        const note = try std.fmt.allocPrint(ctx.arena, "Step {d} of {d}", .{ i + 1, args.count });
        try ctx.progress(@floatFromInt(i + 1), @floatFromInt(args.count), note);
    }
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "sent {d} progress notifications", .{args.count}) };
}

fn bareArray(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    try ctx.checkCancel();
    const values: Value = if (args == .object) args.object.get("values") orelse .null else .null;
    const count: usize = if (values == .array) values.array.items.len else 0;
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{d} values", .{count}) };
}

const StructuredArgs = struct {
    text: []const u8,
    pub const json_schema = .{
        .description = "Send the text and its length as structured content.",
        .fields = .{ .text = .{ .description = "Any text" } },
    };
};

fn structured(ctx: *mcp.RequestContext, args: StructuredArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    try ctx.checkCancel();
    var object: std.json.ObjectMap = .empty;
    try object.put(ctx.arena, "text", .{ .string = args.text });
    try object.put(ctx.arena, "length", .{ .integer = std.math.cast(i64, args.text.len) orelse std.math.maxInt(i64) });
    var result = try mcp.CallToolResult.text(ctx.arena, "{d} bytes", .{args.text.len});
    result.structuredContent = .{ .object = object };
    return .{ .complete = result };
}

/// The result has no content block. The server of zig-sdk adds a text block with the
/// structured content.
fn arrayOutput(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    try ctx.checkCancel();
    var items: std.json.Array = .init(ctx.arena);
    for (array_output_values) |n| try items.append(.{ .integer = n });
    return .{ .complete = .{ .content = &.{}, .structuredContent = .{ .array = items } } };
}

fn crash(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    const after: Value = if (args == .object) args.object.get("after_ms") orelse .null else .null;
    const after_ms: u32 = if (after == .integer) std.math.cast(u32, after.integer) orelse 0 else 0;
    if (after_ms == 0) std.process.exit(crash_exit_code);
    // A plain thread stops the process later. The tasks of the server do not wait for it.
    const thread = try std.Thread.spawn(.{}, exitLater, .{ ctx.io, after_ms });
    thread.detach();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "the server stops in {d} ms", .{after_ms}) };
}

fn exitLater(io: Io, ms: u32) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
    std.process.exit(crash_exit_code);
}

/// The handler of the tools `tool_<i>`. It sends the name of the tool back.
fn generated(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    try ctx.checkCancel();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{s}", .{ctx.target}) };
}

const greet_arguments = [_]mcp.types.PromptArgument{
    .{ .name = "name", .description = "The name of the person", .required = true },
};

/// The prompt `greet`. It is also the target of the completion requests.
fn greet(ctx: *mcp.RequestContext, args: ?std.json.ArrayHashMap([]const u8)) anyerror!mcp.Outcome(mcp.GetPromptResult) {
    const name: []const u8 = if (args) |a| a.map.get("name") orelse "nobody" else "nobody";
    const messages = try ctx.arena.alloc(mcp.types.PromptMessage, 1);
    messages[0] = .{ .role = .user, .content = .{ .text = .{ .text = try std.fmt.allocPrint(ctx.arena, "Hello, {s}.", .{name}) } } };
    return .{ .complete = .{ .description = "A greeting", .messages = messages } };
}

fn complete(ctx: *mcp.RequestContext, params: mcp.types.CompleteRequestParams) anyerror!mcp.types.CompleteResult.Completion {
    _ = params;
    try ctx.checkCancel();
    return .{ .values = &completion_values, .total = completion_values.len, .hasMore = false };
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const Harness = mcp.transport.memory.Harness;

const test_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"t","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}
;

fn testRequest(arena: Allocator, id: i64, method: []const u8, extra: []const u8) ![]u8 {
    const sep: []const u8 = if (extra.len > 0) "," else "";
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{{s}{s}{s}}}}}", .{ id, method, test_meta, sep, extra });
}

fn lastResult(arena: Allocator, h: *Harness) !Value {
    const tree = try mcp.json.parseTree(arena, h.last() orelse return error.NoFrame);
    return tree.object.get("result") orelse error.NoResult;
}

test "tools/list has pages with many tools and the result names every tool" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{ .many_tools = 5, .limits = .{ .page_size = 4 } });
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var names: std.ArrayList([]const u8) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        const extra = if (cursor) |c| try std.fmt.allocPrint(arena, "\"cursor\":\"{s}\"", .{c}) else "";
        try h.send(try testRequest(arena, @intCast(pages + 1), "tools/list", extra));
        const result = try lastResult(arena, &h);
        for (result.object.get("tools").?.array.items) |tool| try names.append(arena, tool.object.get("name").?.string);
        cursor = mcp.json.getString(result, "nextCursor") orelse break;
    }
    // echo, add, slow, progress, bare_array, structured and tool_0 to tool_4.
    try testing.expectEqual(@as(usize, 11), names.items.len);
    try testing.expectEqual(@as(usize, 2), pages);
    try testing.expectEqualStrings("tool_4", names.items[names.items.len - 1]);
    for (names.items) |n| try testing.expect(!std.mem.eql(u8, n, "crash"));
}

test "the tools give the expected results" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{ .many_tools = 1 });
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try h.send(try testRequest(arena, 1, "tools/call", "\"name\":\"bare_array\",\"arguments\":{\"values\":[1,\"x\",null],\"pair\":[\"a\",2]}"));
    var result = try lastResult(arena, &h);
    try testing.expectEqualStrings("3 values", result.object.get("content").?.array.items[0].object.get("text").?.string);

    try h.send(try testRequest(arena, 2, "tools/call", "\"name\":\"structured\",\"arguments\":{\"text\":\"abc\"}"));
    result = try lastResult(arena, &h);
    const sc = result.object.get("structuredContent").?;
    try testing.expectEqualStrings("abc", sc.object.get("text").?.string);
    try testing.expectEqual(@as(i64, 3), sc.object.get("length").?.integer);
    try testing.expectEqualStrings("3 bytes", result.object.get("content").?.array.items[0].object.get("text").?.string);

    try h.send(try testRequest(arena, 3, "tools/call", "\"name\":\"slow\",\"arguments\":{\"ms\":15}"));
    result = try lastResult(arena, &h);
    try testing.expectEqualStrings("slept 15 ms", result.object.get("content").?.array.items[0].object.get("text").?.string);

    try h.send(try testRequest(arena, 4, "tools/call", "\"name\":\"tool_0\""));
    result = try lastResult(arena, &h);
    try testing.expectEqualStrings("tool_0", result.object.get("content").?.array.items[0].object.get("text").?.string);

    try h.send(try testRequest(arena, 5, "completion/complete", "\"ref\":{\"type\":\"ref/prompt\",\"name\":\"greet\"},\"argument\":{\"name\":\"name\",\"value\":\"a\"}"));
    result = try lastResult(arena, &h);
    const values = result.object.get("completion").?.object.get("values").?.array.items;
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expectEqualStrings("alpha", values[0].string);
    try testing.expectEqualStrings("beta", values[1].string);
}

test "the progress tool sends one notification for each step before the result" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta_with_token =
        \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"progressToken":"p1"}
    ;
    try h.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{" ++ meta_with_token ++ ",\"name\":\"progress\",\"arguments\":{\"count\":3}}}");
    try testing.expectEqual(@as(usize, 4), h.out.items.len);
    for (h.out.items[0..3], 1..) |frame, step| {
        const tree = try mcp.json.parseTree(arena, frame);
        try testing.expectEqualStrings("notifications/progress", mcp.json.getString(tree, "method").?);
        const params = tree.object.get("params").?;
        try testing.expectEqualStrings("p1", mcp.json.getString(params, "progressToken").?);
        try testing.expectEqual(@as(i64, @intCast(step)), params.object.get("progress").?.integer);
    }
    const result = try lastResult(arena, &h);
    try testing.expectEqualStrings("sent 3 progress notifications", result.object.get("content").?.array.items[0].object.get("text").?.string);
}

test "the slow tool stops at a cancellation" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var token: mcp.transport.CancelToken = .{};
    token.cancel(io, "test");
    try h.sendWithToken(try testRequest(arena, 1, "tools/call", "\"name\":\"slow\",\"arguments\":{\"ms\":60000}"), &token);
    if (h.last()) |frame| try testing.expect(std.mem.indexOf(u8, frame, "slept") == null);
}

test "without the completion handler the server does not declare completions" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{ .completion = false });
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try h.send(try testRequest(arena, 1, "completion/complete", "\"ref\":{\"type\":\"ref/prompt\",\"name\":\"greet\"},\"argument\":{\"name\":\"name\",\"value\":\"a\"}"));
    const tree = try mcp.json.parseTree(arena, h.last().?);
    try testing.expectEqual(@as(i64, -32601), tree.object.get("error").?.object.get("code").?.integer);
}
