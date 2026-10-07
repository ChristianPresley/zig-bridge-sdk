//! The translation between revision 2025-11-25 of the client and revision 2026-07-28 of the
//! upstream server. It has the capabilities, the `initialize` result, the parameters of a
//! forwarded request, the results and the error table. The functions do no I/O. They take an
//! arena, and that arena owns each value that they return.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const mcp = @import("mcp");
const types = mcp.types;
const bridge = @import("../bridge.zig");
const legacy = @import("legacy.zig");
const Profile = bridge.Profile;

// ---------------------------------------------------------------------------------------------
// Capabilities
// ---------------------------------------------------------------------------------------------

/// The capabilities of the client that go to the upstream server. A false field removes that
/// capability. By default, the upstream server gets each capability as the client declared
/// it. The front end sends the input requests of the upstream server to the client. Thus it
/// declares sampling, elicitation and roots when the client declares them. The bridge never
/// declares the Tasks extension.
pub const CapabilityMask = struct {
    sampling: bool = true,
    elicitation: bool = true,
    roots: bool = true,
    experimental: bool = true,
    extensions: bool = true,
};

/// Translate the capabilities of an `initialize` request into the client capabilities of
/// revision 2026-07-28, and apply `mask`. The parser drops the members that revision
/// 2026-07-28 does not have, for example `tasks` and `roots.listChanged`. It also drops a
/// member that does not have the shape of the schema. Thus the upstream server always gets
/// capabilities that are valid. The modes of `elicitation` and the members `context` and
/// `tools` of `sampling` stay as the client declared them. The function never adds one.
pub fn upstreamCapabilities(arena: Allocator, legacy_caps: Value, mask: CapabilityMask) Allocator.Error!types.ClientCapabilities {
    var out: types.ClientCapabilities = .{};
    if (legacy_caps != .object) return out;
    const caps = legacy_caps.object;
    if (mask.experimental) out.experimental = try objectsOnly(arena, caps.get("experimental"), null);
    if (mask.roots) out.roots = try parseMember(types.Empty, arena, caps.get("roots"));
    if (mask.sampling) out.sampling = try parseMember(types.ClientCapabilities.Sampling, arena, caps.get("sampling"));
    if (mask.elicitation) out.elicitation = try parseMember(types.ClientCapabilities.Elicitation, arena, caps.get("elicitation"));
    if (mask.extensions) out.extensions = try objectsOnly(arena, caps.get("extensions"), mcp.tasks.extension_id);
    return out;
}

/// Parse an object member of a capabilities object. A member that is missing, that is not an
/// object or that does not have the shape of `T` gives null. A settings member of `T` that is
/// not an object becomes null.
fn parseMember(comptime T: type, arena: Allocator, member: ?Value) Allocator.Error!?T {
    const v = member orelse return null;
    if (v != .object) return null;
    var out = mcp.json.parseValue(T, arena, v) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type == ?Value) if (@field(out, field.name)) |settings| if (settings != .object) {
            @field(out, field.name) = null;
        };
    }
    return out;
}

/// A copy of a map of settings objects, for example `extensions`. The copy has no `drop` key
/// and no member that is not an object. A value that is not an object, or an empty copy,
/// gives null.
fn objectsOnly(arena: Allocator, member: ?Value, drop: ?[]const u8) Allocator.Error!?Value {
    const v = member orelse return null;
    if (v != .object) return null;
    var out: ObjectMap = .empty;
    var it = v.object.iterator();
    while (it.next()) |kv| {
        if (drop) |d| if (std.mem.eql(u8, kv.key_ptr.*, d)) continue;
        if (kv.value_ptr.* != .object) continue;
        try out.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }
    if (out.count() == 0) return null;
    return .{ .object = out };
}

// ---------------------------------------------------------------------------------------------
// The initialize result
// ---------------------------------------------------------------------------------------------

/// The server capabilities that the `initialize` result keeps. A false field removes that
/// capability. The defaults remove the capabilities that need notifications to the client,
/// because this version of the bridge sends no notification from the upstream server.
pub const ReplyMask = struct {
    /// Keep `listChanged` of `tools`, `prompts` and `resources`.
    list_changed: bool = false,
    /// Keep `subscribe` of `resources`.
    subscribe: bool = false,
    /// Keep `logging`.
    logging: bool = false,
};

/// The settings of `initializeResult`.
pub const InitOpts = struct {
    profile: *const Profile,
    /// The `serverInfo.name` when the discover result has no server information. The command
    /// line gives the value of `--name`, or the base name of the upstream command without its
    /// extension. When the value is empty, the result uses the name of the profile.
    fallback_name: []const u8,
    /// The `serverInfo.version` when the discover result has no server information.
    fallback_version: []const u8 = bridge.version,
    mask: ReplyMask = .{},
};

/// Make the `initialize` result of revision 2025-11-25 from the raw `server/discover` result
/// of the upstream server. The result has these members:
///
/// - `protocolVersion`: the `reply_protocol_version` of the profile.
/// - `capabilities`: `tools`, `prompts`, `resources`, `completions`, `logging`, `experimental`
///   and `extensions` of the discover result, after `opts.mask`. The result never has `tasks`
///   and never has the Tasks extension.
/// - `serverInfo`: the server information in `_meta` of the discover result, or the fallback
///   name and version.
/// - `instructions`: a copy, when the discover result has them.
pub fn initializeResult(arena: Allocator, discover_raw: Value, opts: InitOpts) Allocator.Error!Value {
    const empty: Value = .{ .object = .empty };
    const discover = if (discover_raw == .object) discover_raw else empty;
    var out: ObjectMap = .empty;
    try out.put(arena, "protocolVersion", .{ .string = opts.profile.reply_protocol_version });
    try out.put(arena, "capabilities", try replyCapabilities(arena, discover.object.get("capabilities") orelse empty, opts.mask));
    try out.put(arena, "serverInfo", try serverInfo(arena, discover.object.get("_meta"), opts));
    if (discover.object.get("instructions")) |i| if (i == .string) try out.put(arena, "instructions", i);
    return .{ .object = out };
}

fn replyCapabilities(arena: Allocator, caps: Value, mask: ReplyMask) Allocator.Error!Value {
    var out: ObjectMap = .empty;
    if (caps != .object) return .{ .object = out };
    const c = caps.object;
    if (c.get("experimental")) |v| if (v == .object) try out.put(arena, "experimental", v);
    if (mask.logging) if (c.get("logging")) |v| if (v == .object) try out.put(arena, "logging", v);
    if (c.get("completions")) |v| if (v == .object) try out.put(arena, "completions", v);
    const list_changed: []const []const u8 = if (mask.list_changed) &.{} else &.{"listChanged"};
    var resources_drop_buf: [2][]const u8 = undefined;
    var resources_drop: std.ArrayList([]const u8) = .initBuffer(&resources_drop_buf);
    if (!mask.list_changed) resources_drop.appendAssumeCapacity("listChanged");
    if (!mask.subscribe) resources_drop.appendAssumeCapacity("subscribe");
    if (c.get("prompts")) |v| if (v == .object) try out.put(arena, "prompts", try withoutKeys(arena, v, list_changed));
    if (c.get("resources")) |v| if (v == .object) try out.put(arena, "resources", try withoutKeys(arena, v, resources_drop.items));
    if (c.get("tools")) |v| if (v == .object) try out.put(arena, "tools", try withoutKeys(arena, v, list_changed));
    if (try objectsOnly(arena, c.get("extensions"), mcp.tasks.extension_id)) |v| try out.put(arena, "extensions", v);
    return .{ .object = out };
}

/// A copy of the object `v` without the keys of `drop`.
fn withoutKeys(arena: Allocator, v: Value, drop: []const []const u8) Allocator.Error!Value {
    var out: ObjectMap = .empty;
    var it = v.object.iterator();
    next: while (it.next()) |kv| {
        for (drop) |d| if (std.mem.eql(u8, kv.key_ptr.*, d)) continue :next;
        try out.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }
    return .{ .object = out };
}

/// The members of the server information that the `initialize` result keeps.
const server_info_keys = [_][]const u8{ "name", "title", "version", "icons", "description", "websiteUrl" };

fn serverInfo(arena: Allocator, meta: ?Value, opts: InitOpts) Allocator.Error!Value {
    if (meta) |m| if (m == .object) if (m.object.get(mcp.protocol.meta.key_server_info)) |info| {
        if (try validServerInfo(arena, info)) {
            var out: ObjectMap = .empty;
            for (server_info_keys) |key| if (info.object.get(key)) |v| try out.put(arena, key, v);
            return .{ .object = out };
        }
    };
    var out: ObjectMap = .empty;
    const name = if (opts.fallback_name.len != 0) opts.fallback_name else opts.profile.name;
    try out.put(arena, "name", .{ .string = name });
    try out.put(arena, "version", .{ .string = opts.fallback_version });
    return .{ .object = out };
}

/// True when `info` has the shape of an `Implementation` with a name that is not empty.
fn validServerInfo(arena: Allocator, info: Value) Allocator.Error!bool {
    if (info != .object) return false;
    const parsed = mcp.json.parseValue(types.Implementation, arena, info) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return parsed.name.len != 0;
}

// ---------------------------------------------------------------------------------------------
// Forwarded requests
// ---------------------------------------------------------------------------------------------

/// The parameters of a forwarded request and the progress token of the client.
pub const Forward = struct {
    /// An object without `_meta` and without `task`. The upstream client adds its own `_meta`.
    params: Value,
    /// The `_meta.progressToken` of the client, or null. Each JSON scalar except null is a
    /// token, also the integer 0. The front end keys progress by request, never by token.
    progress_token: ?Value,
};

/// Make the parameters of a forwarded request from the parameters of the client. Missing
/// parameters give `{}`. The function removes `task`, because the bridge declares no tasks.
/// It removes `_meta` and returns the progress token of the client. In this version, no key
/// of `_meta` goes to the upstream server, also when the profile allows it. The function does
/// not change `params`.
pub fn forwardParams(arena: Allocator, params: ?Value, profile: *const Profile) Allocator.Error!Forward {
    _ = profile;
    var out: ObjectMap = .empty;
    var token: ?Value = null;
    if (params) |p| if (p == .object) {
        var it = p.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            if (std.mem.eql(u8, key, "_meta")) {
                token = progressToken(kv.value_ptr.*);
                continue;
            }
            if (std.mem.eql(u8, key, "task")) continue;
            try out.put(arena, key, kv.value_ptr.*);
        }
    };
    return .{ .params = .{ .object = out }, .progress_token = token };
}

fn progressToken(meta: Value) ?Value {
    if (meta != .object) return null;
    const t = meta.object.get(mcp.protocol.meta.key_progress_token) orelse return null;
    return switch (t) {
        .string, .integer, .float, .number_string, .bool => t,
        .null, .array, .object => null,
    };
}

// ---------------------------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------------------------

/// A shaped result and the changes of the schema walk.
pub const Shaped = struct {
    result: Value,
    /// The changes to the input schemas of a `tools/list` result. The caller writes one log
    /// line for each fix.
    fixes: []const Fix,
};

/// One change to the input schema of a tool.
pub const Fix = struct {
    /// The name of the tool.
    tool: []const u8,
    /// The JSON pointer (RFC 6901) of the schema in the `inputSchema` of the tool. The root
    /// schema has the pointer "".
    pointer: []const u8,
    kind: Kind,
    /// The `maxItems` that the fix added, or null.
    max_items: ?usize = null,

    pub const Kind = enum {
        /// An array schema without `items`, or with `items` null, 0 or "", got `items: {}`.
        items_added,
        /// An array schema with `items: false` got `items: {}`.
        items_false_replaced,
        /// The schema is deeper than `max_schema_depth`. The walk did not examine it.
        too_deep,
    };
};

/// The maximum depth of a schema that the walk of the input schemas examines. The root
/// schema has the depth 0. The walk keeps a deeper schema as it is and adds a fix of the kind
/// `too_deep`.
pub const max_schema_depth = 64;

/// True when the upstream server returned an `InputRequiredResult`.
pub fn isInputRequired(raw: Value) bool {
    const t = mcp.json.getString(raw, "resultType") orelse return false;
    return std.mem.eql(u8, t, types.result_type_input_required);
}

/// Make the result of revision 2025-11-25 for the client from the raw result of the upstream
/// server. Use it only for a complete result. Examine an `InputRequiredResult` with
/// `isInputRequired` first. The function changes the tree of `raw` in place, thus `arena`
/// must own that tree. Use only the result that the function returns. The rules:
///
/// - Each result loses `resultType`, `ttlMs`, `cacheScope` and the server information in
///   `_meta`. An empty `_meta` goes away.
/// - A list result loses a `nextCursor` that is not a string. VS Code requests the next page
///   while `nextCursor` is present, also when it is null.
/// - A `tools/list` result: with `profile.quirks.normalize_array_items`, each array schema of
///   an `inputSchema` gets an `items` schema. The result has a fix for each change.
/// - A `tools/call` result always has a `content` array. When it has `structuredContent` and
///   no text block, it gets a text block with the serialized `structuredContent`.
/// - A `tools/list` result: with `profile.quirks.drop_non_object_output_schema`, each tool
///   loses an `outputSchema` whose root does not have `type: "object"`.
/// - With `profile.quirks.strict_legacy_results`, the function also removes the values that
///   revision 2025-11-25 does not allow. See `strictLegacyResult`.
pub fn shapeResult(arena: Allocator, method: []const u8, raw: Value, profile: *const Profile) Allocator.Error!Shaped {
    var result = raw;
    if (result != .object) return .{ .result = result, .fixes = &.{} };
    const obj = &result.object;
    _ = obj.orderedRemove("resultType");
    _ = obj.orderedRemove("ttlMs");
    _ = obj.orderedRemove("cacheScope");
    if (obj.getPtr("_meta")) |meta| if (meta.* == .object) {
        _ = meta.object.orderedRemove(mcp.protocol.meta.key_server_info);
        if (meta.object.count() == 0) _ = obj.orderedRemove("_meta");
    };
    if (legacy.isListMethod(method)) {
        if (obj.get("nextCursor")) |c| if (c != .string) {
            _ = obj.orderedRemove("nextCursor");
        };
    }
    var fixes: std.ArrayList(Fix) = .empty;
    if (std.mem.eql(u8, method, "tools/list") and profile.quirks.normalize_array_items) {
        if (obj.getPtr("tools")) |tools| if (tools.* == .array) {
            for (tools.array.items) |*tool| {
                if (tool.* != .object) continue;
                const name = mcp.json.getString(tool.*, "name") orelse "";
                const schema = tool.object.getPtr("inputSchema") orelse continue;
                try normalizeArrayItems(arena, name, schema, &fixes);
            }
        };
    }
    if (std.mem.eql(u8, method, "tools/list") and profile.quirks.drop_non_object_output_schema) dropNonObjectOutputSchemas(obj);
    if (std.mem.eql(u8, method, "tools/call")) try mirrorStructuredContent(arena, obj);
    result = strictLegacyResult(method, result, profile);
    return .{ .result = result, .fixes = try fixes.toOwnedSlice(arena) };
}

/// Make sure that a `tools/call` result has a `content` array. When the result has
/// `structuredContent` and `content` has no text block, add a text block with the serialized
/// `structuredContent`. The `structuredContent` stays as it is, whatever its JSON type.
fn mirrorStructuredContent(arena: Allocator, obj: *ObjectMap) Allocator.Error!void {
    const has_array = if (obj.get("content")) |c| c == .array else false;
    if (!has_array) try obj.put(arena, "content", .{ .array = .init(arena) });
    const sc = obj.get("structuredContent") orelse return;
    // A JSON null counts as no structured content, as in the server of zig-sdk.
    if (sc == .null) return;
    const content = obj.getPtr("content").?;
    for (content.array.items) |block| {
        if (std.mem.eql(u8, mcp.json.getString(block, "type") orelse "", "text")) return;
    }
    var text_block: ObjectMap = .empty;
    try text_block.put(arena, "type", .{ .string = "text" });
    try text_block.put(arena, "text", .{ .string = try mcp.json.writeAlloc(arena, sc) });
    try content.array.append(.{ .object = text_block });
}

/// The conversions to revision 2025-11-25 for a client that checks results against that
/// schema. Without `profile.quirks.strict_legacy_results`, the function returns `result`
/// unchanged. With the flag, it removes the values that need no state across requests:
///
/// - `tools/call`: a `structuredContent` that is not an object. The text block of
///   `shapeResult` keeps its data.
/// - `tools/list`: an `outputSchema` whose root does not have `type: "object"`.
///
/// The function changes the tree of `result` in place. Use only the result that it returns.
pub fn strictLegacyResult(method: []const u8, result: Value, profile: *const Profile) Value {
    if (!profile.quirks.strict_legacy_results) return result;
    var out = result;
    if (out != .object) return out;
    if (std.mem.eql(u8, method, "tools/call")) {
        if (out.object.get("structuredContent")) |sc| if (sc != .object) {
            _ = out.object.orderedRemove("structuredContent");
        };
    } else if (std.mem.eql(u8, method, "tools/list")) {
        dropNonObjectOutputSchemas(&out.object);
    }
    return out;
}

/// Remove each `outputSchema` of the `tools` of a `tools/list` result whose root does not
/// have `type: "object"`.
fn dropNonObjectOutputSchemas(obj: *ObjectMap) void {
    const tools = obj.getPtr("tools") orelse return;
    if (tools.* != .array) return;
    for (tools.array.items) |*tool| {
        if (tool.* != .object) continue;
        const schema = tool.object.get("outputSchema") orelse continue;
        const t = mcp.json.getString(schema, "type") orelse "";
        if (!std.mem.eql(u8, t, "object")) _ = tool.object.orderedRemove("outputSchema");
    }
}

/// The keywords whose value is one schema.
const schema_keywords = [_][]const u8{ "additionalProperties", "not", "if", "then", "else", "contains" };
/// The keywords whose value is an object of schemas. The members of `dependencies` can also
/// be arrays of names, which the walk ignores.
const schema_map_keywords = [_][]const u8{ "properties", "patternProperties", "dependencies", "dependentSchemas", "$defs", "definitions" };
/// The keywords whose value is an array of schemas.
const schema_array_keywords = [_][]const u8{ "anyOf", "allOf", "oneOf", "prefixItems" };

/// Give an `items` schema to each array schema in the JSON Schema `schema`. The Copilot
/// extension of VS Code stops each chat request when a schema has `type: "array"` and no
/// truthy `items`. The function changes only an object whose `type` is the string "array":
///
/// - Without `items`, or with an `items` value that is false in JavaScript and is not
///   `false` (`null`, the number 0 or the empty string), it adds `items: {}`.
/// - With `items: false`, it sets `items: {}`. When the schema has no `maxItems`, it adds
///   `maxItems` with the length of `prefixItems` (0 without `prefixItems`). Thus the schema
///   accepts the same arrays as before.
///
/// A type array such as `["array","null"]` stays as it is. The function changes `schema` in
/// place, thus `arena` must own its tree. It adds one fix to `fixes` for each change.
pub fn normalizeArrayItems(arena: Allocator, tool: []const u8, schema: *Value, fixes: *std.ArrayList(Fix)) Allocator.Error!void {
    var walker: Walker = .{ .arena = arena, .tool = tool, .fixes = fixes };
    try walker.walk(schema, 0);
}

const Walker = struct {
    arena: Allocator,
    tool: []const u8,
    fixes: *std.ArrayList(Fix),
    /// The JSON pointer of the schema that the walk examines.
    path: std.ArrayList(u8) = .empty,

    fn walk(w: *Walker, node: *Value, depth: usize) Allocator.Error!void {
        // A boolean schema, an empty schema, or a value that is not a schema, has nothing to
        // change. This also skips the `items: {}` that the walk adds.
        if (node.* != .object or node.object.count() == 0) return;
        if (depth > max_schema_depth) return w.record(.too_deep, null);
        try w.fixItems(node);
        for (schema_keywords) |key| if (node.object.getPtr(key)) |child| {
            const mark = try w.push(key);
            defer w.pop(mark);
            try w.walk(child, depth + 1);
        };
        for (schema_map_keywords) |key| if (node.object.getPtr(key)) |map| if (map.* == .object) {
            const mark = try w.push(key);
            defer w.pop(mark);
            for (map.object.keys(), map.object.values()) |name, *child| {
                const inner = try w.push(name);
                defer w.pop(inner);
                try w.walk(child, depth + 1);
            }
        };
        for (schema_array_keywords) |key| if (node.object.getPtr(key)) |list| if (list.* == .array) {
            const mark = try w.push(key);
            defer w.pop(mark);
            try w.walkArray(list, depth);
        };
        if (node.object.getPtr("items")) |items| {
            const mark = try w.push("items");
            defer w.pop(mark);
            switch (items.*) {
                .object => try w.walk(items, depth + 1),
                // The array form of draft-07: one schema for each position.
                .array => try w.walkArray(items, depth),
                else => {},
            }
        }
    }

    fn walkArray(w: *Walker, list: *Value, depth: usize) Allocator.Error!void {
        for (list.array.items, 0..) |*child, i| {
            var buf: [20]u8 = undefined;
            const index = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            const mark = try w.push(index);
            defer w.pop(mark);
            try w.walk(child, depth + 1);
        }
    }

    fn fixItems(w: *Walker, node: *Value) Allocator.Error!void {
        const t = node.object.get("type") orelse return;
        if (t != .string or !std.mem.eql(u8, t.string, "array")) return;
        const items = node.object.get("items") orelse return w.addItems(node, .items_added, null);
        switch (items) {
            .bool => |b| if (!b) {
                var max_items: ?usize = null;
                if (node.object.get("maxItems") == null) {
                    if (node.object.get("prefixItems")) |p| {
                        if (p == .array) max_items = p.array.items.len;
                    } else max_items = 0;
                }
                if (max_items) |n| try node.object.put(w.arena, "maxItems", .{ .integer = @intCast(n) });
                return w.addItems(node, .items_false_replaced, max_items);
            },
            // The other values that are false in JavaScript. None of them is a schema.
            .null => return w.addItems(node, .items_added, null),
            .integer => |n| if (n == 0) return w.addItems(node, .items_added, null),
            .float => |x| if (x == 0 or std.math.isNan(x)) return w.addItems(node, .items_added, null),
            .number_string => |s| if (isZero(s)) return w.addItems(node, .items_added, null),
            .string => |s| if (s.len == 0) return w.addItems(node, .items_added, null),
            .array, .object => {},
        }
    }

    /// True when the number text `s` has the value zero, for example "0", "-0" or "0.0e5".
    fn isZero(s: []const u8) bool {
        const x = std.fmt.parseFloat(f64, s) catch return false;
        return x == 0;
    }

    fn addItems(w: *Walker, node: *Value, kind: Fix.Kind, max_items: ?usize) Allocator.Error!void {
        try node.object.put(w.arena, "items", .{ .object = .empty });
        try w.record(kind, max_items);
    }

    fn record(w: *Walker, kind: Fix.Kind, max_items: ?usize) Allocator.Error!void {
        try w.fixes.append(w.arena, .{
            .tool = w.tool,
            .pointer = try w.arena.dupe(u8, w.path.items),
            .kind = kind,
            .max_items = max_items,
        });
    }

    /// Add one reference token to the pointer. Return the length before the token.
    fn push(w: *Walker, token: []const u8) Allocator.Error!usize {
        const mark = w.path.items.len;
        try w.path.append(w.arena, '/');
        for (token) |c| switch (c) {
            '~' => try w.path.appendSlice(w.arena, "~0"),
            '/' => try w.path.appendSlice(w.arena, "~1"),
            else => try w.path.append(w.arena, c),
        };
        return mark;
    }

    fn pop(w: *Walker, mark: usize) void {
        w.path.shrinkRetainingCapacity(mark);
    }
};

// ---------------------------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------------------------

/// The cause of an error that the bridge sends to the client. The members from `rpc` to
/// `invalid_meta` are the members of `mcp.Client.RequestError`. The other members are
/// failures of the bridge. The name of the member is the value of `data.cause`.
pub const Cause = enum {
    rpc,
    canceled,
    timeout,
    closed,
    transport_failed,
    invalid_response,
    too_many_rounds,
    out_of_memory,
    undeclared_input_request,
    hook_failed,
    not_connected,
    task_cancelled,
    invalid_request,
    invalid_meta,
    spawn_failed,
    discover_failed,
    upstream_exited,
    not_initialized,
    already_initialized,
    too_many_requests,
    line_too_long,
    too_deep,
    parse_error,
    invalid_request_shape,
    method_not_found,
    invalid_params,
    invalid_input_request,
    too_many_input_requests,
    input_timeout,
    invalid_client_answer,
};

/// The error object of a JSON-RPC error response to the client. `jsonStringify` writes the
/// wire form, and `toWire` gives the error type of zig-sdk.
pub const RpcError = struct {
    code: i64,
    message: []const u8,
    /// The `data` of an upstream error. The bridge ignores it when `cause` is not null.
    data: ?Value = null,
    /// The cause of an error of the bridge. It goes into `data.cause`.
    cause: ?Cause = null,
    /// More text about an error of the bridge, for example the method and the limit of a
    /// timeout. It goes into `data.detail`. It never contains a secret or the standard error
    /// output of the child process.
    detail: ?[]const u8 = null,

    pub fn jsonStringify(self: RpcError, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("code");
        try jws.write(self.code);
        try jws.objectField("message");
        try jws.write(self.message);
        if (self.cause) |cause| {
            try jws.objectField("data");
            try jws.beginObject();
            try jws.objectField("cause");
            try jws.write(@tagName(cause));
            if (self.detail) |d| {
                try jws.objectField("detail");
                try jws.write(d);
            }
            try jws.endObject();
        } else if (self.data) |d| {
            try jws.objectField("data");
            try jws.write(d);
        }
        try jws.endObject();
    }

    /// The error as `mcp.types.Error`, for `mcp.jsonrpc.message.writeErrorResponse`. The
    /// `data` object is in `arena`.
    pub fn toWire(self: RpcError, arena: Allocator) Allocator.Error!types.Error {
        const cause = self.cause orelse return .{ .code = self.code, .message = self.message, .data = self.data };
        var data: ObjectMap = .empty;
        try data.put(arena, "cause", .{ .string = @tagName(cause) });
        if (self.detail) |d| try data.put(arena, "detail", .{ .string = d });
        return .{ .code = self.code, .message = self.message, .data = .{ .object = data } };
    }
};

const Code = mcp.protocol.errors.Code;

/// The JSON-RPC code of each cause. The code is -32603 when no other code applies.
/// `invalid_request` of the upstream client gives -32602, because the transport cannot send
/// an argument of the request. `invalid_meta` also gives -32602, because the client refuses a
/// key in the `_meta` of the request. The code of `invalid_request_shape` is -32600.
pub fn codeOf(cause: Cause) i64 {
    return switch (cause) {
        .parse_error => Code.parse_error.int(),
        .not_initialized,
        .already_initialized,
        .line_too_long,
        .too_deep,
        .invalid_request_shape,
        => Code.invalid_request.int(),
        .method_not_found => Code.method_not_found.int(),
        .invalid_params, .invalid_request, .invalid_meta => Code.invalid_params.int(),
        .rpc,
        .canceled,
        .timeout,
        .closed,
        .transport_failed,
        .invalid_response,
        .too_many_rounds,
        .out_of_memory,
        .undeclared_input_request,
        .hook_failed,
        .not_connected,
        .task_cancelled,
        .spawn_failed,
        .discover_failed,
        .upstream_exited,
        .too_many_requests,
        .invalid_input_request,
        .too_many_input_requests,
        .input_timeout,
        .invalid_client_answer,
        => Code.internal_error.int(),
    };
}

/// False when the bridge sends no response for the cause. The client canceled the request,
/// thus it waits for no response.
pub fn hasResponse(cause: Cause) bool {
    return cause != .canceled;
}

/// The fixed message of each cause. The messages are field values, thus `zig build lint-docs`
/// checks them against the STE profile. VS Code shows a message after "MPC <code>: ", and the
/// model also reads it. A message never contains a secret or the standard error output of the
/// child process.
pub fn messageOf(cause: Cause) []const u8 {
    const Text = struct { message: []const u8 };
    const text: Text = switch (cause) {
        .rpc => .{ .message = "The upstream server sent an error. See the Output channel of the server." },
        .canceled => .{ .message = "The client canceled the request." },
        .timeout => .{ .message = "The upstream server did not answer in time. See the Output channel of the server." },
        .closed => .{ .message = "The upstream server process stopped. See the Output channel of the server." },
        .transport_failed => .{ .message = "The connection to the upstream server failed. See the Output channel of the server." },
        .invalid_response => .{ .message = "The upstream server sent a response that is not valid. See the Output channel of the server." },
        .too_many_rounds => .{ .message = "The upstream server asked for input too many times. See the Output channel of the server." },
        .out_of_memory => .{ .message = "The bridge does not have sufficient memory for the request." },
        .undeclared_input_request => .{ .message = "The upstream server asked for input that the client did not declare." },
        .hook_failed => .{ .message = "The bridge cannot give the input that the upstream server asked for." },
        .not_connected => .{ .message = "The bridge has no connection to the upstream server. See the Output channel of the server." },
        .task_cancelled => .{ .message = "The upstream server canceled the task of the request." },
        .invalid_request => .{ .message = "The bridge cannot send the parameters of the request to the upstream server." },
        .invalid_meta => .{ .message = "The request has a _meta key that the bridge cannot send to the upstream server." },
        .spawn_failed => .{ .message = "The bridge cannot start the upstream server. Examine the command in the configuration of the server. See the Output channel of the server." },
        .discover_failed => .{ .message = "The upstream server did not answer server/discover. It is not an MCP server of revision 2026-07-28, or it does not respond. See the Output channel of the server." },
        .upstream_exited => .{ .message = "The upstream server process stopped. See the Output channel of the server." },
        .not_initialized => .{ .message = "The client did not initialize the connection. Send initialize first." },
        .already_initialized => .{ .message = "The client already sent initialize on this connection." },
        .too_many_requests => .{ .message = mcp.transport.stdio.Server.too_many_requests_message },
        .line_too_long => .{ .message = "The request is longer than the line limit of the bridge." },
        .too_deep => .{ .message = "The request has more levels of nesting than the limit of the bridge." },
        .parse_error => .{ .message = "The request is not valid JSON." },
        .invalid_request_shape => .{ .message = "The message is not a valid JSON-RPC 2.0 request." },
        .method_not_found => .{ .message = "The server does not have this method." },
        .invalid_params => .{ .message = "The parameters of the request are not valid." },
        .invalid_input_request => .{ .message = "The upstream server sent an input request that is not valid for the client. See the Output channel of the server." },
        .too_many_input_requests => .{ .message = "The upstream server asked for more inputs at one time than the limit of the bridge." },
        .input_timeout => .{ .message = "The client did not answer the input request of the upstream server in time." },
        .invalid_client_answer => .{ .message = "The client sent an answer that is not valid for the input request of the upstream server." },
    };
    return text.message;
}

/// The error of the bridge for `cause`, with the code of `codeOf`, the message of `messageOf`
/// and `data.cause`. `detail` goes into `data.detail`. For an upstream JSON-RPC error, use
/// `fromUpstream`. `errorFor(.rpc, ...)` is only for an upstream error that the bridge does
/// not have.
pub fn errorFor(cause: Cause, detail: ?[]const u8) RpcError {
    return .{ .code = codeOf(cause), .message = messageOf(cause), .cause = cause, .detail = detail };
}

/// The cause of an error of the upstream client.
pub fn causeOf(err: mcp.Client.RequestError) Cause {
    return switch (err) {
        error.Rpc => .rpc,
        error.Canceled => .canceled,
        error.Timeout => .timeout,
        error.Closed => .closed,
        error.TransportFailed => .transport_failed,
        error.InvalidResponse => .invalid_response,
        error.TooManyRounds => .too_many_rounds,
        error.OutOfMemory => .out_of_memory,
        error.UndeclaredInputRequest => .undeclared_input_request,
        error.HookFailed => .hook_failed,
        error.NotConnected => .not_connected,
        error.TaskCancelled => .task_cancelled,
        error.InvalidRequest => .invalid_request,
        error.InvalidMeta => .invalid_meta,
    };
}

/// The code -32042 of revision 2025-11-25 (URL elicitation required). Revision 2026-07-28
/// reserves it, and VS Code opens each URL in its `data`.
pub const url_elicitation_required_code: i64 = -32042;

/// The error for the client from a JSON-RPC error of the upstream server. The code, the
/// message and the data stay the same. The only exception is -32042, which becomes -32603
/// without data.
pub fn fromUpstream(e: types.Error) RpcError {
    if (e.code == url_elicitation_required_code) return .{ .code = Code.internal_error.int(), .message = e.message };
    return .{ .code = e.code, .message = e.message, .data = e.data };
}

/// The error of an `initialize` request when `server/discover` fails with the JSON-RPC error
/// `upstream`. The error has the code of the upstream error, the message of
/// `discover_failed` and the upstream message in `data.detail`. Without an upstream error,
/// the result is `errorFor(.discover_failed, null)`. The code -32042 becomes -32603.
pub fn discoverFailed(upstream: ?types.Error) RpcError {
    var out = errorFor(.discover_failed, null);
    const e = upstream orelse return out;
    if (e.code != url_elicitation_required_code) out.code = e.code;
    out.detail = e.message;
    return out;
}

/// A time limit or a wait time as text, for `RpcError.detail` and for the log: whole seconds,
/// else milliseconds. Thus a time below one second does not show as "0 s".
pub const TimeLimit = struct {
    duration: Io.Duration,

    pub fn format(self: TimeLimit, w: *Io.Writer) Io.Writer.Error!void {
        const ms = self.duration.toMilliseconds();
        if (@rem(ms, std.time.ms_per_s) == 0) return w.print("{d} s", .{@divTrunc(ms, std.time.ms_per_s)});
        try w.print("{d} ms", .{ms});
    }
};

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

const test_profile: Profile = .{ .name = "mcp-bridge-test", .quirks = .{ .normalize_array_items = true } };
const plain_profile: Profile = .{ .name = "mcp-bridge-plain" };
const strict_profile: Profile = .{ .name = "mcp-bridge-strict", .quirks = .{ .strict_legacy_results = true } };

fn parse(arena: Allocator, text: []const u8) !Value {
    return mcp.json.parseTree(arena, text);
}

fn expectJson(arena: Allocator, expected: []const u8, value: anytype) !void {
    try testing.expectEqualStrings(expected, try mcp.json.writeAlloc(arena, value));
}

/// The capabilities of the `initialize` request of VS Code 1.140.0.
const vscode_capabilities =
    \\{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}},
    \\"tasks":{"list":{},"cancel":{}},"experimental":{"x":{"a":1}},
    \\"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]},"io.modelcontextprotocol/tasks":{}}}
;

test "upstream capabilities of VS Code with the default mask" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try parse(arena, vscode_capabilities);
    const out = try upstreamCapabilities(arena, caps, .{});
    // The input kinds go upstream as VS Code declared them: roots without listChanged, and
    // sampling without context and tools.
    try testing.expect(out.hasElicitation(.form));
    try testing.expect(out.hasElicitation(.url));
    try testing.expect(out.sampling.?.tools == null);
    try testing.expect(out.sampling.?.context == null);
    try testing.expect(out.roots != null);
    try testing.expect(!out.hasExtension(mcp.tasks.extension_id));
    try testing.expect(out.hasExtension(mcp.protocol.apps.extension_id));
    try expectJson(arena,
        \\{"experimental":{"x":{"a":1}},"roots":{},"sampling":{},"elicitation":{"form":{},"url":{}},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}
    , out);
}

test "upstream capabilities without the input kinds" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try parse(arena, vscode_capabilities);
    const out = try upstreamCapabilities(arena, caps, .{ .sampling = false, .elicitation = false, .roots = false });
    try testing.expect(out.sampling == null);
    try testing.expect(out.elicitation == null);
    try testing.expect(out.roots == null);
    try expectJson(arena,
        \\{"experimental":{"x":{"a":1}},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}
    , out);
    // A client that declares only the form mode.
    const form_only = try upstreamCapabilities(arena, try parse(arena, "{\"elicitation\":{}}"), .{});
    try testing.expect(form_only.hasElicitation(.form));
    try testing.expect(!form_only.hasElicitation(.url));
}

test "upstream capabilities with all input requests" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try parse(arena,
        \\{"roots":{"listChanged":true},"sampling":{"context":{},"tools":{}},"elicitation":{"form":{},"url":{}},"tasks":{}}
    );
    const out = try upstreamCapabilities(arena, caps, .{ .sampling = true, .elicitation = true, .roots = true });
    try testing.expect(out.hasElicitation(.form));
    try testing.expect(out.hasElicitation(.url));
    try expectJson(arena,
        \\{"roots":{},"sampling":{"context":{},"tools":{}},"elicitation":{"form":{},"url":{}}}
    , out);
}

test "upstream capabilities of the Copilot harness" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try parse(arena,
        \\{"sampling":{},"elicitation":{"form":{},"url":{}}}
    );
    // The harness declares no roots.
    try expectJson(arena,
        \\{"sampling":{},"elicitation":{"form":{},"url":{}}}
    , try upstreamCapabilities(arena, caps, .{}));
    try expectJson(arena, "{}", try upstreamCapabilities(arena, caps, .{ .sampling = false, .elicitation = false, .roots = false }));
}

test "upstream capabilities drop the members that are not valid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all: CapabilityMask = .{ .sampling = true, .elicitation = true, .roots = true };
    const caps = try parse(arena,
        \\{"roots":true,"sampling":{"context":7},"elicitation":[],"experimental":{"a":1,"b":{}},
        \\"extensions":{"io.modelcontextprotocol/tasks":{}}}
    );
    try expectJson(arena,
        \\{"experimental":{"b":{}},"sampling":{}}
    , try upstreamCapabilities(arena, caps, all));
    const wrong_settings = try parse(arena,
        \\{"elicitation":{"form":true,"url":{}},"sampling":{"tools":[]}}
    );
    try expectJson(arena,
        \\{"sampling":{},"elicitation":{"url":{}}}
    , try upstreamCapabilities(arena, wrong_settings, all));
    try expectJson(arena, "{}", try upstreamCapabilities(arena, .null, all));
    try expectJson(arena, "{}", try upstreamCapabilities(arena, .{ .object = .empty }, all));
    const no_extra = try upstreamCapabilities(arena, try parse(arena,
        \\{"experimental":{"x":{}},"extensions":{"y":{}},"roots":{}}
    ), .{ .experimental = false, .extensions = false, .roots = false });
    try expectJson(arena, "{}", no_extra);
}

/// A discover result of a zig-sdk server with each capability.
const full_discover =
    \\{"resultType":"complete","ttlMs":60000,"cacheScope":"public","supportedVersions":["2026-07-28"],
    \\"capabilities":{"experimental":{"e":{}},"logging":{},"completions":{},"prompts":{"listChanged":true},
    \\"resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true},"tasks":{"list":{}},
    \\"extensions":{"io.modelcontextprotocol/ui":{},"io.modelcontextprotocol/tasks":{}}},
    \\"instructions":"Use the tools.",
    \\"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"fixture","title":"Fixture","version":"1.2.3",
    \\"icons":[{"src":"data:image/png;base64,AA==","mimeType":"image/png"}],"description":"A server.",
    \\"websiteUrl":"https://example.com","extra":1}}}
;

test "initialize result from a full discover result" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const discover = try parse(arena, full_discover);
    const result = try initializeResult(arena, discover, .{ .profile = &test_profile, .fallback_name = "fixture-server" });
    try expectJson(arena,
        \\{"protocolVersion":"2025-11-25","capabilities":{"experimental":{"e":{}},"completions":{},"prompts":{},"resources":{},"tools":{},"extensions":{"io.modelcontextprotocol/ui":{}}},
    ++
        \\"serverInfo":{"name":"fixture","title":"Fixture","version":"1.2.3","icons":[{"src":"data:image/png;base64,AA==","mimeType":"image/png"}],"description":"A server.","websiteUrl":"https://example.com"},
    ++
        \\"instructions":"Use the tools."}
    , result);
    // The members that revision 2025-11-25 does not have are not in the result.
    try testing.expect(result.object.get("resultType") == null);
    try testing.expect(result.object.get("ttlMs") == null);
    try testing.expect(result.object.get("cacheScope") == null);
    try testing.expect(result.object.get("capabilities").?.object.get("tasks") == null);
}

test "initialize result with notifications in the reply mask" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const discover = try parse(arena, full_discover);
    const all = try initializeResult(arena, discover, .{
        .profile = &test_profile,
        .fallback_name = "x",
        .mask = .{ .list_changed = true, .subscribe = true, .logging = true },
    });
    try expectJson(arena,
        \\{"experimental":{"e":{}},"logging":{},"completions":{},"prompts":{"listChanged":true},"resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true},"extensions":{"io.modelcontextprotocol/ui":{}}}
    , all.object.get("capabilities").?);
    const subscribe_only = try initializeResult(arena, discover, .{ .profile = &test_profile, .fallback_name = "x", .mask = .{ .subscribe = true } });
    try expectJson(arena,
        \\{"subscribe":true}
    , subscribe_only.object.get("capabilities").?.object.get("resources").?);
    const list_changed_only = try initializeResult(arena, discover, .{ .profile = &test_profile, .fallback_name = "x", .mask = .{ .list_changed = true } });
    try expectJson(arena,
        \\{"listChanged":true}
    , list_changed_only.object.get("capabilities").?.object.get("resources").?);
}

test "initialize result without server information uses the fallback name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const discover = try parse(arena,
        \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}
    );
    const result = try initializeResult(arena, discover, .{ .profile = &test_profile, .fallback_name = "my-server", .fallback_version = "9.9.9" });
    try expectJson(arena,
        \\{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"my-server","version":"9.9.9"}}
    , result);
    // The default version is the version of the package.
    const default_version = try initializeResult(arena, discover, .{ .profile = &test_profile, .fallback_name = "my-server" });
    try testing.expectEqualStrings(bridge.version, mcp.json.getString(default_version.object.get("serverInfo").?, "version").?);
}

test "initialize result never has an empty server name" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An empty name and a server information without a version are not valid.
    for ([_][]const u8{
        \\{"capabilities":{},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"","version":"1"}}}
        ,
        \\{"capabilities":{},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"a"}}}
        ,
        \\{"capabilities":{},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"a","version":"1","icons":[{"mimeType":"image/png"}]}}}
        ,
        \\{"capabilities":{},"_meta":{"io.modelcontextprotocol/serverInfo":"a"}}
        ,
        \\{"capabilities":{},"_meta":7}
    }) |text| {
        const result = try initializeResult(arena, try parse(arena, text), .{ .profile = &test_profile, .fallback_name = "fallback", .fallback_version = "1.0.0" });
        try expectJson(arena,
            \\{"name":"fallback","version":"1.0.0"}
        , result.object.get("serverInfo").?);
    }
    // An empty fallback name gives the name of the profile.
    const result = try initializeResult(arena, try parse(arena, "{\"capabilities\":{}}"), .{ .profile = &test_profile, .fallback_name = "", .fallback_version = "1.0.0" });
    try expectJson(arena,
        \\{"name":"mcp-bridge-test","version":"1.0.0"}
    , result.object.get("serverInfo").?);
}

test "initialize result from a discover result that is not valid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const opts: InitOpts = .{ .profile = &test_profile, .fallback_name = "f", .fallback_version = "1" };
    const expected =
        \\{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"f","version":"1"}}
    ;
    try expectJson(arena, expected, try initializeResult(arena, .null, opts));
    try expectJson(arena, expected, try initializeResult(arena, try parse(arena, "{\"capabilities\":[],\"instructions\":7}"), opts));
    try expectJson(arena, expected, try initializeResult(arena, try parse(arena,
        \\{"capabilities":{"tools":true,"prompts":[],"resources":1,"completions":"x","experimental":2,"logging":{},"extensions":{"a":1}}}
    ), opts));
}

test "forward params remove _meta and task and keep the progress token" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parse(arena,
        \\{"name":"echo","arguments":{"text":"hi","_meta":1},"task":{"ttl":1000},
        \\"_meta":{"progressToken":"5c2e7a61-1f0e-4a43-9b38-6e0c2bdbd2f4","vscode.conversationId":"c","vscode.requestId":"r","traceparent":"00-ab-cd-01"}}
    );
    const before = try mcp.json.writeAlloc(arena, params);
    const f = try forwardParams(arena, params, &test_profile);
    try expectJson(arena,
        \\{"name":"echo","arguments":{"text":"hi","_meta":1}}
    , f.params);
    try testing.expectEqualStrings("5c2e7a61-1f0e-4a43-9b38-6e0c2bdbd2f4", f.progress_token.?.string);
    // The parameters of the client stay the same.
    try expectJson(arena, before, params);
}

test "forward params without params give an empty object" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none = try forwardParams(arena, null, &test_profile);
    try expectJson(arena, "{}", none.params);
    try testing.expect(none.progress_token == null);
    const not_object = try forwardParams(arena, .{ .integer = 1 }, &test_profile);
    try expectJson(arena, "{}", not_object.params);
    const cursor = try forwardParams(arena, try parse(arena, "{\"cursor\":\"abc\"}"), &test_profile);
    try expectJson(arena, "{\"cursor\":\"abc\"}", cursor.params);
    try testing.expect(cursor.progress_token == null);
}

test "forward params keep each scalar progress token, also 0" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zero = try forwardParams(arena, try parse(arena, "{\"_meta\":{\"progressToken\":0}}"), &test_profile);
    try expectJson(arena, "{}", zero.params);
    try testing.expectEqual(@as(i64, 0), zero.progress_token.?.integer);
    const float = try forwardParams(arena, try parse(arena, "{\"_meta\":{\"progressToken\":1.5}}"), &test_profile);
    try testing.expect(float.progress_token.? == .float);
    const big = try forwardParams(arena, try parse(arena, "{\"_meta\":{\"progressToken\":123456789012345678901234567890}}"), &test_profile);
    try testing.expect(big.progress_token.? == .number_string);
    const boolean = try forwardParams(arena, try parse(arena, "{\"_meta\":{\"progressToken\":false}}"), &test_profile);
    try testing.expect(boolean.progress_token.? == .bool);
    for ([_][]const u8{
        "{\"_meta\":{\"progressToken\":null}}",
        "{\"_meta\":{\"progressToken\":{}}}",
        "{\"_meta\":{\"progressToken\":[1]}}",
        "{\"_meta\":{\"token\":1}}",
        "{\"_meta\":5}",
    }) |text| {
        const f = try forwardParams(arena, try parse(arena, text), &test_profile);
        try testing.expect(f.progress_token == null);
        try expectJson(arena, "{}", f.params);
    }
}

test "shape result removes the members of revision 2026-07-28" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try parse(arena,
        \\{"resultType":"complete","ttlMs":1000,"cacheScope":"public","contents":[],
        \\"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"s","version":"1"}}}
    );
    const shaped = try shapeResult(arena, "resources/read", raw, &test_profile);
    try expectJson(arena, "{\"contents\":[]}", shaped.result);
    try testing.expectEqual(0, shaped.fixes.len);
    // Other _meta keys stay.
    const other = try shapeResult(arena, "prompts/get", try parse(arena,
        \\{"messages":[],"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"s","version":"1"},"k":1}}
    ), &test_profile);
    try expectJson(arena, "{\"messages\":[],\"_meta\":{\"k\":1}}", other.result);
    // A result that is not an object stays as it is.
    const scalar = try shapeResult(arena, "tools/list", .{ .integer = 3 }, &test_profile);
    try testing.expectEqual(@as(i64, 3), scalar.result.integer);
}

test "shape result removes a nextCursor that is not a string from a list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "tools/list", "prompts/list", "resources/list", "resources/templates/list" }) |method| {
        const null_cursor = try shapeResult(arena, method, try parse(arena, "{\"items\":[],\"nextCursor\":null}"), &plain_profile);
        try expectJson(arena, "{\"items\":[]}", null_cursor.result);
        const number_cursor = try shapeResult(arena, method, try parse(arena, "{\"items\":[],\"nextCursor\":2}"), &plain_profile);
        try expectJson(arena, "{\"items\":[]}", number_cursor.result);
        const string_cursor = try shapeResult(arena, method, try parse(arena, "{\"items\":[],\"nextCursor\":\"p2\"}"), &plain_profile);
        try expectJson(arena, "{\"items\":[],\"nextCursor\":\"p2\"}", string_cursor.result);
        const empty_cursor = try shapeResult(arena, method, try parse(arena, "{\"items\":[],\"nextCursor\":\"\"}"), &plain_profile);
        try expectJson(arena, "{\"items\":[],\"nextCursor\":\"\"}", empty_cursor.result);
    }
    // Other methods keep the member.
    const other = try shapeResult(arena, "completion/complete", try parse(arena, "{\"completion\":{\"values\":[]},\"nextCursor\":null}"), &plain_profile);
    try expectJson(arena, "{\"completion\":{\"values\":[]},\"nextCursor\":null}", other.result);
}

fn shapeTools(arena: Allocator, schema: []const u8) !Shaped {
    const text = try std.fmt.allocPrint(arena, "{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"t\",\"inputSchema\":{s}}}]}}", .{schema});
    return shapeResult(arena, "tools/list", try parse(arena, text), &test_profile);
}

fn inputSchema(shaped: Shaped) Value {
    return shaped.result.object.get("tools").?.array.items[0].object.get("inputSchema").?;
}

test "normalize a bare array" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"object","properties":{"values":{"type":"array","description":"Any"}}}
    );
    try expectJson(arena,
        \\{"type":"object","properties":{"values":{"type":"array","description":"Any","items":{}}}}
    , inputSchema(shaped));
    try testing.expectEqual(1, shaped.fixes.len);
    try testing.expectEqualStrings("t", shaped.fixes[0].tool);
    try testing.expectEqualStrings("/properties/values", shaped.fixes[0].pointer);
    try testing.expectEqual(Fix.Kind.items_added, shaped.fixes[0].kind);
    try testing.expect(shaped.fixes[0].max_items == null);
}

test "normalize an array with prefixItems only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"object","properties":{"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"array"}]}}}
    );
    try expectJson(arena,
        \\{"type":"object","properties":{"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"array","items":{}}],"items":{}}}}
    , inputSchema(shaped));
    try testing.expectEqual(2, shaped.fixes.len);
    try testing.expectEqualStrings("/properties/pair", shaped.fixes[0].pointer);
    try testing.expectEqualStrings("/properties/pair/prefixItems/1", shaped.fixes[1].pointer);
}

test "normalize prefixItems with items false" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"object","properties":{"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":false}}}
    );
    try expectJson(arena,
        \\{"type":"object","properties":{"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":{},"maxItems":2}}}
    , inputSchema(shaped));
    try testing.expectEqual(1, shaped.fixes.len);
    try testing.expectEqual(Fix.Kind.items_false_replaced, shaped.fixes[0].kind);
    try testing.expectEqual(@as(?usize, 2), shaped.fixes[0].max_items);
}

test "normalize items false keeps a maxItems and limits an array without prefixItems" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"object","properties":{"a":{"type":"array","prefixItems":[{}],"items":false,"maxItems":1},"b":{"type":"array","items":false},"c":{"type":"array","items":null}}}
    );
    try expectJson(arena,
        \\{"type":"object","properties":{"a":{"type":"array","prefixItems":[{}],"items":{},"maxItems":1},"b":{"type":"array","items":{},"maxItems":0},"c":{"type":"array","items":{}}}}
    , inputSchema(shaped));
    try testing.expectEqual(3, shaped.fixes.len);
    try testing.expect(shaped.fixes[0].max_items == null);
    try testing.expectEqual(@as(?usize, 0), shaped.fixes[1].max_items);
    try testing.expectEqual(Fix.Kind.items_added, shaped.fixes[2].kind);
}

test "normalize items that are false in JavaScript: 0, 0.0, -0 and the empty string" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"object","properties":{"a":{"type":"array","items":0},"b":{"type":"array","items":0.0},"c":{"type":"array","items":-0},"d":{"type":"array","items":""},"e":{"type":"array","prefixItems":[{}],"items":0}}}
    );
    // Only `items: false` gets a `maxItems`.
    try expectJson(arena,
        \\{"type":"object","properties":{"a":{"type":"array","items":{}},"b":{"type":"array","items":{}},"c":{"type":"array","items":{}},"d":{"type":"array","items":{}},"e":{"type":"array","prefixItems":[{}],"items":{}}}}
    , inputSchema(shaped));
    try testing.expectEqual(5, shaped.fixes.len);
    for (shaped.fixes) |fix| {
        try testing.expectEqual(Fix.Kind.items_added, fix.kind);
        try testing.expect(fix.max_items == null);
    }
    // A value that is true in JavaScript stays as it is, also when it is not a schema.
    const kept = try shapeTools(arena,
        \\{"type":"object","properties":{"a":{"type":"array","items":1},"b":{"type":"array","items":"x"},"c":{"type":"array","items":true}}}
    );
    try testing.expectEqual(0, kept.fixes.len);
}

test "normalize arrays under properties, anyOf and additionalProperties" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"object","properties":{"choice":{"anyOf":[{"type":"array"},{"type":"string"}]},
        \\"nested":{"type":"object","properties":{"deep":{"type":"array","items":{"type":"array"}}}}},
        \\"additionalProperties":{"type":"array"},"patternProperties":{"^x/y~z$":{"type":"array"}},
        \\"$defs":{"list":{"type":"array"}},"definitions":{"old":{"type":"array"}},
        \\"allOf":[{"oneOf":[{"not":{"type":"array"}}]}],"if":{"type":"array"},"then":{"type":"array"},"else":{"type":"array"},
        \\"dependencies":{"a":["b"],"c":{"type":"array"}},"dependentSchemas":{"d":{"type":"array"}},
        \\"contains":{"type":"array"},"items":[{"type":"array"}]}
    );
    // The walk order: the single schemas, the objects of schemas, the arrays of schemas, then
    // `items`.
    const expected = [_][]const u8{
        "/additionalProperties",
        "/if",
        "/then",
        "/else",
        "/contains",
        "/properties/choice/anyOf/0",
        "/properties/nested/properties/deep/items",
        "/patternProperties/^x~1y~0z$",
        "/dependencies/c",
        "/dependentSchemas/d",
        "/$defs/list",
        "/definitions/old",
        "/allOf/0/oneOf/0/not",
        "/items/0",
    };
    try testing.expectEqual(expected.len, shaped.fixes.len);
    for (expected, shaped.fixes) |pointer, fix| {
        try testing.expectEqualStrings(pointer, fix.pointer);
        try testing.expectEqual(Fix.Kind.items_added, fix.kind);
    }
    // A second walk finds nothing to change.
    var again: std.ArrayList(Fix) = .empty;
    var schema = inputSchema(shaped);
    try normalizeArrayItems(arena, "t", &schema, &again);
    try testing.expectEqual(0, again.items.len);
}

test "normalize leaves type arrays and boolean schemas as they are" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema =
        \\{"type":"object","properties":{"a":{"type":["array","null"]},"b":true,"c":false,"d":{"type":"array","items":true},"e":{"type":"array","items":{"type":"string"}},"f":{"type":"Array"}},"additionalProperties":false}
    ;
    const shaped = try shapeTools(arena, schema);
    try expectJson(arena, schema, inputSchema(shaped));
    try testing.expectEqual(0, shaped.fixes.len);
}

test "normalize the root schema and escape the pointer" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"array","properties":{"a/b":{"type":"array"},"~":{"type":"array"},"":{"type":"array"}}}
    );
    try testing.expectEqual(4, shaped.fixes.len);
    try testing.expectEqualStrings("", shaped.fixes[0].pointer);
    try testing.expectEqualStrings("/properties/a~1b", shaped.fixes[1].pointer);
    try testing.expectEqualStrings("/properties/~0", shaped.fixes[2].pointer);
    try testing.expectEqualStrings("/properties/", shaped.fixes[3].pointer);
}

test "normalize stops at the depth limit" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A chain of `not` schemas, max_schema_depth + 2 deep, with a bare array at each level.
    var text: std.ArrayList(u8) = .empty;
    const levels = max_schema_depth + 2;
    for (0..levels) |_| try text.appendSlice(arena, "{\"type\":\"array\",\"not\":");
    try text.appendSlice(arena, "{\"type\":\"array\"}");
    for (0..levels) |_| try text.append(arena, '}');
    const shaped = try shapeTools(arena, text.items);
    // The levels 0 to max_schema_depth get items. The next level has a too_deep fix.
    try testing.expectEqual(max_schema_depth + 2, shaped.fixes.len);
    for (shaped.fixes[0 .. max_schema_depth + 1]) |fix| try testing.expectEqual(Fix.Kind.items_added, fix.kind);
    const last = shaped.fixes[max_schema_depth + 1];
    try testing.expectEqual(Fix.Kind.too_deep, last.kind);
    try testing.expectEqual((max_schema_depth + 1) * "/not".len, last.pointer.len);
    // The schema below the limit stays without items.
    var node = inputSchema(shaped);
    for (0..max_schema_depth + 1) |_| {
        try testing.expect(node.object.get("items") != null);
        node = node.object.get("not").?;
    }
    try testing.expect(node.object.get("items") == null);
}

test "normalize every tool of a page and only with the quirk" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page =
        \\{"tools":[{"name":"a","inputSchema":{"type":"object","properties":{"x":{"type":"array"}}}},
        \\{"name":"b","inputSchema":{"type":"object"}},7,{"name":"c"},
        \\{"name":"d","inputSchema":{"type":"object","properties":{"y":{"type":"array"}}}}],"nextCursor":null}
    ;
    const shaped = try shapeResult(arena, "tools/list", try parse(arena, page), &test_profile);
    try testing.expectEqual(2, shaped.fixes.len);
    try testing.expectEqualStrings("a", shaped.fixes[0].tool);
    try testing.expectEqualStrings("d", shaped.fixes[1].tool);
    try testing.expect(shaped.result.object.get("nextCursor") == null);
    const plain = try shapeResult(arena, "tools/list", try parse(arena, page), &plain_profile);
    try testing.expectEqual(0, plain.fixes.len);
    try testing.expect(plain.result.object.get("tools").?.array.items[0].object.get("inputSchema").?.object.get("properties").?.object.get("x").?.object.get("items") == null);
    // Only tools/list gets the walk.
    const call = try shapeResult(arena, "tools/call", try parse(arena,
        \\{"content":[],"inputSchema":{"type":"array"}}
    ), &test_profile);
    try testing.expectEqual(0, call.fixes.len);
}

test "the schema of the fixture tool bare_array" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeTools(arena,
        \\{"type":"object","properties":{"values":{"type":"array","description":"Any values"},"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":false},"choice":{"anyOf":[{"type":"array"},{"type":"string"}]}},"required":["values"],"additionalProperties":false}
    );
    try expectJson(arena,
        \\{"type":"object","properties":{"values":{"type":"array","description":"Any values","items":{}},"pair":{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":{},"maxItems":2},"choice":{"anyOf":[{"type":"array","items":{}},{"type":"string"}]}},"required":["values"],"additionalProperties":false}
    , inputSchema(shaped));
    try testing.expectEqual(3, shaped.fixes.len);
}

test "tools/call result with structuredContent and no text block gets a text mirror" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shaped = try shapeResult(arena, "tools/call", try parse(arena,
        \\{"resultType":"complete","content":[{"type":"image","data":"AA==","mimeType":"image/png"}],"structuredContent":{"text":"hi","length":2}}
    ), &test_profile);
    try expectJson(arena,
        \\{"content":[{"type":"image","data":"AA==","mimeType":"image/png"},{"type":"text","text":"{\"text\":\"hi\",\"length\":2}"}],"structuredContent":{"text":"hi","length":2}}
    , shaped.result);
}

test "tools/call result keeps a structuredContent of each JSON type" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const array = try shapeResult(arena, "tools/call", try parse(arena, "{\"structuredContent\":[1,2]}"), &test_profile);
    try expectJson(arena, "{\"structuredContent\":[1,2],\"content\":[{\"type\":\"text\",\"text\":\"[1,2]\"}]}", array.result);
    const zero = try shapeResult(arena, "tools/call", try parse(arena, "{\"content\":[],\"structuredContent\":0}"), &test_profile);
    try expectJson(arena, "{\"content\":[{\"type\":\"text\",\"text\":\"0\"}],\"structuredContent\":0}", zero.result);
    // A JSON null is no structured content.
    const null_content = try shapeResult(arena, "tools/call", try parse(arena, "{\"content\":[],\"structuredContent\":null}"), &test_profile);
    try expectJson(arena, "{\"content\":[],\"structuredContent\":null}", null_content.result);
}

test "tools/call result with a text block gets no mirror" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "{\"content\":[{\"type\":\"text\",\"text\":\"own\"}],\"structuredContent\":{\"a\":1},\"isError\":false}";
    const shaped = try shapeResult(arena, "tools/call", try parse(arena, text), &test_profile);
    try expectJson(arena, text, shaped.result);
}

test "tools/call result always has a content array" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const missing = try shapeResult(arena, "tools/call", try parse(arena, "{\"resultType\":\"complete\",\"isError\":true}"), &test_profile);
    try expectJson(arena, "{\"isError\":true,\"content\":[]}", missing.result);
    const not_array = try shapeResult(arena, "tools/call", try parse(arena, "{\"content\":{}}"), &test_profile);
    try expectJson(arena, "{\"content\":[]}", not_array.result);
    // Other methods do not get a content array.
    const read = try shapeResult(arena, "resources/read", try parse(arena, "{\"contents\":[]}"), &test_profile);
    try expectJson(arena, "{\"contents\":[]}", read.result);
}

test "strict legacy results are off for the default profile" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "{\"tools\":[{\"name\":\"a\",\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":{\"type\":\"array\"}}]}";
    const unchanged = strictLegacyResult("tools/list", try parse(arena, text), &plain_profile);
    try expectJson(arena, text, unchanged);
    const call = try shapeResult(arena, "tools/call", try parse(arena, "{\"content\":[],\"structuredContent\":[1]}"), &plain_profile);
    try testing.expect(call.result.object.get("structuredContent") != null);
}

test "the quirk drop_non_object_output_schema removes only the output schemas that are not object schemas" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile: Profile = .{ .name = "mcp-bridge-test", .quirks = .{ .drop_non_object_output_schema = true } };
    const list = try shapeResult(arena, "tools/list", try parse(arena,
        \\{"tools":[{"name":"a","inputSchema":{"type":"object"},"outputSchema":{"type":"array","items":{"type":"integer"}}},
        \\{"name":"b","inputSchema":{"type":"object"},"outputSchema":{"type":"object"}},
        \\{"name":"c","inputSchema":{"type":"object"},"outputSchema":true},{"name":"d","inputSchema":{"type":"object"}}]}
    ), &profile);
    try expectJson(arena,
        \\{"tools":[{"name":"a","inputSchema":{"type":"object"}},{"name":"b","inputSchema":{"type":"object"},"outputSchema":{"type":"object"}},{"name":"c","inputSchema":{"type":"object"}},{"name":"d","inputSchema":{"type":"object"}}]}
    , list.result);
    // The quirk does not change the structured content of a call.
    const call = try shapeResult(arena, "tools/call", try parse(arena, "{\"content\":[],\"structuredContent\":[1]}"), &profile);
    try testing.expect(call.result.object.get("structuredContent").? == .array);
}

test "strict legacy results remove the values that revision 2025-11-25 does not allow" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try shapeResult(arena, "tools/list", try parse(arena,
        \\{"tools":[{"name":"a","inputSchema":{"type":"object"},"outputSchema":{"type":"array"}},
        \\{"name":"b","inputSchema":{"type":"object"},"outputSchema":{"type":"object"}},
        \\{"name":"c","inputSchema":{"type":"object"},"outputSchema":true}]}
    ), &strict_profile);
    try expectJson(arena,
        \\{"tools":[{"name":"a","inputSchema":{"type":"object"}},{"name":"b","inputSchema":{"type":"object"},"outputSchema":{"type":"object"}},{"name":"c","inputSchema":{"type":"object"}}]}
    , list.result);
    const call = try shapeResult(arena, "tools/call", try parse(arena, "{\"structuredContent\":[1]}"), &strict_profile);
    try expectJson(arena, "{\"content\":[{\"type\":\"text\",\"text\":\"[1]\"}]}", call.result);
    const object = try shapeResult(arena, "tools/call", try parse(arena, "{\"structuredContent\":{\"a\":1}}"), &strict_profile);
    try testing.expect(object.result.object.get("structuredContent") != null);
}

test "input required results" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(isInputRequired(try parse(arena, "{\"resultType\":\"input_required\",\"inputRequests\":{}}")));
    try testing.expect(!isInputRequired(try parse(arena, "{\"resultType\":\"complete\"}")));
    try testing.expect(!isInputRequired(try parse(arena, "{}")));
    try testing.expect(!isInputRequired(.null));
}

test "error table" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectJson(arena,
        \\{"code":-32603,"message":"The upstream server process stopped. See the Output channel of the server.","data":{"cause":"upstream_exited"}}
    , errorFor(.upstream_exited, null));
    try expectJson(arena,
        \\{"code":-32603,"message":"The upstream server did not answer in time. See the Output channel of the server.","data":{"cause":"timeout","detail":"tools/call after 3600 s"}}
    , errorFor(.timeout, "tools/call after 3600 s"));
    try expectJson(arena,
        \\{"code":-32600,"message":"The client did not initialize the connection. Send initialize first.","data":{"cause":"not_initialized"}}
    , errorFor(.not_initialized, null));
    try expectJson(arena,
        \\{"code":-32603,"message":"The connection has too many requests in flight","data":{"cause":"too_many_requests"}}
    , errorFor(.too_many_requests, null));
    try testing.expectEqual(@as(i64, -32700), errorFor(.parse_error, null).code);
    try testing.expectEqual(@as(i64, -32600), errorFor(.line_too_long, "1024 bytes").code);
    try testing.expectEqual(@as(i64, -32600), errorFor(.too_deep, null).code);
    try testing.expectEqual(@as(i64, -32600), errorFor(.invalid_request_shape, null).code);
    try testing.expectEqual(@as(i64, -32600), errorFor(.already_initialized, null).code);
    try testing.expectEqual(@as(i64, -32601), errorFor(.method_not_found, null).code);
    try testing.expectEqual(@as(i64, -32602), errorFor(.invalid_params, null).code);
    try testing.expectEqual(@as(i64, -32602), errorFor(.invalid_request, null).code);
    try testing.expectEqual(@as(i64, -32602), errorFor(.invalid_meta, null).code);
    try testing.expectEqual(@as(i64, -32603), errorFor(.discover_failed, null).code);
    try testing.expectEqual(@as(i64, -32603), errorFor(.undeclared_input_request, null).code);
    try testing.expectEqual(@as(i64, -32603), errorFor(.too_many_input_requests, null).code);
    try testing.expectEqual(@as(i64, -32603), errorFor(.invalid_client_answer, null).code);
    // Each cause has a code, a message that ends with a period and its name in data.cause.
    for (std.enums.values(Cause)) |cause| {
        const e = errorFor(cause, null);
        try testing.expect(e.code < 0);
        try testing.expect(e.message.len != 0);
        if (cause != .too_many_requests) try testing.expect(std.mem.endsWith(u8, e.message, "."));
        const wire = try e.toWire(arena);
        try testing.expectEqualStrings(@tagName(cause), mcp.json.getString(wire.data.?, "cause").?);
        // The two wire forms are the same.
        try testing.expectEqualStrings(try mcp.json.writeAlloc(arena, wire), try mcp.json.writeAlloc(arena, e));
    }
    try testing.expect(!hasResponse(.canceled));
    try testing.expect(hasResponse(.timeout));
}

test "error table covers each member of RequestError" {
    const E = mcp.Client.RequestError;
    try testing.expectEqual(Cause.rpc, causeOf(E.Rpc));
    try testing.expectEqual(Cause.canceled, causeOf(E.Canceled));
    try testing.expectEqual(Cause.timeout, causeOf(E.Timeout));
    try testing.expectEqual(Cause.closed, causeOf(E.Closed));
    try testing.expectEqual(Cause.transport_failed, causeOf(E.TransportFailed));
    try testing.expectEqual(Cause.invalid_response, causeOf(E.InvalidResponse));
    try testing.expectEqual(Cause.too_many_rounds, causeOf(E.TooManyRounds));
    try testing.expectEqual(Cause.out_of_memory, causeOf(E.OutOfMemory));
    try testing.expectEqual(Cause.undeclared_input_request, causeOf(E.UndeclaredInputRequest));
    try testing.expectEqual(Cause.hook_failed, causeOf(E.HookFailed));
    try testing.expectEqual(Cause.not_connected, causeOf(E.NotConnected));
    try testing.expectEqual(Cause.task_cancelled, causeOf(E.TaskCancelled));
    try testing.expectEqual(Cause.invalid_request, causeOf(E.InvalidRequest));
    try testing.expectEqual(Cause.invalid_meta, causeOf(E.InvalidMeta));
    // The names of the causes are the names of the errors in snake case.
    inline for (@typeInfo(E).error_set.?) |member| {
        const cause = causeOf(@field(E, member.name));
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        for (member.name, 0..) |c, i| {
            if (std.ascii.isUpper(c)) {
                if (i != 0) {
                    buf[len] = '_';
                    len += 1;
                }
                buf[len] = std.ascii.toLower(c);
            } else buf[len] = c;
            len += 1;
        }
        try testing.expectEqualStrings(buf[0..len], @tagName(cause));
    }
}

test "upstream errors pass unchanged except -32042" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try parse(arena, "{\"uri\":\"file:///x\"}");
    try expectJson(arena,
        \\{"code":-32602,"message":"Resource not found: file:///x","data":{"uri":"file:///x"}}
    , fromUpstream(.{ .code = -32602, .message = "Resource not found: file:///x", .data = data }));
    try expectJson(arena,
        \\{"code":-31429,"message":"Too many tool calls"}
    , fromUpstream(.{ .code = -31429, .message = "Too many tool calls" }));
    const elicitations = try parse(arena, "{\"elicitations\":[{\"url\":\"vscode://x\"}]}");
    try expectJson(arena,
        \\{"code":-32603,"message":"URL elicitation required"}
    , fromUpstream(.{ .code = -32042, .message = "URL elicitation required", .data = elicitations }));
    const wire = try fromUpstream(.{ .code = -32042, .message = "m", .data = elicitations }).toWire(arena);
    try testing.expect(wire.data == null);
}

test "discover failure keeps the upstream code" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectJson(arena,
        \\{"code":-32601,"message":"The upstream server did not answer server/discover. It is not an MCP server of revision 2026-07-28, or it does not respond. See the Output channel of the server.","data":{"cause":"discover_failed","detail":"Method not found"}}
    , discoverFailed(.{ .code = -32601, .message = "Method not found" }));
    try testing.expectEqual(@as(i64, -32603), discoverFailed(null).code);
    try testing.expect(discoverFailed(null).detail == null);
    try testing.expectEqual(@as(i64, -32603), discoverFailed(.{ .code = -32042, .message = "x" }).code);
}

test "a time limit as text" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("60 s", try std.fmt.bufPrint(&buf, "{f}", .{TimeLimit{ .duration = .fromSeconds(60) }}));
    try testing.expectEqualStrings("300 ms", try std.fmt.bufPrint(&buf, "{f}", .{TimeLimit{ .duration = .fromMilliseconds(300) }}));
    try testing.expectEqualStrings("1500 ms", try std.fmt.bufPrint(&buf, "{f}", .{TimeLimit{ .duration = .fromMilliseconds(1500) }}));
}
