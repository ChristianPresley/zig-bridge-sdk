//! The sign-in at an HTTPS upstream server. The upstream server is the HTTPS variant of the
//! fixture server with its authorization server (`fixture.https`). The bridge and its upstream
//! client trust only the test CA. The test replaces only the opener of the browser. It gets the
//! start URL of the receiver. It follows the redirect of the start URL and the redirects of the
//! authorization server into the real loopback receiver of the bridge.
//!
//! The tests cover these parts:
//!
//! - The registration modes, and the errors that name the option to use.
//! - The first sign-in during `initialize`, and the deadline of a sign-in.
//! - The URL elicitation of a step-up after `notifications/initialized`.
//! - The sandbox of VS Code.
//! - The stored sign-in of a second start, the accounts and logout.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const vscode = @import("vscode");
const fixture = @import("fixture");
const harness = @import("harness.zig");

const bridge = vscode.bridge;
const oauth = bridge.oauth;
const Transcript = harness.Transcript;
const testing = std.testing;
const https = fixture.https;

/// The `initialize` request of VS Code without URL elicitation.
const form_only_initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{"form":{}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}}
;

const guarded_call =
    \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"guarded","arguments":{}}}
;

/// The browser of the tests. It never opens a real browser.
const Browser = struct {
    mode: Mode,
    calls: std.atomic.Value(u32) = .init(0),
    lock: Io.Mutex = .init,
    /// The URL of the last page of the last visit: the redirect URI with the code.
    last: std.ArrayList(u8) = .empty,
    /// The URL that the bridge gave to the browser in the last call. Guarded by `lock`.
    opened: std.ArrayList(u8) = .empty,

    const Mode = enum {
        /// GET the URL and follow the redirects into the receiver of the bridge.
        follow,
        /// Only count the call. The redirect never arrives.
        silent,
    };

    fn opener(self: *Browser) oauth.Opener {
        return .{ .context = self, .open = open };
    }

    fn open(context: ?*anyopaque, io: Io, url: []const u8) oauth.OpenerError!void {
        const self: *Browser = @ptrCast(@alignCast(context.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            self.opened.clearRetainingCapacity();
            self.opened.appendSlice(testing.allocator, url) catch {};
        }
        if (self.mode == .silent) return;
        self.visit(io, url) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => return error.BrowserLaunchFailed,
        };
    }

    /// Follow `url` into the receiver, as the browser of the user does.
    fn visit(self: *Browser, io: Io, url: []const u8) https.BrowseError!void {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const v = try https.browse(io, testing.allocator, arena_state.allocator(), url, .{});
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.last.clearRetainingCapacity();
        self.last.appendSlice(testing.allocator, v.url) catch {};
    }

    fn count(self: *Browser) u32 {
        return self.calls.load(.acquire);
    }

    /// A copy of the URL of the last call, in `arena`.
    fn openedUrl(self: *Browser, arena: Allocator) ![]const u8 {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return arena.dupe(u8, self.opened.items);
    }

    fn deinit(self: *Browser) void {
        self.last.deinit(testing.allocator);
        self.opened.deinit(testing.allocator);
    }
};

/// Keeps the sign-in lines of the bridge.
const Lines = struct {
    lock: Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,
    count: std.atomic.Value(u32) = .init(0),

    fn output(self: *Lines) oauth.Output {
        return .{ .context = self, .write_line = write };
    }

    fn write(context: ?*anyopaque, line: []const u8) void {
        const self: *Lines = @ptrCast(@alignCast(context.?));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.text.appendSlice(testing.allocator, line) catch {};
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    fn deinit(self: *Lines) void {
        self.text.deinit(testing.allocator);
    }
};

/// A free port on 127.0.0.1 for the redirect URI of one test.
fn freePort(io: Io) !u16 {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

/// A transcript with an HTTPS upstream server that needs a sign-in. The tap of the transcript
/// sends each upstream request through the HTTP client transport of zig-sdk. The provider of
/// the client is the `Authorizer` of the bridge, and the front end has the same `Authorizer`.
const SignInTranscript = struct {
    t: *Transcript,
    bundle: std.crypto.Certificate.Bundle,
    authorizer: oauth.Authorizer,
    client: *mcp.transport.HttpClient,
    browser: Browser,
    lines: Lines = .{},
    port: u16,

    const Options = struct {
        registration: oauth.Registration = .dynamic,
        account: []const u8 = oauth.default_account,
        browser: Browser.Mode = .follow,
        timeout: Io.Duration = .fromSeconds(30),
        sandboxed: bool = false,
        /// Null uses a free port.
        port: ?u16 = null,
    };

    /// Make the transcript for `server` with the token storage `storage`. Release it with
    /// `destroy`.
    fn create(server: *https.HttpsServer, storage: mcp.auth.TokenStorage, options: Options) !*SignInTranscript {
        const io = testing.io;
        const gpa = testing.allocator;
        const self = try gpa.create(SignInTranscript);
        errdefer gpa.destroy(self);
        self.* = .{
            .t = undefined,
            .bundle = try https.certificateBundle(gpa, io, https.ca_pem),
            .authorizer = undefined,
            .client = undefined,
            .browser = .{ .mode = options.browser },
            .port = options.port orelse try freePort(io),
        };
        errdefer self.bundle.deinit(gpa);
        try self.authorizer.init(io, gpa, .{
            .identity = vscode.identity,
            .server_url = server.url(),
            .account = options.account,
            .redirect_port = self.port,
            .registration = options.registration,
            .storage = storage,
            .ca_bundle = &self.bundle,
            .timeout = options.timeout,
            .opener = self.browser.opener(),
            .output = self.lines.output(),
            .sandboxed = options.sandboxed,
        });
        errdefer self.authorizer.deinit();
        self.client = try mcp.transport.HttpClient.init(io, gpa, .{
            .url = server.url(),
            .auth_provider = self.authorizer.provider(),
            .tls = .{ .trust = .{ .bundle = &self.bundle } },
            .max_response_bytes = bridge.Upstream.default_max_response_bytes,
        });
        errdefer self.client.deinit();
        self.t = try Transcript.create(.{ .remote = true, .frontend = .{ .sign_in = &self.authorizer } });
        self.t.tap.inner = self.client.transport();
        return self;
    }

    fn destroy(self: *SignInTranscript) void {
        const gpa = testing.allocator;
        self.t.destroy();
        self.client.deinit();
        self.authorizer.deinit();
        self.bundle.deinit(gpa);
        self.browser.deinit();
        self.lines.deinit();
        gpa.destroy(self);
    }

    /// The redirect URI of the bridge.
    fn redirectUri(self: *SignInTranscript) []const u8 {
        return self.authorizer.redirectUri();
    }

    /// Send `initialize` and expect a result. Then send `notifications/initialized`.
    fn initialize(self: *SignInTranscript, line: []const u8) !void {
        _ = try harness.expectResult(try self.t.call(1, line));
        try self.t.send(harness.initialized);
        try self.t.waitListening(1);
    }
};

test "the first sign-in opens the browser during initialize, and a step-up asks VS Code with a URL elicitation" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const s = try SignInTranscript.create(server, memory.storage(), .{});
    defer s.destroy();
    const t = s.t;
    const arena = t.arena();

    try s.initialize(harness.vscode_initialize);
    // One sign-in through the browser, with one sign-in line.
    try testing.expectEqual(@as(u32, 1), s.browser.count());
    try testing.expectEqual(@as(u32, 1), s.lines.count.load(.acquire));
    const line_start = try std.fmt.allocPrint(arena, "mcp-bridge-vscode: sign in at {s}", .{server.issuer().?});
    try testing.expect(std.mem.startsWith(u8, s.lines.text.items, line_start));
    // The line has the authorization URL, and the browser got only the one-time start URL of
    // the receiver, without a query.
    try testing.expect(std.mem.indexOf(u8, s.lines.text.items, "code_challenge=") != null);
    const opened = try s.browser.openedUrl(arena);
    const start_prefix = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ s.port, oauth.start_path_prefix });
    try testing.expect(std.mem.startsWith(u8, opened, start_prefix));
    try testing.expectEqual(start_prefix.len + oauth.start_token_len, opened.len);
    try testing.expect(std.mem.indexOfScalar(u8, opened, '?') == null);
    // The registration has the name of the bridge and its exact redirect URI.
    const registered = try server.registrations(arena);
    try testing.expectEqual(@as(usize, 1), registered.len);
    try testing.expectEqualStrings("mcp-bridge-vscode (zig-bridge-sdk)", registered[0].client_name.?);
    try testing.expectEqualStrings(s.redirectUri(), registered[0].redirect_uris[0]);

    // A request with the token of the first sign-in.
    const sum = try t.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":3}}}");
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(sum)));

    // The tool guarded needs a step-up. The bridge does not open the browser. VS Code gets a
    // URL elicitation, accepts it and opens the URL.
    try t.send(guarded_call);
    const request = try t.bridgeRequest("elicitation/create", 1);
    const params = request.object.get("params").?;
    try testing.expectEqualStrings("url", mcp.json.getString(params, "mode").?);
    const url = mcp.json.getString(params, "url").?;
    try testing.expect(std.mem.startsWith(u8, url, server.issuer().?));
    try oauth.validateAuthorizationUrl(url, .{});
    const elicitation_id = mcp.json.getString(params, "elicitationId").?;
    try t.reply(request, "{\"action\":\"accept\"}");
    try s.browser.visit(io, url);
    const result = try t.waitResponse(3);
    try testing.expectEqualStrings(fixture.guarded_text, try harness.firstText(try harness.expectResult(result)));
    // The completion of the elicitation comes before the result.
    const complete_index = (try t.methodIndexFrom(0, "notifications/elicitation/complete")).?;
    try testing.expect(complete_index < (try t.responseIndex(3)).?);
    const complete = (try t.parsedFrames())[complete_index];
    try testing.expectEqualStrings(elicitation_id, mcp.json.getString(complete.object.get("params").?, "elicitationId").?);
    try testing.expectEqual(@as(u32, 1), s.browser.count());
    // The step-up needs no second registration.
    try testing.expectEqual(@as(usize, 1), (try server.registrations(arena)).len);
    try t.verify();
}

test "a declined step-up gives -32603 and no browser, and a cooldown keeps the next one from a new question" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const s = try SignInTranscript.create(server, memory.storage(), .{});
    defer s.destroy();
    const t = s.t;

    try s.initialize(harness.vscode_initialize);
    try t.send(guarded_call);
    const request = try t.bridgeRequest("elicitation/create", 1);
    try t.reply(request, "{\"action\":\"decline\"}");
    const declined = try t.waitResponse(3);
    try harness.expectError(declined, -32603, null, "reauthorization_required");
    try testing.expectEqualStrings("declined", harness.errorDetail(declined).?);
    try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/elicitation/complete"));

    // In the cooldown, the same step-up fails without a new question.
    _ = try t.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"guarded\",\"arguments\":{}}}");
    const again = (try t.response(4)).?;
    try harness.expectError(again, -32603, null, "reauthorization_required");
    try testing.expectEqualStrings("cooldown", harness.errorDetail(again).?);
    try testing.expectEqual(@as(usize, 1), try t.methodCount("elicitation/create"));
    // Only the first sign-in opened the browser.
    try testing.expectEqual(@as(u32, 1), s.browser.count());
    try t.verify();
}

test "without URL elicitation, a step-up fails with -32603, and no browser opens" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const s = try SignInTranscript.create(server, memory.storage(), .{});
    defer s.destroy();
    const t = s.t;

    try s.initialize(form_only_initialize);
    const lines = s.lines.count.load(.acquire);
    const failed = try t.call(3, guarded_call);
    try harness.expectError(failed, -32603, null, "reauthorization_required");
    try testing.expectEqualStrings("no_consent", harness.errorDetail(failed).?);
    try testing.expectEqual(@as(usize, 0), try t.methodCount("elicitation/create"));
    try testing.expectEqual(@as(u32, 1), s.browser.count());
    // No sign-in line: the sign-in did not start.
    try testing.expectEqual(lines, s.lines.count.load(.acquire));
    try t.verify();
}

test "an authorization server without registration: the error names --client-id and the redirect URI, and a pre-registered client signs in" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .dynamic_registration = false } });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{});
        defer s.destroy();
        const failed = try s.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, null, "registration_unavailable");
        const message = failed.object.get("error").?.object.get("message").?.string;
        try testing.expect(std.mem.indexOf(u8, message, "--client-id") != null);
        try testing.expect(std.mem.indexOf(u8, message, "--client-issuer") != null);
        const uri = try std.fmt.allocPrint(s.t.arena(), "the redirect URI {s} ", .{s.redirectUri()});
        try testing.expect(std.mem.indexOf(u8, message, uri) != null);
        try testing.expectEqual(@as(u32, 0), s.browser.count());
        try s.t.verify();
    }
    // A pre-registered client with an issuer that is not the issuer of the server.
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{ .registration = .{ .pre_registered = .{
            .client_id = https.public_client_id,
            .issuer = "https://other.example",
        } } });
        defer s.destroy();
        try harness.expectError(try s.t.call(1, harness.vscode_initialize), -32603, null, "issuer_not_registered");
        try testing.expectEqual(@as(u32, 0), s.browser.count());
    }
    // The confidential client with its secret, as from MCP_BRIDGE_CLIENT_SECRET.
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{ .registration = .{ .pre_registered = .{
            .client_id = https.confidential_client_id,
            .issuer = server.issuer().?,
            .client_secret = https.confidential_client_secret,
        } } });
        defer s.destroy();
        try s.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), s.browser.count());
        try testing.expectEqual(@as(usize, 0), (try server.registrations(s.t.arena())).len);
        // The record never has the secret of a pre-registered client.
        const record = (try storedRecord(s.t.arena(), memory.storage(), &s.authorizer)).?;
        try testing.expect(std.mem.indexOf(u8, record, https.confidential_client_id) != null);
        try testing.expect(std.mem.indexOf(u8, record, https.confidential_client_secret) == null);
        try s.t.verify();
    }
}

/// The serialized record of the sign-in of `a` in `storage`, in `arena`, or null. The index of
/// the bridge gives its key.
fn storedRecord(arena: Allocator, storage: mcp.auth.TokenStorage, a: *oauth.Authorizer) !?[]const u8 {
    for (try oauth.loadIndex(arena, storage, vscode.identity)) |entry| {
        if (!std.mem.eql(u8, entry.url, a.server_url)) continue;
        if (!std.mem.eql(u8, entry.client, a.storage_identity)) continue;
        return try storage.vtable.load(storage.ptr, arena, entry.key());
    }
    return null;
}

test "a client ID metadata document replaces the registration" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .client_metadata = true, .dynamic_registration = false } });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const s = try SignInTranscript.create(server, memory.storage(), .{ .registration = .{ .client_metadata_url = server.clientMetadataUrl().? } });
    defer s.destroy();
    try s.initialize(harness.vscode_initialize);
    try testing.expectEqual(@as(u32, 1), s.browser.count());
    try testing.expectEqual(@as(usize, 0), (try server.registrations(s.t.arena())).len);
    try s.t.verify();
}

test "a denied sign-in and the deadline of a sign-in give their errors" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .deny = true } });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{});
        defer s.destroy();
        try harness.expectError(try s.t.call(1, harness.vscode_initialize), -32603, null, "sign_in_denied");
        try testing.expectEqual(@as(u32, 1), s.browser.count());
    }
    server.setDeny(false);
    {
        // The user never finishes the sign-in. The message names the time limit, the option
        // and the logout command for a stored client that the server forgot.
        const s = try SignInTranscript.create(server, memory.storage(), .{ .browser = .silent, .timeout = .fromMilliseconds(500) });
        defer s.destroy();
        const failed = try s.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, null, "sign_in_timeout");
        const message = failed.object.get("error").?.object.get("message").?.string;
        try testing.expect(std.mem.indexOf(u8, message, "--sign-in-timeout") != null);
        try testing.expect(std.mem.indexOf(u8, message, "\"mcp-bridge-vscode logout <url>\"") != null);
        // The message never has the URL of the upstream server: its path or its query can
        // hold a key, and the model can read the message.
        try testing.expect(std.mem.indexOf(u8, message, server.url()) == null);
        // The connection stays open, and a new initialize can sign in.
        try testing.expectEqual(bridge.Frontend.State.awaiting_initialize, s.t.frontend.state());
        try s.t.verify();
    }
}

test "in the sandbox of VS Code, initialize fails at once without a stored token" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const s = try SignInTranscript.create(server, memory.storage(), .{ .sandboxed = true });
    defer s.destroy();
    const failed = try s.t.call(1, harness.vscode_initialize);
    try harness.expectError(failed, -32603, null, "sandbox");
    try testing.expectEqual(@as(u32, 0), s.browser.count());
    try testing.expectEqual(@as(u32, 0), server.mcpRequestCount());
    try s.t.verify();
}

test "a second start uses the stored sign-in, each account has its own, and logout makes the next start sign in again" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const port = try freePort(io);
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{ .port = port });
        defer s.destroy();
        try testing.expect(s.authorizer.interactive());
        try s.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), s.browser.count());
    }
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{ .port = port });
        defer s.destroy();
        try testing.expect(!s.authorizer.interactive());
        try s.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 0), s.browser.count());
    }
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{ .port = port, .account = "work" });
        defer s.destroy();
        try testing.expect(s.authorizer.interactive());
        try s.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), s.browser.count());
    }

    var buf: [oauth.max_redirect_uri_len]u8 = undefined;
    const storage_identity = try vscode.identity.storageIdentity(gpa, oauth.default_account, oauth.writeRedirectUri(&buf, port));
    defer gpa.free(storage_identity);
    const report = try oauth.logout(io, gpa, memory.storage(), .{ .identity = vscode.identity, .url = server.url(), .storage_identity = storage_identity });
    try testing.expectEqual(@as(usize, 1), report.deleted);
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{ .port = port });
        defer s.destroy();
        try testing.expect(s.authorizer.interactive());
        try s.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), s.browser.count());
    }
    // The account "work" kept its sign-in.
    {
        const s = try SignInTranscript.create(server, memory.storage(), .{ .port = port, .account = "work" });
        defer s.destroy();
        try testing.expect(!s.authorizer.interactive());
    }
}

test "the end of the input during the wait for the browser ends the sign-in well inside 10 s" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const s = try SignInTranscript.create(server, memory.storage(), .{ .browser = .silent, .timeout = .fromSeconds(120) });
    defer s.destroy();
    try s.t.send(harness.vscode_initialize);
    // The sign-in waits after the browser call.
    const until = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(10), .clock = .awake });
    while (s.browser.count() == 0) {
        if (Io.Clock.Timestamp.now(io, .awake).durationTo(until).raw.nanoseconds <= 0) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    const started = Io.Clock.Timestamp.now(io, .awake);
    s.t.frontend.shutdown();
    try testing.expect(started.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds() < 10_000);
    // A canceled initialize gets no response.
    try testing.expect((try s.t.response(1)) == null);
}
