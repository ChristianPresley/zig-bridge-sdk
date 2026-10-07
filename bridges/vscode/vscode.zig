//! The bridge for Visual Studio Code (VS Code). VS Code speaks MCP revision 2025-11-25. This
//! bridge lets it use a server of revision 2026-07-28.
//!
//! Visual Studio Code and VS Code are trademarks of Microsoft Corporation. This project has no
//! affiliation with Microsoft, and Microsoft does not endorse it.
const std = @import("std");

/// The zig-sdk module of this package. An embedder takes `mcp` from here, so that it uses the
/// same types as the bridge.
pub const mcp = @import("mcp");
/// The core of the bridges.
pub const bridge = @import("bridge");

/// The settings of the VS Code bridge.
pub const profile: bridge.Profile = .{
    .name = "mcp-bridge-vscode",
    .meta_passthrough = .{
        .keys = &.{ "traceparent", "tracestate" },
        .prefixes = &.{"vscode."},
    },
    .quirks = .{
        // The Copilot extension stops each request when an array schema has no `items`.
        .normalize_array_items = true,
        // VS Code reads the results of revision 2026-07-28. The MCP Apps need them unchanged.
        .strict_legacy_results = false,
    },
};

test "the VS Code profile passes the trace keys and the vscode keys" {
    try std.testing.expect(profile.meta_passthrough.allows("traceparent"));
    try std.testing.expect(profile.meta_passthrough.allows("vscode.conversationId"));
    try std.testing.expect(!profile.meta_passthrough.allows("progressToken"));
    try std.testing.expect(profile.quirks.normalize_array_items);
}
