//! The era tests of `bridge.embed.serveStdioAuto`: the first lines of a client select the path
//! of the connection. The function gets the fixture server and the VS Code profile, as in
//! `vscode.serveStdio`. It runs on the task of the test until the end of the input. Then the
//! test examines the path (`Era`) and the frames.
//!
//! - The input is `Io.Reader.fixed`, or a `Script`. Each step of a script waits for frames of
//!   the function (`Gate`), and then the reader gives the bytes of the step. A test uses a
//!   script for an answer to an input request of the bridge, and for the legacy path. At the
//!   end of the input, the front end cancels the requests in flight. Thus the last step waits
//!   for the last response.
//! - The frames go to an `Io.Writer.Allocating` behind a small buffer and a lock (`Output`).
//!   Thus a frame gets to the test only after its flush, and a script can read the frames
//!   while the function writes.
//! - `Run.verify` checks each frame against the schema of its revision: 2025-11-25 on the
//!   legacy path, and 2026-07-28 on the modern path. Only the server answers
//!   `server/discover`, thus its result is always a frame of revision 2026-07-28.
//! - The function must return in `stop_bound` after the end of the input. The grace period is
//!   longer. Thus a request or a listen stream that holds the stop until the end of the grace
//!   period fails the test.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const vscode = @import("vscode");
const fixture = @import("fixture");
const h = @import("harness.zig");
const wire = @import("wire_check.zig");

const embed = vscode.bridge.embed;
const Era = embed.Era;
const testing = std.testing;

/// The time that the requests in flight get at the end of the input.
const grace: Io.Duration = .fromSeconds(10);
/// The longest time from the end of the input to the return of the function.
const stop_bound: Io.Duration = .fromSeconds(3);
/// The longest wait of a step of a script for its frames.
const wait_limit: Io.Duration = .fromSeconds(10);

// -- Input lines --------------------------------------------------------------------------------

/// A request line and its newline. The id `id` and the params `params` are JSON text.
fn request(comptime id: []const u8, comptime method: []const u8, comptime params: []const u8) []const u8 {
    return "{\"jsonrpc\":\"2.0\",\"id\":" ++ id ++ ",\"method\":\"" ++ method ++ "\",\"params\":" ++ params ++ "}\n";
}

/// The `_meta` member of a request of revision 2026-07-28.
const modern_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"embed-test","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}
;
const modern_discover = request("11", "server/discover", "{" ++ modern_meta ++ "}");
const modern_list = request("2", "tools/list", "{" ++ modern_meta ++ "}");
const modern_add = request("3", "tools/call", "{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":3}," ++ modern_meta ++ "}");

/// The first request and the notification of VS Code, each with its newline.
const vscode_initialize = h.vscode_initialize ++ "\n";
const initialized = h.initialized ++ "\n";
const legacy_add = request("2", "tools/call", "{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":3}}");
/// The answer of VS Code to the first request of the bridge: the form of `ask_form`.
const form_answer = "{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}}\n";
const form_text = "form: accept {\"name\":\"Ada\"}";

/// The `_meta` of a request of revision 2026-07-28 from the Copilot harness of VS Code.
const copilot_meta =
    \\{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"copilot-cli","version":"1.0.89"},"io.modelcontextprotocol/clientCapabilities":{"sampling":{},"elicitation":{"form":{},"url":{}}}}
;
/// The `initialize` params of the Copilot harness: sampling and the two elicitation modes.
const copilot_initialize_params =
    \\{"protocolVersion":"2025-11-25","capabilities":{"sampling":{},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"copilot-cli","version":"1.0.89"}}
;

/// The message of the error -32601 of the bridge.
const method_not_found_message = "The server does not have this method.";

// -- Output -------------------------------------------------------------------------------------

/// The output of the function: an `Io.Writer.Allocating` behind a buffer of 256 bytes and a
/// lock.
const Output = struct {
    writer: Io.Writer,
    io: Io,
    lock: Io.Mutex = .init,
    /// The bytes of the flushed frames. Guarded by `lock`.
    bytes: Io.Writer.Allocating,
    /// The number of bytes of `bytes` that `sync` parsed. Only the task of the test uses this
    /// field, `lines` and `frames`.
    parsed_len: usize = 0,
    /// The complete lines, in the arena of the run.
    lines: std.ArrayList([]const u8) = .empty,
    /// The parsed lines, in the arena of the run.
    frames: std.ArrayList(Value) = .empty,
    buf: [256]u8 = undefined,

    /// Make the output in place, because the writer points into `buf`.
    fn init(self: *Output, io: Io) void {
        self.* = .{
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.buf },
            .io = io,
            .bytes = .init(testing.allocator),
        };
    }

    fn deinit(self: *Output) void {
        self.bytes.deinit();
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Output = @alignCast(@fieldParentPtr("writer", w));
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const sink = &self.bytes.writer;
        try sink.writeAll(w.buffered());
        w.end = 0;
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try sink.writeAll(bytes);
            count += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try sink.writeAll(last);
        return count + last.len * splat;
    }

    /// Parse the new complete lines in `arena`. Returns all frames so far.
    fn sync(self: *Output, arena: Allocator) ![]const Value {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const bytes = self.bytes.written();
        while (std.mem.findScalarPos(u8, bytes, self.parsed_len, '\n')) |end| {
            const line = try arena.dupe(u8, bytes[self.parsed_len..end]);
            self.parsed_len = end + 1;
            const frame = mcp.json.parseTree(arena, line) catch |e| {
                std.debug.print("\nthe function wrote a line that is not JSON: {s}\n", .{line});
                return e;
            };
            try self.lines.append(arena, line);
            try self.frames.append(arena, frame);
        }
        return self.frames.items;
    }

    /// The number of bytes after the last complete line.
    fn partialLen(self: *Output) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.bytes.written().len - self.parsed_len;
    }
};

// -- Script -------------------------------------------------------------------------------------

/// The frames that a step of a script waits for. Each condition that is set must be true.
const Gate = struct {
    /// The response with this id.
    response: ?i64 = null,
    /// The request of the bridge with this id.
    bridge_request: ?[]const u8 = null,
    /// At least `count` frames with this method.
    method: ?[]const u8 = null,
    count: usize = 1,
    /// A listen stream of the server.
    listening: bool = false,
};

/// One step of a script: wait for `after`, then give `bytes` to the reader. The bytes can hold
/// more than one line. A step without bytes only waits.
const Step = struct {
    after: Gate = .{},
    bytes: []const u8 = "",
};

/// A reader that gives the steps of a script in their order. The end of the last step is the
/// end of the input. A step that does not get its frames in `wait_limit` ends the input with
/// `error.ReadFailed`.
const Script = struct {
    reader: Io.Reader,
    io: Io,
    steps: []const Step,
    output: *Output,
    server: *mcp.Server,
    arena: Allocator,
    /// The index of the next step.
    next_step: usize = 0,
    /// The bytes of the current step that the reader did not give yet.
    pending: []const u8 = "",
    /// For each step, the number of frames when the step got its frames.
    marks: []usize,
    /// The step that failed, and its error.
    failed_step: ?usize = null,
    failure: ?anyerror = null,
    /// The time of the end of the input.
    ended: ?Io.Clock.Timestamp = null,
    buf: [4096]u8 = undefined,

    /// Make the script in place, because the reader points into `buf`.
    fn init(self: *Script, io: Io, arena: Allocator, steps: []const Step, output: *Output, server: *mcp.Server) !void {
        self.* = .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &self.buf, .seek = 0, .end = 0 },
            .io = io,
            .steps = steps,
            .output = output,
            .server = server,
            .arena = arena,
            .marks = try arena.alloc(usize, steps.len),
        };
        @memset(self.marks, 0);
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Script = @alignCast(@fieldParentPtr("reader", r));
        while (self.pending.len == 0) {
            if (self.failure != null) return error.ReadFailed;
            if (self.next_step == self.steps.len) {
                if (self.ended == null) self.ended = Io.Clock.Timestamp.now(self.io, .awake);
                return error.EndOfStream;
            }
            const step = self.steps[self.next_step];
            self.marks[self.next_step] = self.waitFor(step.after) catch |e| {
                self.failed_step = self.next_step;
                self.failure = e;
                self.ended = Io.Clock.Timestamp.now(self.io, .awake);
                return error.ReadFailed;
            };
            self.pending = step.bytes;
            self.next_step += 1;
        }
        const n = try w.write(limit.sliceConst(self.pending));
        self.pending = self.pending[n..];
        return n;
    }

    /// Wait until the frames open `gate`, at most `wait_limit`. Returns the number of frames.
    fn waitFor(self: *Script, gate: Gate) !usize {
        const deadline = Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = wait_limit, .clock = .awake });
        while (true) {
            const frames = try self.output.sync(self.arena);
            if (opened(self.server, frames, gate)) return frames.len;
            if (Io.Clock.Timestamp.now(self.io, .awake).durationTo(deadline).raw.nanoseconds <= 0) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

fn opened(server: *mcp.Server, frames: []const Value, gate: Gate) bool {
    if (gate.listening and subscriptionCount(server) == 0) return false;
    if (gate.response) |id| if (responseIndex(frames, id) == null) return false;
    if (gate.bridge_request) |id| if (bridgeRequest(frames, id) == null) return false;
    if (gate.method) |m| if (methodCount(frames, m) < gate.count) return false;
    return true;
}

// -- Run ----------------------------------------------------------------------------------------

/// The input of a run.
const Input = union(enum) {
    /// All bytes at once in `Io.Reader.fixed`, then the end of the input.
    fixed: []const u8,
    /// The steps of a `Script`.
    script: []const Step,
};

const RunOptions = struct {
    input: Input,
    discover: embed.Discover = .answer,
    limits: mcp.Limits = .{},
};

/// One call of the function, its server and its frames.
const Run = struct {
    server: *mcp.Server,
    output: Output,
    arena_state: std.heap.ArenaAllocator,
    era: Era = .none,
    /// The bytes of the input.
    input: []const u8 = "",
    /// For each step of a script, the number of frames before the step gave its bytes.
    marks: []const usize = &.{},
    frames: []const Value = &.{},

    fn destroy(self: *Run) void {
        self.output.deinit();
        fixture.destroy(self.server);
        self.arena_state.deinit();
        testing.allocator.destroy(self);
    }

    fn arena(self: *Run) Allocator {
        return self.arena_state.allocator();
    }

    /// The response with the id `id`.
    fn response(self: *Run, id: i64) !Value {
        if (responseIndex(self.frames, id)) |i| return self.frames[i];
        std.debug.print("\nno response with the id {d}\n", .{id});
        self.printFrames();
        return error.TestNoResponse;
    }

    /// The method of each frame from the index `start`, or "response" for a response.
    fn methodsFrom(self: *Run, start: usize) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.frames[start..]) |f| try out.append(self.arena(), mcp.json.getString(f, "method") orelse "response");
        return out.items;
    }

    fn printFrames(self: *Run) void {
        std.debug.print("the frames of the function:\n", .{});
        for (self.output.lines.items, 0..) |line, i| std.debug.print("  {d}: {s}\n", .{ i, line });
    }

    /// The server has no listen stream, and it ends each new listen stream at once.
    fn expectServerStopped(self: *Run) !void {
        try testing.expectEqual(@as(usize, 0), subscriptionCount(self.server));
        try testing.expect(self.server.shutting_down.load(.acquire));
    }

    /// Check each frame against the schema of its revision. Each response must belong to a
    /// request of the input, and each request gets one response at most.
    fn verify(self: *Run) !void {
        const a = self.arena();
        var schemas: wire.Schemas = .init(testing.allocator);
        defer schemas.deinit();
        var sent: std.ArrayList(Sent) = .empty;
        var it = std.mem.splitScalar(u8, self.input, '\n');
        while (it.next()) |line| {
            const v = mcp.json.parseTree(a, line) catch continue;
            if (v != .object) continue;
            const method = mcp.json.getString(v, "method") orelse continue;
            const id = v.object.get("id") orelse continue;
            try sent.append(a, .{ .id = id, .method = method });
        }
        for (self.frames, 0..) |frame, i| {
            self.checkFrame(&schemas, sent.items, frame, i) catch |e| {
                std.debug.print("frame {d}: {s}\n", .{ i, self.output.lines.items[i] });
                return e;
            };
        }
    }

    fn checkFrame(self: *Run, schemas: *wire.Schemas, sent: []Sent, frame: Value, index: usize) !void {
        const a = self.arena();
        const context = try std.fmt.allocPrint(a, "frame {d}", .{index});
        if (frame != .object) return failCheck("the frame is not an object", .{});
        if (!std.mem.eql(u8, mcp.json.getString(frame, "jsonrpc") orelse "", "2.0")) return failCheck("the frame has no jsonrpc 2.0", .{});
        const modern = self.era != .legacy;
        if (frame.object.get("method")) |method| {
            if (method != .string) return failCheck("the method is not a string", .{});
            // No test of the modern path opens a listen stream or calls a tool that asks for
            // input. Thus the server sends no message of its own on that path.
            if (modern) return failCheck("a message of the server on the modern path: {s}", .{method.string});
            if (frame.object.get("id")) |id| {
                if (id != .string or !std.mem.startsWith(u8, id.string, vscode.profile.request_id_prefix))
                    return failCheck("a request of the bridge without the id prefix of the profile", .{});
                const definition = wire.bridgeRequestDefinition(method.string) orelse return failCheck("the bridge sent the request {s}", .{method.string});
                return schemas.check(.legacy, definition, frame, context);
            }
            const definition = wire.notificationDefinition(method.string) orelse return failCheck("the bridge sent the notification {s}", .{method.string});
            return schemas.check(.legacy, definition, frame, context);
        }
        const id = frame.object.get("id") orelse return failCheck("a response without an id member", .{});
        if (frame.object.get("result")) |result| {
            const req = answer(sent, id) orelse return failCheck("a result for an id that the test did not send, or a second response", .{});
            // Only the server answers `server/discover`, also before `initialize`.
            if (std.mem.eql(u8, req.method, "server/discover")) return schemas.check(.modern, "DiscoverResultResponse", frame, context);
            if (modern) {
                const definition = modernResponseDefinition(req.method) orelse return failCheck("a modern result for {s}", .{req.method});
                return schemas.check(.modern, definition, frame, context);
            }
            try schemas.check(.legacy, "JSONRPCResultResponse", frame, context);
            const definition = wire.resultDefinition(req.method) orelse return failCheck("a legacy result for {s}", .{req.method});
            try schemas.check(.legacy, definition, try wire.checkedResult(a, req.method, result), context);
            return wire.expectLegacyResult(req.method, result);
        }
        if (frame.object.get("error") == null) return failCheck("the frame is not a JSON-RPC message", .{});
        var envelope = frame;
        if (id == .null) {
            // JSON-RPC 2.0 wants the id null when the id of a line is not known. The two
            // schemas have no null id, but the member is optional.
            var copy = try frame.object.clone(a);
            _ = copy.orderedRemove("id");
            envelope = .{ .object = copy };
        } else if (answer(sent, id) == null) {
            return failCheck("an error for an id that the test did not send, or a second response", .{});
        }
        return schemas.check(if (modern) .modern else .legacy, "JSONRPCErrorResponse", envelope, context);
    }
};

/// A request of the input.
const Sent = struct {
    id: Value,
    method: []const u8,
    answered: bool = false,
};

/// Mark the first request with `id` that has no response, and return it.
fn answer(sent: []Sent, id: Value) ?*Sent {
    for (sent) |*s| {
        if (s.answered or !sameId(s.id, id)) continue;
        s.answered = true;
        return s;
    }
    return null;
}

/// The definition of the 2026-07-28 schema for the response to `method`, or null.
fn modernResponseDefinition(method: []const u8) ?[]const u8 {
    const map: std.StaticStringMap([]const u8) = .initComptime(.{
        .{ "server/discover", "DiscoverResultResponse" },
        .{ "tools/list", "ListToolsResultResponse" },
        .{ "tools/call", "CallToolResultResponse" },
        .{ "prompts/list", "ListPromptsResultResponse" },
        .{ "prompts/get", "GetPromptResultResponse" },
        .{ "resources/list", "ListResourcesResultResponse" },
        .{ "resources/read", "ReadResourceResultResponse" },
    });
    return map.get(method);
}

fn failCheck(comptime format: []const u8, args: anytype) error{TestFrameCheck} {
    std.debug.print("\n" ++ format ++ "\n", args);
    return error.TestFrameCheck;
}

/// Call the function with the input of `options` on the task of the test, and return after
/// its return. The run fails when a step of a script does not get its frames. It also fails
/// when the function returns more than `stop_bound` after the end of the input.
fn serve(options: RunOptions) !*Run {
    const io = testing.io;
    const gpa = testing.allocator;
    const run = try gpa.create(Run);
    errdefer gpa.destroy(run);
    const server = try fixture.build(gpa, io, .{ .limits = options.limits });
    errdefer fixture.destroy(server);
    run.* = .{ .server = server, .output = undefined, .arena_state = .init(gpa) };
    errdefer run.arena_state.deinit();
    run.output.init(io);
    errdefer run.output.deinit();
    const a = run.arena();
    const embed_options: embed.Options = .{ .profile = &vscode.profile, .discover = options.discover, .shutdown_grace = grace };
    const ended: Io.Clock.Timestamp = switch (options.input) {
        .fixed => |bytes| ended: {
            run.input = bytes;
            var reader: Io.Reader = .fixed(bytes);
            const start: Io.Clock.Timestamp = .now(io, .awake);
            run.era = try embed.serveStdioAuto(io, gpa, server, &reader, &run.output.writer, embed_options);
            break :ended start;
        },
        .script => |steps| ended: {
            var all: std.ArrayList(u8) = .empty;
            for (steps) |s| try all.appendSlice(a, s.bytes);
            run.input = all.items;
            var script: Script = undefined;
            try script.init(io, a, steps, &run.output, server);
            run.era = try embed.serveStdioAuto(io, gpa, server, &script.reader, &run.output.writer, embed_options);
            run.marks = script.marks;
            if (script.failure) |e| {
                const step = script.steps[script.failed_step.?];
                std.debug.print("\nstep {d} did not get its frames ({t}): {f}\n", .{ script.failed_step.?, e, std.json.fmt(step.after, .{}) });
                run.frames = run.output.sync(a) catch &.{};
                run.printFrames();
                return e;
            }
            break :ended script.ended orelse {
                std.debug.print("\nthe function returned before the end of the input\n", .{});
                return error.TestEarlyReturn;
            };
        },
    };
    const elapsed = ended.durationTo(.now(io, .awake)).raw;
    run.frames = try run.output.sync(a);
    if (elapsed.nanoseconds > stop_bound.nanoseconds) {
        std.debug.print("\nthe function returned {d} ms after the end of the input\n", .{elapsed.toMilliseconds()});
        return error.TestSlowStop;
    }
    // The output holds only complete JSON-RPC lines.
    if (run.output.partialLen() != 0) {
        std.debug.print("\nthe output ends with a part of a line\n", .{});
        return error.TestPartialLine;
    }
    return run;
}

// -- Frames -------------------------------------------------------------------------------------

fn sameId(a: Value, b: Value) bool {
    return switch (a) {
        .integer => |n| b == .integer and b.integer == n,
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
        .null => b == .null,
        else => false,
    };
}

/// The index of the response with the integer id `id`, or null.
fn responseIndex(frames: []const Value, id: i64) ?usize {
    for (frames, 0..) |f, i| {
        if (f != .object or f.object.get("method") != null) continue;
        const frame_id = f.object.get("id") orelse continue;
        if (frame_id == .integer and frame_id.integer == id) return i;
    }
    return null;
}

/// The request of the bridge with the id `id`, or null.
fn bridgeRequest(frames: []const Value, id: []const u8) ?Value {
    for (frames) |f| {
        if (f != .object or f.object.get("method") == null) continue;
        const frame_id = f.object.get("id") orelse continue;
        if (frame_id == .string and std.mem.eql(u8, frame_id.string, id)) return f;
    }
    return null;
}

/// The number of frames with the method `method`.
fn methodCount(frames: []const Value, method: []const u8) usize {
    var n: usize = 0;
    for (frames) |f| {
        const m = mcp.json.getString(f, "method") orelse continue;
        n += @intFromBool(std.mem.eql(u8, m, method));
    }
    return n;
}

/// The number of listen streams of `server`.
fn subscriptionCount(server: *mcp.Server) usize {
    server.subscriptions_lock.lockUncancelable(testing.io);
    defer server.subscriptions_lock.unlock(testing.io);
    return server.subscriptions.items.len;
}

/// True when the `tools/list` result `result` has the tool `name`.
fn listed(result: Value, name: []const u8) bool {
    for (result.object.get("tools").?.array.items) |tool| {
        if (std.mem.eql(u8, tool.object.get("name").?.string, name)) return true;
    }
    return false;
}

fn expectMethods(expected: []const []const u8, actual: []const []const u8) !void {
    if (expected.len == actual.len) {
        for (expected, actual) |want, got| {
            if (!std.mem.eql(u8, want, got)) break;
        } else return;
    }
    std.debug.print("\nexpected the methods {f}, got {f}\n", .{ std.json.fmt(expected, .{}), std.json.fmt(actual, .{}) });
    return error.TestExpectedEqual;
}

/// The checks of an `initialize` result of the legacy path.
fn expectLegacyInitialize(frame: Value) !void {
    const result = try h.expectResult(frame);
    try testing.expectEqualStrings("2025-11-25", result.object.get("protocolVersion").?.string);
    try testing.expectEqualStrings(fixture.server_name, result.object.get("serverInfo").?.object.get("name").?.string);
    try testing.expect(result.object.get("capabilities").?.object.get("tools") != null);
}

/// The checks of a `server/discover` result of the server: revision 2026-07-28, and no member
/// of an `initialize` result.
fn expectDiscoverResult(frame: Value) !void {
    const result = try h.expectResult(frame);
    var modern = false;
    for (result.object.get("supportedVersions").?.array.items) |v| modern = modern or std.mem.eql(u8, v.string, "2026-07-28");
    try testing.expect(modern);
    try testing.expect(result.object.get("protocolVersion") == null);
    try testing.expect(result.object.get("serverInfo") == null);
    try testing.expectEqualStrings("The upstream server of the zig-bridge-sdk tests.", result.object.get("instructions").?.string);
}

/// The checks of a result of the modern path: the member `resultType` of revision 2026-07-28.
fn expectModernResult(frame: Value) !Value {
    const result = try h.expectResult(frame);
    try testing.expectEqualStrings("complete", result.object.get("resultType").?.string);
    return result;
}

/// The checks of the parse error of zig-sdk for a line without a known id.
fn expectParseError(frame: Value, message: []const u8) !void {
    try h.expectError(frame, -32700, message, null);
    try testing.expect(frame.object.get("id").? == .null);
}

// -- The legacy path ----------------------------------------------------------------------------

test "initialize first selects the legacy path: VS Code lists the tools and answers the form of a tool" {
    const steps = [_]Step{
        .{ .bytes = vscode_initialize },
        .{ .after = .{ .response = 1 }, .bytes = initialized },
        .{ .bytes = request("2", "tools/list", "{}") },
        .{ .after = .{ .response = 2 }, .bytes = request("3", "tools/call", "{\"name\":\"ask_form\",\"arguments\":{}}") },
        // The bridge asks VS Code for the form with the request b-1, and it gives the answer
        // to the server in the next round.
        .{ .after = .{ .bridge_request = "b-1" }, .bytes = form_answer },
        .{ .after = .{ .response = 3 } },
    };
    const run = try serve(.{ .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.legacy, run.era);
    try expectLegacyInitialize(try run.response(1));
    const tools = try h.expectResult(try run.response(2));
    try testing.expect(listed(tools, "ask_form"));
    try testing.expect(listed(tools, "add"));
    const form = bridgeRequest(run.frames, "b-1").?;
    try testing.expectEqualStrings("elicitation/create", form.object.get("method").?.string);
    try testing.expectEqualStrings("Tell us about you.", form.object.get("params").?.object.get("message").?.string);
    try testing.expectEqualStrings(form_text, try h.firstText(try h.expectResult(try run.response(3))));
    try testing.expectEqual(@as(usize, 1), methodCount(run.frames, "elicitation/create"));
    try run.verify();
    try run.expectServerStopped();
}

test "server/discover first: the server answers it without a path, and initialize then selects the legacy path" {
    const steps = [_]Step{
        .{ .bytes = modern_discover },
        .{ .after = .{ .response = 11 }, .bytes = vscode_initialize },
        .{ .after = .{ .response = 1 }, .bytes = initialized },
        .{ .bytes = legacy_add },
        .{ .after = .{ .response = 2 } },
    };
    const run = try serve(.{ .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.legacy, run.era);
    // The result of revision 2026-07-28 from the server is the first frame.
    try testing.expectEqual(@as(?usize, 0), responseIndex(run.frames, 11));
    try expectDiscoverResult(try run.response(11));
    try expectLegacyInitialize(try run.response(1));
    try testing.expectEqualStrings("5", try h.firstText(try h.expectResult(try run.response(2))));
    try run.verify();
    try run.expectServerStopped();
}

test "Discover.refuse: server/discover gets -32601, and the Copilot harness then takes the legacy path for a form" {
    const steps = [_]Step{
        .{ .bytes = request("0", "server/discover", "{\"_meta\":" ++ copilot_meta ++ "}") },
        .{ .after = .{ .response = 0 }, .bytes = request("2", "initialize", copilot_initialize_params) },
        .{ .after = .{ .response = 2 }, .bytes = initialized },
        .{ .bytes = request("5", "tools/call", "{\"name\":\"ask_form\",\"_meta\":{\"progressToken\":0}}") },
        .{ .after = .{ .bridge_request = "b-1" }, .bytes = form_answer },
        .{ .after = .{ .response = 5 } },
    };
    const run = try serve(.{ .discover = .refuse, .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.legacy, run.era);
    // The same error as the front end gives to server/discover.
    try h.expectError(try run.response(0), -32601, method_not_found_message, "method_not_found");
    try expectLegacyInitialize(try run.response(2));
    // The harness has no MRTR. On the legacy path, the bridge does the rounds for it.
    try testing.expectEqualStrings(form_text, try h.firstText(try h.expectResult(try run.response(5))));
    try run.verify();
    try run.expectServerStopped();
}

test "blank lines select no path: initialize after them selects the legacy path" {
    const steps = [_]Step{
        .{ .bytes = "\n" },
        .{ .bytes = " \t\r\n\n" },
        .{ .bytes = vscode_initialize },
        .{ .after = .{ .response = 1 } },
    };
    {
        const legacy_run = try serve(.{ .input = .{ .script = &steps } });
        defer legacy_run.destroy();
        try testing.expectEqual(Era.legacy, legacy_run.era);
        // The blank lines got no -32700. Only initialize got a response.
        try testing.expectEqual(@as(usize, 1), legacy_run.frames.len);
        try expectLegacyInitialize(try legacy_run.response(1));
        try legacy_run.verify();
    }
    // Blank lines and then the end of the input select no path.
    const run = try serve(.{ .input = .{ .fixed = "\n \t\r\n\n" } });
    defer run.destroy();
    try testing.expectEqual(Era.none, run.era);
    try testing.expectEqual(@as(usize, 0), run.output.bytes.written().len);
    try run.expectServerStopped();
}

test "a line that is too long first gets no response and selects no path" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    var limits: mcp.Limits = .{};
    limits.stdio.max_line_bytes = 2048;
    // A request of revision 2026-07-28 that is longer than the limit and than the buffer of
    // the reader. If it selected the modern path, zig-sdk would refuse initialize.
    const long = request("9", "tools/list", "{\"cursor\":\"" ++ "x" ** 10000 ++ "\"," ++ modern_meta ++ "}");
    const steps = [_]Step{
        .{ .bytes = long },
        .{ .bytes = vscode_initialize },
        .{ .after = .{ .response = 1 } },
    };
    const run = try serve(.{ .limits = limits, .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.legacy, run.era);
    try testing.expectEqual(@as(usize, 1), run.frames.len);
    try expectLegacyInitialize(try run.response(1));
    try run.verify();
}

test "two messages in one chunk: initialize and notifications/initialized" {
    // The two lines and a ping come in one read. The front end reads the lines after
    // initialize from the buffer of the same reader. It ignores a notifications/initialized
    // before the initialize result, thus the ping shows that no byte is lost.
    const steps = [_]Step{
        .{ .bytes = vscode_initialize ++ initialized ++ "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n" },
        .{ .after = .{ .response = 1 } },
        .{ .after = .{ .response = 2 } },
    };
    const run = try serve(.{ .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.legacy, run.era);
    try expectLegacyInitialize(try run.response(1));
    try testing.expect((try h.expectResult(try run.response(2))) == .object);
    // No line got an error. The notifications/initialized of this chunk can arrive after the
    // initialize result. Then it starts the listen stream, and the server sends its list
    // changes before the ping result. Thus the other frames can only be notifications.
    for (run.frames) |frame| {
        if (frame != .object) return error.UnexpectedFrame;
        if (frame.object.get("error") != null) return error.UnexpectedErrorFrame;
        if (mcp.json.getString(frame, "method")) |method| {
            try testing.expect(std.mem.startsWith(u8, method, "notifications/"));
        }
    }
    try run.verify();
}

test "notifications/initialized after the initialize result starts the listen stream before the next result" {
    // The race of the test above, in a fixed order: the notification comes after the result of
    // initialize. The listen stream then gives its list changes before the ping result.
    const steps = [_]Step{
        .{ .bytes = vscode_initialize },
        .{ .after = .{ .response = 1 }, .bytes = initialized },
        .{ .after = .{ .method = "notifications/resources/list_changed" }, .bytes = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n" },
        .{ .after = .{ .response = 2 } },
    };
    const run = try serve(.{ .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.legacy, run.era);
    try expectLegacyInitialize(try run.response(1));
    try testing.expect((try h.expectResult(try run.response(2))) == .object);
    try run.verify();
}

test "the legacy path: the list changes of the server reach VS Code over the memory link, and the end of the input with the listen stream stops at once" {
    const toggle_off = request("2", "tools/call", "{\"name\":\"toggle\",\"arguments\":{\"enabled\":false}}");
    const toggle_on = request("4", "tools/call", "{\"name\":\"toggle\",\"arguments\":{\"enabled\":true}}");
    const steps = [_]Step{
        .{ .bytes = vscode_initialize },
        .{ .after = .{ .response = 1 }, .bytes = initialized },
        // The server has the listen stream of the bridge, maybe before its acknowledgment
        // reached the bridge. The list change of the call waits for the acknowledgment.
        .{ .after = .{ .listening = true }, .bytes = toggle_off },
        // The acknowledgment gave one list change for each list.
        .{ .after = .{ .response = 2, .method = "notifications/resources/list_changed" }, .bytes = request("3", "tools/list", "{}") },
        .{ .after = .{ .response = 3 }, .bytes = toggle_on },
        // The end of the input while the listen stream is open.
        .{ .after = .{ .response = 4 } },
    };
    const run = try serve(.{ .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.legacy, run.era);
    try testing.expectEqualStrings("tool toggled: disabled", try h.firstText(try h.expectResult(try run.response(2))));
    try testing.expect(!listed(try h.expectResult(try run.response(3)), "toggled"));
    try testing.expectEqualStrings("tool toggled: enabled", try h.firstText(try h.expectResult(try run.response(4))));

    // The list change of the first call comes before its result.
    const result_index = responseIndex(run.frames, 2).?;
    try testing.expect(methodCount(run.frames[run.marks[2]..result_index], "notifications/tools/list_changed") >= 1);
    // After the acknowledgment, a call gives exactly its list change and then its result.
    try expectMethods(&.{ "notifications/tools/list_changed", "response" }, try run.methodsFrom(run.marks[4]));
    // One list change for each list at the acknowledgment, and one for each call. The bridge
    // removes the subscription id of the server.
    try testing.expectEqual(@as(usize, 3), methodCount(run.frames, "notifications/tools/list_changed"));
    try testing.expectEqual(@as(usize, 1), methodCount(run.frames, "notifications/prompts/list_changed"));
    try testing.expectEqual(@as(usize, 1), methodCount(run.frames, "notifications/resources/list_changed"));
    for (run.frames) |f| {
        if (f.object.get("method") != null and f.object.get("id") == null) try testing.expect(f.object.get("params") == null);
    }
    // `serve` checked the stop in `stop_bound`. The grace period is longer.
    try run.verify();
    try run.expectServerStopped();
}

// -- The modern path ----------------------------------------------------------------------------

test "server/discover first: the server answers it without a path, and a modern call then selects the modern path" {
    const steps = [_]Step{
        .{ .bytes = modern_discover },
        .{ .after = .{ .response = 11 }, .bytes = modern_add },
        // After the first other request, the path stays. zig-sdk does not know initialize.
        .{ .after = .{ .response = 3 }, .bytes = vscode_initialize },
        .{ .after = .{ .response = 1 } },
    };
    const run = try serve(.{ .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try expectDiscoverResult(try run.response(11));
    try testing.expectEqualStrings("5", try h.firstText(try expectModernResult(try run.response(3))));
    try h.expectError(try run.response(1), -32601, null, null);
    try testing.expectEqual(@as(usize, 3), run.frames.len);
    try run.verify();
    try run.expectServerStopped();
}

test "Discover.refuse: server/discover gets -32601 and selects no path, and a modern request then selects the modern path" {
    const steps = [_]Step{
        .{ .bytes = modern_discover },
        // A client of revision 2026-07-28 that continues without the result of
        // server/discover.
        .{ .after = .{ .response = 11 }, .bytes = modern_list },
        .{ .after = .{ .response = 2 } },
    };
    const run = try serve(.{ .discover = .refuse, .input = .{ .script = &steps } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try h.expectError(try run.response(11), -32601, method_not_found_message, "method_not_found");
    const result = try expectModernResult(try run.response(2));
    try testing.expect(listed(result, "add"));
    try testing.expectEqual(@as(usize, 2), run.frames.len);
    // `verify` checks the result against `ListToolsResultResponse` of revision 2026-07-28.
    try run.verify();
    try run.expectServerStopped();
}

test "a tools/list with the _meta of revision 2026-07-28 first selects the modern path" {
    const run = try serve(.{ .input = .{ .fixed = modern_list } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try testing.expectEqual(@as(usize, 1), run.frames.len);
    const result = try expectModernResult(try run.response(2));
    try testing.expect(listed(result, "ask_form"));
    try testing.expect(listed(result, "add"));
    try run.verify();
    try run.expectServerStopped();
}

test "the end of the input right after a modern call: the call ends in the grace period and writes its result" {
    // The fixed reader ends the input before the call ends. On the modern path, as on the stdio
    // transport of zig-sdk, a request in flight gets the grace period.
    const run = try serve(.{ .input = .{ .fixed = request("6", "tools/call", "{\"name\":\"slow\",\"arguments\":{\"ms\":300}," ++ modern_meta ++ "}") } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try testing.expectEqualStrings("slept 300 ms", try h.firstText(try expectModernResult(try run.response(6))));
    try run.verify();
    try run.expectServerStopped();
}

test "a notification first selects the modern path, also notifications/initialized" {
    const run = try serve(.{ .input = .{ .fixed = initialized ++ modern_add } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    // The notification got no response.
    try testing.expectEqual(@as(usize, 1), run.frames.len);
    try testing.expectEqualStrings("5", try h.firstText(try expectModernResult(try run.response(3))));
    try run.verify();
}

test "malformed JSON first selects the modern path, and zig-sdk answers -32700" {
    // The line has the method initialize, but it is not complete JSON.
    const run = try serve(.{ .input = .{ .fixed = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"\n" ++ modern_add } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try testing.expectEqual(@as(usize, 2), run.frames.len);
    try expectParseError(run.frames[0], "Parse error");
    try testing.expectEqualStrings("5", try h.firstText(try expectModernResult(try run.response(3))));
    try run.verify();
}

test "a line that is not valid UTF-8 first selects the modern path with the parse error of zig-sdk" {
    const bad = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"\xff\xfe\"}}}\n";
    const run = try serve(.{ .input = .{ .fixed = bad ++ modern_add } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try testing.expectEqual(@as(usize, 2), run.frames.len);
    try expectParseError(run.frames[0], "Parse error: invalid UTF-8");
    try testing.expectEqualStrings("5", try h.firstText(try expectModernResult(try run.response(3))));
    try run.verify();
}

/// A call of the tool `echo` with a text that is an `initialize` request.
const echo_initialize_head =
    \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"text":"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"},
;
const echo_initialize = echo_initialize_head ++ modern_meta ++ "}}\n";

test "initialize only in a string value selects the modern path" {
    const run = try serve(.{ .input = .{ .fixed = echo_initialize } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", try h.firstText(try expectModernResult(try run.response(4))));
    try run.verify();
}

test "the end of the input at once selects no path, writes nothing and ends the listen streams of the server" {
    const run = try serve(.{ .input = .{ .fixed = "" } });
    defer run.destroy();
    try testing.expectEqual(Era.none, run.era);
    try testing.expectEqual(@as(usize, 0), run.output.bytes.written().len);
    try run.expectServerStopped();
}

test "two messages in one chunk: server/discover and a modern call" {
    const run = try serve(.{ .input = .{ .fixed = modern_discover ++ modern_add } });
    defer run.destroy();
    try testing.expectEqual(Era.modern, run.era);
    try testing.expectEqual(@as(usize, 2), run.frames.len);
    // The server answers server/discover on the reader, before the call starts.
    try testing.expectEqual(@as(?usize, 0), responseIndex(run.frames, 11));
    try expectDiscoverResult(try run.response(11));
    try testing.expectEqualStrings("5", try h.firstText(try expectModernResult(try run.response(3))));
    try run.verify();
    try run.expectServerStopped();
}
