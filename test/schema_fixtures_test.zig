//! Checks that the vendored schemas compile with the zig-sdk validator. For each schema, one
//! definition must accept a valid message and refuse a message that is not valid.
const std = @import("std");
const mcp = @import("mcp");

const schema_2025_11_25 = @embedFile("schema_2025_11_25");
const schema_2026_07_28 = @embedFile("schema_2026_07_28");

/// Compiles the definition `name` of a schema document. The root of the copy refers to the
/// definition, so the validator checks an instance against that definition only.
fn compileDefinition(arena: std.mem.Allocator, document: []const u8, name: []const u8) !mcp.schema.validator.Schema {
    var root = try std.json.parseFromSliceLeaky(std.json.Value, arena, document, .{});
    try root.object.put(arena, "$ref", .{ .string = try std.fmt.allocPrint(arena, "#/$defs/{s}", .{name}) });
    return mcp.schema.validator.compile(arena, root, .{});
}

fn isValid(arena: std.mem.Allocator, schema: *const mcp.schema.validator.Schema, instance: []const u8) !bool {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, instance, .{});
    return (try mcp.schema.validator.validate(arena, schema, value)).valid;
}

test "the 2025-11-25 schema checks an initialize result" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try compileDefinition(arena, schema_2025_11_25, "InitializeResult");
    try std.testing.expect(try isValid(arena, &schema,
        \\{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"s","version":"1"}}
    ));
    try std.testing.expect(!try isValid(arena, &schema,
        \\{"protocolVersion":"2025-11-25","capabilities":{"tools":{}}}
    ));
}

test "the 2026-07-28 schema checks a discover result" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try compileDefinition(arena, schema_2026_07_28, "DiscoverResult");
    try std.testing.expect(try isValid(arena, &schema,
        \\{"resultType":"complete","ttlMs":0,"cacheScope":"public","supportedVersions":["2026-07-28"],"capabilities":{}}
    ));
    try std.testing.expect(!try isValid(arena, &schema,
        \\{"resultType":"complete","ttlMs":0,"cacheScope":"public","capabilities":{}}
    ));
}
