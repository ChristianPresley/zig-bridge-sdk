//! The VS Code bridge with an HTTPS upstream server, made from the same parts as the
//! executable. `vscode.upstreamConfig` gives the `Upstream` its HTTP client with the trust, the
//! proxy and the provider of the sign-in. `vscode.frontendOptions` gives the front end the
//! sign-in. The upstream server is the HTTPS variant of the fixture server with its
//! authorization server (`fixture.https`). The bridge trusts only the CA of the test.
//!
//! The tests replace only the opener of the browser. The browser of the tests gets the start URL
//! of the receiver. It follows the redirect of the start URL and the redirects of the
//! authorization server into the real loopback receiver of the bridge. It never opens a real
//! browser.
//!
//! The tests cover these parts:
//!
//! - Each registration mode, and the error that names the options and the redirect URI.
//! - The file store across a new start, the accounts, logout, and a client that the
//!   authorization server forgot.
//! - The step-up of a tool through a URL elicitation, and the cases without a browser.
//! - The one-time start URL of the browser, a guess of its token and a second request of it.
//! - The program of `BROWSER` on a POSIX system.
//! - The end of the input and a cancel during the wait for the browser.
//! - A server certificate of a CA that the bridge does not trust, and `--ca-file`.
//! - The icons of a remote server, and an HTTPS proxy of the environment.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const vscode = @import("vscode");
const fixture = @import("fixture");
const harness = @import("harness.zig");

const bridge = vscode.bridge;
const oauth = bridge.oauth;
const https = fixture.https;
const proxy = mcp.transport.proxy;
const Transcript = harness.Transcript;
const testing = std.testing;

/// The `initialize` request of VS Code without URL elicitation.
const form_only_initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{"form":{}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}}
;

/// The cancellation of the `initialize` request by VS Code.
const cancel_initialize =
    \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"the user stopped the server"}}
;

/// A token key of the file store for the tests: 64 hexadecimal digits. It is a test value.
const test_token_key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

/// The time that a test waits for an event of the bridge.
const wait_limit: Io.Duration = .fromSeconds(10);

/// The bound of the stop of a sign-in at the end of the input or at a cancel. It is well
/// inside the 10 s of the design.
const stop_bound: Io.Duration = .fromSeconds(5);

/// The number of loops of the tests that stop a sign-in.
const stop_loops = 20;

fn addLine(a: Allocator, id: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"add\",\"arguments\":{{\"a\":2,\"b\":3}}}}}}", .{id});
}

fn guardedLine(a: Allocator, id: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{}}}}}}", .{ id, fixture.guarded_tool });
}

fn cancelLine(a: Allocator, id: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{{\"requestId\":{d},\"reason\":\"test\"}}}}", .{id});
}

/// A free port on 127.0.0.1 for the redirect URI of one test.
fn freePort(io: Io) !u16 {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

fn now(io: Io) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(io, .awake);
}

fn since(io: Io, start: Io.Clock.Timestamp) Io.Duration {
    return start.durationTo(now(io)).raw;
}

fn expectWithin(elapsed: Io.Duration, bound: Io.Duration, what: []const u8) !void {
    if (elapsed.nanoseconds <= bound.nanoseconds) return;
    std.debug.print("\n{s} took {d} ms, more than {d} ms\n", .{ what, elapsed.toMilliseconds(), bound.toMilliseconds() });
    return error.TestTooSlow;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// The message of an error response.
fn errorMessage(frame: Value) []const u8 {
    return frame.object.get("error").?.object.get("message").?.string;
}

// ---------------------------------------------------------------------------------------------
// The browser of the tests
// ---------------------------------------------------------------------------------------------

/// The browser of the tests. It never opens a real browser.
const Browser = struct {
    /// Guarded by `lock`, because a test can change it between two sign-ins.
    mode: Mode = .follow,
    /// The proxy of the hosts that are not loopback hosts, or null.
    through: ?proxy.Proxy = null,
    /// The CA certificates that the browser trusts, in PEM.
    trust_pem: []const u8 = https.ca_pem,
    calls: std.atomic.Value(u32) = .init(0),
    lock: Io.Mutex = .init,
    /// The status of the last page of the last visit. Guarded by `lock`.
    last_status: u16 = 0,
    /// The URL of the last page of the last visit. Guarded by `lock`.
    last_url: std.ArrayList(u8) = .empty,
    /// Each URL that the bridge gave to the browser, in the order of the calls. Guarded by
    /// `lock`.
    opened: std.ArrayList([]u8) = .empty,
    /// The status of each start path with a wrong token, for `guess`. Guarded by `lock`.
    guesses: std.ArrayList(u16) = .empty,
    /// The two responses of the start URL, for `start_twice`. Guarded by `lock`.
    twice: Twice = .{},

    const Mode = enum {
        /// GET the URL and follow the redirects into the receiver of the bridge.
        follow,
        /// Only count the call. The redirect never arrives.
        silent,
        /// GET start paths with a wrong token first, as a program that guesses. Then follow
        /// the URL.
        guess,
        /// GET the start URL two times without a redirect: first as another program, then as
        /// the browser of the user. Then follow the `Location` of the first response.
        start_twice,
    };

    /// What the browser saw in the mode `start_twice`.
    const Twice = struct {
        first_status: u16 = 0,
        /// The `Location` of the first response.
        location: std.ArrayList(u8) = .empty,
        /// The `Cache-Control` of the first response.
        cache_control: std.ArrayList(u8) = .empty,
        /// The `Referrer-Policy` of the first response.
        referrer_policy: std.ArrayList(u8) = .empty,
        second_status: u16 = 0,
        /// The page of the second response.
        second_body: std.ArrayList(u8) = .empty,
        /// The status of the last page after the browser followed `location`.
        late_status: u16 = 0,
    };

    fn opener(self: *Browser) oauth.Opener {
        return .{ .context = self, .open = open };
    }

    fn open(context: ?*anyopaque, io: Io, url: []const u8) oauth.OpenerError!void {
        const self: *Browser = @ptrCast(@alignCast(context.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        const mode = self.record(url);
        const result: anyerror!void = switch (mode) {
            .silent => return,
            .follow => self.visit(io, url),
            .guess => self.guess(io, url),
            .start_twice => self.startTwice(io, url),
        };
        result catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {
                std.debug.print("\nthe browser of the test failed in the mode {t}: {t}\n", .{ mode, e });
                return error.BrowserLaunchFailed;
            },
        };
    }

    /// Keep a copy of `url`, and return the mode.
    fn record(self: *Browser, url: []const u8) Mode {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        const copy = testing.allocator.dupe(u8, url) catch return self.mode;
        self.opened.append(testing.allocator, copy) catch testing.allocator.free(copy);
        return self.mode;
    }

    fn setMode(self: *Browser, mode: Mode) void {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.mode = mode;
    }

    /// Follow `url` into the receiver, as the browser of the user does.
    fn visit(self: *Browser, io: Io, url: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const v = try https.browse(io, testing.allocator, arena_state.allocator(), url, .{ .trust_pem = self.trust_pem, .through = self.through });
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.last_status = v.status;
        self.last_url.clearRetainingCapacity();
        try self.last_url.appendSlice(testing.allocator, v.url);
    }

    /// GET the start paths of `wrongTokens` on the receiver of the start URL `url`, and keep
    /// their statuses. Then follow `url`.
    fn guess(self: *Browser, io: Io, url: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const split = (std.mem.indexOf(u8, url, oauth.start_path_prefix) orelse return error.TestNoStartUrl) + oauth.start_path_prefix.len;
        for (try wrongTokens(arena, url[split..])) |token| {
            const response = try loopbackGet(io, arena, try std.mem.concat(arena, u8, &.{ url[0..split], token }));
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            try self.guesses.append(testing.allocator, response.status);
        }
        try self.visit(io, url);
    }

    /// GET the start URL `url` two times, and then follow the `Location` of the first
    /// response. Keep the three results.
    fn startTwice(self: *Browser, io: Io, url: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const first = try loopbackGet(io, arena, url);
        const second = try loopbackGet(io, arena, url);
        const location = first.header("location") orelse return error.TestNoLocation;
        const late = try https.browse(io, testing.allocator, arena, location, .{ .trust_pem = self.trust_pem, .through = self.through });
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        const gpa = testing.allocator;
        self.twice.first_status = first.status;
        try self.twice.location.appendSlice(gpa, location);
        try self.twice.cache_control.appendSlice(gpa, first.header("cache-control") orelse "");
        try self.twice.referrer_policy.appendSlice(gpa, first.header("referrer-policy") orelse "");
        self.twice.second_status = second.status;
        try self.twice.second_body.appendSlice(gpa, second.body);
        self.twice.late_status = late.status;
    }

    fn count(self: *Browser) u32 {
        return self.calls.load(.acquire);
    }

    fn lastStatus(self: *Browser) u16 {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return self.last_status;
    }

    /// A copy of the URL of the last page of the last visit, in `arena`.
    fn lastUrl(self: *Browser, arena: Allocator) ![]const u8 {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return arena.dupe(u8, self.last_url.items);
    }

    /// A copy of the URL of the call `index` (from 0), in `arena`.
    fn openedUrl(self: *Browser, arena: Allocator, index: usize) ![]const u8 {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        if (index >= self.opened.items.len) return error.TestNoBrowserCall;
        return arena.dupe(u8, self.opened.items[index]);
    }

    fn deinit(self: *Browser) void {
        const gpa = testing.allocator;
        for (self.opened.items) |url| gpa.free(url);
        self.opened.deinit(gpa);
        self.last_url.deinit(gpa);
        self.guesses.deinit(gpa);
        self.twice.location.deinit(gpa);
        self.twice.cache_control.deinit(gpa);
        self.twice.referrer_policy.deinit(gpa);
        self.twice.second_body.deinit(gpa);
    }
};

/// One response of the loopback receiver of the bridge.
const LoopbackResponse = struct {
    status: u16,
    /// The status line and the header fields.
    head: []const u8,
    body: []const u8,

    /// The value of the header field `name`, or null.
    fn header(self: LoopbackResponse, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }
};

/// Sends one `GET` request for `url` (`http://127.0.0.1:<port>/<path>`) and reads the response.
/// The function does not follow a redirect. The result is in `arena`.
fn loopbackGet(io: Io, arena: Allocator, url: []const u8) !LoopbackResponse {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return error.TestNotLoopback;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.TestNotLoopback;
    const port = try std.fmt.parseInt(u16, rest[0..slash], 10);
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var socket_writer = stream.writer(io, &out_buf);
    try socket_writer.interface.print("GET {s} HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\naccept: text/html\r\nconnection: close\r\n\r\n", .{ rest[slash..], port });
    try socket_writer.interface.flush();
    const in_buf = try arena.alloc(u8, 16 * 1024);
    var socket_reader = stream.reader(io, in_buf);
    var http_reader: std.http.Reader = .{ .in = &socket_reader.interface, .interface = undefined, .state = .ready, .max_head_len = in_buf.len };
    const head = try arena.dupe(u8, try http_reader.receiveHead());
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return error.TestBadResponse;
    var response: LoopbackResponse = .{ .status = try std.fmt.parseInt(u16, head[9..12], 10), .head = head, .body = "" };
    if (response.header("content-length")) |text| {
        const body = try arena.alloc(u8, try std.fmt.parseInt(usize, text, 10));
        try socket_reader.interface.readSliceAll(body);
        response.body = body;
    }
    return response;
}

/// Returns tokens that are not `token`, in `arena`. Three tokens have one different character:
/// at the start, in the middle and at the end. The other tokens have a different case, one
/// character less or one character more. The list also has an empty token and a token with a
/// longer path.
fn wrongTokens(arena: Allocator, token: []const u8) ![]const []const u8 {
    if (token.len < 2) return error.TestShortToken;
    var list: std.ArrayList([]const u8) = .empty;
    for ([_]usize{ 0, token.len / 2, token.len - 1 }) |i| {
        const copy = try arena.dupe(u8, token);
        copy[i] = if (copy[i] == 'A') 'B' else 'A';
        try list.append(arena, copy);
    }
    for (token, 0..) |c, i| if (std.ascii.isAlphabetic(c)) {
        const copy = try arena.dupe(u8, token);
        copy[i] = if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c);
        try list.append(arena, copy);
        break;
    };
    try list.append(arena, token[0 .. token.len - 1]);
    try list.append(arena, try std.mem.concat(arena, u8, &.{ token, "A" }));
    try list.append(arena, "");
    try list.append(arena, try std.mem.concat(arena, u8, &.{ token, "/x" }));
    return list.items;
}

/// Checks that `url` is the start URL of the receiver on `port`, and returns its token. The URL
/// is `http://127.0.0.1:<port>/start/<token>`, and the token has `oauth.start_token_len`
/// characters of base64url. The URL has no query. Thus it has no `state` and no
/// `code_challenge`, and other local users cannot read them in the arguments of a process.
fn expectStartUrl(arena: Allocator, url: []const u8, port: u16) ![]const u8 {
    const prefix = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}" ++ oauth.start_path_prefix, .{port});
    if (!std.mem.startsWith(u8, url, prefix)) {
        std.debug.print("\nthe browser got a URL that is not the start URL on port {d}: {s}\n", .{ port, url });
        return error.TestNotStartUrl;
    }
    const token = url[prefix.len..];
    try testing.expectEqual(oauth.start_token_len, token.len);
    for (token) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    for ([_][]const u8{ "?", "state=", "code_challenge", "redirect_uri", "client_id" }) |part| {
        if (contains(url, part)) {
            std.debug.print("\nthe start URL has '{s}': {s}\n", .{ part, url });
            return error.TestStartUrlHasQuery;
        }
    }
    return token;
}

/// Keeps the sign-in lines of the bridge.
const Lines = struct {
    lock: Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,
    lines: std.atomic.Value(u32) = .init(0),

    fn output(self: *Lines) oauth.Output {
        return .{ .context = self, .write_line = write };
    }

    fn write(context: ?*anyopaque, line: []const u8) void {
        const self: *Lines = @ptrCast(@alignCast(context.?));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.text.appendSlice(testing.allocator, line) catch {};
        _ = self.lines.fetchAdd(1, .acq_rel);
    }

    fn count(self: *Lines) u32 {
        return self.lines.load(.acquire);
    }

    /// The URL of the sign-in line `index` (from 0), in `arena`.
    fn url(self: *Lines, arena: Allocator, index: usize) ![]const u8 {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        var it = std.mem.splitScalar(u8, self.text.items, '\n');
        var i: usize = 0;
        while (it.next()) |line| : (i += 1) {
            if (i != index) continue;
            const prefix = vscode.profile.name ++ ": sign in at ";
            if (!std.mem.startsWith(u8, line, prefix)) return error.TestNoSignInLine;
            return arena.dupe(u8, line[prefix.len..]);
        }
        return error.TestNoSignInLine;
    }

    fn deinit(self: *Lines) void {
        self.text.deinit(testing.allocator);
    }
};

// ---------------------------------------------------------------------------------------------
// The bridge of a test
// ---------------------------------------------------------------------------------------------

/// A bridge with an HTTPS upstream server, as `mcp-bridge-vscode <url>` makes it, in the test
/// process. The upstream configuration and the options of the front end come from
/// `vscode.upstreamConfig` and `vscode.frontendOptions`. The lines of VS Code go to the front end
/// of the transcript.
const Remote = struct {
    t: *Transcript,
    bundle: std.crypto.Certificate.Bundle,
    authorizer: oauth.Authorizer,
    signs_in: bool,
    browser: Browser,
    lines: Lines = .{},

    const Options = struct {
        /// The sign-in of the bridge. Null: the bridge has no sign-in.
        sign_in: ?SignIn = null,
        trust: Trust = .{ .pem = https.ca_pem },
        /// The proxy of the HTTP client and of the sign-in.
        proxy: proxy.Config = .{ .environment = null },
        /// The proxy of the browser of the test.
        browser_proxy: ?proxy.Proxy = null,
        /// The CA certificates that the browser of the test trusts, in PEM.
        browser_trust: []const u8 = https.ca_pem,
        /// The time limit of `server/discover`, as `--discover-timeout`.
        discover_timeout: Io.Duration = .fromSeconds(bridge.Frontend.default_discover_timeout_s),
    };

    /// The CA certificates that the bridge trusts.
    const Trust = union(enum) {
        /// Only the certificates of this PEM text.
        pem: []const u8,
        /// The system trust store and the file at this path, as with `--ca-file`.
        ca_file: []const u8,
    };

    const SignIn = struct {
        /// The token storage. It must stay valid until `destroy`.
        storage: mcp.auth.TokenStorage,
        registration: oauth.Registration = .dynamic,
        account: []const u8 = oauth.default_account,
        /// The redirect port. Null takes a free port.
        port: ?u16 = null,
        browser: Browser.Mode = .follow,
        timeout: Io.Duration = .fromSeconds(30),
        /// The opener of the bridge. Null gives the browser of the test.
        opener: ?oauth.Opener = null,
    };

    /// Make the bridge for `server`. Release it with `destroy`.
    fn create(server: *https.HttpsServer, options: Options) !*Remote {
        const io = testing.io;
        const gpa = testing.allocator;
        const self = try gpa.create(Remote);
        errdefer gpa.destroy(self);
        self.* = .{
            .t = undefined,
            .bundle = undefined,
            .authorizer = undefined,
            .signs_in = options.sign_in != null,
            .browser = .{ .through = options.browser_proxy, .trust_pem = options.browser_trust },
        };
        self.bundle = switch (options.trust) {
            .pem => |pem| try https.certificateBundle(gpa, io, pem),
            .ca_file => |path| try bridge.Upstream.loadCaBundle(io, gpa, path),
        };
        errdefer self.bundle.deinit(gpa);
        if (options.sign_in) |s| {
            self.browser.mode = s.browser;
            try self.authorizer.init(io, gpa, .{
                .identity = vscode.identity,
                .server_url = server.url(),
                .account = s.account,
                .redirect_port = s.port orelse try freePort(io),
                .registration = s.registration,
                .storage = s.storage,
                .ca_bundle = &self.bundle,
                .proxy = options.proxy,
                .timeout = s.timeout,
                .opener = s.opener orelse self.browser.opener(),
                .output = self.lines.output(),
            });
        }
        errdefer if (self.signs_in) self.authorizer.deinit();
        const serve: vscode.ServeOptions = .{
            .upstream = .{ .http = .{ .url = server.url(), .ca_bundle = &self.bundle, .proxy = options.proxy } },
            .sign_in = if (self.signs_in) &self.authorizer else null,
            .discover_timeout = options.discover_timeout,
        };
        self.t = try Transcript.create(.{ .upstream = vscode.upstreamConfig(serve), .frontend = vscode.frontendOptions(serve) });
        return self;
    }

    fn destroy(self: *Remote) void {
        const gpa = testing.allocator;
        // The front end and the HTTP client stop first, because they use the authorizer.
        self.t.destroy();
        if (self.signs_in) self.authorizer.deinit();
        self.bundle.deinit(gpa);
        self.lines.deinit();
        self.browser.deinit();
        gpa.destroy(self);
    }

    fn redirectUri(self: *const Remote) []const u8 {
        return self.authorizer.redirectUri();
    }

    /// The redirect port of the sign-in.
    fn redirectPort(self: *const Remote) u16 {
        return self.authorizer.sign_in.options.redirect_port;
    }

    /// Send `line`, the `initialize` request, and expect a result. Then send
    /// `notifications/initialized` and wait for the first listen stream. Returns the result.
    fn initialize(self: *Remote, line: []const u8) !Value {
        const result = try harness.expectResult(try self.t.call(1, line));
        try self.t.send(harness.initialized);
        try testing.expectEqual(bridge.Frontend.State.ready, self.t.frontend.state());
        try self.t.waitListening(1);
        return result;
    }

    /// Wait until the bridge called the browser `n` times.
    fn waitBrowser(self: *Remote, n: u32) !void {
        const io = testing.io;
        const until = now(io).addDuration(.{ .raw = wait_limit, .clock = .awake });
        while (self.browser.count() < n) {
            if (now(io).durationTo(until).raw.nanoseconds <= 0) {
                std.debug.print("\nthe bridge did not open the browser in {d} s\n", .{wait_limit.toSeconds()});
                return error.TestTimeout;
            }
            try io.sleep(.fromMilliseconds(2), .awake);
        }
    }

    /// Check the sign-in line `index`: its URL passes the check of the bridge and starts with
    /// the issuer of `server`.
    fn expectSignInLine(self: *Remote, server: *https.HttpsServer, index: usize) ![]const u8 {
        const url = try self.lines.url(self.t.arena(), index);
        try oauth.validateAuthorizationUrl(url, .{});
        try testing.expect(std.mem.startsWith(u8, url, server.issuer().?));
        return url;
    }
};

/// The serialized record of the sign-in of `r` in `storage`, in `arena`, or null. The index of
/// the bridge gives its key.
fn storedRecord(arena: Allocator, storage: mcp.auth.TokenStorage, r: *Remote) !?[]const u8 {
    for (try oauth.loadIndex(arena, storage, vscode.identity)) |entry| {
        if (!std.mem.eql(u8, entry.url, r.authorizer.server_url)) continue;
        if (!std.mem.eql(u8, entry.client, r.authorizer.storage_identity)) continue;
        return try storage.vtable.load(storage.ptr, arena, entry.key());
    }
    return null;
}

/// True when a tool of a `tools/list` result has the name `name`.
fn hasTool(result: Value, name: []const u8) bool {
    for (result.object.get("tools").?.array.items) |tool| {
        if (std.mem.eql(u8, mcp.json.getString(tool, "name") orelse "", name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// The registration modes
// ---------------------------------------------------------------------------------------------

/// The URI of the resource of 5 MiB.
const big_resource_uri = "file:///fixture/big.txt";

/// The size of the large results.
const big_bytes = 5 << 20;

fn readBig(ctx: *mcp.RequestContext, uri: []const u8) anyerror!mcp.Outcome(mcp.ReadResourceResult) {
    const text = try ctx.arena.alloc(u8, big_bytes);
    @memset(text, 'r');
    const contents = try ctx.arena.alloc(mcp.types.ResourceContents, 1);
    contents[0] = .{ .text = .{ .uri = uri, .mimeType = "text/plain", .text = text } };
    return .{ .complete = .{ .contents = contents } };
}

test "dynamic registration: initialize signs in, then tools/list and tools/call go over HTTPS, and results of 5 MiB come in one POST" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    try server.server.addResource(.{ .uri = big_resource_uri, .name = "big", .mime_type = "text/plain" }, readBig);
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage() } });
    defer r.destroy();
    const t = r.t;
    const arena = t.arena();

    try testing.expect(r.authorizer.interactive());
    const result = try r.initialize(harness.vscode_initialize);
    try testing.expectEqualStrings(fixture.server_name, mcp.json.getString(result.object.get("serverInfo").?, "name").?);
    // One sign-in: one sign-in line and one call of the browser.
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    try testing.expectEqual(@as(u32, 1), r.lines.count());
    try testing.expectEqual(@as(u16, 200), r.browser.lastStatus());
    _ = try r.expectSignInLine(server, 0);
    // The registration request has the name of the bridge and its exact redirect URI.
    const registered = try server.registrations(arena);
    try testing.expectEqual(@as(usize, 1), registered.len);
    try testing.expectEqualStrings("mcp-bridge-vscode (zig-bridge-sdk)", registered[0].client_name.?);
    try testing.expectEqual(@as(usize, 1), registered[0].redirect_uris.len);
    try testing.expectEqualStrings(r.redirectUri(), registered[0].redirect_uris[0]);
    // The record has the storage identity of the bridge, the account and the redirect URI.
    const identity = try std.fmt.allocPrint(arena, "mcp-bridge-vscode|default|{s}", .{r.redirectUri()});
    try testing.expectEqualStrings(identity, r.authorizer.storage_identity);
    try testing.expect(try storedRecord(arena, memory.storage(), r) != null);
    try testing.expect(!r.authorizer.interactive());

    const list = try harness.expectResult(try t.request(2, "tools/list", null));
    for ([_][]const u8{ "add", fixture.guarded_tool, "big" }) |name| try testing.expect(hasTool(list, name));
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try t.call(3, try addLine(arena, 3)))));

    // A result of 5 MiB comes in one POST to the MCP endpoint, for tools/call and for
    // resources/read.
    const before = server.mcpRequestCount();
    const big = try t.call(4, try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{{\"name\":\"big\",\"arguments\":{{\"bytes\":{d}}}}}}}", .{big_bytes}));
    try testing.expectEqual(@as(usize, big_bytes), (try harness.firstText(try harness.expectResult(big))).len);
    try testing.expectEqual(before + 1, server.mcpRequestCount());
    const read = try harness.expectResult(try t.request(5, "resources/read", "{\"uri\":\"" ++ big_resource_uri ++ "\"}"));
    try testing.expectEqual(@as(usize, big_bytes), read.object.get("contents").?.array.items[0].object.get("text").?.string.len);
    try testing.expectEqual(before + 2, server.mcpRequestCount());
    // No more sign-in.
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    try t.verify();
}

test "an authorization server without registration: the error names --client-id, --client-issuer and the redirect URI, and the client secret from the environment signs in" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .dynamic_registration = false } });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();

    // The default of the bridge without a registration option.
    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage() } });
        defer r.destroy();
        const failed = try r.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, null, "registration_unavailable");
        const message = errorMessage(failed);
        try testing.expect(contains(message, "--client-id"));
        try testing.expect(contains(message, "--client-issuer"));
        try testing.expect(contains(message, try std.fmt.allocPrint(r.t.arena(), "the redirect URI {s} ", .{r.redirectUri()})));
        // No sign-in started, and the connection waits for a new initialize.
        try testing.expectEqual(@as(u32, 0), r.browser.count());
        try testing.expectEqual(@as(u32, 0), r.lines.count());
        try testing.expectEqual(bridge.Frontend.State.awaiting_initialize, r.t.frontend.state());
        try r.t.verify();
    }

    // The pre-registered confidential client. The secret comes from the environment, as
    // `MCP_BRIDGE_CLIENT_SECRET` gives it to the executable.
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put(oauth.client_secret_variable, https.confidential_client_secret);
    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .registration = .{ .pre_registered = .{
            .client_id = https.confidential_client_id,
            .issuer = server.issuer().?,
            .client_secret = environ.get(oauth.client_secret_variable),
        } } } });
        defer r.destroy();
        const arena = r.t.arena();
        _ = try r.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        try testing.expectEqual(@as(usize, 0), (try server.registrations(arena)).len);
        const list = try harness.expectResult(try r.t.request(2, "tools/list", null));
        try testing.expect(hasTool(list, "add"));
        try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try r.t.call(3, try addLine(arena, 3)))));
        // The stored record never has the secret of a pre-registered client.
        const record = (try storedRecord(arena, memory.storage(), r)).?;
        try testing.expect(contains(record, https.confidential_client_id));
        try testing.expect(!contains(record, https.confidential_client_secret));
        try r.t.verify();
    }
}

test "a client ID metadata document on the server replaces the registration" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .client_metadata = true, .dynamic_registration = false } });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const r = try Remote.create(server, .{ .sign_in = .{
        .storage = memory.storage(),
        .registration = .{ .client_metadata_url = server.clientMetadataUrl().? },
    } });
    defer r.destroy();
    const arena = r.t.arena();
    _ = try r.initialize(harness.vscode_initialize);
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    try testing.expectEqual(@as(usize, 0), (try server.registrations(arena)).len);
    // The client ID is the URL of the document.
    const record = (try storedRecord(arena, memory.storage(), r)).?;
    try testing.expect(contains(record, server.clientMetadataUrl().?));
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try r.t.call(2, try addLine(arena, 2)))));
    try r.t.verify();
}

test "the default client ID metadata document of the bridge: without documents on the authorization server, the bridge registers, and without registration the error names --client-id" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    // The command line without a registration option, as `cli.zig` gives it.
    const default_document: oauth.Registration = .{ .client_metadata_url = vscode.client_metadata_url };
    {
        // The authorization server does not accept client ID metadata documents. The bridge
        // then uses dynamic client registration with its name.
        const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
        defer server.stop();
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .registration = default_document } });
        defer r.destroy();
        const arena = r.t.arena();
        _ = try r.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        const registered = try server.registrations(arena);
        try testing.expectEqual(@as(usize, 1), registered.len);
        try testing.expectEqualStrings("mcp-bridge-vscode (zig-bridge-sdk)", registered[0].client_name.?);
        try testing.expectEqualStrings(r.redirectUri(), registered[0].redirect_uris[0]);
        // The document of the bridge has the base storage identity.
        try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "mcp-bridge-vscode|default|{s}", .{r.redirectUri()}), r.authorizer.storage_identity);
        try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try r.t.call(2, try addLine(arena, 2)))));
        try r.t.verify();
    }
    {
        // No documents and no registration: the error names the options.
        const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .dynamic_registration = false } });
        defer server.stop();
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .registration = default_document } });
        defer r.destroy();
        const failed = try r.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, null, "registration_unavailable");
        try testing.expect(contains(errorMessage(failed), "--client-id"));
        try testing.expectEqual(@as(u32, 0), r.browser.count());
        try r.t.verify();
    }
}

// ---------------------------------------------------------------------------------------------
// The stored sign-ins
// ---------------------------------------------------------------------------------------------

/// The settings of one start of the bridge with the file store.
const FileStart = struct {
    server: *https.HttpsServer,
    environ: *const std.process.Environ.Map,
    token_dir: []const u8,
    port: u16,
};

/// Start the bridge with the file store in `s.token_dir` for `account`, initialize it and call a
/// tool. The start needs the browser only when `browser` is true.
fn startWithFileStore(s: FileStart, account: []const u8, browser: bool) !void {
    const io = testing.io;
    const gpa = testing.allocator;
    var store: oauth.TokenStore = undefined;
    try store.open(io, gpa, .{ .choice = .file, .identity = vscode.identity, .environ_map = s.environ, .token_dir = s.token_dir });
    defer store.deinit();
    try testing.expectEqual(oauth.TokenStore.Kind.file, store.activeKind());
    const r = try Remote.create(s.server, .{ .sign_in = .{ .storage = store.storage(), .account = account, .port = s.port } });
    defer r.destroy();
    try testing.expectEqual(browser, r.authorizer.interactive());
    _ = try r.initialize(harness.vscode_initialize);
    try testing.expectEqual(@as(u32, @intFromBool(browser)), r.browser.count());
    try testing.expectEqual(@as(u32, @intFromBool(browser)), r.lines.count());
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try r.t.call(2, try addLine(r.t.arena(), 2)))));
    try r.t.verify();
}

test "the file store keeps the sign-in for the next start, each account has its own record, and logout deletes one record" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_dir = try std.fs.path.join(arena, &.{ try tmp.dir.realPathFileAlloc(io, ".", arena), "tokens" });
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put(oauth.token_key_variable, test_token_key);
    const s: FileStart = .{ .server = server, .environ = &environ, .token_dir = token_dir, .port = try freePort(io) };

    // The first start signs in. Each new start reads the record from the files.
    try startWithFileStore(s, oauth.default_account, true);
    try startWithFileStore(s, oauth.default_account, false);
    // A second account needs its own sign-in.
    try startWithFileStore(s, "work", true);
    try startWithFileStore(s, "work", false);
    try testing.expectEqual(@as(usize, 2), (try server.registrations(arena)).len);

    // logout deletes the record of one account, through the index in the file store.
    {
        var store: oauth.TokenStore = undefined;
        try store.open(io, gpa, .{ .choice = .file, .identity = vscode.identity, .environ_map = &environ, .token_dir = token_dir });
        defer store.deinit();
        try testing.expectEqual(@as(usize, 2), (try oauth.loadIndex(arena, store.storage(), vscode.identity)).len);
        var buf: [oauth.max_redirect_uri_len]u8 = undefined;
        const storage_identity = try vscode.identity.storageIdentity(arena, oauth.default_account, oauth.writeRedirectUri(&buf, s.port));
        const report = try oauth.logout(io, gpa, store.storage(), .{ .identity = vscode.identity, .url = server.url(), .storage_identity = storage_identity });
        try testing.expectEqual(@as(usize, 1), report.deleted);
        try testing.expectEqual(oauth.LogoutReport.Discovery.not_needed, report.discovery);
        try testing.expectEqual(@as(usize, 1), (try oauth.loadIndex(arena, store.storage(), vscode.identity)).len);
    }
    // After logout, the next start signs in and registers again. The other account keeps its
    // record.
    try startWithFileStore(s, oauth.default_account, true);
    try startWithFileStore(s, "work", false);
    try testing.expectEqual(@as(usize, 3), (try server.registrations(arena)).len);
}

test "the authorization server forgot the client: the sign-in ends at its time limit with the logout advice, and after logout the bridge registers again" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    // The access token expires inside the refresh margin of the client, and the server gives no
    // refresh token. Thus each new start needs the authorization endpoint.
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .access_token_lifetime_seconds = 30, .refresh_tokens = false } });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try freePort(io);

    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .port = port } });
        defer r.destroy();
        _ = try r.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), r.browser.count());
    }
    try testing.expectEqual(@as(usize, 1), (try server.registrations(arena)).len);

    try server.forgetClients();
    {
        // The browser gets the error page of the authorization server, and no redirect comes.
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .port = port, .timeout = .fromSeconds(1) } });
        defer r.destroy();
        try testing.expect(r.authorizer.interactive());
        const failed = try r.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, null, "sign_in_timeout");
        const message = errorMessage(failed);
        try testing.expect(contains(message, "did not complete in 1 s"));
        try testing.expect(contains(message, "--sign-in-timeout"));
        try testing.expect(contains(message, "\"mcp-bridge-vscode logout <url>\""));
        // The message never has the URL of the upstream server, because its path or its
        // query can hold a key.
        try testing.expect(!contains(message, server.url()));
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        try testing.expect(r.browser.lastStatus() >= 400);
        // The bridge never deletes the record by itself.
        try testing.expect(try storedRecord(arena, memory.storage(), r) != null);
        try testing.expectEqual(bridge.Frontend.State.awaiting_initialize, r.t.frontend.state());
        try r.t.verify();
    }
    try testing.expectEqual(@as(usize, 1), (try server.registrations(arena)).len);

    var buf: [oauth.max_redirect_uri_len]u8 = undefined;
    const storage_identity = try vscode.identity.storageIdentity(arena, oauth.default_account, oauth.writeRedirectUri(&buf, port));
    const report = try oauth.logout(io, gpa, memory.storage(), .{ .identity = vscode.identity, .url = server.url(), .storage_identity = storage_identity });
    try testing.expectEqual(@as(usize, 1), report.deleted);
    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .port = port } });
        defer r.destroy();
        _ = try r.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try r.t.call(2, try addLine(r.t.arena(), 2)))));
    }
    try testing.expectEqual(@as(usize, 2), (try server.registrations(arena)).len);
}

/// Replace the refresh token of the stored record of `r` with `value`.
fn replaceRefreshToken(storage: mcp.auth.TokenStorage, r: *Remote, value: []const u8) !void {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (try oauth.loadIndex(arena_state.allocator(), storage, vscode.identity)) |entry| {
        if (!std.mem.eql(u8, entry.url, r.authorizer.server_url)) continue;
        if (!std.mem.eql(u8, entry.client, r.authorizer.storage_identity)) continue;
        var record = (try storage.load(gpa, entry.key())) orelse return error.TestNoRecord;
        defer record.deinit(gpa);
        var changed = record;
        changed.refresh_token = value;
        return storage.save(gpa, entry.key(), changed);
    }
    return error.TestNoRecord;
}

test "a stored record that needs a refresh or that has another client ID gets the time limit of the sign-in, and its timeout names the sign-in, not server/discover" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    // The access token expires inside the refresh margin, thus each new start refreshes it.
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{ .access_token_lifetime_seconds = 30, .dynamic_registration = false } });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const port = try freePort(io);
    const public: oauth.Registration = .{ .pre_registered = .{ .client_id = https.public_client_id, .issuer = server.issuer().? } };
    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .registration = public, .port = port } });
        defer r.destroy();
        _ = try r.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), r.browser.count());
    }
    // A short limit of server/discover and a longer limit of the sign-in. The browser never
    // completes the sign-in.
    const discover_timeout: Io.Duration = .fromSeconds(2);
    const sign_in_timeout: Io.Duration = .fromSeconds(3);
    {
        // The authorization server refuses the refresh token, thus the request signs in
        // through the browser.
        const r = try Remote.create(server, .{ .discover_timeout = discover_timeout, .sign_in = .{ .storage = memory.storage(), .registration = public, .port = port, .browser = .silent, .timeout = sign_in_timeout } });
        defer r.destroy();
        try replaceRefreshToken(memory.storage(), r, "made-up-unknown-refresh-token");
        try testing.expect(r.authorizer.interactive());
        const failed = try r.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, null, "sign_in_timeout");
        try testing.expect(contains(errorMessage(failed), "did not complete in 3 s"));
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        try r.t.verify();
    }
    {
        // A different client ID of the command line: the stored record of the other client
        // does not count.
        const other: oauth.Registration = .{ .pre_registered = .{ .client_id = "made-up-other-client", .issuer = server.issuer().? } };
        const r = try Remote.create(server, .{ .discover_timeout = discover_timeout, .sign_in = .{ .storage = memory.storage(), .registration = other, .port = port, .browser = .silent, .timeout = sign_in_timeout } });
        defer r.destroy();
        try testing.expect(r.authorizer.interactive());
        const failed = try r.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, null, "sign_in_timeout");
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        try r.t.verify();
    }
}

// ---------------------------------------------------------------------------------------------
// The step-up of a tool
// ---------------------------------------------------------------------------------------------

test "a step-up asks VS Code with a URL elicitation: a cancel of the call cancels the elicitation, and an accepted elicitation gives the result" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage() } });
    defer r.destroy();
    const t = r.t;
    const arena = t.arena();
    _ = try r.initialize(harness.vscode_initialize);
    try testing.expectEqual(@as(u32, 1), r.browser.count());

    // The tool guarded needs a scope that the token does not have. The bridge asks VS Code.
    // VS Code cancels the call before the user decides.
    try t.send(try guardedLine(arena, 2));
    const first = try t.bridgeRequest("elicitation/create", 1);
    const first_id = first.object.get("id").?.string;
    try t.send(try cancelLine(arena, 2));
    try t.waitIdle();
    try testing.expect((try t.response(2)) == null);
    // The bridge withdraws its elicitation.
    const cancelled = (try t.methodIndexFrom(0, "notifications/cancelled")).?;
    const withdrawn = (try t.parsedFrames())[cancelled].object.get("params").?;
    try testing.expectEqualStrings(first_id, mcp.json.getString(withdrawn, "requestId").?);

    // The next call asks again: a cancel starts no cooldown.
    try t.send(try guardedLine(arena, 3));
    const request = try t.bridgeRequest("elicitation/create", 2);
    const params = request.object.get("params").?;
    try testing.expectEqualStrings("url", mcp.json.getString(params, "mode").?);
    const url = mcp.json.getString(params, "url").?;
    try oauth.validateAuthorizationUrl(url, .{});
    try testing.expect(std.mem.startsWith(u8, url, server.issuer().?));
    try testing.expect(contains(url, "mcp%3Awrite") or contains(url, "mcp:write"));
    const elicitation_id = mcp.json.getString(params, "elicitationId").?;
    // The bridge prints the URL of each sign-in, but it does not open the browser itself.
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    try testing.expectEqualStrings(url, try r.expectSignInLine(server, 2));
    // VS Code accepts, and it opens the URL.
    try t.reply(request, "{\"action\":\"accept\"}");
    try r.browser.visit(io, url);
    const result = try t.waitResponse(3);
    try testing.expectEqualStrings(fixture.guarded_text, try harness.firstText(try harness.expectResult(result)));
    // The completion of the elicitation comes before the result.
    const complete_index = (try t.methodIndexFrom(0, "notifications/elicitation/complete")).?;
    try testing.expect(complete_index < (try t.responseIndex(3)).?);
    const complete = (try t.parsedFrames())[complete_index];
    try testing.expectEqualStrings(elicitation_id, mcp.json.getString(complete.object.get("params").?, "elicitationId").?);

    // The new token has the scope. The next call needs no step-up.
    try testing.expectEqualStrings(fixture.guarded_text, try harness.firstText(try harness.expectResult(try t.call(4, try guardedLine(arena, 4)))));
    try testing.expectEqual(@as(usize, 2), try t.methodCount("elicitation/create"));
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    try t.verify();
}

test "a declined step-up gives -32603, and with a client without URL elicitation the browser never opens" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const port = try freePort(io);

    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .port = port } });
        defer r.destroy();
        const t = r.t;
        _ = try r.initialize(harness.vscode_initialize);
        try t.send(try guardedLine(t.arena(), 2));
        try t.reply(try t.bridgeRequest("elicitation/create", 1), "{\"action\":\"decline\"}");
        const declined = try t.waitResponse(2);
        try harness.expectError(declined, -32603, null, "reauthorization_required");
        try testing.expectEqualStrings("declined", harness.errorDetail(declined).?);
        try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/elicitation/complete"));
        // Only the first sign-in opened the browser.
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        try t.verify();
    }

    // A new start with the stored sign-in, and a client without URL elicitation. The step-up
    // fails at once: no elicitation, no sign-in line and no browser.
    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .port = port } });
        defer r.destroy();
        const t = r.t;
        _ = try r.initialize(form_only_initialize);
        try testing.expectEqual(@as(u32, 0), r.browser.count());
        const failed = try t.call(2, try guardedLine(t.arena(), 2));
        try harness.expectError(failed, -32603, null, "reauthorization_required");
        try testing.expectEqualStrings("no_consent", harness.errorDetail(failed).?);
        try testing.expectEqual(@as(usize, 0), try t.methodCount("elicitation/create"));
        try testing.expectEqual(@as(u32, 0), r.browser.count());
        try testing.expectEqual(@as(u32, 0), r.lines.count());
        // The other tools still work.
        try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try t.call(3, try addLine(t.arena(), 3)))));
        try t.verify();
    }
}

// ---------------------------------------------------------------------------------------------
// The one-time start URL
// ---------------------------------------------------------------------------------------------

/// The `initialize` request of VS Code with the id 2, for a second `initialize` after a failed
/// one.
const vscode_initialize_2 = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":" ++ harness.vscode_initialize_params ++ "}";

test "the browser gets only the one-time start URL, and the start URL leads to the sign-in and the redirect" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage() } });
    defer r.destroy();
    const t = r.t;
    const arena = t.arena();

    _ = try r.initialize(harness.vscode_initialize);
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    // The opener got only the start URL: no state, no code challenge and no query.
    const start_url = try r.browser.openedUrl(arena, 0);
    _ = try expectStartUrl(arena, start_url, r.redirectPort());
    // The sign-in line has the authorization URL with its state and its code challenge. Thus a
    // user can open it when the browser does not open.
    const line_url = try r.expectSignInLine(server, 0);
    const query = try mcp.auth.common.parseQuery(arena, line_url);
    const state: []const u8 = query.get("state") orelse "";
    const code_challenge: []const u8 = query.get("code_challenge") orelse "";
    try testing.expect(state.len > 0);
    try testing.expect(code_challenge.len > 0);
    try testing.expectEqualStrings(r.redirectUri(), query.get("redirect_uri").?);
    // The start URL led through the authorization server to the redirect with the code and the
    // state of the sign-in line, and the receiver answered with its page.
    try testing.expectEqual(@as(u16, 200), r.browser.lastStatus());
    const redirect = try r.browser.lastUrl(arena);
    try testing.expect(std.mem.startsWith(u8, redirect, try std.fmt.allocPrint(arena, "{s}?", .{r.redirectUri()})));
    const redirect_query = try mcp.auth.common.parseQuery(arena, redirect);
    const code: []const u8 = redirect_query.get("code") orelse "";
    try testing.expect(code.len > 0);
    try testing.expectEqualStrings(state, redirect_query.get("state").?);

    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try t.call(2, try addLine(arena, 2)))));
    try t.verify();
}

test "a start path with a wrong token gets 404, and the sign-in goes on and completes" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .browser = .guess } });
    defer r.destroy();
    const t = r.t;
    const arena = t.arena();

    // The browser first sends the guesses of another program. A guess never stops the
    // sign-in, thus the real start URL still works.
    _ = try r.initialize(harness.vscode_initialize);
    _ = try expectStartUrl(arena, try r.browser.openedUrl(arena, 0), r.redirectPort());
    const guesses = blk: {
        r.browser.lock.lockUncancelable(io);
        defer r.browser.lock.unlock(io);
        break :blk try arena.dupe(u16, r.browser.guesses.items);
    };
    try testing.expectEqual((try wrongTokens(arena, "x" ** oauth.start_token_len)).len, guesses.len);
    for (guesses) |status| try testing.expectEqual(@as(u16, 404), status);
    try testing.expectEqual(@as(u16, 200), r.browser.lastStatus());
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try t.call(2, try addLine(arena, 2)))));
    try t.verify();
}

test "a second request of the start URL stops the sign-in at once, the redirect after it gets no token, and a new initialize gets a new start URL" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    // The time limit of the sign-in is much longer than the wait of the test. Thus only the
    // second request can stop the sign-in in time.
    const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .browser = .start_twice, .timeout = .fromSeconds(120) } });
    defer r.destroy();
    const t = r.t;
    const arena = t.arena();

    // Another program sends the first request, and the browser of the user sends the second.
    const started = now(io);
    const failed = try t.call(1, harness.vscode_initialize);
    try expectWithin(since(io, started), stop_bound, "the stop of the sign-in at the second request of the start URL");
    try harness.expectError(failed, -32603, bridge.translate.messageOf(.sign_in_start_reused), "sign_in_start_reused");
    try testing.expect(harness.errorDetail(failed) == null);
    try testing.expectEqual(bridge.Frontend.State.awaiting_initialize, t.frontend.state());
    // The problem of the authorizer has the reason of the sign-in.
    try testing.expectEqual(oauth.Reason.start_reused, r.authorizer.sign_in.lastFailure().?.reason);

    const first_start = try r.browser.openedUrl(arena, 0);
    const first_token = try expectStartUrl(arena, first_start, r.redirectPort());
    const first_line = try r.expectSignInLine(server, 0);
    {
        r.browser.lock.lockUncancelable(io);
        defer r.browser.lock.unlock(io);
        const twice = &r.browser.twice;
        // The first request got the redirect to the authorization URL of the sign-in line,
        // without a store and without a referrer.
        try testing.expectEqual(@as(u16, 303), twice.first_status);
        try testing.expectEqualStrings(first_line, twice.location.items);
        try testing.expectEqualStrings("no-store", twice.cache_control.items);
        try testing.expectEqualStrings("no-referrer", twice.referrer_policy.items);
        // The second request got the page that tells the user to start the sign-in again.
        try testing.expectEqual(@as(u16, 410), twice.second_status);
        try testing.expect(contains(twice.second_body.items, "Start the sign-in again."));
        // The redirect of the authorization server came after the stop. The receiver refused
        // it, thus the bridge got no code for the account of the other program.
        try testing.expectEqual(@as(u16, 400), twice.late_status);
    }

    // A new initialize starts a new sign-in with a new start URL, and the sign-in completes.
    r.browser.setMode(.follow);
    _ = try harness.expectResult(try t.call(2, vscode_initialize_2));
    try t.send(harness.initialized);
    try testing.expectEqual(bridge.Frontend.State.ready, t.frontend.state());
    try t.waitListening(1);
    try testing.expectEqual(@as(u32, 2), r.browser.count());
    const second_token = try expectStartUrl(arena, try r.browser.openedUrl(arena, 1), r.redirectPort());
    try testing.expect(!std.mem.eql(u8, first_token, second_token));
    try testing.expectEqual(@as(u32, 2), r.lines.count());
    try testing.expect(!std.mem.eql(u8, first_line, try r.expectSignInLine(server, 1)));
    try testing.expectEqual(@as(u16, 200), r.browser.lastStatus());
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try t.call(3, try addLine(arena, 3)))));
    try t.verify();
}

/// Waits for the file at `path`, and returns its text in `arena`.
fn waitFile(io: Io, arena: Allocator, path: []const u8) ![]const u8 {
    const until = now(io).addDuration(.{ .raw = wait_limit, .clock = .awake });
    while (true) {
        if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024))) |text| {
            return text;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
        if (now(io).durationTo(until).raw.nanoseconds <= 0) {
            std.debug.print("\nno file {s} in {d} s\n", .{ path, wait_limit.toSeconds() });
            return error.TestTimeout;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "on a POSIX system, the program of BROWSER gets only the start URL as its argument, and the sign-in completes through that URL" {
    switch (builtin.os.tag) {
        // On Windows, the opener of the system opens the real browser.
        .windows, .wasi => return error.SkipZigTest,
        else => {},
    }
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The program writes its arguments to a file and ends. Other local users can read these
    // arguments. The rename makes the file complete in one step.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    if (std.mem.indexOfScalar(u8, dir, '\'') != null) return error.TestPathHasQuote;
    const record = try std.fs.path.join(arena, &.{ dir, "argv.txt" });
    const script = try std.fs.path.join(arena, &.{ dir, "browser.sh" });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = script,
        .data = try std.fmt.allocPrint(arena, "#!/bin/sh\nprintf '%s\\n' \"$#\" \"$@\" > '{s}.part' && mv '{s}.part' '{s}'\n", .{ record, record, record }),
    });
    try Io.Dir.cwd().setFilePermissions(io, script, .fromMode(0o700), .{});
    var environ = try testing.environ.createMap(gpa);
    defer environ.deinit();
    try environ.put("BROWSER", script);
    const system: oauth.SystemOpener = .{ .environ_map = &environ };

    const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .opener = system.opener() } });
    defer r.destroy();
    const t = r.t;
    try t.send(harness.vscode_initialize);
    // The program got one argument: the start URL.
    const argv = try waitFile(io, arena, record);
    var lines = std.mem.splitScalar(u8, argv, '\n');
    try testing.expectEqualStrings("1", lines.next().?);
    const start_url = lines.next().?;
    try testing.expectEqualStrings("", lines.rest());
    _ = try expectStartUrl(arena, start_url, r.redirectPort());
    // The test is the browser of the user: it opens that argument.
    try r.browser.visit(io, start_url);
    try testing.expectEqual(@as(u16, 200), r.browser.lastStatus());
    _ = try harness.expectResult(try t.waitResponse(1));
    try t.waitIdle();
    try t.send(harness.initialized);
    try t.waitListening(1);
    // The sign-in line has the authorization URL, and the test browser got no call.
    const line_url = try r.expectSignInLine(server, 0);
    try testing.expect(contains(line_url, "code_challenge="));
    try testing.expectEqual(@as(u32, 0), r.browser.count());
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try t.call(2, try addLine(arena, 2)))));
    try t.verify();
}

// ---------------------------------------------------------------------------------------------
// The end of the input and a cancel during the sign-in
// ---------------------------------------------------------------------------------------------

test "the end of the input or a cancel of initialize during the wait for the browser ends the sign-in well inside 10 s, 20 times each" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    // The same redirect port in each loop: each stop releases the port of the receiver.
    const port = try freePort(io);
    const Stop = enum { end_of_input, cancel };

    for (0..stop_loops) |_| for ([_]Stop{ .end_of_input, .cancel }) |stop| {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage(), .port = port, .browser = .silent, .timeout = .fromSeconds(120) } });
        defer r.destroy();
        const t = r.t;
        try t.send(harness.vscode_initialize);
        // The sign-in waits for the redirect after the call of the browser.
        try r.waitBrowser(1);
        const started = now(io);
        switch (stop) {
            .end_of_input => t.frontend.shutdown(),
            .cancel => {
                try t.send(cancel_initialize);
                try t.waitIdle();
            },
        }
        try expectWithin(since(io, started), stop_bound, @tagName(stop));
        // A stopped initialize gets no response.
        try testing.expect((try t.response(1)) == null);
        try testing.expectEqual(@as(u32, 1), r.lines.count());
        switch (stop) {
            .end_of_input => try testing.expectEqual(bridge.Frontend.State.closing, t.frontend.state()),
            .cancel => try testing.expectEqual(bridge.Frontend.State.awaiting_initialize, t.frontend.state()),
        }
    };
}

// ---------------------------------------------------------------------------------------------
// The trust, the icons and the proxy
// ---------------------------------------------------------------------------------------------

test "a server certificate of a CA that the bridge does not trust fails initialize with a clear error, and --ca-file with that CA works" {
    const io = testing.io;
    const gpa = testing.allocator;
    const saved = harness.quiet();
    defer testing.log_level = saved;
    const server = try https.HttpsServer.start(gpa, io, .{ .chain = .untrusted, .oauth = .{} });
    defer server.stop();
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();

    {
        const r = try Remote.create(server, .{ .sign_in = .{ .storage = memory.storage() } });
        defer r.destroy();
        const failed = try r.t.call(1, harness.vscode_initialize);
        try harness.expectError(failed, -32603, bridge.translate.messageOf(.transport_failed), "transport_failed");
        // The TLS handshake failed: no request reached the server, and no sign-in started.
        try testing.expectEqual(@as(u32, 0), server.mcpRequestCount());
        try testing.expectEqual(@as(u32, 0), r.browser.count());
        try testing.expectEqual(@as(u32, 0), r.lines.count());
        try testing.expectEqual(bridge.Frontend.State.awaiting_initialize, r.t.frontend.state());
        try r.t.verify();
    }
    // `--ca-file` adds the CA to the system trust store, for the MCP requests and for the
    // requests of the sign-in.
    {
        const r = try Remote.create(server, .{
            .sign_in = .{ .storage = memory.storage() },
            .trust = .{ .ca_file = https.untrusted_ca_file },
            .browser_trust = https.untrusted_ca_pem,
        });
        defer r.destroy();
        _ = try r.initialize(harness.vscode_initialize);
        try testing.expectEqual(@as(u32, 1), r.browser.count());
        try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try r.t.call(2, try addLine(r.t.arena(), 2)))));
        try r.t.verify();
    }
}

/// The icons of the server and of the tool `iconic`: a `data:` icon, and `file:`, `https:` and
/// `http:` icons.
const icon_set = [_]mcp.types.Icon{
    .{ .src = "data:image/png;base64,AA==", .mimeType = "image/png" },
    .{ .src = "file:///home/u/icon.png" },
    .{ .src = "https://mcp.example.com/icon.png" },
    .{ .src = "http://127.0.0.1/icon.png" },
};

fn iconic(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "iconic", .{}) };
}

/// Check that `holder` has only the `data:` icon of `icon_set`.
fn expectDataIconOnly(holder: Value) !void {
    const icons = holder.object.get("icons") orelse return error.TestNoIcons;
    try testing.expectEqual(@as(usize, 1), icons.array.items.len);
    try testing.expectEqualStrings(icon_set[0].src, icons.array.items[0].object.get("src").?.string);
}

test "a remote server over HTTPS: only the data icons of the server and of its tools reach VS Code" {
    const io = testing.io;
    const gpa = testing.allocator;
    // Without an authorization server, the bridge has no sign-in.
    const server = try https.HttpsServer.start(gpa, io, .{});
    defer server.stop();
    server.server.options.info.icons = &icon_set;
    try server.server.addToolJson(.{ .name = "iconic", .description = "A tool with icons of each kind", .icons = &icon_set }, iconic);
    const r = try Remote.create(server, .{});
    defer r.destroy();
    const t = r.t;

    const result = try r.initialize(harness.vscode_initialize);
    try expectDataIconOnly(result.object.get("serverInfo").?);
    const list = try harness.expectResult(try t.request(2, "tools/list", null));
    for (list.object.get("tools").?.array.items) |tool| {
        if (std.mem.eql(u8, mcp.json.getString(tool, "name").?, "iconic")) try expectDataIconOnly(tool);
    }
    // No frame of the bridge has an icon that is not a data icon.
    for (0..t.count()) |i| for (icon_set[1..]) |icon| try testing.expect(!contains(t.text(i), icon.src));
    try t.verify();
}

/// A `CONNECT` proxy on a loopback port, as the proxy of a company network. It records the
/// target of each tunnel. For the host `https.proxy_host` and for 127.0.0.1, it connects to
/// 127.0.0.1 at the port of the target, and it refuses the other hosts. Each connection has its
/// own task, because a listen stream keeps its tunnel open. `stop` wakes the accept loop as
/// `mcp.util.wake` tells, then it cancels the tunnels that are left.
const ConnectProxy = struct {
    io: Io,
    gpa: Allocator,
    listener: Io.net.Server,
    accept_future: Io.Future(void),
    stopping: std.atomic.Value(bool) = .init(false),
    /// The tasks of the connections.
    group: Io.Group = .init,
    lock: Io.Mutex = .init,
    /// The targets of the tunnels, in order. Guarded by `lock`.
    targets: std.ArrayList([]u8) = .empty,

    /// Start the proxy. It must not move until `stop`.
    fn start(self: *ConnectProxy) !void {
        const io = testing.io;
        const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .io = io, .gpa = testing.allocator, .listener = try address.listen(io, .{}), .accept_future = undefined };
        errdefer self.listener.deinit(io);
        self.accept_future = try io.concurrent(acceptLoop, .{self});
    }

    fn stop(self: *ConnectProxy) void {
        mcp.util.wake.cancelAcceptLoop(self.io, &self.accept_future, self.listener.socket.address, &self.stopping);
        self.group.cancel(self.io);
        self.listener.deinit(self.io);
        for (self.targets.items) |target| self.gpa.free(target);
        self.targets.deinit(self.gpa);
    }

    /// The proxy URL for `HTTPS_PROXY`, in `arena`.
    fn url(self: *const ConnectProxy, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{self.listener.socket.address.getPort()});
    }

    /// The proxy for the browser of the tests.
    fn route(self: *const ConnectProxy) proxy.Proxy {
        return .{ .host = "127.0.0.1", .port = self.listener.socket.address.getPort() };
    }

    /// The number of tunnels to `target`, and the number of tunnels to other targets.
    fn counts(self: *ConnectProxy, target: []const u8) struct { usize, usize } {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var same: usize = 0;
        for (self.targets.items) |t| same += @intFromBool(std.mem.eql(u8, t, target));
        return .{ same, self.targets.items.len - same };
    }

    fn record(self: *ConnectProxy, target: []const u8) !void {
        const owned = try self.gpa.dupe(u8, target);
        errdefer self.gpa.free(owned);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.targets.append(self.gpa, owned);
    }

    fn acceptLoop(self: *ConnectProxy) void {
        const io = self.io;
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(io) catch |e| switch (e) {
                error.SocketNotListening, error.Canceled => return,
                else => continue,
            };
            // The connection of `wake`, or a client that came during the stop.
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                return;
            }
            self.group.concurrent(io, serve, .{ self, stream }) catch stream.close(io);
        }
    }

    fn serve(self: *ConnectProxy, client: Io.net.Stream) void {
        defer client.close(self.io);
        self.tunnel(client) catch {};
    }

    fn tunnel(self: *ConnectProxy, client: Io.net.Stream) !void {
        const io = self.io;
        var in_buf: [8192]u8 = undefined;
        var out_buf: [512]u8 = undefined;
        var reader = client.reader(io, &in_buf);
        var writer = client.writer(io, &out_buf);
        var head_reader: std.http.Reader = .{ .in = &reader.interface, .interface = undefined, .state = .ready, .max_head_len = in_buf.len };
        const head = try head_reader.receiveHead();
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        var words = std.mem.splitScalar(u8, lines.first(), ' ');
        const method = words.first();
        const target = words.next() orelse return answer(&writer.interface, .bad_request);
        if (!std.mem.eql(u8, method, "CONNECT")) return answer(&writer.interface, .method_not_allowed);
        const colon = std.mem.lastIndexOfScalar(u8, target, ':') orelse return answer(&writer.interface, .bad_request);
        const host = target[0..colon];
        const port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch return answer(&writer.interface, .bad_request);
        try self.record(target);
        if (!std.ascii.eqlIgnoreCase(host, https.proxy_host) and !std.mem.eql(u8, host, "127.0.0.1")) return answer(&writer.interface, .forbidden);
        const address = try Io.net.IpAddress.parse("127.0.0.1", port);
        const upstream = address.connect(io, .{ .mode = .stream }) catch return answer(&writer.interface, .bad_gateway);
        defer upstream.close(io);
        try writer.interface.writeAll("HTTP/1.1 200 Connection established\r\n\r\n");
        try writer.interface.flush();
        // A second task copies the bytes of the client to the server. When the server closes
        // its side, the copy to the client ends, and the cancel ends the second task.
        var forward = try io.concurrent(copy, .{ io, &reader.interface, upstream, true });
        copyStream(io, upstream, client);
        _ = forward.cancel(io);
    }

    fn answer(w: *Io.Writer, status: std.http.Status) !void {
        try w.print("HTTP/1.1 {d} {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{ @intFromEnum(status), status.phrase() orelse "" });
        try w.flush();
    }

    fn copyStream(io: Io, from: Io.net.Stream, to: Io.net.Stream) void {
        var buf: [16 * 1024]u8 = undefined;
        var reader = from.reader(io, &buf);
        copy(io, &reader.interface, to, false);
    }

    /// The length of the record of an encrypted TLS 1.3 alert without padding. The record has
    /// the alert (2 bytes) and the inner content type (1 byte). It also has the tag of AES-GCM
    /// or ChaCha20-Poly1305 (16 bytes).
    const alert_record_len = 2 + 1 + 16;

    /// True when `bytes` is one TLS 1.3 record with an alert and nothing more. A client sends such
    /// a record, its close_notify, just before it closes the connection. No HTTP request fits in
    /// a record of this length.
    fn isLoneAlert(bytes: []const u8) bool {
        if (bytes.len != 5 + alert_record_len) return false;
        // The type application_data and the version of the record layer of TLS 1.3.
        return bytes[0] == 23 and bytes[1] == 3 and bytes[2] == 3 and std.mem.readInt(u16, bytes[3..5], .big) == alert_record_len;
    }

    /// Copy the bytes of `from` to `to` until the end of `from`. Then end the output of `to`.
    ///
    /// With `drop_alert`, the copy does not send a lone alert record (`isLoneAlert`). The front of
    /// the fixture server closes its connection after each MCP response. A close_notify of the
    /// client that arrives at a closed socket makes the server send a reset. The proxy reads that
    /// reset in the copy to the client, and on Windows Zig std then writes a stack trace in a
    /// Debug build. The client closes the connection after the alert, thus the server loses
    /// nothing.
    fn copy(io: Io, from: *Io.Reader, to: Io.net.Stream, drop_alert: bool) void {
        var buf: [16 * 1024]u8 = undefined;
        var writer = to.writer(io, &buf);
        while (true) {
            if (from.bufferedLen() == 0) from.fillMore() catch break;
            if (drop_alert and isLoneAlert(from.buffered())) {
                from.tossBuffered();
                continue;
            }
            writer.interface.writeAll(from.buffered()) catch break;
            from.tossBuffered();
            writer.interface.flush() catch break;
        }
        to.shutdown(io, .send) catch {};
    }
};

test "HTTPS_PROXY of the environment carries the MCP requests and the requests of the sign-in" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The URLs of the server have the host `fixture.test`, which only the proxy can reach.
    const server = try https.HttpsServer.start(gpa, io, .{ .host = https.proxy_host, .oauth = .{} });
    defer server.stop();
    var tunnels: ConnectProxy = undefined;
    try tunnels.start();
    defer tunnels.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("HTTPS_PROXY", try tunnels.url(arena));
    var memory: mcp.auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();

    const r = try Remote.create(server, .{
        .sign_in = .{ .storage = memory.storage() },
        .proxy = .{ .environment = &environ },
        .browser_proxy = tunnels.route(),
    });
    defer r.destroy();
    const t = r.t;
    _ = try r.initialize(harness.vscode_initialize);
    try testing.expectEqual(@as(u32, 1), r.browser.count());
    _ = try r.expectSignInLine(server, 0);
    try testing.expectEqualStrings("5", try harness.firstText(try harness.expectResult(try t.call(2, try addLine(arena, 2)))));

    // Each tunnel goes to the server: the discovery, the registration, the token request, the
    // browser and the MCP requests. The proxy refused no other host.
    const target = try std.fmt.allocPrint(arena, "{s}:{d}", .{ https.proxy_host, server.port });
    const same, const other = tunnels.counts(target);
    try testing.expectEqual(@as(usize, 0), other);
    // At least the challenge, the metadata documents, the registration, the browser, the token
    // and the MCP requests after the sign-in.
    try testing.expect(same >= 6);
    try testing.expectEqual(@as(usize, 1), (try server.registrations(arena)).len);
    try t.verify();
}
