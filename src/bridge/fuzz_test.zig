//! The fuzz targets of the core module. A target must never crash. An error is the correct
//! result for bad input. `zig build test -Dfuzz --fuzz` examines the targets, and the plain
//! test run executes each target one time with its corpus.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Smith = std.testing.Smith;
const mcp = @import("mcp");
const bridge = @import("../bridge.zig");
const legacy = bridge.legacy;
const translate = bridge.translate;
const Frontend = bridge.Frontend;
const Upstream = bridge.Upstream;

const max_input = 2048;

const profile: bridge.Profile = .{ .name = "mcp-bridge-fuzz", .quirks = .{ .normalize_array_items = true, .drop_non_object_output_schema = true } };
const strict_profile: bridge.Profile = .{ .name = "mcp-bridge-fuzz", .quirks = .{ .strict_legacy_results = true } };

fn input(smith: *Smith, buf: *[max_input]u8, hash: u32) []u8 {
    const n = smith.sliceWithHash(buf, hash);
    return buf[0..n];
}

// ---------------------------------------------------------------------------------------------
// The parsers of the legacy requests
// ---------------------------------------------------------------------------------------------

fn legacyParams(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const bytes = input(smith, &buf, 0x3001);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = legacy.classify(bytes);
    _ = legacy.classifyNotification(bytes);
    const params: ?Value = mcp.json.parseTree(arena, bytes) catch null;
    _ = legacy.hasModernMeta(params);
    if (legacy.parseInitializeParams(arena, params)) |p| {
        // The parsed capabilities go upstream. The mask of the bridge never adds a kind.
        const caps = try translate.upstreamCapabilities(arena, p.capabilities, .{});
        try std.testing.expect(caps.sampling == null and caps.elicitation == null and caps.roots == null);
        _ = try translate.upstreamCapabilities(arena, p.capabilities, .{ .sampling = true, .elicitation = true, .roots = true });
    } else |_| {}
    _ = legacy.parseSetLevelParams(arena, params) catch {};
    _ = legacy.parseCancelledParams(arena, params) catch {};
}

test "fuzz: the parsers of the legacy requests" {
    try std.testing.fuzz({}, legacyParams, .{ .corpus = &.{
        \\{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}},"tasks":{"list":{}},"extensions":{"io.modelcontextprotocol/ui":{}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}
        ,
        \\{"level":"debug"}
        ,
        \\{"requestId":7,"reason":"x"}
        ,
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}
        ,
        "tools/call",
    } });
}

// ---------------------------------------------------------------------------------------------
// The translation of results
// ---------------------------------------------------------------------------------------------

/// The methods of the results that `shapeResult` changes.
const result_methods = [_][]const u8{ "tools/list", "tools/call", "prompts/list", "prompts/get", "resources/list", "resources/read", "resources/templates/list", "completion/complete" };

fn translateValues(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const bytes = input(smith, &buf, 0x3002);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = mcp.json.parseTree(arena, bytes) catch return;

    const init_result = try translate.initializeResult(arena, value, .{ .profile = &profile, .fallback_name = "" });
    // The result always has a server name.
    const info = init_result.object.get("serverInfo").?;
    try std.testing.expect(mcp.json.getString(info, "name").?.len > 0);
    _ = try mcp.json.writeAlloc(arena, init_result);

    const fwd = try translate.forwardParams(arena, value, &profile);
    try std.testing.expect(fwd.params == .object);
    try std.testing.expect(fwd.params.object.get("_meta") == null);
    try std.testing.expect(fwd.params.object.get("task") == null);
    _ = translate.isInputRequired(value);

    for (result_methods) |method| {
        // `shapeResult` changes its value, thus each method gets its own copy.
        const raw = mcp.json.parseTree(arena, bytes) catch unreachable;
        const shaped = try translate.shapeResult(arena, method, raw, &profile);
        if (shaped.result == .object) {
            const object = shaped.result.object;
            for ([_][]const u8{ "resultType", "ttlMs", "cacheScope" }) |key| try std.testing.expect(object.get(key) == null);
            if (legacy.isListMethod(method)) if (object.get("nextCursor")) |cursor| try std.testing.expect(cursor == .string);
        }
        _ = try mcp.json.writeAlloc(arena, translate.strictLegacyResult(method, shaped.result, &strict_profile));
    }
}

test "fuzz: the translation of results" {
    try std.testing.fuzz({}, translateValues, .{ .corpus = &.{
        \\{"resultType":"complete","ttlMs":5,"tools":[{"name":"t","inputSchema":{"type":"object","properties":{"a":{"type":"array"},"b":{"type":"array","prefixItems":[{}],"items":false}}}}],"nextCursor":null,"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"s","version":"1"}}}
        ,
        \\{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true},"logging":{},"extensions":{"io.modelcontextprotocol/tasks":{}}},"instructions":"x"}
        ,
        \\{"content":[],"structuredContent":[1,2],"_meta":{"progressToken":0},"task":{}}
        ,
        \\{"resultType":"input_required","inputRequests":{},"requestState":"s"}
        ,
        "[]",
    } });
}

// ---------------------------------------------------------------------------------------------
// The line reader and the id recovery
// ---------------------------------------------------------------------------------------------

fn lineReader(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const bytes = input(smith, &buf, 0x3003);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = Frontend.recoverId(arena, bytes);
    _ = Frontend.recoverTrailingId(bytes);
    // A small buffer and a small limit examine the slow path and the lines that are too long.
    var fixed: Io.Reader = .fixed(bytes);
    var reader_buf: [16]u8 = undefined;
    var limited = fixed.limited(.unlimited, &reader_buf);
    var reader: Frontend.LineReader = .{ .reader = &limited.interface, .max_line_bytes = 64 };
    var lines: usize = 0;
    while (lines <= bytes.len) : (lines += 1) {
        switch (try reader.next(arena)) {
            .eof => return,
            .line => |l| {
                try std.testing.expect(l.len <= 64);
                _ = Frontend.recoverId(arena, l);
            },
            .too_long => |long| {
                try std.testing.expect(long.head.len <= Frontend.LineReader.head_bytes);
                try std.testing.expect(long.tail.len <= Frontend.LineReader.tail_bytes);
                _ = Frontend.recoverLongLineId(arena, long);
            },
            .invalid_utf8 => |l| try std.testing.expect(!std.unicode.utf8ValidateSlice(l)),
        }
    }
    return error.TestTooManyLines;
}

test "fuzz: the line reader and the id recovery" {
    try std.testing.fuzz({}, lineReader, .{
        .corpus = &.{
            "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"x\":\"" ++ "y" ** 80 ++ "\"}}\n{\"id\":\"b-1\"}\r\n\n",
            "{\"params\":{\"id\":5},\"id\":\"a\\\"b\"}\n\xff\xfe\nlast",
            "{\"id\":123456789012345678901234567890",
            // The order of the members of the TypeScript SDK 1.x: the id comes last.
            "{\"method\":\"tools/call\",\"params\":{\"x\":\"" ++ "y" ** 80 ++ "\"},\"jsonrpc\":\"2.0\",\"id\":7}\r\n",
        },
    });
}

// ---------------------------------------------------------------------------------------------
// The front end
// ---------------------------------------------------------------------------------------------

/// The `initialize` request of the front end target.
const initialize_line =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fuzz","version":"1"}}}
;

/// The limits of the front end target. They are small, thus the target reaches the errors.
const fuzz_options: Frontend.Options = .{
    .max_line_bytes = 256,
    .json_max_depth = 16,
    .max_in_flight_requests = 4,
    .shutdown_grace = .fromSeconds(2),
    .discover_timeout = .fromSeconds(5),
    .timeouts = .{ .list = .fromSeconds(5), .read = .fromSeconds(5), .call = .fromSeconds(5) },
};

/// Collects the frames of the front end.
const Frames = struct {
    io: Io,
    gpa: Allocator,
    lock: Io.Mutex = .init,
    list: std.ArrayList([]u8) = .empty,

    fn write(ptr: *anyopaque, frame: []const u8) Frontend.Sink.WriteError!void {
        const self: *Frames = @ptrCast(@alignCast(ptr));
        const copy = try self.gpa.dupe(u8, frame);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.list.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return error.OutOfMemory;
        };
    }

    fn deinit(self: *Frames) void {
        for (self.list.items) |f| self.gpa.free(f);
        self.list.deinit(self.gpa);
    }
};

const EchoArgs = struct { text: []const u8 };

fn echo(ctx: *mcp.RequestContext, args: EchoArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    try ctx.checkCancel();
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{s}", .{args.text}) };
}

/// The JSON text of an id. Equal ids have equal texts.
fn idKey(arena: Allocator, id: mcp.RequestId) Allocator.Error![]const u8 {
    return mcp.json.writeAlloc(arena, id);
}

/// The id that can get a response for `line`. The rules are those of the front end. A request
/// gives its id. A line that is not valid gives the id in its text. A line with the id of a
/// request of the bridge gives no id.
fn expectedId(arena: Allocator, line: []const u8) Allocator.Error!?mcp.RequestId {
    const depth = @min(fuzz_options.json_max_depth, mcp.json.max_message_depth);
    const recovered = recovered: {
        if (line.len > fuzz_options.max_line_bytes) break :recovered Frontend.recoverLongLineId(arena, .of(line));
        if (!std.unicode.utf8ValidateSlice(line)) break :recovered Frontend.recoverId(arena, line);
        const msg = mcp.jsonrpc.Message.parseMaxDepth(arena, line, depth) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :recovered Frontend.recoverId(arena, line),
        };
        return switch (msg) {
            .request => |r| r.id,
            else => null,
        };
    };
    const id = recovered orelse return null;
    if (id == .string and std.mem.startsWith(u8, id.string, profile.request_id_prefix)) return null;
    return id;
}

/// Count `key` one more time in `counts`.
fn bump(arena: Allocator, counts: *std.StringHashMapUnmanaged(usize), key: []const u8) Allocator.Error!void {
    const entry = try counts.getOrPut(arena, key);
    entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
}

/// The first byte of the input selects an `initialize` before the lines. The other bytes are
/// the lines of the client. The upstream server is an `mcp.Server` in this process. After the
/// stop of the front end, the target examines the frames:
///
/// - Each frame is one JSON-RPC message.
/// - The bridge sends no request.
/// - An id gets no more responses than requests with that id. Thus a response of the client,
///   for example to a `b-` id, gets no frame.
fn frontendLines(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const bytes = input(smith, &buf, 0x3004);
    const gpa = std.testing.allocator;
    // The test runner does not make `std.testing.io` for a fuzz run, thus the target makes its
    // own `Io`.
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // The front end writes warnings for some lines. They are correct results here.
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const server = try gpa.create(mcp.Server);
    defer gpa.destroy(server);
    server.* = try mcp.Server.init(gpa, io, .{ .info = .{ .name = "fuzz-upstream", .version = "1.0.0" } });
    defer server.deinit();
    try server.addTool(.{ .name = "echo", .description = "Send the text back" }, echo);
    const upstream = try Upstream.init(io, gpa, .{ .memory = server });
    defer upstream.deinit();
    var frames: Frames = .{ .io = io, .gpa = gpa };
    defer frames.deinit();

    // The number of requests for each id. Only these ids can get a response.
    var requests: std.StringHashMapUnmanaged(usize) = .empty;
    {
        var frontend: Frontend = .init(io, gpa, upstream, &profile, .{ .ptr = &frames, .write = Frames.write }, fuzz_options);
        defer frontend.deinit();
        const lines = if (bytes.len > 0) bytes[1..] else bytes;
        if (bytes.len > 0 and bytes[0] & 1 == 1) {
            try bump(arena, &requests, "1");
            try frontend.receive(initialize_line);
            var waits: usize = 0;
            while (frontend.state() == .initializing) : (waits += 1) {
                if (waits > 5000) return error.TestTimeout;
                try io.sleep(.fromMilliseconds(1), .awake);
            }
        }
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try frontend.receive(line);
            if (try expectedId(arena, line)) |id| try bump(arena, &requests, try idKey(arena, id));
        }
    }

    var responses: std.StringHashMapUnmanaged(usize) = .empty;
    for (frames.list.items) |frame| {
        try std.testing.expect(std.mem.indexOfAny(u8, frame, "\r\n") == null);
        const msg = mcp.jsonrpc.Message.parse(arena, frame) catch |e| {
            std.debug.print("\nthe bridge wrote a frame that is not a JSON-RPC message ({t}): {s}\n", .{ e, frame });
            return e;
        };
        const id: ?mcp.RequestId = switch (msg) {
            .request => return error.TestBridgeSentRequest,
            .notification => |n| {
                try std.testing.expectEqualStrings("notifications/progress", n.method);
                continue;
            },
            .response => |r| r.id,
            .error_response => |e| e.id,
        };
        const key = try idKey(arena, id orelse continue);
        try bump(arena, &responses, key);
        const allowed = requests.get(key) orelse 0;
        if (responses.get(key).? > allowed) {
            std.debug.print("\nthe id {s} has more responses than requests: {s}\n", .{ key, frame });
            return error.TestTooManyResponses;
        }
    }
}

test "fuzz: the lines of the client through the front end" {
    try std.testing.fuzz({}, frontendLines, .{
        .corpus = &.{
            "\x01{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"progressToken\":0}}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"a\"}}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":3}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"cancel\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}",
            "\x00{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"info\"}}",
            "\x01{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"text\":\"a\\ud800\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"x\",\"params\":[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":\"b-2\",\"error\":{\"code\":1,\"message\":\"\\udc00\"}}\n" ++
                "\xff{\"id\":7}\n{\"jsonrpc\":\"2.0\",\"id\":8}\n{\"id\":9.5,\"method\":\"ping\"}",
            // A string id with bytes that are not UTF-8 and a control character.
            "\x00{\"jsonrpc\":\"2.0\",\"id\":\"\xb3\xe3\x1c\xb6rpc\",\"method\":\"x\"}\n{\"id\":\"a\x01\"}",
            // A line that is too long, with the id last as the TypeScript SDK 1.x writes it.
            "\x01{\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"" ++ "a" ** 300 ++ "\"}},\"jsonrpc\":\"2.0\",\"id\":9}",
        },
    });
}
