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

/// The corpus of a target that reads one slice with `input`. `Smith` reads the length of a
/// slice as a 32-bit little-endian integer before its bytes. Thus each entry gets its length
/// as a prefix. Without the prefix, `Smith` reads the first four bytes of the entry as the
/// length.
fn corpus(comptime entries: []const []const u8) []const []const u8 {
    const out = comptime out: {
        var list: [entries.len][]const u8 = undefined;
        for (entries, &list) |entry, *item| {
            var prefix: [4]u8 = undefined;
            std.mem.writeInt(u32, &prefix, entry.len, .little);
            const prefixed = prefix ++ entry[0..entry.len].*;
            item.* = &prefixed;
        }
        break :out list;
    };
    return &out;
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
        // The parsed capabilities go upstream. The bridge never adds a kind or a member of
        // sampling that the client did not declare.
        const caps = try translate.upstreamCapabilities(arena, p.capabilities, .{});
        const declared: ?Value = if (p.capabilities == .object) p.capabilities else null;
        const sampling: ?Value = if (declared) |d| d.object.get("sampling") else null;
        if (sampling == null) try std.testing.expect(caps.sampling == null);
        if (caps.sampling) |s| {
            if (s.tools != null) try std.testing.expect(mcp.json.hasKey(sampling.?, "tools"));
            if (s.context != null) try std.testing.expect(mcp.json.hasKey(sampling.?, "context"));
        }
        if (declared == null or declared.?.object.get("elicitation") == null) try std.testing.expect(caps.elicitation == null);
        if (declared == null or declared.?.object.get("roots") == null) try std.testing.expect(caps.roots == null);
        const none = try translate.upstreamCapabilities(arena, p.capabilities, .{ .sampling = false, .elicitation = false, .roots = false });
        try std.testing.expect(none.sampling == null and none.elicitation == null and none.roots == null);
    } else |_| {}
    _ = legacy.parseSetLevelParams(arena, params) catch {};
    _ = legacy.parseCancelledParams(arena, params) catch {};
}

test "fuzz: the parsers of the legacy requests" {
    try std.testing.fuzz({}, legacyParams, .{ .corpus = corpus(&.{
        \\{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}},"tasks":{"list":{}},"extensions":{"io.modelcontextprotocol/ui":{}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}
        ,
        \\{"level":"debug"}
        ,
        \\{"requestId":7,"reason":"x"}
        ,
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}
        ,
        "tools/call",
    }) });
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
    // For a remote upstream server, the server information has only data icons.
    const remote = try translate.initializeResult(arena, value, .{ .profile = &profile, .fallback_name = "", .icons = .data_only });
    try expectDataIcons(remote.object.get("serverInfo").?);

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
        // The icon rule of a remote upstream server keeps only data icons in the items.
        var remote_result = try translate.shapeResult(arena, method, mcp.json.parseTree(arena, bytes) catch unreachable, &profile);
        translate.filterIcons(method, &remote_result.result, .data_only);
        if (remote_result.result == .object) if (iconMember(method)) |member| if (remote_result.result.object.get(member)) |items| if (items == .array) {
            for (items.array.items) |item| {
                const is_link = std.mem.eql(u8, mcp.json.getString(item, "type") orelse "", "resource_link");
                if (!std.mem.eql(u8, member, "content") or is_link) try expectDataIcons(item);
            }
        };
        _ = try mcp.json.writeAlloc(arena, remote_result.result);
    }
}

/// The member of a result of `method` whose items `translate.filterIcons` examines, or null.
fn iconMember(method: []const u8) ?[]const u8 {
    const members = [_]struct { []const u8, []const u8 }{
        .{ "tools/list", "tools" },
        .{ "prompts/list", "prompts" },
        .{ "resources/list", "resources" },
        .{ "resources/templates/list", "resourceTemplates" },
        .{ "tools/call", "content" },
    };
    for (members) |m| if (std.mem.eql(u8, m[0], method)) return m[1];
    return null;
}

/// Check that each icon of `holder` has a `data:` URI, and that `icons` is not empty.
fn expectDataIcons(holder: Value) !void {
    if (holder != .object) return;
    const icons = holder.object.get("icons") orelse return;
    try std.testing.expect(icons == .array and icons.array.items.len > 0);
    for (icons.array.items) |icon| {
        try std.testing.expect(std.ascii.startsWithIgnoreCase(mcp.json.getString(icon, "src") orelse "", "data:"));
    }
}

test "fuzz: the translation of results" {
    try std.testing.fuzz({}, translateValues, .{ .corpus = corpus(&.{
        \\{"resultType":"complete","ttlMs":5,"tools":[{"name":"t","inputSchema":{"type":"object","properties":{"a":{"type":"array"},"b":{"type":"array","prefixItems":[{}],"items":false}}}}],"nextCursor":null,"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"s","version":"1"}}}
        ,
        \\{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":true},"logging":{},"extensions":{"io.modelcontextprotocol/tasks":{}}},"instructions":"x"}
        ,
        \\{"content":[],"structuredContent":[1,2],"_meta":{"progressToken":0},"task":{}}
        ,
        \\{"resultType":"input_required","inputRequests":{},"requestState":"s"}
        ,
        "[]",
    }) });
}

// ---------------------------------------------------------------------------------------------
// The input requests
// ---------------------------------------------------------------------------------------------

const inputs = bridge.input;

/// The bytes are an input request, an answer of the client and a URL. The checks never send a
/// `task`, an accepted URL never gives content upstream, and a failure is always -32603 or an
/// error of the client.
fn inputValues(_: void, smith: *Smith) anyerror!void {
    var buf: [max_input]u8 = undefined;
    const bytes = input(smith, &buf, 0x3005);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A web browser reads a backslash as the end of the host. Thus an allowed URL has none.
    if (inputs.urlAllowed(bytes)) try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\\') == null);
    const value = mcp.json.parseTree(arena, bytes) catch return;
    const caps = try translate.upstreamCapabilities(arena, try mcp.json.parseTree(arena,
        \\{"roots":{},"sampling":{},"elicitation":{"form":{},"url":{}}}
    ), .{});
    _ = inputs.asksForUrl(value, "https://example.com/");
    _ = try mcp.json.writeAlloc(arena, try inputs.continueAnswer(arena, .{ .result = value }));
    _ = try mcp.json.writeAlloc(arena, try inputs.retryParams(arena, value, .{ .input_responses = value, .request_state = "s" }));
    const checked = switch (try inputs.check(arena, caps, "k", value, .{})) {
        .fail => |e| return std.testing.expectEqual(@as(i64, -32603), e.code),
        .ok => |c| c,
    };
    if (checked.params) |p| try std.testing.expect(p.object.get("task") == null);
    const answers = [_]inputs.Answer{ .{ .result = value }, .bad_line, .{ .rpc_error = .{ .code = -32000, .message = "refused" } } };
    for (answers) |answer| switch (try inputs.shapeAnswer(arena, "k", &checked, answer)) {
        .fail => |e| try std.testing.expect(e.code == -32603 or e.code == -32000),
        .value => |v| {
            if (checked.kind == .elicitation_url) try std.testing.expect(v.object.get("content") == null);
            _ = try mcp.json.writeAlloc(arena, v);
        },
    };
}

test "fuzz: the checks of the input requests and of the answers" {
    try std.testing.fuzz({}, inputValues, .{
        .corpus = corpus(&.{
            \\{"method":"elicitation/create","params":{"mode":"form","message":"m","requestedSchema":{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer","minimum":0},"c":{"type":"boolean"},"d":{"type":"string","enum":["x","y"]}},"required":["a"]}},"action":"accept","content":{"a":"v"}}
            ,
            \\{"method":"elicitation/create","params":{"mode":"url","message":"m","url":"https://example.com/"},"action":"accept","content":{"x":1}}
            ,
            \\{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"t"}}],"maxTokens":5,"tools":[]},"role":"assistant","content":{"type":"text","text":"t"},"model":"m"}
            ,
            \\{"method":"roots/list","task":{},"roots":[{"uri":"file:///a"},{"uri":"x:/b"}]}
            ,
            "http://[::ffff:127.0.0.1]:80/",
            "file://localhost/etc/passwd",
            // A web browser reads the host evil.com.
            "http://evil.com\\@localhost/",
            "http://evil.com\\@127.0.0.1/",
        }),
    });
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
        .corpus = corpus(&.{
            "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"x\":\"" ++ "y" ** 80 ++ "\"}}\n{\"id\":\"b-1\"}\r\n\n",
            "{\"params\":{\"id\":5},\"id\":\"a\\\"b\"}\n\xff\xfe\nlast",
            "{\"id\":123456789012345678901234567890",
            // The order of the members of the TypeScript SDK 1.x: the id comes last.
            "{\"method\":\"tools/call\",\"params\":{\"x\":\"" ++ "y" ** 80 ++ "\"},\"jsonrpc\":\"2.0\",\"id\":7}\r\n",
        }),
    });
}

// ---------------------------------------------------------------------------------------------
// The front end
// ---------------------------------------------------------------------------------------------

/// The `initialize` request of the front end target. The client declares the form mode, thus
/// the tool `ask` sends its form to the client.
const initialize_line =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{"form":{}}},"clientInfo":{"name":"fuzz","version":"1"}}}
;

/// The limits of the front end target. They are small, thus the target reaches the errors.
const fuzz_options: Frontend.Options = .{
    .max_line_bytes = 256,
    .json_max_depth = 16,
    .max_in_flight_requests = 4,
    .shutdown_grace = .fromSeconds(2),
    .discover_timeout = .fromSeconds(5),
    .timeouts = .{ .list = .fromSeconds(5), .read = .fromSeconds(5), .call = .fromSeconds(5), .input = .fromSeconds(5) },
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

/// The text resource of the front end target. A line can subscribe to it, and the tool `touch`
/// tells the listen streams that it changed.
const fuzz_uri = "file:///fuzz.txt";

fn readFuzz(ctx: *mcp.RequestContext, uri: []const u8) anyerror!mcp.Outcome(mcp.ReadResourceResult) {
    const contents = try ctx.arena.alloc(mcp.types.ResourceContents, 1);
    contents[0] = .{ .text = .{ .uri = uri, .text = "fuzz" } };
    return .{ .complete = .{ .contents = contents } };
}

fn touch(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    ctx.server.notifyResourceUpdated(ctx.io, fuzz_uri);
    _ = ctx.server.setToolEnabled(ctx.io, "echo", true);
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "touched", .{}) };
}

/// Ask for a name in a form, then send the action and the name back. The bridge sends the
/// form to the client as a request with a `b-` id, thus the lines of the client can answer
/// it.
fn ask(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.elicitResponse("name")) |a| {
        const name = if (a.content) |c| mcp.json.getString(c, "name") orelse "nobody" else "nobody";
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{t}: {s}", .{ a.action, name }) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitForm("name", "Name?", try mcp.InputRequired.stringSchema(ctx.arena, "name", null, true));
    return .{ .input_required = ir };
}

/// Wait until each request in flight waits for the answers of the client, at most one
/// second. Then the requests of the bridge for the last line are in the pending table, and
/// the next line of the client can answer them.
fn settle(io: Io, frontend: *Frontend) Io.Cancelable!void {
    var waits: usize = 0;
    while (frontend.inFlightCount() > frontend.waitingForClientCount() and waits < 1000) : (waits += 1) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
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
/// - The only request of the bridge is the form of the tool `ask`, with a `b-` id.
/// - The bridge cancels only a request that it sent before.
/// - An id gets no more responses than requests with that id. Thus a response of the client,
///   for example to a `b-` id, gets no frame.
///
/// After each line, the target waits until each request in flight waits for the client
/// (`settle`). Thus an answer of the client can reach the pending table.
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
    try server.addToolJson(.{ .name = "ask", .description = "Ask for a name" }, ask);
    try server.addToolJson(.{ .name = "touch", .description = "Change the resource" }, touch);
    try server.addResource(.{ .uri = fuzz_uri, .name = "fuzz" }, readFuzz);
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
            try settle(io, &frontend);
        }
    }

    var responses: std.StringHashMapUnmanaged(usize) = .empty;
    // The ids of the requests of the bridge, in the order of the frames.
    var asked: std.StringHashMapUnmanaged(void) = .empty;
    for (frames.list.items) |frame| {
        try std.testing.expect(std.mem.indexOfAny(u8, frame, "\r\n") == null);
        const msg = mcp.jsonrpc.Message.parse(arena, frame) catch |e| {
            std.debug.print("\nthe bridge wrote a frame that is not a JSON-RPC message ({t}): {s}\n", .{ e, frame });
            return e;
        };
        const id: ?mcp.RequestId = switch (msg) {
            .request => |r| {
                if (r.id != .string or !std.mem.startsWith(u8, r.id.string, profile.request_id_prefix)) return error.TestBridgeRequestId;
                try std.testing.expectEqualStrings("elicitation/create", r.method);
                const entry = try asked.getOrPut(arena, r.id.string);
                if (entry.found_existing) return error.TestBridgeRequestIdTwice;
                continue;
            },
            .notification => |n| {
                if (std.mem.eql(u8, n.method, "notifications/cancelled")) {
                    const params = n.params orelse return error.TestCancelWithoutParams;
                    const request_id = mcp.json.getString(params, "requestId") orelse return error.TestCancelWithoutStringId;
                    if (!asked.contains(request_id)) {
                        std.debug.print("\nthe bridge canceled a request that it did not send: {s}\n", .{frame});
                        return error.TestCancelOfUnsentRequest;
                    }
                    continue;
                }
                // After `notifications/initialized`, the listen stream sends the list changes.
                for (translate.forwarded_events) |m| {
                    if (std.mem.eql(u8, m, n.method)) break;
                } else try std.testing.expectEqualStrings("notifications/progress", n.method);
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
        .corpus = corpus(&.{
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
            // The listen stream: the subscriptions, an update and a log level.
            "\x01{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"file:///fuzz.txt\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"file:///fuzz.txt\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"debug\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"touch\",\"_meta\":{\"traceparent\":\"t\",\"vscode.x\":1}}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"file:///fuzz.txt\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":1}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/subscribe\"}",
            // A line that is too long, with the id last as the TypeScript SDK 1.x writes it.
            "\x01{\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"" ++ "a" ** 300 ++ "\"}},\"jsonrpc\":\"2.0\",\"id\":9}",
            // The pending table: an answer, a second answer, an answer with a lone surrogate,
            // a late answer after a cancellation, and a form without an answer at the end.
            "\x01{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"Bo\"}}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":\"b-2\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"\\ud800\"}}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":4}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":\"b-3\",\"result\":{\"action\":\"cancel\"}}\n" ++
                "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}",
        }),
    });
}
