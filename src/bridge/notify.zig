//! The notifications of a listen stream for the client. Revision 2025-11-25 has no listen
//! stream: the server sends its list changes on the connection, and the client subscribes to
//! a resource with `resources/subscribe`. Revision 2026-07-28 sends these notifications on a
//! `subscriptions/listen` stream. A `Listener` keeps one such stream open for the client:
//!
//! - One owner task (`run`) holds the streams, the subscribed URIs and the state. It runs in
//!   the group of the front end. Each stream has its own task and its own arena. Each
//!   notification for the client gets its own scratch memory.
//! - The client gets only `notifications/tools/list_changed`,
//!   `notifications/prompts/list_changed`, `notifications/resources/list_changed` and
//!   `notifications/resources/updated`, without the subscription id
//!   (`translate.listenEvent`). The listener reads each acknowledgment and keeps its
//!   subscription id, but the client does not get it. The client never gets a
//!   `notifications/cancelled` of the upstream server. Its ids can be equal to the ids of the
//!   client.
//! - `change` adds a URI or removes a URI. The owner task does one change at a time. A URI
//!   that the set has already, and a URI that the set does not have, give the response `{}` at
//!   once. For another change, the owner task opens a new stream with the new URIs. The
//!   acknowledgment of the new stream writes the response `{}` to the client, and then the
//!   owner task cancels the old stream. When the new stream fails before its acknowledgment,
//!   the old stream and the old URIs stay, and the client gets the error.
//! - After a gap, the lists and the resources of the client can be old. The upstream server
//!   does not send the events of the gap again. Thus after some acknowledgments, the client
//!   gets one list change for each list that it knows and one update for each URI of the
//!   stream. These are the acknowledgment of the first stream, of each stream after a loss,
//!   and each second or later acknowledgment of the active stream. The client of zig-sdk
//!   opens a stream again after a lost connection (`Retry.force`). A change of the URIs
//!   without a gap gives no list change and no update.
//! - The active stream is the stream whose events go to the client. A stream becomes active at
//!   its first acknowledgment. A newer stream takes its place at its own first acknowledgment.
//!   An older stream that sends its first acknowledgment after a newer stream does not become
//!   active again. After the last unsubscribe, no stream is active.
//! - After a loss, the owner task opens a new stream after a wait. The wait starts at
//!   `Options.backoff` (0.5 s) and doubles to at most `Options.max_backoff` (30 s). A stream
//!   that lives for `Options.stable` (10 s) after its first acknowledgment resets the wait at
//!   its end. Thus an upstream server that ends each stream soon after its acknowledgment gets
//!   the new streams after longer waits. The owner task opens no new stream after a
//!   cancellation, after a JSON-RPC error and after the end of the upstream server. A change of
//!   the URIs can open a stream again.
//! - Over HTTP, a stream can fail with the status 401 or 403: its sign-in did not complete.
//!   With a sign-in (`Options.sign_ins`), the owner task then waits for the next sign-in of
//!   another request. `Listener.signedIn` wakes it, and it opens a new stream.
//! - At the end of the input, `stop` cancels each stream. The front end waits for the end of
//!   `run`, at most `shutdown_grace`, and then it closes the upstream client.
//!
//! The callback of a stream (`onEvent`) runs on the reader task of the transport, or on the
//! task that publishes the event (memory link). On the memory link, the server holds its
//! locks during the call. Thus a callback only translates the notification and writes it
//! under the output lock of the front end, only for the active stream (`Host.writeIf`). A
//! callback takes no other lock of the bridge, waits for nothing and sends no request. The
//! lock order is: the subscription lock of the server, the lock of the stream, the lock of the
//! memory link, then the output lock.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const types = mcp.types;
const CancelToken = mcp.transport.CancelToken;
const translate = @import("translate.zig");
const Upstream = @import("Upstream.zig");

const log = std.log.scoped(.bridge);

/// The functions of the front end for a `Listener`.
pub const Host = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write one frame to the client under the output lock. Drop it after the end of the
        /// output. The function must not wait for another lock.
        write: *const fn (context: *anyopaque, frame: []const u8) void,
        /// As `write`, but only when `active` has the value `generation`. The function reads
        /// `active` under the output lock, thus the check and the write are one step. Returns
        /// false when `active` has another value.
        writeIf: *const fn (context: *anyopaque, frame: []const u8, active: *const std.atomic.Value(u64), generation: u64) bool,
        /// The log level of the client, or null.
        logLevel: *const fn (context: *anyopaque) ?types.LoggingLevel,
    };

    fn write(self: Host, frame: []const u8) void {
        self.vtable.write(self.context, frame);
    }

    fn writeIf(self: Host, frame: []const u8, active: *const std.atomic.Value(u64), generation: u64) bool {
        return self.vtable.writeIf(self.context, frame, active, generation);
    }

    fn logLevel(self: Host) ?types.LoggingLevel {
        return self.vtable.logLevel(self.context);
    }
};

/// The settings of a `Listener`.
pub const Options = struct {
    /// The list changes that the client knows. The stream asks for these lists, and after a
    /// gap the client gets one list change for each of them.
    tools: bool = false,
    prompts: bool = false,
    resources: bool = false,
    /// The first wait before a new stream after a loss.
    backoff: Io.Duration = .fromMilliseconds(500),
    /// The longest wait before a new stream after a loss.
    max_backoff: Io.Duration = .fromSeconds(30),
    /// A stream that lives for this time after its first acknowledgment resets the wait to
    /// `backoff` at its end. After a shorter stream, the wait stays long.
    stable: Io.Duration = .fromSeconds(10),
    /// The number of challenges that the sign-in of an HTTP upstream server answered
    /// (`oauth.Authorizer.answered`), or null without a sign-in. A stream that fails with
    /// the HTTP status 401 or 403 means a sign-in that did not complete. Then the listener
    /// opens no new stream until this number changes, and `Listener.signedIn` wakes it. It
    /// never opens a new stream on a timer, because each new stream could ask the user again.
    sign_ins: ?*const std.atomic.Value(u64) = null,

    fn hasLists(self: Options) bool {
        return self.tools or self.prompts or self.resources;
    }
};

/// Writes the response of a `resources/subscribe` or `resources/unsubscribe` request.
pub const Respond = struct {
    context: *anyopaque,
    /// Write the result `{}`. The function can run in the callback of an acknowledgment, thus
    /// it must only write.
    ok: *const fn (context: *anyopaque) void,
    /// Write the error `err`.
    fail: *const fn (context: *anyopaque, err: translate.RpcError) void,
};

/// One `resources/subscribe` or `resources/unsubscribe` of the client.
pub const Change = struct {
    kind: Kind,
    uri: []const u8,
    respond: Respond,
    /// What happened. `Listener.change` sets it.
    outcome: Outcome = .canceled,
    /// The owner task sets it at the end of the change.
    done: Io.Event = .unset,

    pub const Kind = enum { subscribe, unsubscribe };

    pub const Outcome = enum {
        /// The set had the URI already, or did not have the URI to remove. The response `{}`
        /// went out at once.
        unchanged,
        /// The listener has the new URIs. The response `{}` went out.
        changed,
        /// The new stream failed, and the old stream stays. The response is an error.
        failed,
        /// The listener stopped first. No response went out.
        canceled,
    };
};

/// The listen stream of one connection of the client. See the comment of the file.
pub const Listener = struct {
    io: Io,
    gpa: Allocator,
    upstream: *Upstream,
    host: Host = undefined,
    options: Options = .{},
    /// Guards `queue` and `stopping`.
    lock: Io.Mutex = .init,
    /// The changes that wait for the owner task.
    queue: std.ArrayList(*Change) = .empty,
    /// True after `stop`.
    stopping: bool = false,
    /// Wakes the owner task: a change, an acknowledgment, the end of a stream, or the stop.
    wake: Io.Event = .unset,
    /// True from `start` to the end of `run`.
    running: std.atomic.Value(bool) = .init(false),
    /// The generation of the stream whose events go to the client, or zero before the first
    /// stream. A stream sets it at its first acknowledgment, before the response of its
    /// change. The value only increases, thus an older stream does not become active again.
    /// The callback of a stream reads it under the output lock before it writes an event
    /// (`Host.writeIf`). Thus the events of an old stream do not go to the client after the
    /// response of the new stream. After the last unsubscribe without lists, it is the
    /// generation of no stream.
    active: std.atomic.Value(u64) = .init(0),
    /// The number of acknowledgments of all streams. The tests read it.
    acknowledgments: std.atomic.Value(u64) = .init(0),
    /// The number of waits for a new stream after a loss. The tests read it.
    retries: std.atomic.Value(u64) = .init(0),

    // The fields below belong to the owner task.

    /// The tasks of the streams.
    group: Io.Group = .init,
    /// Each stream with a task.
    streams: std.ArrayList(*Stream) = .empty,
    /// The stream that has the URIs of `uris`, or null.
    current: ?*Stream = null,
    /// The stream of the change in progress, until its acknowledgment or its end.
    next: ?*Stream = null,
    /// The subscribed URIs, in `gpa`.
    uris: std.ArrayList([]const u8) = .empty,
    /// The generation of the last stream.
    generation: u64 = 0,
    /// True when the client can have old lists and old resources: before the first
    /// acknowledgment, and after a loss until the next acknowledgment.
    gap: bool = true,
    /// False after a cancellation, a JSON-RPC error or the end of the upstream server. Then
    /// only a change opens a stream. Also false while `sign_in_wait` is set.
    reopen: bool = true,
    /// The wait before the next new stream after a loss.
    backoff: Io.Duration = .fromMilliseconds(500),
    /// The time of the next new stream after a loss, or null for at once.
    retry_at: ?Io.Clock.Timestamp = null,
    /// After a stream that failed with 401 or 403: the value of `Options.sign_ins` at its end.
    /// The listener opens a new stream when the value changes. Else null.
    sign_in_wait: ?u64 = null,

    /// The reason of the cancellation of a stream that a change replaced.
    const replaced_reason = "the bridge replaced the listen stream";
    /// The reason of the cancellation of each stream at the stop.
    const stop_reason = "the client closed the connection";

    pub fn init(io: Io, gpa: Allocator, upstream: *Upstream) Listener {
        return .{ .io = io, .gpa = gpa, .upstream = upstream };
    }

    /// Release the memory. Call it after the end of `run`, or without a call of `start`.
    pub fn deinit(self: *Listener) void {
        std.debug.assert(!self.running.load(.acquire));
        self.queue.deinit(self.gpa);
        self.streams.deinit(self.gpa);
        self.clearUris();
        self.uris.deinit(self.gpa);
    }

    /// Start the owner task in `group`. The listener must stay at its address until the end
    /// of `run`.
    pub fn start(self: *Listener, group: *Io.Group, host: Host, options: Options) Io.ConcurrentError!void {
        self.host = host;
        self.options = options;
        self.backoff = options.backoff;
        self.running.store(true, .release);
        group.concurrent(self.io, run, .{self}) catch |e| {
            self.running.store(false, .release);
            return e;
        };
    }

    /// True from `start` to the end of `run`.
    pub fn isRunning(self: *const Listener) bool {
        return self.running.load(.acquire);
    }

    /// Wake the owner task after a sign-in. When a stream failed with 401 or 403 and the
    /// number of `Options.sign_ins` changed, the owner task opens a new stream. Another task
    /// can call it at each time. The function does not wait.
    pub fn signedIn(self: *Listener) void {
        self.wake.set(self.io);
    }

    /// Stop the listener: the owner task cancels each stream, waits for their tasks and
    /// returns. The function does not wait.
    pub fn stop(self: *Listener) void {
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.stopping = true;
        }
        self.wake.set(self.io);
    }

    /// Do one change of the URIs, and wait for its end. The owner task writes the response
    /// through `c.respond`, except for the outcome `canceled`. When the listener does not run,
    /// the outcome is `canceled` at once.
    pub fn change(self: *Listener, c: *Change) void {
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (self.stopping or !self.running.load(.acquire)) {
                c.outcome = .canceled;
                return;
            }
            self.queue.append(self.gpa, c) catch {
                c.outcome = .failed;
                c.respond.fail(c.respond.context, translate.errorFor(.out_of_memory, null));
                return;
            };
        }
        self.wake.set(self.io);
        c.done.waitUncancelable(self.io);
    }

    // -----------------------------------------------------------------------------------------
    // The owner task
    // -----------------------------------------------------------------------------------------

    /// The owner task. It returns after `stop`, or after a cancellation of its group.
    pub fn run(self: *Listener) Io.Cancelable!void {
        defer self.finish();
        while (true) {
            // An event after this point sets `wake` again, thus the wait below returns.
            self.wake.reset();
            self.reap();
            if (self.isStopping()) return;
            // A change waits until the change before it ends.
            while (self.next == null) self.begin(self.takeChange() orelse break);
            self.resumeAfterSignIn();
            self.reconnect();
            const timeout: Io.Timeout = if (self.waitUntil()) |at| .{ .deadline = at } else .none;
            self.wake.waitTimeout(self.io, timeout) catch |e| switch (e) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
        }
    }

    fn isStopping(self: *Listener) bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.stopping;
    }

    /// The oldest change in the queue, or null.
    fn takeChange(self: *Listener) ?*Change {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    /// The time of the next new stream, or null when the owner task waits for an event only.
    fn waitUntil(self: *const Listener) ?Io.Clock.Timestamp {
        if (self.current != null or self.next != null or !self.reopen) return null;
        return self.retry_at;
    }

    /// Process the acknowledgments and the ends of the streams.
    fn reap(self: *Listener) void {
        if (self.current) |s| {
            self.seeAcks(s);
            // The current stream can end while the stream of a change waits for its
            // acknowledgment. Its end comes before `commit`, thus `commit` sees the gap and
            // writes the list changes and the updates. The loop below calls `ended` for this
            // stream again, and the second call does nothing.
            if (s.ended.load(.acquire)) self.ended(s);
        }
        // The acknowledgment of the stream of a change comes before its end: a stream can send
        // its acknowledgment and end before the owner task sees the acknowledgment.
        if (self.next) |s| if (s.seen == 0 and s.acks.load(.acquire) > 0) self.commit(s);
        var i: usize = 0;
        while (i < self.streams.items.len) {
            const s = self.streams.items[i];
            if (!s.ended.load(.acquire)) {
                i += 1;
                continue;
            }
            _ = self.streams.swapRemove(i);
            self.ended(s);
            s.destroy();
        }
    }

    /// Process the new acknowledgments of the current stream `s`.
    fn seeAcks(self: *Listener, s: *Stream) void {
        const acks = s.acks.load(.acquire);
        if (acks <= s.seen) return;
        if (s.seen == 0) s.acked_at = self.now();
        s.seen = acks;
        self.gap = false;
    }

    /// The stream of a change has its acknowledgment. Its callback wrote the response. The
    /// stream takes the place of the current stream, and the listener has its URIs.
    fn commit(self: *Listener, s: *Stream) void {
        s.seen = s.acks.load(.acquire);
        s.acked_at = self.now();
        self.next = null;
        // The old stream ended while the new stream waited for its acknowledgment. Thus the
        // client can have old lists and old resources.
        if (self.gap and !s.after_gap) self.writeGap(s.uris);
        if (self.current) |old| self.retire(old);
        self.current = s;
        self.setUris(s.uris);
        self.gap = false;
        self.reopen = true;
        self.retry_at = null;
        self.sign_in_wait = null;
        if (s.change) |c| self.complete(c, .changed);
    }

    /// A stream task ended.
    fn ended(self: *Listener, s: *Stream) void {
        if (s.retired) return;
        if (s == self.next) {
            // The stream can send its acknowledgment and end after `reap` read its
            // acknowledgments. Its callback wrote the response and made it active. Thus the
            // change is done, and this end is the end of the current stream.
            if (s.acks.load(.acquire) > 0) {
                self.commit(s);
                return self.ended(s);
            }
            // The stream of a change ended before its acknowledgment. The old stream stays.
            self.next = null;
            const c = s.change.?;
            if (s.result) |_| {
                log.warn("the listen stream for a change of the subscriptions ended before its acknowledgment", .{});
                c.respond.fail(c.respond.context, translate.errorFor(.invalid_response, "subscriptions/listen"));
            } else |e| {
                if (e == error.Canceled) return self.complete(c, .canceled);
                log.warn("the listen stream for a change of the subscriptions failed: {t}", .{e});
                c.respond.fail(c.respond.context, self.errorOf(s, e));
            }
            return self.complete(c, .failed);
        }
        if (s != self.current) return;
        // The stream can send its acknowledgment and end after `reap` read its
        // acknowledgments.
        self.seeAcks(s);
        self.current = null;
        self.gap = true;
        // Only a stream that lived for some time resets the wait. An upstream server can end
        // each stream at once after its acknowledgment.
        if (s.acked_at) |at| {
            if (at.durationTo(self.now()).raw.nanoseconds >= self.options.stable.nanoseconds) self.backoff = self.options.backoff;
        }
        if (s.result) |_| {
            // A server ends its streams with a result at its stop, for example.
            if (self.upstream.gone()) {
                log.debug("the listen stream ended with the upstream server", .{});
                self.reopen = false;
                return;
            }
            log.info("the upstream server ended the listen stream. A new stream follows in {f}.", .{translate.TimeLimit{ .duration = self.backoff }});
            return self.scheduleRetry();
        } else |e| switch (e) {
            error.Closed, error.TransportFailed, error.Timeout => {
                if (self.upstream.gone()) {
                    log.debug("the listen stream ended with the upstream server", .{});
                    self.reopen = false;
                    return;
                }
                log.warn("the listen stream ended: {t}. A new stream follows in {f}.", .{ e, translate.TimeLimit{ .duration = self.backoff } });
                return self.scheduleRetry();
            },
            error.Canceled => {
                log.debug("the listen stream ended with a cancellation", .{});
                self.reopen = false;
            },
            error.Rpc => {
                if (s.diag.rpc_error) |rpc| {
                    log.warn("the upstream server refused the listen stream with the error {d}: {s}. The bridge sends no more list changes.", .{ rpc.code, rpc.message });
                } else log.warn("the upstream server refused the listen stream. The bridge sends no more list changes.", .{});
                self.reopen = false;
            },
            // An HTTP status without a JSON-RPC message, for example 503 from a proxy while
            // the upstream server restarts. Only a status that can change makes a new stream.
            error.InvalidResponse => {
                const status = s.diag.http_status orelse 0;
                if (transientStatus(status)) {
                    log.warn("the listen stream ended with the HTTP status {d}. A new stream follows in {f}.", .{ status, translate.TimeLimit{ .duration = self.backoff } });
                    return self.scheduleRetry();
                }
                // The sign-in of the stream did not complete, for example because the user
                // declined it. A later sign-in of another request makes the token usable.
                if (status == 401 or status == 403) if (self.options.sign_ins) |count| {
                    log.warn("the listen stream failed with the HTTP status {d}. A new stream follows after the next sign-in.", .{status});
                    self.reopen = false;
                    self.sign_in_wait = count.load(.acquire);
                    return;
                };
                if (status == 0) {
                    log.warn("the listen stream failed: {t}. The bridge sends no more list changes.", .{e});
                } else log.warn("the listen stream failed with the HTTP status {d}. The bridge sends no more list changes.", .{status});
                self.reopen = false;
            },
            else => {
                log.warn("the listen stream failed: {t}. The bridge sends no more list changes.", .{e});
                self.reopen = false;
            },
        }
    }

    /// The error for the client after the failure `e` of the stream of a change.
    fn errorOf(self: *Listener, s: *Stream, e: Upstream.RequestError) translate.RpcError {
        return switch (e) {
            error.Rpc => if (s.diag.rpc_error) |rpc| translate.fromUpstream(rpc) else translate.errorFor(.rpc, null),
            error.Closed => translate.errorFor(if (self.upstream.gone()) .upstream_exited else .closed, "subscriptions/listen"),
            else => translate.errorFor(translate.causeOf(e), "subscriptions/listen"),
        };
    }

    /// True for an HTTP status that can change for the same request. These are 408, 429, and
    /// each status from 500 to 599 except 501 (not implemented).
    fn transientStatus(status: u16) bool {
        return status == 408 or status == 429 or (status >= 500 and status <= 599 and status != 501);
    }

    fn scheduleRetry(self: *Listener) void {
        self.retry_at = self.now().addDuration(.{ .raw = self.backoff, .clock = .awake });
        const doubled: Io.Duration = .fromNanoseconds(self.backoff.nanoseconds *| 2);
        self.backoff = if (doubled.nanoseconds > self.options.max_backoff.nanoseconds) self.options.max_backoff else doubled;
        _ = self.retries.fetchAdd(1, .release);
    }

    fn now(self: *const Listener) Io.Clock.Timestamp {
        return Io.Clock.Timestamp.now(self.io, .awake);
    }

    /// Start the change `c`.
    fn begin(self: *Listener, c: *Change) void {
        var fallback = std.heap.stackFallback(1024, self.gpa);
        var scratch: std.heap.ArenaAllocator = .init(fallback.get());
        defer scratch.deinit();
        const uris = self.changedUris(scratch.allocator(), c) catch {
            c.respond.fail(c.respond.context, translate.errorFor(.out_of_memory, null));
            return self.complete(c, .failed);
        } orelse {
            c.respond.ok(c.respond.context);
            return self.complete(c, .unchanged);
        };
        if (uris.len == 0 and !self.options.hasLists()) {
            // The last URI went away, and the client knows no list: no stream is necessary.
            // No event of the old stream goes to the client after the response. The old
            // stream can still give an event that the upstream server wrote before it read
            // the cancellation. The generation of no stream is active, thus a late first
            // acknowledgment of the old stream does not make it active again.
            self.generation += 1;
            self.active.store(self.generation, .release);
            c.respond.ok(c.respond.context);
            if (self.current) |old| self.retire(old);
            self.current = null;
            self.setUris(uris);
            return self.complete(c, .changed);
        }
        self.next = self.open(uris, c) catch |e| {
            log.warn("cannot open a listen stream for a change of the subscriptions: {t}", .{e});
            c.respond.fail(c.respond.context, translate.errorFor(.out_of_memory, null));
            return self.complete(c, .failed);
        };
    }

    /// The URIs after the change `c`, in `arena`, or null when the change gives the same URIs.
    fn changedUris(self: *const Listener, arena: Allocator, c: *const Change) Allocator.Error!?[]const []const u8 {
        const index: ?usize = for (self.uris.items, 0..) |u, i| {
            if (std.mem.eql(u8, u, c.uri)) break i;
        } else null;
        var out: std.ArrayList([]const u8) = .empty;
        switch (c.kind) {
            .subscribe => {
                if (index != null) return null;
                try out.ensureTotalCapacity(arena, self.uris.items.len + 1);
                for (self.uris.items) |u| out.appendAssumeCapacity(u);
                out.appendAssumeCapacity(c.uri);
            },
            .unsubscribe => {
                const skip = index orelse return null;
                try out.ensureTotalCapacity(arena, self.uris.items.len);
                for (self.uris.items, 0..) |u, i| if (i != skip) out.appendAssumeCapacity(u);
            },
        }
        return out.items;
    }

    /// After a stream that failed with 401 or 403: allow a new stream when a sign-in completed
    /// after the end of that stream.
    fn resumeAfterSignIn(self: *Listener) void {
        const seen = self.sign_in_wait orelse return;
        const count = self.options.sign_ins orelse return;
        if (count.load(.acquire) == seen) return;
        log.info("a sign-in completed. The bridge opens the listen stream again.", .{});
        self.sign_in_wait = null;
        self.reopen = true;
        self.retry_at = null;
    }

    /// Open a stream after a loss, or the first stream, when it is time.
    fn reconnect(self: *Listener) void {
        if (self.current != null or self.next != null or !self.reopen) return;
        if (!self.options.hasLists() and self.uris.items.len == 0) return;
        if (self.retry_at) |at| {
            if (self.now().durationTo(at).raw.nanoseconds > 0) return;
        }
        self.retry_at = null;
        self.current = self.open(self.uris.items, null) catch |e| {
            log.warn("cannot open a listen stream: {t}", .{e});
            return self.scheduleRetry();
        };
    }

    /// Make a stream with the filter for `uris`, and start its task. `uris` can point into
    /// memory that the function does not keep.
    fn open(self: *Listener, uris: []const []const u8, c: ?*Change) (Allocator.Error || Io.ConcurrentError)!*Stream {
        try self.streams.ensureUnusedCapacity(self.gpa, 1);
        self.generation += 1;
        const s = try Stream.create(self, uris, c);
        errdefer s.destroy();
        try self.group.concurrent(self.io, Stream.run, .{s});
        self.streams.appendAssumeCapacity(s);
        return s;
    }

    /// Cancel a stream. Its task ends later, and `reap` releases it.
    fn retire(self: *Listener, s: *Stream) void {
        s.retired = true;
        s.token.cancel(self.io, replaced_reason);
    }

    fn complete(self: *Listener, c: *Change, outcome: Change.Outcome) void {
        c.outcome = outcome;
        c.done.set(self.io);
    }

    fn setUris(self: *Listener, uris: []const []const u8) void {
        self.clearUris();
        self.uris.ensureTotalCapacity(self.gpa, uris.len) catch return log.warn("the bridge has no memory for the subscribed URIs", .{});
        for (uris) |u| {
            const copy = self.gpa.dupe(u8, u) catch return log.warn("the bridge has no memory for the subscribed URIs", .{});
            self.uris.appendAssumeCapacity(copy);
        }
    }

    fn clearUris(self: *Listener) void {
        for (self.uris.items) |u| self.gpa.free(u);
        self.uris.clearRetainingCapacity();
    }

    /// The end of `run`: cancel each stream, wait for the tasks of the streams, and end each
    /// change that waits.
    fn finish(self: *Listener) void {
        {
            // After this block, `change` puts no change into the queue.
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            self.stopping = true;
        }
        for (self.streams.items) |s| s.token.cancel(self.io, stop_reason);
        // The streams end soon after their cancellation. A cancellation of the owner task
        // also goes to them. After the end of a task, no callback of its stream runs.
        self.group.await(self.io) catch {};
        if (self.next) |s| {
            self.next = null;
            if (s.change) |c| self.complete(c, .canceled);
        }
        for (self.streams.items) |s| s.destroy();
        self.streams.clearRetainingCapacity();
        self.current = null;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            for (self.queue.items) |c| self.complete(c, .canceled);
            self.queue.clearRetainingCapacity();
        }
        self.running.store(false, .release);
    }

    // -----------------------------------------------------------------------------------------
    // The callbacks of the streams
    // -----------------------------------------------------------------------------------------

    /// After a gap: one list change for each list that the client knows, and one update for
    /// each URI of `uris`. The client then reads the lists and the resources again.
    fn writeGap(self: *Listener, uris: []const []const u8) void {
        self.writeListChanges();
        self.writeUpdates(uris);
    }

    /// Write one list change for each list that the client knows.
    fn writeListChanges(self: *Listener) void {
        if (self.options.tools) self.host.write("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
        if (self.options.prompts) self.host.write("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/prompts/list_changed\"}");
        if (self.options.resources) self.host.write("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\"}");
    }

    /// Write one `notifications/resources/updated` for each URI of `uris`. Each frame has its
    /// own scratch memory.
    fn writeUpdates(self: *Listener, uris: []const []const u8) void {
        for (uris) |uri| {
            var fallback = std.heap.stackFallback(1024, self.gpa);
            var scratch: std.heap.ArenaAllocator = .init(fallback.get());
            defer scratch.deinit();
            const frame = mcp.json.writeAlloc(scratch.allocator(), mcp.jsonrpc.message.OutNotification(Updated){
                .method = "notifications/resources/updated",
                .params = .{ .uri = uri },
            }) catch {
                log.debug("dropped an update of a resource after a gap of the listen stream: no memory", .{});
                continue;
            };
            self.host.write(frame);
        }
    }

    /// The params of `notifications/resources/updated`.
    const Updated = struct { uri: []const u8 };
};

/// One `subscriptions/listen` request and its task.
const Stream = struct {
    listener: *Listener,
    arena: std.heap.ArenaAllocator,
    token: CancelToken = .{},
    generation: u64,
    /// The URIs of the filter, in `arena`.
    uris: []const []const u8,
    /// The filter of the request, in `arena`.
    filter: Value,
    /// Write one list change for each list that the client knows after the first
    /// acknowledgment.
    after_gap: bool,
    /// The change whose response the first acknowledgment writes, or null.
    change: ?*Change,
    /// The number of acknowledgments. Only the callback changes it, after it wrote its
    /// frames.
    acks: std.atomic.Value(u32) = .init(0),
    /// The subscription id of the last acknowledgment, as JSON text. The callback writes it
    /// before it changes `acks`.
    subscription_id: [32]u8 = undefined,
    subscription_id_len: usize = 0,
    /// The JSON-RPC error after `error.Rpc`, in `arena`.
    diag: mcp.Client.Diagnostics = .{},
    /// The result of the request. The task sets it before `ended`.
    result: Upstream.RequestError!void = {},
    ended: std.atomic.Value(bool) = .init(false),
    // The fields below belong to the owner task.
    /// The number of acknowledgments that the owner task processed.
    seen: u32 = 0,
    /// The time when the owner task saw the first acknowledgment, or null.
    acked_at: ?Io.Clock.Timestamp = null,
    /// True after the owner task canceled the stream.
    retired: bool = false,

    fn create(listener: *Listener, uris: []const []const u8, c: ?*Change) Allocator.Error!*Stream {
        const gpa = listener.gpa;
        const s = try gpa.create(Stream);
        errdefer gpa.destroy(s);
        s.* = .{
            .listener = listener,
            .arena = .init(gpa),
            .generation = listener.generation,
            .uris = &.{},
            .filter = .null,
            .after_gap = listener.gap,
            .change = c,
        };
        errdefer s.arena.deinit();
        const arena = s.arena.allocator();
        const copy = try arena.alloc([]const u8, uris.len);
        for (uris, copy) |u, *out| out.* = try arena.dupe(u8, u);
        s.uris = copy;
        s.filter = try filterOf(arena, listener.options, copy);
        return s;
    }

    fn destroy(s: *Stream) void {
        const gpa = s.listener.gpa;
        s.arena.deinit();
        gpa.destroy(s);
    }

    /// The task of the stream. After `ended`, the task does not use the stream, because the
    /// owner task can release it.
    fn run(s: *Stream) Io.Cancelable!void {
        const listener = s.listener;
        const io = listener.io;
        if (listener.upstream.listen(s.arena.allocator(), s.filter, .{
            .cancel = &s.token,
            .on_notification = onEvent,
            .context = s,
            .log_level = listener.host.logLevel(),
            .diagnostics = &s.diag,
        })) |_| {
            s.result = {};
        } else |e| {
            s.result = e;
        }
        s.ended.store(true, .release);
        listener.wake.set(io);
    }

    /// The callback of the stream. See the comment of the file for its rules.
    fn onEvent(context: ?*anyopaque, method: []const u8, params: ?Value) void {
        const s: *Stream = @ptrCast(@alignCast(context.?));
        const listener = s.listener;
        var fallback = std.heap.stackFallback(2048, listener.gpa);
        var scratch: std.heap.ArenaAllocator = .init(fallback.get());
        defer scratch.deinit();
        const event = translate.listenEvent(scratch.allocator(), method, params) catch {
            log.debug("dropped the notification {s} of the listen stream: no memory", .{method});
            return;
        };
        switch (event) {
            .acknowledged => s.acknowledged(params),
            .forward => |p| {
                // The first check saves the work for a stream that is not active. The check
                // under the output lock decides.
                if (listener.active.load(.acquire) == s.generation) {
                    const frame = mcp.json.writeAlloc(scratch.allocator(), mcp.jsonrpc.message.OutNotification(?Value){ .method = method, .params = p }) catch return;
                    if (listener.host.writeIf(frame, &listener.active, s.generation)) return;
                }
                log.debug("dropped the notification {s} of a listen stream that has no acknowledgment, or that a newer stream replaced", .{method});
            },
            .drop => log.debug("dropped the notification {s} of the listen stream", .{method}),
        }
    }

    /// An acknowledgment. The first acknowledgment makes the stream active and writes the
    /// response of the change. After a gap, the client gets the list changes and the updates.
    fn acknowledged(s: *Stream, params: ?Value) void {
        const listener = s.listener;
        s.recordSubscriptionId(params);
        const n = s.acks.load(.monotonic) + 1;
        if (n == 1) {
            // The generations only increase. A newer stream can send its acknowledgment first,
            // and then this stream does not become active. The stream of a change is always
            // the newest stream.
            //
            // The stream becomes active before the response. Thus an event of the old stream
            // goes out before the response, or it does not go out (`Host.writeIf`).
            const before = listener.active.fetchMax(s.generation, .acq_rel);
            // The response goes out before an event of the new stream, because the client
            // reads the events of a URI only after the response.
            if (s.change) |c| c.respond.ok(c.respond.context);
            if (before < s.generation and s.after_gap) listener.writeGap(s.uris);
        } else if (listener.active.load(.acquire) == s.generation) {
            // The client of zig-sdk opened the stream again. Events can be lost in the gap.
            // A stream that a newer stream replaced gives no list change and no update.
            listener.writeGap(s.uris);
        }
        log.debug("listen stream {s}: acknowledgment {d}", .{ s.subscription_id[0..s.subscription_id_len], n });
        // The owner task sees the acknowledgment before the tests see the count.
        s.acks.store(n, .release);
        _ = listener.acknowledgments.fetchAdd(1, .release);
        listener.wake.set(listener.io);
    }

    fn recordSubscriptionId(s: *Stream, params: ?Value) void {
        const p = params orelse return;
        if (p != .object) return;
        const meta = p.object.get("_meta") orelse return;
        if (meta != .object) return;
        const id = meta.object.get(mcp.protocol.meta.key_subscription_id) orelse return;
        var w: Io.Writer = .fixed(&s.subscription_id);
        mcp.json.write(id, &w) catch {};
        s.subscription_id_len = w.end;
    }
};

/// The `notifications` filter of a listen stream: the lists of `options` and the URIs.
fn filterOf(arena: Allocator, options: Options, uris: []const []const u8) Allocator.Error!Value {
    var filter: std.json.ObjectMap = .empty;
    if (options.tools) try filter.put(arena, "toolsListChanged", .{ .bool = true });
    if (options.prompts) try filter.put(arena, "promptsListChanged", .{ .bool = true });
    if (options.resources) try filter.put(arena, "resourcesListChanged", .{ .bool = true });
    if (uris.len > 0) {
        var list: std.json.Array = .init(arena);
        try list.ensureTotalCapacity(uris.len);
        for (uris) |u| list.appendAssumeCapacity(.{ .string = u });
        try filter.put(arena, "resourceSubscriptions", .{ .array = list });
    }
    return .{ .object = filter };
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const Transport = mcp.transport.Transport;

/// The front end of the tests: it keeps each frame and each response of a change.
const TestHost = struct {
    io: Io,
    lock: Io.Mutex = .init,
    frames: std.ArrayList([]u8) = .empty,
    level: ?types.LoggingLevel = null,

    const vtable: Host.VTable = .{ .write = write, .writeIf = writeIf, .logLevel = logLevel };

    fn host(self: *TestHost) Host {
        return .{ .context = self, .vtable = &vtable };
    }

    fn write(context: *anyopaque, frame: []const u8) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        const copy = testing.allocator.dupe(u8, frame) catch return;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.frames.append(testing.allocator, copy) catch testing.allocator.free(copy);
    }

    /// `lock` stands for the output lock of the front end.
    fn writeIf(context: *anyopaque, frame: []const u8, active: *const std.atomic.Value(u64), generation: u64) bool {
        const self: *TestHost = @ptrCast(@alignCast(context));
        const copy = testing.allocator.dupe(u8, frame) catch return true;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (active.load(.acquire) != generation) {
            testing.allocator.free(copy);
            return false;
        }
        self.frames.append(testing.allocator, copy) catch testing.allocator.free(copy);
        return true;
    }

    fn logLevel(context: *anyopaque) ?types.LoggingLevel {
        const self: *TestHost = @ptrCast(@alignCast(context));
        return self.level;
    }

    fn deinit(self: *TestHost) void {
        for (self.frames.items) |f| testing.allocator.free(f);
        self.frames.deinit(testing.allocator);
    }

    fn count(self: *TestHost) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.frames.items.len;
    }

    /// The frames, parsed in `arena`.
    fn parsed(self: *TestHost, arena: Allocator) ![]Value {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const out = try arena.alloc(Value, self.frames.items.len);
        for (self.frames.items, out) |f, *v| v.* = try mcp.json.parseTree(arena, f);
        return out;
    }

    /// The method of each frame, or "response" for a response.
    fn methods(self: *TestHost, arena: Allocator) ![]const []const u8 {
        const frames = try self.parsed(arena);
        const out = try arena.alloc([]const u8, frames.len);
        for (frames, out) |f, *m| m.* = mcp.json.getString(f, "method") orelse "response";
        return out;
    }

    /// The number of frames with the method `method`.
    fn methodCount(self: *TestHost, arena: Allocator, method: []const u8) !usize {
        var n: usize = 0;
        for (try self.methods(arena)) |m| n += @intFromBool(std.mem.eql(u8, m, method));
        return n;
    }

    /// Wait until there are `n` frames, at most five seconds.
    fn waitFor(self: *TestHost, n: usize) !void {
        var i: usize = 0;
        while (self.count() < n) : (i += 1) {
            if (i > 5000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

/// The response of a change in the tests. It writes a response frame with the id `id` to the
/// host, thus the tests see the order of the response and the events.
const TestResponse = struct {
    host: *TestHost,
    id: i64,
    /// The error of `fail`, or null.
    err: ?translate.RpcError = null,

    fn respond(self: *TestResponse) Respond {
        return .{ .context = self, .ok = ok, .fail = fail };
    }

    fn ok(context: *anyopaque) void {
        const self: *TestResponse = @ptrCast(@alignCast(context));
        var buf: [64]u8 = undefined;
        TestHost.write(self.host, std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}", .{self.id}) catch unreachable);
    }

    fn fail(context: *anyopaque, err: translate.RpcError) void {
        const self: *TestResponse = @ptrCast(@alignCast(context));
        self.err = err;
        var buf: [96]u8 = undefined;
        TestHost.write(self.host, std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"m\"}}}}", .{ self.id, err.code }) catch unreachable);
    }
};

/// An upstream server for the listen streams of the tests. Each `subscriptions/listen` is one
/// attempt, and `plan` tells what each attempt does. After the last item of `plan`, an attempt
/// sends its acknowledgment and waits for its cancellation. `publish` sends an event to the
/// open streams, as `mcp.Server` does on the memory link.
const FakeServer = struct {
    io: Io,
    plan: []const Attempt = &.{},
    lock: Io.Mutex = .init,
    /// Each attempt, in the order of its start. Guarded by `lock`.
    attempts: std.ArrayList(Record) = .empty,
    /// The streams after their acknowledgment, until their end. Guarded by `lock`.
    open: std.ArrayList(*Open) = .empty,
    /// The acknowledgments and the cancellations in their order, for example "ack 1" and
    /// "cancel 0". "acked 1" follows the callback of the acknowledgment of attempt 1. Guarded
    /// by `lock`.
    notes: std.ArrayList([]u8) = .empty,

    const Attempt = struct {
        ack: bool = true,
        /// Send the acknowledgment only after the callback of the acknowledgment of the
        /// attempt with this index. The attempt sends it also after its cancellation, as an
        /// upstream server that wrote the acknowledgment before it read the cancellation.
        ack_after: ?usize = null,
        /// The frames after the acknowledgment. The text `{sid}` becomes the subscription id.
        events: []const []const u8 = &.{},
        end: End = .wait,
        /// With `end = .wait`, a frame after the cancellation, or null. An upstream server
        /// can write an event before it reads the cancellation.
        late: ?[]const u8 = null,
        /// The HTTP status of `end = .http_status`.
        status: u16 = 401,

        const End = enum {
            /// Wait for the cancellation.
            wait,
            /// Return `error.Closed`, as after a lost connection.
            closed,
            /// Send the result of the stream.
            result,
            /// Send a JSON-RPC error.
            rpc_error,
            /// Answer with the HTTP status `status` and no JSON-RPC message, as the HTTP
            /// client transport does after a challenge that the sign-in did not answer.
            http_status,
        };
    };

    const Record = struct {
        at: Io.Clock.Timestamp,
        /// The URIs of the filter, in `testing.allocator`.
        uris: [][]u8,
        tools: bool,
        /// The log level of the request, in `testing.allocator`, or null.
        level: ?[]u8,
    };

    const Open = struct {
        ex: *Transport.Exchange,
        record: usize,
    };

    const vtable: Transport.ClientTransport.VTable = .{ .kind = .memory, .exchange = exchange, .notify = onNotify };

    fn transport(self: *FakeServer) Transport.ClientTransport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn deinit(self: *FakeServer) void {
        const gpa = testing.allocator;
        for (self.attempts.items) |r| {
            for (r.uris) |u| gpa.free(u);
            gpa.free(r.uris);
            if (r.level) |l| gpa.free(l);
        }
        self.attempts.deinit(gpa);
        self.open.deinit(gpa);
        for (self.notes.items) |n| gpa.free(n);
        self.notes.deinit(gpa);
    }

    fn attemptCount(self: *FakeServer) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.attempts.items.len;
    }

    fn openCount(self: *FakeServer) usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.open.items.len;
    }

    /// A copy of the record of attempt `index`. The URIs stay in the server.
    fn attempt(self: *FakeServer, index: usize) Record {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.attempts.items[index];
    }

    /// Wait until there are `n` attempts, at most five seconds.
    fn waitAttempts(self: *FakeServer, n: usize) !void {
        var i: usize = 0;
        while (self.attemptCount() < n) : (i += 1) {
            if (i > 5000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    /// Wait until `n` streams are open, at most five seconds.
    fn waitOpen(self: *FakeServer, n: usize) !void {
        var i: usize = 0;
        while (self.openCount() != n) : (i += 1) {
            if (i > 5000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    /// The index of the note `text`, or null.
    fn noteIndex(self: *FakeServer, text: []const u8) ?usize {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.notes.items, 0..) |n, i| if (std.mem.eql(u8, n, text)) return i;
        return null;
    }

    fn note(self: *FakeServer, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(testing.allocator, format, args) catch return;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.notes.append(testing.allocator, text) catch testing.allocator.free(text);
    }

    /// Send the event `template` to each open stream whose filter has `uri`, or to each open
    /// stream when `uri` is null.
    fn publish(self: *FakeServer, template: []const u8, uri: ?[]const u8) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.open.items) |o| {
            if (uri) |u| {
                const r = self.attempts.items[o.record];
                for (r.uris) |have| {
                    if (std.mem.eql(u8, have, u)) break;
                } else continue;
            }
            try deliver(o.ex, template);
        }
    }

    /// Give `template` to the stream of `ex`, with its subscription id.
    fn deliver(ex: *Transport.Exchange, template: []const u8) !void {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{ex.id.integer});
        const frame = try std.mem.replaceOwned(u8, testing.allocator, template, "{sid}", id);
        defer testing.allocator.free(frame);
        ex.deliver(testing.io, frame) catch return error.TestDeliverFailed;
    }

    fn exchange(ptr: *anyopaque, io: Io, ex: *Transport.Exchange) Transport.ExchangeError!void {
        const self: *FakeServer = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, ex.method, "subscriptions/listen")) return error.Closed;
        const index, const plan = self.record(io, ex) catch return error.OutOfMemory;
        if (!plan.ack) return end(ex, plan);
        if (plan.ack_after) |other| try self.waitNote(io, other);
        // The note and the open stream come before the acknowledgment, because the listener
        // can cancel the old stream at once after it.
        self.note("ack {d}", .{index});
        var open: Open = .{ .ex = ex, .record = index };
        {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            self.open.append(testing.allocator, &open) catch return error.OutOfMemory;
        }
        defer {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            for (self.open.items, 0..) |o, i| if (o == &open) {
                _ = self.open.swapRemove(i);
                break;
            };
        }
        deliver(ex, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid}},\"notifications\":{}}}") catch return error.InvalidFrame;
        // The listen streams use `inline_notifications`, thus the callback ran.
        self.note("acked {d}", .{index});
        for (plan.events) |e| deliver(ex, e) catch return error.InvalidFrame;
        if (plan.end != .wait) return end(ex, plan);
        // At most ten seconds, so that a failed test does not stop the test run.
        var i: usize = 0;
        while (!ex.cancel.isCancelled() and i < 10_000) : (i += 1) try io.sleep(.fromMilliseconds(1), .awake);
        self.note("cancel {d}", .{index});
        if (plan.late) |frame| deliver(ex, frame) catch return error.InvalidFrame;
        return error.Canceled;
    }

    /// Wait until the callback of the acknowledgment of attempt `index` ran, at most ten
    /// seconds. A cancellation does not end the wait.
    fn waitNote(self: *FakeServer, io: Io, index: usize) Transport.ExchangeError!void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "acked {d}", .{index}) catch unreachable;
        var i: usize = 0;
        while (self.noteIndex(text) == null) : (i += 1) {
            if (i > 10_000) return error.Timeout;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn end(ex: *Transport.Exchange, plan: Attempt) Transport.ExchangeError!void {
        switch (plan.end) {
            .wait => unreachable,
            .closed => return error.Closed,
            .result => deliver(ex, "{\"jsonrpc\":\"2.0\",\"id\":{sid},\"result\":{\"resultType\":\"complete\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid}}}}") catch return error.InvalidFrame,
            .rpc_error => deliver(ex, "{\"jsonrpc\":\"2.0\",\"id\":{sid},\"error\":{\"code\":-32603,\"message\":\"Subscription filter too large\"}}") catch return error.InvalidFrame,
            .http_status => {
                ex.http_status = plan.status;
                return error.HttpStatus;
            },
        }
    }

    /// Keep the time and the filter of an attempt. Returns its index and its plan.
    fn record(self: *FakeServer, io: Io, ex: *Transport.Exchange) !struct { usize, Attempt } {
        const gpa = testing.allocator;
        const params = ex.params orelse return error.TestNoParams;
        const filter = params.object.get("notifications").?;
        var uris: std.ArrayList([]u8) = .empty;
        defer {
            for (uris.items) |u| gpa.free(u);
            uris.deinit(gpa);
        }
        if (filter.object.get("resourceSubscriptions")) |list| for (list.array.items) |u| {
            const copy = try gpa.dupe(u8, u.string);
            uris.append(gpa, copy) catch {
                gpa.free(copy);
                return error.OutOfMemory;
            };
        };
        const meta = params.object.get("_meta").?;
        const level: ?[]u8 = if (mcp.json.getString(meta, mcp.protocol.meta.key_log_level)) |l| try gpa.dupe(u8, l) else null;
        errdefer if (level) |l| gpa.free(l);
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        const index = self.attempts.items.len;
        try self.attempts.ensureUnusedCapacity(gpa, 1);
        const owned = try uris.toOwnedSlice(gpa);
        self.attempts.appendAssumeCapacity(.{
            .at = Io.Clock.Timestamp.now(io, .awake),
            .uris = owned,
            .tools = filter.object.get("toolsListChanged") != null,
            .level = level,
        });
        return .{ index, if (index < self.plan.len) self.plan[index] else .{} };
    }

    fn onNotify(ptr: *anyopaque, io: Io, frame: []const u8) Transport.SendError!void {
        _ = .{ ptr, io, frame };
    }
};

/// A listener with a fake upstream server and a test host.
const TestListener = struct {
    fake: FakeServer,
    host: TestHost,
    upstream: *Upstream,
    listener: Listener,
    group: Io.Group = .init,
    arena_state: std.heap.ArenaAllocator,
    /// The log level of the tests before `create`. The tests expect the warnings of the
    /// listener.
    saved_level: std.log.Level,

    /// Start a listener. `level` is the log level of the client.
    fn create(plan: []const FakeServer.Attempt, options: Options, level: ?types.LoggingLevel) !*TestListener {
        const io = testing.io;
        const gpa = testing.allocator;
        const self = try gpa.create(TestListener);
        errdefer gpa.destroy(self);
        self.* = .{
            .fake = .{ .io = io, .plan = plan },
            .host = .{ .io = io, .level = level },
            .upstream = undefined,
            .listener = undefined,
            .arena_state = .init(gpa),
            .saved_level = testing.log_level,
        };
        self.upstream = try Upstream.init(io, gpa, .{ .transport = self.fake.transport() });
        errdefer self.upstream.deinit();
        try self.upstream.connect(.{ .name = "notify-test", .version = "1" }, .{});
        testing.log_level = .err;
        errdefer testing.log_level = self.saved_level;
        self.listener = .init(io, gpa, self.upstream);
        try self.listener.start(&self.group, self.host.host(), options);
        return self;
    }

    /// Stop the listener and release all.
    fn destroy(self: *TestListener) void {
        self.stop();
        self.listener.deinit();
        self.upstream.deinit();
        self.fake.deinit();
        self.host.deinit();
        self.arena_state.deinit();
        testing.log_level = self.saved_level;
        testing.allocator.destroy(self);
    }

    fn stop(self: *TestListener) void {
        self.listener.stop();
        self.group.await(testing.io) catch {};
    }

    fn arena(self: *TestListener) Allocator {
        return self.arena_state.allocator();
    }

    /// Wait until the streams have `n` acknowledgments, at most five seconds.
    fn waitAcks(self: *TestListener, n: u64) !void {
        var i: usize = 0;
        while (self.listener.acknowledgments.load(.acquire) < n) : (i += 1) {
            if (i > 5000) return error.TestTimeout;
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

/// Run `Listener.change` in a task of a group, and count the return.
fn changeTask(listener: *Listener, c: *Change, returned: *std.atomic.Value(usize)) Io.Cancelable!void {
    listener.change(c);
    _ = returned.fetchAdd(1, .release);
}

/// Do each change of `changes` in its own task, at the same time, and wait until each call of
/// `Listener.change` returns, at most five seconds. After that time, the function stops the
/// listener, thus each change ends, and it returns `error.TestTimeout`. Thus a change that
/// does not end does not stop the test run.
fn changeWithin(t: *TestListener, changes: []const *Change) !void {
    var returned: std.atomic.Value(usize) = .init(0);
    var group: Io.Group = .init;
    defer group.await(testing.io) catch {};
    // On an error, the stop ends each change before the wait for the group.
    errdefer t.listener.stop();
    for (changes) |c| try group.concurrent(testing.io, changeTask, .{ &t.listener, c, &returned });
    var i: usize = 0;
    while (returned.load(.acquire) < changes.len) : (i += 1) {
        if (i > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

const all_lists: Options = .{ .tools = true, .prompts = true, .resources = true, .backoff = .fromMilliseconds(10), .max_backoff = .fromMilliseconds(40) };

const list_changes = [_][]const u8{
    "notifications/tools/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/list_changed",
};

fn expectMethods(expected: []const []const u8, actual: []const []const u8) !void {
    if (expected.len == actual.len) {
        for (expected, actual) |want, got| {
            if (!std.mem.eql(u8, want, got)) break;
        } else return;
    }
    std.debug.print("\nexpected the methods {f}, got {f}\n", .{ std.json.fmt(expected, .{}), std.json.fmt(actual, .{}) });
    return error.TestExpectedEqual;
}

test "an HTTP status that can change makes a new listen stream" {
    for ([_]u16{ 408, 429, 500, 502, 503, 504, 599 }) |status| try testing.expect(Listener.transientStatus(status));
    for ([_]u16{ 0, 200, 202, 400, 401, 403, 404, 405, 413, 501, 600 }) |status| try testing.expect(!Listener.transientStatus(status));
}

test "a stream that gets 401 or 403 waits for the next sign-in and not for a timer, and without a sign-in it stops" {
    for ([_]u16{ 401, 403 }) |status| {
        var sign_ins: std.atomic.Value(u64) = .init(0);
        var options = all_lists;
        options.sign_ins = &sign_ins;
        const t = try TestListener.create(&.{.{ .ack = false, .end = .http_status, .status = status }}, options, null);
        defer t.destroy();
        try t.fake.waitAttempts(1);
        // Many times the longest wait of a loss: no new stream on a timer.
        try testing.io.sleep(.fromMilliseconds(200), .awake);
        try testing.expectEqual(@as(usize, 1), t.fake.attemptCount());
        // A wake without a new sign-in opens no stream.
        t.listener.signedIn();
        try testing.io.sleep(.fromMilliseconds(50), .awake);
        try testing.expectEqual(@as(usize, 1), t.fake.attemptCount());
        // A sign-in of another request opens the stream again. The client gets the list
        // changes of the gap.
        _ = sign_ins.fetchAdd(1, .release);
        t.listener.signedIn();
        try t.waitAcks(1);
        try testing.expectEqual(@as(usize, 2), t.fake.attemptCount());
        try t.host.waitFor(list_changes.len);
        try expectMethods(&list_changes, try t.host.methods(t.arena()));
    }
    // Without a sign-in, the status stops the new streams, also after a wake.
    const t = try TestListener.create(&.{.{ .ack = false, .end = .http_status, .status = 401 }}, all_lists, null);
    defer t.destroy();
    try t.fake.waitAttempts(1);
    t.listener.signedIn();
    try testing.io.sleep(.fromMilliseconds(200), .awake);
    try testing.expectEqual(@as(usize, 1), t.fake.attemptCount());
}

test "only the four events go to the client, without the subscription id" {
    const meta = "\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid}}";
    const t = try TestListener.create(&.{.{
        .events = &.{
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{" ++ meta ++ "}}",
            // A listen stream that ends with a cancellation of a third-party server.
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1," ++ meta ++ "}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"error\",\"data\":\"x\"," ++ meta ++ "}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tasks/status\",\"params\":{" ++ meta ++ "}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid},\"k\":1}}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/prompts/list_changed\",\"params\":{" ++ meta ++ "}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\"}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}",
            // A second acknowledgment in one stream.
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{" ++ meta ++ "}}",
        },
    }}, all_lists, null);
    defer t.destroy();
    // The first acknowledgment gives the list changes, and the second gives them again.
    try t.waitAcks(2);
    try t.host.waitFor(3 + 4 + 3);
    const a = t.arena();
    try expectMethods(&(list_changes ++ [_][]const u8{
        "notifications/tools/list_changed",
        "notifications/resources/updated",
        "notifications/prompts/list_changed",
        "notifications/resources/list_changed",
    } ++ list_changes), try t.host.methods(a));
    for (try t.host.parsed(a)) |f| {
        const params = f.object.get("params") orelse continue;
        try testing.expectEqualStrings("notifications/resources/updated", mcp.json.getString(f, "method").?);
        try testing.expectEqualStrings("file:///a", mcp.json.getString(params, "uri").?);
        // The other keys of `_meta` stay.
        const kept = params.object.get("_meta").?;
        try testing.expectEqual(@as(usize, 1), kept.object.count());
        try testing.expectEqual(@as(i64, 1), kept.object.get("k").?.integer);
    }
    // The stream asks for the lists, and for no URI.
    const first = t.fake.attempt(0);
    try testing.expect(first.tools);
    try testing.expectEqual(@as(usize, 0), first.uris.len);
    try testing.expect(first.level == null);
}

test "the response of a change comes before the first event of the new stream, and the old stream ends after the acknowledgment" {
    const t = try TestListener.create(&.{}, all_lists, .warning);
    defer t.destroy();
    try t.waitAcks(1);
    const a = t.arena();
    var r1: TestResponse = .{ .host = &t.host, .id = 7 };
    var c1: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r1.respond() };
    try changeWithin(t, &.{&c1});
    try testing.expectEqual(Change.Outcome.changed, c1.outcome);
    try testing.expectEqual(@as(usize, 2), t.fake.attemptCount());
    const second = t.fake.attempt(1);
    try testing.expectEqualStrings("file:///a", second.uris[0]);
    // Each stream has the log level of the client.
    try testing.expectEqualStrings("warning", second.level.?);
    // The old stream ends after the acknowledgment of the new stream.
    try t.fake.waitOpen(1);
    try testing.expect(t.fake.noteIndex("ack 1").? < t.fake.noteIndex("cancel 0").?);
    try t.fake.publish("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid}}}}", "file:///a");
    try t.host.waitFor(3 + 2);
    // A change gives no list change: the response, then the event.
    try expectMethods(&(list_changes ++ [_][]const u8{ "response", "notifications/resources/updated" }), try t.host.methods(a));

    // A URI that the set has already, and a URI that it does not have, give `{}` at once and
    // no new stream.
    var r2: TestResponse = .{ .host = &t.host, .id = 8 };
    var c2: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r2.respond() };
    try changeWithin(t, &.{&c2});
    try testing.expectEqual(Change.Outcome.unchanged, c2.outcome);
    var c3: Change = .{ .kind = .unsubscribe, .uri = "file:///b", .respond = r2.respond() };
    try changeWithin(t, &.{&c3});
    try testing.expectEqual(Change.Outcome.unchanged, c3.outcome);
    try testing.expectEqual(@as(usize, 2), t.fake.attemptCount());
    try testing.expectEqual(@as(usize, 3 + 4), t.host.count());

    // Unsubscribe: the new stream has the lists and no URI. An update of the URI does not
    // reach it.
    var c4: Change = .{ .kind = .unsubscribe, .uri = "file:///a", .respond = r2.respond() };
    try changeWithin(t, &.{&c4});
    try testing.expectEqual(Change.Outcome.changed, c4.outcome);
    try testing.expectEqual(@as(usize, 3), t.fake.attemptCount());
    try testing.expectEqual(@as(usize, 0), t.fake.attempt(2).uris.len);
    try t.fake.waitOpen(1);
    try t.fake.publish("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\"}}", "file:///a");
    try testing.expectEqual(@as(usize, 3 + 5), t.host.count());
    try testing.expectEqual(@as(usize, 1), try t.host.methodCount(a, "notifications/resources/updated"));
}

test "two changes at the same time: the last stream has both URIs" {
    const t = try TestListener.create(&.{}, all_lists, null);
    defer t.destroy();
    try t.waitAcks(1);
    var r1: TestResponse = .{ .host = &t.host, .id = 1 };
    var r2: TestResponse = .{ .host = &t.host, .id = 2 };
    var c1: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r1.respond() };
    var c2: Change = .{ .kind = .subscribe, .uri = "file:///b", .respond = r2.respond() };
    try changeWithin(t, &.{ &c1, &c2 });
    try testing.expectEqual(Change.Outcome.changed, c1.outcome);
    try testing.expectEqual(Change.Outcome.changed, c2.outcome);
    try testing.expectEqual(@as(usize, 3), t.fake.attemptCount());
    try testing.expectEqual(@as(usize, 2), t.fake.attempt(2).uris.len);
    try t.fake.waitOpen(1);
    // Each URI gets its update one time.
    const a = t.arena();
    for ([_][]const u8{ "file:///a", "file:///b" }) |uri| {
        const event = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{{\"uri\":\"{s}\"}}}}", .{uri});
        try t.fake.publish(event, uri);
    }
    try testing.expectEqual(@as(usize, 2), try t.host.methodCount(a, "notifications/resources/updated"));
    try testing.expectEqual(@as(usize, 2), try t.host.methodCount(a, "response"));
}

test "a new stream that fails before its acknowledgment keeps the old stream and the old URIs" {
    const t = try TestListener.create(&.{ .{}, .{ .ack = false, .end = .rpc_error } }, all_lists, null);
    defer t.destroy();
    try t.waitAcks(1);
    var r: TestResponse = .{ .host = &t.host, .id = 3 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c});
    try testing.expectEqual(Change.Outcome.failed, c.outcome);
    // The error of the upstream server goes to the client.
    try testing.expectEqual(@as(i64, -32603), r.err.?.code);
    try testing.expectEqualStrings("Subscription filter too large", r.err.?.message);
    try testing.expect(t.fake.noteIndex("cancel 0") == null);
    try testing.expectEqual(@as(usize, 1), t.fake.openCount());
    // The listener still has no URI: the next subscribe opens a stream with one URI.
    var c2: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c2});
    try testing.expectEqual(Change.Outcome.changed, c2.outcome);
    try testing.expectEqual(@as(usize, 1), t.fake.attempt(2).uris.len);
}

test "the list changes after a gap: the first stream, a second acknowledgment and a new stream after a loss" {
    const t = try TestListener.create(&.{
        // The connection fails after the acknowledgment, and the client of zig-sdk opens the
        // stream again in the same request.
        .{ .end = .closed },
        // The upstream server ends the stream with its result.
        .{ .end = .result },
    }, all_lists, null);
    defer t.destroy();
    try t.waitAcks(3);
    try t.host.waitFor(9);
    try expectMethods(&(list_changes ++ list_changes ++ list_changes), try t.host.methods(t.arena()));
    try testing.expectEqual(@as(usize, 3), t.fake.attemptCount());
    // A change gives no list changes.
    var r: TestResponse = .{ .host = &t.host, .id = 4 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c});
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try testing.expectEqual(@as(usize, 10), t.host.count());
}

test "new streams after a loss wait longer each time, and a stream that lived for the stable time resets the wait" {
    const burst = (mcp.Limits{}).max_lost_stream_retries + 1;
    const fail: FakeServer.Attempt = .{ .ack = false, .end = .closed };
    // After the failures, one stream sends its acknowledgment and its result.
    const plan = [_]FakeServer.Attempt{fail} ** (3 * burst) ++ [_]FakeServer.Attempt{.{ .end = .result }};
    // Each stream with an acknowledgment is stable.
    const options: Options = .{ .tools = true, .backoff = .fromMilliseconds(20), .max_backoff = .fromMilliseconds(50), .stable = .fromNanoseconds(0) };
    const t = try TestListener.create(&plan, options, null);
    defer t.destroy();
    try t.waitAcks(2);
    try testing.expectEqual(@as(usize, 3 * burst + 2), t.fake.attemptCount());
    // The client of zig-sdk sends the request again at once, `burst - 1` times. Then the
    // listener waits 20 ms, 40 ms and 50 ms.
    const waits = [_]i64{ 20, 40, 50 };
    for (waits, 1..) |ms, n| {
        const before = t.fake.attempt(n * burst - 1).at;
        const after = t.fake.attempt(n * burst).at;
        const gap = before.durationTo(after).raw.toMilliseconds();
        if (gap < ms) {
            std.debug.print("\nthe wait {d} took {d} ms, not {d} ms or more\n", .{ n, gap, ms });
            return error.TestWaitTooShort;
        }
    }
    // Only the acknowledgments give the list change, one time each.
    try t.host.waitFor(2);
    try expectMethods(&.{ "notifications/tools/list_changed", "notifications/tools/list_changed" }, try t.host.methods(t.arena()));
    // The end of the stable stream reset the wait to 20 ms, and the wait for the next stream
    // doubled it. Without the reset, the wait stays at 50 ms.
    t.stop();
    try testing.expectEqual(@as(i64, 40), t.listener.backoff.toMilliseconds());
}

test "an upstream server that ends each stream after its acknowledgment gets the new streams after longer waits" {
    // The server of zig-sdk does this after `shutdownSubscriptions`: it acknowledges a new
    // stream and ends it at once.
    const ends: FakeServer.Attempt = .{ .end = .result };
    const options: Options = .{ .tools = true, .backoff = .fromMilliseconds(20), .max_backoff = .fromMilliseconds(80) };
    const t = try TestListener.create(&([_]FakeServer.Attempt{ends} ** 5), options, null);
    defer t.destroy();
    try t.waitAcks(6);
    // Each stream follows a loss, thus each acknowledgment gives the list change. The waits
    // between the streams become longer: 20 ms, 40 ms, 80 ms, 80 ms and 80 ms.
    const waits = [_]i64{ 20, 40, 80, 80, 80 };
    for (waits, 0..) |ms, n| {
        const gap = t.fake.attempt(n).at.durationTo(t.fake.attempt(n + 1).at).raw.toMilliseconds();
        if (gap < ms) {
            std.debug.print("\nthe wait {d} took {d} ms, not {d} ms or more\n", .{ n, gap, ms });
            return error.TestWaitTooShort;
        }
    }
    try t.host.waitFor(6);
    try testing.expectEqual(@as(usize, 6), try t.host.methodCount(t.arena(), "notifications/tools/list_changed"));
}

test "a JSON-RPC error ends the new streams, and a change opens a stream again" {
    const t = try TestListener.create(&.{.{ .ack = false, .end = .rpc_error }}, all_lists, null);
    defer t.destroy();
    try t.fake.waitAttempts(1);
    try testing.io.sleep(.fromMilliseconds(100), .awake);
    try testing.expectEqual(@as(usize, 1), t.fake.attemptCount());
    try testing.expectEqual(@as(usize, 0), t.host.count());
    var r: TestResponse = .{ .host = &t.host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c});
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try testing.expectEqual(@as(usize, 2), t.fake.attemptCount());
    // The stream follows a gap, thus the client gets the list changes and an update of the URI
    // after the response.
    try expectMethods(&([_][]const u8{"response"} ++ list_changes ++ [_][]const u8{"notifications/resources/updated"}), try t.host.methods(t.arena()));
}

test "the current stream ends before the owner task sees the acknowledgment of a change: the client gets the list changes" {
    // The owner task sees the two events in one step. The tasks of the streams do not run:
    // the test makes the state of the streams itself.
    const io = testing.io;
    const gpa = testing.allocator;
    var host: TestHost = .{ .io = io };
    defer host.deinit();
    const upstream = try Upstream.init(io, gpa, .{ .transport = undefined });
    defer upstream.deinit();
    var listener: Listener = .init(io, gpa, upstream);
    defer listener.deinit();
    listener.host = host.host();
    listener.options = all_lists;
    listener.gap = false;
    defer {
        for (listener.streams.items) |s| s.destroy();
        listener.streams.clearRetainingCapacity();
    }

    // The current stream had its acknowledgment, and the upstream server ended it.
    try listener.streams.ensureUnusedCapacity(gpa, 2);
    const old = try Stream.create(&listener, &.{}, null);
    listener.streams.appendAssumeCapacity(old);
    old.acks.store(1, .release);
    old.seen = 1;
    old.ended.store(true, .release);
    listener.current = old;

    // The stream of a change started before the end, and it has its acknowledgment.
    var r: TestResponse = .{ .host = &host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    const new = try Stream.create(&listener, &.{"file:///a"}, &c);
    listener.streams.appendAssumeCapacity(new);
    try testing.expect(!new.after_gap);
    new.acks.store(1, .release);
    listener.next = new;

    listener.reap();
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try testing.expect(listener.current == new);
    try testing.expect(listener.retry_at == null);
    try testing.expectEqual(@as(usize, 1), listener.streams.items.len);
    try testing.expectEqualStrings("file:///a", listener.uris.items[0]);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try expectMethods(&(list_changes ++ [_][]const u8{"notifications/resources/updated"}), try host.methods(arena_state.allocator()));
}

test "a second acknowledgment gives the list changes only for the active stream" {
    // The callbacks run on the task of the test. The tasks of the streams do not run.
    const io = testing.io;
    const gpa = testing.allocator;
    var host: TestHost = .{ .io = io };
    defer host.deinit();
    const upstream = try Upstream.init(io, gpa, .{ .transport = undefined });
    defer upstream.deinit();
    var listener: Listener = .init(io, gpa, upstream);
    defer listener.deinit();
    listener.host = host.host();
    listener.options = all_lists;
    listener.gap = false;
    listener.generation = 1;
    const old = try Stream.create(&listener, &.{}, null);
    defer old.destroy();
    listener.generation = 2;
    const new = try Stream.create(&listener, &.{"file:///a"}, null);
    defer new.destroy();

    old.acknowledged(null);
    new.acknowledged(null);
    try testing.expectEqual(@as(u64, 2), listener.active.load(.acquire));
    try testing.expectEqual(@as(usize, 0), host.count());
    // The client of zig-sdk opens the old stream again before its cancellation. The newer
    // stream is active, thus the client gets no list change.
    old.acknowledged(null);
    try testing.expectEqual(@as(usize, 0), host.count());
    // A second acknowledgment of the active stream gives one list change for each list, and
    // one update for each URI of the stream.
    new.acknowledged(null);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectMethods(&(list_changes ++ [_][]const u8{"notifications/resources/updated"}), try host.methods(a));
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///a"}}
    , host.frames.items[3]);
    try testing.expectEqual(@as(u64, 4), listener.acknowledgments.load(.acquire));
}

test "an older stream that sends its first acknowledgment after the stream of a change stays inactive" {
    // The callbacks run on the task of the test. The tasks of the streams do not run.
    const io = testing.io;
    const gpa = testing.allocator;
    var host: TestHost = .{ .io = io };
    defer host.deinit();
    const upstream = try Upstream.init(io, gpa, .{ .transport = undefined });
    defer upstream.deinit();
    var listener: Listener = .init(io, gpa, upstream);
    defer listener.deinit();
    listener.host = host.host();
    listener.options = all_lists;
    defer {
        for (listener.streams.items) |s| s.destroy();
        listener.streams.clearRetainingCapacity();
    }

    // The first stream has no acknowledgment yet, and the stream of a subscribe starts.
    try listener.streams.ensureUnusedCapacity(gpa, 2);
    listener.generation = 1;
    const old = try Stream.create(&listener, &.{}, null);
    listener.streams.appendAssumeCapacity(old);
    listener.current = old;
    var r: TestResponse = .{ .host = &host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    listener.generation = 2;
    const new = try Stream.create(&listener, &.{"file:///a"}, &c);
    listener.streams.appendAssumeCapacity(new);
    listener.next = new;
    try testing.expect(old.after_gap and new.after_gap);

    // An upstream server that runs each request in its own task can acknowledge the new stream
    // first. The new stream gives the response and the frames after the gap. The old stream
    // gives nothing, and it does not become active.
    new.acknowledged(null);
    old.acknowledged(null);
    try testing.expectEqual(@as(u64, 2), listener.active.load(.acquire));
    listener.reap();
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try testing.expect(listener.current == new);
    try testing.expect(old.retired);
    try testing.expectEqual(@as(u64, 2), listener.active.load(.acquire));

    // An event of the new stream reaches the client, and an event of the old stream does not.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const update = try mcp.json.parseTree(a, "{\"uri\":\"file:///a\"}");
    Stream.onEvent(new, "notifications/resources/updated", update);
    Stream.onEvent(old, "notifications/tools/list_changed", null);
    Stream.onEvent(new, "notifications/tools/list_changed", null);
    try expectMethods(&([_][]const u8{"response"} ++ list_changes ++ [_][]const u8{
        "notifications/resources/updated",
        "notifications/resources/updated",
        "notifications/tools/list_changed",
    }), try host.methods(a));
}

test "the stream of a change that acknowledges and ends between two reads of the owner task completes the change" {
    // The tasks of the streams do not run: the test makes the state of the streams itself.
    const io = testing.io;
    const gpa = testing.allocator;
    var host: TestHost = .{ .io = io };
    defer host.deinit();
    const upstream = try Upstream.init(io, gpa, .{ .transport = undefined });
    defer upstream.deinit();
    var listener: Listener = .init(io, gpa, upstream);
    defer listener.deinit();
    listener.host = host.host();
    listener.options = all_lists;
    listener.gap = false;
    defer {
        for (listener.streams.items) |s| s.destroy();
        listener.streams.clearRetainingCapacity();
    }

    try listener.streams.ensureUnusedCapacity(gpa, 2);
    listener.generation = 1;
    const old = try Stream.create(&listener, &.{}, null);
    listener.streams.appendAssumeCapacity(old);
    old.acks.store(1, .release);
    old.seen = 1;
    listener.current = old;
    listener.active.store(1, .release);
    var r: TestResponse = .{ .host = &host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    listener.generation = 2;
    const new = try Stream.create(&listener, &.{"file:///a"}, &c);
    listener.streams.appendAssumeCapacity(new);
    listener.next = new;

    // `reap` read no acknowledgment of the new stream. Then the stream sent its
    // acknowledgment and its result, and the loop of `reap` sees its end.
    new.acknowledged(null);
    new.ended.store(true, .release);
    listener.ended(new);
    // The change has the new URIs, and the new stream ended as the current stream.
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try testing.expect(r.err == null);
    try testing.expect(old.retired);
    try testing.expect(listener.current == null);
    try testing.expect(listener.retry_at != null);
    try testing.expect(listener.gap);
    try testing.expectEqualStrings("file:///a", listener.uris.items[0]);
    try testing.expectEqual(@as(u64, 2), listener.active.load(.acquire));
}

test "after the last unsubscribe, a late first acknowledgment of the old stream does not make it active" {
    // The callbacks run on the task of the test. The tasks of the streams do not run.
    const io = testing.io;
    const gpa = testing.allocator;
    var host: TestHost = .{ .io = io };
    defer host.deinit();
    const upstream = try Upstream.init(io, gpa, .{ .transport = undefined });
    defer upstream.deinit();
    var listener: Listener = .init(io, gpa, upstream);
    defer listener.deinit();
    listener.host = host.host();
    defer {
        for (listener.streams.items) |s| s.destroy();
        listener.streams.clearRetainingCapacity();
    }

    // The client knows no list. The stream of the URI has no acknowledgment yet.
    try listener.streams.ensureUnusedCapacity(gpa, 1);
    listener.generation = 1;
    const old = try Stream.create(&listener, &.{"file:///a"}, null);
    listener.streams.appendAssumeCapacity(old);
    listener.current = old;
    listener.setUris(&.{"file:///a"});
    var r: TestResponse = .{ .host = &host, .id = 1 };
    var c: Change = .{ .kind = .unsubscribe, .uri = "file:///a", .respond = r.respond() };
    listener.begin(&c);
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try testing.expect(old.retired);
    try testing.expectEqual(@as(usize, 0), listener.uris.items.len);

    // The acknowledgment of the old stream was on the way. It gives nothing, and the events
    // of the old stream do not reach the client after the response.
    old.acknowledged(null);
    try testing.expect(listener.active.load(.acquire) > old.generation);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    Stream.onEvent(old, "notifications/resources/updated", try mcp.json.parseTree(a, "{\"uri\":\"file:///a\"}"));
    try expectMethods(&.{"response"}, try host.methods(a));
}

test "a stream that lived for the stable time resets the wait, and a shorter stream does not" {
    // The tasks of the streams do not run: the test makes the state of the streams itself.
    const io = testing.io;
    const gpa = testing.allocator;
    const upstream = try Upstream.init(io, gpa, .{ .transport = undefined });
    defer upstream.deinit();
    for ([_]struct { stable: Io.Duration, backoff_ms: i64 }{
        // The wait goes back to 20 ms, and the wait for the next stream doubles it.
        .{ .stable = .fromNanoseconds(0), .backoff_ms = 40 },
        // The wait of 80 ms stays, and the wait for the next stream doubles it.
        .{ .stable = .fromSeconds(60), .backoff_ms = 160 },
    }) |case| {
        var listener: Listener = .init(io, gpa, upstream);
        defer listener.deinit();
        listener.options = .{ .tools = true, .backoff = .fromMilliseconds(20), .max_backoff = .fromSeconds(1), .stable = case.stable };
        listener.backoff = .fromMilliseconds(80);
        listener.gap = false;
        const s = try Stream.create(&listener, &.{}, null);
        defer s.destroy();
        s.acks.store(1, .release);
        s.seen = 1;
        s.acked_at = Io.Clock.Timestamp.now(io, .awake);
        listener.current = s;
        // The upstream server ended the stream with its result.
        s.ended.store(true, .release);
        listener.ended(s);
        try testing.expect(listener.retry_at != null);
        try testing.expectEqual(case.backoff_ms, listener.backoff.toMilliseconds());
    }
}

test "the stop cancels the stream, opens no new stream, and a change after the stop gets no response" {
    const t = try TestListener.create(&.{}, all_lists, null);
    defer t.destroy();
    try t.waitAcks(1);
    const started = Io.Clock.Timestamp.now(testing.io, .awake);
    t.stop();
    try testing.expect(started.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw.toMilliseconds() < 1000);
    try testing.expect(!t.listener.isRunning());
    try testing.expect(t.fake.noteIndex("cancel 0") != null);
    try testing.expectEqual(@as(usize, 1), t.fake.attemptCount());
    var r: TestResponse = .{ .host = &t.host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c});
    try testing.expectEqual(Change.Outcome.canceled, c.outcome);
    try testing.expectEqual(@as(usize, 3), t.host.count());
}

test "the stop does not wait for the end of a wait after a loss" {
    const burst = (mcp.Limits{}).max_lost_stream_retries + 1;
    const fail: FakeServer.Attempt = .{ .ack = false, .end = .closed };
    const t = try TestListener.create(&([_]FakeServer.Attempt{fail} ** 16), .{ .tools = true, .backoff = .fromSeconds(30) }, null);
    defer t.destroy();
    try t.fake.waitAttempts(burst);
    const started = Io.Clock.Timestamp.now(testing.io, .awake);
    t.stop();
    try testing.expect(started.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw.toMilliseconds() < 1000);
    try testing.expectEqual(@as(usize, burst), t.fake.attemptCount());
}

test "without lists, the listener opens a stream only for URIs, and the last unsubscribe ends it" {
    // The stream gives an update after its cancellation. The client does not get it after the
    // response of the unsubscribe. The first stream follows the gap at the start, thus the
    // client gets one update of its URI after the response of the subscribe.
    const t = try TestListener.create(&.{.{
        .late = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid}}}}",
    }}, .{}, null);
    defer t.destroy();
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectEqual(@as(usize, 0), t.fake.attemptCount());
    var r: TestResponse = .{ .host = &t.host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c});
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try testing.expectEqual(@as(usize, 1), t.fake.attemptCount());
    try testing.expect(!t.fake.attempt(0).tools);
    var c2: Change = .{ .kind = .unsubscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c2});
    try testing.expectEqual(Change.Outcome.changed, c2.outcome);
    try t.fake.waitOpen(0);
    try testing.expect(t.fake.noteIndex("cancel 0") != null);
    try testing.expectEqual(@as(usize, 1), t.fake.attemptCount());
    // Two responses, the update after the gap at the start, and no list change.
    try expectMethods(&.{ "response", "notifications/resources/updated", "response" }, try t.host.methods(t.arena()));
}

test "an older stream that acknowledges after the stream of a change: the events of the new stream reach the client" {
    // The first stream sends its acknowledgment only after the stream of the change. Its
    // acknowledgment comes before or after its cancellation.
    const t = try TestListener.create(&.{.{ .ack_after = 1 }}, all_lists, null);
    defer t.destroy();
    try t.fake.waitAttempts(1);
    var r: TestResponse = .{ .host = &t.host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c});
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    try t.waitAcks(2);
    try t.fake.waitOpen(1);
    try testing.expect(t.fake.noteIndex("acked 1").? < t.fake.noteIndex("ack 0").?);
    try t.fake.publish("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///a\",\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid}}}}", "file:///a");
    try t.fake.publish("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":{sid}}}}", null);
    // The stream of the change follows the gap at the start: the response, the list changes
    // and an update of its URI. The first stream gives nothing. Then the two events.
    try expectMethods(&([_][]const u8{"response"} ++ list_changes ++ [_][]const u8{
        "notifications/resources/updated",
        "notifications/resources/updated",
        "notifications/tools/list_changed",
    }), try t.host.methods(t.arena()));
}

test "after a loss, the client gets one update for each subscribed URI" {
    // The stream of the change sends its acknowledgment and its result at once.
    const t = try TestListener.create(&.{ .{}, .{ .end = .result } }, all_lists, null);
    defer t.destroy();
    try t.waitAcks(1);
    var r: TestResponse = .{ .host = &t.host, .id = 1 };
    var c: Change = .{ .kind = .subscribe, .uri = "file:///a", .respond = r.respond() };
    try changeWithin(t, &.{&c});
    try testing.expectEqual(Change.Outcome.changed, c.outcome);
    // The new stream after the loss has the URI. Its acknowledgment gives the list changes
    // and one update of the URI, without `_meta`.
    try t.waitAcks(3);
    try t.host.waitFor(3 + 1 + 4);
    try testing.expectEqualStrings("file:///a", t.fake.attempt(2).uris[0]);
    const a = t.arena();
    try expectMethods(&(list_changes ++ [_][]const u8{"response"} ++ list_changes ++ [_][]const u8{"notifications/resources/updated"}), try t.host.methods(a));
    const update = (try t.host.parsed(a))[7];
    try testing.expectEqualStrings("{\"uri\":\"file:///a\"}", try mcp.json.writeAlloc(a, update.object.get("params").?));
}

test "the filter of a stream" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const all = try filterOf(arena, .{ .tools = true, .prompts = true, .resources = true }, &.{ "file:///a", "file:///b" });
    try testing.expectEqualStrings(
        \\{"toolsListChanged":true,"promptsListChanged":true,"resourcesListChanged":true,"resourceSubscriptions":["file:///a","file:///b"]}
    , try mcp.json.writeAlloc(arena, all));
    try testing.expectEqualStrings("{}", try mcp.json.writeAlloc(arena, try filterOf(arena, .{}, &.{})));
}
