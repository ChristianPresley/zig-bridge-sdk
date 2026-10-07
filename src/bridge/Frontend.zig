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
//! - The front end sends the input requests of the upstream server to the client as requests
//!   with the string ids `<request_id_prefix><n>` (`input.zig` has the rules). A table keeps
//!   each such request until its answer. The reader puts each answer into the table at once,
//!   also at the limit of requests in flight. It drops an answer whose id is not in the table,
//!   because VS Code ignores a cancellation of the bridge and answers late.
//! - After `notifications/initialized`, a listen stream sends the list changes and the
//!   resource updates of the upstream server to the client (`notify.zig`).
//!   `resources/subscribe` and `resources/unsubscribe` change the URIs of the stream.
//! - Each upstream request has the log level of `logging/setLevel` and the `_meta` keys of the
//!   client that the profile allows. The log messages of the upstream server go to the client
//!   as `notifications/message` (`forwardLog`).
//!
//! A canceled request gets no response. Each task writes its frames under one lock, thus the
//! frames do not mix. This output lock is the last lock in each lock order.
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
const input = @import("input.zig");
const notify = @import("notify.zig");
const Upstream = @import("Upstream.zig");
const Profile = bridge.Profile;
const TimeLimit = translate.TimeLimit;

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
/// The requests of the bridge to the client that wait for their answers. Guarded by
/// `pending_lock`.
pending: std.ArrayList(*Pending) = .empty,
pending_lock: Io.Mutex = .init,
/// The number in the id of the next request of the bridge to the client.
next_request: std.atomic.Value(u64) = .init(1),
/// The number in the next `elicitationId` of a URL elicitation.
next_elicitation: std.atomic.Value(u64) = .init(1),
/// The listen stream of the notifications of the upstream server for the client.
listener: notify.Listener,
/// The notifications that the `initialize` result declares to the client. `runInitialize`
/// sets it before the state becomes `ready`.
declared: translate.Declared = .{},
/// True after the start of the listener. Guarded by `in_flight_lock`.
listening: bool = false,

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
    /// The first round of `prompts/get` and `resources/read`.
    read: Io.Duration = .fromSeconds(120),
    /// Each round of `tools/call`. The client can cancel a call earlier.
    call: Io.Duration = .fromSeconds(3600),
    /// The wait for the answers of the client to the input requests of one round. This limit
    /// also applies to each round after the first round of `prompts/get` and
    /// `resources/read`. A person gives these answers, thus the limit is long.
    input: Io.Duration = .fromSeconds(3600),

    /// The limit of the first round of `method`.
    pub fn forMethod(self: Timeouts, method: []const u8) Io.Duration {
        if (std.mem.eql(u8, method, "tools/call")) return self.call;
        if (std.mem.eql(u8, method, "prompts/get") or std.mem.eql(u8, method, "resources/read")) return self.read;
        return self.list;
    }

    /// The limit of the round `round` of `method`. The first round has the number 0.
    pub fn forRound(self: Timeouts, method: []const u8, round: u32) Io.Duration {
        if (round == 0 or std.mem.eql(u8, method, "tools/call")) return self.forMethod(method);
        return self.input;
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
    /// The maximum number of input requests in one round. A round with more input requests
    /// fails with -32603, and the client gets none of them.
    max_input_requests_per_round: u32 = input.default_max_requests_per_round,
    /// The first wait before a new listen stream after a loss. The wait doubles after each
    /// loss.
    listen_backoff: Io.Duration = .fromMilliseconds(500),
    /// The longest wait before a new listen stream after a loss.
    listen_max_backoff: Io.Duration = .fromSeconds(30),
    hooks: Hooks = .{},
};

const default_limits: mcp.Limits = .{};

/// The cancellation reason that goes to the upstream server when the client cancels a request.
const client_cancel_reason = "the client canceled the request";
/// The cancellation reason at the end of the input.
const eof_cancel_reason = "the client closed the connection";
/// The cancellation reason after the upstream server stopped.
const upstream_exit_reason = "the upstream server stopped";
/// The cancellation reason of a request of the bridge whose answer did not come in time.
const input_timeout_reason = "no answer in time";

/// A task that waits for the answers of the client also wakes after this time. The reader
/// and a cancellation wake it earlier.
const pending_poll_interval: Io.Duration = .fromMilliseconds(100);

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
    /// Wakes the task while it waits for the answers of the client: the reader sets it after
    /// an answer, and a cancellation sets it.
    wake: Io.Event = .unset,
    /// True while the task waits for the answers of the client and not for the upstream
    /// server. The watcher reads it for its log line.
    waiting_for_client: std.atomic.Value(bool) = .init(false),
};

/// A request of the bridge to the client that waits for its answer. This is the pending table
/// of `mcp.transport.stdio.Client`, for the requests in the other direction. The task of the
/// request registers the entry before it writes the request, and it unregisters the entry on
/// each path out. Thus the reader never sees an entry that is not valid.
const Pending = struct {
    /// The id, for example "b-1".
    id: []const u8,
    /// The `wake` event of the slot. The reader sets it after it resolved the entry.
    wake: *Io.Event,
    /// A copy of the response line in `gpa`. The reader sets it.
    frame: ?[]u8 = null,
    /// True after a line with the id of the entry that is not a valid message.
    bad_line: bool = false,
    /// True after the request went out. Only the task of the request reads and writes it. A
    /// cancellation must only name a request that the client got.
    sent: bool = false,

    fn resolved(self: *const Pending) bool {
        return self.frame != null or self.bad_line;
    }
};

pub fn init(io: Io, gpa: Allocator, upstream: *Upstream, profile: *const Profile, sink: Sink, options: Options) Frontend {
    return .{
        .io = io,
        .gpa = gpa,
        .upstream = upstream,
        .profile = profile,
        .sink = sink,
        .options = options,
        .listener = .init(io, gpa, upstream),
    };
}

/// Stop the requests in flight, and release the memory of the front end. The function does
/// not release the upstream.
pub fn deinit(self: *Frontend) void {
    self.shutdown();
    self.listener.deinit();
    self.in_flight.deinit(self.gpa);
    self.pending.deinit(self.gpa);
}

/// The number of requests of the bridge that wait for an answer of the client.
pub fn pendingCount(self: *Frontend) usize {
    self.pending_lock.lockUncancelable(self.io);
    defer self.pending_lock.unlock(self.io);
    return self.pending.items.len;
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

/// The number of requests in flight that wait for the answers of the client to their input
/// requests.
pub fn waitingForClientCount(self: *Frontend) usize {
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    var n: usize = 0;
    for (self.in_flight.items) |slot| n += @intFromBool(slot.waiting_for_client.load(.acquire));
    return n;
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
            error.InvalidId => {
                // A response with the id null, or with an id that is not a string or an
                // integer, belongs to no request of the bridge. It gets no answer.
                if (isResponse(arena, line)) return log.debug("dropped a response of the client with an id that is not valid", .{});
                self.writeError(null, translate.errorFor(.invalid_request_shape, null));
            },
        }
        return;
    };
    switch (msg) {
        .request => |req| self.handleRequest(slot, req),
        .notification => |n| {
            defer self.destroySlot(slot);
            self.handleNotification(arena, n);
        },
        .response => |r| {
            defer self.destroySlot(slot);
            self.routeAnswer(r.id, .{ .frame = line });
        },
        .error_response => |e| {
            defer self.destroySlot(slot);
            const id = e.id orelse return log.debug("dropped an error response of the client without an id", .{});
            self.routeAnswer(id, .{ .frame = line });
        },
    }
}

/// True when `line` is a JSON object with `result` or `error` and without `method`.
fn isResponse(arena: Allocator, line: []const u8) bool {
    const v = mcp.json.parseTree(arena, line) catch return false;
    if (v != .object or v.object.get("method") != null) return false;
    return v.object.get("result") != null or v.object.get("error") != null;
}

/// An answer of the client for the pending table.
const Resolution = union(enum) {
    /// The line of a response or an error response.
    frame: []const u8,
    /// A line with the id that is not a valid message.
    bad_line,
};

/// Give the answer of the client to the request of the bridge with the id `id`. The function
/// drops an answer whose id is not a string with the prefix of the profile. It also drops an
/// answer for an id that is not in the table, and a second answer. The reader calls it,
/// thus it never waits for a slot.
fn routeAnswer(self: *Frontend, id: RequestId, resolution: Resolution) void {
    if (id != .string or !std.mem.startsWith(u8, id.string, self.profile.request_id_prefix)) {
        log.debug("dropped a response of the client with the id {f}: the bridge sent no request with this id", .{id});
        return;
    }
    if (!self.resolvePending(id.string, resolution)) {
        log.debug("dropped a response of the client with the id {f}: the request is not in flight or has an answer", .{id});
    }
}

/// Resolve the entry with the id `id`, and wake its task. Returns false when the table has no
/// such entry without an answer.
fn resolvePending(self: *Frontend, id: []const u8, resolution: Resolution) bool {
    self.pending_lock.lockUncancelable(self.io);
    defer self.pending_lock.unlock(self.io);
    for (self.pending.items) |p| {
        if (!std.mem.eql(u8, p.id, id)) continue;
        if (p.resolved()) return false;
        switch (resolution) {
            .frame => |line| p.frame = self.gpa.dupe(u8, line) catch {
                // Without memory, the answer counts as a line that is not valid.
                p.bad_line = true;
                p.wake.set(self.io);
                return true;
            },
            .bad_line => p.bad_line = true,
        }
        p.wake.set(self.io);
        return true;
    }
    return false;
}

/// Put all entries into the table, or none of them.
fn registerPending(self: *Frontend, entries: []Pending) Allocator.Error!void {
    self.pending_lock.lockUncancelable(self.io);
    defer self.pending_lock.unlock(self.io);
    try self.pending.ensureUnusedCapacity(self.gpa, entries.len);
    for (entries) |*p| self.pending.appendAssumeCapacity(p);
}

/// Remove the entries from the table. After this step, the reader does not change them.
fn unregisterPending(self: *Frontend, entries: []Pending) void {
    self.pending_lock.lockUncancelable(self.io);
    defer self.pending_lock.unlock(self.io);
    for (entries) |*p| {
        for (self.pending.items, 0..) |item, i| if (item == p) {
            _ = self.pending.swapRemove(i);
            break;
        };
    }
}

/// True when each entry has an answer.
fn allResolved(self: *Frontend, entries: []const Pending) bool {
    self.pending_lock.lockUncancelable(self.io);
    defer self.pending_lock.unlock(self.io);
    for (entries) |*p| if (!p.resolved()) return false;
    return true;
}

/// The number of entries without an answer.
fn unresolvedCount(self: *Frontend, entries: []const Pending) usize {
    self.pending_lock.lockUncancelable(self.io);
    defer self.pending_lock.unlock(self.io);
    var n: usize = 0;
    for (entries) |*p| n += @intFromBool(!p.resolved());
    return n;
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

/// Answer a line that is not valid with the id `id`, or with the id null. A line with the id
/// of a request of the bridge is an answer of the client that is not valid. It gets no
/// answer, and the request of the bridge gets it as its answer.
fn answerBadLine(self: *Frontend, id: ?RequestId, cause: translate.Cause) void {
    if (id) |i| if (i == .string and std.mem.startsWith(u8, i.string, self.profile.request_id_prefix)) {
        log.debug("the client answered request {f} with a line that is not valid: {t}", .{ i, cause });
        self.routeAnswer(i, .bad_line);
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
            switch (slot.kind) {
                .forwarded => _ = self.admit(slot),
                // Only a running listener can change the URIs. It starts at
                // `notifications/initialized` when the result declares `resources.subscribe`.
                .subscribe, .unsubscribe => if (self.declared.resources_subscribe and self.listener.isRunning()) {
                    _ = self.admit(slot);
                } else self.errorInline(slot, translate.errorFor(.method_not_found, null)),
                else => self.errorInline(slot, translate.errorFor(.method_not_found, null)),
            }
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
        .initialized => {
            log.debug("the client sent notifications/initialized", .{});
            self.startListener();
        },
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
                cancelSlot(self.io, slot, client_cancel_reason);
                return;
            }
        },
    }
}

/// Start the listen stream after `notifications/initialized`, when the `initialize` result
/// declares a list change or `resources.subscribe`. The start happens under `in_flight_lock`,
/// thus `stopAdmission` sees it. A second `notifications/initialized`, and one before the
/// `initialize` result, start nothing.
fn startListener(self: *Frontend) void {
    if (self.lifecycle.load(.acquire) != .ready) return log.debug("ignored notifications/initialized: the connection is not ready", .{});
    const d = self.declared;
    if (!d.listens()) return;
    self.in_flight_lock.lockUncancelable(self.io);
    defer self.in_flight_lock.unlock(self.io);
    if (!self.admitting or self.listening) return;
    self.listening = true;
    self.listener.start(&self.group, .{ .context = self, .vtable = &host_vtable }, .{
        .tools = d.tools_list_changed,
        .prompts = d.prompts_list_changed,
        .resources = d.resources_list_changed,
        .backoff = self.options.listen_backoff,
        .max_backoff = self.options.listen_max_backoff,
    }) catch |e| log.warn("cannot start the listen stream: {t}. The client gets no list changes.", .{e});
}

/// The functions of the front end for the listener.
const host_vtable: notify.Host.VTable = .{ .write = hostWrite, .writeIf = hostWriteIf, .logLevel = hostLogLevel };

fn hostWrite(context: *anyopaque, frame: []const u8) void {
    const self: *Frontend = @ptrCast(@alignCast(context));
    self.writeFrame(frame);
}

fn hostWriteIf(context: *anyopaque, frame: []const u8, active: *const std.atomic.Value(u64), generation: u64) bool {
    const self: *Frontend = @ptrCast(@alignCast(context));
    self.out_lock.lockUncancelable(self.io);
    defer self.out_lock.unlock(self.io);
    if (active.load(.acquire) != generation) return false;
    self.writeLocked(frame);
    return true;
}

fn hostLogLevel(context: *anyopaque) ?types.LoggingLevel {
    const self: *Frontend = @ptrCast(@alignCast(context));
    return self.clientLogLevel();
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
        .subscribe, .unsubscribe => self.runSubscribe(slot),
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
    // On stdio, the log messages of the upstream server belong to no request.
    self.upstream.on_log = .{ .context = self, .call = upstreamLog };
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
        .log_level = self.clientLogLevel(),
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
    self.declared = translate.declared(raw, self.options.reply_mask);
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

/// Send a request of the client to the upstream server and answer the client. When the
/// upstream server asks for input, the task asks the client (`input.Session`) and sends the
/// request again with the answers. It does so until a complete result or an error, at most
/// `Upstream.maxRounds` rounds. The progress of each round goes to the token of the client.
///
/// Each path out calls `Session.finish` or `Session.observe` before the response. Thus the
/// client gets `notifications/elicitation/complete` for each URL that the user accepted.
fn runForward(self: *Frontend, slot: *Slot) void {
    const arena = slot.arena.allocator();
    const fwd = translate.forwardParams(arena, slot.params, self.profile) catch
        return self.respondError(slot, translate.errorFor(.out_of_memory, null));
    slot.progress_token = fwd.progress_token;
    var session: input.Session = .{
        .arena = arena,
        .io = self.io,
        .capabilities = self.upstream.clientCapabilities() orelse .{},
        .peer = .{ .context = slot, .vtable = &peer_vtable },
        .options = .{
            .max_requests_per_round = self.options.max_input_requests_per_round,
            .timeout = self.options.timeouts.input,
            .schema_limits = self.upstream.schemaLimits(),
        },
    };
    const max_rounds = self.upstream.maxRounds();
    var params = fwd.params;
    var has_state = false;
    var round: u32 = 0;
    while (true) : (round += 1) {
        var diag: mcp.Client.Diagnostics = .{};
        const timeout = self.options.timeouts.forRound(slot.method, round);
        const raw = self.upstream.request(arena, slot.method, params, .{
            .cancel = &slot.token,
            .timeout = timeout,
            .callbacks = .{
                .context = slot,
                .progress = if (fwd.progress_token != null) onProgress else null,
                .log = onLog,
            },
            .diagnostics = &diag,
            .client_id = slot.id,
            // A change of the level reaches the next round.
            .log_level = self.clientLogLevel(),
            .meta = fwd.meta,
        }) catch |e| {
            if (e == error.Rpc and has_state) if (diag.rpc_error) |rpc| if (input.isRejectedState(rpc)) {
                return self.rejectedState(slot, &session, rpc);
            };
            return self.failForward(slot, &session, e, diag, timeout);
        };
        // The client gets the complete notification of an accepted URL before the response.
        session.observe(raw);
        if (!translate.isInputRequired(raw)) return self.finishForward(slot, raw);
        if (round + 1 >= max_rounds) {
            log.warn("request {f} ({s}): the upstream server asked for input in {d} rounds", .{ slot.id, slot.method, round + 1 });
            self.logOutcome(slot, "TooManyRounds");
            return self.failRounds(slot, &session, translate.errorFor(.too_many_rounds, null));
        }
        const outcome = session.round(raw) catch
            return self.failRounds(slot, &session, translate.errorFor(.out_of_memory, null));
        switch (outcome) {
            .retry => |retry| {
                params = input.retryParams(arena, fwd.params, retry) catch
                    return self.failRounds(slot, &session, translate.errorFor(.out_of_memory, null));
                has_state = retry.request_state != null;
                log.debug("request {f} ({s}): round {d} has the answers of the client after {d} ms", .{ slot.id, slot.method, round + 1, session.last_wait.toMilliseconds() });
            },
            .fail => |err| {
                if (err.cause == null) {
                    // The error of the client goes to the original request, for example the
                    // refusal of a sampling request by the user. This is not a fault.
                    log.info("request {f} ({s}): the client answered an input request with an error: {s}", .{ slot.id, slot.method, err.message });
                } else {
                    log.warn("request {f} ({s}): the input requests of the upstream server failed: {s}", .{ slot.id, slot.method, err.detail orelse err.message });
                }
                self.logOutcome(slot, "input failed");
                return self.failRounds(slot, &session, err);
            },
            .canceled => {
                session.finish();
                return self.logOutcome(slot, "Canceled");
            },
        }
    }
}

/// Answer the client with `err` after the rounds stopped.
fn failRounds(self: *Frontend, slot: *Slot, session: *input.Session, err: translate.RpcError) void {
    session.finish();
    self.respondError(slot, err);
}

/// Answer the client after a failed upstream request.
fn failForward(self: *Frontend, slot: *Slot, session: *input.Session, e: Upstream.RequestError, diag: mcp.Client.Diagnostics, timeout: Io.Duration) void {
    const arena = slot.arena.allocator();
    const cause = translate.causeOf(e);
    self.logOutcome(slot, @errorName(e));
    session.finish();
    if (!translate.hasResponse(cause)) return;
    const err: translate.RpcError = switch (cause) {
        .rpc => if (diag.rpc_error) |rpc| translate.fromUpstream(rpc) else translate.errorFor(.rpc, null),
        .timeout => translate.errorFor(.timeout, std.fmt.allocPrint(arena, "{s}: no response in {f}", .{ slot.method, TimeLimit{ .duration = timeout } }) catch null),
        .closed => translate.errorFor(if (self.upstream.gone()) .upstream_exited else .closed, null),
        else => translate.errorFor(cause, null),
    };
    if (cause == .timeout) log.warn("request {f} ({s}): no response in {f}", .{ slot.id, slot.method, TimeLimit{ .duration = timeout } });
    self.respondError(slot, err);
}

/// Answer the client after the upstream server refused the `requestState` of a round.
fn rejectedState(self: *Frontend, slot: *Slot, session: *input.Session, rpc: types.Error) void {
    const arena = slot.arena.allocator();
    log.warn("request {f} ({s}): the upstream server refused the request state after an input wait of {f}", .{ slot.id, slot.method, TimeLimit{ .duration = session.last_wait } });
    self.logOutcome(slot, "request state refused");
    session.finish();
    const rejected = input.rejectedState(arena, slot.method, rpc) catch
        return self.respondError(slot, translate.errorFor(.out_of_memory, null));
    switch (rejected) {
        .result => |result| self.respond(slot, result),
        .rpc_error => |err| self.respondError(slot, err),
    }
}

/// Answer the client with the complete result `raw` of the upstream server.
fn finishForward(self: *Frontend, slot: *Slot, raw: Value) void {
    const arena = slot.arena.allocator();
    const shaped = translate.shapeResult(arena, slot.method, raw, self.profile) catch
        return self.respondError(slot, translate.errorFor(.out_of_memory, null));
    for (shaped.fixes) |fix| switch (fix.kind) {
        .too_deep => log.info("tool '{s}': the input schema at '{s}' is too deep to examine", .{ fix.tool, fix.pointer }),
        else => log.info("tool '{s}': added an items schema at '{s}' of the input schema", .{ fix.tool, fix.pointer }),
    };
    self.logOutcome(slot, "ok");
    self.respond(slot, shaped.result);
}

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
    _ = self.writeForSlot(slot, frame, .notification);
}

/// A log message that the transport routed to a request, for example on the memory link.
fn onLog(context: ?*anyopaque, params: types.LoggingMessageNotificationParams) void {
    const slot: *Slot = @ptrCast(@alignCast(context.?));
    slot.owner.forwardLog(params);
}

/// A log message of a stdio upstream server. It runs on the reader task of the upstream
/// client.
fn upstreamLog(context: *anyopaque, params: types.LoggingMessageNotificationParams) void {
    const self: *Frontend = @ptrCast(@alignCast(context));
    self.forwardLog(params);
}

/// Send a log message of the upstream server to the client as `notifications/message` of
/// revision 2025-11-25. The function drops a message below the level of the client. The
/// upstream server filters with the level of each request, but a request can start before a
/// change of the level. The function only translates and writes under the output lock, thus
/// the reader task of the upstream client can call it.
pub fn forwardLog(self: *Frontend, params: types.LoggingMessageNotificationParams) void {
    if (self.clientLogLevel()) |min| if (params.level.severity() < min.severity()) return;
    const frame = mcp.json.writeAlloc(self.gpa, mcp.jsonrpc.message.OutNotification(translate.LogMessage){
        .method = "notifications/message",
        .params = translate.logMessage(params),
    }) catch return log.debug("dropped a log message of the upstream server: no memory", .{});
    defer self.gpa.free(frame);
    self.writeFrame(frame);
}

/// Add the URI of `resources/subscribe` to the listen stream, or remove the URI of
/// `resources/unsubscribe`. The listener writes the response (`notify.Change`).
fn runSubscribe(self: *Frontend, slot: *Slot) void {
    const params = legacy.parseSubscribeParams(slot.arena.allocator(), slot.params) catch |e| {
        const cause: translate.Cause = if (e == error.OutOfMemory) .out_of_memory else .invalid_params;
        return self.respondError(slot, translate.errorFor(cause, null));
    };
    var change: notify.Change = .{
        .kind = if (slot.kind == .subscribe) .subscribe else .unsubscribe,
        .uri = params.uri,
        .respond = .{ .context = slot, .ok = subscribeOk, .fail = subscribeFail },
    };
    self.listener.change(&change);
    // A canceled change has no response. After the end of the input, or after the loss of
    // the upstream server, the slot drops this error.
    if (change.outcome == .canceled) self.respondError(slot, translate.errorFor(.closed, "subscriptions/listen"));
    self.logOutcome(slot, @tagName(change.outcome));
}

fn subscribeOk(context: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    slot.owner.respond(slot, .{ .object = .empty });
}

fn subscribeFail(context: *anyopaque, err: translate.RpcError) void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    slot.owner.respondError(slot, err);
}

// ---------------------------------------------------------------------------------------------
// Requests of the bridge to the client
// ---------------------------------------------------------------------------------------------

/// The functions of the front end for `input.Session`. The context is the slot of the original
/// request.
const peer_vtable: input.Peer.VTable = .{ .ask = askClient, .notify = notifyClient, .newElicitationId = newElicitationId };

/// Send each question to the client as a request with a new id, and wait for all answers.
/// All entries go into the pending table before the first request goes out. Thus a failure
/// before the requests go out leaves no request without an entry.
///
/// The task wakes when the reader resolves an entry, when the client cancels the request, and
/// after `pending_poll_interval`. On a cancellation, at the end of the input and at the end of
/// `timeout`, the task first removes its entries from the table. Then it sends
/// `notifications/cancelled` for each request that went out and has no answer. VS Code
/// ignores this notification, and the reader drops its late answer.
fn askClient(context: *anyopaque, arena: Allocator, questions: []const input.Question, answers: []input.Answer, timeout: Io.Duration) input.AskError!void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    const self = slot.owner;
    const io = self.io;
    const entries = try arena.alloc(Pending, questions.len);
    const frames = try arena.alloc([]const u8, questions.len);
    for (questions, entries, frames) |q, *p, *frame| {
        const n = self.next_request.fetchAdd(1, .monotonic);
        p.* = .{ .id = try std.fmt.allocPrint(arena, "{s}{d}", .{ self.profile.request_id_prefix, n }), .wake = &slot.wake };
        frame.* = try mcp.json.writeAlloc(arena, mcp.jsonrpc.message.OutRequest(?Value){ .id = .{ .string = p.id }, .method = q.method, .params = q.params });
    }
    // The client can cancel the request during the checks of the round. Then no request
    // goes out.
    if (slot.token.isCancelled()) return error.Canceled;
    try self.registerPending(entries);
    defer self.releasePending(entries);
    // A cancellation, or the error after the loss of the upstream server, can come between
    // two writes. Then `writeForSlot` drops the frames from that point, and their entries are
    // not `sent`.
    for (questions, entries, frames) |q, *p, frame| {
        p.sent = self.writeForSlot(slot, frame, .notification);
        if (p.sent) log.debug("request {f} ({s}): sent {s} to the client as request \"{s}\"", .{ slot.id, slot.method, q.method, p.id });
    }
    slot.waiting_for_client.store(true, .release);
    defer slot.waiting_for_client.store(false, .release);
    const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = timeout, .clock = .awake });
    while (true) {
        slot.wake.reset();
        if (self.allResolved(entries)) break;
        if (slot.token.isCancelled()) {
            self.cancelPending(entries, slot.token.reason orelse client_cancel_reason);
            return error.Canceled;
        }
        const left = Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw;
        if (left.nanoseconds <= 0) {
            log.warn("request {f} ({s}): no answers of the client in {f} (input requests without an answer: {d} of {d})", .{ slot.id, slot.method, TimeLimit{ .duration = timeout }, self.unresolvedCount(entries), entries.len });
            self.cancelPending(entries, input_timeout_reason);
            return error.Timeout;
        }
        const wait: Io.Duration = if (left.nanoseconds < pending_poll_interval.nanoseconds) left else pending_poll_interval;
        slot.wake.waitTimeout(io, .{ .duration = .{ .raw = wait, .clock = .awake } }) catch |e| switch (e) {
            error.Timeout => {},
            error.Canceled => {
                self.cancelPending(entries, eof_cancel_reason);
                return error.Canceled;
            },
        };
    }
    self.unregisterPending(entries);
    for (entries, answers) |*p, *answer| answer.* = try parseAnswer(arena, p);
}

/// The answer of the client in a resolved entry, parsed in `arena`.
fn parseAnswer(arena: Allocator, p: *const Pending) Allocator.Error!input.Answer {
    const frame = p.frame orelse return .bad_line;
    const msg = Message.parse(arena, frame) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .bad_line,
    };
    return switch (msg) {
        .response => |r| .{ .result = r.result },
        .error_response => |e| .{ .rpc_error = .{ .code = e.code, .message = e.message, .data = e.data } },
        .request, .notification => .bad_line,
    };
}

/// Remove the entries from the table, then send `notifications/cancelled` for each entry
/// that went out and has no answer. The notification goes out also after a cancellation of
/// the original request.
fn cancelPending(self: *Frontend, entries: []Pending, reason: []const u8) void {
    self.unregisterPending(entries);
    for (entries) |*p| {
        if (p.resolved() or !p.sent) continue;
        log.debug("canceled request \"{s}\" to the client: {s}", .{ p.id, reason });
        const frame = mcp.json.writeAlloc(self.gpa, mcp.jsonrpc.message.OutNotification(CancelledParams){
            .method = "notifications/cancelled",
            .params = .{ .requestId = p.id, .reason = reason },
        }) catch continue;
        defer self.gpa.free(frame);
        self.writeFrame(frame);
    }
}

/// The `params` of a `notifications/cancelled` to the client.
const CancelledParams = struct {
    requestId: []const u8,
    reason: []const u8,
};

/// Remove the entries from the table and free the copies of the answers. Each path out of
/// `askClient` calls it. After `unregisterPending`, it only frees the copies.
fn releasePending(self: *Frontend, entries: []Pending) void {
    self.unregisterPending(entries);
    for (entries) |*p| if (p.frame) |f| {
        self.gpa.free(f);
        p.frame = null;
    };
}

/// Send a notification of the input requests of the slot. After a cancellation, the
/// notification still goes out, as `notifications/cancelled` does. Thus the client can
/// close the parts of the request that it shows, for example an accepted URL.
fn notifyClient(context: *anyopaque, method: []const u8, params: Value) void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    const self = slot.owner;
    const frame = mcp.json.writeAlloc(self.gpa, mcp.jsonrpc.message.OutNotification(Value){ .method = method, .params = params }) catch return;
    defer self.gpa.free(frame);
    if (slot.token.isCancelled()) return self.writeFrame(frame);
    _ = self.writeForSlot(slot, frame, .notification);
}

fn newElicitationId(context: *anyopaque, arena: Allocator) Allocator.Error![]const u8 {
    const slot: *Slot = @ptrCast(@alignCast(context));
    const n = slot.owner.next_elicitation.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(arena, "elicitation-{d}", .{n});
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
/// check of `answered` and the write are one step. A canceled request gets no frame. Returns
/// true when the sink took the frame.
fn writeForSlot(self: *Frontend, slot: *Slot, frame: []const u8, kind: FrameKind) bool {
    self.out_lock.lockUncancelable(self.io);
    defer self.out_lock.unlock(self.io);
    if (self.closed.load(.acquire) or slot.answered or slot.token.isCancelled()) return false;
    if (kind == .response) slot.answered = true;
    self.sink.write(self.sink.ptr, frame) catch |e| {
        log.debug("cannot write a frame: {t}", .{e});
        return false;
    };
    return true;
}

fn respond(self: *Frontend, slot: *Slot, result: Value) void {
    const frame = mcp.json.writeAlloc(self.gpa, mcp.jsonrpc.message.OutResponse(Value){ .id = slot.id, .result = result }) catch
        return self.respondError(slot, translate.errorFor(.out_of_memory, null));
    defer self.gpa.free(frame);
    _ = self.writeForSlot(slot, frame, .response);
}

fn respondError(self: *Frontend, slot: *Slot, err: translate.RpcError) void {
    var buf: [1024]u8 = undefined;
    const frame = self.errorFrame(&buf, slot.id, err) orelse return;
    defer frame.deinit(self.gpa);
    _ = self.writeForSlot(slot, frame.text, .response);
}

/// Write a frame that belongs to no slot task.
fn writeFrame(self: *Frontend, frame: []const u8) void {
    self.out_lock.lockUncancelable(self.io);
    defer self.out_lock.unlock(self.io);
    self.writeLocked(frame);
}

/// Write a frame that belongs to no slot task. The caller holds `out_lock`.
fn writeLocked(self: *Frontend, frame: []const u8) void {
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
        // While the client has the input requests of a round, no upstream request is in
        // flight. A person can take a long time to answer.
        if (slot.waiting_for_client.load(.acquire)) {
            log.info("still waiting for the answers of the client to the input requests of {s} (request {f}, {d} s)", .{ slot.method, slot.id, waited_s });
            continue;
        }
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
    self.listener.stop();
    // This task is in the group, thus it cannot wait for the group. The requests and the
    // listen stream fail at once, because the client of the upstream server is closed.
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
        cancelSlot(self.io, slot, upstream_exit_reason);
    }
}

/// Cancel the request of `slot`, and wake its task when it waits for the answers of the
/// client.
fn cancelSlot(io: Io, slot: *Slot, reason: []const u8) void {
    slot.token.cancel(io, reason);
    slot.wake.set(io);
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
    for (self.in_flight.items) |slot| cancelSlot(self.io, slot, reason);
}

/// Wait until no request is in flight and the listener stopped, at most `grace`. Returns false
/// at the end of `grace`.
fn waitForSlots(self: *Frontend, grace: Io.Duration) bool {
    const io = self.io;
    const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = grace, .clock = .awake });
    while (self.inFlightCount() > 0 or self.listener.isRunning()) {
        if (Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw.nanoseconds <= 0) return false;
        io.sleep(.fromMilliseconds(5), .awake) catch return false;
    }
    return true;
}

/// Stop the connection. The function stops the admission, cancels each request in flight and
/// stops the listener. It waits for them for at most `shutdown_grace`, then it cancels the
/// tasks that are left and closes the upstream. Thus the listen stream ends before the
/// upstream client closes. The function does nothing the second time. `run` calls it at the
/// end of the input.
pub fn shutdown(self: *Frontend) void {
    if (self.shut_down) return;
    self.shut_down = true;
    self.stop();
    self.lifecycle.store(.closing, .release);
    if (!self.upstream_lost.load(.acquire)) if (self.options.hooks.on_eof) |f| f(self.options.hooks.context, self.upstream);
    self.stopAdmission();
    self.cancelAll(eof_cancel_reason);
    self.listener.stop();
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

test "the timeouts by method" {
    const t: Timeouts = .{};
    try testing.expectEqual(@as(i64, 3600), t.forMethod("tools/call").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("resources/read").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("prompts/get").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("tools/list").toSeconds());
    try testing.expectEqual(@as(i64, 120), t.forMethod("completion/complete").toSeconds());
    // The rounds after the first round of a read wait for a person, thus they get the limit
    // of the input.
    const short: Timeouts = .{ .read = .fromSeconds(5), .call = .fromSeconds(7), .input = .fromSeconds(9) };
    try testing.expectEqual(@as(i64, 5), short.forRound("prompts/get", 0).toSeconds());
    try testing.expectEqual(@as(i64, 9), short.forRound("prompts/get", 1).toSeconds());
    try testing.expectEqual(@as(i64, 9), short.forRound("resources/read", 3).toSeconds());
    try testing.expectEqual(@as(i64, 7), short.forRound("tools/call", 0).toSeconds());
    try testing.expectEqual(@as(i64, 7), short.forRound("tools/call", 2).toSeconds());
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

    /// The frames with the method `method`, parsed in `arena`. A request has an id, a
    /// notification has none.
    fn withMethod(self: *TestSink, arena: Allocator, method: []const u8) ![]Value {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var out: std.ArrayList(Value) = .empty;
        for (self.frames.items) |f| {
            const v = try mcp.json.parseTree(arena, f);
            const m = mcp.json.getString(v, "method") orelse continue;
            if (std.mem.eql(u8, m, method)) try out.append(arena, v);
        }
        return out.items;
    }

    /// Wait until there are `n` frames with the method `method`, at most five seconds. Return
    /// the last of them.
    fn waitMethod(self: *TestSink, arena: Allocator, method: []const u8, n: usize) !Value {
        var i: usize = 0;
        while (true) : (i += 1) {
            const found = try self.withMethod(arena, method);
            if (found.len >= n) return found[n - 1];
            if (i > 5000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

/// The response line of the client for the request `request` of the bridge.
fn answerLine(arena: Allocator, request: Value, result: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"result\":{s}}}", .{ request.object.get("id").?.string, result });
}

/// The error response line of the client for the request `request` of the bridge.
fn errorLine(arena: Allocator, request: Value, err: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"error\":{s}}}", .{ request.object.get("id").?.string, err });
}

/// Wait until the bridge has no request to the client that waits for an answer, at most five
/// seconds.
fn waitNoPending(frontend: *Frontend) !void {
    var i: usize = 0;
    while (frontend.pendingCount() > 0) : (i += 1) {
        if (i > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

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
    const vtable: Transport.ClientTransport.VTable = .{ .kind = .memory, .exchange = exchange, .notify = onNotify };

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

    fn onNotify(ptr: *anyopaque, io: Io, frame: []const u8) Transport.SendError!void {
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

/// A client transport of an upstream server that the test scripts. It answers
/// `server/discover` with a fixed result, and each other request with the next item of
/// `script`. An item is a result object as JSON text, or an error object with the prefix
/// "error:". After the last item, a request fails with `error.Closed`.
const ScriptTransport = struct {
    script: []const []const u8,
    lock: Io.Mutex = .init,
    /// The number of requests after `server/discover`. Guarded by `lock`.
    requests: usize = 0,

    const Transport = mcp.transport.Transport;
    const vtable: Transport.ClientTransport.VTable = .{ .kind = .memory, .exchange = exchange, .notify = onNotify };
    const discover_result =
        \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"prompts":{}}}
    ;

    fn transport(self: *ScriptTransport) Transport.ClientTransport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn count(self: *ScriptTransport) usize {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return self.requests;
    }

    fn exchange(ptr: *anyopaque, io: Io, ex: *Transport.Exchange) Transport.ExchangeError!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        const item = if (std.mem.eql(u8, ex.method, "server/discover")) discover_result else item: {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            if (self.requests >= self.script.len) return error.Closed;
            defer self.requests += 1;
            break :item self.script[self.requests];
        };
        const is_error = std.mem.startsWith(u8, item, "error:");
        const body = if (is_error) item["error:".len..] else item;
        const id = mcp.json.writeAlloc(testing.allocator, ex.id) catch return error.OutOfMemory;
        defer testing.allocator.free(id);
        const frame = std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"{s}\":{s}}}", .{ id, if (is_error) "error" else "result", body }) catch return error.OutOfMemory;
        defer testing.allocator.free(frame);
        ex.deliver(io, frame) catch return error.InvalidFrame;
    }

    fn onNotify(ptr: *anyopaque, io: Io, frame: []const u8) Transport.SendError!void {
        _ = .{ ptr, io, frame };
    }
};

/// A front end with a scripted upstream server.
const ScriptBridge = struct {
    script: ScriptTransport,
    upstream: *Upstream,
    out: TestSink,
    frontend: Frontend,
    arena_state: std.heap.ArenaAllocator,

    fn create(script: []const []const u8, options: Options) !*ScriptBridge {
        const io = testing.io;
        const gpa = testing.allocator;
        const self = try gpa.create(ScriptBridge);
        errdefer gpa.destroy(self);
        self.script = .{ .script = script };
        self.upstream = try Upstream.init(io, gpa, .{ .transport = self.script.transport() });
        self.out = .{ .io = io };
        self.frontend = .init(io, gpa, self.upstream, &TestBridge.profile, self.out.sink(), options);
        self.arena_state = .init(gpa);
        try self.frontend.receive(vscode_initialize);
        try self.out.waitFor(1);
        try waitUntilIdle(&self.frontend);
        try testing.expectEqual(State.ready, self.frontend.state());
        return self;
    }

    fn destroy(self: *ScriptBridge) void {
        self.frontend.deinit();
        self.upstream.deinit();
        self.out.deinit();
        self.arena_state.deinit();
        testing.allocator.destroy(self);
    }

    fn arena(self: *ScriptBridge) Allocator {
        return self.arena_state.allocator();
    }
};

/// Wait for the response with the id `id`, at most five seconds.
fn waitResponse(out: *TestSink, arena: Allocator, id: i64) !Value {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (out.byId(arena, id)) |v| return v else |e| if (e != error.TestFrameMissing) return e;
        if (i > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// A front end with an upstream server in this process.
const TestBridge = struct {
    server: *mcp.Server,
    upstream: *Upstream,
    out: TestSink,
    frontend: Frontend,
    arena_state: std.heap.ArenaAllocator,

    const profile: Profile = .{ .name = "mcp-bridge-test", .quirks = .{ .normalize_array_items = true } };

    fn create(options: Options) !*TestBridge {
        return createWith(testServer, options);
    }

    /// A front end with the upstream server of `makeServer`.
    fn createWith(makeServer: *const fn (gpa: Allocator, io: Io) anyerror!*mcp.Server, options: Options) !*TestBridge {
        const io = testing.io;
        const gpa = testing.allocator;
        const self = try gpa.create(TestBridge);
        errdefer gpa.destroy(self);
        self.server = try makeServer(gpa, io);
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

fn testServer(gpa: Allocator, io: Io) anyerror!*mcp.Server {
    const server = try gpa.create(mcp.Server);
    errdefer gpa.destroy(server);
    server.* = try mcp.Server.init(gpa, io, .{
        .info = .{ .name = "frontend-test", .version = "2.0.0" },
        .mrtr = .{ .sampling = true, .roots = true },
    });
    errdefer server.deinit();
    try server.addTool(.{ .name = "add", .description = "Add two integers" }, testAdd);
    try server.addTool(.{ .name = "block", .description = "Wait for the cancellation" }, testBlock);
    try server.addTool(.{ .name = "steps", .description = "Send progress, then a result" }, testSteps);
    try server.addToolJson(.{ .name = "ask", .description = "Ask for a name" }, testAsk);
    try server.addToolJson(.{ .name = "url", .description = "Ask the user to open a URL" }, testUrl);
    try server.addToolJson(.{ .name = "url_twice", .description = "Ask for the same URL in two rounds" }, testUrlTwice);
    try server.addToolJson(.{ .name = "sample", .description = "Ask the model of the client" }, testSample);
    try server.addToolJson(.{ .name = "roots", .description = "List the roots of the client" }, testRoots);
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

/// Ask for a name in a form. Each round sends one progress notification.
fn testAsk(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    const answer = try ctx.elicitResponse("name");
    try ctx.progress(if (answer == null) 1 else 2, 2, null);
    if (answer) |a| {
        if (a.action != .accept) return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "action: {t}", .{a.action}) };
        const name = mcp.json.getString(a.content orelse .null, "name") orelse "nobody";
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "Hello, {s}.", .{name}) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitForm("name", "Name?", try mcp.InputRequired.stringSchema(ctx.arena, "name", null, true));
    return .{ .input_required = ir };
}

const test_url = "https://example.com/auth";

fn testUrl(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.elicitResponse("auth")) |a| return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "url: {t}", .{a.action}) };
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitUrl("auth", "Sign in", test_url);
    return .{ .input_required = ir };
}

/// Ask for the same URL in round 1 and round 2. A server does that when it does not wait for
/// the end of the step in the browser. Round 3 gives the result.
fn testUrlTwice(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    const round = try ctx.state(u32) orelse 0;
    if (round == 2) {
        const a = (try ctx.elicitResponse("auth")).?;
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "url twice: {t}", .{a.action}) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitUrl("auth", "Sign in", test_url);
    try ir.setStateFmt("{d}", .{round + 1});
    return .{ .input_required = ir };
}

fn testSample(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.sampleResponse("model")) |r| {
        const block = r.content.blocks()[0];
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "model: {s}", .{if (block == .text) block.text.text else "?"}) };
    }
    const messages = try ctx.arena.alloc(types.SamplingMessage, 1);
    messages[0] = .{ .role = .user, .content = .{ .single = .{ .text = .{ .text = "Say hello" } } } };
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.sample("model", .{ .messages = messages, .maxTokens = 20 });
    return .{ .input_required = ir };
}

fn testRoots(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.rootsResponse("where")) |r| {
        var text: std.ArrayList(u8) = .empty;
        for (r.roots) |root| try text.print(ctx.arena, "{s};", .{root.uri});
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "roots: {s}", .{text.items}) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.listRoots("where");
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
    // The upstream server declares the list changes of its tools, thus the result has them.
    try testing.expect(caps.object.get("tools").?.object.get("listChanged").?.bool);
    try testing.expect(caps.object.get("resources") == null);
    try testing.expect(caps.object.get("tasks") == null);
    try testing.expect(b.frontend.declared.tools_list_changed);
    try testing.expect(!b.frontend.declared.resources_subscribe);
    try testing.expectEqualStrings("frontend-test", result.object.get("serverInfo").?.object.get("name").?.string);
    for ([_][]const u8{ "resultType", "ttlMs", "cacheScope", "_meta" }) |key| try testing.expect(result.object.get(key) == null);
    try testing.expectEqual(State.ready, b.frontend.state());
    // The upstream server got the client information and the input capabilities of VS Code.
    const upstream_options = b.upstream.conn.?.client.options;
    try testing.expectEqualStrings("Visual Studio Code", upstream_options.info.name);
    try testing.expect(upstream_options.capabilities.sampling != null);
    try testing.expect(upstream_options.capabilities.hasElicitation(.form));
    try testing.expect(upstream_options.capabilities.hasElicitation(.url));
    try testing.expect(upstream_options.capabilities.roots != null);
    try testing.expect(upstream_options.capabilities.hasExtension("io.modelcontextprotocol/ui"));

    try expectError(try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{}}"), -32600, "already_initialized");
    try expectError(try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/discover\"}"), -32601, "method_not_found");
    // The upstream server declares no subscriptions.
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
}

/// The text of the first content block of a `tools/call` response.
fn resultText(v: Value) ![]const u8 {
    const result = v.object.get("result") orelse return error.TestExpectedResult;
    return result.object.get("content").?.array.items[0].object.get("text").?.string;
}

test "a form elicitation goes to the client, and its answer goes upstream" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\",\"_meta\":{\"progressToken\":\"p-1\"}}}");
    const request = try b.out.waitMethod(arena, "elicitation/create", 1);
    // A request of the bridge has a string id with the prefix of the profile.
    try testing.expectEqualStrings("b-1", request.object.get("id").?.string);
    const params = request.object.get("params").?;
    try testing.expectEqualStrings("Name?", params.object.get("message").?.string);
    try testing.expect(params.object.get("requestedSchema").?.object.get("properties").?.object.get("name") != null);
    try testing.expectEqual(@as(usize, 1), b.frontend.pendingCount());
    try b.send(try answerLine(arena, request, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}"));
    const response = try waitResponse(&b.out, arena, 2);
    try testing.expectEqualStrings("Hello, Ada.", try resultText(response));
    try b.waitIdle();
    try testing.expectEqual(@as(usize, 0), b.frontend.pendingCount());
    // The progress of both rounds goes to the token of the client.
    const progress = try b.out.withMethod(arena, "notifications/progress");
    try testing.expectEqual(@as(usize, 2), progress.len);
    for (progress) |p| try testing.expectEqualStrings("p-1", p.object.get("params").?.object.get("progressToken").?.string);
    // A declined form: the content does not go upstream.
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const second = try b.out.waitMethod(arena, "elicitation/create", 2);
    try testing.expectEqualStrings("b-2", second.object.get("id").?.string);
    try b.send(try answerLine(arena, second, "{\"action\":\"decline\",\"content\":{\"name\":\"x\"}}"));
    try testing.expectEqualStrings("action: decline", try resultText(try waitResponse(&b.out, arena, 3)));
}

test "accepted content that does not agree with the schema fails the original request" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const request = try b.out.waitMethod(arena, "elicitation/create", 1);
    try b.send(try answerLine(arena, request, "{\"action\":\"accept\",\"content\":{\"name\":7}}"));
    try expectError(try waitResponse(&b.out, arena, 2), -32603, "invalid_client_answer");
}

test "the client cancels the original request while a request of the bridge waits" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const request = try b.out.waitMethod(arena, "elicitation/create", 1);
    try b.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2,\"reason\":\"stop\"}}");
    try b.waitIdle();
    // The bridge cancels its request, and sends no response for the canceled request.
    const cancelled = try b.out.waitMethod(arena, "notifications/cancelled", 1);
    try testing.expectEqualStrings("b-1", cancelled.object.get("params").?.object.get("requestId").?.string);
    try testing.expectError(error.TestFrameMissing, b.out.byId(arena, 2));
    try testing.expectEqual(@as(usize, 0), b.frontend.pendingCount());
    // VS Code ignores the cancellation and answers late. The bridge drops the answer.
    const before = b.out.count();
    try b.send(try answerLine(arena, request, "{\"action\":\"cancel\"}"));
    try testing.expectEqual(before, b.out.count());
    try testing.expect((try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}")).object.get("result") != null);
}

test "at the limit of requests in flight, the answers of the client still reach their requests" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try TestBridge.create(.{ .max_in_flight_requests = 1 });
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const request = try b.out.waitMethod(arena, "elicitation/create", 1);
    // The reader does not wait: a second request gets -32603 at once.
    const before = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":1,\"b\":1}}}");
    try testing.expectEqual(before + 1, b.out.count());
    try expectError(try b.out.byId(arena, 3), -32603, "too_many_requests");
    try b.send(try answerLine(arena, request, "{\"action\":\"accept\",\"content\":{\"name\":\"Bo\"}}"));
    try testing.expectEqualStrings("Hello, Bo.", try resultText(try waitResponse(&b.out, arena, 2)));

    // A cancellation of the client also reaches its request at the limit.
    try b.waitIdle();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const second = try b.out.waitMethod(arena, "elicitation/create", 2);
    try testing.expectEqualStrings("b-2", second.object.get("id").?.string);
    const count = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":1,\"b\":1}}}");
    try testing.expectEqual(count + 1, b.out.count());
    try expectError(try b.out.byId(arena, 5), -32603, "too_many_requests");
    try b.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":4,\"reason\":\"stop\"}}");
    const cancelled = try b.out.waitMethod(arena, "notifications/cancelled", 1);
    try testing.expectEqualStrings("b-2", cancelled.object.get("params").?.object.get("requestId").?.string);
    try b.waitIdle();
    try testing.expectError(error.TestFrameMissing, b.out.byId(arena, 4));
    try testing.expectEqual(@as(usize, 1), (try b.out.withMethod(arena, "notifications/cancelled")).len);
    try testing.expectEqual(@as(usize, 0), b.frontend.pendingCount());
    try testing.expectEqual(@as(usize, 0), b.frontend.inFlightCount());
}

test "the bridge cancels only the requests to the client that went out" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const before = b.out.count();
    const slot = try b.frontend.newSlot();
    defer b.frontend.destroySlot(slot);
    slot.id = .{ .integer = 9 };
    slot.method = "tools/call";
    const arena = slot.arena.allocator();
    const questions = [_]input.Question{ .{ .method = "roots/list", .params = null }, .{ .method = "roots/list", .params = null } };
    var answers: [questions.len]input.Answer = undefined;
    // The original request has its response, as after the loss of the upstream server. Thus
    // the requests do not go out, and at the end of the time limit no cancellation goes out.
    slot.answered = true;
    try testing.expectError(error.Timeout, askClient(slot, arena, &questions, &answers, .fromMilliseconds(50)));
    // A canceled request sends nothing.
    slot.answered = false;
    slot.token.cancel(testing.io, "stop");
    try testing.expectError(error.Canceled, askClient(slot, arena, &questions, &answers, .fromSeconds(5)));
    try testing.expectEqual(before, b.out.count());
    try testing.expectEqual(@as(usize, 0), b.frontend.pendingCount());
}

test "the loss of the upstream server while a request of the bridge waits for the client" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    _ = try b.out.waitMethod(arena, "elicitation/create", 1);
    b.frontend.failInFlight();
    try b.waitIdle();
    try expectError(try b.out.byId(arena, 2), -32603, "upstream_exited");
    // The cancellation of the request of the bridge tells the true reason.
    const cancelled = try b.out.withMethod(arena, "notifications/cancelled");
    try testing.expectEqual(@as(usize, 1), cancelled.len);
    const params = cancelled[0].object.get("params").?;
    try testing.expectEqualStrings("b-1", params.object.get("requestId").?.string);
    try testing.expectEqualStrings(upstream_exit_reason, params.object.get("reason").?.string);
    try testing.expectEqual(@as(usize, 0), b.frontend.pendingCount());
}

test "the end of the input stops a request that waits for the client" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    _ = try b.out.waitMethod(arena, "elicitation/create", 1);
    const started = Io.Clock.Timestamp.now(testing.io, .awake);
    b.frontend.shutdown();
    // The task wakes at once, much earlier than `shutdown_grace`.
    try testing.expect(started.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw.toMilliseconds() < 1000);
    try testing.expectEqual(@as(usize, 0), b.frontend.inFlightCount());
    try testing.expectEqual(@as(usize, 0), b.frontend.pendingCount());
    try testing.expectError(error.TestFrameMissing, b.out.byId(arena, 2));
}

test "answers of the client without a request, and an answer that is not valid" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    _ = try b.out.waitMethod(arena, "elicitation/create", 1);
    // An unknown id, a numeric id and an error without an id: the bridge drops them, and the
    // request still waits.
    const before = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-99\",\"result\":{\"action\":\"accept\"}}");
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"action\":\"accept\"}}");
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{\"action\":\"accept\"}}");
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":{\"action\":\"accept\"}}");
    try testing.expectEqual(before, b.out.count());
    try testing.expectEqual(@as(usize, 1), b.frontend.pendingCount());
    // An answer with a lone surrogate, which std.json refuses. The id resolves the request
    // as an error, thus the elicitation gets cancel upstream.
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"\\ud800\"}}}");
    try testing.expectEqualStrings("action: cancel", try resultText(try waitResponse(&b.out, arena, 2)));
    // A second answer for the same id gets nothing.
    const after = b.out.count();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"accept\"}}");
    try testing.expectEqual(after, b.out.count());
}

test "an error of the client: elicitation gives cancel, sampling fails the original request" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const form = try b.out.waitMethod(arena, "elicitation/create", 1);
    try b.send(try errorLine(arena, form, "{\"code\":-32603,\"message\":\"The form failed.\"}"));
    try testing.expectEqualStrings("action: cancel", try resultText(try waitResponse(&b.out, arena, 2)));

    // VS Code refuses a sampling request with -32000. The original request gets that error.
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"sample\"}}");
    const sample = try b.out.waitMethod(arena, "sampling/createMessage", 1);
    try testing.expectEqualStrings("Say hello", sample.object.get("params").?.object.get("messages").?.array.items[0].object.get("content").?.object.get("text").?.string);
    try b.send(try errorLine(arena, sample, "{\"code\":-32000,\"message\":\"The user refused the request.\",\"data\":{\"x\":1}}"));
    const refused = try waitResponse(&b.out, arena, 3);
    const err = refused.object.get("error").?;
    try testing.expectEqual(@as(i64, -32000), err.object.get("code").?.integer);
    try testing.expectEqualStrings("The user refused the request.", err.object.get("message").?.string);
    try testing.expectEqual(@as(i64, 1), err.object.get("data").?.object.get("x").?.integer);

    // A sampling answer goes upstream.
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"sample\"}}");
    const again = try b.out.waitMethod(arena, "sampling/createMessage", 2);
    try b.send(try answerLine(arena, again, "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"Hello!\"},\"model\":\"m\"}"));
    try testing.expectEqualStrings("model: Hello!", try resultText(try waitResponse(&b.out, arena, 4)));
}

test "roots: only file URIs go upstream" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"roots\"}}");
    const request = try b.out.waitMethod(arena, "roots/list", 1);
    try b.send(try answerLine(arena, request, "{\"roots\":[{\"uri\":\"file:///work\",\"name\":\"work\"},{\"uri\":\"vscode-vfs://github/x\"}]}"));
    try testing.expectEqualStrings("roots: file:///work;", try resultText(try waitResponse(&b.out, arena, 2)));
}

test "a URL elicitation gets an elicitationId, and the complete notification comes before the result" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"url\"}}");
    const request = try b.out.waitMethod(arena, "elicitation/create", 1);
    const params = request.object.get("params").?;
    try testing.expectEqualStrings("url", params.object.get("mode").?.string);
    try testing.expectEqualStrings(test_url, params.object.get("url").?.string);
    const elicitation_id = params.object.get("elicitationId").?.string;
    try b.send(try answerLine(arena, request, "{\"action\":\"accept\"}"));
    try testing.expectEqualStrings("url: accept", try resultText(try waitResponse(&b.out, arena, 2)));
    const complete = try b.out.waitMethod(arena, "notifications/elicitation/complete", 1);
    try testing.expectEqualStrings(elicitation_id, complete.object.get("params").?.object.get("elicitationId").?.string);
    // The notification comes before the response.
    b.out.lock.lockUncancelable(testing.io);
    defer b.out.lock.unlock(testing.io);
    const last = b.out.frames.items[b.out.frames.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, last, "\"id\":2") != null);
}

test "a second round with the same accepted URL gets the Continue form" {
    const b = try TestBridge.create(.{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"url_twice\"}}");
    const first = try b.out.waitMethod(arena, "elicitation/create", 1);
    try testing.expectEqualStrings("url", first.object.get("params").?.object.get("mode").?.string);
    try b.send(try answerLine(arena, first, "{\"action\":\"accept\"}"));
    const second = try b.out.waitMethod(arena, "elicitation/create", 2);
    const form = second.object.get("params").?;
    try testing.expectEqualStrings("form", form.object.get("mode").?.string);
    try testing.expect(form.object.get("url") == null);
    try testing.expect(form.object.get("requestedSchema").?.object.get("properties").?.object.get(input.continue_property) != null);
    // No complete notification while the server asks for the URL.
    try testing.expectEqual(@as(usize, 0), (try b.out.withMethod(arena, "notifications/elicitation/complete")).len);
    try b.send(try answerLine(arena, second, "{\"action\":\"accept\",\"content\":{\"continue\":\"Continue\"}}"));
    try testing.expectEqualStrings("url twice: accept", try resultText(try waitResponse(&b.out, arena, 2)));
    try testing.expectEqual(@as(usize, 1), (try b.out.withMethod(arena, "notifications/elicitation/complete")).len);
}

test "the client does not answer in time" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try TestBridge.create(.{ .timeouts = .{ .input = .fromMilliseconds(200) } });
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const request = try b.out.waitMethod(arena, "elicitation/create", 1);
    try expectError(try waitResponse(&b.out, arena, 2), -32603, "input_timeout");
    const cancelled = try b.out.waitMethod(arena, "notifications/cancelled", 1);
    try testing.expectEqualStrings("b-1", cancelled.object.get("params").?.object.get("requestId").?.string);
    // The late answer gets nothing.
    try b.waitIdle();
    const before = b.out.count();
    try b.send(try answerLine(arena, request, "{\"action\":\"cancel\"}"));
    try testing.expectEqual(before, b.out.count());
}

/// An `InputRequiredResult` of a scripted server with a form and a request state.
const scripted_form =
    \\{"resultType":"input_required","inputRequests":{"name":{"method":"elicitation/create","params":{"message":"Name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}},"requestState":"sealed-1"}
;
const scripted_refusal =
    \\error:{"code":-32602,"message":"Invalid or expired requestState","data":{"reason":"invalid_request_state"}}
;

test "a refused requestState gives an isError result for tools/call and an error for prompts/get" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const b = try ScriptBridge.create(&.{ scripted_form, scripted_refusal, scripted_form, scripted_refusal }, .{});
    defer b.destroy();
    const arena = b.arena();
    try b.frontend.receive("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"t\"}}");
    const first = try b.out.waitMethod(arena, "elicitation/create", 1);
    try b.frontend.receive(try answerLine(arena, first, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}"));
    const tool = (try waitResponse(&b.out, arena, 2)).object.get("result").?;
    try testing.expect(tool.object.get("isError").?.bool);
    const text = tool.object.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "Invalid or expired requestState") != null);
    try testing.expect(std.mem.endsWith(u8, text, "Run the tool again."));

    try b.frontend.receive("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"prompts/get\",\"params\":{\"name\":\"p\"}}");
    const second = try b.out.waitMethod(arena, "elicitation/create", 2);
    try b.frontend.receive(try answerLine(arena, second, "{\"action\":\"decline\"}"));
    const err = (try waitResponse(&b.out, arena, 3)).object.get("error").?;
    try testing.expectEqual(@as(i64, -32602), err.object.get("code").?.integer);
    try testing.expect(std.mem.endsWith(u8, err.object.get("message").?.string, "Send the request again."));
    try testing.expectEqualStrings("invalid_request_state", err.object.get("data").?.object.get("reason").?.string);
    try testing.expectEqual(@as(usize, 4), b.script.count());
}

test "the rounds stop at the limit of the upstream client" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const state_only = "{\"resultType\":\"input_required\",\"requestState\":\"again\"}";
    const max = (mcp.Limits{}).mrtr_max_rounds_client;
    const script = [_][]const u8{state_only} ** (max + 2);
    const b = try ScriptBridge.create(&script, .{});
    defer b.destroy();
    const arena = b.arena();
    try b.frontend.receive("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"t\"}}");
    try expectError(try waitResponse(&b.out, arena, 2), -32603, "too_many_rounds");
    try testing.expectEqual(@as(usize, max), b.script.count());
}

test "a round with more input requests than the limit sends nothing to the client" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    const many = "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"roots/list\"},\"b\":{\"method\":\"roots/list\"},\"c\":{\"method\":\"roots/list\"}}}";
    const b = try ScriptBridge.create(&.{many}, .{ .max_input_requests_per_round = 2 });
    defer b.destroy();
    const arena = b.arena();
    try b.frontend.receive("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"t\"}}");
    try expectError(try waitResponse(&b.out, arena, 2), -32603, "too_many_input_requests");
    try testing.expectEqual(@as(usize, 0), (try b.out.withMethod(arena, "roots/list")).len);
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

// The tests of the notifications: the listen stream, the subscriptions and the log messages.

const notes_uri = "file:///test/notes.txt";

/// An upstream server with notifications: a tool that changes the tool list, a resource with
/// updates, and log messages.
fn notifyServer(gpa: Allocator, io: Io) anyerror!*mcp.Server {
    const server = try gpa.create(mcp.Server);
    errdefer gpa.destroy(server);
    server.* = try mcp.Server.init(gpa, io, .{
        .info = .{ .name = "notify-test", .version = "1.0.0" },
        .capabilities = .{ .logging = .{ .object = .empty } },
    });
    errdefer server.deinit();
    try server.addToolJson(.{ .name = "flip", .description = "Disable the tool spare" }, testFlip);
    try server.addToolJson(.{ .name = "spare", .description = "A tool that flip disables" }, testAsk);
    try server.addToolJson(.{ .name = "poke", .description = "Tell the subscribers that the notes changed" }, testPoke);
    try server.addToolJson(.{ .name = "say", .description = "Send log messages" }, testSay);
    try server.addResource(.{ .uri = notes_uri, .name = "notes", .mime_type = "text/plain" }, testNotes);
    return server;
}

fn testFlip(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    const changed = ctx.server.setToolEnabled(ctx.io, "spare", false);
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "changed: {}", .{changed}) };
}

fn testPoke(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    ctx.server.notifyResourceUpdated(ctx.io, notes_uri);
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "poked", .{}) };
}

fn testSay(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    try ctx.log(.debug, "test", .{ .string = "debug" });
    try ctx.log(.warning, "test", .{ .string = "warning" });
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "said", .{}) };
}

fn testNotes(ctx: *mcp.RequestContext, uri: []const u8) anyerror!mcp.Outcome(mcp.ReadResourceResult) {
    const contents = try ctx.arena.alloc(types.ResourceContents, 1);
    contents[0] = .{ .text = .{ .uri = uri, .mimeType = "text/plain", .text = "notes" } };
    return .{ .complete = .{ .contents = contents } };
}

/// The methods of the frames from `start`, or "response" for a response.
fn methodsFrom(out: *TestSink, arena: Allocator, start: usize) ![]const []const u8 {
    out.lock.lockUncancelable(testing.io);
    defer out.lock.unlock(testing.io);
    var list: std.ArrayList([]const u8) = .empty;
    for (out.frames.items[start..]) |f| {
        const v = try mcp.json.parseTree(arena, f);
        try list.append(arena, mcp.json.getString(v, "method") orelse "response");
    }
    return list.items;
}

fn expectMethods(expected: []const []const u8, actual: []const []const u8) !void {
    if (expected.len == actual.len) {
        for (expected, actual) |want, got| {
            if (!std.mem.eql(u8, want, got)) break;
        } else return;
    }
    std.debug.print("\nexpected the methods {f}, got {f}\n", .{ std.json.fmt(expected, .{}), std.json.fmt(actual, .{}) });
    return error.TestExpectedEqual;
}

fn expectJson(arena: Allocator, expected: []const u8, value: Value) !void {
    try testing.expectEqualStrings(expected, try mcp.json.writeAlloc(arena, value));
}

/// Send `notifications/initialized`, and wait for the first acknowledgment of the listen
/// stream.
fn startListening(b: *TestBridge) !void {
    try b.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    var i: usize = 0;
    while (b.frontend.listener.acknowledgments.load(.acquire) == 0) : (i += 1) {
        if (i > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "notifications/initialized starts the listen stream, and a change of the tools comes before the result" {
    const b = try TestBridge.createWith(notifyServer, .{});
    defer b.destroy();
    try b.initialize();
    try testing.expect(b.frontend.declared.listens());
    try testing.expect(b.frontend.declared.logging);
    try startListening(b);
    // A second notifications/initialized starts nothing.
    try b.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    const arena = b.arena_state.allocator();
    // The list changes after the acknowledgment. The server has no prompts.
    try expectMethods(&.{ "response", "notifications/tools/list_changed", "notifications/resources/list_changed" }, try methodsFrom(&b.out, arena, 0));
    const start = b.out.count();
    _ = try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"flip\"}}");
    try expectMethods(&.{ "notifications/tools/list_changed", "response" }, try methodsFrom(&b.out, arena, start));
    // A call that changes nothing gives no list change.
    _ = try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"flip\"}}");
    try expectMethods(&.{ "notifications/tools/list_changed", "response", "response" }, try methodsFrom(&b.out, arena, start));
    try testing.expectEqual(@as(u64, 1), b.frontend.listener.acknowledgments.load(.acquire));
}

test "resources/subscribe and resources/unsubscribe change the URIs of the listen stream" {
    const b = try TestBridge.createWith(notifyServer, .{});
    defer b.destroy();
    try b.initialize();
    try startListening(b);
    const arena = b.arena_state.allocator();
    const start = b.out.count();
    const subscribed = try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"" ++ notes_uri ++ "\"}}");
    try testing.expectEqual(@as(usize, 0), subscribed.object.get("result").?.object.count());
    // The new stream gives no list change, and its update comes before the result of the call.
    _ = try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"poke\"}}");
    try expectMethods(&.{ "response", "notifications/resources/updated", "response" }, try methodsFrom(&b.out, arena, start));
    const updates = try b.out.withMethod(arena, "notifications/resources/updated");
    try expectJson(arena, "{\"uri\":\"" ++ notes_uri ++ "\"}", updates[0].object.get("params").?);
    // A URI that the stream has already gets `{}` without a new stream.
    _ = try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"" ++ notes_uri ++ "\"}}");
    // An unknown URI gets `{}`, and parameters that are not valid get -32602.
    _ = try b.call(5, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"file:///other\"}}");
    try expectError(try b.call(6, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/subscribe\",\"params\":{\"uri\":5}}"), -32602, "invalid_params");
    _ = try b.call(7, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/unsubscribe\",\"params\":{\"uri\":\"" ++ notes_uri ++ "\"}}");
    for ([_]i64{ 4, 5, 7 }) |id| try testing.expect((try b.out.byId(arena, id)).object.get("result") != null);
    // After the unsubscribe, an update does not reach the client.
    const before = b.out.count();
    _ = try b.call(8, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"poke\"}}");
    try expectMethods(&.{"response"}, try methodsFrom(&b.out, arena, before));
}

test "logging/setLevel goes upstream with each request, and the log messages of a request go to the client" {
    const b = try TestBridge.createWith(notifyServer, .{});
    defer b.destroy();
    try b.initialize();
    const arena = b.arena_state.allocator();
    // Without a level, the upstream server sends no log message.
    var start = b.out.count();
    _ = try b.call(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"say\"}}");
    try expectMethods(&.{"response"}, try methodsFrom(&b.out, arena, start));
    // The upstream server sends the messages at the level and above. The memory link gives
    // them to the request.
    _ = try b.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"logging/setLevel\",\"params\":{\"level\":\"info\"}}");
    start = b.out.count();
    _ = try b.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"say\"}}");
    try expectMethods(&.{ "notifications/message", "response" }, try methodsFrom(&b.out, arena, start));
    const messages = try b.out.withMethod(arena, "notifications/message");
    try expectJson(arena, "{\"level\":\"warning\",\"logger\":\"test\",\"data\":\"warning\"}", messages[0].object.get("params").?);
    // The bridge also drops a message below the level of the client.
    b.frontend.forwardLog(.{ .level = .info, .data = .{ .string = "x" } });
    b.frontend.forwardLog(.{ .level = .debug, .data = .{ .string = "y" } });
    b.frontend.forwardLog(.{ .level = .critical, .data = .{ .integer = 1 } });
    try testing.expectEqual(@as(usize, 3), (try b.out.withMethod(arena, "notifications/message")).len);
}

test "the end of the input stops the listen stream before the upstream closes" {
    const b = try TestBridge.createWith(notifyServer, .{});
    defer b.destroy();
    try b.initialize();
    try startListening(b);
    try testing.expect(b.frontend.listener.isRunning());
    const before = b.out.count();
    const started = Io.Clock.Timestamp.now(testing.io, .awake);
    b.frontend.shutdown();
    try testing.expect(started.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw.toMilliseconds() < 1000);
    try testing.expect(!b.frontend.listener.isRunning());
    try testing.expect(b.upstream.conn == null);
    // A subscribe after the end of the input gets nothing.
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/subscribe\",\"params\":{\"uri\":\"" ++ notes_uri ++ "\"}}");
    try testing.expectEqual(before, b.out.count());
}
