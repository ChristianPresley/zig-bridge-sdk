//! The HTTPS variant of the upstream server of the tests. `HttpsServer` serves the tools of
//! `fixture.zig` on `https://127.0.0.1:<port>/mcp` with the test certificate of
//! `test/fixtures/tls`.
//!
//! The server has two parts in one process:
//!
//! - A TLS front on the public port. It reads each request and answers the endpoints of the
//!   authorization server and of the fixture. For the MCP endpoint, it checks the access
//!   token and sends the request to the back.
//! - The back: the Streamable HTTP server of zig-sdk on a loopback port without TLS. It
//!   gives the MCP semantics, also SSE and listen streams. The front copies each response
//!   and its stream to the client. When the client closes its connection, the front closes
//!   the connection to the back, and the back cancels the request.
//!
//! With `Options.oauth`, an `mcp.auth.AuthorizationServer` in the same process signs the
//! client in. Its issuer is the origin of the server. Each request needs an access token
//! with `base_scope`. A call of the tool `guarded` also needs `step_up_scope`. Without it,
//! the front answers 403 with `insufficient_scope`, and the client must ask for more scopes.
//!
//! The authorization server approves each request for `subject` without a page, or denies
//! each request when the test sets `OAuth.deny`. It has two clients that the tests know:
//! `confidential_client_id` with `confidential_client_secret`, and `public_client_id`.
//! `HttpsServer.forgetClients` makes it forget each client of the registration endpoint.
//! The POST endpoint `forget_clients_path` does the same for a test in another process.
//!
//! With `Options.bearer_token`, each request to the MCP endpoint needs that static token, as a
//! header of `--header-env` of the bridge sends it. The server then has no authorization
//! server, and its challenge names none.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const mcp = @import("mcp");
const fixture = @import("fixture.zig");

const as = mcp.auth.authorization_server;
const store_mod = mcp.auth.authorization_store;
const tls = mcp.tls;
const http1 = mcp.transport.http1;
const wake = mcp.util.wake;

const log = std.log.scoped(.fixture_https);

/// The test CA in PEM. The tests trust it.
pub const ca_pem = @embedFile("fixtures/tls/ca.crt");
/// The path of the test CA from the root of the repository, for `--ca-file`.
pub const ca_file = "test/fixtures/tls/ca.crt";
/// The second CA in PEM. The tests do not trust it.
pub const untrusted_ca_pem = @embedFile("fixtures/tls/untrusted-ca.crt");
/// The path of the second CA from the root of the repository.
pub const untrusted_ca_file = "test/fixtures/tls/untrusted-ca.crt";

const server_cert_pem = @embedFile("fixtures/tls/server.crt");
const server_key_pem = @embedFile("fixtures/tls/server.key");
const untrusted_server_cert_pem = @embedFile("fixtures/tls/untrusted-server.crt");
const untrusted_server_key_pem = @embedFile("fixtures/tls/untrusted-server.key");

/// The path of the MCP endpoint.
pub const mcp_path = "/mcp";
/// The path of the protected resource metadata (RFC 9728) of the MCP endpoint.
pub const resource_metadata_path = "/.well-known/oauth-protected-resource" ++ mcp_path;
/// The path of the client ID metadata document of the server, with `OAuth.client_metadata`.
pub const client_metadata_path = "/fixture/client.json";
/// A POST to this path makes the authorization server forget each client of the registration
/// endpoint.
pub const forget_clients_path = "/fixture/forget-clients";

/// The scope that each request needs.
pub const base_scope = "mcp:read";
/// The scope that a call of the tool `guarded` also needs.
pub const step_up_scope = "mcp:write";
/// The user of each approved authorization request.
pub const subject = "fixture-user";

/// A pre-registered client with a secret. It authenticates with `client_secret_basic`.
pub const confidential_client_id = "bridge-fixture-confidential";
/// The secret of `confidential_client_id`. It is a test value, not a secret.
pub const confidential_client_secret = "bridge-fixture-secret-0123456789";
/// A pre-registered public client.
pub const public_client_id = "bridge-fixture-public";
/// The `client_name` of the client ID metadata document of the server.
pub const client_metadata_name = "bridge-fixture metadata client";
/// The redirect URI of the pre-registered clients and of the client ID metadata document. The
/// authorization server of zig-sdk accepts each port of a loopback redirect URI.
pub const loopback_redirect_uri = "http://127.0.0.1/callback";
/// A host name for the tests with a proxy. The server certificates name it. No DNS server
/// resolves it, thus only a test proxy can connect to it. zig-sdk never sends a loopback host
/// to a proxy of the environment.
pub const proxy_host = "fixture.test";

const scopes = [_][]const u8{ base_scope, step_up_scope };

/// The most requests on one connection of the front.
const max_requests_per_connection = 100;

/// The certificate of the server.
pub const Chain = enum {
    /// A certificate of the test CA (`ca_pem`).
    trusted,
    /// A certificate of the CA that the tests do not trust (`untrusted_ca_pem`).
    untrusted,
};

pub const Options = struct {
    /// The port on 127.0.0.1. Zero takes a free port: read `HttpsServer.port`.
    port: u16 = 0,
    /// The host of the URLs of the server: the MCP endpoint, the resource and the issuer. The
    /// listener is always on 127.0.0.1. Set `proxy_host` for a test with a proxy. The URL of
    /// the client ID metadata document always has the host 127.0.0.1, because the
    /// authorization server gets it without a proxy.
    host: []const u8 = "127.0.0.1",
    chain: Chain = .trusted,
    /// The options of the MCP server. The server also sets `guarded` and `big`.
    server: fixture.Options = .{},
    /// Require OAuth through the authorization server in the same process. Null serves
    /// without authorization.
    oauth: ?OAuth = null,
    /// Require the header `Authorization: Bearer <bearer_token>` on each request to the MCP
    /// endpoint. A request without it gets 401 with a challenge that names no authorization
    /// server. It does not go with `oauth`. `start` keeps a copy.
    bearer_token: ?[]const u8 = null,
};

pub const OAuth = struct {
    /// Offer dynamic client registration (RFC 7591). False gives an authorization server
    /// without a registration endpoint.
    dynamic_registration: bool = true,
    /// Accept client ID metadata documents. The server then serves its own document at
    /// `client_metadata_path`. The authorization server gets it over HTTPS.
    client_metadata: bool = false,
    /// The CA file of the authorization server for client ID metadata documents. The path
    /// starts at the current directory. The tests run in the root of the repository.
    ca_file: []const u8 = ca_file,
    /// Deny each authorization request. The browser then goes to the redirect URI with
    /// `error=access_denied`. `HttpsServer.setDeny` changes it later.
    deny: bool = false,
    access_token_lifetime_seconds: i64 = 900,
    /// Issue a refresh token with each access token.
    refresh_tokens: bool = true,
};

/// A client that the registration endpoint registered.
pub const Registration = struct {
    client_id: []const u8,
    /// The `client_name` of the registration request.
    client_name: ?[]const u8,
    redirect_uris: []const []const u8,
};

/// The HTTPS server. `start` makes it and starts its tasks. `stop` stops them and releases it.
pub const HttpsServer = struct {
    io: Io,
    gpa: Allocator,
    /// The MCP server. A test can change it, for example with `setToolEnabled`.
    server: *mcp.Server,
    /// The port of the TLS listener on 127.0.0.1.
    port: u16,
    arena_state: std.heap.ArenaAllocator,
    /// `https://<host>:<port>`: the origin of the server, also the issuer.
    origin: []const u8,
    mcp_url: []const u8,
    chain: tls.CertChain,
    chains: [1]*const tls.CertChain,
    tls_server: tls.Server,
    listener: Io.net.Server,
    accept_future: Io.Future(void),
    /// The tasks of the connections of the front.
    group: Io.Group = .init,
    closing: std.atomic.Value(bool) = .init(false),
    back: mcp.transport.http.Server,
    back_future: Io.Future(void),
    auth: ?*Auth,
    /// The copy of `Options.bearer_token` in the arena, or null.
    bearer_token: ?[]const u8,
    max_body_bytes: usize,
    mcp_requests: std.atomic.Value(u32) = .init(0),

    /// Make the server and start to accept connections.
    pub fn start(gpa: Allocator, io: Io, options: Options) !*HttpsServer {
        if (options.oauth != null and options.bearer_token != null) return error.BearerTokenWithOAuth;
        const self = try gpa.create(HttpsServer);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .server = undefined,
            .port = 0,
            .arena_state = .init(gpa),
            .origin = "",
            .mcp_url = "",
            .chain = undefined,
            .chains = undefined,
            .tls_server = undefined,
            .listener = undefined,
            .accept_future = undefined,
            .back = undefined,
            .back_future = undefined,
            .auth = null,
            .bearer_token = null,
            .max_body_bytes = options.server.limits.http.max_body_bytes,
        };
        errdefer self.arena_state.deinit();
        const arena = self.arena_state.allocator();
        if (options.bearer_token) |token| self.bearer_token = try arena.dupe(u8, token);

        var server_options = options.server;
        server_options.guarded = true;
        server_options.big = true;
        self.server = try fixture.build(gpa, io, server_options);
        errdefer fixture.destroy(self.server);

        self.chain = switch (options.chain) {
            .trusted => try tls.CertChain.fromPem(gpa, server_cert_pem, server_key_pem),
            .untrusted => try tls.CertChain.fromPem(gpa, untrusted_server_cert_pem, untrusted_server_key_pem),
        };
        errdefer self.chain.deinit();
        self.chains = .{&self.chain};
        self.tls_server = try tls.Server.init(.{ .chains = &self.chains, .alpn = &.{"http/1.1"} });

        // No `reuse_address`: a second listener cannot share the port.
        const address = try Io.net.IpAddress.parse("127.0.0.1", options.port);
        self.listener = try address.listen(io, .{});
        errdefer self.listener.deinit(io);
        self.port = self.listener.socket.address.getPort();
        self.origin = try std.fmt.allocPrint(arena, "https://{s}:{d}", .{ options.host, self.port });
        self.mcp_url = try std.mem.concat(arena, u8, &.{ self.origin, mcp_path });

        self.back = .init(io, gpa, self.server, .{ .address = "127.0.0.1", .port = 0 });
        try self.back.bind();
        errdefer self.back.deinit();
        self.back_future = try io.concurrent(serveBack, .{&self.back});
        errdefer {
            self.back.shutdown();
            self.back_future.await(io);
        }

        if (options.oauth) |o| self.auth = try Auth.create(self, o);
        errdefer if (self.auth) |a| a.destroy(gpa);

        self.accept_future = try io.concurrent(acceptLoop, .{self});
        return self;
    }

    /// Stop the tasks and release the server.
    pub fn stop(self: *HttpsServer) void {
        const io = self.io;
        const gpa = self.gpa;
        wake.cancelAcceptLoop(io, &self.accept_future, self.listener.socket.address, &self.closing);
        self.group.cancel(io);
        endAccept(io, &self.back);
        self.back.shutdown();
        self.back_future.await(io);
        self.back.deinit();
        self.listener.deinit(io);
        if (self.auth) |a| a.destroy(gpa);
        self.chain.deinit();
        fixture.destroy(self.server);
        self.arena_state.deinit();
        gpa.destroy(self);
    }

    /// The URL of the MCP endpoint: `https://127.0.0.1:<port>/mcp`.
    pub fn url(self: *const HttpsServer) []const u8 {
        return self.mcp_url;
    }

    /// The issuer of the authorization server, or null without OAuth.
    pub fn issuer(self: *const HttpsServer) ?[]const u8 {
        return if (self.auth != null) self.origin else null;
    }

    /// The URL of the client ID metadata document of the server, or null without
    /// `OAuth.client_metadata`.
    pub fn clientMetadataUrl(self: *const HttpsServer) ?[]const u8 {
        const a = self.auth orelse return null;
        return a.client_metadata_url;
    }

    /// The number of requests to the MCP endpoint, also the requests that got a challenge.
    pub fn mcpRequestCount(self: *const HttpsServer) u32 {
        return self.mcp_requests.load(.acquire);
    }

    /// Make the authorization server forget each client of the registration endpoint. Its
    /// registration then stops to work: the authorization endpoint shows an error page and
    /// does not redirect, and the token endpoint answers `invalid_client`.
    pub fn forgetClients(self: *HttpsServer) Allocator.Error!void {
        const a = self.auth orelse return;
        try a.store.forget();
    }

    /// Deny or approve each authorization request from now on.
    pub fn setDeny(self: *HttpsServer, deny: bool) void {
        const a = self.auth orelse return;
        a.decider.deny.store(deny, .release);
    }

    /// The clients of the registration endpoint, in the order of their registration. The
    /// list and its texts are copies in `arena`.
    pub fn registrations(self: *HttpsServer, arena: Allocator) Allocator.Error![]const Registration {
        const a = self.auth orelse return &.{};
        return a.store.copyRegistrations(arena);
    }

    fn serveBack(back: *mcp.transport.http.Server) void {
        back.serve() catch |e| log.warn("the back server stopped: {t}", .{e});
    }

    fn acceptLoop(self: *HttpsServer) void {
        const io = self.io;
        while (!self.closing.load(.acquire)) {
            const stream = self.listener.accept(io) catch |e| switch (e) {
                error.SocketNotListening, error.Canceled => return,
                else => {
                    log.warn("accept failed: {t}", .{e});
                    continue;
                },
            };
            // The connection of `wake`, or a client that came during the stop.
            if (self.closing.load(.acquire)) {
                stream.close(io);
                return;
            }
            const conn = self.gpa.create(Connection) catch {
                stream.close(io);
                continue;
            };
            conn.* = .{ .owner = self, .stream = stream };
            self.group.concurrent(io, Connection.run, .{conn}) catch {
                stream.close(io);
                self.gpa.destroy(conn);
            };
        }
    }

    /// Answer one request. Returns true when the connection can carry one more request.
    /// `socket` is the reader of the socket under TLS.
    fn handle(self: *HttpsServer, request: *http.Server.Request, socket: *Io.net.Stream.Reader) !bool {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The body can use the buffer of the head.
        const target = try arena.dupe(u8, request.head.target);
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        const keep_alive = request.head.keep_alive;
        if (std.mem.eql(u8, path, mcp_path)) return self.forward(arena, request, socket);
        if (self.auth) |a| {
            if (a.server.isEndpoint(target)) {
                _ = try a.server.handleHttp(request, null);
                return request.head.keep_alive;
            }
            if (std.mem.eql(u8, path, resource_metadata_path)) {
                if (request.head.method != .GET) return methodNotAllowed(request, "GET");
                const doc = try a.resource_server.metadataJson(arena);
                try request.respond(doc, .{ .keep_alive = keep_alive, .extra_headers = &json_headers });
                return keep_alive;
            }
            if (a.client_metadata_document) |doc| if (std.mem.eql(u8, path, client_metadata_path)) {
                if (request.head.method != .GET) return methodNotAllowed(request, "GET");
                try request.respond(doc, .{ .keep_alive = keep_alive, .extra_headers = &document_headers });
                return keep_alive;
            };
            if (std.mem.eql(u8, path, forget_clients_path)) {
                if (request.head.method != .POST) return methodNotAllowed(request, "POST");
                try a.store.forget();
                try request.respond("", .{ .status = .no_content, .keep_alive = keep_alive });
                return keep_alive;
            }
        }
        try request.respond("Not Found", .{ .status = .not_found, .keep_alive = keep_alive, .extra_headers = &text_headers });
        return keep_alive;
    }

    /// Check the authorization of a request to the MCP endpoint, send it to the back, and copy
    /// the response to the client. The connection then closes.
    fn forward(self: *HttpsServer, arena: Allocator, request: *http.Server.Request, socket: *Io.net.Stream.Reader) !bool {
        if (request.head.method != .POST) return methodNotAllowed(request, "POST");
        _ = self.mcp_requests.fetchAdd(1, .acq_rel);

        // Copy the headers before the body uses the buffer of the head.
        var headers: std.ArrayList(http.Header) = .empty;
        var authorization: ?[]const u8 = null;
        var method_header: ?[]const u8 = null;
        var name_header: ?[]const u8 = null;
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                authorization = try arena.dupe(u8, h.value);
                continue;
            }
            if (std.ascii.eqlIgnoreCase(h.name, "mcp-method")) method_header = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "mcp-name")) name_header = try arena.dupe(u8, h.value);
            if (forwarded(h.name)) try headers.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
        }

        // The authorization comes before the body. The back checks that the `Mcp-*` headers
        // agree with the body, so the front can trust `Mcp-Name`.
        if (self.auth) |a| switch (try a.resource_server.authorizeRequest(arena, .{ .authorization = authorization, .method = "POST" })) {
            .challenge => |c| {
                try respondChallenge(arena, request, c);
                return false;
            },
            .ok => |principal| if (isGuardedCall(method_header, name_header) and !a.resource_server.hasScope(&principal, step_up_scope)) {
                try respondChallenge(arena, request, try a.stepUpChallenge(arena));
                return false;
            },
        };
        if (self.bearer_token) |token| if (!bearerMatches(authorization, token)) {
            try request.respond("", .{ .status = .unauthorized, .keep_alive = false, .extra_headers = &bearer_challenge_headers });
            return false;
        };

        if (request.head.expect != null) return respondStatus(request, .expectation_failed);
        if (request.head.transfer_encoding == .none and request.head.content_length == null) request.head.content_length = 0;
        if (request.head.content_length) |len| if (len > self.max_body_bytes) return respondStatus(request, .payload_too_large);
        var body_buf: [4096]u8 = undefined;
        const body = request.readerExpectNone(&body_buf).allocRemaining(arena, .limited(self.max_body_bytes)) catch |e| switch (e) {
            error.StreamTooLong => return respondStatus(request, .payload_too_large),
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return false,
        };

        const back = http1.Connection.open(self.io, self.gpa, "127.0.0.1", self.back.bound_port, null) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return respondStatus(request, .bad_gateway),
        };
        defer back.close();
        const host = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{self.back.bound_port});
        back.send("POST", mcp_path, host, headers.items, body) catch return respondStatus(request, .bad_gateway);
        const response = back.receiveHead() catch return respondStatus(request, .bad_gateway);

        // Copy the headers of the response before its body uses the buffer.
        var response_headers: std.ArrayList(http.Header) = .empty;
        var rit = response.head.iterateHeaders();
        while (rit.next()) |h| {
            if (hopByHop(h.name)) continue;
            try response_headers.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
        }
        var body_writer = try request.respondStreaming(&.{}, .{
            .content_length = response.head.content_length,
            .respond_options = .{ .status = response.head.status, .keep_alive = false, .extra_headers = response_headers.items },
        });
        if (!self.relay(back.bodyReader(&response), &body_writer, socket)) return false;
        body_writer.end() catch {};
        return false;
    }

    /// Copy the body of the back to the client until its end. A second task reads the socket
    /// of the client. When the client closes its connection, the copy stops. Returns true
    /// after the complete body.
    fn relay(self: *HttpsServer, body: *Io.Reader, out: *http.BodyWriter, socket: *Io.net.Stream.Reader) bool {
        const Result = union(enum) { copied: bool, client_closed: void };
        var buffer: [2]Result = undefined;
        var select: Io.Select(Result) = .init(self.io, &buffer);
        select.concurrent(.copied, copyBody, .{ body, out }) catch return copyBody(body, out);
        defer select.cancelDiscard();
        select.concurrent(.client_closed, watchClient, .{socket}) catch {};
        const first = select.await() catch return false;
        return switch (first) {
            .copied => |complete| complete,
            .client_closed => false,
        };
    }
};

/// One connection of the front.
const Connection = struct {
    owner: *HttpsServer,
    stream: Io.net.Stream,

    fn run(conn: *Connection) Io.Cancelable!void {
        const self = conn.owner;
        defer {
            conn.stream.close(self.io);
            self.gpa.destroy(conn);
        }
        conn.serve() catch |e| log.debug("a connection ended: {t}", .{e});
    }

    fn serve(conn: *Connection) !void {
        const self = conn.owner;
        const io = self.io;
        const gpa = self.gpa;
        const read_buf = try gpa.alloc(u8, tls.Connection.min_input_buffer_len);
        defer gpa.free(read_buf);
        const write_buf = try gpa.alloc(u8, tls.Connection.min_output_buffer_len);
        defer gpa.free(write_buf);
        const tls_read_buf = try gpa.alloc(u8, tls.Connection.min_read_buffer_len);
        defer gpa.free(tls_read_buf);
        const tls_write_buf = try gpa.alloc(u8, 16 << 10);
        defer gpa.free(tls_write_buf);
        var reader = conn.stream.reader(io, read_buf);
        var writer = conn.stream.writer(io, write_buf);
        var tls_conn = try self.tls_server.accept(&reader.interface, &writer.interface, .{
            .io = io,
            .read_buffer = tls_read_buf,
            .write_buffer = tls_write_buf,
            // HTTP gives the length of each message, so a missing close_notify is an ordinary end.
            .allow_truncation_attacks = true,
        });
        // The front sends no close_notify. HTTP gives the length of each message. The client
        // often closes first after the response, and the write then fails. On Windows, Zig std
        // writes a stack trace for that failure in a Debug build.
        defer tls_conn.deinit();
        var http_server: http.Server = .init(&tls_conn.reader, &tls_conn.writer);
        var served: usize = 0;
        while (served < max_requests_per_connection) : (served += 1) {
            var request = http_server.receiveHead() catch |e| switch (e) {
                error.HttpHeadersOversize => {
                    tls_conn.writer.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
                    tls_conn.writer.flush() catch {};
                    return;
                },
                else => return,
            };
            if (!try self.handle(&request, &reader)) return;
        }
    }
};

/// Copy `body` to `out` until the end of `body`. Returns false when a read or a write fails.
fn copyBody(body: *Io.Reader, out: *http.BodyWriter) bool {
    while (true) {
        if (body.bufferedLen() == 0) body.fillMore() catch |e| return e == error.EndOfStream;
        out.writer.writeAll(body.buffered()) catch return false;
        body.tossBuffered();
        out.flush() catch return false;
    }
}

/// Read the socket of the client until it closes, or until a cancel. The task reads only into
/// the free space at the end of the buffer of the socket, as the HTTP server of zig-sdk does.
fn watchClient(socket: *Io.net.Stream.Reader) void {
    const r = &socket.interface;
    while (r.end < r.buffer.len) r.fillMore() catch return;
}

const json_headers = [_]http.Header{.{ .name = "content-type", .value = "application/json" }};
const document_headers = [_]http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
};
const text_headers = [_]http.Header{.{ .name = "content-type", .value = "text/plain" }};

/// True for a request header that goes to the back.
fn forwarded(name: []const u8) bool {
    for ([_][]const u8{ "content-type", "accept", "accept-encoding", "traceparent", "tracestate" }) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return name.len > 4 and std.ascii.startsWithIgnoreCase(name, "mcp-");
}

/// True for a response header that the front writes itself.
fn hopByHop(name: []const u8) bool {
    for ([_][]const u8{ "connection", "content-length", "transfer-encoding", "keep-alive" }) |n| {
        if (std.ascii.eqlIgnoreCase(name, n)) return true;
    }
    return false;
}

/// The challenge of `Options.bearer_token`. It names no authorization server and no resource
/// metadata, thus a client cannot sign in.
const bearer_challenge_headers = [_]http.Header{.{ .name = "www-authenticate", .value = "Bearer realm=\"bridge-fixture\"" }};

/// True when `authorization` is `Bearer <token>`. The scheme is not case-sensitive.
fn bearerMatches(authorization: ?[]const u8, token: []const u8) bool {
    const value = authorization orelse return false;
    const scheme = "bearer ";
    if (value.len != scheme.len + token.len) return false;
    if (!std.ascii.startsWithIgnoreCase(value, scheme)) return false;
    return std.mem.eql(u8, value[scheme.len..], token);
}

fn isGuardedCall(method: ?[]const u8, name: ?[]const u8) bool {
    return std.mem.eql(u8, method orelse "", "tools/call") and std.mem.eql(u8, name orelse "", fixture.guarded_tool);
}

fn methodNotAllowed(request: *http.Server.Request, allow: []const u8) !bool {
    try request.respond("", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &.{.{ .name = "allow", .value = allow }} });
    return false;
}

/// Answer with `status` and an empty body, and close the connection.
fn respondStatus(request: *http.Server.Request, status: http.Status) !bool {
    try request.respond("", .{ .status = status, .keep_alive = false });
    return false;
}

fn respondChallenge(arena: Allocator, request: *http.Server.Request, c: mcp.auth.resource_server.Challenge) !void {
    var buf: [3]http.Header = undefined;
    var headers: std.ArrayList(http.Header) = .empty;
    try headers.appendSlice(arena, c.headers(&buf));
    try headers.append(arena, json_headers[0]);
    try request.respond(c.body, .{ .status = @enumFromInt(c.status), .keep_alive = false, .extra_headers = headers.items });
}

/// The authorization server and the resource server of an `HttpsServer` with OAuth. The
/// options of the authorization server point into this struct, so it does not move.
const Auth = struct {
    key: mcp.auth.jwt.SigningKey,
    signing_keys: [1]as.SigningKey,
    resources: [1]as.Resource,
    clients: [2]as.ClientRegistration,
    decider: Decider,
    store: ClientStore,
    server: mcp.auth.AuthorizationServer,
    verifier: mcp.auth.JwtVerifier,
    authorization_servers: [1][]const u8,
    resource_server: mcp.auth.ResourceServer,
    client_metadata_url: ?[]const u8,
    client_metadata_document: ?[]const u8,

    fn create(owner: *HttpsServer, o: OAuth) !*Auth {
        const io = owner.io;
        const gpa = owner.gpa;
        const arena = owner.arena_state.allocator();
        const self = try gpa.create(Auth);
        errdefer gpa.destroy(self);
        self.key = try as.generateSigningKey(io);
        errdefer self.key.deinit();
        self.signing_keys = .{.{ .key = &self.key, .kid = "fixture-1" }};
        self.resources = .{.{ .uri = owner.mcp_url }};
        self.clients = .{
            .{
                .client_id = confidential_client_id,
                .client_secret = confidential_client_secret,
                .client_name = "bridge-fixture confidential client",
                .redirect_uris = &.{loopback_redirect_uri},
            },
            .{
                .client_id = public_client_id,
                .client_name = "bridge-fixture public client",
                .redirect_uris = &.{loopback_redirect_uri},
            },
        };
        self.decider = .{};
        self.decider.deny.store(o.deny, .release);
        self.store.init(io, gpa);
        errdefer self.store.deinit();
        if (o.client_metadata) {
            const document_url = try std.fmt.allocPrint(arena, "https://127.0.0.1:{d}{s}", .{ owner.port, client_metadata_path });
            self.client_metadata_url = document_url;
            self.client_metadata_document = try clientMetadataDocument(arena, document_url);
        } else {
            self.client_metadata_url = null;
            self.client_metadata_document = null;
        }
        self.server = try mcp.auth.AuthorizationServer.init(io, gpa, .{
            .issuer = owner.origin,
            .signing_keys = &self.signing_keys,
            .resources = &self.resources,
            .scopes_supported = &scopes,
            .default_scopes = &.{base_scope},
            .authorizer = self.decider.authorizer(),
            .clients = &self.clients,
            // zig-sdk turns dynamic registration off without an explicit value. The bridge
            // registers with it by default.
            .dynamic_registration = if (o.dynamic_registration) .{} else null,
            // The server gets its own document from 127.0.0.1, a private address.
            .client_metadata = if (o.client_metadata) .{ .allow_private_addresses = true, .ca_file = o.ca_file } else null,
            .store = self.store.store(),
            .access_token_lifetime_seconds = o.access_token_lifetime_seconds,
            .issue_refresh_tokens = o.refresh_tokens,
        });
        errdefer self.server.deinit();
        // From now on, each new client comes from the registration endpoint.
        self.store.started = true;
        self.verifier = .{
            .options = .{
                .keys = try self.server.verificationKeys(arena),
                .issuer = owner.origin,
                .audience = owner.mcp_url,
                .token_type = as.access_token_type,
            },
            .clock = .{ .io = io },
        };
        self.authorization_servers = .{owner.origin};
        self.resource_server = .{
            .resource = owner.mcp_url,
            .resource_metadata_url = try std.mem.concat(arena, u8, &.{ owner.origin, resource_metadata_path }),
            .authorization_servers = &self.authorization_servers,
            .scopes_supported = &scopes,
            .required_scopes = &.{base_scope},
            .verifier = self.verifier.verifier(),
        };
        return self;
    }

    fn destroy(self: *Auth, gpa: Allocator) void {
        self.server.deinit();
        self.store.deinit();
        self.key.deinit();
        gpa.destroy(self);
    }

    /// The 403 challenge for a call of the tool `guarded` with a token without
    /// `step_up_scope`. The scope of the challenge has both scopes.
    fn stepUpChallenge(self: *const Auth, arena: Allocator) Allocator.Error!mcp.auth.resource_server.Challenge {
        const description = "The tool needs the scope " ++ step_up_scope;
        return .{
            .status = 403,
            .www_authenticate = try std.fmt.allocPrint(arena, "Bearer error=\"insufficient_scope\", error_description=\"{s}\", resource_metadata=\"{s}\", scope=\"{s} {s}\"", .{
                description, self.resource_server.resource_metadata_url, base_scope, step_up_scope,
            }),
            .body = "{\"error\":\"insufficient_scope\",\"error_description\":\"" ++ description ++ "\"}",
        };
    }
};

/// The client ID metadata document of the server at `url`.
fn clientMetadataDocument(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"client_id\":{f},\"client_name\":{f},\"redirect_uris\":[{f}],\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\",\"application_type\":\"native\"}}", .{
        std.json.fmt(url, .{}), std.json.fmt(client_metadata_name, .{}), std.json.fmt(loopback_redirect_uri, .{}),
    });
}

/// Approves each authorization request for `subject`, or denies each one. The decision has
/// no page.
const Decider = struct {
    deny: std.atomic.Value(bool) = .init(false),

    fn authorizer(self: *Decider) as.Authorizer {
        return .{ .userdata = self, .decide = decide };
    }

    fn decide(userdata: ?*anyopaque, arena: Allocator, request: *const as.AuthorizationRequest) anyerror!as.Decision {
        _ = arena;
        _ = request;
        const self: *Decider = @ptrCast(@alignCast(userdata.?));
        if (self.deny.load(.acquire)) return .deny;
        return .{ .approve = .{ .subject = subject } };
    }
};

/// The store of the authorization server: a `MemoryStore` that records the clients of the
/// registration endpoint and can forget them.
const ClientStore = struct {
    io: Io,
    gpa: Allocator,
    memory: as.MemoryStore,
    lock: Io.Mutex = .init,
    /// False while the authorization server registers its configured clients.
    started: bool = false,
    /// Holds the texts of `registered`.
    records: std.heap.ArenaAllocator,
    registered: std.ArrayList(Registration) = .empty,
    /// The client IDs that the store does not give out any more. The keys are in `records`.
    forgotten: std.StringHashMapUnmanaged(void) = .empty,

    fn init(self: *ClientStore, io: Io, gpa: Allocator) void {
        self.* = .{ .io = io, .gpa = gpa, .memory = .init(io, gpa, .{}), .records = .init(gpa) };
    }

    fn deinit(self: *ClientStore) void {
        self.forgotten.deinit(self.gpa);
        self.registered.deinit(self.gpa);
        self.records.deinit();
        self.memory.deinit();
    }

    fn store(self: *ClientStore) store_mod.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn inner(self: *ClientStore) store_mod.Store {
        return self.memory.store();
    }

    fn forget(self: *ClientStore) Allocator.Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.registered.items) |r| try self.forgotten.put(self.gpa, r.client_id, {});
    }

    fn copyRegistrations(self: *ClientStore, arena: Allocator) Allocator.Error![]const Registration {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const out = try arena.alloc(Registration, self.registered.items.len);
        for (self.registered.items, out) |r, *d| d.* = try copyRegistration(arena, r);
        return out;
    }

    fn copyRegistration(arena: Allocator, r: Registration) Allocator.Error!Registration {
        const uris = try arena.alloc([]const u8, r.redirect_uris.len);
        for (r.redirect_uris, uris) |u, *d| d.* = try arena.dupe(u8, u);
        return .{
            .client_id = try arena.dupe(u8, r.client_id),
            .client_name = if (r.client_name) |n| try arena.dupe(u8, n) else null,
            .redirect_uris = uris,
        };
    }

    const vtable: store_mod.Store.VTable = .{
        .get_client = getClient,
        .put_client = putClient,
        .put_code = putCode,
        .take_code = takeCode,
        .put_refresh_token = putRefreshToken,
        .take_refresh_token = takeRefreshToken,
        .revoke_family = revokeFamily,
        .record_jti = recordJti,
    };

    fn cast(ptr: *anyopaque) *ClientStore {
        return @ptrCast(@alignCast(ptr));
    }

    fn getClient(ptr: *anyopaque, arena: Allocator, client_id: []const u8) store_mod.Error!?store_mod.Client {
        const self = cast(ptr);
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (self.forgotten.contains(client_id)) return null;
        }
        return self.inner().getClient(arena, client_id);
    }

    fn putClient(ptr: *anyopaque, client: *const store_mod.Client) store_mod.Error!void {
        const self = cast(ptr);
        try self.inner().putClient(client);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (!self.started) return;
        const copy = try copyRegistration(self.records.allocator(), .{
            .client_id = client.client_id,
            .client_name = client.client_name,
            .redirect_uris = client.redirect_uris,
        });
        try self.registered.append(self.gpa, copy);
    }

    fn putCode(ptr: *anyopaque, hash: *const store_mod.Hash, record: *const store_mod.CodeRecord, now: i64) store_mod.Error!void {
        return cast(ptr).inner().putCode(hash, record, now);
    }

    fn takeCode(ptr: *anyopaque, arena: Allocator, hash: *const store_mod.Hash, now: i64) store_mod.Error!?store_mod.Taken(store_mod.CodeRecord) {
        return cast(ptr).inner().takeCode(arena, hash, now);
    }

    fn putRefreshToken(ptr: *anyopaque, hash: *const store_mod.Hash, record: *const store_mod.RefreshRecord, now: i64) store_mod.Error!void {
        return cast(ptr).inner().putRefreshToken(hash, record, now);
    }

    fn takeRefreshToken(ptr: *anyopaque, arena: Allocator, hash: *const store_mod.Hash, now: i64) store_mod.Error!?store_mod.Taken(store_mod.RefreshRecord) {
        return cast(ptr).inner().takeRefreshToken(arena, hash, now);
    }

    fn revokeFamily(ptr: *anyopaque, family: *const store_mod.FamilyId, now: i64) store_mod.Error!void {
        return cast(ptr).inner().revokeFamily(family, now);
    }

    fn recordJti(ptr: *anyopaque, key: *const store_mod.Hash, expires_at: i64, now: i64) store_mod.Error!bool {
        const s = cast(ptr).inner();
        return s.vtable.record_jti(s.ptr, key, expires_at, now);
    }
};

// -- Helpers of the tests -------------------------------------------------------------------------

/// A std certificate bundle with the certificates of `pem`, for example `ca_pem`. Give it to
/// `HttpClient.Options.tls` as `.{ .trust = .{ .bundle = &bundle } }` and to
/// `OAuthClient.Options.ca_bundle`. Release it with `deinit(gpa)`.
pub fn certificateBundle(gpa: Allocator, io: Io, pem: []const u8) !std.crypto.Certificate.Bundle {
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(gpa);
    const now_sec = Io.Clock.real.now(io).toSeconds();
    var it: tls.pem.Iterator = .init(pem);
    while (it.nextLabeled("CERTIFICATE")) |block| {
        const der = try block.decode(gpa);
        defer gpa.free(der);
        const start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.appendSlice(gpa, der);
        try bundle.parseCert(gpa, start, now_sec);
    }
    return bundle;
}

/// Ends the accept loop of the zig-sdk HTTP server `server` before its `shutdown`. Call
/// `shutdown` of the server after this function.
///
/// The `shutdown` of zig-sdk cancels the accept loop. On Windows, the cancel of an accept that
/// waits makes Zig std write a stack trace in a Debug build. Thus the function sets the stop
/// flag of the server and connects one time. The loop accepts the connection, sees the flag,
/// closes the connection and ends. The function waits for that close for at most
/// `end_accept_wait`.
pub fn endAccept(io: Io, server: *mcp.transport.http.Server) void {
    server.closing.store(true, .release);
    const Result = union(enum) { closed: void, expired: void };
    var buffer: [2]Result = undefined;
    var select: Io.Select(Result) = .init(io, &buffer);
    defer select.cancelDiscard();
    select.concurrent(.closed, waitForClose, .{ io, server.bound_port }) catch return;
    select.concurrent(.expired, sleepEndAcceptWait, .{io}) catch {};
    _ = select.await() catch {};
}

/// The longest wait of `endAccept`.
const end_accept_wait: Io.Duration = .fromSeconds(2);

fn sleepEndAcceptWait(io: Io) void {
    io.sleep(end_accept_wait, .awake) catch {};
}

/// Connect to 127.0.0.1 at `port`, and read until the other side closes the connection.
fn waitForClose(io: Io, port: u16) void {
    const address = Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    const stream = address.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);
    var buf: [64]u8 = undefined;
    var reader = stream.reader(io, &buf);
    while (true) reader.interface.fillMore() catch return;
}

/// What `browse` saw at the end.
pub const Visit = struct {
    /// The status of the last response.
    status: u16,
    /// The URL of the last request, in the arena of the call.
    url: []const u8,
};

/// The most redirects that `browse` follows.
pub const max_redirects = 5;

pub const BrowseError = error{
    OutOfMemory,
    /// `BrowseOptions.trust_pem` has no certificate that the browser can use.
    InvalidTrust,
    InvalidUrl,
    /// An `http` URL has a host that is not a loopback address.
    NotLoopback,
    ConnectFailed,
    TlsFailed,
    /// The proxy of `BrowseOptions.through` refused the tunnel.
    ProxyRefused,
    Canceled,
    /// The server did not answer with an HTTP response.
    BadResponse,
    /// A redirect has no `Location`, or its `Location` is not an absolute URL.
    BadRedirect,
    TooManyRedirects,
};

/// The settings of `browse`.
pub const BrowseOptions = struct {
    /// The CA certificates that the browser trusts, in PEM.
    trust_pem: []const u8 = ca_pem,
    /// The proxy of each host that is not a loopback host, or null. A loopback host, for
    /// example the host of the redirect URI, gets a direct connection, as in a browser with a
    /// proxy setting.
    through: ?mcp.transport.proxy.Proxy = null,
};

/// Open `url` as a browser does in a test. The function sends a GET request to each URL, and it
/// follows each redirect. An `https` URL needs a certificate of a CA in `options.trust_pem`. An
/// `http` URL needs a loopback host, for example the redirect URI of a sign-in. The result is
/// in `arena`.
pub fn browse(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, options: BrowseOptions) BrowseError!Visit {
    var trust = tls.CaSet.init(gpa);
    defer trust.deinit();
    trust.addPem(options.trust_pem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTrust,
    };
    var current: []const u8 = try arena.dupe(u8, url);
    var redirects: usize = 0;
    while (true) : (redirects += 1) {
        const target = http1.Target.parse(arena, current) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUrl => return error.InvalidUrl,
        };
        // The connection takes an IPv6 address without the brackets of the URL.
        const host = if (std.mem.startsWith(u8, target.host, "[")) target.host[1 .. target.host.len - 1] else target.host;
        const loopback = isLoopbackHost(host);
        if (!target.secure and !loopback) return error.NotLoopback;
        const secure: ?http1.TlsSetup = if (target.secure) .{ .trust = .{ .ca_set = &trust } } else null;
        const conn = http1.Connection.openThrough(io, gpa, if (loopback) null else options.through, host, target.port, secure) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.TlsFailed => return error.TlsFailed,
            error.ConnectFailed => return error.ConnectFailed,
            error.ProxyRefused => return error.ProxyRefused,
        };
        defer conn.close();
        conn.send("GET", target.path, target.host_header, &.{.{ .name = "accept", .value = "text/html" }}, "") catch return error.BadResponse;
        const response = conn.receiveHead() catch return error.BadResponse;
        const status: u16 = @intFromEnum(response.head.status);
        const location: ?[]const u8 = if (response.head.location) |l| try arena.dupe(u8, l) else null;
        _ = conn.bodyReader(&response).discardRemaining() catch {};
        if (status < 300 or status >= 400) return .{ .status = status, .url = current };
        if (redirects == max_redirects) return error.TooManyRedirects;
        const next = location orelse return error.BadRedirect;
        if (!std.ascii.startsWithIgnoreCase(next, "https://") and !std.ascii.startsWithIgnoreCase(next, "http://")) return error.BadRedirect;
        current = next;
    }
}

fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "::1")) return true;
    const ip = Io.net.Ip4Address.parse(host, 0) catch return false;
    return ip.bytes[0] == 127;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

/// The redirect URI of the OAuth clients of the tests. With `headless_redirect`, no listener
/// needs the port.
const test_redirect_uri = "http://127.0.0.1:41999/callback";

const call_options: mcp.Client.RequestOptions = .{ .timeout = .fromSeconds(30) };

/// The arguments of a tool without parameters: an empty object.
const no_arguments: std.json.Value = .{ .object = .empty };

/// An MCP client with `HttpClient`, the trust of one CA and an optional `OAuthClient`. The
/// client must not move after `init`.
const TestClient = struct {
    bundle: std.crypto.Certificate.Bundle,
    oauth: mcp.auth.OAuthClient,
    has_oauth: bool,
    http_client: *mcp.transport.HttpClient,
    client: mcp.Client,

    fn init(self: *TestClient, server: *const HttpsServer, oauth: ?mcp.auth.OAuthClient.Options, trust_pem: []const u8) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        self.bundle = try certificateBundle(gpa, io, trust_pem);
        errdefer self.bundle.deinit(gpa);
        self.has_oauth = oauth != null;
        if (oauth) |o| {
            var options = o;
            options.ca_bundle = &self.bundle;
            self.oauth = .init(io, gpa, options);
        }
        errdefer if (self.has_oauth) self.oauth.deinit();
        self.http_client = try mcp.transport.HttpClient.init(io, gpa, .{
            .url = server.url(),
            .auth = if (self.has_oauth) &self.oauth else null,
            .tls = .{ .trust = .{ .bundle = &self.bundle } },
            .max_response_bytes = 16 << 20,
        });
        errdefer self.http_client.deinit();
        self.client = .init(gpa, io, .{ .info = .{ .name = "fixture-https-test", .version = "0.0.0" } });
        self.client.connect(self.http_client.transport());
    }

    fn deinit(self: *TestClient) void {
        self.client.deinit();
        self.http_client.deinit();
        if (self.has_oauth) self.oauth.deinit();
        self.bundle.deinit(testing.allocator);
    }

    fn discover(self: *TestClient, arena: Allocator) !mcp.types.DiscoverResult {
        return self.client.discover(arena, call_options);
    }

    /// The first text of the result of a call of `tool`.
    fn callText(self: *TestClient, arena: Allocator, tool: []const u8, arguments: anytype) ![]const u8 {
        var diagnostics: mcp.Client.Diagnostics = .{};
        var options = call_options;
        options.diagnostics = &diagnostics;
        const result = self.client.callTool(arena, tool, arguments, options) catch |e| {
            if (diagnostics.rpc_error) |r| std.debug.print("{s}: error {d}: {s}\n", .{ tool, r.code, r.message });
            return e;
        };
        return switch (result.content[0]) {
            .text => |t| t.text,
            else => error.NotText,
        };
    }
};

fn expectDiscover(result: mcp.types.DiscoverResult) !void {
    var found = false;
    for (result.supportedVersions) |v| found = found or std.mem.eql(u8, v, mcp.protocol.version.version);
    try testing.expect(found);
    try testing.expectEqualStrings("The upstream server of the zig-bridge-sdk tests.", result.instructions.?);
}

fn hasScope(oauth: *const mcp.auth.OAuthClient, scope: []const u8) bool {
    for (oauth.granted_scopes.items) |s| if (std.mem.eql(u8, s, scope)) return true;
    return false;
}

fn countProgress(userdata: ?*anyopaque, params: mcp.types.ProgressNotificationParams) void {
    _ = params;
    const count: *u32 = @ptrCast(@alignCast(userdata.?));
    count.* += 1;
}

test "without OAuth, discover, tool calls, SSE progress and a large result go through the TLS front" {
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{});
    defer server.stop();
    var c: TestClient = undefined;
    try c.init(server, null, ca_pem);
    defer c.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectDiscover(try c.discover(arena));
    try testing.expectEqualStrings("5", try c.callText(arena, "add", .{ .a = 2, .b = 3 }));
    // Without the authorization server, the tool guarded needs no scope.
    try testing.expectEqualStrings(fixture.guarded_text, try c.callText(arena, fixture.guarded_tool, no_arguments));

    // The progress notifications come in the SSE stream of the response.
    var progress_count: u32 = 0;
    var options = call_options;
    options.on_progress = countProgress;
    options.userdata = &progress_count;
    _ = try c.client.callTool(arena, "progress", .{ .count = 3 }, options);
    try testing.expectEqual(@as(u32, 3), progress_count);

    // A result of 5 MiB comes in one POST.
    const before = server.mcpRequestCount();
    const text = try c.callText(arena, "big", .{ .bytes = 5 << 20 });
    try testing.expectEqual(@as(usize, 5 << 20), text.len);
    try testing.expectEqual(before + 1, server.mcpRequestCount());
}

fn cancelLater(io: Io, token: *mcp.transport.CancelToken) void {
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    token.cancel(io, "test");
}

test "a cancel of the client ends a slow call, and the server takes the next call" {
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{});
    defer server.stop();
    var c: TestClient = undefined;
    try c.init(server, null, ca_pem);
    defer c.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var token: mcp.transport.CancelToken = .{};
    var canceller = try io.concurrent(cancelLater, .{ io, &token });
    defer canceller.await(io);
    const start = Io.Timestamp.now(io, .awake);
    var options = call_options;
    options.cancel = &token;
    try testing.expectError(error.Canceled, c.client.callTool(arena, "slow", .{ .ms = 60_000 }, options));
    try testing.expect(start.untilNow(io, .awake).toSeconds() < 10);
    try testing.expectEqualStrings("5", try c.callText(arena, "add", .{ .a = 2, .b = 3 }));
}

test "a client that does not trust the CA of the server certificate gets no connection" {
    // The client of zig-sdk writes warnings for the failures that the test causes. The output
    // of the test shows only errors.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{ .chain = .untrusted });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var refused: TestClient = undefined;
    try refused.init(server, null, ca_pem);
    defer refused.deinit();
    if (refused.discover(arena)) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expectError(error.TlsFailed, browse(io, gpa, arena, server.url(), .{}));

    var trusting: TestClient = undefined;
    try trusting.init(server, null, untrusted_ca_pem);
    defer trusting.deinit();
    try expectDiscover(try trusting.discover(arena));
}

test "OAuth with dynamic registration: discover signs in, and the tool guarded asks for a step-up" {
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var c: TestClient = undefined;
    try c.init(server, .{ .client_name = "fixture test client", .redirect_uri = test_redirect_uri }, ca_pem);
    defer c.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectDiscover(try c.discover(arena));
    const registered = try server.registrations(arena);
    try testing.expectEqual(@as(usize, 1), registered.len);
    try testing.expectEqualStrings("fixture test client", registered[0].client_name.?);
    try testing.expectEqualStrings(test_redirect_uri, registered[0].redirect_uris[0]);
    try testing.expect(hasScope(&c.oauth, base_scope));
    try testing.expect(!hasScope(&c.oauth, step_up_scope));

    try testing.expectEqualStrings(fixture.guarded_text, try c.callText(arena, fixture.guarded_tool, no_arguments));
    try testing.expect(hasScope(&c.oauth, step_up_scope));
    try testing.expectEqualStrings("5", try c.callText(arena, "add", .{ .a = 2, .b = 3 }));
    // The step-up needs no second registration.
    try testing.expectEqual(@as(usize, 1), (try server.registrations(arena)).len);
}

test "without a registration endpoint, dynamic registration fails and the pre-registered clients sign in" {
    // The client of zig-sdk writes warnings for the failures that the test causes. The output
    // of the test shows only errors.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{ .oauth = .{ .dynamic_registration = false } });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dynamic: TestClient = undefined;
    try dynamic.init(server, .{ .redirect_uri = test_redirect_uri }, ca_pem);
    defer dynamic.deinit();
    try testing.expectError(error.RegistrationUnavailable, dynamic.oauth.handleChallenge(arena, server.url(), 401, null, 1));
    if (dynamic.discover(arena)) |_| return error.TestUnexpectedResult else |_| {}

    const confidential = [_]mcp.auth.OAuthClient.Credentials{.{ .issuer = server.issuer().?, .client_id = confidential_client_id, .client_secret = confidential_client_secret }};
    var with_secret: TestClient = undefined;
    try with_secret.init(server, .{ .registration = .{ .pre_registered = &confidential }, .redirect_uri = test_redirect_uri }, ca_pem);
    defer with_secret.deinit();
    try expectDiscover(try with_secret.discover(arena));

    const public = [_]mcp.auth.OAuthClient.Credentials{.{ .issuer = server.issuer().?, .client_id = public_client_id }};
    var without_secret: TestClient = undefined;
    try without_secret.init(server, .{ .registration = .{ .pre_registered = &public }, .redirect_uri = test_redirect_uri }, ca_pem);
    defer without_secret.deinit();
    try expectDiscover(try without_secret.discover(arena));

    try testing.expectEqual(@as(usize, 0), (try server.registrations(arena)).len);
}

test "the authorization server gets the client ID metadata document of the server" {
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{ .oauth = .{ .client_metadata = true, .dynamic_registration = false } });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document_url = server.clientMetadataUrl().?;

    var c: TestClient = undefined;
    try c.init(server, .{ .registration = .{ .client_metadata_url = document_url }, .redirect_uri = test_redirect_uri }, ca_pem);
    defer c.deinit();
    try expectDiscover(try c.discover(arena));
    try testing.expectEqual(@as(usize, 0), (try server.registrations(arena)).len);

    // The document passes the checks of the authorization server of zig-sdk.
    const body = try get(io, gpa, arena, document_url);
    const client = try mcp.auth.client_metadata.parseDocument(arena, document_url, body);
    try testing.expectEqualStrings(client_metadata_name, client.client_name.?);
}

test "after the server forgets a client, a refresh registers again, and a sign-in without a refresh token fails" {
    // The client of zig-sdk writes warnings for the failures that the test causes. The output
    // of the test shows only errors.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An access token that expires inside the refresh margin of OAuthClient (60 s). Thus a
    // second client with the same storage does not use the stored access token.
    const lifetime = 30;

    for ([_]bool{ true, false }) |refresh_tokens| {
        const server = try HttpsServer.start(gpa, io, .{ .oauth = .{ .access_token_lifetime_seconds = lifetime, .refresh_tokens = refresh_tokens } });
        defer server.stop();
        var tokens: mcp.auth.MemoryTokenStorage = .init(io, gpa);
        defer tokens.deinit();
        const oauth: mcp.auth.OAuthClient.Options = .{ .redirect_uri = test_redirect_uri, .storage = tokens.storage() };

        var first: TestClient = undefined;
        try first.init(server, oauth, ca_pem);
        defer first.deinit();
        try expectDiscover(try first.discover(arena));
        try testing.expectEqual(@as(usize, 1), (try server.registrations(arena)).len);

        try server.forgetClients();
        var second: TestClient = undefined;
        try second.init(server, oauth, ca_pem);
        defer second.deinit();
        if (refresh_tokens) {
            // The token endpoint refuses the client. OAuthClient deletes the record and
            // registers again.
            try expectDiscover(try second.discover(arena));
            try testing.expectEqual(@as(usize, 2), (try server.registrations(arena)).len);
        } else {
            // The authorization endpoint does not know the client: an error page and no
            // redirect.
            if (second.discover(arena)) |_| return error.TestUnexpectedResult else |_| {}
            try testing.expectEqual(@as(usize, 1), (try server.registrations(arena)).len);
            // A client without the stored record registers again.
            var third: TestClient = undefined;
            try third.init(server, .{ .redirect_uri = test_redirect_uri }, ca_pem);
            defer third.deinit();
            try expectDiscover(try third.discover(arena));
            try testing.expectEqual(@as(usize, 2), (try server.registrations(arena)).len);
        }
    }
}

/// Accepts one connection, reads one request head and answers 200. A stop flag ends the wait
/// for the connection, as `wake.cancelAcceptLoop` expects.
const Receiver = struct {
    listener: Io.net.Server,
    stopping: std.atomic.Value(bool) = .init(false),
    target: [512]u8 = undefined,
    target_len: usize = 0,

    fn run(self: *Receiver) void {
        const io = testing.io;
        const stream = self.listener.accept(io) catch return;
        defer stream.close(io);
        if (self.stopping.load(.acquire)) return;
        var in_buf: [4096]u8 = undefined;
        var out_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);
        var server: http.Server = .init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch return;
        const n = @min(request.head.target.len, self.target.len);
        @memcpy(self.target[0..n], request.head.target[0..n]);
        self.target_len = n;
        request.respond("signed in", .{ .keep_alive = false }) catch {};
    }

    fn query(self: *const Receiver) []const u8 {
        const t = self.target[0..self.target_len];
        const q = std.mem.indexOfScalar(u8, t, '?') orelse return "";
        return t[q + 1 ..];
    }
};

/// One authorization request of the public client to the redirect URI of `receiver`, as the
/// browser gets it. The challenge is the S256 challenge of an empty verifier: the test never
/// sends a token request.
fn browseAuthorization(arena: Allocator, server: *const HttpsServer, redirect_port: u16) !Visit {
    const url = try std.fmt.allocPrint(arena, "{s}/authorize?response_type=code&client_id={s}&redirect_uri=http%3A%2F%2F127.0.0.1%3A{d}%2Fcallback&state=fixture-state&code_challenge=47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU&code_challenge_method=S256", .{ server.origin, public_client_id, redirect_port });
    return browse(testing.io, testing.allocator, arena, url, .{});
}

test "browse follows the redirect of the authorization server to the redirect URI, also with access_denied" {
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{ .oauth = .{ .deny = true } });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]bool{ true, false }) |deny| {
        server.setDeny(deny);
        var receiver: Receiver = .{ .listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{}) };
        defer receiver.listener.deinit(io);
        var future = try io.concurrent(Receiver.run, .{&receiver});
        const visit = browseAuthorization(arena, server, receiver.listener.socket.address.getPort());
        wake.cancelAcceptLoop(io, &future, receiver.listener.socket.address, &receiver.stopping);
        const v = try visit;
        try testing.expectEqual(@as(u16, 200), v.status);
        try testing.expect(std.mem.startsWith(u8, v.url, "http://127.0.0.1:"));
        const q = receiver.query();
        try testing.expect(std.mem.indexOf(u8, q, "state=fixture-state") != null);
        if (deny) {
            try testing.expect(std.mem.indexOf(u8, q, "error=access_denied") != null);
        } else {
            try testing.expect(std.mem.indexOf(u8, q, "code=") != null);
        }
    }

    // A dynamic client with the default decision signs in after the deny ends.
    var c: TestClient = undefined;
    try c.init(server, .{ .redirect_uri = test_redirect_uri }, ca_pem);
    defer c.deinit();
    try expectDiscover(try c.discover(arena));
}

/// The body of a GET request to `url` with the trust of the test CA.
fn get(io: Io, gpa: Allocator, arena: Allocator, url: []const u8) ![]const u8 {
    const target = try http1.Target.parse(arena, url);
    var trust = tls.CaSet.init(gpa);
    defer trust.deinit();
    try trust.addPem(ca_pem);
    const conn = try http1.Connection.open(io, gpa, target.host, target.port, .{ .trust = .{ .ca_set = &trust } });
    defer conn.close();
    try conn.send("GET", target.path, target.host_header, &.{}, "");
    const response = try conn.receiveHead();
    if (response.head.status != .ok) return error.UnexpectedStatus;
    return conn.bodyReader(&response).allocRemaining(arena, .limited(1 << 20));
}

/// The status of a POST request without a body to `url` with the trust of the test CA.
fn post(io: Io, gpa: Allocator, arena: Allocator, url: []const u8) !http.Status {
    const target = try http1.Target.parse(arena, url);
    var trust = tls.CaSet.init(gpa);
    defer trust.deinit();
    try trust.addPem(ca_pem);
    const conn = try http1.Connection.open(io, gpa, target.host, target.port, .{ .trust = .{ .ca_set = &trust } });
    defer conn.close();
    try conn.send("POST", target.path, target.host_header, &.{}, "");
    const response = try conn.receiveHead();
    _ = conn.bodyReader(&response).discardRemaining() catch {};
    return response.head.status;
}

test "the metadata documents and the endpoint that forgets the clients" {
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{ .oauth = .{} });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prm = try mcp.json.parseTree(arena, try get(io, gpa, arena, try std.mem.concat(arena, u8, &.{ server.origin, resource_metadata_path })));
    try testing.expectEqualStrings(server.url(), mcp.json.getString(prm, "resource").?);
    try testing.expectEqualStrings(server.origin, prm.object.get("authorization_servers").?.array.items[0].string);

    const metadata = try mcp.json.parseTree(arena, try get(io, gpa, arena, try std.mem.concat(arena, u8, &.{ server.origin, "/.well-known/oauth-authorization-server" })));
    try testing.expectEqualStrings(server.origin, mcp.json.getString(metadata, "issuer").?);
    try testing.expect(mcp.json.getString(metadata, "registration_endpoint") != null);
    try testing.expect(metadata.object.get("client_id_metadata_document_supported").?.bool == false);

    // A request without a token gets a challenge. A GET request gets no challenge.
    try testing.expectEqual(http.Status.unauthorized, try post(io, gpa, arena, server.url()));
    try testing.expectError(error.UnexpectedStatus, get(io, gpa, arena, server.url()));

    var c: TestClient = undefined;
    try c.init(server, .{ .redirect_uri = test_redirect_uri }, ca_pem);
    defer c.deinit();
    try expectDiscover(try c.discover(arena));
    try testing.expectEqual(http.Status.no_content, try post(io, gpa, arena, try std.mem.concat(arena, u8, &.{ server.origin, forget_clients_path })));
    try testing.expectEqual(http.Status.not_found, try post(io, gpa, arena, try std.mem.concat(arena, u8, &.{ server.origin, "/unknown" })));
}

test "with a bearer token, each request needs the token, and the challenge names no authorization server" {
    // The client of zig-sdk writes warnings for the failures that the test causes. The output
    // of the test shows only errors.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;
    const gpa = testing.allocator;
    const io = testing.io;
    const token = "fixture-static-token";
    try testing.expectError(error.BearerTokenWithOAuth, HttpsServer.start(gpa, io, .{ .bearer_token = token, .oauth = .{} }));
    const server = try HttpsServer.start(gpa, io, .{ .bearer_token = token });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(server.issuer() == null);
    try testing.expectEqual(http.Status.unauthorized, try post(io, gpa, arena, server.url()));
    // No metadata document: a client finds no authorization server.
    try testing.expectError(error.UnexpectedStatus, get(io, gpa, arena, try std.mem.concat(arena, u8, &.{ server.origin, resource_metadata_path })));

    var bundle = try certificateBundle(gpa, io, ca_pem);
    defer bundle.deinit(gpa);
    const cases = [_]struct { authorization: []const u8, accepted: bool }{
        .{ .authorization = "Bearer " ++ token, .accepted = true },
        .{ .authorization = "bearer " ++ token, .accepted = true },
        .{ .authorization = "Bearer " ++ token ++ "x", .accepted = false },
        .{ .authorization = "Basic " ++ token, .accepted = false },
    };
    for (cases) |case| {
        const http_client = try mcp.transport.HttpClient.init(io, gpa, .{
            .url = server.url(),
            .extra_headers = &.{.{ .name = "authorization", .value = case.authorization }},
            .tls = .{ .trust = .{ .bundle = &bundle } },
        });
        defer http_client.deinit();
        var client: mcp.Client = .init(gpa, io, .{ .info = .{ .name = "fixture-https-test", .version = "0.0.0" } });
        defer client.deinit();
        client.connect(http_client.transport());
        var diagnostics: mcp.Client.Diagnostics = .{};
        var options = call_options;
        options.diagnostics = &diagnostics;
        if (case.accepted) {
            try expectDiscover(try client.discover(arena, options));
        } else {
            if (client.discover(arena, options)) |_| return error.TestUnexpectedResult else |_| {}
            try testing.expectEqual(@as(?u16, 401), diagnostics.http_status);
        }
    }
}

test "the option host names the URLs, and the certificate names proxy_host" {
    const gpa = testing.allocator;
    const io = testing.io;
    const server = try HttpsServer.start(gpa, io, .{ .host = proxy_host, .oauth = .{} });
    defer server.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const origin = try std.fmt.allocPrint(arena, "https://{s}:{d}", .{ proxy_host, server.port });
    try testing.expectEqualStrings(try std.mem.concat(arena, u8, &.{ origin, mcp_path }), server.url());
    try testing.expectEqualStrings(origin, server.issuer().?);

    // A connection to 127.0.0.1 that verifies the name proxy_host, as through a proxy.
    var trust = tls.CaSet.init(gpa);
    defer trust.deinit();
    try trust.addPem(ca_pem);
    const conn = try http1.Connection.open(io, gpa, "127.0.0.1", server.port, .{ .trust = .{ .ca_set = &trust }, .server_name = proxy_host });
    defer conn.close();
    try conn.send("GET", resource_metadata_path, origin["https://".len..], &.{}, "");
    const response = try conn.receiveHead();
    try testing.expectEqual(http.Status.ok, response.head.status);
    const prm = try mcp.json.parseTree(arena, try conn.bodyReader(&response).allocRemaining(arena, .limited(1 << 20)));
    try testing.expectEqualStrings(server.url(), mcp.json.getString(prm, "resource").?);
}

test "certificateBundle reads each certificate of a PEM text" {
    const gpa = testing.allocator;
    var bundle = try certificateBundle(gpa, testing.io, ca_pem ++ untrusted_ca_pem);
    defer bundle.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), bundle.map.count());
}
