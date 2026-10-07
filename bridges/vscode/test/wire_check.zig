//! The checks of the frames of the transcript tests. Each frame to VS Code must be valid for
//! one definition of the schema of revision 2025-11-25. Each request to the upstream server
//! must be valid for one definition of the schema of revision 2026-07-28. The test chooses
//! the definition from the method. It never uses a union definition, because those
//! accept almost all objects.
//!
//! The schema of revision 2025-11-25 permits members that the bridge must remove. Thus the
//! checks also find these members by name.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const validator = mcp.schema.validator;

const schema_2025_11_25 = @embedFile("schema_2025_11_25");
const schema_2026_07_28 = @embedFile("schema_2026_07_28");

/// False in the tests of this file that expect a failure. Then a failure writes no output.
var verbose = true;

/// The schema of a check.
pub const Revision = enum {
    /// Revision 2025-11-25: the frames to VS Code.
    legacy,
    /// Revision 2026-07-28: the requests to the upstream server.
    modern,
};

/// The compiled definitions of the two schemas. The function `check` compiles a definition
/// when it needs it for the first time.
pub const Schemas = struct {
    arena_state: std.heap.ArenaAllocator,
    documents: [2]?Value = .{ null, null },
    compiled: std.StringHashMapUnmanaged(*const validator.Schema) = .empty,

    pub fn init(gpa: Allocator) Schemas {
        return .{ .arena_state = .init(gpa) };
    }

    pub fn deinit(self: *Schemas) void {
        self.arena_state.deinit();
    }

    /// Validate `instance` against the definition `name` of the schema of `revision`.
    /// `context` goes into the failure output.
    pub fn check(self: *Schemas, revision: Revision, name: []const u8, instance: Value, context: []const u8) !void {
        const schema = try self.definition(revision, name);
        var scratch: std.heap.ArenaAllocator = .init(self.arena_state.child_allocator);
        defer scratch.deinit();
        const result = try validator.validate(scratch.allocator(), schema, instance);
        if (result.valid) return;
        if (!verbose) return error.TestSchemaMismatch;
        std.debug.print("\n{s}: not valid for {t} {s}\n", .{ context, revision, name });
        for (result.failures) |f| std.debug.print("  at '{s}': {s}: {s}\n", .{ f.instance_path, f.keyword, f.message });
        return error.TestSchemaMismatch;
    }

    fn definition(self: *Schemas, revision: Revision, name: []const u8) !*const validator.Schema {
        const arena = self.arena_state.allocator();
        const key = try std.fmt.allocPrint(arena, "{t}/{s}", .{ revision, name });
        if (self.compiled.get(key)) |s| return s;
        const doc = try self.document(revision);
        const defs = doc.object.get("$defs").?;
        if (defs.object.get(name) == null) {
            std.debug.print("\nthe {t} schema has no definition {s}\n", .{ revision, name });
            return error.TestUnknownDefinition;
        }
        // A shallow copy of the root with a reference to the definition. The copy shares
        // `$defs` with the document.
        var root: std.json.ObjectMap = .empty;
        var it = doc.object.iterator();
        while (it.next()) |kv| try root.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        try root.put(arena, "$ref", .{ .string = try std.fmt.allocPrint(arena, "#/$defs/{s}", .{name}) });
        const schema = try arena.create(validator.Schema);
        schema.* = try validator.compile(arena, .{ .object = root }, .{});
        try self.compiled.put(arena, key, schema);
        return schema;
    }

    fn document(self: *Schemas, revision: Revision) !Value {
        const index = @intFromEnum(revision);
        if (self.documents[index]) |d| return d;
        const text = switch (revision) {
            .legacy => schema_2025_11_25,
            .modern => schema_2026_07_28,
        };
        const d = try std.json.parseFromSliceLeaky(Value, self.arena_state.allocator(), text, .{});
        self.documents[index] = d;
        return d;
    }
};

/// The definition of the 2025-11-25 schema for the result of `method`, or null when the
/// method has no result for VS Code.
pub fn resultDefinition(method: []const u8) ?[]const u8 {
    const map: std.StaticStringMap([]const u8) = .initComptime(.{
        .{ "initialize", "InitializeResult" },
        .{ "ping", "EmptyResult" },
        .{ "logging/setLevel", "EmptyResult" },
        .{ "resources/subscribe", "EmptyResult" },
        .{ "resources/unsubscribe", "EmptyResult" },
        .{ "tools/list", "ListToolsResult" },
        .{ "tools/call", "CallToolResult" },
        .{ "prompts/list", "ListPromptsResult" },
        .{ "prompts/get", "GetPromptResult" },
        .{ "resources/list", "ListResourcesResult" },
        .{ "resources/templates/list", "ListResourceTemplatesResult" },
        .{ "resources/read", "ReadResourceResult" },
        .{ "completion/complete", "CompleteResult" },
    });
    return map.get(method);
}

/// The definition of the 2025-11-25 schema for a request of the bridge to VS Code, or null.
/// The bridge sends only the input requests of the upstream server.
pub fn bridgeRequestDefinition(method: []const u8) ?[]const u8 {
    const map: std.StaticStringMap([]const u8) = .initComptime(.{
        .{ "elicitation/create", "ElicitRequest" },
        .{ "sampling/createMessage", "CreateMessageRequest" },
        .{ "roots/list", "ListRootsRequest" },
    });
    return map.get(method);
}

/// The definition of the 2025-11-25 schema for a notification of the bridge to VS Code, or
/// null.
pub fn notificationDefinition(method: []const u8) ?[]const u8 {
    const map: std.StaticStringMap([]const u8) = .initComptime(.{
        .{ "notifications/progress", "ProgressNotification" },
        .{ "notifications/cancelled", "CancelledNotification" },
        .{ "notifications/elicitation/complete", "ElicitationCompleteNotification" },
    });
    return map.get(method);
}

/// The definition of the 2026-07-28 schema for a request to the upstream server, or null.
pub fn upstreamRequestDefinition(method: []const u8) ?[]const u8 {
    const map: std.StaticStringMap([]const u8) = .initComptime(.{
        .{ "server/discover", "DiscoverRequest" },
        .{ "tools/list", "ListToolsRequest" },
        .{ "tools/call", "CallToolRequest" },
        .{ "prompts/list", "ListPromptsRequest" },
        .{ "prompts/get", "GetPromptRequest" },
        .{ "resources/list", "ListResourcesRequest" },
        .{ "resources/templates/list", "ListResourceTemplatesRequest" },
        .{ "resources/read", "ReadResourceRequest" },
        .{ "completion/complete", "CompleteRequest" },
    });
    return map.get(method);
}

/// The members of a result that revision 2025-11-25 does not have. The bridge removes them.
pub const modern_result_members = [_][]const u8{ "resultType", "ttlMs", "cacheScope", "inputRequests", "requestState" };

/// The `_meta` keys of a result that the bridge removes.
pub const modern_result_meta = [_][]const u8{ "io.modelcontextprotocol/serverInfo", "io.modelcontextprotocol/subscriptionId" };

/// The `_meta` keys that the upstream client of this version writes into a request. The
/// bridge sends no key of VS Code to the upstream server in this version.
pub const upstream_meta_keys = [_][]const u8{
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/clientInfo",
    "io.modelcontextprotocol/clientCapabilities",
    "io.modelcontextprotocol/logLevel",
    "progressToken",
};

/// The value that the schema check of `method` gets for `result`. The VS Code profile passes
/// a `structuredContent` that is not an object without a change, because MCP Apps read it.
/// Revision 2025-11-25 wants an object, thus the check of that one member is off.
pub fn checkedResult(arena: Allocator, method: []const u8, result: Value) Allocator.Error!Value {
    if (!std.mem.eql(u8, method, "tools/call") or result != .object) return result;
    const sc = result.object.get("structuredContent") orelse return result;
    if (sc == .object) return result;
    var copy = try result.object.clone(arena);
    _ = copy.orderedRemove("structuredContent");
    return .{ .object = copy };
}

/// Fail when `result` has a member that the bridge must remove before the result goes to
/// VS Code. These checks find what the schema cannot find, because the 2025-11-25 schema
/// permits additional members.
pub fn expectLegacyResult(method: []const u8, result: Value) !void {
    if (result != .object) return fail("the result of {s} is not an object", .{method});
    for (modern_result_members) |key| if (result.object.get(key) != null)
        return fail("the result of {s} has the member {s}", .{ method, key });
    if (result.object.get("nextCursor")) |cursor| if (cursor != .string)
        return fail("the result of {s} has a nextCursor that is not a string", .{method});
    if (result.object.get("_meta")) |meta| {
        if (meta != .object) return fail("the _meta of the result of {s} is not an object", .{method});
        for (modern_result_meta) |key| if (meta.object.get(key) != null)
            return fail("the _meta of the result of {s} has the key {s}", .{ method, key });
    }
    if (std.mem.eql(u8, method, "initialize")) {
        const caps = result.object.get("capabilities") orelse return fail("the initialize result has no capabilities", .{});
        if (caps.object.get("tasks") != null) return fail("the initialize result declares tasks", .{});
        if (caps.object.get("extensions")) |ext| if (ext.object.get(mcp.tasks.extension_id) != null)
            return fail("the initialize result declares the Tasks extension", .{});
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        const tools = result.object.get("tools") orelse return fail("the tools/list result has no tools", .{});
        for (tools.array.items) |tool| {
            const schema = tool.object.get("inputSchema") orelse continue;
            try expectArrayItems(mcp.json.getString(tool, "name") orelse "?", schema, 0);
        }
    }
}

/// The check of the Copilot extension: each array schema has an `items` value that is true
/// in JavaScript. The walk examines each object of the schema, also objects in keywords that
/// are not schemas. Thus it finds more than the walk of Copilot.
fn expectArrayItems(tool: []const u8, node: Value, depth: usize) !void {
    if (depth > 200) return fail("the input schema of {s} is too deep", .{tool});
    switch (node) {
        .object => |o| {
            if (o.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "array")) {
                const items = o.get("items") orelse return fail("tool {s}: an array schema has no items", .{tool});
                if (!truthy(items)) return fail("tool {s}: an array schema has items that are false in JavaScript", .{tool});
            };
            var it = o.iterator();
            while (it.next()) |kv| try expectArrayItems(tool, kv.value_ptr.*, depth + 1);
        },
        .array => |a| for (a.items) |item| try expectArrayItems(tool, item, depth + 1),
        else => {},
    }
}

/// The truth value of JavaScript for a JSON value.
fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0 and !std.math.isNan(f),
        .number_string => |s| !std.mem.eql(u8, s, "0"),
        .string => |s| s.len != 0,
        .array, .object => true,
    };
}

/// Fail when a request to the upstream server has `task` or a `_meta` key of VS Code. This
/// version of the bridge must not send them. Also fail when the client capabilities declare
/// `tasks`, the Tasks extension, `roots.listChanged`, `sampling.tools` or `sampling.context`.
/// The clients of the transcripts declare no sampling with tools or context, thus the bridge
/// must not declare them upstream.
pub fn expectUpstreamRequest(method: []const u8, frame: Value) !void {
    const params = frame.object.get("params") orelse return fail("the upstream {s} request has no params", .{method});
    if (params.object.get("task") != null) return fail("the upstream {s} request has a task", .{method});
    const meta = params.object.get("_meta") orelse return fail("the upstream {s} request has no _meta", .{method});
    var it = meta.object.iterator();
    next: while (it.next()) |kv| {
        for (upstream_meta_keys) |k| if (std.mem.eql(u8, k, kv.key_ptr.*)) continue :next;
        return fail("the upstream {s} request has the _meta key {s}", .{ method, kv.key_ptr.* });
    }
    const caps = meta.object.get("io.modelcontextprotocol/clientCapabilities") orelse
        return fail("the upstream {s} request has no client capabilities", .{method});
    if (caps.object.get("tasks") != null) return fail("the upstream {s} request declares tasks", .{method});
    if (caps.object.get("roots")) |roots| if (roots.object.get("listChanged") != null)
        return fail("the upstream {s} request declares roots.listChanged", .{method});
    if (caps.object.get("sampling")) |sampling| for ([_][]const u8{ "tools", "context" }) |key| if (sampling.object.get(key) != null)
        return fail("the upstream {s} request declares sampling.{s}", .{ method, key });
    if (caps.object.get("extensions")) |ext| if (ext.object.get(mcp.tasks.extension_id) != null)
        return fail("the upstream {s} request declares the Tasks extension", .{method});
}

fn fail(comptime format: []const u8, args: anytype) error{TestUnexpectedMember} {
    if (verbose) std.debug.print("\n" ++ format ++ "\n", args);
    return error.TestUnexpectedMember;
}

test "a definition rejects a frame that its union accepts" {
    var schemas: Schemas = .init(std.testing.allocator);
    defer schemas.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try mcp.json.parseTree(arena,
        \\{"tools":[{"name":"t","inputSchema":{"type":"object"}}],"nextCursor":null}
    );
    try schemas.check(.legacy, "Result", list, "test");
    verbose = false;
    defer verbose = true;
    try std.testing.expectError(error.TestSchemaMismatch, schemas.check(.legacy, "ListToolsResult", list, "test"));
    try std.testing.expectError(error.TestUnexpectedMember, expectLegacyResult("tools/list", list));
}

test "the definitions of the requests of the bridge refuse a frame without a required member" {
    var schemas: Schemas = .init(std.testing.allocator);
    defer schemas.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = "{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"Sign in.\",\"url\":\"https://example.com/auth\"";
    const complete = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{";
    const sampling = "{\"jsonrpc\":\"2.0\",\"id\":\"b-2\",\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[]";
    try schemas.check(.legacy, "ElicitRequest", try mcp.json.parseTree(arena, url ++ ",\"elicitationId\":\"e-1\"}}"), "test");
    try schemas.check(.legacy, "ElicitationCompleteNotification", try mcp.json.parseTree(arena, complete ++ "\"elicitationId\":\"e-1\"}}"), "test");
    try schemas.check(.legacy, "CreateMessageRequest", try mcp.json.parseTree(arena, sampling ++ ",\"maxTokens\":5}}"), "test");
    // VS Code needs the elicitationId of a URL elicitation and of its complete notification.
    // Revision 2025-11-25 also needs maxTokens.
    verbose = false;
    defer verbose = true;
    try std.testing.expectError(error.TestSchemaMismatch, schemas.check(.legacy, "ElicitRequest", try mcp.json.parseTree(arena, url ++ "}}"), "test"));
    try std.testing.expectError(error.TestSchemaMismatch, schemas.check(.legacy, "ElicitationCompleteNotification", try mcp.json.parseTree(arena, complete ++ "}}"), "test"));
    try std.testing.expectError(error.TestSchemaMismatch, schemas.check(.legacy, "CreateMessageRequest", try mcp.json.parseTree(arena, sampling ++ "}}"), "test"));
}

test "the Copilot check finds an array schema without items" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good = try mcp.json.parseTree(arena,
        \\{"tools":[{"name":"t","inputSchema":{"type":"object","properties":{"a":{"type":"array","items":{}},"b":{"type":["array","null"]}}}}]}
    );
    try expectLegacyResult("tools/list", good);
    const bad = try mcp.json.parseTree(arena,
        \\{"tools":[{"name":"t","inputSchema":{"type":"object","properties":{"a":{"anyOf":[{"type":"array","items":false}]}}}}]}
    );
    verbose = false;
    defer verbose = true;
    try std.testing.expectError(error.TestUnexpectedMember, expectLegacyResult("tools/list", bad));
}
