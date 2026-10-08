//! The part of MCP revision 2025-11-25 that the bridges receive from their client. It has the
//! `initialize` parameters and the classes of the methods and of the notifications. It also
//! has the parameters that the front end reads itself. The functions do no I/O.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");

/// The legacy protocol revision.
pub const protocol_version = @import("../bridge.zig").legacy_protocol_version;

/// The parameters of an `initialize` request. The parser ignores unknown fields.
pub const InitializeParams = struct {
    /// The revision that the client asks for. The response of the bridge always has the
    /// revision of its profile.
    protocolVersion: []const u8,
    /// The capabilities of the client, as the client sent them. A missing value is `{}`.
    capabilities: Value = .{ .object = .empty },
    clientInfo: mcp.types.Implementation,
    _meta: ?Value = null,
};

pub const ParamsError = error{
    /// The parameters do not have the shape of the method.
    InvalidParams,
    OutOfMemory,
};

/// Parse the parameters of an `initialize` request. Missing parameters give
/// `error.InvalidParams`, because `protocolVersion` and `clientInfo` are mandatory. All memory
/// comes from `arena`.
pub fn parseInitializeParams(arena: Allocator, params: ?Value) ParamsError!InitializeParams {
    return parseParams(InitializeParams, arena, params orelse return error.InvalidParams);
}

/// The parameters of `logging/setLevel`.
pub const SetLevelParams = struct {
    level: mcp.types.LoggingLevel,
};

/// Parse the parameters of a `logging/setLevel` request. All memory comes from `arena`.
pub fn parseSetLevelParams(arena: Allocator, params: ?Value) ParamsError!SetLevelParams {
    return parseParams(SetLevelParams, arena, params orelse return error.InvalidParams);
}

/// The parameters of `resources/subscribe` and `resources/unsubscribe`.
pub const SubscribeParams = struct {
    uri: []const u8,
};

/// Parse the parameters of a `resources/subscribe` or `resources/unsubscribe` request. All
/// memory comes from `arena`.
pub fn parseSubscribeParams(arena: Allocator, params: ?Value) ParamsError!SubscribeParams {
    return parseParams(SubscribeParams, arena, params orelse return error.InvalidParams);
}

/// The parameters of `notifications/cancelled`. Revision 2025-11-25 makes `requestId`
/// optional, because a client cancels a task with `tasks/cancel`. The bridges declare no
/// tasks, thus a notification without `requestId` cancels nothing.
pub const CancelledParams = struct {
    requestId: ?mcp.RequestId = null,
    reason: ?[]const u8 = null,
};

/// Parse the parameters of a `notifications/cancelled` notification. All memory comes from
/// `arena`.
pub fn parseCancelledParams(arena: Allocator, params: ?Value) ParamsError!CancelledParams {
    return parseParams(CancelledParams, arena, params orelse return error.InvalidParams);
}

fn parseParams(comptime T: type, arena: Allocator, params: Value) ParamsError!T {
    if (params != .object) return error.InvalidParams;
    return mcp.json.parseValue(T, arena, params) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidParams,
    };
}

/// What the front end does with a request of the client.
pub const MethodKind = enum {
    /// The front end starts the upstream connection and answers with the translated discover
    /// result.
    initialize,
    /// The front end answers with `{}`.
    ping,
    /// `logging/setLevel`. The front end keeps the level and answers with `{}`.
    set_level,
    /// `resources/subscribe`. The listen stream of the front end gets the URI.
    subscribe,
    /// `resources/unsubscribe`. The listen stream of the front end loses the URI.
    unsubscribe,
    /// `server/discover` of revision 2026-07-28. The front end answers with -32601 at once,
    /// thus a client of two revisions continues with `initialize`.
    discover,
    /// The front end sends the request to the upstream server and translates the result.
    forwarded,
    /// The front end answers with -32601.
    unknown,
};

/// The requests that go to the upstream server. Both revisions have these methods with the
/// same name.
pub const forwarded_methods = [_][]const u8{
    "tools/list",
    "tools/call",
    "prompts/list",
    "prompts/get",
    "resources/list",
    "resources/templates/list",
    "resources/read",
    "completion/complete",
};

const method_kinds: std.StaticStringMap(MethodKind) = .initComptime(.{
    .{ "initialize", .initialize },
    .{ "ping", .ping },
    .{ "logging/setLevel", .set_level },
    .{ "resources/subscribe", .subscribe },
    .{ "resources/unsubscribe", .unsubscribe },
    .{ "server/discover", .discover },
    .{ "tools/list", .forwarded },
    .{ "tools/call", .forwarded },
    .{ "prompts/list", .forwarded },
    .{ "prompts/get", .forwarded },
    .{ "resources/list", .forwarded },
    .{ "resources/templates/list", .forwarded },
    .{ "resources/read", .forwarded },
    .{ "completion/complete", .forwarded },
});

/// Return the class of the request method `method`. The comparison is exact and is case
/// sensitive.
pub fn classify(method: []const u8) MethodKind {
    return method_kinds.get(method) orelse .unknown;
}

/// True when the results of `method` have pages and a `nextCursor`.
pub fn isListMethod(method: []const u8) bool {
    const lists = [_][]const u8{ "tools/list", "prompts/list", "resources/list", "resources/templates/list" };
    for (lists) |m| if (std.mem.eql(u8, m, method)) return true;
    return false;
}

/// What the reader does with a notification of the client. The reader processes each
/// notification itself and never sends one to the upstream server.
pub const NotificationKind = enum {
    /// `notifications/initialized`. After the initialize result, the reader starts the listen
    /// stream of the upstream server when the server declares list changes or subscriptions.
    initialized,
    /// `notifications/cancelled`. The reader cancels the request with that id.
    cancelled,
    /// `notifications/roots/list_changed`. The reader ignores it, because revision 2026-07-28
    /// has no such notification: the upstream server asks for the roots in each request that
    /// needs them.
    roots_list_changed,
    /// Each other notification. The reader ignores it and writes a debug log line.
    other,
};

const notification_kinds: std.StaticStringMap(NotificationKind) = .initComptime(.{
    .{ "notifications/initialized", .initialized },
    .{ "notifications/cancelled", .cancelled },
    .{ "notifications/roots/list_changed", .roots_list_changed },
});

/// Return the class of the notification method `method`.
pub fn classifyNotification(method: []const u8) NotificationKind {
    return notification_kinds.get(method) orelse .other;
}

/// True when `params` has a `_meta` object with the protocol version key of revision
/// 2026-07-28. A client of two revisions sends this key in each modern request. Before
/// `initialize`, the front end answers such a request with -32601, thus the client
/// continues with `initialize`.
pub fn hasModernMeta(params: ?Value) bool {
    const p = params orelse return false;
    if (p != .object) return false;
    const m = p.object.get("_meta") orelse return false;
    return mcp.json.hasKey(m, mcp.protocol.meta.key_protocol_version);
}

const testing = std.testing;

fn parseTest(arena: Allocator, text: []const u8) !Value {
    return mcp.json.parseTree(arena, text);
}

test "initialize params of VS Code" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parseTest(arena,
        \\{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},
        \\"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"},
        \\"_meta":{"x":1},"unknown":true}
    );
    const p = try parseInitializeParams(arena, params);
    try testing.expectEqualStrings("2025-11-25", p.protocolVersion);
    try testing.expectEqualStrings("Visual Studio Code", p.clientInfo.name);
    try testing.expectEqualStrings("1.140.0", p.clientInfo.version);
    try testing.expect(p.capabilities == .object);
    try testing.expect(p.capabilities.object.get("roots") != null);
    try testing.expect(p._meta != null);
}

test "initialize params without capabilities get an empty object" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parseTest(arena,
        \\{"protocolVersion":"2025-11-25","clientInfo":{"name":"copilot-cli","version":"1.0.89"}}
    );
    const p = try parseInitializeParams(arena, params);
    try testing.expect(p.capabilities == .object);
    try testing.expectEqual(0, p.capabilities.object.count());
    try testing.expect(p._meta == null);
}

test "initialize params that are not valid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidParams, parseInitializeParams(arena, null));
    try testing.expectError(error.InvalidParams, parseInitializeParams(arena, .{ .string = "x" }));
    // No clientInfo.
    try testing.expectError(error.InvalidParams, parseInitializeParams(arena, try parseTest(arena,
        \\{"protocolVersion":"2025-11-25","capabilities":{}}
    )));
    // A clientInfo without a version.
    try testing.expectError(error.InvalidParams, parseInitializeParams(arena, try parseTest(arena,
        \\{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"x"}}
    )));
    // A protocolVersion that is not a string.
    try testing.expectError(error.InvalidParams, parseInitializeParams(arena, try parseTest(arena,
        \\{"protocolVersion":20251125,"capabilities":{},"clientInfo":{"name":"x","version":"1"}}
    )));
}

test "setLevel and cancelled params" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const level = try parseSetLevelParams(arena, try parseTest(arena, "{\"level\":\"warning\"}"));
    try testing.expectEqual(mcp.types.LoggingLevel.warning, level.level);
    try testing.expectError(error.InvalidParams, parseSetLevelParams(arena, try parseTest(arena, "{\"level\":\"loud\"}")));
    try testing.expectError(error.InvalidParams, parseSetLevelParams(arena, null));

    const subscribe = try parseSubscribeParams(arena, try parseTest(arena, "{\"uri\":\"file:///a.txt\",\"_meta\":{}}"));
    try testing.expectEqualStrings("file:///a.txt", subscribe.uri);
    try testing.expectError(error.InvalidParams, parseSubscribeParams(arena, try parseTest(arena, "{\"uri\":5}")));
    try testing.expectError(error.InvalidParams, parseSubscribeParams(arena, try parseTest(arena, "{}")));
    try testing.expectError(error.InvalidParams, parseSubscribeParams(arena, null));

    const numeric = try parseCancelledParams(arena, try parseTest(arena, "{\"requestId\":7,\"reason\":\"stop\"}"));
    try testing.expectEqual(@as(i64, 7), numeric.requestId.?.integer);
    try testing.expectEqualStrings("stop", numeric.reason.?);
    const text = try parseCancelledParams(arena, try parseTest(arena, "{\"requestId\":\"b-1\"}"));
    try testing.expectEqualStrings("b-1", text.requestId.?.string);
    const none = try parseCancelledParams(arena, try parseTest(arena, "{}"));
    try testing.expect(none.requestId == null);
    try testing.expectError(error.InvalidParams, parseCancelledParams(arena, try parseTest(arena, "{\"requestId\":1.5}")));
}

test "classify the request methods" {
    try testing.expectEqual(MethodKind.initialize, classify("initialize"));
    try testing.expectEqual(MethodKind.ping, classify("ping"));
    try testing.expectEqual(MethodKind.set_level, classify("logging/setLevel"));
    try testing.expectEqual(MethodKind.subscribe, classify("resources/subscribe"));
    try testing.expectEqual(MethodKind.unsubscribe, classify("resources/unsubscribe"));
    try testing.expectEqual(MethodKind.discover, classify("server/discover"));
    for (forwarded_methods) |m| try testing.expectEqual(MethodKind.forwarded, classify(m));
    try testing.expectEqual(MethodKind.unknown, classify("subscriptions/listen"));
    try testing.expectEqual(MethodKind.unknown, classify("tasks/get"));
    try testing.expectEqual(MethodKind.unknown, classify("Tools/List"));
    try testing.expectEqual(MethodKind.unknown, classify(""));
}

test "list methods" {
    try testing.expect(isListMethod("tools/list"));
    try testing.expect(isListMethod("prompts/list"));
    try testing.expect(isListMethod("resources/list"));
    try testing.expect(isListMethod("resources/templates/list"));
    try testing.expect(!isListMethod("tools/call"));
    try testing.expect(!isListMethod("completion/complete"));
}

test "classify the notifications" {
    try testing.expectEqual(NotificationKind.initialized, classifyNotification("notifications/initialized"));
    try testing.expectEqual(NotificationKind.cancelled, classifyNotification("notifications/cancelled"));
    try testing.expectEqual(NotificationKind.roots_list_changed, classifyNotification("notifications/roots/list_changed"));
    try testing.expectEqual(NotificationKind.other, classifyNotification("notifications/progress"));
    try testing.expectEqual(NotificationKind.other, classifyNotification("notifications/tasks/status"));
}

test "modern _meta of a client of two revisions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(hasModernMeta(try parseTest(arena,
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}
    )));
    try testing.expect(!hasModernMeta(try parseTest(arena, "{\"_meta\":{\"progressToken\":0}}")));
    try testing.expect(!hasModernMeta(try parseTest(arena, "{\"_meta\":7}")));
    try testing.expect(!hasModernMeta(try parseTest(arena, "{}")));
    try testing.expect(!hasModernMeta(null));
}
