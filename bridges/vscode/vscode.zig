//! The bridge for Visual Studio Code (VS Code). VS Code speaks MCP revision 2025-11-25. This
//! bridge lets it use a server of revision 2026-07-28.
//!
//! Visual Studio Code and VS Code are trademarks of Microsoft Corporation. This project has no
//! affiliation with Microsoft, and Microsoft does not endorse it.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

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
        // VS Code does not read the output schema. The TypeScript SDK 1.x refuses a
        // `tools/list` result with an output schema that is not an object schema.
        .drop_non_object_output_schema = true,
        // VS Code reads the results of revision 2026-07-28. The MCP Apps need them unchanged.
        .strict_legacy_results = false,
    },
};

/// The names of the VS Code bridge that an authorization server and the keychain see. The
/// `client_name` is "mcp-bridge-vscode (zig-bridge-sdk)", and the keychain service is
/// "zig-bridge-sdk/mcp-bridge-vscode". The token directory ends in `zig-bridge-sdk/vscode/tokens`.
/// The default client ID metadata document is `client_metadata_url`. The names are a part of
/// the stored sign-ins, thus they never change.
pub const identity: bridge.oauth.Identity = .of(profile.name, "vscode", client_metadata_url);

/// The URL of the client ID metadata document of the VS Code bridge on GitHub Pages. It is
/// also the `client_id` in the document (`site/vscode/client.json`), and the default of
/// `--client-metadata-url`. The `redirect_uris` of the document has only the redirect URI of
/// `bridge.oauth.default_redirect_port`.
pub const client_metadata_url = "https://christianpresley.github.io/zig-bridge-sdk/vscode/client.json";

/// The settings of `serve`.
pub const ServeOptions = struct {
    /// The upstream server: a command, or the URL of a remote server.
    upstream: UpstreamOptions,
    /// The sign-in at the HTTP upstream server, or null. `serve` gives its provider to the
    /// HTTP client and the sign-in to the front end. `UpstreamOptions.http.auth` must then be
    /// null.
    sign_in: ?*bridge.oauth.Authorizer = null,
    /// The `serverInfo.name` when the upstream server sends none. Empty uses `defaultName` of
    /// the command, or `defaultUrlName` of the URL. VS Code makes the ids of the tools from
    /// this name. Thus each upstream server gets its own name, and never the fixed name of
    /// the bridge.
    name: []const u8 = "",
    /// The time limit of `server/discover`.
    discover_timeout: Io.Duration = .fromSeconds(bridge.Frontend.default_discover_timeout_s),
    /// The maximum length of one line from VS Code, and of one line from a stdio upstream
    /// server. `UpstreamOptions.http` has its own limit.
    max_line_bytes: usize = bridge.Upstream.default_max_line_bytes,
    /// The functions of the executable for the end of the input and for the loss of the
    /// upstream server.
    hooks: bridge.Frontend.Hooks = .{},
};

/// The upstream server of `serve`.
pub const UpstreamOptions = union(enum) {
    /// The upstream command and its arguments. The bridge starts it at the first
    /// `initialize` and speaks to it over stdio. The list has at least one item.
    command: []const []const u8,
    /// The URL of a remote upstream server and the settings of the HTTP client. The bridge
    /// speaks to it over Streamable HTTP. A failed request gets an error, and the bridge
    /// continues.
    http: bridge.Upstream.Config.Http,
};

/// The size of the read buffer of stdin.
const stdin_buffer_bytes = 64 << 10;

/// Serve VS Code over the stdin and the stdout of the process until the end of stdin. The
/// first `initialize` of VS Code starts the upstream command, or makes the HTTP client for
/// the URL. Stdout carries only JSON-RPC messages.
///
/// The function returns `.eof` after the end of stdin and a bounded stop. It returns
/// `.upstream_exited` when the upstream command stopped first. The reader can then wait for
/// the next line, thus an executable exits in `hooks.on_upstream_exit`. An HTTP upstream
/// server never gives `.upstream_exited`.
pub fn serve(io: Io, gpa: Allocator, options: ServeOptions) !bridge.Frontend.RunResult {
    const upstream = try bridge.Upstream.init(io, gpa, upstreamConfig(options));
    defer upstream.deinit();
    const in_buf = try gpa.alloc(u8, stdin_buffer_bytes);
    defer gpa.free(in_buf);
    var out_buf: [64 << 10]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, in_buf);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    var frontend: bridge.Frontend = .init(io, gpa, upstream, &profile, .writer(&stdout.interface), frontendOptions(options));
    defer frontend.deinit();
    return frontend.run(&stdin.interface);
}

/// The configuration of the upstream server that `serve` makes from `options`. With a
/// sign-in, the HTTP client gets its provider.
pub fn upstreamConfig(options: ServeOptions) bridge.Upstream.Config {
    return switch (options.upstream) {
        .command => |argv| .{ .stdio = .{ .argv = argv, .max_line_bytes = options.max_line_bytes } },
        .http => |h| http: {
            var config = h;
            if (options.sign_in) |a| config.auth = .{ .provider = a.provider() };
            break :http .{ .http = config };
        },
    };
}

/// The settings of the front end that `serve` makes from `options`. Without a name, the
/// fallback name is `defaultName` of the command, or `defaultUrlName` of the URL.
pub fn frontendOptions(options: ServeOptions) bridge.Frontend.Options {
    return .{
        .max_line_bytes = options.max_line_bytes,
        .discover_timeout = options.discover_timeout,
        .fallback_name = if (options.name.len != 0) options.name else switch (options.upstream) {
            .command => |argv| defaultName(argv[0]),
            .http => |h| defaultUrlName(h.url),
        },
        .hooks = options.hooks,
        .sign_in = switch (options.upstream) {
            .command => null,
            .http => options.sign_in,
        },
    };
}

/// Returns the default server name of the upstream command: the file name of `command`
/// without its extension. The result is not empty when `command` is not empty. For an empty
/// result, the `initialize` result has the name of the profile.
pub fn defaultName(command: []const u8) []const u8 {
    return nameOf(command, std.fs.path.basename(command));
}

/// Returns the default server name of an upstream server at `url`: the host of the URL, as
/// the URL writes it, without the port. The result points into `url`. It is empty for a text
/// that is not a URL with a host. For an empty result, the `initialize` result has the name
/// of the profile.
pub fn defaultUrlName(url: []const u8) []const u8 {
    const uri = std.Uri.parse(url) catch return "";
    const host = uri.host orelse return "";
    return switch (host) {
        .raw, .percent_encoded => |text| text,
    };
}

/// The file name `base` of `command` without its extension, or `command` when `base` is
/// empty. The tests give the base name with the path rules of Windows, also on Linux.
fn nameOf(command: []const u8, base: []const u8) []const u8 {
    if (base.len == 0) return command;
    // The name of a file such as ".server" has no extension.
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base;
    return base[0..dot];
}

test "the default name is the file name of the command without its extension" {
    try std.testing.expectEqualStrings("npx", defaultName("npx"));
    try std.testing.expectEqualStrings("node", defaultName("/usr/local/bin/node"));
    try std.testing.expectEqualStrings("server", defaultName("/opt/mcp/bin/server.exe"));
    try std.testing.expectEqualStrings("my.server", defaultName("./my.server.py"));
    try std.testing.expectEqualStrings(".server", defaultName("/srv/.server"));
    try std.testing.expectEqualStrings("server", defaultName("server."));
    try std.testing.expectEqualStrings("server", defaultName("bin/server/"));
    try std.testing.expectEqualStrings("/", defaultName("/"));
    try std.testing.expectEqualStrings("", defaultName(""));
}

test "the default name of a Windows path" {
    // The test uses the path rules of Windows on all platforms.
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "C:\\Program Files\\nodejs\\npx.cmd", "npx" },
        .{ "C:/tools/server.EXE", "server" },
        .{ "tools\\server.exe", "server" },
        .{ "\\\\host\\share\\my.server.py", "my.server" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], nameOf(c[0], std.fs.path.basenameWindows(c[0])));
        if (@import("builtin").os.tag == .windows) try std.testing.expectEqualStrings(c[1], defaultName(c[0]));
    }
}

test "serve takes the fallback name from the option, else from the command" {
    const command: []const []const u8 = &.{ "/opt/mcp/bin/files-server.exe", "--stdio" };
    try std.testing.expectEqualStrings("files-server", frontendOptions(.{ .upstream = .{ .command = command } }).fallback_name);
    try std.testing.expectEqualStrings("files", frontendOptions(.{ .upstream = .{ .command = command }, .name = "files" }).fallback_name);
    const options = frontendOptions(.{ .upstream = .{ .command = command }, .max_line_bytes = 4096, .discover_timeout = .fromSeconds(5) });
    try std.testing.expectEqual(@as(usize, 4096), options.max_line_bytes);
    try std.testing.expectEqual(@as(i64, 5), options.discover_timeout.toSeconds());
}

test "serve takes the fallback name of an HTTP upstream server from the host of the URL" {
    const http: ServeOptions = .{ .upstream = .{ .http = .{ .url = "https://mcp.example.com:8443/v1/mcp?tenant=a" } } };
    try std.testing.expectEqualStrings("mcp.example.com", frontendOptions(http).fallback_name);
    var named = http;
    named.name = "example";
    try std.testing.expectEqualStrings("example", frontendOptions(named).fallback_name);
    try std.testing.expectEqualStrings("127.0.0.1", defaultUrlName("http://127.0.0.1:3000/mcp"));
    try std.testing.expectEqualStrings("[::1]", defaultUrlName("http://[::1]:3000/mcp"));
    try std.testing.expectEqualStrings("", defaultUrlName("not a url"));
    try std.testing.expectEqualStrings("", defaultUrlName("mailto:a@example.com"));
}

test "serve gives the upstream server the command or the URL" {
    const command: []const []const u8 = &.{"server"};
    const stdio = upstreamConfig(.{ .upstream = .{ .command = command }, .max_line_bytes = 4096 });
    try std.testing.expectEqual(@as(usize, 4096), stdio.stdio.max_line_bytes);
    try std.testing.expectEqualStrings("server", stdio.stdio.argv[0]);
    const headers = [_]std.http.Header{.{ .name = "x-tenant", .value = "a" }};
    const http = upstreamConfig(.{ .upstream = .{ .http = .{ .url = "https://mcp.example.com/mcp", .headers = &headers, .max_response_bytes = 1024 } } });
    try std.testing.expectEqualStrings("https://mcp.example.com/mcp", http.http.url);
    try std.testing.expectEqual(@as(usize, 1024), http.http.max_response_bytes);
    try std.testing.expectEqualStrings("x-tenant", http.http.headers[0].name);
    try std.testing.expect(http.http.auth == null);
}

test "the VS Code profile passes the trace keys and the vscode keys" {
    try std.testing.expect(profile.meta_passthrough.allows("traceparent"));
    try std.testing.expect(profile.meta_passthrough.allows("vscode.conversationId"));
    try std.testing.expect(!profile.meta_passthrough.allows("progressToken"));
    try std.testing.expect(profile.quirks.normalize_array_items);
    try std.testing.expect(profile.quirks.drop_non_object_output_schema);
    try std.testing.expect(!profile.quirks.strict_legacy_results);
}

test "the OAuth identity of the VS Code bridge stays the same" {
    try std.testing.expectEqualStrings("mcp-bridge-vscode (zig-bridge-sdk)", identity.client_name);
    try std.testing.expectEqualStrings("zig-bridge-sdk/mcp-bridge-vscode", identity.keychain_service);
    try std.testing.expectEqualStrings("vscode", identity.product);
    try std.testing.expectEqualStrings(profile.name, identity.bridge_name);
    try std.testing.expectEqualStrings("https://christianpresley.github.io/zig-bridge-sdk/vscode/client.json", client_metadata_url);
}
