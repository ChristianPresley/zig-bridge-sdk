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
//! The upstream server sends no notification to the client in this version. The progress of a
//! request goes to `RequestOpts.progress`. The client drops each other notification.
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
    /// Receives each progress notification of the request. Null drops them.
    progress: ?ProgressSink = null,
    /// Receives the JSON-RPC error of the upstream server after `error.Rpc`.
    diagnostics: ?*mcp.Client.Diagnostics = null,
    /// The id of the request of the client, for the debug log lines. The value must stay
    /// valid during the request.
    client_id: ?mcp.RequestId = null,
};

/// Receives the progress notifications of one request. The client calls `call` in the task of
/// the request, before the response. In each round of the request, the upstream server sends
/// the progress with the id of that round as its token. Thus `call` gets the progress of all
/// rounds of the request. The params are valid only during the call.
pub const ProgressSink = struct {
    context: *anyopaque,
    call: *const fn (context: ?*anyopaque, params: types.ProgressNotificationParams) void,
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
            // A notification that belongs to no request goes to `on_notification`. It is null,
            // thus the client drops each such notification, also a `notifications/cancelled`
            // of the upstream server.
            const child = mcp.transport.stdio.Client.spawn(self.io, self.gpa, .{
                .argv = s.argv,
                .cwd = if (s.cwd) |p| .{ .path = p } else .inherit,
                .limits = limits,
                .max_restarts = 0,
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
    try conn.tracer.register(opts);
    defer conn.tracer.unregister(opts.cancel);
    const response = try conn.client.request(arena, .@"server/discover", .{ .object = .empty }, requestOptions(opts));
    return response.raw;
}

/// Send a request and return the raw result. The client does not answer an input request of
/// the upstream server. It returns the `InputRequiredResult` as the result. `params` must be
/// an object, and the client adds its own `_meta`.
pub fn request(self: *Upstream, arena: Allocator, method: []const u8, params: Value, opts: RequestOpts) RequestError!Value {
    const conn = self.conn orelse return error.NotConnected;
    var options = requestOptions(opts);
    options.allow_input_required = true;
    try conn.tracer.register(opts);
    defer conn.tracer.unregister(opts.cancel);
    const response = try conn.client.requestAs(arena, Value, method, params, options);
    return response.raw;
}

fn requestOptions(opts: RequestOpts) mcp.Client.RequestOptions {
    return .{
        .timeout = opts.timeout,
        // A request has only its own limit. The default maximum of zig-sdk is shorter than the
        // limit of `tools/call`.
        .max_total_timeout = opts.timeout,
        .cancel = opts.cancel,
        .on_progress = if (opts.progress) |p| p.call else null,
        .userdata = if (opts.progress) |p| p.context else null,
        .cache_mode = .bypass,
        .diagnostics = opts.diagnostics,
    };
}

/// True when the child process stopped its stdout. Then each request fails. The other
/// transports never stop.
pub fn gone(self: *const Upstream) bool {
    const conn = self.conn orelse return false;
    return switch (conn.transport) {
        .stdio => |c| c.reader_done.load(.acquire),
        .memory, .external => false,
    };
}

/// The process id of the child process on POSIX, or null. The value stays the same until
/// `close` stopped the child process. Another thread can call this function.
pub fn pid(self: *const Upstream) ?i32 {
    const value = self.child_pid.load(.acquire);
    return if (value == 0) null else value;
}

/// Use this function after `gone` gave true. It stops each process that is left in the
/// process tree of the upstream server. It returns the termination status of the child
/// process. The requests in flight then fail at once. Call `close` later to release the
/// connection. The function returns null for a transport without a child process, or when it
/// cannot get the status.
pub fn reap(self: *Upstream) ?std.process.Child.Term {
    const conn = self.conn orelse return null;
    const c = switch (conn.transport) {
        .stdio => |c| c,
        .memory, .external => return null,
    };
    var term: ?std.process.Child.Term = null;
    if (c.child.id) |id| {
        // A signal to a process that stopped does not change its status. Thus the status
        // tells why the process stopped, also after this signal.
        switch (builtin.os.tag) {
            .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
            .wasi => {},
            else => std.posix.kill(if (c.options.process_group) -id else id, .KILL) catch {},
        }
        if (builtin.os.tag != .wasi) term = c.child.wait(self.io) catch null;
    }
    // The child process is gone. `kill` waits for the reader task and, on Windows, closes the
    // job object, which stops the other processes of the tree.
    c.kill();
    return term;
}

/// Stop the upstream server and release the connection. On stdio, the client closes the
/// stdin of the child process and waits at most two times `shutdown_grace` before it stops
/// the process tree. When the child process closed its stdout before, the function stops the
/// process tree at once, because the child process can continue to run. The function does
/// nothing without a connection. Call it only when no request is in flight.
pub fn close(self: *Upstream) void {
    const conn = self.conn orelse return;
    self.conn = null;
    switch (conn.transport) {
        .stdio => |c| {
            // After the end of the stream, the client waits for the reader task only. Then
            // `deinit` waits for the exit of the child process without a time limit. A child
            // process that closed its stdout can continue to run, thus stop the tree first.
            // `kill` waits for the reader task and for the exit of the child process.
            if (c.reader_done.load(.acquire) and c.child.id != null) c.kill();
            // After the end of the stream or after `reap`, the client is closed, and its
            // `close` does not close the pipe of stdin. No request is in flight here.
            if (c.closed.load(.acquire)) if (c.child.stdin) |stdin| {
                stdin.close(self.io);
                c.child.stdin = null;
            };
            c.deinit();
        },
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

    fn register(self: *Tracer, opts: RequestOpts) Allocator.Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.requests.append(self.gpa, .{ .token = opts.cancel, .client_id = opts.client_id });
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
        .progress = .{ .context = &recorder, .call = Recorder.record },
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

test "the tracer counts the rounds of each request" {
    const io = testing.io;
    var tracer: Tracer = .{ .io = io, .gpa = testing.allocator, .inner = undefined };
    defer tracer.deinit();
    var a: CancelToken = .{};
    var b: CancelToken = .{};
    try tracer.register(.{ .cancel = &a, .timeout = .fromSeconds(1), .client_id = .{ .integer = 7 } });
    try tracer.register(.{ .cancel = &b, .timeout = .fromSeconds(1) });
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
