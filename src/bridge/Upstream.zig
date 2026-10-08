//! The modern side of a bridge: an `mcp.Client` of revision 2026-07-28 and its transport. The
//! front end makes one `Upstream` for each connection of the client. `connect` starts the
//! upstream server, and `close` stops it.
//!
//! This version has four transports:
//!
//! - `stdio`: the bridge starts the upstream command as a child process. The child process
//!   writes its stderr lines to the stderr of the bridge. The client never starts the child
//!   process again: when it stops, `gone` gives true.
//! - `http`: the Streamable HTTP client transport of zig-sdk (`mcp.transport.HttpClient`) to
//!   the URL of a remote upstream server. Each request has its own connection. A failed
//!   request fails alone, thus `gone` always gives false, and the bridge continues. The
//!   results keep only the `data:` icons (`isRemote`).
//! - `memory`: an `mcp.Server` in the same process, through `mcp.transport.memory.ClientLink`.
//!   The tests use it.
//! - `transport`: a client transport of the caller. The tests use it to script the responses
//!   of the upstream server, also for `server/discover`.
//!
//! The client accepts responses with up to `mcp.json.max_message_depth` levels of nesting,
//! because VS Code reads JSON of all depths. Thus the schema rules of `translate` see each
//! tool, and a deep schema does not make the whole `tools/list` fail.
//!
//! The notifications of the upstream server go to these functions:
//!
//! - The progress of a request goes to `Callbacks.progress` of the request.
//! - A log message goes to `Callbacks.log` of its request when the transport routes it to the
//!   request. The memory link does that. On stdio, a log message has no progress token and no
//!   subscription id, thus the reader task of the client gives it to `on_log`.
//! - The events of a listen stream go to `ListenOpts.on_notification` of the stream.
//!
//! The client drops each other notification, also a `notifications/cancelled` of the upstream
//! server.
const Upstream = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const types = mcp.types;
const CancelToken = mcp.transport.CancelToken;

const log = std.log.scoped(.bridge);

io: Io,
gpa: Allocator,
config: Config,
/// The connection after `connect`, or null. Only the task that calls `connect` and `close`
/// changes it. The other tasks read it only after the front end published the connection.
conn: ?*Connection = null,
/// The process id of the child process on POSIX, or 0. Another thread can read it, thus it is
/// atomic.
child_pid: std.atomic.Value(i32) = .init(0),
/// Receives the log messages of a stdio upstream server that the client cannot give to a
/// request. Set it before `connect`. The function runs on the reader task of the client. It
/// must only translate the message and write it, because the reader task reads no frame while
/// the function runs.
on_log: ?LogSink = null,

/// The upstream server of a bridge.
pub const Config = union(enum) {
    /// Start a command and speak MCP over its stdin and stdout.
    stdio: Stdio,
    /// Speak MCP over Streamable HTTP to the URL of a remote server.
    http: Http,
    /// Speak to an `mcp.Server` in this process. The caller owns the server.
    memory: *mcp.Server,
    /// Speak through a client transport. The caller owns the transport, and it must stay
    /// valid while the `Upstream` lives.
    transport: mcp.transport.Transport.ClientTransport,

    pub const Stdio = struct {
        /// The command and its arguments. The slices must stay valid while the `Upstream`
        /// lives.
        argv: []const []const u8,
        /// The current directory of the child process. Null uses the current directory of
        /// the bridge.
        cwd: ?[]const u8 = null,
        /// The maximum length of one line from the upstream server. VS Code reads lines of
        /// all lengths, thus the default is larger than the default of zig-sdk.
        max_line_bytes: usize = default_max_line_bytes,
    };

    /// The settings of the HTTP client transport. Each slice and each pointer must stay valid
    /// while the `Upstream` lives.
    pub const Http = struct {
        /// The URL of the MCP endpoint of the upstream server. The caller checks the scheme:
        /// the command line of a bridge permits `https`, and `http` only for a loopback host.
        url: []const u8,
        /// The headers of the configuration, for example an `authorization` header with a
        /// static token. Each request sends them after the headers of zig-sdk. The caller
        /// refuses the names that zig-sdk sends. The log lines never show a value.
        headers: []const std.http.Header = &.{},
        /// The authorization of the requests, or null. A static `authorization` header in
        /// `headers` and `auth` exclude each other, because a request must not have two
        /// `authorization` headers.
        auth: ?Auth = null,
        /// The maximum length of one message from the upstream server: a JSON body, or one
        /// event of an SSE response. An SSE response has no limit of its total length. Thus
        /// a long tool call and a listen stream continue. A longer message makes the request
        /// fail, and the client does not send it again.
        max_response_bytes: usize = default_max_response_bytes,
        /// The CA certificates for an `https` URL. Null uses the system trust store.
        /// `loadCaBundle` gives the system trust store and the certificates of a file.
        ca_bundle: ?*const std.crypto.Certificate.Bundle = null,
        /// The HTTP proxy. The default reads no environment, thus the client connects
        /// directly. An executable gives `.{ .environment = init.environ_map }`, so that
        /// `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` apply. A loopback host never gets a
        /// proxy from the environment.
        proxy: mcp.transport.proxy.Config = .{ .environment = null },
    };
};

/// The authorization of the requests to an HTTP upstream server. `oauth.Authorizer.provider`
/// gives the provider of the sign-in of the bridge. A static token goes in
/// `Config.Http.headers` and not here.
pub const Auth = struct {
    /// Gives the token of each request, and answers the 401 and 403 challenges of the
    /// upstream server. The HTTP client transport of zig-sdk calls it in the task of the
    /// request. It must stay valid while the `Upstream` lives.
    provider: mcp.auth.Provider,
};

/// The default of `Config.Stdio.max_line_bytes`: 64 MiB.
pub const default_max_line_bytes: usize = 64 << 20;

/// The default of `Config.Http.max_response_bytes`: 64 MiB, the same as the line limit of a
/// stdio upstream server. VS Code reads messages of all lengths.
pub const default_max_response_bytes: usize = 64 << 20;

const Connection = struct {
    /// Holds the client information and the capabilities of the client.
    arena: std.heap.ArenaAllocator,
    client: mcp.Client,
    transport: union(enum) {
        stdio: *mcp.transport.stdio.Client,
        http: *mcp.transport.HttpClient,
        memory: mcp.transport.memory.ClientLink,
        external: mcp.transport.Transport.ClientTransport,
    },
    tracer: Tracer,
};

/// The settings of one request to the upstream server.
pub const RequestOpts = struct {
    /// The request stops when this token fires. The client then sends `notifications/cancelled`
    /// to the upstream server and returns `error.Canceled`.
    cancel: *CancelToken,
    /// The time limit of the request, with all its rounds. It must be finite.
    timeout: Io.Duration,
    /// Receive the progress and the log messages of the request. Null drops them.
    callbacks: ?Callbacks = null,
    /// Receives the JSON-RPC error of the upstream server after `error.Rpc`.
    diagnostics: ?*mcp.Client.Diagnostics = null,
    /// The id of the request of the client, for the debug log lines. The value must stay
    /// valid during the request.
    client_id: ?mcp.RequestId = null,
    /// The log level of the client. The upstream server sends the log messages of the request
    /// at this level and above. Null asks for no log messages.
    log_level: ?types.LoggingLevel = null,
    /// The `_meta` entries of the client for the upstream server, for example `traceparent`.
    /// The client of zig-sdk refuses a key that `mcp.protocol.meta.validateKey` refuses and a
    /// key of zig-sdk. The request then fails with `error.InvalidMeta`, and nothing goes out.
    /// `translate.passMeta` removes these keys.
    meta: ?std.json.ObjectMap = null,
};

/// Receives the notifications of one request. The client calls the functions in the task of
/// the request, before the response. The params are valid only during the call.
pub const Callbacks = struct {
    context: *anyopaque,
    /// Receives each progress notification. In each round of the request, the upstream server
    /// sends the progress with the id of that round as its token. Thus the function gets the
    /// progress of all rounds of the request. Null drops the progress.
    progress: ?*const fn (context: ?*anyopaque, params: types.ProgressNotificationParams) void = null,
    /// Receives each log message that the transport routes to the request. The memory link
    /// routes each log message of a request. On stdio, `on_log` of the `Upstream` gets the log
    /// messages. Null drops them.
    log: ?*const fn (context: ?*anyopaque, params: types.LoggingMessageNotificationParams) void = null,
};

/// Receives the log messages of a stdio upstream server. The params are valid only during
/// the call.
pub const LogSink = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, params: types.LoggingMessageNotificationParams) void,
};

/// The settings of a listen stream (`listen`).
pub const ListenOpts = struct {
    /// The stream stops when this token fires. The client then sends `notifications/cancelled`
    /// to the upstream server and returns `error.Canceled`.
    cancel: *CancelToken,
    /// Receives each notification of the stream, also the acknowledgment. On stdio, the
    /// function runs on the reader task of the client, before the reader task reads the next
    /// frame. Thus an event gets to the function before a response that the upstream server
    /// wrote after the event. On the memory link, the function runs on the task that publishes
    /// the event, and the server holds its locks. Thus the function must only translate the
    /// notification and write it. It must not wait, and it must not send a request.
    ///
    /// `method` and `params` are valid only during the call.
    on_notification: *const fn (context: ?*anyopaque, method: []const u8, params: ?Value) void,
    context: *anyopaque,
    /// The log level of the client, as for each request.
    log_level: ?types.LoggingLevel = null,
    /// Receives the JSON-RPC error of the upstream server after `error.Rpc`.
    diagnostics: ?*mcp.Client.Diagnostics = null,
};

pub const ConnectError = error{
    /// The bridge cannot start the upstream command.
    SpawnFailed,
    /// The bridge cannot make the HTTP client. The URL is not valid, the bridge cannot read
    /// the system trust store, or a proxy variable has no `http` proxy URL. A configuration
    /// with `auth` and a static `authorization` header also gives this error. The log has the
    /// cause.
    ConnectFailed,
    OutOfMemory,
};

pub const RequestError = mcp.Client.RequestError;

/// Make an `Upstream` without a connection. Release it with `deinit`.
pub fn init(io: Io, gpa: Allocator, config: Config) Allocator.Error!*Upstream {
    const self = try gpa.create(Upstream);
    self.* = .{ .io = io, .gpa = gpa, .config = config };
    return self;
}

/// Stop the upstream server and release the `Upstream`.
pub fn deinit(self: *Upstream) void {
    self.close();
    self.gpa.destroy(self);
}

/// Start the upstream server and make the client. `info` and `capabilities` go into the
/// `_meta` of each request. The function copies them. A connection that exists stops first.
pub fn connect(self: *Upstream, info: types.Implementation, capabilities: types.ClientCapabilities) ConnectError!void {
    self.close();
    const conn = try self.gpa.create(Connection);
    conn.* = .{ .arena = .init(self.gpa), .client = undefined, .transport = undefined, .tracer = undefined };
    errdefer {
        conn.arena.deinit();
        self.gpa.destroy(conn);
    }
    const arena = conn.arena.allocator();
    var limits: mcp.Limits = .{};
    limits.json_max_depth = mcp.json.max_message_depth;
    switch (self.config) {
        .stdio => |s| limits.stdio.max_line_bytes = s.max_line_bytes,
        .http, .memory, .transport => {},
    }
    conn.client = .init(self.gpa, self.io, .{
        .info = try deepCopy(types.Implementation, arena, info),
        .capabilities = try deepCopy(types.ClientCapabilities, arena, capabilities),
        .limits = limits,
    });
    errdefer conn.client.deinit();
    switch (self.config) {
        .stdio => |s| {
            // The client never starts the child process again. When it stops, the bridge
            // answers the requests in flight and exits, and VS Code starts the bridge again.
            // A notification without a progress token and without a subscription id goes to
            // the `on_notification` spawn option. `onStdioNotification` gives only the log
            // messages to `on_log`, and drops each other such notification, also a
            // `notifications/cancelled` of the upstream server.
            const child = mcp.transport.stdio.Client.spawn(self.io, self.gpa, .{
                .argv = s.argv,
                .cwd = if (s.cwd) |p| .{ .path = p } else .inherit,
                .limits = limits,
                .max_restarts = 0,
                .on_notification = onStdioNotification,
                .userdata = self,
            }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("cannot start the upstream command: {t}", .{e});
                    return error.SpawnFailed;
                },
            };
            conn.transport = .{ .stdio = child };
            if (comptime hasPid()) if (child.child.id) |id| self.child_pid.store(@intCast(id), .release);
        },
        .http => |h| {
            // zig-sdk would send the header of the provider and the static header.
            if (h.auth != null) for (h.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                log.warn("a static authorization header and the sign-in of the bridge exclude each other", .{});
                return error.ConnectFailed;
            };
            // `init` makes no connection. Each request opens its own connection, through the
            // proxy when there is one.
            const client = mcp.transport.HttpClient.init(self.io, self.gpa, .{
                .url = h.url,
                .extra_headers = h.headers,
                .max_response_bytes = h.max_response_bytes,
                .auth_provider = if (h.auth) |a| a.provider else null,
                .tls = if (h.ca_bundle) |b| .{ .trust = .{ .bundle = b } } else null,
                .proxy = h.proxy,
            }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("cannot make the HTTP client for the upstream server: {t}", .{e});
                    return error.ConnectFailed;
                },
            };
            conn.transport = .{ .http = client };
        },
        .memory => |server| conn.transport = .{ .memory = .init(self.io, self.gpa, server) },
        .transport => |t| conn.transport = .{ .external = t },
    }
    conn.tracer = .{ .io = self.io, .gpa = self.gpa, .inner = switch (conn.transport) {
        .stdio => |c| c.transport(),
        .http => |c| c.transport(),
        .memory => |*link| link.transport(),
        .external => |t| t,
    } };
    conn.client.connect(conn.tracer.transport());
    self.conn = conn;
}

/// Send `server/discover` and return the raw result. The function checks that the result has
/// the shape of a `DiscoverResult`.
pub fn discover(self: *Upstream, arena: Allocator, opts: RequestOpts) RequestError!Value {
    const conn = self.conn orelse return error.NotConnected;
    try conn.tracer.register(opts.cancel, opts.client_id);
    defer conn.tracer.unregister(opts.cancel);
    const response = try conn.client.request(arena, .@"server/discover", .{ .object = .empty }, requestOptions(opts));
    return response.raw;
}

/// Send a request and return the raw result. The client does not answer an input request of
/// the upstream server. It returns the `InputRequiredResult` as the result, and the front end
/// asks the client. Thus each call is one round. `params` must be an object, and the client
/// adds its own `_meta`. For the next round, `params` has `inputResponses` and
/// `requestState`.
pub fn request(self: *Upstream, arena: Allocator, method: []const u8, params: Value, opts: RequestOpts) RequestError!Value {
    const conn = self.conn orelse return error.NotConnected;
    var options = requestOptions(opts);
    options.allow_input_required = true;
    try conn.tracer.register(opts.cancel, opts.client_id);
    defer conn.tracer.unregister(opts.cancel);
    const response = try conn.client.requestAs(arena, Value, method, params, options);
    return response.raw;
}

fn requestOptions(opts: RequestOpts) mcp.Client.RequestOptions {
    const callbacks = opts.callbacks orelse Callbacks{ .context = undefined };
    return .{
        .timeout = opts.timeout,
        // A request has only its own limit. The default maximum of zig-sdk is shorter than the
        // limit of `tools/call`.
        .max_total_timeout = opts.timeout,
        .cancel = opts.cancel,
        .on_progress = callbacks.progress,
        .on_log = callbacks.log,
        .userdata = if (opts.callbacks) |c| c.context else null,
        .cache_mode = .bypass,
        .diagnostics = opts.diagnostics,
        .log_level = opts.log_level,
        .meta = opts.meta,
    };
}

/// Open a `subscriptions/listen` stream with the filter `notifications`, and return the raw
/// result at the end of the stream. The upstream server ends a stream with a result, for
/// example at its stop. The function returns `error.Canceled` after the cancellation of the
/// stream.
///
/// The stream has no time limit, but its acknowledgment must arrive in
/// `limits.listen_ack_timeout` (stdio). When the stream stops because the connection failed,
/// the client opens it again at once, at most `limits.max_lost_stream_retries` times
/// (`Retry.force`). Thus `on_notification` can get more than one acknowledgment in one call.
/// The events can go to `on_notification` while the stream task waits. See `ListenOpts`.
pub fn listen(self: *Upstream, arena: Allocator, notifications: Value, opts: ListenOpts) RequestError!Value {
    const conn = self.conn orelse return error.NotConnected;
    var params: std.json.ObjectMap = .empty;
    try params.put(arena, "notifications", notifications);
    try conn.tracer.register(opts.cancel, null);
    defer conn.tracer.unregister(opts.cancel);
    const response = try conn.client.requestAs(arena, Value, "subscriptions/listen", .{ .object = params }, .{
        .cancel = opts.cancel,
        .retry = .force,
        .inline_notifications = true,
        .on_notification = opts.on_notification,
        .userdata = opts.context,
        .log_level = opts.log_level,
        .cache_mode = .bypass,
        .diagnostics = opts.diagnostics,
    });
    return response.raw;
}

/// The `on_notification` spawn option of the stdio client. It runs on the reader task. It
/// gives each valid log message to `on_log`, and drops each other notification.
fn onStdioNotification(userdata: ?*anyopaque, method: []const u8, params: ?Value) void {
    const self: *Upstream = @ptrCast(@alignCast(userdata.?));
    if (!std.mem.eql(u8, method, "notifications/message")) {
        log.debug("dropped the notification {s} of the upstream server: it belongs to no request", .{method});
        return;
    }
    const sink = self.on_log orelse return;
    var fallback = std.heap.stackFallback(4096, self.gpa);
    var scratch: std.heap.ArenaAllocator = .init(fallback.get());
    defer scratch.deinit();
    const p = mcp.json.parseValue(types.LoggingMessageNotificationParams, scratch.allocator(), params orelse .null) catch {
        log.debug("dropped a log message of the upstream server that is not valid", .{});
        return;
    };
    sink.call(sink.context, p);
}

/// The capabilities that the client declares to the upstream server, or null without a
/// connection.
pub fn clientCapabilities(self: *const Upstream) ?types.ClientCapabilities {
    const conn = self.conn orelse return null;
    return conn.client.options.capabilities;
}

/// The maximum number of rounds of one request: `mrtr_max_rounds_client` of the limits of the
/// client.
pub fn maxRounds(self: *const Upstream) u32 {
    const conn = self.conn orelse return (mcp.Limits{}).mrtr_max_rounds_client;
    return conn.client.options.limits.mrtr_max_rounds_client;
}

/// The limits of the schema validator of the client.
pub fn schemaLimits(self: *const Upstream) mcp.Limits.Schema {
    const conn = self.conn orelse return .{};
    return conn.client.options.limits.schema;
}

/// True when the child process stopped its stdout. Then each request fails. The other
/// transports never stop. Over HTTP, a failed request fails alone, and the next request
/// opens a new connection.
///
/// The client closes itself at the end of the stdout, before the requests in flight fail with
/// `error.Closed`. Thus `gone` gives true when such a request fails. The reader task of the
/// client reaps the child process after that. `reap` waits for the reap.
pub fn gone(self: *const Upstream) bool {
    const conn = self.conn orelse return false;
    return switch (conn.transport) {
        // Only `reap` and `close` close the client of a connection. `close` removes the
        // connection first.
        .stdio => |c| c.closed.load(.acquire),
        .http, .memory, .external => false,
    };
}

/// True when the upstream server is a remote server and not a local process. This applies to
/// `http`, and to a client transport of the caller with a network kind. The results for the
/// client then keep only the `data:` icons (`translate.IconRule`). The value does not need a
/// connection.
pub fn isRemote(self: *const Upstream) bool {
    return switch (self.config) {
        .stdio, .memory => false,
        .http => true,
        .transport => |t| switch (t.kind()) {
            .stdio, .memory, .unix_socket => false,
            .streamable_http, .grpc, .websocket => true,
        },
    };
}

/// The process id of the child process on POSIX, or null. The value stays the same until
/// `close` stopped the child process. Another thread can call this function.
pub fn pid(self: *const Upstream) ?i32 {
    const value = self.child_pid.load(.acquire);
    return if (value == 0) null else value;
}

/// Use this function after `gone` gave true. It waits until the client reaped the child
/// process, and returns the termination status of the child process. The function returns
/// null for a transport without a child process, or when the system gave no status. Call
/// `close` later to release the connection.
///
/// The reader task of the client reaps the child process after the end of its stdout. A child
/// process that does not exit in `shutdown_grace` gets a termination signal, and after one
/// more grace period a kill signal. On POSIX, the signals go to the process group of the
/// child process. On Windows, the function also stops each process that is left in the job
/// object of the child process. On POSIX, a process of the group continues to run when the
/// child process exits by itself. The client sends no signal after the reap, because the
/// system can give the process id to a new process.
pub fn reap(self: *Upstream) ?std.process.Child.Term {
    const conn = self.conn orelse return null;
    const c = switch (conn.transport) {
        .stdio => |c| c,
        .http, .memory, .external => return null,
    };
    // `close` waits for the reap of the reader task, and closes the job object on Windows.
    // `kill` sends the kill signal first. Then the status of a child process that is about to
    // exit can be the signal and not its exit code.
    c.close();
    return c.exitStatus();
}

/// Stop the upstream server and release the connection. On stdio, the client closes the
/// stdin of the child process and reaps it. A child process that does not exit in
/// `shutdown_grace` gets a termination signal, and after one more grace period a kill signal.
/// This also applies to a child process that closed its stdout and continues to run. The
/// function does nothing without a connection. Call it only when no request is in flight.
pub fn close(self: *Upstream) void {
    const conn = self.conn orelse return;
    self.conn = null;
    switch (conn.transport) {
        .stdio => |c| c.deinit(),
        .http, .memory, .external => {},
    }
    // The child process is stopped now. Until here, a watchdog can use its process id.
    self.child_pid.store(0, .release);
    conn.client.deinit();
    // No request is in flight, thus no task uses the HTTP client.
    switch (conn.transport) {
        .http => |c| c.deinit(),
        .stdio, .memory, .external => {},
    }
    conn.tracer.deinit();
    conn.arena.deinit();
    self.gpa.destroy(conn);
}

pub const LoadCaError = std.crypto.Certificate.Bundle.AddCertsFromFilePathError || error{
    /// The file has no certificate that the bundle can use: no PEM certificate, or only
    /// certificates that expired.
    NoCertificate,
    /// The bridge cannot read the system trust store.
    TrustStoreUnavailable,
};

/// The CA certificates of the system trust store and of the PEM file at `path`, for
/// `Config.Http.ca_bundle`. A relative path starts at the current directory. Release the
/// result with `deinit`. The file adds certificates, and the system trust store stays. Thus
/// the HTTP client also trusts each server that the system trusts.
pub fn loadCaBundle(io: Io, gpa: Allocator, path: []const u8) LoadCaError!std.crypto.Certificate.Bundle {
    const now = Io.Clock.real.now(io);
    // The certificates of the file alone, so that a file with no certificate gives an error.
    // The bundle drops a certificate whose subject it has, thus a count of the full bundle
    // cannot tell that.
    var file_only: std.crypto.Certificate.Bundle = .empty;
    defer file_only.deinit(gpa);
    try addCertsFromFile(&file_only, io, gpa, now, path);
    if (file_only.map.count() == 0) return error.NoCertificate;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(gpa);
    bundle.rescan(gpa, io, now) catch return error.TrustStoreUnavailable;
    try addCertsFromFile(&bundle, io, gpa, now, path);
    return bundle;
}

fn addCertsFromFile(bundle: *std.crypto.Certificate.Bundle, io: Io, gpa: Allocator, now: Io.Timestamp, path: []const u8) std.crypto.Certificate.Bundle.AddCertsFromFilePathError!void {
    if (std.fs.path.isAbsolute(path)) return bundle.addCertsFromFilePathAbsolute(gpa, io, now, path);
    return bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), path);
}

/// A client transport around the transport of the connection. It writes one debug log line
/// for each exchange. The line has the upstream id, the round and the id of the request of
/// the client. It also has the method, the outcome, the HTTP status and the time. Each round
/// of a request and each new attempt after a lost stream is one exchange. The line has no
/// content of a frame and no header.
const Tracer = struct {
    io: Io,
    gpa: Allocator,
    inner: Transport.ClientTransport,
    lock: Io.Mutex = .init,
    /// The requests in flight, by their cancel token.
    requests: std.ArrayList(Entry) = .empty,

    const Transport = mcp.transport.Transport;

    const Entry = struct {
        token: *const CancelToken,
        client_id: ?mcp.RequestId,
        rounds: u32 = 0,
    };

    fn deinit(self: *Tracer) void {
        self.requests.deinit(self.gpa);
    }

    fn transport(self: *Tracer) Transport.ClientTransport {
        return .{ .ptr = self, .vtable = switch (self.inner.kind()) {
            inline else => |kind| vtableFor(kind),
        } };
    }

    fn vtableFor(comptime kind: Transport.Kind) *const Transport.ClientTransport.VTable {
        return &struct {
            const vtable: Transport.ClientTransport.VTable = .{
                .kind = kind,
                .exchange = exchange,
                .notify = notify,
                .credential = credential,
            };
        }.vtable;
    }

    fn register(self: *Tracer, token: *const CancelToken, client_id: ?mcp.RequestId) Allocator.Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.requests.append(self.gpa, .{ .token = token, .client_id = client_id });
    }

    fn unregister(self: *Tracer, token: *const CancelToken) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.requests.items, 0..) |e, i| if (e.token == token) {
            _ = self.requests.swapRemove(i);
            return;
        };
    }

    /// The id of the request of the client and the number of this round, from 1.
    fn nextRound(self: *Tracer, token: *const CancelToken) struct { ?mcp.RequestId, u32 } {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.requests.items) |*e| if (e.token == token) {
            e.rounds += 1;
            return .{ e.client_id, e.rounds };
        };
        return .{ null, 0 };
    }

    fn exchange(ptr: *anyopaque, io: Io, ex: *Transport.Exchange) Transport.ExchangeError!void {
        const self: *Tracer = @ptrCast(@alignCast(ptr));
        const client_id, const round = self.nextRound(ex.cancel);
        const started = Io.Clock.Timestamp.now(io, .awake);
        const result = self.inner.exchange(io, ex);
        const ms = started.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
        const outcome: []const u8 = if (result) |_| "response" else |e| @errorName(e);
        const note: ClientNote = .{ .id = client_id };
        const status: StatusNote = .{ .status = ex.http_status };
        log.debug("upstream request {f} ({s}, round {d} of {f}): {s}{f} after {d} ms", .{ ex.id, ex.method, round, note, outcome, status, ms });
        return result;
    }

    /// The HTTP status of an exchange for the log line, or nothing without a status.
    const StatusNote = struct {
        status: u16,

        pub fn format(self: StatusNote, w: *Io.Writer) Io.Writer.Error!void {
            if (self.status != 0) try w.print(" (HTTP status {d})", .{self.status});
        }
    };

    fn notify(ptr: *anyopaque, io: Io, frame: []const u8) Transport.SendError!void {
        const self: *Tracer = @ptrCast(@alignCast(ptr));
        return self.inner.notify(io, frame);
    }

    fn credential(ptr: *anyopaque, arena: Allocator) Allocator.Error!?[]const u8 {
        const self: *Tracer = @ptrCast(@alignCast(ptr));
        return self.inner.credential(arena);
    }

    const ClientNote = struct {
        id: ?mcp.RequestId,

        pub fn format(self: ClientNote, w: *Io.Writer) Io.Writer.Error!void {
            if (self.id) |id| try w.print("client request {f}", .{id}) else try w.writeAll("no client request");
        }
    };
};

fn hasPid() bool {
    return builtin.os.tag != .windows and builtin.os.tag != .wasi;
}

/// A copy of `value` in `arena`, through its JSON form.
fn deepCopy(comptime T: type, arena: Allocator, value: T) Allocator.Error!T {
    const tree = try mcp.Client.toValue(arena, value);
    return mcp.json.parseValue(T, arena, tree) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // The text comes from a value of the same type.
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn testServer(gpa: Allocator, io: Io) !*mcp.Server {
    const server = try gpa.create(mcp.Server);
    errdefer gpa.destroy(server);
    server.* = try mcp.Server.init(gpa, io, .{ .info = .{ .name = "upstream-test", .version = "1.0.0" } });
    errdefer server.deinit();
    try server.addTool(.{ .name = "steps", .description = "Send progress, then a result" }, steps);
    try server.addTool(.{ .name = "big", .description = "Send a long text" }, big);
    return server;
}

fn destroyServer(server: *mcp.Server) void {
    const gpa = server.gpa;
    server.deinit();
    gpa.destroy(server);
}

const StepsArgs = struct { count: u32 };

fn steps(ctx: *mcp.RequestContext, args: StepsArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    var i: u32 = 0;
    while (i < args.count) : (i += 1) try ctx.progress(@floatFromInt(i + 1), @floatFromInt(args.count), null);
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{d} steps", .{args.count}) };
}

const BigArgs = struct { bytes: u32 };

/// A result with a text of `bytes` bytes and no progress, thus one JSON body over HTTP.
fn big(ctx: *mcp.RequestContext, args: BigArgs) anyerror!mcp.Outcome(mcp.CallToolResult) {
    const text = try ctx.arena.alloc(u8, args.bytes);
    @memset(text, 'x');
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{s}", .{text}) };
}

/// The Streamable HTTP server of zig-sdk on a loopback port, for the tests of the `http`
/// transport. With a token, the server refuses each request without that bearer token. The
/// fixture must stay at its address between `start` and `stop`.
const HttpFixture = struct {
    server: *mcp.Server,
    transport: mcp.transport.http.Server,
    resource: mcp.auth.ResourceServer,
    future: Io.Future(void),
    url_buf: [64]u8,
    url: []const u8,
    token: ?[]const u8,

    fn start(self: *HttpFixture, token: ?[]const u8) !void {
        const io = testing.io;
        const gpa = testing.allocator;
        self.token = token;
        self.server = try testServer(gpa, io);
        errdefer destroyServer(self.server);
        self.transport = .init(io, gpa, self.server, .{ .port = 0, .auth = if (token != null) &self.resource else null });
        errdefer self.transport.deinit();
        try self.transport.bind();
        self.url = try std.fmt.bufPrint(&self.url_buf, "http://127.0.0.1:{d}/mcp", .{self.transport.bound_port});
        self.resource = .{
            .resource = self.url,
            .resource_metadata_url = "http://127.0.0.1/.well-known/oauth-protected-resource/mcp",
            .authorization_servers = &.{"https://as.example"},
            .verifier = .{ .ptr = self, .verify = verify },
        };
        self.future = try io.concurrent(serve, .{&self.transport});
    }

    fn serve(t: *mcp.transport.http.Server) void {
        t.serve() catch {};
    }

    fn verify(ptr: *anyopaque, arena: Allocator, token: []const u8) mcp.auth.resource_server.VerifyError!mcp.auth.Principal {
        _ = arena;
        const self: *HttpFixture = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, token, self.token.?)) return error.InvalidToken;
        return .{ .subject = "test" };
    }

    fn stop(self: *HttpFixture) void {
        self.endAccept();
        self.transport.shutdown();
        self.future.await(testing.io);
        self.transport.deinit();
        destroyServer(self.server);
    }

    /// Ends the accept loop of the server before its `shutdown`, as `fixture.https.endAccept`
    /// does. The `shutdown` of zig-sdk cancels the accept loop. On Windows, the cancel of an
    /// accept that waits makes Zig std write a stack trace in a Debug build. Thus the function
    /// sets the stop flag and connects one time. The loop accepts the connection, sees the
    /// flag, closes the connection and ends. The function waits for that close for at most 2 s.
    fn endAccept(self: *HttpFixture) void {
        const io = testing.io;
        self.transport.closing.store(true, .release);
        const Result = union(enum) { closed: void, expired: void };
        var buffer: [2]Result = undefined;
        var select: Io.Select(Result) = .init(io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.closed, waitForClose, .{ io, self.transport.bound_port }) catch return;
        select.concurrent(.expired, sleepTwoSeconds, .{io}) catch {};
        _ = select.await() catch {};
    }

    fn sleepTwoSeconds(io: Io) void {
        io.sleep(.fromSeconds(2), .awake) catch {};
    }

    /// Connect to 127.0.0.1 at `port`, and read until the other side closes the connection.
    fn waitForClose(io: Io, port: u16) void {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        const stream = address.connect(io, .{ .mode = .stream }) catch return;
        defer stream.close(io);
        var buf: [64]u8 = undefined;
        var reader = stream.reader(io, &buf);
        while (true) reader.interface.fillMore() catch return;
    }
};

test "a request without a connection fails, and close without a connection does nothing" {
    const io = testing.io;
    const server = try testServer(testing.allocator, io);
    defer destroyServer(server);
    const upstream = try init(io, testing.allocator, .{ .memory = server });
    defer upstream.deinit();
    var token: CancelToken = .{};
    try testing.expectError(error.NotConnected, upstream.request(testing.allocator, "tools/list", .{ .object = .empty }, .{ .cancel = &token, .timeout = .fromSeconds(5) }));
    try testing.expect(!upstream.gone());
    try testing.expectEqual(@as(?i32, null), upstream.pid());
    upstream.close();
}

test "discover and a request through the memory transport" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try testServer(gpa, io);
    defer destroyServer(server);
    const upstream = try init(io, gpa, .{ .memory = server });
    defer upstream.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        // The upstream keeps its own copy of the client information.
        var name_buf = "Visual Studio Code".*;
        try upstream.connect(.{ .name = &name_buf, .version = "1.140.0" }, .{});
        @memset(&name_buf, 'x');
    }
    try testing.expectEqualStrings("Visual Studio Code", upstream.conn.?.client.options.info.name);

    var token: CancelToken = .{};
    const raw = try upstream.discover(arena, .{ .cancel = &token, .timeout = .fromSeconds(5) });
    try testing.expect(raw.object.get("capabilities").?.object.get("tools") != null);

    const Recorder = struct {
        values: [8]f64 = undefined,
        count: usize = 0,
        fn record(context: ?*anyopaque, params: types.ProgressNotificationParams) void {
            const r: *@This() = @ptrCast(@alignCast(context.?));
            if (r.count < r.values.len) r.values[r.count] = params.progress;
            r.count += 1;
        }
    };
    var recorder: Recorder = .{};
    const params = try mcp.json.parseTree(arena, "{\"name\":\"steps\",\"arguments\":{\"count\":3}}");
    const result = try upstream.request(arena, "tools/call", params, .{
        .cancel = &token,
        .timeout = .fromSeconds(5),
        .callbacks = .{ .context = &recorder, .progress = Recorder.record },
    });
    try testing.expectEqual(@as(usize, 3), recorder.count);
    try testing.expectEqual(@as(f64, 3), recorder.values[2]);
    try testing.expectEqualStrings("3 steps", result.object.get("content").?.array.items[0].object.get("text").?.string);

    // An unknown tool gives the JSON-RPC error of the upstream server.
    var diag: mcp.Client.Diagnostics = .{};
    const unknown = try mcp.json.parseTree(arena, "{\"name\":\"none\"}");
    try testing.expectError(error.Rpc, upstream.request(arena, "tools/call", unknown, .{ .cancel = &token, .timeout = .fromSeconds(5), .diagnostics = &diag }));
    try testing.expect(diag.rpc_error != null);
    // The tracer forgets each request at its end.
    try testing.expectEqual(@as(usize, 0), upstream.conn.?.tracer.requests.items.len);

    upstream.close();
    try testing.expect(upstream.conn == null);
    try testing.expectEqual(@as(?std.process.Child.Term, null), upstream.reap());
}

test "a command that does not exist gives error.SpawnFailed" {
    // The warning about the command is expected.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const io = testing.io;
    const argv = [_][]const u8{"mcp-bridge-test-command-that-does-not-exist"};
    const upstream = try init(io, testing.allocator, .{ .stdio = .{ .argv = &argv } });
    defer upstream.deinit();
    try testing.expectError(error.SpawnFailed, upstream.connect(.{ .name = "x", .version = "1" }, .{}));
    try testing.expect(upstream.conn == null);
    try testing.expect(!upstream.gone());
}

test "reap gives the exit code of a child process that exits by itself" {
    // The warning of zig-sdk about the exit is expected.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const io = testing.io;
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/c", "exit", "5" }
    else
        &.{ "/bin/sh", "-c", "exit 5" };
    const upstream = try init(io, testing.allocator, .{ .stdio = .{ .argv = argv } });
    defer upstream.deinit();
    upstream.connect(.{ .name = "x", .version = "1" }, .{}) catch return error.SkipZigTest;
    const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(10), .clock = .awake });
    while (!upstream.gone()) {
        if (Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw.nanoseconds <= 0) return error.TestUnexpectedResult;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    const expected: std.process.Child.Term = .{ .exited = 5 };
    try testing.expectEqual(@as(?std.process.Child.Term, expected), upstream.reap());
    // The status stays after the reap, and `close` releases the connection.
    try testing.expectEqual(@as(?std.process.Child.Term, expected), upstream.reap());
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var token: CancelToken = .{};
    try testing.expectError(error.Closed, upstream.request(arena_state.allocator(), "tools/list", .{ .object = .empty }, .{ .cancel = &token, .timeout = .fromSeconds(5) }));
    upstream.close();
    try testing.expect(!upstream.gone());
    try testing.expectEqual(@as(?std.process.Child.Term, null), upstream.reap());
}

test "the stdio callback gives only the valid log messages to on_log" {
    const io = testing.io;
    const argv = [_][]const u8{"unused"};
    const upstream = try init(io, testing.allocator, .{ .stdio = .{ .argv = &argv } });
    defer upstream.deinit();
    const Recorder = struct {
        levels: [4]types.LoggingLevel = undefined,
        count: usize = 0,
        fn record(context: *anyopaque, params: types.LoggingMessageNotificationParams) void {
            const r: *@This() = @ptrCast(@alignCast(context));
            if (r.count < r.levels.len) r.levels[r.count] = params.level;
            r.count += 1;
        }
    };
    var recorder: Recorder = .{};
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Without `on_log`, the callback drops the message.
    onStdioNotification(upstream, "notifications/message", try mcp.json.parseTree(arena, "{\"level\":\"info\",\"data\":1}"));
    upstream.on_log = .{ .context = &recorder, .call = Recorder.record };
    onStdioNotification(upstream, "notifications/message", try mcp.json.parseTree(arena, "{\"level\":\"error\",\"logger\":\"db\",\"data\":{\"x\":1}}"));
    // The cancellation of the upstream server at its stop, and other notifications that
    // belong to no request.
    onStdioNotification(upstream, "notifications/cancelled", try mcp.json.parseTree(arena, "{\"requestId\":2,\"reason\":\"server shutdown\"}"));
    onStdioNotification(upstream, "notifications/tools/list_changed", null);
    // A log message that is not valid.
    onStdioNotification(upstream, "notifications/message", try mcp.json.parseTree(arena, "{\"level\":\"loud\",\"data\":1}"));
    onStdioNotification(upstream, "notifications/message", null);
    try testing.expectEqual(@as(usize, 1), recorder.count);
    try testing.expectEqual(types.LoggingLevel.@"error", recorder.levels[0]);
}

/// The notifications of one listen stream of a test.
const ListenEvents = struct {
    io: Io,
    acknowledged: std.atomic.Value(bool) = .init(false),
    changes: std.atomic.Value(usize) = .init(0),

    fn on(context: ?*anyopaque, method: []const u8, params: ?Value) void {
        _ = params;
        const self: *ListenEvents = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, method, "notifications/subscriptions/acknowledged")) return self.acknowledged.store(true, .release);
        if (std.mem.eql(u8, method, "notifications/tools/list_changed")) _ = self.changes.fetchAdd(1, .acq_rel);
    }

    fn run(up: *Upstream, events: *ListenEvents, token: *CancelToken, result: *RequestError!void) Io.Cancelable!void {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const filter = mcp.json.parseTree(arena, "{\"toolsListChanged\":true}") catch unreachable;
        if (up.listen(arena, filter, .{ .cancel = token, .on_notification = on, .context = events })) |_| {
            result.* = {};
        } else |e| result.* = e;
    }

    /// Wait for at most 10 s until `flag` gives true.
    fn waitFor(self: *ListenEvents, comptime flag: fn (*ListenEvents) bool) !void {
        var i: usize = 0;
        while (!flag(self)) : (i += 1) {
            if (i > 10_000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn isAcknowledged(self: *ListenEvents) bool {
        return self.acknowledged.load(.acquire);
    }

    fn hasChange(self: *ListenEvents) bool {
        return self.changes.load(.acquire) > 0;
    }
};

/// Open a listen stream through `upstream`, publish a change of the tools on `server`, and
/// cancel the stream after the change arrived.
fn expectListen(upstream: *Upstream, server: *mcp.Server) !void {
    const io = testing.io;
    var events: ListenEvents = .{ .io = io };
    var token: CancelToken = .{};
    var result: RequestError!void = {};
    var group: Io.Group = .init;
    try group.concurrent(io, ListenEvents.run, .{ upstream, &events, &token, &result });
    errdefer group.cancel(io);
    try events.waitFor(ListenEvents.isAcknowledged);
    server.notifyToolsListChanged(io);
    try events.waitFor(ListenEvents.hasChange);
    token.cancel(io, "test");
    try group.await(io);
    try testing.expectError(error.Canceled, result);
    try testing.expectEqual(@as(usize, 1), events.changes.load(.acquire));
    // The tracer forgets the stream at its end.
    try testing.expectEqual(@as(usize, 0), upstream.conn.?.tracer.requests.items.len);
}

test "a listen stream through the memory transport gets the acknowledgment and the events" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try testServer(gpa, io);
    defer destroyServer(server);
    const upstream = try init(io, gpa, .{ .memory = server });
    defer upstream.deinit();
    try upstream.connect(.{ .name = "x", .version = "1" }, .{});
    try expectListen(upstream, server);
}

test "an HTTP upstream server: the headers, a call with progress, a listen stream and no loss" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The warnings of zig-sdk about the status 401 are expected.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    var f: HttpFixture = undefined;
    try f.start("marker-token-7f3a");
    defer f.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var token: CancelToken = .{};

    // Without the static header, the server refuses the request with 401, and the client
    // has no authorization. The request fails alone: the upstream server is not gone.
    {
        const upstream = try init(io, gpa, .{ .http = .{ .url = f.url } });
        defer upstream.deinit();
        try testing.expect(upstream.isRemote());
        try upstream.connect(.{ .name = "x", .version = "1" }, .{});
        var diag: mcp.Client.Diagnostics = .{};
        try testing.expectError(error.InvalidResponse, upstream.discover(arena, .{ .cancel = &token, .timeout = .fromSeconds(10), .diagnostics = &diag }));
        try testing.expectEqual(@as(?u16, 401), diag.http_status);
        try testing.expect(!upstream.gone());
        try testing.expectEqual(@as(?i32, null), upstream.pid());
        try testing.expectEqual(@as(?std.process.Child.Term, null), upstream.reap());
    }

    // A proxy of the environment never applies to a loopback host. The proxy port is closed,
    // thus a request through it would fail.
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HTTP_PROXY", "http://127.0.0.1:9");
    try env.put("ALL_PROXY", "http://127.0.0.1:9");
    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = "Bearer marker-token-7f3a" },
        .{ .name = "x-client", .value = "test" },
    };
    const upstream = try init(io, gpa, .{ .http = .{ .url = f.url, .headers = &headers, .proxy = .{ .environment = &env } } });
    defer upstream.deinit();
    try upstream.connect(.{ .name = "x", .version = "1" }, .{});
    var diag: mcp.Client.Diagnostics = .{};
    const raw = try upstream.discover(arena, .{ .cancel = &token, .timeout = .fromSeconds(10), .diagnostics = &diag });
    try testing.expect(raw.object.get("capabilities").?.object.get("tools") != null);
    try testing.expectEqual(@as(?u16, 200), diag.http_status);

    // The progress of a call comes as SSE events before the result.
    const Recorder = struct {
        count: std.atomic.Value(usize) = .init(0),
        fn record(context: ?*anyopaque, params: types.ProgressNotificationParams) void {
            _ = params;
            const r: *@This() = @ptrCast(@alignCast(context.?));
            _ = r.count.fetchAdd(1, .acq_rel);
        }
    };
    var recorder: Recorder = .{};
    const call = try upstream.request(arena, "tools/call", try mcp.json.parseTree(arena, "{\"name\":\"steps\",\"arguments\":{\"count\":3}}"), .{
        .cancel = &token,
        .timeout = .fromSeconds(10),
        .callbacks = .{ .context = &recorder, .progress = Recorder.record },
    });
    try testing.expectEqual(@as(usize, 3), recorder.count.load(.acquire));
    try testing.expectEqualStrings("3 steps", call.object.get("content").?.array.items[0].object.get("text").?.string);

    try expectListen(upstream, f.server);
    try testing.expect(!upstream.gone());
}

test "an HTTP upstream server: a response over max_response_bytes fails once, and the next request works" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The warning of zig-sdk about the size is expected.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    var f: HttpFixture = undefined;
    try f.start(null);
    defer f.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var token: CancelToken = .{};

    const upstream = try init(io, gpa, .{ .http = .{ .url = f.url, .max_response_bytes = 4096 } });
    defer upstream.deinit();
    try upstream.connect(.{ .name = "x", .version = "1" }, .{});
    _ = try upstream.discover(arena, .{ .cancel = &token, .timeout = .fromSeconds(10) });
    const long = try mcp.json.parseTree(arena, "{\"name\":\"big\",\"arguments\":{\"bytes\":8192}}");
    try testing.expectError(error.InvalidResponse, upstream.request(arena, "tools/call", long, .{ .cancel = &token, .timeout = .fromSeconds(10) }));
    try testing.expect(!upstream.gone());
    const short = try mcp.json.parseTree(arena, "{\"name\":\"big\",\"arguments\":{\"bytes\":100}}");
    const result = try upstream.request(arena, "tools/call", short, .{ .cancel = &token, .timeout = .fromSeconds(10) });
    try testing.expectEqual(@as(usize, 100), result.object.get("content").?.array.items[0].object.get("text").?.string.len);
}

test "an HTTP client that cannot be made gives error.ConnectFailed" {
    const io = testing.io;
    const gpa = testing.allocator;
    // The warnings about the causes are expected.
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    // A URL without a host.
    {
        const upstream = try init(io, gpa, .{ .http = .{ .url = "https:///mcp" } });
        defer upstream.deinit();
        try testing.expectError(error.ConnectFailed, upstream.connect(.{ .name = "x", .version = "1" }, .{}));
        try testing.expect(upstream.conn == null);
    }
    // A static authorization header and the authorization of the bridge.
    {
        const NoToken = struct {
            fn token(ptr: *anyopaque, arena: Allocator) ?[]const u8 {
                _ = ptr;
                _ = arena;
                return null;
            }
            fn handleChallenge(ptr: *anyopaque, arena: Allocator, url: []const u8, status: u16, www: ?[]const u8, attempt: u8) anyerror!void {
                _ = .{ ptr, arena, url, status, www, attempt };
                return error.AuthorizationFailed;
            }
            const vtable: mcp.auth.Provider.VTable = .{ .token = token, .handle_challenge = handleChallenge };
        };
        var dummy: u8 = 0;
        const headers = [_]std.http.Header{.{ .name = "Authorization", .value = "Bearer t" }};
        const upstream = try init(io, gpa, .{ .http = .{
            .url = "http://127.0.0.1:9/mcp",
            .headers = &headers,
            .auth = .{ .provider = .{ .ptr = &dummy, .vtable = &NoToken.vtable } },
        } });
        defer upstream.deinit();
        try testing.expectError(error.ConnectFailed, upstream.connect(.{ .name = "x", .version = "1" }, .{}));
    }
    // A proxy variable without an http proxy URL.
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "socks5://proxy.example:1080");
    const upstream = try init(io, gpa, .{ .http = .{ .url = "https://mcp.example.com/mcp", .proxy = .{ .environment = &env } } });
    defer upstream.deinit();
    try testing.expectError(error.ConnectFailed, upstream.connect(.{ .name = "x", .version = "1" }, .{}));
}

test "only an HTTP upstream server and a network transport are remote" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try testServer(gpa, io);
    defer destroyServer(server);
    const argv = [_][]const u8{"unused"};
    const cases = [_]struct { config: Config, remote: bool }{
        .{ .config = .{ .stdio = .{ .argv = &argv } }, .remote = false },
        .{ .config = .{ .memory = server }, .remote = false },
        .{ .config = .{ .http = .{ .url = "https://mcp.example.com/mcp" } }, .remote = true },
    };
    for (cases) |case| {
        const upstream = try init(io, gpa, case.config);
        defer upstream.deinit();
        try testing.expectEqual(case.remote, upstream.isRemote());
    }
    const Kinds = struct {
        fn transport(comptime kind: mcp.transport.Transport.Kind) mcp.transport.Transport.ClientTransport {
            const vtable = &struct {
                const v: mcp.transport.Transport.ClientTransport.VTable = .{ .kind = kind, .exchange = undefined, .notify = undefined };
            }.v;
            return .{ .ptr = undefined, .vtable = vtable };
        }
    };
    inline for (.{
        .{ mcp.transport.Transport.Kind.stdio, false },
        .{ mcp.transport.Transport.Kind.memory, false },
        .{ mcp.transport.Transport.Kind.unix_socket, false },
        .{ mcp.transport.Transport.Kind.streamable_http, true },
        .{ mcp.transport.Transport.Kind.grpc, true },
        .{ mcp.transport.Transport.Kind.websocket, true },
    }) |case| {
        const upstream = try init(io, gpa, .{ .transport = Kinds.transport(case[0]) });
        defer upstream.deinit();
        try testing.expectEqual(case[1], upstream.isRemote());
    }
}

test "loadCaBundle adds the certificates of a PEM file to the system trust store" {
    const io = testing.io;
    const gpa = testing.allocator;
    const Bundle = std.crypto.Certificate.Bundle;
    var system: Bundle = .empty;
    defer system.deinit(gpa);
    system.rescan(gpa, io, Io.Clock.real.now(io)) catch return error.SkipZigTest;
    if (system.map.count() == 0) return error.SkipZigTest;

    // One certificate of the system trust store as a PEM file.
    var it = system.map.valueIterator();
    const start = it.next().?.*;
    const element = try std.crypto.Certificate.der.Element.parse(system.bytes.items, start);
    const der = system.bytes.items[start..element.slice.end];
    const encoder = std.base64.standard.Encoder;
    const pem = try gpa.alloc(u8, encoder.calcSize(der.len));
    defer gpa.free(pem);
    _ = encoder.encode(pem, der);
    const text = try std.mem.concat(gpa, u8, &.{ "-----BEGIN CERTIFICATE-----\n", pem, "\n-----END CERTIFICATE-----\n" });
    defer gpa.free(text);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ca.pem", .data = text });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.pem", .data = "no certificate here\n" });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/ca.pem", .{tmp.sub_path});
    var bundle = try loadCaBundle(io, gpa, path);
    defer bundle.deinit(gpa);
    // The file adds no subject that the system does not have, and the system store stays.
    try testing.expectEqual(system.map.count(), bundle.map.count());

    const empty = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/empty.pem", .{tmp.sub_path});
    try testing.expectError(error.NoCertificate, loadCaBundle(io, gpa, empty));
    const missing = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/missing.pem", .{tmp.sub_path});
    try testing.expectError(error.FileNotFound, loadCaBundle(io, gpa, missing));
}

test "loadCaBundle adds the private CAs of the test certificates to the system trust store" {
    const io = testing.io;
    const gpa = testing.allocator;
    const Bundle = std.crypto.Certificate.Bundle;
    var system: Bundle = .empty;
    defer system.deinit(gpa);
    system.rescan(gpa, io, Io.Clock.real.now(io)) catch return error.SkipZigTest;
    // The two CAs of the HTTPS tests. The system does not have them, thus each file adds one
    // subject. The tests run in the root of the repository.
    for ([_][]const u8{ "test/fixtures/tls/ca.crt", "test/fixtures/tls/untrusted-ca.crt" }) |path| {
        var bundle = try loadCaBundle(io, gpa, path);
        defer bundle.deinit(gpa);
        try testing.expectEqual(system.map.count() + 1, bundle.map.count());
    }
}

test "the tracer counts the rounds of each request" {
    const io = testing.io;
    var tracer: Tracer = .{ .io = io, .gpa = testing.allocator, .inner = undefined };
    defer tracer.deinit();
    var a: CancelToken = .{};
    var b: CancelToken = .{};
    try tracer.register(&a, .{ .integer = 7 });
    try tracer.register(&b, null);
    _ = tracer.nextRound(&a);
    const id, const round = tracer.nextRound(&a);
    try testing.expectEqual(@as(i64, 7), id.?.integer);
    try testing.expectEqual(@as(u32, 2), round);
    try testing.expectEqual(@as(u32, 1), tracer.nextRound(&b)[1]);
    tracer.unregister(&a);
    try testing.expectEqual(@as(u32, 0), tracer.nextRound(&a)[1]);
    tracer.unregister(&b);
    try testing.expectEqual(@as(usize, 0), tracer.requests.items.len);
}
