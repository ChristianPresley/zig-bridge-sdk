//! The modern side of a bridge: an `mcp.Client` of revision 2026-07-28 and its transport. The
//! front end makes one `Upstream` for each connection of the client. `connect` starts the
//! upstream server, and `close` stops it.
//!
//! This version has three transports:
//!
//! - `stdio`: the bridge starts the upstream command as a child process. The child process
//!   writes its stderr lines to the stderr of the bridge. The client never starts the child
//!   process again: when it stops, `gone` gives true.
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
};

/// The default of `Config.Stdio.max_line_bytes`: 64 MiB.
pub const default_max_line_bytes: usize = 64 << 20;

const Connection = struct {
    /// Holds the client information and the capabilities of the client.
    arena: std.heap.ArenaAllocator,
    client: mcp.Client,
    transport: union(enum) {
        stdio: *mcp.transport.stdio.Client,
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
        .memory, .transport => {},
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
        .memory => |server| conn.transport = .{ .memory = .init(self.io, self.gpa, server) },
        .transport => |t| conn.transport = .{ .external = t },
    }
    conn.tracer = .{ .io = self.io, .gpa = self.gpa, .inner = switch (conn.transport) {
        .stdio => |c| c.transport(),
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
/// transports never stop.
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
        .memory, .external => false,
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
        .memory, .external => return null,
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
        .memory, .external => {},
    }
    // The child process is stopped now. Until here, a watchdog can use its process id.
    self.child_pid.store(0, .release);
    conn.client.deinit();
    conn.tracer.deinit();
    conn.arena.deinit();
    self.gpa.destroy(conn);
}

/// A client transport around the transport of the connection. It writes one debug log line
/// for each exchange. The line has the upstream id, the round and the id of the request of
/// the client. It also has the method, the outcome and the time. Each round of a request and
/// each new attempt after a lost stream is one exchange. The line has no content of a frame.
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
        log.debug("upstream request {f} ({s}, round {d} of {f}): {s} after {d} ms", .{ ex.id, ex.method, round, note, outcome, ms });
        return result;
    }

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

test "a listen stream through the memory transport gets the acknowledgment and the events" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try testServer(gpa, io);
    defer destroyServer(server);
    const upstream = try init(io, gpa, .{ .memory = server });
    defer upstream.deinit();
    try upstream.connect(.{ .name = "x", .version = "1" }, .{});
    const Events = struct {
        io: Io,
        lock: Io.Mutex = .init,
        acknowledged: std.atomic.Value(bool) = .init(false),
        changes: usize = 0,
        fn on(context: ?*anyopaque, method: []const u8, params: ?Value) void {
            _ = params;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, method, "notifications/subscriptions/acknowledged")) return self.acknowledged.store(true, .release);
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (std.mem.eql(u8, method, "notifications/tools/list_changed")) self.changes += 1;
        }
        fn run(up: *Upstream, events: *@This(), token: *CancelToken, result: *RequestError!void) Io.Cancelable!void {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const filter = mcp.json.parseTree(arena, "{\"toolsListChanged\":true}") catch unreachable;
            if (up.listen(arena, filter, .{ .cancel = token, .on_notification = on, .context = events })) |_| {
                result.* = {};
            } else |e| result.* = e;
        }
    };
    var events: Events = .{ .io = io };
    var token: CancelToken = .{};
    var result: RequestError!void = {};
    var group: Io.Group = .init;
    try group.concurrent(io, Events.run, .{ upstream, &events, &token, &result });
    var i: usize = 0;
    while (!events.acknowledged.load(.acquire)) : (i += 1) {
        if (i > 5000) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    server.notifyToolsListChanged(io);
    token.cancel(io, "test");
    try group.await(io);
    try testing.expectError(error.Canceled, result);
    try testing.expectEqual(@as(usize, 1), events.changes);
    // The tracer forgets the stream at its end.
    try testing.expectEqual(@as(usize, 0), upstream.conn.?.tracer.requests.items.len);
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
