//! The harness of the transcript tests of the VS Code bridge. A test sends the lines of VS Code
//! to `Frontend.receive` and reads the frames of the bridge from a sink. The upstream server is
//! the fixture server in the same process. The upstream client speaks to it through the tap
//! (`Upstream.Config.transport`) and `mcp.transport.memory.ClientLink`. The tap can also give
//! scripted responses, also for `server/discover`.
//!
//! `Transcript.verify` checks each frame of the bridge against the schema of revision
//! 2025-11-25. It also checks each request to the upstream server that the tap saw against
//! the schema of revision 2026-07-28.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const vscode = @import("vscode");
const fixture = @import("fixture");
const wire = @import("wire_check.zig");

const bridge = vscode.bridge;
const Frontend = bridge.Frontend;
const Upstream = bridge.Upstream;
const Transport = mcp.transport.Transport;
const testing = std.testing;

/// The params of the `initialize` request of VS Code 1.140.0 (`mcpServerRequestHandler.ts`).
/// The capabilities have members that revision 2026-07-28 does not have: `roots.listChanged`
/// and `tasks`.
pub const vscode_initialize_params =
    \\{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}},"tasks":{"list":{},"cancel":{},"requests":{"sampling":{"createMessage":{}},"elicitation":{"create":{}}}},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}
;

/// The first request of VS Code: `initialize` with the id 1.
pub const vscode_initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":" ++ vscode_initialize_params ++ "}";

/// The notification of VS Code after the `initialize` result.
pub const initialized =
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
;

/// The URI of the view of the MCP App of the extra tools.
pub const app_view_uri = "ui://fixture/view";
/// The HTML of that view.
pub const app_view_html = "<p>The view of the fixture.</p>";
/// The URI of the text resource of the extra tools.
pub const readme_uri = "file:///fixture/readme.txt";
/// The text of that resource.
pub const readme_text = "The text of the fixture.";

/// The time that a test waits for a frame or for the end of the requests in flight.
const wait_limit: Io.Duration = .fromSeconds(10);

/// A front end, the fixture server and the frames of one transcript.
pub const Transcript = struct {
    io: Io,
    gpa: Allocator,
    server: *mcp.Server,
    /// The transport to the fixture server. The tap sends the requests through it.
    link: mcp.transport.memory.ClientLink,
    upstream: *Upstream,
    frontend: Frontend,
    tap: Tap,
    /// Holds the parsed frames and the lines of the test. Only the task of the test uses it.
    arena_state: std.heap.ArenaAllocator,
    lock: Io.Mutex = .init,
    /// The frames of the bridge in the order of the writes. Guarded by `lock`.
    frames: std.ArrayList([]u8) = .empty,
    /// The parsed frames. Only the task of the test reads and writes it.
    parsed: std.ArrayList(Value) = .empty,
    /// The requests of the test, in the order of the lines.
    sent: std.ArrayList(Sent) = .empty,

    pub const Options = struct {
        fixture: fixture.Options = .{},
        frontend: Frontend.Options = .{},
        /// Add an MCP App, a text resource and the Tasks extension to the fixture server.
        extras: bool = true,
    };

    /// One request of the test.
    const Sent = struct {
        /// The id as JSON text.
        key: []const u8,
        /// Null for a line that is not valid JSON. Such a line can get an error, but no result.
        method: ?[]const u8,
        answered: bool = false,
    };

    /// Make a transcript. Release it with `destroy`.
    pub fn create(options: Options) !*Transcript {
        const io = testing.io;
        const gpa = testing.allocator;
        const self = try gpa.create(Transcript);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .server = undefined,
            .link = undefined,
            .upstream = undefined,
            .frontend = undefined,
            .tap = .{ .io = io, .gpa = gpa },
            .arena_state = .init(gpa),
        };
        errdefer self.arena_state.deinit();
        self.server = try fixture.build(gpa, io, options.fixture);
        errdefer fixture.destroy(self.server);
        if (options.extras) try addExtras(self.server, self.arena_state.allocator());
        self.link = .init(io, gpa, self.server);
        self.tap.inner = self.link.transport();
        self.upstream = try Upstream.init(io, gpa, self.upstreamConfig());
        errdefer self.upstream.deinit();
        self.frontend = .init(io, gpa, self.upstream, &vscode.profile, .{ .ptr = self, .write = write }, options.frontend);
        return self;
    }

    pub fn destroy(self: *Transcript) void {
        self.frontend.deinit();
        self.upstream.deinit();
        fixture.destroy(self.server);
        self.tap.deinit();
        for (self.frames.items) |f| self.gpa.free(f);
        self.frames.deinit(self.gpa);
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    pub fn arena(self: *Transcript) Allocator {
        return self.arena_state.allocator();
    }

    fn write(ptr: *anyopaque, frame: []const u8) Frontend.Sink.WriteError!void {
        const self: *Transcript = @ptrCast(@alignCast(ptr));
        const copy = try self.gpa.dupe(u8, frame);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.frames.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return error.OutOfMemory;
        };
    }

    // -- Input ----------------------------------------------------------------------------------

    /// Give one line of VS Code to the front end.
    pub fn send(self: *Transcript, line: []const u8) !void {
        try self.record(line);
        try self.frontend.receive(line);
    }

    /// Send the request `method` with the id `id`. `params` is JSON text or null. Then wait
    /// for its response and for the end of the requests in flight.
    pub fn request(self: *Transcript, id: i64, method: []const u8, params: ?[]const u8) !Value {
        return self.call(id, try requestLine(self.arena(), id, method, params));
    }

    /// Send the request `method`, which the front end answers before `receive` returns.
    pub fn requestInline(self: *Transcript, id: i64, method: []const u8, params: ?[]const u8) !Value {
        return self.callInline(id, try requestLine(self.arena(), id, method, params));
    }

    /// Send a request and wait for its response and for the end of the requests in flight.
    pub fn call(self: *Transcript, id: i64, line: []const u8) !Value {
        try self.send(line);
        const frame = try self.waitResponse(id);
        try self.waitIdle();
        return frame;
    }

    /// Send a request that the front end answers on the reader, before `receive` returns.
    pub fn callInline(self: *Transcript, id: i64, line: []const u8) !Value {
        try self.send(line);
        return try self.response(id) orelse {
            std.debug.print("\nno response to {d} before receive returned\n", .{id});
            return error.TestNoInlineResponse;
        };
    }

    /// Send the `initialize` request of VS Code and `notifications/initialized`. Returns the
    /// `initialize` result.
    pub fn initialize(self: *Transcript) !Value {
        const result = try expectResult(try self.call(1, vscode_initialize));
        try self.send(initialized);
        try testing.expectEqual(Frontend.State.ready, self.frontend.state());
        return result;
    }

    /// Give `data` to `Frontend.run` through a reader with a buffer of `buffer_len` bytes.
    /// The function returns at the end of `data`, after the stop of the front end.
    pub fn runLines(self: *Transcript, data: []const u8, buffer_len: usize) !Frontend.RunResult {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len > 0) try self.record(trimmed);
        }
        const buf = try self.gpa.alloc(u8, buffer_len);
        defer self.gpa.free(buf);
        var fixed: Io.Reader = .fixed(data);
        var limited = fixed.limited(.unlimited, buf);
        return self.frontend.run(&limited.interface);
    }

    /// Keep the id and the method of a request of the test.
    fn record(self: *Transcript, line: []const u8) !void {
        const a = self.arena();
        if (mcp.json.parseTree(a, line)) |v| {
            if (v != .object) return;
            // A response or a notification of VS Code gets no response.
            const method = mcp.json.getString(v, "method") orelse return;
            const id = v.object.get("id") orelse return;
            const key = try idKey(a, id) orelse return;
            try self.sent.append(a, .{ .key = key, .method = method });
        } else |_| {
            const id = Frontend.recoverId(a, line) orelse return;
            try self.sent.append(a, .{ .key = try requestIdKey(a, id), .method = null });
        }
    }

    // -- Output ---------------------------------------------------------------------------------

    /// The number of frames of the bridge.
    pub fn count(self: *Transcript) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.frames.items.len;
    }

    /// The parsed frames of the bridge.
    pub fn parsedFrames(self: *Transcript) ![]const Value {
        try self.sync();
        return self.parsed.items;
    }

    /// The text of the frame at `index`.
    pub fn text(self: *Transcript, index: usize) []const u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.frames.items[index];
    }

    fn sync(self: *Transcript) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        while (self.parsed.items.len < self.frames.items.len) {
            const frame = self.frames.items[self.parsed.items.len];
            const v = mcp.json.parseTree(self.arena(), frame) catch |e| {
                std.debug.print("\nthe bridge wrote a frame that is not JSON: {s}\n", .{frame});
                return e;
            };
            try self.parsed.append(self.arena(), v);
        }
    }

    /// The response with the integer id `id`, or null.
    pub fn response(self: *Transcript, id: i64) !?Value {
        for (try self.parsedFrames()) |v| {
            if (v != .object or v.object.get("method") != null) continue;
            const frame_id = v.object.get("id") orelse continue;
            if (frame_id == .integer and frame_id.integer == id) return v;
        }
        return null;
    }

    /// The number of responses with the integer id `id`.
    pub fn responseCount(self: *Transcript, id: i64) !usize {
        var n: usize = 0;
        for (try self.parsedFrames()) |v| {
            if (v != .object or v.object.get("method") != null) continue;
            const frame_id = v.object.get("id") orelse continue;
            if (frame_id == .integer and frame_id.integer == id) n += 1;
        }
        return n;
    }

    /// The index of the response with the integer id `id`, or null.
    pub fn responseIndex(self: *Transcript, id: i64) !?usize {
        for (try self.parsedFrames(), 0..) |v, i| {
            if (v != .object or v.object.get("method") != null) continue;
            const frame_id = v.object.get("id") orelse continue;
            if (frame_id == .integer and frame_id.integer == id) return i;
        }
        return null;
    }

    pub fn waitResponse(self: *Transcript, id: i64) !Value {
        const until = self.deadline();
        while (true) {
            if (try self.response(id)) |v| return v;
            try self.pause(until, "a response");
        }
    }

    /// Wait until no request is in flight.
    pub fn waitIdle(self: *Transcript) !void {
        const until = self.deadline();
        while (self.frontend.inFlightCount() > 0) try self.pause(until, "the end of the requests in flight");
    }

    fn deadline(self: *Transcript) Io.Clock.Timestamp {
        return Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = wait_limit, .clock = .awake });
    }

    fn pause(self: *Transcript, until: Io.Clock.Timestamp, what: []const u8) !void {
        if (Io.Clock.Timestamp.now(self.io, .awake).durationTo(until).raw.nanoseconds <= 0) {
            std.debug.print("\nno {s} in {d} s\n", .{ what, wait_limit.toSeconds() });
            return error.TestTimeout;
        }
        try self.io.sleep(.fromMilliseconds(1), .awake);
    }

    // -- Upstream -------------------------------------------------------------------------------

    /// The upstream setting of the transcript: the tap in front of the fixture server. A test
    /// that sets a different `upstream.config` uses this value to set it back.
    pub fn upstreamConfig(self: *Transcript) Upstream.Config {
        return .{ .transport = self.tap.transport() };
    }

    /// Wait for the end of the requests in flight, and return the tap. From now on, the index
    /// 0 of the tap is the next upstream request. `verify` still checks all the requests.
    pub fn tapUpstream(self: *Transcript) !*Tap {
        try self.waitIdle();
        if (self.upstream.conn == null) return error.TestNotConnected;
        self.tap.mark();
        return &self.tap;
    }

    /// The upstream client of the connection.
    pub fn upstreamClient(self: *Transcript) !*mcp.Client {
        const conn = self.upstream.conn orelse return error.TestNotConnected;
        return &conn.client;
    }

    // -- Checks ---------------------------------------------------------------------------------

    /// Check each frame of the bridge and each request that the tap saw. Each response must
    /// belong to a request of the test, and each request gets one response at most. A result
    /// must be valid for the result definition of its method, and it must not have the
    /// members of revision 2026-07-28. The function waits for the end of the requests in
    /// flight first.
    pub fn verify(self: *Transcript) !void {
        try self.waitIdle();
        try self.sync();
        var schemas: wire.Schemas = .init(self.gpa);
        defer schemas.deinit();
        for (self.sent.items) |*s| s.answered = false;
        for (self.parsed.items, 0..) |frame, i| {
            self.checkFrame(&schemas, frame, self.text(i), i) catch |e| {
                std.debug.print("frame {d}: {s}\n", .{ i, self.text(i) });
                return e;
            };
        }
        try self.tap.verify(&schemas, self.arena());
    }

    fn checkFrame(self: *Transcript, schemas: *wire.Schemas, frame: Value, raw: []const u8, index: usize) !void {
        const a = self.arena();
        const context = try std.fmt.allocPrint(a, "frame {d}", .{index});
        if (std.mem.indexOfAny(u8, raw, "\r\n") != null) return failCheck("the frame has a line end", .{});
        if (frame != .object) return failCheck("the frame is not an object", .{});
        const version = mcp.json.getString(frame, "jsonrpc") orelse "";
        if (!std.mem.eql(u8, version, "2.0")) return failCheck("the frame has no jsonrpc 2.0", .{});
        if (frame.object.get("method")) |method| {
            // This version of the bridge sends no request to VS Code.
            if (frame.object.get("id") != null) return failCheck("the bridge sent a request", .{});
            if (method == .string and std.mem.eql(u8, method.string, "notifications/progress"))
                return schemas.check(.legacy, "ProgressNotification", frame, context);
            return failCheck("the bridge sent an unexpected notification", .{});
        }
        if (frame.object.get("result")) |result| {
            const id = frame.object.get("id") orelse return failCheck("a result without an id", .{});
            const sent = try self.answer(id) orelse return failCheck("a result for an id that VS Code did not send", .{});
            const method = sent.method orelse return failCheck("a result for a line that is not valid", .{});
            try schemas.check(.legacy, "JSONRPCResultResponse", frame, context);
            const definition = wire.resultDefinition(method) orelse return failCheck("a result for {s}", .{method});
            try schemas.check(.legacy, definition, try wire.checkedResult(a, method, result), context);
            return wire.expectLegacyResult(method, result);
        }
        if (frame.object.get("error")) |_| {
            const id = frame.object.get("id") orelse return failCheck("an error without an id member", .{});
            var envelope = frame;
            if (id == .null) {
                // JSON-RPC 2.0 wants the id null when the bridge cannot find the id. The
                // 2025-11-25 schema has no null id, but the member is optional there.
                var copy = try frame.object.clone(a);
                _ = copy.orderedRemove("id");
                envelope = .{ .object = copy };
            } else if (try self.answer(id) == null) {
                return failCheck("an error for an id that VS Code did not send, or a second response", .{});
            }
            return schemas.check(.legacy, "JSONRPCErrorResponse", envelope, context);
        }
        return failCheck("the frame is not a JSON-RPC message", .{});
    }

    /// Mark the first request with `id` that has no response, and return it.
    fn answer(self: *Transcript, id: Value) !?*Sent {
        const key = try idKey(self.arena(), id) orelse return null;
        for (self.sent.items) |*s| {
            if (s.answered or !std.mem.eql(u8, s.key, key)) continue;
            s.answered = true;
            return s;
        }
        return null;
    }
};

/// A request line of VS Code. `params` is JSON text or null.
pub fn requestLine(a: Allocator, id: i64, method: []const u8, params: ?[]const u8) Allocator.Error![]u8 {
    if (params) |p| return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p });
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
}

fn failCheck(comptime format: []const u8, args: anytype) error{TestFrameCheck} {
    std.debug.print("\n" ++ format ++ "\n", args);
    return error.TestFrameCheck;
}

/// The JSON text of an id, or null when the value is not an id.
fn idKey(a: Allocator, id: Value) Allocator.Error!?[]const u8 {
    return switch (id) {
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .number_string => |s| s,
        .string => |s| try std.fmt.allocPrint(a, "\"{s}\"", .{s}),
        else => null,
    };
}

fn requestIdKey(a: Allocator, id: mcp.RequestId) Allocator.Error![]const u8 {
    return switch (id) {
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .big => |digits| digits,
        .string => |s| try std.fmt.allocPrint(a, "\"{s}\"", .{s}),
    };
}

/// The client transport of the upstream client. It keeps a copy of each request. In the mode
/// `forward`, the tap sends each request to the fixture server. In the other modes, the tap
/// gives a scripted outcome and does not use the server.
pub const Tap = struct {
    io: Io,
    gpa: Allocator,
    /// The transport to the fixture server.
    inner: Transport.ClientTransport = undefined,
    lock: Io.Mutex = .init,
    /// Guarded by `lock`.
    script: Script = .forward,
    /// The requests in the order of their start. Guarded by `lock`.
    exchanges: std.ArrayList(Exchange) = .empty,
    /// The index in `exchanges` of the request with the index 0 of `count`, `exchange` and
    /// `request`. Guarded by `lock`.
    base: usize = 0,

    /// What the tap does with the next requests.
    pub const Script = union(enum) {
        /// Send the request to the fixture server.
        forward,
        /// Answer with this result object, as JSON text.
        result: []const u8,
        /// Answer with this error object, as JSON text.
        rpc_error: []const u8,
        /// Fail the exchange with this error.
        fail: Transport.ExchangeError,
        /// Wait for the cancellation or for the time limit of the request.
        wait,
    };

    /// One request to the upstream server.
    pub const Exchange = struct {
        /// The request frame. The tap owns it.
        frame: []u8,
        /// The error of the exchange, or null for a response.
        outcome: ?Transport.ExchangeError = null,
        done: bool = false,
    };

    fn deinit(self: *Tap) void {
        for (self.exchanges.items) |e| self.gpa.free(e.frame);
        self.exchanges.deinit(self.gpa);
    }

    pub fn setScript(self: *Tap, script: Script) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.script = script;
    }

    /// Count the requests from now on.
    fn mark(self: *Tap) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.base = self.exchanges.items.len;
    }

    /// The number of requests that started after the last `Transcript.tapUpstream`.
    pub fn count(self: *Tap) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.exchanges.items.len - self.base;
    }

    /// A copy of the request at `index`, from the last `Transcript.tapUpstream`.
    pub fn exchange(self: *Tap, index: usize) Exchange {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.exchanges.items[self.base + index];
    }

    /// The request at `index`, parsed in `a`.
    pub fn request(self: *Tap, a: Allocator, index: usize) !Value {
        return mcp.json.parseTree(a, self.exchange(index).frame);
    }

    /// Wait until `n` requests started.
    pub fn waitStarted(self: *Tap, n: usize) !void {
        const deadline = Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = wait_limit, .clock = .awake });
        while (self.count() < n) {
            if (Io.Clock.Timestamp.now(self.io, .awake).durationTo(deadline).raw.nanoseconds <= 0) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn transport(self: *Tap) Transport.ClientTransport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // The tap stands for the memory transport to the fixture server, thus it has its kind.
    const vtable: Transport.ClientTransport.VTable = .{ .kind = .memory, .exchange = onExchange, .notify = onNotify };

    fn onExchange(ptr: *anyopaque, io: Io, ex: *Transport.Exchange) Transport.ExchangeError!void {
        const self: *Tap = @ptrCast(@alignCast(ptr));
        const copy = self.gpa.dupe(u8, ex.frame) catch return error.OutOfMemory;
        const index, const script = begin: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.exchanges.append(self.gpa, .{ .frame = copy }) catch {
                self.gpa.free(copy);
                return error.OutOfMemory;
            };
            break :begin .{ self.exchanges.items.len - 1, self.script };
        };
        const result = self.run(io, ex, script);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.exchanges.items[index].outcome = if (result) |_| null else |e| e;
        self.exchanges.items[index].done = true;
        return result;
    }

    fn run(self: *Tap, io: Io, ex: *Transport.Exchange, script: Script) Transport.ExchangeError!void {
        switch (script) {
            .forward => return self.inner.exchange(io, ex),
            .result => |body| return self.respond(io, ex, "result", body),
            .rpc_error => |body| return self.respond(io, ex, "error", body),
            .fail => |e| return e,
            .wait => while (true) {
                if (ex.cancel.isCancelled()) return error.Canceled;
                if (ex.expired(io)) return error.Timeout;
                try io.sleep(.fromMilliseconds(2), .awake);
            },
        }
    }

    fn respond(self: *Tap, io: Io, ex: *Transport.Exchange, member: []const u8, body: []const u8) Transport.ExchangeError!void {
        const id = mcp.json.writeAlloc(self.gpa, ex.id) catch return error.OutOfMemory;
        defer self.gpa.free(id);
        const frame = std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"{s}\":{s}}}", .{ id, member, body }) catch return error.OutOfMemory;
        defer self.gpa.free(frame);
        ex.deliver(io, frame) catch return error.InvalidFrame;
    }

    fn onNotify(ptr: *anyopaque, io: Io, frame: []const u8) Transport.SendError!void {
        const self: *Tap = @ptrCast(@alignCast(ptr));
        return self.inner.notify(io, frame);
    }

    fn verify(self: *Tap, schemas: *wire.Schemas, a: Allocator) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.exchanges.items, 0..) |e, i| {
            const context = try std.fmt.allocPrint(a, "upstream request {d}", .{i});
            errdefer std.debug.print("{s}: {s}\n", .{ context, e.frame });
            const v = try mcp.json.parseTree(a, e.frame);
            const method = mcp.json.getString(v, "method") orelse return failCheck("an upstream request without a method", .{});
            const definition = wire.upstreamRequestDefinition(method) orelse return failCheck("an upstream request {s}", .{method});
            try schemas.check(.modern, definition, v, context);
            try wire.expectUpstreamRequest(method, v);
        }
    }
};

// -- Fixture extras ---------------------------------------------------------------------------

/// Add an MCP App, a text resource and the Tasks extension to the fixture server. The server
/// declares the Tasks extension, but the bridge must not declare it to VS Code.
fn addExtras(server: *mcp.Server, a: Allocator) !void {
    server.options.apps = .{};
    var extensions: std.json.ObjectMap = .empty;
    try extensions.put(a, mcp.apps.extension_id, .{ .object = .empty });
    try extensions.put(a, mcp.tasks.extension_id, .{ .object = .empty });
    server.options.capabilities.extensions = .{ .object = extensions };
    try server.addUiResource(.{ .uri = app_view_uri, .name = "view", .description = "The view of the tool show" }, app_view_html);
    try server.addToolJson(.{
        .name = "show",
        .description = "Show the view of the fixture",
        .ui = .{ .resourceUri = app_view_uri },
    }, show);
    try server.addResource(.{ .uri = readme_uri, .name = "readme", .mime_type = "text/plain" }, readReadme);
}

fn show(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "shown", .{}) };
}

fn readReadme(ctx: *mcp.RequestContext, uri: []const u8) anyerror!mcp.Outcome(mcp.ReadResourceResult) {
    const contents = try ctx.arena.alloc(mcp.types.ResourceContents, 1);
    contents[0] = .{ .text = .{ .uri = uri, .mimeType = "text/plain", .text = readme_text } };
    return .{ .complete = .{ .contents = contents } };
}

// -- Assertions -------------------------------------------------------------------------------

/// The `result` of a response. Fails for an error response.
pub fn expectResult(frame: Value) !Value {
    if (frame.object.get("result")) |r| return r;
    std.debug.print("\nexpected a result, got: {f}\n", .{std.json.fmt(frame, .{})});
    return error.TestExpectedResult;
}

/// Check the code of an error response. A message and a cause that are not null must also
/// be equal.
pub fn expectError(frame: Value, code: i64, message: ?[]const u8, cause: ?[]const u8) !void {
    const err = frame.object.get("error") orelse {
        std.debug.print("\nexpected an error, got: {f}\n", .{std.json.fmt(frame, .{})});
        return error.TestExpectedError;
    };
    try testing.expectEqual(code, err.object.get("code").?.integer);
    if (message) |m| try testing.expectEqualStrings(m, err.object.get("message").?.string);
    if (cause) |c| {
        const data = err.object.get("data") orelse return error.TestExpectedData;
        try testing.expectEqualStrings(c, data.object.get("cause").?.string);
    }
}

/// The `data.detail` of an error response, or null.
pub fn errorDetail(frame: Value) ?[]const u8 {
    const err = frame.object.get("error") orelse return null;
    const data = err.object.get("data") orelse return null;
    if (data != .object) return null;
    return mcp.json.getString(data, "detail");
}

/// The text of the first content block of a `tools/call` result.
pub fn firstText(result: Value) ![]const u8 {
    const content = result.object.get("content") orelse return error.TestNoContent;
    if (content.array.items.len == 0) return error.TestNoContent;
    return content.array.items[0].object.get("text").?.string;
}

/// Hide the warnings that a test expects. Restore the level with the return value.
pub fn quiet() std.log.Level {
    const saved = testing.log_level;
    testing.log_level = .err;
    return saved;
}
