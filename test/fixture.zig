//! The tools, the prompts and the completion handler of the upstream server of the tests. The
//! executable `bridge-fixture-server` serves them over stdio. A test can also make the server in
//! its own process with `build` and connect to it through `mcp.transport.memory`.
//!
//! The tools `ask_form`, `ask_url`, `ask_url_twice`, `ask_bad_url`, `sample`, `sample_tools`,
//! `list_roots`, `multi` and `many_inputs`, and the prompt `ask_name`, ask the client for input
//! with an `InputRequiredResult`. The round after the answers gives a text result.
//!
//! The tools `toggle`, `touch` and `log` send notifications during the call. `toggle` enables
//! or disables the tool `toggled` or the prompt `toggled`. Thus the server writes a list change
//! to each listen stream before the result of the call. This is an interoperability case for
//! VS Code.
//!
//! `touch` tells the listen streams that a resource changed. `log` sends log messages at four
//! levels. The server declares `logging`.
//!
//! `https` has the HTTPS variant of the server: the same tools behind a TLS listener, with an
//! optional OAuth authorization server in the same process.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");

/// The HTTPS variant of the server.
pub const https = @import("fixture_https.zig");

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

/// The exit code of the process after a call of the tool `shutdown`.
pub const shutdown_exit_code: u8 = 0;

/// The input schema of the tool `shutdown`. The server ends each listen stream at once, as at
/// the end of its input. On stdio, each stream then gets its result and a
/// `notifications/cancelled`. The call gets a result, and the process stops `after_ms` later.
pub const shutdown_schema =
    \\{"type":"object","properties":{"after_ms":{"type":"integer","minimum":1,"maximum":60000,"description":"The time in milliseconds from the result to the stop"}},"required":["after_ms"],"additionalProperties":false}
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

/// The `requestedSchema` of the tool `ask_form`: a string, a number, a boolean and an enum.
pub const ask_form_schema =
    \\{"type":"object","properties":{"name":{"type":"string","title":"Name","minLength":1},"age":{"type":"integer","title":"Age","minimum":0,"maximum":150},"subscribe":{"type":"boolean","title":"Subscribe"},"color":{"type":"string","title":"Color","enum":["red","green","blue"]}},"required":["name"]}
;

/// The URL of the tools `ask_url` and `ask_url_twice`.
pub const auth_url = "https://example.com/auth";

/// The URL of the tool `ask_bad_url`. The bridge never sends a `file:` URL to the client. The
/// URL has a host, because zig-sdk refuses a URL elicitation without a host, for example
/// `file:///etc/passwd`.
pub const bad_url = "file://localhost/etc/passwd";

/// The number of input requests of the tool `many_inputs`: one more than the default limit of
/// the bridge for one round.
pub const many_inputs_count = 17;

/// The input schema of the tool `toggle`. Without `target`, the tool changes the tool
/// `toggled`.
pub const toggle_schema =
    \\{"type":"object","properties":{"enabled":{"type":"boolean","description":"Enable the target, or disable it"},"target":{"type":"string","enum":["tool","prompt"],"description":"The tool toggled or the prompt toggled"}},"required":["enabled"],"additionalProperties":false}
;

/// The input schema of the tool `touch`.
pub const touch_schema =
    \\{"type":"object","properties":{"uri":{"type":"string","description":"The URI of the resource that changed"}},"required":["uri"],"additionalProperties":false}
;

/// The URI of the text resource of the server. A test subscribes to it and changes it with the
/// tool `touch`.
pub const notes_uri = "file:///fixture/notes.txt";
/// The text of the resource `notes_uri`.
pub const notes_text = "The notes of the fixture.";

/// The levels of the log messages of the tool `log`, in this order.
pub const log_levels = [_]mcp.types.LoggingLevel{ .debug, .info, .warning, .@"error" };
/// The logger name of the log messages of the tool `log`.
pub const log_logger = "fixture";

/// The name of the tool of the option `guarded`. Behind the authorization server of the HTTPS
/// variant, a call of this tool needs the scope `https.step_up_scope`.
pub const guarded_tool = "guarded";
/// The text of the result of the tool `guarded`.
pub const guarded_text = "guarded: allowed";

/// The largest text of the tool `big`.
pub const max_big_bytes = 64 << 20;
/// The input schema of the tool `big`.
pub const big_schema =
    \\{"type":"object","properties":{"bytes":{"type":"integer","minimum":1,"maximum":67108864,"description":"The size of the text in bytes"}},"required":["bytes"],"additionalProperties":false}
;

pub const Options = struct {
    /// The number of generated tools. Their names are `tool_0` to `tool_<N-1>`. With more tools
    /// than `limits.page_size`, the result of `tools/list` has more than one page.
    many_tools: u32 = 0,
    /// Register the completion handler. Without it, the server does not declare the
    /// `completions` capability, and `completion/complete` gives the error -32601.
    completion: bool = true,
    /// Register the tools `crash` and `shutdown`. A call of `crash` stops the process with
    /// `crash_exit_code`. A call of `shutdown` ends the listen streams and then stops the
    /// process with `shutdown_exit_code`. Only the executable sets this option, because these
    /// tools also stop a test process.
    crash: bool = false,
    /// Register the tool `array_output`. Its output schema and its structured content are
    /// arrays. The TypeScript SDK 1.x refuses such a result, thus the executable does not set
    /// this option.
    array_output: bool = false,
    /// The limits of the server. A test can set a small `page_size`.
    limits: mcp.Limits = .{},
    /// Register the tool `guarded`. The HTTPS variant sets this option. Its authorization
    /// server then asks for a step-up for each call of the tool.
    guarded: bool = false,
    /// Register the tool `big`. Its result has a text of `bytes` bytes, up to `max_big_bytes`.
    /// The HTTPS variant sets this option for the tests of large responses.
    big: bool = false,
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
        // The tools that ask for input use each kind. The server sends a kind only when the
        // client declared it.
        .mrtr = .{ .elicitation = true, .sampling = true, .sampling_tools = true, .roots = true },
        // The tool `log` sends log messages.
        .capabilities = .{ .logging = .{ .object = .empty } },
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
        try server.addToolJson(.{ .name = "shutdown", .description = "End the listen streams as at the end of the input, then stop the server process with exit code 0", .input_schema = shutdown_schema }, shutdown);
    }
    try server.addToolJson(.{ .name = "ask_form", .description = "Ask for a name, an age, a choice and a color in a form" }, askForm);
    try server.addToolJson(.{ .name = "ask_url", .description = "Ask the user to open a page" }, askUrl);
    try server.addToolJson(.{
        .name = "ask_url_twice",
        .description = "Ask for the same page in two rounds, unless the argument complete is true",
        .input_schema = ask_url_twice_schema,
    }, askUrlTwice);
    try server.addToolJson(.{ .name = "ask_bad_url", .description = "Ask the user to open a file URL" }, askBadUrl);
    try server.addToolJson(.{ .name = "sample", .description = "Ask the model of the client for a text" }, sample);
    try server.addToolJson(.{ .name = "sample_tools", .description = "Ask the model of the client with a tool" }, sampleTools);
    try server.addToolJson(.{ .name = "list_roots", .description = "List the roots of the client" }, listRoots);
    try server.addToolJson(.{ .name = "multi", .description = "Ask for a name and the roots in one round" }, multi);
    try server.addToolJson(.{ .name = "many_inputs", .description = "Ask for the roots 17 times in one round" }, manyInputs);
    try server.addToolJson(.{ .name = "toggle", .description = "Enable or disable the tool toggled or the prompt toggled", .input_schema = toggle_schema }, toggle);
    try server.addToolJson(.{ .name = "toggled", .description = "A tool that the tool toggle enables and disables", .annotations = read_only }, toggled);
    try server.addToolJson(.{ .name = "touch", .description = "Tell the subscribers that a resource changed", .input_schema = touch_schema }, touch);
    try server.addToolJson(.{ .name = "log", .description = "Send log messages at the levels debug, info, warning and error", .annotations = read_only }, logMessages);
    try server.addResource(.{ .uri = notes_uri, .name = "notes", .mime_type = "text/plain" }, readNotes);
    if (options.guarded) {
        try server.addToolJson(.{ .name = guarded_tool, .description = "A tool that needs the scope mcp:write behind the authorization server", .annotations = read_only }, guarded);
    }
    if (options.big) {
        try server.addToolJson(.{ .name = "big", .description = "Send back a text of the given size", .annotations = read_only, .input_schema = big_schema }, big);
    }
    var i: u32 = 0;
    while (i < options.many_tools) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "tool_{d}", .{i}) catch unreachable; // 15 bytes at most
        try server.addToolJson(.{ .name = name, .description = "A generated tool for the tests of the list pages", .annotations = read_only }, generated);
    }
    try server.addPrompt(.{ .name = "greet", .description = "Greet a person", .arguments = &greet_arguments }, greet);
    try server.addPrompt(.{ .name = "ask_name", .description = "Ask for a name in a form, then greet the person" }, askName);
    try server.addPrompt(.{ .name = "toggled", .description = "A prompt that the tool toggle enables and disables" }, toggledPrompt);
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
    const thread = try std.Thread.spawn(.{}, exitLater, .{ ctx.io, after_ms, crash_exit_code });
    thread.detach();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "the server stops in {d} ms", .{after_ms}) };
}

/// End each listen stream as the stdio server does at the end of its input. Each stream gets
/// its result and then a `notifications/cancelled` with the id of the stream. The process
/// stops later with `shutdown_exit_code`.
fn shutdown(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    const after: Value = if (args == .object) args.object.get("after_ms") orelse .null else .null;
    if (after != .integer) return error.InvalidParams;
    const after_ms = std.math.cast(u32, after.integer) orelse return error.InvalidParams;
    if (after_ms == 0) return error.InvalidParams;
    ctx.server.shutdownSubscriptions(ctx.io);
    const thread = try std.Thread.spawn(.{}, exitLater, .{ ctx.io, after_ms, shutdown_exit_code });
    thread.detach();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "the server ended its listen streams and stops in {d} ms", .{after_ms}) };
}

fn exitLater(io: Io, ms: u32, code: u8) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
    std.process.exit(code);
}

// -- The tools that send notifications ----------------------------------------------------------

/// Enable or disable the tool `toggled` or the prompt `toggled`. A change writes the list
/// change to each listen stream of the server before the result.
fn toggle(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    const enabled_arg: Value = if (args == .object) args.object.get("enabled") orelse .null else .null;
    if (enabled_arg != .bool) return error.InvalidParams;
    const target = if (args == .object) mcp.json.getString(args, "target") orelse "tool" else "tool";
    const prompt = std.mem.eql(u8, target, "prompt");
    if (!prompt and !std.mem.eql(u8, target, "tool")) return error.InvalidParams;
    const changed = if (prompt)
        ctx.server.setPromptEnabled(ctx.io, "toggled", enabled_arg.bool)
    else
        ctx.server.setToolEnabled(ctx.io, "toggled", enabled_arg.bool);
    const state = if (enabled_arg.bool) "enabled" else "disabled";
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{s} toggled: {s}{s}", .{ target, state, if (changed) "" else " (no change)" }) };
}

fn toggled(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "toggled", .{}) };
}

fn toggledPrompt(ctx: *mcp.RequestContext, args: ?std.json.ArrayHashMap([]const u8)) anyerror!mcp.Outcome(mcp.GetPromptResult) {
    _ = args;
    const messages = try ctx.arena.alloc(mcp.types.PromptMessage, 1);
    messages[0] = .{ .role = .user, .content = .{ .text = .{ .text = "toggled" } } };
    return .{ .complete = .{ .messages = messages } };
}

/// Tell each listen stream with the URI that the resource changed, before the result.
fn touch(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    const uri = if (args == .object) mcp.json.getString(args, "uri") orelse return error.InvalidParams else return error.InvalidParams;
    ctx.server.notifyResourceUpdated(ctx.io, uri);
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "touched {s}", .{uri}) };
}

/// Send one log message at each level of `log_levels`. The server sends only the messages at
/// the log level of the request and above, and none without a level.
fn logMessages(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    for (log_levels) |level| {
        try ctx.log(level, log_logger, .{ .string = try std.fmt.allocPrint(ctx.arena, "a message at the level {t}", .{level}) });
    }
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "logged {d} messages", .{log_levels.len}) };
}

fn readNotes(ctx: *mcp.RequestContext, uri: []const u8) anyerror!mcp.Outcome(mcp.ReadResourceResult) {
    const contents = try ctx.arena.alloc(mcp.types.ResourceContents, 1);
    contents[0] = .{ .text = .{ .uri = uri, .mimeType = "text/plain", .text = notes_text } };
    return .{ .complete = .{ .contents = contents } };
}

/// The tool `guarded`. The authorization server of the HTTPS variant checks the scope before
/// the call comes to the server. Thus the tool itself does no check.
fn guarded(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    try ctx.checkCancel();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, guarded_text, .{}) };
}

/// The tool `big`: a text of `bytes` times the letter x.
fn big(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    const bytes: Value = if (args == .object) args.object.get("bytes") orelse .null else .null;
    if (bytes != .integer or bytes.integer < 1 or bytes.integer > max_big_bytes) return error.InvalidParams;
    try ctx.checkCancel();
    const text = try ctx.arena.alloc(u8, @intCast(bytes.integer));
    @memset(text, 'x');
    const content = try ctx.arena.alloc(mcp.types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .complete = .{ .content = content } };
}

/// The handler of the tools `tool_<i>`. It sends the name of the tool back.
fn generated(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    try ctx.checkCancel();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{s}", .{ctx.target}) };
}

// -- The tools that ask for input ---------------------------------------------------------------

/// The text result of an elicitation answer: the action, and the content as JSON for
/// `accept`.
fn elicitText(ctx: *mcp.RequestContext, prefix: []const u8, answer: mcp.types.ElicitResult) !mcp.CallToolResult {
    if (answer.action != .accept or answer.content == null) return mcp.CallToolResult.text(ctx.arena, "{s}: {t}", .{ prefix, answer.action });
    return mcp.CallToolResult.text(ctx.arena, "{s}: accept {s}", .{ prefix, try mcp.json.writeAlloc(ctx.arena, answer.content.?) });
}

fn askForm(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.elicitResponse("profile")) |a| return .{ .complete = try elicitText(ctx, "form", a) };
    const schema = try mcp.json.parseValue(mcp.types.ElicitRequestFormParams.RequestedSchema, ctx.arena, try mcp.json.parseTree(ctx.arena, ask_form_schema));
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitForm("profile", "Tell us about you.", schema);
    return .{ .input_required = ir };
}

fn askUrl(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.elicitResponse("auth")) |a| return .{ .complete = try elicitText(ctx, "url", a) };
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitUrl("auth", "Sign in to continue.", auth_url);
    return .{ .input_required = ir };
}

/// The input schema of the tool `ask_url_twice`.
pub const ask_url_twice_schema =
    \\{"type":"object","properties":{"complete":{"type":"boolean","description":"Give the result in round 2"}},"additionalProperties":false}
;

/// Round 1 asks for `auth_url`. Round 2 asks for it again, as a server does that does not
/// wait for the end of the step in the browser. With `complete: true`, round 2 gives the
/// result instead. The request state holds the number of the round.
fn askUrlTwice(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    const complete_arg: Value = if (args == .object) args.object.get("complete") orelse .null else .null;
    const complete_early = complete_arg == .bool and complete_arg.bool;
    const round = try ctx.state(u32) orelse 0;
    if (round >= 2 or (round == 1 and complete_early)) {
        const a = try ctx.elicitResponse("auth") orelse return error.InvalidParams;
        return .{ .complete = try elicitText(ctx, "url twice", a) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitUrl("auth", "Sign in to continue.", auth_url);
    try ir.setStateFmt("{d}", .{round + 1});
    return .{ .input_required = ir };
}

fn askBadUrl(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.elicitResponse("file")) |a| return .{ .complete = try elicitText(ctx, "url", a) };
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitUrl("file", "Open the file.", bad_url);
    return .{ .input_required = ir };
}

/// One user message with the text `text`.
fn userMessage(ctx: *mcp.RequestContext, text: []const u8) ![]const mcp.types.SamplingMessage {
    const messages = try ctx.arena.alloc(mcp.types.SamplingMessage, 1);
    messages[0] = .{ .role = .user, .content = .{ .single = .{ .text = .{ .text = text } } } };
    return messages;
}

/// The text of the model in a sampling answer.
fn modelText(ctx: *mcp.RequestContext, result: mcp.types.CreateMessageResult) !mcp.CallToolResult {
    for (result.content.blocks()) |block| if (block == .text) return mcp.CallToolResult.text(ctx.arena, "model: {s}", .{block.text.text});
    return mcp.CallToolResult.text(ctx.arena, "model: no text", .{});
}

fn sample(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.sampleResponse("model")) |r| return .{ .complete = try modelText(ctx, r) };
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.sample("model", .{ .messages = try userMessage(ctx, "Say hello."), .maxTokens = 50 });
    return .{ .input_required = ir };
}

/// A sampling request with a tool. The server sends it only to a client that declared
/// `sampling.tools`. VS Code does not declare it, thus the bridge never declares it upstream.
fn sampleTools(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.sampleResponse("model")) |r| return .{ .complete = try modelText(ctx, r) };
    const tools = try ctx.arena.alloc(mcp.types.Tool, 1);
    tools[0] = .{ .name = "lookup", .inputSchema = try mcp.json.parseTree(ctx.arena, "{\"type\":\"object\"}") };
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.sample("model", .{ .messages = try userMessage(ctx, "Look up the weather."), .maxTokens = 50, .tools = tools });
    return .{ .input_required = ir };
}

/// The URIs of a roots answer, one on each line.
fn rootsText(ctx: *mcp.RequestContext, result: mcp.types.ListRootsResult) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (result.roots, 0..) |root, i| {
        if (i > 0) try text.append(ctx.arena, '\n');
        try text.appendSlice(ctx.arena, root.uri);
    }
    return text.items;
}

fn listRoots(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.rootsResponse("roots")) |r| return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "roots: {s}", .{try rootsText(ctx, r)}) };
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.listRoots("roots");
    return .{ .input_required = ir };
}

/// Two input requests in one round: a form and the roots.
fn multi(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (ctx.hasAllResponses(&.{ "name", "roots" })) {
        const name = (try ctx.elicitResponse("name")).?;
        const roots = (try ctx.rootsResponse("roots")).?;
        const given = if (name.content) |c| mcp.json.getString(c, "name") orelse "nobody" else "nobody";
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "name: {s} ({t}); roots: {d}", .{ given, name.action, roots.roots.len }) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitForm("name", "Your name?", try mcp.InputRequired.stringSchema(ctx.arena, "name", null, true));
    try ir.listRoots("roots");
    return .{ .input_required = ir };
}

/// `many_inputs_count` input requests in one round, with the keys `r0` to `r16`.
fn manyInputs(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (ctx.input_responses) |responses| return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "answers: {d}", .{responses.map.count()}) };
    var ir: mcp.InputRequired = .init(ctx.arena);
    for (0..many_inputs_count) |i| try ir.listRoots(try std.fmt.allocPrint(ctx.arena, "r{d}", .{i}));
    return .{ .input_required = ir };
}

/// The prompt `ask_name`: it asks for a name in a form, then greets the person.
fn askName(ctx: *mcp.RequestContext, args: ?std.json.ArrayHashMap([]const u8)) anyerror!mcp.Outcome(mcp.GetPromptResult) {
    _ = args;
    const answer = try ctx.elicitResponse("name") orelse {
        var ir: mcp.InputRequired = .init(ctx.arena);
        try ir.elicitForm("name", "Your name?", try mcp.InputRequired.stringSchema(ctx.arena, "name", null, true));
        return .{ .input_required = ir };
    };
    const name = if (answer.content) |c| mcp.json.getString(c, "name") orelse "nobody" else "nobody";
    const messages = try ctx.arena.alloc(mcp.types.PromptMessage, 1);
    messages[0] = .{ .role = .user, .content = .{ .text = .{ .text = try std.fmt.allocPrint(ctx.arena, "Hello, {s}.", .{name}) } } };
    return .{ .complete = .{ .description = "A greeting after a form", .messages = messages } };
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

test {
    _ = https;
}

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
    // echo, add, slow, progress, bare_array, structured, the nine tools that ask for input,
    // toggle, toggled, touch, log and tool_0 to tool_4.
    try testing.expectEqual(@as(usize, 24), names.items.len);
    try testing.expectEqual(@as(usize, 5), pages);
    try testing.expectEqualStrings("tool_4", names.items[names.items.len - 1]);
    for (names.items) |n| {
        try testing.expect(!std.mem.eql(u8, n, "crash"));
        try testing.expect(!std.mem.eql(u8, n, "shutdown"));
        try testing.expect(!std.mem.eql(u8, n, guarded_tool));
        try testing.expect(!std.mem.eql(u8, n, "big"));
    }
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

/// The text of the first content block of the result in the last frame.
fn lastText(arena: Allocator, h: *Harness) ![]const u8 {
    return (try lastResult(arena, h)).object.get("content").?.array.items[0].object.get("text").?.string;
}

/// True when the result of `tools/list` or `prompts/list` in the last frame names `name`.
fn listed(arena: Allocator, h: *Harness, member: []const u8, name: []const u8) !bool {
    for ((try lastResult(arena, h)).object.get(member).?.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("name").?.string, name)) return true;
    }
    return false;
}

test "the tool toggle enables and disables the tool toggled and the prompt toggled" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try h.send(try testRequest(arena, 1, "tools/list", ""));
    try testing.expect(try listed(arena, &h, "tools", "toggled"));
    try h.send(try testRequest(arena, 2, "tools/call", "\"name\":\"toggle\",\"arguments\":{\"enabled\":false}"));
    try testing.expectEqualStrings("tool toggled: disabled", try lastText(arena, &h));
    try h.send(try testRequest(arena, 3, "tools/list", ""));
    try testing.expect(!try listed(arena, &h, "tools", "toggled"));
    try h.send(try testRequest(arena, 4, "tools/call", "\"name\":\"toggle\",\"arguments\":{\"enabled\":false}"));
    try testing.expectEqualStrings("tool toggled: disabled (no change)", try lastText(arena, &h));
    try h.send(try testRequest(arena, 5, "tools/call", "\"name\":\"toggle\",\"arguments\":{\"enabled\":true}"));
    try testing.expectEqualStrings("tool toggled: enabled", try lastText(arena, &h));

    try h.send(try testRequest(arena, 6, "tools/call", "\"name\":\"toggle\",\"arguments\":{\"enabled\":false,\"target\":\"prompt\"}"));
    try testing.expectEqualStrings("prompt toggled: disabled", try lastText(arena, &h));
    try h.send(try testRequest(arena, 7, "prompts/list", ""));
    try testing.expect(!try listed(arena, &h, "prompts", "toggled"));
    try testing.expect(try listed(arena, &h, "prompts", "greet"));

    // The resource of the tool touch.
    try h.send(try testRequest(arena, 8, "tools/call", "\"name\":\"touch\",\"arguments\":{\"uri\":\"" ++ notes_uri ++ "\"}"));
    try testing.expectEqualStrings("touched " ++ notes_uri, try lastText(arena, &h));
    try h.send(try testRequest(arena, 9, "resources/read", "\"uri\":\"" ++ notes_uri ++ "\""));
    try testing.expectEqualStrings(notes_text, (try lastResult(arena, &h)).object.get("contents").?.array.items[0].object.get("text").?.string);
}

test "the tool log sends the messages at the log level of the request and above" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Without a log level, the server sends no log message.
    try h.send(try testRequest(arena, 1, "tools/call", "\"name\":\"log\""));
    try testing.expectEqual(@as(usize, 1), h.out.items.len);
    try testing.expectEqualStrings("logged 4 messages", try lastText(arena, &h));
    h.clear();
    try h.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/logLevel\":\"warning\"},\"name\":\"log\"}}");
    try testing.expectEqual(@as(usize, 3), h.out.items.len);
    for (h.out.items[0..2], [_][]const u8{ "warning", "error" }) |frame, level| {
        const tree = try mcp.json.parseTree(arena, frame);
        try testing.expectEqualStrings("notifications/message", mcp.json.getString(tree, "method").?);
        const params = tree.object.get("params").?;
        try testing.expectEqualStrings(level, mcp.json.getString(params, "level").?);
        try testing.expectEqualStrings(log_logger, mcp.json.getString(params, "logger").?);
    }
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

/// The `_meta` of a client that declares each input kind, but not `sampling.tools`.
const input_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"t","version":"1"},"io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{},"url":{}},"sampling":{},"roots":{}}}
;

/// The `_meta` of a client that also declares `sampling.tools`.
const tools_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"t","version":"1"},"io.modelcontextprotocol/clientCapabilities":{"sampling":{"tools":{}}}}
;

/// The rounds of one request of a client that declares the input kinds.
const Rounds = struct {
    h: *Harness,
    arena: Allocator,
    meta: []const u8 = input_meta,
    next_id: i64 = 1,
    method: []const u8 = "tools/call",
    /// The params of the request without `_meta`, as JSON members.
    params: []const u8,
    /// The `requestState` of the last `InputRequiredResult`.
    state: ?[]const u8 = null,

    /// Send a round. `responses` is the `inputResponses` object as JSON text, or null for the
    /// first round. Returns the frame of the response.
    fn send(self: *Rounds, responses: ?[]const u8) !Value {
        var line: std.ArrayList(u8) = .empty;
        try line.print(self.arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{{s},{s}", .{ self.next_id, self.method, self.meta, self.params });
        self.next_id += 1;
        if (responses) |r| try line.print(self.arena, ",\"inputResponses\":{s}", .{r});
        if (self.state) |s| try line.print(self.arena, ",\"requestState\":\"{s}\"", .{s});
        try line.appendSlice(self.arena, "}}");
        try self.h.send(line.items);
        const frame = try mcp.json.parseTree(self.arena, self.h.last() orelse return error.NoFrame);
        if (frame.object.get("result")) |result| self.state = mcp.json.getString(result, "requestState");
        return frame;
    }

    /// Send a round, expect an `InputRequiredResult`, and return its `inputRequests`.
    fn inputs(self: *Rounds, responses: ?[]const u8) !Value {
        const result = (try self.send(responses)).object.get("result") orelse return error.NoResult;
        try testing.expectEqualStrings("input_required", mcp.json.getString(result, "resultType").?);
        return result.object.get("inputRequests") orelse .{ .object = .empty };
    }

    /// Send a round, expect a complete `tools/call` result, and return its first text.
    fn text(self: *Rounds, responses: ?[]const u8) ![]const u8 {
        const result = (try self.send(responses)).object.get("result") orelse return error.NoResult;
        try testing.expectEqualStrings("complete", mcp.json.getString(result, "resultType").?);
        return result.object.get("content").?.array.items[0].object.get("text").?.string;
    }
};

test "ask_form asks for a form with each kind of field and gives the answer back" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Rounds = .{ .h = &h, .arena = arena_state.allocator(), .params = "\"name\":\"ask_form\"" };
    const inputs = try r.inputs(null);
    const profile = inputs.object.get("profile").?;
    try testing.expectEqualStrings("elicitation/create", mcp.json.getString(profile, "method").?);
    const properties = profile.object.get("params").?.object.get("requestedSchema").?.object.get("properties").?;
    try testing.expectEqualStrings("string", mcp.json.getString(properties.object.get("name").?, "type").?);
    try testing.expectEqualStrings("integer", mcp.json.getString(properties.object.get("age").?, "type").?);
    try testing.expectEqualStrings("boolean", mcp.json.getString(properties.object.get("subscribe").?, "type").?);
    try testing.expectEqual(@as(usize, 3), properties.object.get("color").?.object.get("enum").?.array.items.len);
    try testing.expectEqualStrings(
        \\form: accept {"name":"Ada","age":36,"subscribe":true,"color":"green"}
    , try r.text(
        \\{"profile":{"action":"accept","content":{"name":"Ada","age":36,"subscribe":true,"color":"green"}}}
    ));
    r.state = null;
    _ = try r.inputs(null);
    try testing.expectEqualStrings("form: decline", try r.text("{\"profile\":{\"action\":\"decline\"}}"));
}

test "a client without the input kinds gets -32021" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "ask_form", "ask_url", "sample", "list_roots", "sample_tools" }) |tool| {
        try h.send(try testRequest(arena, 1, "tools/call", try std.fmt.allocPrint(arena, "\"name\":\"{s}\"", .{tool})));
        const tree = try mcp.json.parseTree(arena, h.last().?);
        try testing.expectEqual(@as(i64, -32021), tree.object.get("error").?.object.get("code").?.integer);
    }
    // sample_tools needs sampling.tools, which input_meta does not declare.
    var r: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"sample_tools\"" };
    const refused = try r.send(null);
    try testing.expectEqual(@as(i64, -32021), refused.object.get("error").?.object.get("code").?.integer);
    // A client with sampling.tools gets the request with the tool.
    r.meta = tools_meta;
    const inputs = try r.inputs(null);
    const tools = inputs.object.get("model").?.object.get("params").?.object.get("tools").?;
    try testing.expectEqualStrings("lookup", mcp.json.getString(tools.array.items[0], "name").?);
}

test "the URL tools" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var url: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"ask_url\"" };
    const params = (try url.inputs(null)).object.get("auth").?.object.get("params").?;
    try testing.expectEqualStrings("url", mcp.json.getString(params, "mode").?);
    try testing.expectEqualStrings(auth_url, mcp.json.getString(params, "url").?);
    try testing.expectEqualStrings("url: accept", try url.text("{\"auth\":{\"action\":\"accept\"}}"));

    // The same URL in round 2, then the result in round 3.
    var twice: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"ask_url_twice\"" };
    _ = try twice.inputs(null);
    try testing.expect(twice.state != null);
    const again = try twice.inputs("{\"auth\":{\"action\":\"accept\"}}");
    try testing.expectEqualStrings(auth_url, mcp.json.getString(again.object.get("auth").?.object.get("params").?, "url").?);
    try testing.expectEqualStrings("url twice: accept", try twice.text("{\"auth\":{\"action\":\"accept\"}}"));
    // With complete: true, round 2 gives the result.
    var once: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"ask_url_twice\",\"arguments\":{\"complete\":true}" };
    _ = try once.inputs(null);
    try testing.expectEqualStrings("url twice: accept", try once.text("{\"auth\":{\"action\":\"accept\"}}"));

    var bad: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"ask_bad_url\"" };
    try testing.expectEqualStrings(bad_url, mcp.json.getString((try bad.inputs(null)).object.get("file").?.object.get("params").?, "url").?);
    try testing.expectEqualStrings("url: decline", try bad.text("{\"file\":{\"action\":\"decline\"}}"));
}

test "sampling, roots, two inputs in one round and many inputs" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"sample\"" };
    const model = (try s.inputs(null)).object.get("model").?;
    try testing.expectEqualStrings("sampling/createMessage", mcp.json.getString(model, "method").?);
    try testing.expect(model.object.get("params").?.object.get("tools") == null);
    try testing.expectEqualStrings("model: Hello", try s.text(
        \\{"model":{"role":"assistant","content":{"type":"text","text":"Hello"},"model":"m"}}
    ));

    var roots: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"list_roots\"" };
    try testing.expectEqualStrings("roots/list", mcp.json.getString((try roots.inputs(null)).object.get("roots").?, "method").?);
    try testing.expectEqualStrings("roots: file:///a\nfile:///b", try roots.text(
        \\{"roots":{"roots":[{"uri":"file:///a"},{"uri":"file:///b","name":"b"}]}}
    ));

    var both: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"multi\"" };
    try testing.expectEqual(@as(usize, 2), (try both.inputs(null)).object.count());
    try testing.expectEqualStrings("name: Ada (accept); roots: 1", try both.text(
        \\{"name":{"action":"accept","content":{"name":"Ada"}},"roots":{"roots":[{"uri":"file:///a"}]}}
    ));

    var many: Rounds = .{ .h = &h, .arena = arena, .params = "\"name\":\"many_inputs\"" };
    const inputs = try many.inputs(null);
    try testing.expectEqual(@as(usize, many_inputs_count), inputs.object.count());
    var answers: std.ArrayList(u8) = .empty;
    try answers.append(arena, '{');
    for (inputs.object.keys(), 0..) |key, i| {
        if (i > 0) try answers.append(arena, ',');
        try answers.print(arena, "\"{s}\":{{\"roots\":[]}}", .{key});
    }
    try answers.append(arena, '}');
    try testing.expectEqualStrings("answers: 17", try many.text(answers.items));
}

test "the prompt ask_name asks for a name, then greets the person" {
    const io = testing.io;
    const server = try build(testing.allocator, io, .{});
    defer destroy(server);
    var h: Harness = .init(io, testing.allocator, server);
    defer h.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var r: Rounds = .{ .h = &h, .arena = arena_state.allocator(), .method = "prompts/get", .params = "\"name\":\"ask_name\"" };
    try testing.expectEqualStrings("elicitation/create", mcp.json.getString((try r.inputs(null)).object.get("name").?, "method").?);
    const frame = try r.send("{\"name\":{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}}");
    const messages = frame.object.get("result").?.object.get("messages").?.array.items;
    try testing.expectEqualStrings("Hello, Ada.", messages[0].object.get("content").?.object.get("text").?.string);
}
