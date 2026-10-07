//! The legacy front end of a bridge: a stdio server of revision 2025-11-25 for one client
//! connection. It reads one JSON-RPC message from each line, answers the lifecycle requests
//! itself and sends the other requests to the `Upstream` of revision 2026-07-28.
//!
//! The structure is that of `mcp.transport.stdio.Server`, with these changes:
//!
//! - A lifecycle state: `awaiting_initialize`, `initializing`, `ready` and `closing`. Only the
//!   first `initialize` starts the upstream server.
//! - The reader never waits for a free slot. At the limit of requests in flight, it answers
//!   the new request with -32603 at once. Thus it always reads the cancellations.
//! - An own line reader keeps the start and the end of a line that is too long. The front end
//!   then finds the id of the request in that text and answers with that id.
//! - A watcher task examines the upstream server. When the upstream server stops, the front
//!   end answers each request in flight with -32603 and stops.
//! - At the end of the input, the front end cancels the requests in flight and waits for them
//!   for at most `shutdown_grace`.
//!
//! A canceled request gets no response. Each task writes its frames under one lock, thus the
//! frames do not mix.
const Frontend = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const types = mcp.types;
const RequestId = mcp.RequestId;
const Message = mcp.jsonrpc.Message;
const CancelToken = mcp.transport.CancelToken;
const bridge = @import("../bridge.zig");
const legacy = @import("legacy.zig");
const translate = @import("translate.zig");
const Upstream = @import("Upstream.zig");
const Profile = bridge.Profile;

const log = std.log.scoped(.bridge);

io: Io,
gpa: Allocator,
upstream: *Upstream,
profile: *const Profile,
sink: Sink,
options: Options,
lifecycle: std.atomic.Value(State) = .init(.awaiting_initialize),
/// The level of `logging/setLevel`, plus one. Zero when the client sent no level.
client_level: std.atomic.Value(u8) = .init(0),
out_lock: Io.Mutex = .init,
in_flight: std.ArrayList(*Slot) = .empty,
in_flight_lock: Io.Mutex = .init,
group: Io.Group = .init,
/// False after `stopAdmission`. Guarded by `in_flight_lock`.
admitting: bool = true,
/// True when no more frames go out.
closed: std.atomic.Value(bool) = .init(false),
/// True when the reader and the watcher stop.
stopping: std.atomic.Value(bool) = .init(false),
/// Wakes the watcher when `stopping` becomes true.
stop_event: Io.Event = .unset,
/// True after the upstream server stopped while the input was open.
upstream_lost: std.atomic.Value(bool) = .init(false),
/// True after `shutdown`. Only the task of `run` and `deinit` read and write it.
shut_down: bool = false,

/// The lifecycle of the connection.
pub const State = enum(u8) {
    /// The client did not send `initialize`, or the last `initialize` failed.
    awaiting_initialize,
    /// The bridge starts the upstream server and waits for `server/discover`.
    initializing,
    /// The bridge sends the requests to the upstream server.
    ready,
    /// The input ended, or the upstream server stopped.
    closing,
};

/// The result of `run`.
pub const RunResult = enum {
    /// The input ended. The executable exits with code 0.
    eof,
    /// The upstream server stopped while the input was open. The executable exits with code 1.
    upstream_exited,
};

/// Writes one frame: a serialized JSON-RPC message without a newline.
pub const Sink = struct {
    ptr: *anyopaque,
    write: *const fn (ptr: *anyopaque, frame: []const u8) WriteError!void,

    pub const WriteError = error{ WriteFailed, OutOfMemory };

    /// A sink that writes each frame as one line to `w` and flushes it.
    pub fn writer(w: *Io.Writer) Sink {
        return .{ .ptr = w, .write = writeLine };
    }

    fn writeLine(ptr: *anyopaque, frame: []const u8) WriteError!void {
        const w: *Io.Writer = @ptrCast(@alignCast(ptr));
        mcp.util.line_framer.writeFrame(w, frame) catch return error.WriteFailed;
    }
};

/// Functions of the caller for two events. The executable uses them. A library leaves them
/// null.
pub const Hooks = struct {
    context: ?*anyopaque = null,
    /// At the end of the input, before the bounded wait for the requests in flight. The
    /// executable starts its watchdog here.
    on_eof: ?*const fn (context: ?*anyopaque, upstream: *Upstream) void = null,
    /// After the upstream server stopped and the front end answered the requests in flight.
    /// The reader can wait for input that never comes, thus the executable exits here with
    /// code 1. Without this function, `run` returns after the next line or the end of the
    /// input.
    on_upstream_exit: ?*const fn (context: ?*anyopaque) void = null,
};

/// The time limits of the forwarded requests. Each limit is finite.
pub const Timeouts = struct {
    /// The list requests and `completion/complete`.
    list: Io.Duration = .fromSeconds(120),
    /// `prompts/get` and `resources/read`.
    read: Io.Duration = .fromSeconds(120),
    /// `tools/call`. The client can cancel a call earlier.
    call: Io.Duration = .fromSeconds(3600),

    /// The limit of `method`.
    pub fn forMethod(self: Timeouts, method: []const u8) Io.Duration {
        if (std.mem.eql(u8, method, "tools/call")) return self.call;
        if (std.mem.eql(u8, method, "prompts/get") or std.mem.eql(u8, method, "resources/read")) return self.read;
        return self.list;
    }
};

/// The default time limit of `server/discover`, in seconds. The first start of a command such
/// as `npx -y` can take a long time.
pub const default_discover_timeout_s: u32 = 60;

pub const Options = struct {
    /// The maximum length of one line from the client. The default is the same as on the
    /// upstream side.
    max_line_bytes: usize = Upstream.default_max_line_bytes,
    /// The maximum nesting depth of one message from the client.
    json_max_depth: u16 = default_limits.json_max_depth,
    /// The maximum number of requests in flight. The front end answers a request above the
    /// limit with -32603.
    max_in_flight_requests: u32 = default_limits.max_in_flight_requests,
    /// The time that the requests in flight get at the end of the input.
    shutdown_grace: Io.Duration = default_limits.shutdown_grace,
    /// The time limit of `server/discover`.
    discover_timeout: Io.Duration = .fromSeconds(default_discover_timeout_s),
    timeouts: Timeouts = .{},
    /// The `serverInfo.name` when the upstream server sends none. Empty uses the name of the
    /// profile.
    fallback_name: []const u8 = "",
    /// The capabilities of the client that go to the upstream server.
    capability_mask: translate.CapabilityMask = .{},
    /// The capabilities of the upstream server that go into the `initialize` result.
    reply_mask: translate.ReplyMask = .{},
    /// How often the watcher examines the upstream server.
    watch_interval: Io.Duration = .fromMilliseconds(200),
    hooks: Hooks = .{},
};

const default_limits: mcp.Limits = .{};

/// The cancellation reason that goes to the upstream server when the client cancels a request.
const client_cancel_reason = "the client canceled the request";
/// The cancellation reason at the end of the input.
const eof_cancel_reason = "the client closed the connection";

/// The first log line about a request in flight comes after this time, and the next lines
/// come after each `report_interval_s`.
const first_report_s = 10;
const report_interval_s = 30;

/// One request in its own task. The slot owns its arena, which holds the line and the parsed
/// message.
const Slot = struct {
    owner: *Frontend,
    arena: std.heap.ArenaAllocator,
    token: CancelToken = .{},
    id: RequestId = undefined,
    method: []const u8 = "",
    params: ?Value = null,
    kind: legacy.MethodKind = .unknown,
    /// The progress token of the client, or null.
    progress_token: ?Value = null,
    /// True after the response. Guarded by `out_lock`.
    answered: bool = false,
    started: Io.Clock.Timestamp = undefined,
    /// The time of the next log line about this request, in seconds after `started`. Only the
    /// watcher reads and writes it.
    next_report_s: i64 = first_report_s,
};

pub fn init(io: Io, gpa: Allocator, upstream: *Upstream, profile: *const Profile, sink: Sink, options: Options) Frontend {
    return .{ .io = io, .gpa = gpa, .upstream = upstream, .profile = profile, .sink = sink, .options = options };
}

/// Stop the requests in flight, and release the memory of the front end. The function does
/// not release the upstream.
pub fn deinit(self: *Frontend) void {
    self.shutdown();
    self.in_flight.deinit(self.gpa);
}

/// The lifecycle state.
pub fn state(self: *const Frontend) State {
    return self.lifecycle.load(.acquire);
}

/// The level of the last `logging/setLevel` of the client, or null.
pub fn clientLogLevel(self: *const Frontend) ?types.LoggingLevel {
    const v = self.client_level.load(.acquire);
    return if (v == 0) null else @enumFromInt(v - 1);
}

/// The number of requests in flight.
pub fn inFlightCount(self: *Frontend) usize {
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    return self.in_flight.items.len;
}

// ---------------------------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------------------------

/// Read lines from `in` until the end of the input, process each message, then stop with
/// `shutdown`. A watcher task examines the upstream server while the function runs.
pub fn run(self: *Frontend, in: *Io.Reader) !RunResult {
    errdefer self.shutdown();
    try self.group.concurrent(self.io, watch, .{self});
    var reader: LineReader = .{ .reader = in, .max_line_bytes = self.options.max_line_bytes };
    while (!self.stopping.load(.acquire)) {
        const slot = try self.newSlot();
        const arena = slot.arena.allocator();
        const next = reader.next(arena) catch |e| {
            self.destroySlot(slot);
            switch (e) {
                error.ReadFailed => break,
                error.OutOfMemory => return error.OutOfMemory,
            }
        };
        switch (next) {
            .eof => {
                self.destroySlot(slot);
                break;
            },
            .line => |line| try self.dispatch(slot, line),
            .too_long => |long| {
                defer self.destroySlot(slot);
                self.tooLong(long);
            },
            .invalid_utf8 => |line| {
                defer self.destroySlot(slot);
                self.badLine(line, .parse_error);
            },
        }
    }
    self.shutdown();
    return if (self.upstream_lost.load(.acquire)) .upstream_exited else .eof;
}

/// Process one complete message of the client, without the line reader. The function copies
/// `text`. A text longer than `max_line_bytes` gets the error of a line that is too long.
pub fn receive(self: *Frontend, text: []const u8) !void {
    const slot = try self.newSlot();
    const arena = slot.arena.allocator();
    if (text.len > self.options.max_line_bytes) {
        defer self.destroySlot(slot);
        self.tooLong(.of(text));
        return;
    }
    if (!std.unicode.utf8ValidateSlice(text)) {
        defer self.destroySlot(slot);
        self.badLine(text, .parse_error);
        return;
    }
    const line = arena.dupe(u8, text) catch {
        self.destroySlot(slot);
        return error.OutOfMemory;
    };
    try self.dispatch(slot, line);
}

fn newSlot(self: *Frontend) Allocator.Error!*Slot {
    const slot = try self.gpa.create(Slot);
    slot.* = .{ .owner = self, .arena = .init(self.gpa) };
    return slot;
}

fn destroySlot(self: *Frontend, slot: *Slot) void {
    slot.arena.deinit();
    self.gpa.destroy(slot);
}

/// Parse one line in the arena of `slot` and process it. The function owns `slot`.
fn dispatch(self: *Frontend, slot: *Slot, line: []const u8) !void {
    const arena = slot.arena.allocator();
    const depth = @min(self.options.json_max_depth, mcp.json.max_message_depth);
    const msg = Message.parseMaxDepth(arena, line, depth) catch |e| {
        defer self.destroySlot(slot);
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                const too_deep = if (mcp.json.checkDepth(line, depth)) |_| false else |_| true;
                self.badLine(line, if (too_deep) .too_deep else .parse_error);
            },
            error.Invalid => self.badLine(line, .invalid_request_shape),
            error.InvalidId => self.writeError(null, translate.errorFor(.invalid_request_shape, null)),
        }
        return;
    };
    switch (msg) {
        .request => |req| self.handleRequest(slot, req),
        .notification => |n| {
            defer self.destroySlot(slot);
            self.handleNotification(arena, n);
        },
        .response, .error_response => {
            defer self.destroySlot(slot);
            // This version sends no request to the client, thus no response belongs to a
            // request of the bridge.
            log.debug("dropped a response of the client", .{});
        },
    }
}

/// Answer a line that is not a valid message. The function finds the id of the request in
/// `text`.
fn badLine(self: *Frontend, text: []const u8, cause: translate.Cause) void {
    var buf: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    self.answerBadLine(recoverId(fba.allocator(), text), cause);
}

/// Answer a line that is longer than `max_line_bytes`. The function finds the id of the
/// request in the start or in the end of the line.
fn tooLong(self: *Frontend, long: LongLine) void {
    var buf: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    self.answerBadLine(recoverLongLineId(fba.allocator(), long), .line_too_long);
}

/// Answer a line that is not valid with the id `id`, or with the id null. A response of the
/// client to a request of the bridge gets no answer.
fn answerBadLine(self: *Frontend, id: ?RequestId, cause: translate.Cause) void {
    if (id) |i| if (i == .string and std.mem.startsWith(u8, i.string, self.profile.request_id_prefix)) {
        log.debug("dropped a line with the id of a request of the bridge", .{});
        return;
    };
    var detail_buf: [64]u8 = undefined;
    const detail: ?[]const u8 = switch (cause) {
        .line_too_long => std.fmt.bufPrint(&detail_buf, "limit: {d} bytes", .{self.options.max_line_bytes}) catch null,
        .too_deep => std.fmt.bufPrint(&detail_buf, "limit: {d} levels", .{@min(self.options.json_max_depth, mcp.json.max_message_depth)}) catch null,
        else => null,
    };
    log.debug("answered a line that is not valid: {t}", .{cause});
    self.writeError(id, translate.errorFor(cause, detail));
}

fn handleRequest(self: *Frontend, slot: *Slot, req: Message.Request) void {
    slot.id = req.id;
    slot.method = req.method;
    slot.params = req.params;
    slot.kind = legacy.classify(req.method);
    const current = self.lifecycle.load(.acquire);
    switch (slot.kind) {
        .ping => self.answerInline(slot, .{ .object = .empty }),
        .set_level => {
            const p = legacy.parseSetLevelParams(slot.arena.allocator(), req.params) catch |e| {
                const cause: translate.Cause = if (e == error.OutOfMemory) .out_of_memory else .invalid_params;
                return self.errorInline(slot, translate.errorFor(cause, null));
            };
            // Revision 2026-07-28 has no setLevel request. A later version sends the level
            // with each request.
            self.client_level.store(@as(u8, @intFromEnum(p.level)) + 1, .release);
            self.answerInline(slot, .{ .object = .empty });
        },
        // A client of two revisions sends `server/discover` first. The answer -32601 makes it
        // continue with `initialize`.
        .discover => self.errorInline(slot, translate.errorFor(.method_not_found, null)),
        .initialize => {
            if (current == .closing) return self.closingInline(slot);
            if (self.lifecycle.cmpxchgStrong(.awaiting_initialize, .initializing, .acq_rel, .acquire) != null) {
                return self.errorInline(slot, translate.errorFor(.already_initialized, null));
            }
            if (!self.admit(slot)) _ = self.lifecycle.cmpxchgStrong(.initializing, .awaiting_initialize, .acq_rel, .acquire);
        },
        .forwarded, .subscribe, .unsubscribe, .unknown => {
            if (current == .closing) return self.closingInline(slot);
            if (current != .ready) {
                // A request of revision 2026-07-28 before `initialize` gets -32601, thus a
                // client of two revisions continues with `initialize`.
                const cause: translate.Cause = if (legacy.hasModernMeta(req.params)) .method_not_found else .not_initialized;
                return self.errorInline(slot, translate.errorFor(cause, null));
            }
            if (slot.kind != .forwarded) return self.errorInline(slot, translate.errorFor(.method_not_found, null));
            _ = self.admit(slot);
        },
    }
}

/// Answer a request on the reader and release its slot.
fn answerInline(self: *Frontend, slot: *Slot, result: Value) void {
    defer self.destroySlot(slot);
    self.writeResult(slot.id, result);
}

fn errorInline(self: *Frontend, slot: *Slot, err: translate.RpcError) void {
    defer self.destroySlot(slot);
    self.writeError(slot.id, err);
}

/// A request after the end of the connection. After the loss of the upstream server, the
/// request gets an error. After the end of the input, it gets nothing.
fn closingInline(self: *Frontend, slot: *Slot) void {
    if (self.upstream_lost.load(.acquire)) return self.errorInline(slot, translate.errorFor(.upstream_exited, null));
    self.destroySlot(slot);
}

fn handleNotification(self: *Frontend, arena: Allocator, n: Message.Notification) void {
    switch (legacy.classifyNotification(n.method)) {
        .initialized => log.debug("the client sent notifications/initialized", .{}),
        .roots_list_changed => {},
        .other => log.debug("ignored the notification {s}", .{n.method}),
        .cancelled => {
            const params = legacy.parseCancelledParams(arena, n.params) catch return;
            const id = params.requestId orelse return;
            self.in_flight_lock.lockUncancelable(self.io);
            defer self.in_flight_lock.unlock(self.io);
            for (self.in_flight.items) |slot| {
                if (!slot.id.eql(id)) continue;
                log.debug("the client canceled request {f} ({s})", .{ slot.id, slot.method });
                slot.token.cancel(self.io, client_cancel_reason);
                return;
            }
        },
    }
}

/// Start the task of a request, or answer it when the limit is full. The admission and the
/// start happen under `in_flight_lock`, thus `stopAdmission` sees each task. The reader never
/// waits here. Returns true when the task started. The function owns `slot`.
fn admit(self: *Frontend, slot: *Slot) bool {
    slot.started = Io.Clock.Timestamp.now(self.io, .awake);
    const Outcome = enum { started, stopped, full, failed };
    self.in_flight_lock.lockUncancelable(self.io);
    const outcome: Outcome = outcome: {
        if (!self.admitting) break :outcome .stopped;
        if (self.in_flight.items.len >= self.options.max_in_flight_requests) break :outcome .full;
        self.in_flight.append(self.gpa, slot) catch break :outcome .failed;
        self.group.concurrent(self.io, runSlot, .{slot}) catch {
            self.removeLocked(slot);
            break :outcome .failed;
        };
        break :outcome .started;
    };
    self.in_flight_lock.unlock(self.io);
    switch (outcome) {
        .started => return true,
        .stopped => self.closingInline(slot),
        .full => {
            log.warn("rejected request {f} ({s}): too many requests in flight", .{ slot.id, slot.method });
            self.errorInline(slot, translate.errorFor(.too_many_requests, null));
        },
        .failed => self.errorInline(slot, translate.errorFor(.too_many_requests, null)),
    }
    return false;
}

fn removeLocked(self: *Frontend, slot: *Slot) void {
    for (self.in_flight.items, 0..) |s, i| if (s == slot) {
        _ = self.in_flight.swapRemove(i);
        return;
    };
}

fn untrack(self: *Frontend, slot: *Slot) void {
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    self.removeLocked(slot);
}

// ---------------------------------------------------------------------------------------------
// Slot tasks
// ---------------------------------------------------------------------------------------------

fn runSlot(slot: *Slot) Io.Cancelable!void {
    const self = slot.owner;
    defer {
        self.untrack(slot);
        self.destroySlot(slot);
    }
    switch (slot.kind) {
        .initialize => self.runInitialize(slot),
        .forwarded => self.runForward(slot),
        else => unreachable,
    }
}

fn runInitialize(self: *Frontend, slot: *Slot) void {
    const arena = slot.arena.allocator();
    const params = legacy.parseInitializeParams(arena, slot.params) catch |e| {
        const cause: translate.Cause = if (e == error.OutOfMemory) .out_of_memory else .invalid_params;
        return self.failInitialize(slot, translate.errorFor(cause, null));
    };
    log.info("initialize from {s} {s}", .{ params.clientInfo.name, params.clientInfo.version });
    const caps = translate.upstreamCapabilities(arena, params.capabilities, self.options.capability_mask) catch
        return self.failInitialize(slot, translate.errorFor(.out_of_memory, null));
    self.upstream.connect(params.clientInfo, caps) catch |e| {
        const cause: translate.Cause = if (e == error.OutOfMemory) .out_of_memory else .spawn_failed;
        return self.failInitialize(slot, translate.errorFor(cause, null));
    };
    var diag: mcp.Client.Diagnostics = .{};
    const raw = self.upstream.discover(arena, .{
        .cancel = &slot.token,
        .timeout = self.options.discover_timeout,
        .diagnostics = &diag,
        .client_id = slot.id,
    }) catch |e| {
        if (e == error.Canceled) {
            // At the end of the input, `shutdown` closes the upstream.
            if (self.lifecycle.load(.acquire) == .closing) return;
            self.upstream.close();
            _ = self.lifecycle.cmpxchgStrong(.initializing, .awaiting_initialize, .acq_rel, .acquire);
            return;
        }
        const err: translate.RpcError = switch (e) {
            error.Rpc => translate.discoverFailed(diag.rpc_error),
            error.Timeout => translate.errorFor(.discover_failed, std.fmt.allocPrint(arena, "no response in {f}", .{TimeLimit{ .duration = self.options.discover_timeout }}) catch null),
            else => translate.errorFor(translate.causeOf(e), "server/discover"),
        };
        log.warn("server/discover failed: {t}", .{e});
        return self.failInitialize(slot, err);
    };
    const result = translate.initializeResult(arena, raw, .{
        .profile = self.profile,
        .fallback_name = self.options.fallback_name,
        .mask = self.options.reply_mask,
    }) catch return self.failInitialize(slot, translate.errorFor(.out_of_memory, null));
    // The state is `ready` before the response goes out, because the next requests of the
    // client can come at once. At the end of the input, the state is `closing`.
    if (self.lifecycle.cmpxchgStrong(.initializing, .ready, .acq_rel, .acquire) != null) return;
    log.info("the upstream server is ready", .{});
    self.respond(slot, result);
}

/// Stop the upstream server, return to `awaiting_initialize`, then answer with `err`. Thus a
/// new `initialize` of the client finds the state `awaiting_initialize`.
fn failInitialize(self: *Frontend, slot: *Slot, err: translate.RpcError) void {
    if (self.lifecycle.load(.acquire) != .closing) self.upstream.close();
    _ = self.lifecycle.cmpxchgStrong(.initializing, .awaiting_initialize, .acq_rel, .acquire);
    self.respondError(slot, err);
}

fn runForward(self: *Frontend, slot: *Slot) void {
    const arena = slot.arena.allocator();
    const fwd = translate.forwardParams(arena, slot.params, self.profile) catch
        return self.respondError(slot, translate.errorFor(.out_of_memory, null));
    slot.progress_token = fwd.progress_token;
    var diag: mcp.Client.Diagnostics = .{};
    const timeout = self.options.timeouts.forMethod(slot.method);
    const raw = self.upstream.request(arena, slot.method, fwd.params, .{
        .cancel = &slot.token,
        .timeout = timeout,
        .progress = if (fwd.progress_token != null) .{ .context = slot, .call = onProgress } else null,
        .diagnostics = &diag,
        .client_id = slot.id,
    }) catch |e| {
        const cause = translate.causeOf(e);
        self.logOutcome(slot, @errorName(e));
        if (!translate.hasResponse(cause)) return;
        const err: translate.RpcError = switch (cause) {
            .rpc => if (diag.rpc_error) |rpc| translate.fromUpstream(rpc) else translate.errorFor(.rpc, null),
            .timeout => translate.errorFor(.timeout, std.fmt.allocPrint(arena, "{s}: no response in {f}", .{ slot.method, TimeLimit{ .duration = timeout } }) catch null),
            .closed => translate.errorFor(if (self.upstream.gone()) .upstream_exited else .closed, null),
            else => translate.errorFor(cause, null),
        };
        if (cause == .timeout) log.warn("request {f} ({s}): no response in {f}", .{ slot.id, slot.method, TimeLimit{ .duration = timeout } });
        return self.respondError(slot, err);
    };
    if (translate.isInputRequired(raw)) {
        // A later version asks the client and sends the answers to the upstream server.
        log.warn("request {f} ({s}): the upstream server asked for input", .{ slot.id, slot.method });
        return self.respondError(slot, translate.errorFor(.input_required, null));
    }
    const shaped = translate.shapeResult(arena, slot.method, raw, self.profile) catch
        return self.respondError(slot, translate.errorFor(.out_of_memory, null));
    for (shaped.fixes) |fix| switch (fix.kind) {
        .too_deep => log.info("tool '{s}': the input schema at '{s}' is too deep to examine", .{ fix.tool, fix.pointer }),
        else => log.info("tool '{s}': added an items schema at '{s}' of the input schema", .{ fix.tool, fix.pointer }),
    };
    self.logOutcome(slot, "ok");
    self.respond(slot, shaped.result);
}

/// A time limit as text: whole seconds, else milliseconds. Thus a limit below one second does
/// not show as "0 s".
const TimeLimit = struct {
    duration: Io.Duration,

    pub fn format(self: TimeLimit, w: *Io.Writer) Io.Writer.Error!void {
        const ms = self.duration.toMilliseconds();
        if (@rem(ms, std.time.ms_per_s) == 0) return w.print("{d} s", .{@divTrunc(ms, std.time.ms_per_s)});
        try w.print("{d} ms", .{ms});
    }
};

fn logOutcome(self: *Frontend, slot: *Slot, outcome: []const u8) void {
    const elapsed = slot.started.durationTo(Io.Clock.Timestamp.now(self.io, .awake)).raw.toMilliseconds();
    log.debug("request {f} ({s}): {s} after {d} ms", .{ slot.id, slot.method, outcome, elapsed });
}

/// The `params` of a progress notification to the client.
const ProgressParams = struct {
    progressToken: Value,
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,
};

/// Send the progress of the upstream server to the client with the progress token of the
/// client. The upstream server uses the id of each round as its token, and the client of
/// zig-sdk gives each round to this function. Thus each round goes to the token of the
/// client.
fn onProgress(context: ?*anyopaque, params: types.ProgressNotificationParams) void {
    const slot: *Slot = @ptrCast(@alignCast(context.?));
    const self = slot.owner;
    const token = slot.progress_token orelse return;
    const frame = mcp.json.writeAlloc(self.gpa, mcp.jsonrpc.message.OutNotification(ProgressParams){
        .method = "notifications/progress",
        .params = .{ .progressToken = token, .progress = params.progress, .total = params.total, .message = params.message },
    }) catch return;
    defer self.gpa.free(frame);
    self.writeForSlot(slot, frame, .notification);
}

// ---------------------------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------------------------

const FrameKind = enum {
    /// A notification of the request. It goes out before the response only.
    notification,
    /// The response of the request. It goes out once, and not after a cancellation.
    response,
};

/// Write a frame of a request. All frames of a request go out under `out_lock`, thus the
/// check of `answered` and the write are one step. A canceled request gets no frame.
fn writeForSlot(self: *Frontend, slot: *Slot, frame: []const u8, kind: FrameKind) void {
    self.out_lock.lockUncancelable(self.io);
    defer self.out_lock.unlock(self.io);
    if (self.closed.load(.acquire) or slot.answered or slot.token.isCancelled()) return;
    if (kind == .response) slot.answered = true;
    self.sink.write(self.sink.ptr, frame) catch |e| log.debug("cannot write a frame: {t}", .{e});
}

fn respond(self: *Frontend, slot: *Slot, result: Value) void {
    const frame = mcp.json.writeAlloc(self.gpa, mcp.jsonrpc.message.OutResponse(Value){ .id = slot.id, .result = result }) catch
        return self.respondError(slot, translate.errorFor(.out_of_memory, null));
    defer self.gpa.free(frame);
    self.writeForSlot(slot, frame, .response);
}

fn respondError(self: *Frontend, slot: *Slot, err: translate.RpcError) void {
    var buf: [1024]u8 = undefined;
    const frame = self.errorFrame(&buf, slot.id, err) orelse return;
    defer frame.deinit(self.gpa);
    self.writeForSlot(slot, frame.text, .response);
}

/// Write a frame that belongs to no slot task.
fn writeFrame(self: *Frontend, frame: []const u8) void {
    self.out_lock.lockUncancelable(self.io);
    defer self.out_lock.unlock(self.io);
    if (self.closed.load(.acquire)) return;
    self.sink.write(self.sink.ptr, frame) catch |e| log.debug("cannot write a frame: {t}", .{e});
}

fn writeResult(self: *Frontend, id: RequestId, result: Value) void {
    const frame = mcp.json.writeAlloc(self.gpa, mcp.jsonrpc.message.OutResponse(Value){ .id = id, .result = result }) catch
        return self.writeError(id, translate.errorFor(.out_of_memory, null));
    defer self.gpa.free(frame);
    self.writeFrame(frame);
}

fn writeError(self: *Frontend, id: ?RequestId, err: translate.RpcError) void {
    var buf: [1024]u8 = undefined;
    const frame = self.errorFrame(&buf, id, err) orelse return;
    defer frame.deinit(self.gpa);
    self.writeFrame(frame.text);
}

/// An error response. `RpcError` writes its own `data`, thus the frame needs no arena.
const ErrorEnvelope = struct {
    id: ?RequestId,
    err: translate.RpcError,

    pub fn jsonStringify(self: ErrorEnvelope, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("jsonrpc");
        try jws.write(mcp.jsonrpc.message.jsonrpc_version);
        try jws.objectField("id");
        if (self.id) |id| try jws.write(id) else try jws.write(null);
        try jws.objectField("error");
        try jws.write(self.err);
        try jws.endObject();
    }
};

/// The text of an error response.
const ErrorFrame = struct {
    text: []u8,
    /// True when `gpa` holds `text`.
    owned: bool,

    fn deinit(self: ErrorFrame, gpa: Allocator) void {
        if (self.owned) gpa.free(self.text);
    }
};

/// The error response for `err`. Without memory, the response is the `out_of_memory` error
/// in `buf`. Null when that also fails.
fn errorFrame(self: *Frontend, buf: []u8, id: ?RequestId, err: translate.RpcError) ?ErrorFrame {
    if (mcp.json.writeAlloc(self.gpa, ErrorEnvelope{ .id = id, .err = err })) |text| return .{ .text = text, .owned = true } else |_| {}
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const text = mcp.json.writeAlloc(fba.allocator(), ErrorEnvelope{ .id = id, .err = translate.errorFor(.out_of_memory, null) }) catch return null;
    return .{ .text = text, .owned = false };
}

// ---------------------------------------------------------------------------------------------
// Upstream loss and shutdown
// ---------------------------------------------------------------------------------------------

/// The task that examines the upstream server. It also writes a log line about each request
/// that waits for a long time.
fn watch(self: *Frontend) Io.Cancelable!void {
    while (!self.stopping.load(.acquire)) {
        self.stop_event.waitTimeout(self.io, .{ .duration = .{ .raw = self.options.watch_interval, .clock = .awake } }) catch |e| switch (e) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        if (self.stopping.load(.acquire)) return;
        if (self.lifecycle.load(.acquire) == .ready and self.upstream.gone()) {
            self.upstreamLost();
            return;
        }
        self.reportWaits();
    }
}

fn reportWaits(self: *Frontend) void {
    const now = Io.Clock.Timestamp.now(self.io, .awake);
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    for (self.in_flight.items) |slot| {
        const waited_s = slot.started.durationTo(now).raw.toSeconds();
        if (waited_s < slot.next_report_s) continue;
        slot.next_report_s = waited_s + report_interval_s;
        const method = if (slot.kind == .initialize) "server/discover" else slot.method;
        log.info("still waiting for the upstream server: {s} (request {f}, {d} s)", .{ method, slot.id, waited_s });
    }
}

/// The upstream server stopped while the input is open. Answer each request in flight with
/// -32603, stop the reader and call `Hooks.on_upstream_exit`.
fn upstreamLost(self: *Frontend) void {
    self.upstream_lost.store(true, .release);
    self.lifecycle.store(.closing, .release);
    if (self.upstream.reap()) |term| switch (term) {
        .exited => |code| log.err("the upstream server exited with code {d}", .{code}),
        .signal => |sig| log.err("the upstream server stopped on signal {d}", .{@intFromEnum(sig)}),
        else => log.err("the upstream server stopped", .{}),
    } else log.err("the upstream server stopped", .{});
    self.stopAdmission();
    self.failInFlight();
    // This task is in the group, thus it cannot wait for the group. The requests fail at
    // once, because the client of the upstream server is closed.
    _ = self.waitForSlots(self.options.shutdown_grace);
    // After this step, no frame is in progress. Thus the hook can stop the process.
    self.closeOutput();
    self.stop();
    if (self.options.hooks.on_upstream_exit) |f| f(self.options.hooks.context);
}

/// Answer each request in flight with -32603, then cancel it. A request that the client
/// canceled gets no response. Its task can stay in flight until it sees the cancellation.
/// The reader cancels a request under `in_flight_lock`, thus the check and the response are
/// one step.
fn failInFlight(self: *Frontend) void {
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    for (self.in_flight.items) |slot| {
        if (slot.token.isCancelled()) continue;
        self.respondError(slot, translate.errorFor(.upstream_exited, null));
        slot.token.cancel(self.io, eof_cancel_reason);
    }
}

/// Send no more frames. A frame that is in progress completes first, because the function
/// sets the flag under `out_lock`.
fn closeOutput(self: *Frontend) void {
    self.out_lock.lockUncancelable(self.io);
    defer self.out_lock.unlock(self.io);
    self.closed.store(true, .release);
}

/// Stop the reader after its next line, and wake the watcher.
fn stop(self: *Frontend) void {
    self.stopping.store(true, .release);
    self.stop_event.set(self.io);
}

/// Drop each request that arrives from now on. The requests in flight continue.
fn stopAdmission(self: *Frontend) void {
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    self.admitting = false;
}

/// Cancel each request in flight. A canceled request gets no response.
fn cancelAll(self: *Frontend, reason: []const u8) void {
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    for (self.in_flight.items) |slot| slot.token.cancel(self.io, reason);
}

/// Wait until no request is in flight, at most `grace`. Returns false at the end of `grace`.
fn waitForSlots(self: *Frontend, grace: Io.Duration) bool {
    const io = self.io;
    const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = grace, .clock = .awake });
    while (self.inFlightCount() > 0) {
        if (Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw.nanoseconds <= 0) return false;
        io.sleep(.fromMilliseconds(5), .awake) catch return false;
    }
    return true;
}

/// Stop the connection. The function stops the admission and cancels each request in flight.
/// It waits for them for at most `shutdown_grace`, then it cancels the tasks that are left
/// and closes the upstream. The function does nothing the second time. `run` calls it at the
/// end of the input.
pub fn shutdown(self: *Frontend) void {
    if (self.shut_down) return;
    self.shut_down = true;
    self.stop();
    self.lifecycle.store(.closing, .release);
    if (!self.upstream_lost.load(.acquire)) if (self.options.hooks.on_eof) |f| f(self.options.hooks.context, self.upstream);
    self.stopAdmission();
    self.cancelAll(eof_cancel_reason);
    if (self.waitForSlots(self.options.shutdown_grace)) {
        // Only the watcher can be left. `stop_event` wakes it.
        self.group.await(self.io) catch {};
    } else {
        self.group.cancel(self.io);
    }
    self.closeOutput();
    self.upstream.close();
}

// ---------------------------------------------------------------------------------------------
// Line reader and id recovery
// ---------------------------------------------------------------------------------------------

/// The start and the end of a line that is too long. VS Code writes the id of a request near
/// the start of the line. The TypeScript SDK 1.x writes it as the last member.
pub const LongLine = struct {
    /// The first bytes of the line, at most `LineReader.head_bytes`.
    head: []const u8,
    /// The last bytes of the line, at most `LineReader.tail_bytes`. The head and the tail can
    /// have bytes in common.
    tail: []const u8,

    /// The start and the end of `text`. The result points into `text`.
    pub fn of(text: []const u8) LongLine {
        return .{
            .head = text[0..@min(text.len, LineReader.head_bytes)],
            .tail = text[text.len - @min(text.len, LineReader.tail_bytes) ..],
        };
    }
};

/// Reads newline-delimited messages. Unlike `mcp.util.line_framer`, it keeps the start and
/// the end of a line that is too long. Thus the front end can find the id of the request.
pub const LineReader = struct {
    reader: *Io.Reader,
    max_line_bytes: usize,

    /// The length of the start of a line that `next` keeps for a line that is too long.
    pub const head_bytes = 256;
    /// The length of the end of a line that `next` keeps for a line that is too long.
    pub const tail_bytes = 256;

    pub const Line = union(enum) {
        /// A line without its line end. It is valid UTF-8 and not blank.
        line: []u8,
        /// A line that is longer than `max_line_bytes`. The reader skipped the rest of the
        /// line. The tail can end with a `\r`.
        too_long: LongLine,
        /// A line that is not valid UTF-8.
        invalid_utf8: []u8,
        /// The input ended.
        eof,
    };

    pub const Error = error{ ReadFailed, OutOfMemory };

    /// Read the next line that is not blank into `arena`. The reader removes a `\r` at the
    /// end of the line.
    pub fn next(self: *LineReader, arena: Allocator) Error!Line {
        while (true) {
            const raw = switch (try self.readLine(arena)) {
                .line => |l| l,
                else => |other| return other,
            };
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (isBlank(line)) continue;
            if (!std.unicode.utf8ValidateSlice(line)) return .{ .invalid_utf8 = @constCast(line) };
            return .{ .line = @constCast(line) };
        }
    }

    fn readLine(self: *LineReader, arena: Allocator) Error!Line {
        // Fast path: the line is in the buffer of the reader.
        if (self.reader.takeDelimiterExclusive('\n')) |line| {
            // At the end of the input, the last line comes without its delimiter.
            if (self.reader.bufferedLen() > 0 and self.reader.buffered()[0] == '\n') self.reader.toss(1);
            return try self.keep(arena, line);
        } else |e| switch (e) {
            error.StreamTooLong => {},
            error.EndOfStream => {
                const rest = self.reader.buffered();
                if (rest.len == 0) return .eof;
                const line = try self.keep(arena, rest);
                self.reader.toss(rest.len);
                return line;
            },
            error.ReadFailed => return error.ReadFailed,
        }
        // Slow path: collect the line in a buffer that grows up to the limit. The buffer can
        // always hold the start of a line that is too long.
        var aw: Io.Writer.Allocating = .init(arena);
        const limit = @max(self.max_line_bytes, head_bytes) + 1;
        _ = self.reader.streamDelimiterLimit(&aw.writer, '\n', .limited(limit)) catch |e| switch (e) {
            error.StreamTooLong => {
                const written = aw.written();
                const head = try arena.dupe(u8, written[0..@min(written.len, head_bytes)]);
                var tail: Tail = .{};
                tail.append(written);
                // Skip the rest of the line. Else it becomes the next line.
                try self.skipLine(&tail);
                return .{ .too_long = .{ .head = head, .tail = try arena.dupe(u8, tail.slice()) } };
            },
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
        };
        // The delimiter is next, or the input ended.
        if (self.reader.peekByte()) |_| {
            self.reader.toss(1);
        } else |_| {
            if (aw.written().len == 0) return .eof;
        }
        return self.keep(arena, aw.written());
    }

    /// A copy of `line`, or of its start and its end when the line is too long.
    fn keep(self: *LineReader, arena: Allocator, line: []const u8) Allocator.Error!Line {
        if (line.len > self.max_line_bytes) {
            const long: LongLine = .of(line);
            return .{ .too_long = .{ .head = try arena.dupe(u8, long.head), .tail = try arena.dupe(u8, long.tail) } };
        }
        return .{ .line = try arena.dupe(u8, line) };
    }

    /// Skip the rest of the line and its delimiter. Keep the end of the line in `tail`.
    fn skipLine(self: *LineReader, tail: *Tail) Error!void {
        while (true) {
            const data = self.reader.peekGreedy(1) catch |e| switch (e) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
            if (std.mem.indexOfScalar(u8, data, '\n')) |i| {
                tail.append(data[0..i]);
                self.reader.toss(i + 1);
                return;
            }
            tail.append(data);
            self.reader.toss(data.len);
        }
    }

    /// The last `tail_bytes` bytes of the data that `append` got.
    const Tail = struct {
        buf: [tail_bytes]u8 = undefined,
        len: usize = 0,

        fn append(self: *Tail, data: []const u8) void {
            if (data.len >= tail_bytes) {
                @memcpy(&self.buf, data[data.len - tail_bytes ..]);
                self.len = tail_bytes;
                return;
            }
            const kept = @min(self.len, tail_bytes - data.len);
            std.mem.copyForwards(u8, self.buf[0..kept], self.buf[self.len - kept .. self.len]);
            @memcpy(self.buf[kept..][0..data.len], data);
            self.len = kept + data.len;
        }

        fn slice(self: *const Tail) []const u8 {
            return self.buf[0..self.len];
        }
    };

    fn isBlank(line: []const u8) bool {
        for (line) |c| if (c != ' ' and c != '\t') return false;
        return true;
    }
};

/// Find the `id` member of the top-level object in `text`, which can be JSON that is not
/// valid or only the start of a line. The function examines the bytes and does not parse the
/// text. It ignores an `id` in a nested value. It gives null without such a member. It also
/// gives null when the value is not a valid JSON string or an integer, or when the text ends
/// in the value.
///
/// A string id with escape sequences goes to `allocator`. Another string id points into
/// `text`.
pub fn recoverId(allocator: Allocator, text: []const u8) ?RequestId {
    var i = skipSpace(text, 0);
    if (i >= text.len or text[i] != '{') return null;
    i += 1;
    var depth: usize = 1;
    var expect_key = true;
    while (i < text.len) {
        switch (text[i]) {
            '"' => {
                const end = stringEnd(text, i) orelse return null;
                if (depth == 1 and expect_key) {
                    expect_key = false;
                    if (std.mem.eql(u8, text[i + 1 .. end - 1], "id")) {
                        var j = skipSpace(text, end);
                        if (j >= text.len or text[j] != ':') return null;
                        j = skipSpace(text, j + 1);
                        return idValue(allocator, text, j);
                    }
                }
                i = end;
                continue;
            },
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return null;
            },
            ',' => if (depth == 1) {
                expect_key = true;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

/// Find the id of a line that is too long: `recoverId` of the head, else
/// `recoverTrailingId` of the tail.
pub fn recoverLongLineId(allocator: Allocator, long: LongLine) ?RequestId {
    return recoverId(allocator, long.head) orelse recoverTrailingId(long.tail);
}

/// Find an `id` member at the end of `text`, which is the end of a line. The TypeScript SDK
/// 1.x writes the id of a request as the last member. The text must end with `"id"`, a colon,
/// the value, one `}` and optional white space. Thus the member is the last member of the
/// top-level object. A comma or a `{` comes before the member.
///
/// The value is an integer, or a string without escape sequences. The function gives null
/// for a different text. A string id points into `text`.
pub fn recoverTrailingId(text: []const u8) ?RequestId {
    var end = skipSpaceBack(text, text.len);
    if (end == 0 or text[end - 1] != '}') return null;
    end = skipSpaceBack(text, end - 1);
    if (end == 0) return null;
    var start: usize = undefined;
    const id: RequestId = id: {
        if (text[end - 1] == '"') {
            const open = std.mem.lastIndexOfScalar(u8, text[0 .. end - 1], '"') orelse return null;
            const inner = text[open + 1 .. end - 1];
            // A JSON string has no control characters and is valid UTF-8. A backslash starts
            // an escape sequence, and then the quote before can be a part of the string.
            for (inner) |b| if (b < 0x20 or b == '\\') return null;
            if (!std.unicode.utf8ValidateSlice(inner)) return null;
            start = open;
            break :id .{ .string = inner };
        }
        if (!std.ascii.isDigit(text[end - 1])) return null;
        start = end - 1;
        while (start > 0 and std.ascii.isDigit(text[start - 1])) start -= 1;
        if (start > 0 and text[start - 1] == '-') start -= 1;
        const digits = text[start..end];
        if (std.fmt.parseInt(i64, digits, 10)) |n| break :id .{ .integer = n } else |_| break :id .{ .big = digits };
    };
    // A colon and the key `"id"` come before the value. A fraction, an exponent or a cut
    // number has a different byte before the digits, and the check fails.
    var i = skipSpaceBack(text, start);
    if (i == 0 or text[i - 1] != ':') return null;
    i = skipSpaceBack(text, i - 1);
    if (i < 4 or !std.mem.eql(u8, text[i - 4 .. i], "\"id\"")) return null;
    i = skipSpaceBack(text, i - 4);
    if (i == 0 or (text[i - 1] != ',' and text[i - 1] != '{')) return null;
    return id;
}

/// The index after the last byte before `end` that is not white space.
fn skipSpaceBack(text: []const u8, end: usize) usize {
    var i = end;
    while (i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t' or text[i - 1] == '\r' or text[i - 1] == '\n')) i -= 1;
    return i;
}

/// The id at `text[start..]`.
fn idValue(allocator: Allocator, text: []const u8, start: usize) ?RequestId {
    if (start >= text.len) return null;
    const c = text[start];
    if (c == '"') {
        const end = stringEnd(text, start) orelse return null;
        const inner = text[start + 1 .. end - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
            // A JSON string has no control characters and is valid UTF-8. Else the id is not a
            // string, and the writer of the response would write it as an array of bytes.
            for (inner) |b| if (b < 0x20) return null;
            if (!std.unicode.utf8ValidateSlice(inner)) return null;
            return .{ .string = inner };
        }
        const decoded = mcp.json.parseTree(allocator, text[start..end]) catch return null;
        return if (decoded == .string) .{ .string = decoded.string } else null;
    }
    if (c != '-' and !std.ascii.isDigit(c)) return null;
    var end = start + 1;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    // The number continues after the end of the text, or it is not an integer.
    if (end >= text.len) return null;
    switch (text[end]) {
        '.', 'e', 'E' => return null,
        else => {},
    }
    const digits = text[start..end];
    if (digits.len == 1 and c == '-') return null;
    if (std.fmt.parseInt(i64, digits, 10)) |n| return .{ .integer = n } else |_| return .{ .big = digits };
}

/// The index after the last quote of the string that starts at `text[start]`, or null when
/// the text ends first.
fn stringEnd(text: []const u8, start: usize) ?usize {
    var k = start + 1;
    while (k < text.len) {
        switch (text[k]) {
            '\\' => k += 2,
            '"' => return k + 1,
            else => k += 1,
        }
    }
    return null;
}

fn skipSpace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
    return i;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "the line reader keeps the start and the end of a line that is too long" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"x\":\"" ++ "y" ** 300 ++ "\"}}";
    // The order of the members of the TypeScript SDK 1.x: the id comes last.
    const ts_long = "{\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"" ++ "y" ** 300 ++ "\"}},\"jsonrpc\":\"2.0\",\"id\":43}";
    // Much longer than the buffer of the slow path, thus the tail comes from the rest only.
    const ts_longer = "{\"method\":\"x\",\"params\":{\"text\":\"" ++ "z" ** 2000 ++ "\"},\"jsonrpc\":\"2.0\",\"id\":\"ts-44\"}";
    // A small buffer takes the slow path, a large buffer the fast path.
    for ([_]usize{ 16, 4096 }) |buffer_len| {
        var fixed: Io.Reader = .fixed("{\"a\":1}\r\n\n  \n" ++ long ++ "\n" ++ ts_long ++ "\r\n" ++ ts_longer ++ "\nok\n\xff\xfe\nlast");
        const buf = try arena.alloc(u8, buffer_len);
        var limited = fixed.limited(.unlimited, buf);
        var reader: LineReader = .{ .reader = &limited.interface, .max_line_bytes = 100 };
        try testing.expectEqualStrings("{\"a\":1}", (try reader.next(arena)).line);
        const first = (try reader.next(arena)).too_long;
        try testing.expectEqualStrings(long[0..LineReader.head_bytes], first.head);
        try testing.expectEqualStrings(long[long.len - LineReader.tail_bytes ..], first.tail);
        try testing.expectEqual(@as(i64, 42), recoverLongLineId(arena, first).?.integer);
        const second = (try reader.next(arena)).too_long;
        try testing.expectEqualStrings(ts_long[0..LineReader.head_bytes], second.head);
        // The tail keeps the `\r` of the line end.
        try testing.expectEqualStrings(ts_long[ts_long.len - LineReader.tail_bytes + 1 ..] ++ "\r", second.tail);
        try testing.expect(recoverId(arena, second.head) == null);
        try testing.expectEqual(@as(i64, 43), recoverLongLineId(arena, second).?.integer);
        const third = (try reader.next(arena)).too_long;
        try testing.expectEqualStrings(ts_longer[ts_longer.len - LineReader.tail_bytes ..], third.tail);
        try testing.expectEqualStrings("ts-44", recoverLongLineId(arena, third).?.string);
        try testing.expectEqualStrings("ok", (try reader.next(arena)).line);
        try testing.expectEqualStrings("\xff\xfe", (try reader.next(arena)).invalid_utf8);
        try testing.expectEqualStrings("last", (try reader.next(arena)).line);
        try testing.expect(try reader.next(arena) == .eof);
    }
}

test "recoverId finds the id of the top-level object" {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = fba.allocator();
    try testing.expectEqual(@as(i64, 7), recoverId(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"x\"").?.integer);
    try testing.expectEqual(@as(i64, -3), recoverId(a, " { \"id\" : -3 , \"x\": [").?.integer);
    try testing.expectEqualStrings("b-1", recoverId(a, "{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"x\":\"\\ud800\"}}").?.string);
    try testing.expectEqualStrings("a\"b", recoverId(a, "{\"id\":\"a\\\"b\",").?.string);
    try testing.expectEqualStrings("123456789012345678901234567890", recoverId(a, "{\"id\":123456789012345678901234567890}").?.big);
    // An id in a nested value, or as a value, does not count.
    try testing.expectEqual(@as(i64, 9), recoverId(a, "{\"params\":{\"id\":5,\"list\":[{\"id\":6}]},\"name\":\"id\",\"id\":9}").?.integer);
    try testing.expect(recoverId(a, "{\"params\":{\"id\":5}}") == null);
    // A value that the text cuts, or that is not an id.
    try testing.expect(recoverId(a, "{\"id\":12") == null);
    try testing.expect(recoverId(a, "{\"id\":\"abc") == null);
    // A string with bytes that are not UTF-8, or with a control character, is not a JSON
    // string.
    try testing.expect(recoverId(a, "{\"id\":\"\xb3\xe3rpc\",\"method\":\"x\"}") == null);
    try testing.expect(recoverId(a, "{\"id\":\"a\x1cb\",\"method\":\"x\"}") == null);
    try testing.expect(recoverId(a, "{\"id\":\"a\\u001cb\x01\",\"method\":\"x\"}") == null);
    try testing.expectEqualStrings("caf\xc3\xa9", recoverId(a, "{\"id\":\"caf\xc3\xa9\",\"method\":\"x\"}").?.string);
    try testing.expect(recoverId(a, "{\"id\":1.5}") == null);
    try testing.expect(recoverId(a, "{\"id\":null}") == null);
    try testing.expect(recoverId(a, "{\"id\":-}") == null);
    try testing.expect(recoverId(a, "[{\"id\":1}]") == null);
    try testing.expect(recoverId(a, "") == null);
    try testing.expect(recoverId(a, "{\"method\":\"x\"}") == null);
}

test "recoverTrailingId finds the id at the end of the top-level object" {
    try testing.expectEqual(@as(i64, 7), recoverTrailingId("yy\"}},\"jsonrpc\":\"2.0\",\"id\":7}").?.integer);
    try testing.expectEqual(@as(i64, -12), recoverTrailingId("x\" , \"id\" : -12 }\r\n").?.integer);
    try testing.expectEqual(@as(i64, 3), recoverTrailingId("{\"id\":3}").?.integer);
    try testing.expectEqualStrings("req-1", recoverTrailingId("\"2.0\",\"id\":\"req-1\"}").?.string);
    try testing.expectEqualStrings("caf\xc3\xa9", recoverTrailingId(",\"id\":\"caf\xc3\xa9\"}").?.string);
    try testing.expectEqualStrings("123456789012345678901234567890", recoverTrailingId(",\"id\":123456789012345678901234567890}").?.big);
    // An id in a nested object has more than one `}` after it.
    try testing.expect(recoverTrailingId(",\"params\":{\"id\":5}}") == null);
    // The text of a string value, and a key that only ends with "id". A string can end with
    // an escaped backslash.
    try testing.expect(recoverTrailingId(",\"text\":\"a \\\"id\\\":5}\"}") == null);
    try testing.expect(recoverTrailingId(",\"xid\":5}") == null);
    try testing.expectEqual(@as(i64, 5), recoverTrailingId(",\"text\":\"a\\\\\",\"id\":5}").?.integer);
    try testing.expect(recoverTrailingId("[\"id\":5}") == null);
    // A value that is not an integer or a string without escape sequences.
    try testing.expect(recoverTrailingId(",\"id\":1.5}") == null);
    try testing.expect(recoverTrailingId(",\"id\":1e5}") == null);
    try testing.expect(recoverTrailingId(",\"id\":null}") == null);
    try testing.expect(recoverTrailingId(",\"id\":\"a\\\"b\"}") == null);
    try testing.expect(recoverTrailingId(",\"id\":\"a\x01b\"}") == null);
    try testing.expect(recoverTrailingId(",\"id\":\"\xb3\xe3\"}") == null);
    // A text that does not end with the object, or that starts in the value.
    try testing.expect(recoverTrailingId(",\"id\":5") == null);
    try testing.expect(recoverTrailingId(",\"id\":5}x") == null);
    try testing.expect(recoverTrailingId("5}") == null);
    try testing.expect(recoverTrailingId("\"id\":5}") == null);
    try testing.expect(recoverTrailingId("}") == null);
    try testing.expect(recoverTrailingId("") == null);
}

test "a time limit as text" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("60 s", try std.fmt.bufPrint(&buf, "{f}", .{TimeLimit{ .duration = .fromSeconds(60) }}));
    try testing.expectEqualStrings("300 ms", try std.fmt.bufPrint(&buf, "{f}", .{TimeLimit{ .duration = .fromMilliseconds(300) }}));
    try testing.expectEqualStrings("1500 ms", try std.fmt.bufPrint(&buf, "{f}", .{TimeLimit{ .duration = .fromMilliseconds(1500) }}));
}

test "the timeouts by method" {
    const t: Timeouts = .{};
    try testing.expectEqual(@as(i64, 3600), t.forMethod("tools/call").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("resources/read").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("prompts/get").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("tools/list").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("completion/complete").toSeconds());
}

/// Collects the frames of a front end.
const TestSink = struct {
    io: Io,
    lock: Io.Mutex = .init,
    frames: std.ArrayList([]u8) = .empty,

    fn sink(self: *TestSink) Sink {
        return .{ .ptr = self, .write = write };
    }

    fn write(ptr: *anyopaque, frame: []const u8) Sink.WriteError!void {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        const copy = try testing.allocator.dupe(u8, frame);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.frames.append(testing.allocator, copy) catch {
            testing.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    fn deinit(self: *TestSink) void {
        for (self.frames.items) |f| testing.allocator.free(f);
        self.frames.deinit(testing.allocator);
    }

    fn count(self: *TestSink) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.frames.items.len;
    }

    /// Wait until there are `n` frames, at most five seconds.
    fn waitFor(self: *TestSink, n: usize) !void {
        var i: usize = 0;
        while (self.count() < n) : (i += 1) {
            if (i > 5000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    /// The frame with the id `id`, parsed in `arena`.
    fn byId(self: *TestSink, arena: Allocator, id: i64) !Value {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.frames.items) |f| {
            const v = try mcp.json.parseTree(arena, f);
            const frame_id = v.object.get("id") orelse continue;
            if (frame_id == .integer and frame_id.integer == id) return v;
        }
        return error.TestFrameMissing;
    }

    fn has(self: *TestSink, needle: []const u8) bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.frames.items) |f| if (std.mem.indexOf(u8, f, needle) != null) return true;
        return false;
    }
};

/// Wait until no request is in flight, at most five seconds.
fn waitUntilIdle(frontend: *Frontend) !void {
    var i: usize = 0;
    while (frontend.inFlightCount() > 0) : (i += 1) {
        if (i > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// A client transport that sends each request to `inner`, except `tools/call`. It holds each
/// `tools/call` until `release`, also after a cancellation. Thus a canceled request stays in
/// flight, as a request on stdio does between two polls of its cancellation.
const HoldTransport = struct {
    inner: mcp.transport.Transport.ClientTransport,
    held: std.atomic.Value(usize) = .init(0),
    released: std.atomic.Value(bool) = .init(false),

    const Transport = mcp.transport.Transport;
    const vtable: Transport.ClientTransport.VTable = .{ .kind = .memory, .exchange = exchange, .notify = notify };

    fn transport(self: *HoldTransport) Transport.ClientTransport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn release(self: *HoldTransport) void {
        self.released.store(true, .release);
    }

    fn exchange(ptr: *anyopaque, io: Io, ex: *Transport.Exchange) Transport.ExchangeError!void {
        const self: *HoldTransport = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, ex.method, "tools/call")) return self.inner.exchange(io, ex);
        _ = self.held.fetchAdd(1, .acq_rel);
        // At most ten seconds, so that a failed test does not stop the test run.
        var i: usize = 0;
        while (!self.released.load(.acquire) and i < 10_000) : (i += 1) try io.sleep(.fromMilliseconds(1), .awake);
        return if (ex.cancel.isCancelled()) error.Canceled else error.Closed;
    }

    fn notify(ptr: *anyopaque, io: Io, frame: []const u8) Transport.SendError!void {
        const self: *HoldTransport = @ptrCast(@alignCast(ptr));
        return self.inner.notify(io, frame);
    }

    /// Wait until the transport holds `n` calls, at most five seconds.
    fn waitHeld(self: *HoldTransport, n: usize) !void {
        var i: usize = 0;
        while (self.held.load(.acquire) < n) : (i += 1) {
            if (i > 5000) return error.TestTimeout;
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

/// A front end with an upstream server in this process.
const TestBridge = struct {
    server: *mcp.Server,
    upstream: *Upstream,
    out: TestSink,
    frontend: Frontend,
    arena_state: std.heap.ArenaAllocator,

    const profile: Profile = .{ .name = "mcp-bridge-test", .quirks = .{ .normalize_array_items = true } };

    fn create(options: Options) !*TestBridge {
        const io = testing.io;
        const gpa = testing.allocator;
        const self = try gpa.create(TestBridge);
        errdefer gpa.destroy(self);
        self.server = try testServer(gpa, io);
        errdefer destroyServer(self.server);
        self.upstream = try Upstream.init(io, gpa, .{ .memory = self.server });
        self.out = .{ .io = io };
        self.frontend = .init(io, gpa, self.upstream, &profile, self.out.sink(), options);
        self.arena_state = .init(gpa);
        return self;
    }

    fn destroy(self: *TestBridge) void {
        self.frontend.deinit();
        self.upstream.deinit();
        destroyServer(self.server);
        self.out.deinit();
        self.arena_state.deinit();
        testing.allocator.destroy(self);
    }

    fn send(self: *TestBridge, text: []const u8) !void {
        try self.frontend.receive(text);
    }

    /// Send a request and wait for its response.
    fn call(self: *TestBridge, id: i64, text: []const u8) !Value {
        const before = self.out.count();
        try self.send(text);
        try self.out.waitFor(before + 1);
        try self.waitIdle();
        return self.out.byId(self.arena_state.allocator(), id);
    }

    fn waitIdle(self: *TestBridge) !void {
        return waitUntilIdle(&self.frontend);
    }

    fn initialize(self: *TestBridge) !void {
        const v = try self.call(1, vscode_initialize);
        try testing.expect(v.object.get("result") != null);
        try testing.expectEqual(State.ready, self.frontend.state());
    }
};

/// The `initialize` request of VS Code 1.140.0.
const vscode_initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}},"tasks":{"list":{},"cancel":{},"requests":{"sampling":{"createMessage":{}},"elicitation":{"create":{}}}},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}}
;

fn testServer(gpa: Allocator, io: Io) !*mcp.Server {
    const server = try gpa.create(mcp.Server);
    errdefer gpa.destroy(server);
    server.* = try mcp.Server.init(gpa, io, .{ .info = .{ .name = "frontend-test", .version = "2.0.0" } });
    errdefer server.deinit();
    try server.addTool(.{ .name = "add", .description = "Add two integers" }, testAdd);
    try server.addTool(.{ .name = "block", .description = "Wait for the cancellation" }, testBlock);
    try server.addTool(.{ .name = "steps", .description = "Send progress, then a result" }, testSteps);
    try server.addToolJson(.{ .name = "ask", .description = "Ask for a name" }, testAsk);
    try server.addToolJson(.{
        .name = "bare",
        .description = "An array without items",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"v\":{\"type\":\"array\"}}}",
    }, testAsk);
    return server;
}

fn destroyServer(server: *mcp.Server) void {
    const gpa = server.gpa;
    server.deinit();
    gpa.destroy(server);
}

fn testAdd(ctx: *mcp.RequestContext, args: struct { a: i64, b: i64 }) anyerror!mcp.Outcome(mcp.CallToolResult) {
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{d}", .{args.a + args.b}) };
}

fn testBlock(ctx: *mcp.RequestContext, args: struct {}) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        try ctx.checkCancel();
        try ctx.io.sleep(.fromMilliseconds(1), .awake);
    }
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "not canceled", .{}) };
}

fn testSteps(ctx: *mcp.RequestContext, args: struct { count: u32 }) anyerror!mcp.Outcome(mcp.CallToolResult) {
    var i: u32 = 0;
    while (i < args.count) : (i += 1) try ctx.progress(@floatFromInt(i + 1), @floatFromInt(args.count), null);
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{d} steps", .{args.count}) };
}

fn testAsk(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitForm("name", "Name?", try mcp.InputRequired.stringSchema(ctx.arena, "name", null, true));
    return .{ .input_required = ir };
}

fn expectError(v: Value, code: i64, cause: ?[]const u8) !void {
    const err = v.object.get("error") orelse return error.TestExpectedError;
    try testing.expectEqual(code, err.object.get("code").?.integer);
    if (cause) |c| try testing.expectEqualStrings(c, err.object.get("data").?.object.get("cause").?.string);
}

test "the lifecycle before initialize" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try testing.expectEqual(State.awaiting_initialize, b.frontend.state());
    try expectError(try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"), -32600, "not_initialized");
    try testing.expect((try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}")).object.get("result") != null);
    try testing.expect((try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"debug\"}}")).object.get("result") != null);
    try testing.expectEqual(types.LoggingLevel.debug, b.frontend.clientLogLevel().?);
    try expectError(try b.call(5, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"loud\"}}"), -32602, "invalid_params");
    // A client of two revisions: discover and a request with modern `_meta` get -32601.
    try expectError(try b.call(6, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}"), -32601, "method_not_found");
    try expectError(try b.call(7, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}"), -32601, "method_not_found");
    // A notification gets no answer.
    const before = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try testing.expectEqual(before, b.out.count());
    try testing.expectEqual(State.awaiting_initialize, b.frontend.state());
    // Initialize parameters that are not valid: the state stays `awaiting_initialize`.
    try expectError(try b.call(8, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"initialize\",\"params\":{}}"), -32602, "invalid_params");
    try testing.expectEqual(State.awaiting_initialize, b.frontend.state());
    try b.initialize();
}

test "the initialize result for VS Code, and a second initialize" {
    const b = try TestBridge.create(.{ .fallback_name = "fallback" });
    defer b.destroy();
    const v = try b.call(1, vscode_initialize);
    const result = v.object.get("result").?;
    try testing.expectEqualStrings("2025-11-25", result.object.get("protocolVersion").?.string);
    const caps = result.object.get("capabilities").?;
    try testing.expect(caps.object.get("tools") != null);
    try testing.expect(caps.object.get("tools").?.object.get("listChanged") == null);
    try testing.expect(caps.object.get("tasks") == null);
    try testing.expectEqualStrings("frontend-test", result.object.get("serverInfo").?.object.get("name").?.string);
    for ([_][]const u8{ "resultType", "ttlMs", "cacheScope", "_meta" }) |key| try testing.expect(result.object.get(key) == null);
    try testing.expectEqual(State.ready, b.frontend.state());
    // The upstream server got the client information of VS Code and no input capabilities.
    const upstream_options = b.upstream.conn.?.client.options;
    try testing.expectEqualStrings("Visual Studio Code", upstream_options.info.name);
    try testing.expect(upstream_options.capabilities.sampling == null);
    try testing.expect(upstream_options.capabilities.elicitation == null);
    try testing.expect(upstream_options.capabilities.roots == null);
    try testing.expect(upstream_options.capabilities.hasExtension("io.modelcontextprotocol/ui"));

    try expectError(try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{}}"), -32600, "already_initialized");
    try expectError(try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/discover\"}"), -32601, "method_not_found");
    try expectError(try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"x:/y\"}}"), -32601, "method_not_found");
    try expectError(try b.call(5, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tasks/list\"}"), -32601, "method_not_found");
}

test "two initialize requests at the same time give one result" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.send(vscode_initialize);
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"x\",\"version\":\"1\"}}}");
    try b.out.waitFor(2);
    try b.waitIdle();
    const arena = b.arena_state.allocator();
    try testing.expect((try b.out.byId(arena, 1)).object.get("result") != null);
    try expectError(try b.out.byId(arena, 2), -32600, "already_initialized");
    try testing.expectEqual(State.ready, b.frontend.state());
}

test "forwarded requests, results and errors" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try TestBridge.create(.{ .capability_mask = .{ .elicitation = true } });
    defer b.destroy();
    try b.initialize();
    const added = try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":3},\"_meta\":{\"vscode.requestId\":\"r\"}}}");
    const result = added.object.get("result").?;
    try testing.expectEqualStrings("5", result.object.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expect(result.object.get("resultType") == null);

    // The array schema without items gets `items: {}`.
    const list = try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"progressToken\":0}}}");
    var found = false;
    for (list.object.get("result").?.object.get("tools").?.array.items) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, "bare")) continue;
        const v = tool.object.get("inputSchema").?.object.get("properties").?.object.get("v").?;
        try testing.expect(v.object.get("items").? == .object);
        found = true;
    }
    try testing.expect(found);
    try testing.expect(list.object.get("result").?.object.get("nextCursor") == null);

    // An error of the upstream server goes to the client.
    try expectError(try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"none\"}}"), -32602, null);
    // The upstream server declares no completions.
    try expectError(try b.call(5, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"completion/complete\",\"params\":{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"x\"},\"argument\":{\"name\":\"a\",\"value\":\"\"}}}"), -32601, null);
    // An input request of the upstream server gets -32603 in this version.
    try expectError(try b.call(6, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}"), -32603, "input_required");
}

test "progress goes to the token of the client, and only with a token" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    _ = try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"steps\",\"arguments\":{\"count\":3},\"_meta\":{\"progressToken\":\"6b3c-uuid\",\"vscode.conversationId\":\"c\"}}}");
    _ = try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"steps\",\"arguments\":{\"count\":2},\"_meta\":{\"progressToken\":0}}}");
    _ = try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"steps\",\"arguments\":{\"count\":2}}}");
    const arena = b.arena_state.allocator();
    var uuid: usize = 0;
    var zero: usize = 0;
    var last_uuid: f64 = 0;
    var response_index: ?usize = null;
    b.out.lock.lockUncancelable(testing.io);
    defer b.out.lock.unlock(testing.io);
    for (b.out.frames.items, 0..) |f, i| {
        const v = try mcp.json.parseTree(arena, f);
        if (v.object.get("id")) |id| if (id.integer == 2) {
            response_index = i;
        };
        const method = v.object.get("method") orelse continue;
        try testing.expectEqualStrings("notifications/progress", method.string);
        const params = v.object.get("params").?;
        try testing.expect(params.object.get("_meta") == null);
        const token = params.object.get("progressToken").?;
        switch (token) {
            .string => |s| {
                try testing.expectEqualStrings("6b3c-uuid", s);
                // Each progress comes before the response.
                try testing.expect(response_index == null);
                uuid += 1;
                last_uuid = switch (params.object.get("progress").?) {
                    .integer => |n| @floatFromInt(n),
                    .float => |x| x,
                    else => return error.TestUnexpectedValue,
                };
            },
            .integer => |n| {
                try testing.expectEqual(@as(i64, 0), n);
                zero += 1;
            },
            else => return error.TestUnexpectedValue,
        }
    }
    try testing.expectEqual(@as(usize, 3), uuid);
    try testing.expectEqual(@as(f64, 3), last_uuid);
    try testing.expectEqual(@as(usize, 2), zero);
}

test "the reader rejects a request at the limit, and a canceled request gets no response" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try TestBridge.create(.{ .max_in_flight_requests = 1 });
    defer b.destroy();
    try b.initialize();
    const before = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"block\"}}");
    try testing.expectEqual(@as(usize, 1), b.frontend.inFlightCount());
    // The reader does not wait: the second request gets -32603 at once.
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":1,\"b\":1}}}");
    try testing.expectEqual(before + 1, b.out.count());
    const arena = b.arena_state.allocator();
    try expectError(try b.out.byId(arena, 3), -32603, "too_many_requests");
    // The reader still processes the cancellation and the ping.
    try b.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2,\"reason\":\"stop\"}}");
    try b.waitIdle();
    try testing.expect((try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}")).object.get("result") != null);
    try testing.expectError(error.TestFrameMissing, b.out.byId(arena, 2));
}

test "after the loss of the upstream server, a canceled request gets no response" {
    const io = testing.io;
    const gpa = testing.allocator;
    const server = try testServer(gpa, io);
    defer destroyServer(server);
    var link: mcp.transport.memory.ClientLink = .init(io, gpa, server);
    var hold: HoldTransport = .{ .inner = link.transport() };
    const upstream = try Upstream.init(io, gpa, .{ .transport = hold.transport() });
    defer upstream.deinit();
    var out: TestSink = .{ .io = io };
    defer out.deinit();
    var frontend: Frontend = .init(io, gpa, upstream, &TestBridge.profile, out.sink(), .{});
    defer frontend.deinit();
    // After a failed check, the held calls end before the stop of the front end.
    defer hold.release();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try frontend.receive(vscode_initialize);
    try out.waitFor(1);
    try waitUntilIdle(&frontend);
    try testing.expectEqual(State.ready, frontend.state());
    try frontend.receive("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":1,\"b\":1}}}");
    try frontend.receive("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":2}}}");
    try hold.waitHeld(2);
    // The client cancels request 2, but its task stays in flight.
    try frontend.receive("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}");
    try testing.expectEqual(@as(usize, 2), frontend.inFlightCount());
    // The upstream server stops in this window.
    frontend.failInFlight();
    hold.release();
    try waitUntilIdle(&frontend);
    try expectError(try out.byId(arena, 3), -32603, "upstream_exited");
    try testing.expectError(error.TestFrameMissing, out.byId(arena, 2));
    try testing.expectEqual(@as(usize, 2), out.count());
}

test "lines that are not valid get an error with the id of the request" {
    const b = try TestBridge.create(.{ .max_line_bytes = 1024, .json_max_depth = 10 });
    defer b.destroy();
    try b.initialize();
    // A lone surrogate escape, which std.json rejects.
    try expectError(try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"\\ud800\"}}"), -32700, "parse_error");
    try expectError(try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"a\":[[[[[[[[[[1]]]]]]]]]}}"), -32600, "too_deep");
    try expectError(try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"x\":\"" ++ "y" ** 1100 ++ "\"}}"), -32600, "line_too_long");
    // The TypeScript SDK 1.x writes the id last.
    try expectError(try b.call(8, "{\"method\":\"tools/call\",\"params\":{\"x\":\"" ++ "y" ** 1100 ++ "\"},\"jsonrpc\":\"2.0\",\"id\":8}"), -32600, "line_too_long");
    try expectError(try b.call(5, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"x\":\"\xff\"}}"), -32700, "parse_error");
    try expectError(try b.call(6, "{\"jsonrpc\":\"1.0\",\"id\":6,\"method\":\"ping\"}"), -32600, "invalid_request_shape");
    // Without an id, the error has the id null.
    const before = b.out.count();
    try b.send("not json");
    try b.out.waitFor(before + 1);
    b.out.lock.lockUncancelable(testing.io);
    const last = b.out.frames.items[b.out.frames.items.len - 1];
    b.out.lock.unlock(testing.io);
    try testing.expect(std.mem.indexOf(u8, last, "\"id\":null") != null);
    // Responses of the client and a bad line with the id of a request of the bridge get no
    // answer.
    const count = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}");
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"\\ud800\"}}");
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"error\":{\"code\":1,\"message\":\"m\"}}");
    try testing.expectEqual(count, b.out.count());
    try testing.expect((try b.call(7, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}")).object.get("result") != null);
}

test "a command that does not exist fails initialize, and the connection stays open" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const io = testing.io;
    const gpa = testing.allocator;
    const argv = [_][]const u8{"mcp-bridge-test-command-that-does-not-exist"};
    const upstream = try Upstream.init(io, gpa, .{ .stdio = .{ .argv = &argv } });
    defer upstream.deinit();
    var out: TestSink = .{ .io = io };
    defer out.deinit();
    var frontend: Frontend = .init(io, gpa, upstream, &TestBridge.profile, out.sink(), .{});
    defer frontend.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    for (0..2) |_| {
        const before = out.count();
        try frontend.receive(vscode_initialize);
        try out.waitFor(before + 1);
        try waitUntilIdle(&frontend);
        out.lock.lockUncancelable(io);
        const frame = out.frames.items[out.frames.items.len - 1];
        out.lock.unlock(io);
        try expectError(try mcp.json.parseTree(arena_state.allocator(), frame), -32603, "spawn_failed");
        try testing.expectEqual(State.awaiting_initialize, frontend.state());
    }
}

test "shutdown cancels the requests in flight and sends no response" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    var eof_calls: usize = 0;
    const Hook = struct {
        fn onEof(context: ?*anyopaque, upstream: *Upstream) void {
            _ = upstream;
            const n: *usize = @ptrCast(@alignCast(context.?));
            n.* += 1;
        }
    };
    b.frontend.options.hooks = .{ .context = &eof_calls, .on_eof = Hook.onEof };
    try b.initialize();
    const before = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"block\"}}");
    b.frontend.shutdown();
    b.frontend.shutdown();
    try testing.expectEqual(@as(usize, 1), eof_calls);
    try testing.expectEqual(State.closing, b.frontend.state());
    try testing.expectEqual(@as(usize, 0), b.frontend.inFlightCount());
    try testing.expectEqual(before, b.out.count());
    try testing.expect(b.upstream.conn == null);
    // After the end of the input, a request gets nothing.
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}");
    try testing.expectEqual(before, b.out.count());
}

test "run reads the lines until the end of the input" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    var in: Io.Reader = .fixed(vscode_initialize ++ "\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\r\n" ++
        "\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n");
    try testing.expectEqual(RunResult.eof, try b.frontend.run(&in));
    // The initialize task can still run when the ping comes. The ping gets its answer, and
    // the shutdown cancels the initialize.
    try testing.expect(b.out.has("\"id\":2,\"result\":{}"));
    try testing.expectEqual(State.closing, b.frontend.state());
}
