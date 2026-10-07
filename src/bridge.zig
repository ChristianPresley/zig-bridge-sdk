//! The core of zig-bridge-sdk. A bridge connects a client of an earlier MCP revision to a server
//! of revision 2026-07-28. The core has the parts that every bridge uses. Each product has its
//! own module with a `Profile`.
//!
//! The modern side always uses zig-sdk (`mcp`). The legacy side is in this module.
const std = @import("std");

/// The zig-sdk module that the bridges use.
pub const mcp = @import("mcp");

/// The version of this package, from `build.zig.zon`.
pub const version: []const u8 = @import("build_options").version;

/// The legacy protocol revision that the bridges speak to their client.
pub const legacy_protocol_version = "2025-11-25";

/// The part of revision 2025-11-25 that the bridges receive from their client.
pub const legacy = @import("bridge/legacy.zig");
/// The translation of capabilities, parameters, results and errors. It does no I/O.
pub const translate = @import("bridge/translate.zig");
/// The log function of the executables: a fixed tag on each stderr line and a level at run
/// time.
pub const log = @import("bridge/log.zig");
/// The legacy stdio server of a bridge for one client connection.
pub const Frontend = @import("bridge/Frontend.zig");
/// The upstream server of revision 2026-07-28 and the client of zig-sdk for it.
pub const Upstream = @import("bridge/Upstream.zig");
/// The input requests of the upstream server: the checks, the rounds and the answers of the
/// client.
pub const input = @import("bridge/input.zig");

test {
    _ = legacy;
    _ = translate;
    _ = log;
    _ = Frontend;
    _ = Upstream;
    _ = input;
    _ = @import("bridge/fuzz_test.zig");
}

/// The settings of one product. Each bridge module declares one `Profile`, and the core
/// functions take it as `*const Profile`. The product is a property of the executable. The
/// core never chooses a profile from the `clientInfo` of the client.
pub const Profile = struct {
    /// The name of the executable. The logs use it as their tag.
    name: []const u8,
    /// The `protocolVersion` of the `initialize` result.
    reply_protocol_version: []const u8 = legacy_protocol_version,
    /// The prefix of the ids of the requests that the bridge sends to the client. The ids are
    /// strings, so that they cannot be equal to a numeric id of the client.
    request_id_prefix: []const u8 = "b-",
    /// The `_meta` keys of a client request that go to the upstream server.
    meta_passthrough: MetaPassthrough = .{},
    /// The changes to the results that this client needs.
    quirks: Quirks = .{},

    pub const MetaPassthrough = struct {
        /// Keys that go to the upstream server without a change.
        keys: []const []const u8 = &.{},
        /// Key prefixes that go to the upstream server without a change.
        prefixes: []const []const u8 = &.{},

        /// Returns true when the key goes to the upstream server.
        pub fn allows(self: MetaPassthrough, key: []const u8) bool {
            for (self.keys) |k| if (std.mem.eql(u8, k, key)) return true;
            for (self.prefixes) |p| if (std.mem.startsWith(u8, key, p)) return true;
            return false;
        }
    };

    pub const Quirks = struct {
        /// Give `items: {}` to each array schema of a tool `inputSchema` that has no `items`.
        normalize_array_items: bool = false,
        /// Remove each tool `outputSchema` whose root does not have `type: "object"`.
        /// Revision 2025-11-25 allows only that root. A client that checks `tools/list`
        /// against that revision refuses the whole list for one such schema.
        drop_non_object_output_schema: bool = false,
        /// Change the results of revision 2026-07-28 that revision 2025-11-25 does not allow.
        strict_legacy_results: bool = false,
    };
};

test "meta passthrough allows the keys and the prefixes" {
    const p: Profile.MetaPassthrough = .{ .keys = &.{"traceparent"}, .prefixes = &.{"vendor."} };
    try std.testing.expect(p.allows("traceparent"));
    try std.testing.expect(p.allows("vendor.requestId"));
    try std.testing.expect(!p.allows("progressToken"));
    try std.testing.expect(!p.allows("io.modelcontextprotocol/logLevel"));
}

test "profile defaults" {
    const p: Profile = .{ .name = "x" };
    try std.testing.expectEqualStrings("2025-11-25", p.reply_protocol_version);
    try std.testing.expectEqualStrings("b-", p.request_id_prefix);
}
