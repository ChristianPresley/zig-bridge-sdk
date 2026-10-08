//! The checks of the files in `site/`. The workflow `.github/workflows/pages.yml` publishes
//! them on GitHub Pages.
const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp");
const bridge = @import("bridge");
const vscode = @import("vscode");

const vscode_client = @embedFile("site_vscode_client");

test "the client ID metadata document of the vscode bridge passes the checks of zig-sdk" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The document has the values of the executable: its URL, the `client_name` of the
    // identity, and the redirect URI of the default `--redirect-port`.
    const client = try mcp.auth.client_metadata.parseDocument(arena, vscode.client_metadata_url, vscode_client);
    try testing.expectEqualStrings(vscode.client_metadata_url, client.client_id);
    try testing.expectEqualStrings(vscode.identity.client_name, client.client_name.?);
    var redirect_buf: [bridge.oauth.max_redirect_uri_len]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), client.redirect_uris.len);
    try testing.expectEqualStrings(bridge.oauth.writeRedirectUri(&redirect_buf, bridge.oauth.default_redirect_port), client.redirect_uris[0]);
    try testing.expect(client.grant_types.authorization_code and client.grant_types.refresh_token);
    try testing.expect(!client.grant_types.client_credentials and !client.grant_types.jwt_bearer);
    try testing.expectEqual(mcp.auth.authorization_store.AuthMethod.none, client.auth_method);
    // The document has no `scope`. Thus an authorization server does not limit the scopes
    // that the bridge asks for each server.
    try testing.expectEqual(@as(usize, 0), client.scopes.len);

    const tree = try mcp.json.parseTree(arena, vscode_client);
    try testing.expectEqualStrings("native", mcp.json.getString(tree, "application_type").?);
    const response_types = tree.object.get("response_types").?.array.items;
    try testing.expectEqual(@as(usize, 1), response_types.len);
    try testing.expectEqualStrings("code", response_types[0].string);
    // The draft of client ID metadata documents recommends 5 KiB at most.
    try testing.expect(vscode_client.len <= 5 * 1024);
}
