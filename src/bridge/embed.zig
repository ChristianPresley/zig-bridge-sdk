//! The bridge in the process of a zig-sdk server. The server calls `serveStdioAuto`, or the
//! stdio function of a product such as `vscode.serveStdio`, in place of
//! `mcp.transport.stdio.serve`. Then one executable serves a client of revision 2025-11-25 and
//! a client of revision 2026-07-28 on stdio.
//!
//! The first request of the client selects the path of the connection (`classify`):
//!
//! - `initialize` selects the legacy path. A `Frontend` with the profile of the product serves
//!   the connection. Its `Upstream` is the same server through
//!   `mcp.transport.memory.ClientLink` (`Upstream.Config.memory`).
//! - Each other message selects the modern path, also a line that is not valid JSON-RPC. The
//!   stdio transport of zig-sdk (`mcp.transport.stdio.Server`) gets that line and the next
//!   lines. It answers a line that is not valid with -32700 or -32600.
//! - A `server/discover` request before the first other request selects no path. The server
//!   answers it, or the bridge answers -32601 (`Discover`). The next request selects the path.
//!
//! The function reads the first lines with `mcp.util.line_framer` and the line limit of the
//! server (`limits.stdio.max_line_bytes`). It drops a line that is too long and reads the next
//! line, as the stdio transport of zig-sdk does. The framer skips a blank line. It keeps no
//! data outside the reader, thus the path reads each byte after the first request from the
//! same reader.
//!
//! The two paths use the limits of the server (`server.options.limits`): the line length, the
//! depth, the requests in flight and `shutdown_grace`. They have these differences:
//!
//! - On the legacy path, a line that is too long gets -32600. On the first line and on the
//!   modern path, the function drops it without a response.
//! - On the legacy path, a handler sees `ctx.kind == .memory`. The memory link gives no caller
//!   (`Peer.unknown`) to the rate limits of the server. On the modern path, a handler sees
//!   `.stdio`, and the rate limits see one caller for the connection.
//!
//! The reader never waits for a free slot. At the limit of requests in flight, the two paths
//! answer a new request with -32603 at once. Thus the reader always reads the cancellations
//! and the end of the input.
//!
//! On the legacy path, the memory link has these limits (`mcp.transport.memory.ClientLink`):
//!
//! - The handler of a request runs on the task of the request of the client. Only the cancel
//!   token of that request stops the handler: a cancellation of the client, or the end of the
//!   input.
//! - The link obeys no time limit. Thus the time limits of the front end for the server, for
//!   example `Frontend.Timeouts.call` and `Frontend.Options.discover_timeout`, do not apply in
//!   the process. The wait for the answers of the client to the input requests keeps its limit
//!   (`Frontend.Timeouts.input`).
//! - The acknowledgment of a listen stream arrives on the task of the stream, before the server
//!   can publish an event to the stream. zig-sdk 0.4.0 gives this order (change C). Thus the
//!   front end can forward the list changes and the resource updates of the server.
//! - The server publishes an event on the task that changes the server, and it holds its locks
//!   during the callback of the stream. The callback only translates the event and writes it
//!   under the output lock of the front end (`notify.zig`). The lock order is
//!   `subscriptions_lock` of the server, `sub.mutex` of the stream, `Forward.lock` of the link,
//!   then `out_lock` of the front end. Thus a change of the server, for example
//!   `setToolEnabled`, writes its list change to the client before its result. While the
//!   client does not read the output, each event and each new listen stream of the server
//!   waits.
//!
//! At the end of the input, the function stops in a bounded time and returns:
//!
//! - The legacy path cancels the requests in flight and the listen stream. It waits for them
//!   for at most `shutdown_grace`, then it cancels the tasks that are left (`Frontend.shutdown`).
//! - The modern path ends the listen streams of the server (`Server.shutdownSubscriptions`). It
//!   waits for the other requests for at most `shutdown_grace`. A request that ends in the
//!   grace period still writes its response, as on the stdio transport of zig-sdk. Then the
//!   function fires the cancel tokens of the requests that are left, and it cancels their
//!   tasks (`stopModern`).
//!
//! Only a handler that does not examine its cancel token and has no cancel point can still
//! stop the return. The function arms no watchdog. An executable can arm one.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const Message = mcp.jsonrpc.Message;
const Transport = mcp.transport.Transport;
const line_framer = mcp.util.line_framer;
const bridge = @import("../bridge.zig");
const Frontend = @import("Frontend.zig");
const Upstream = @import("Upstream.zig");
const translate = @import("translate.zig");
const Profile = bridge.Profile;

const log = std.log.scoped(.bridge);

/// The answer to a `server/discover` request before the first other request.
pub const Discover = enum {
    /// The server answers. A client of revision 2026-07-28 then takes the modern path. This is
    /// the default, because each server of revision 2026-07-28 must answer `server/discover`.
    ///
    /// The Copilot harness of VS Code sends `server/discover` first, and it takes the modern
    /// path. It has no MRTR yet (copilot-cli issue 4834). Thus it cannot complete a tool of
    /// the server that asks for input.
    answer,
    /// The bridge answers with the error -32601 and selects no path. A client of the two
    /// revisions then sends `initialize`, and it takes the legacy path. The bridge then does
    /// the MRTR rounds for it. The Copilot harness does this. A client of revision 2026-07-28
    /// that needs a `server/discover` result cannot use the server. A client that sends its
    /// requests without `server/discover` still takes the modern path.
    refuse,
};

/// The settings of `serveStdioAuto`.
pub const Options = struct {
    /// The profile of the product for the legacy path. It must stay valid while the function
    /// runs.
    profile: *const Profile,
    /// The answer to a `server/discover` request before the first other request.
    discover: Discover = .answer,
    /// The time that the requests in flight get at the end of the input. Null uses
    /// `limits.shutdown_grace` of the server.
    shutdown_grace: ?Io.Duration = null,
};

/// The path that served the connection.
pub const Era = enum {
    /// The input ended before a request selected a path.
    none,
    /// The first request was `initialize`. The connection used revision 2025-11-25.
    legacy,
    /// The connection used revision 2026-07-28.
    modern,
};

/// The meaning of the first line of a connection.
pub const Class = enum {
    /// A request with the method `initialize`: the legacy path.
    legacy,
    /// Each other message, and a line that is not valid JSON-RPC: the modern path.
    modern,
    /// A request with the method `server/discover`. It selects no path.
    discover,
};

/// Returns the class of the first line `line` of a connection. The function parses the line
/// with `Message.parseMaxDepth` and `max_depth` in `arena`. Only a request with the method
/// exactly `initialize` is `legacy`, and only a request with the method exactly
/// `server/discover` is `discover`. A notification, a response, and a line that is not valid
/// JSON-RPC are `modern`.
pub fn classify(arena: Allocator, line: []const u8, max_depth: u16) Allocator.Error!Class {
    return (try parse(arena, line, max_depth)).class;
}

/// A first line, parsed.
const First = struct {
    class: Class,
    /// The request of a `discover` line. Null for the other classes.
    request: ?Message.Request = null,
};

fn parse(arena: Allocator, line: []const u8, max_depth: u16) Allocator.Error!First {
    const msg = Message.parseMaxDepth(arena, line, max_depth) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax, error.Invalid, error.InvalidId => return .{ .class = .modern },
    };
    const req = switch (msg) {
        .request => |r| r,
        .notification, .response, .error_response => return .{ .class = .modern },
    };
    if (std.mem.eql(u8, req.method, "initialize")) return .{ .class = .legacy };
    if (std.mem.eql(u8, req.method, "server/discover")) return .{ .class = .discover, .request = req };
    return .{ .class = .modern };
}

/// The scratch memory that a reader loop keeps between two lines.
const scratch_retain = 64 << 10;

/// The cancellation reason of a request that is left at the end of the input on the modern
/// path. The front end gives the same reason on the legacy path.
const eof_cancel_reason = "the client closed the connection";

/// Serve `server` over `in` and `out` until the end of `in`, for a client of revision
/// 2025-11-25 or of revision 2026-07-28. The first request of the client selects the path. See
/// the comment of the file. `out` gets only JSON-RPC messages, one on each line.
///
/// Returns the path after the end of the input and a bounded stop. The server must stay valid
/// until the return. At the return, the server has no listen stream, and it ends each new
/// listen stream at once (`Server.shutdownSubscriptions`).
pub fn serveStdioAuto(io: Io, gpa: Allocator, server: *mcp.Server, in: *Io.Reader, out: *Io.Writer, options: Options) !Era {
    const limits = server.options.limits;
    const grace = options.shutdown_grace orelse limits.shutdown_grace;
    // On the modern path, the rate limits of the server see one caller for the whole
    // connection, also for a `server/discover` before the first other request. On the legacy
    // path, the memory link gives no caller (`Peer.unknown`).
    const peer: Transport.Peer = .{ .connection = Transport.nextConnectionId() };
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var framer: line_framer.Framer = .{ .reader = in, .max_line_bytes = limits.stdio.max_line_bytes };
    while (true) {
        _ = scratch.reset(.{ .retain_with_limit = scratch_retain });
        const arena = scratch.allocator();
        const line = framer.next(arena) catch |e| switch (e) {
            error.EndOfStream, error.ReadFailed => {
                log.debug("the input ended before the first request", .{});
                server.shutdownSubscriptions(io);
                return .none;
            },
            error.LineTooLong => {
                log.warn("dropped a frame longer than {d} bytes", .{limits.stdio.max_line_bytes});
                continue;
            },
            error.InvalidUtf8, error.ControlCharacter => {
                log.debug("the first line is not valid UTF-8: the connection uses revision 2026-07-28", .{});
                try serveModern(io, gpa, server, peer, &framer, .invalid_utf8, &scratch, out, grace);
                return .modern;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const first = try parse(arena, line, limits.json_max_depth);
        switch (first.class) {
            .discover => try answerDiscover(io, server, peer, arena, first.request.?, out, options.discover),
            .legacy => {
                log.debug("the first request is initialize: the connection uses revision 2025-11-25", .{});
                try serveLegacy(io, gpa, server, options.profile, in, out, line, &scratch, grace);
                return .legacy;
            },
            .modern => {
                log.debug("the first message is not initialize: the connection uses revision 2026-07-28", .{});
                try serveModern(io, gpa, server, peer, &framer, .{ .line = line }, &scratch, out, grace);
                return .modern;
            },
        }
    }
}

/// Answer a `server/discover` request before the first other request. The function runs on
/// the reader task, and no other task writes to `out` yet.
fn answerDiscover(io: Io, server: *mcp.Server, peer: Transport.Peer, arena: Allocator, req: Message.Request, out: *Io.Writer, policy: Discover) Allocator.Error!void {
    switch (policy) {
        .answer => {
            // The server answers `server/discover` without a wait. The token never fires.
            var token: mcp.transport.CancelToken = .{};
            var writer: LineResponder = .{ .out = out };
            server.handle(io, .{
                .kind = .stdio,
                .arena = arena,
                .message = .{ .request = req },
                .responder = writer.responder(),
                .cancel = &token,
                .peer = peer,
            });
        },
        .refuse => {
            log.debug("answered server/discover with -32601: the option refuses it", .{});
            const err = try translate.errorFor(.method_not_found, null).toWire(arena);
            var aw: Io.Writer.Allocating = .init(arena);
            mcp.jsonrpc.message.writeErrorResponse(&aw.writer, req.id, err) catch return error.OutOfMemory;
            writeLine(out, aw.written());
        },
    }
}

/// Write one frame and a newline to `out`. A failed write goes to the debug log, as on the
/// stdio transport of zig-sdk.
fn writeLine(out: *Io.Writer, frame: []const u8) void {
    line_framer.writeFrame(out, frame) catch |e| log.debug("cannot write a frame: {t}", .{e});
}

/// The responder of a request that the server answers on the reader task, before the first
/// request selects a path.
const LineResponder = struct {
    out: *Io.Writer,

    fn responder(self: *LineResponder) Transport.Responder {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.Responder.VTable = .{ .notify = write, .finish = write, .abort = abort };

    fn write(ptr: *anyopaque, io: Io, frame: []const u8) Transport.SendError!void {
        _ = io;
        const self: *LineResponder = @ptrCast(@alignCast(ptr));
        line_framer.writeFrame(self.out, frame) catch return error.WriteFailed;
    }

    fn abort(ptr: *anyopaque, io: Io) void {
        _ = ptr;
        _ = io;
    }
};

/// The legacy path: a front end over the memory link to `server`. The front end gets
/// `first`, then it reads the next lines from `in` until the end of the input.
fn serveLegacy(
    io: Io,
    gpa: Allocator,
    server: *mcp.Server,
    profile: *const Profile,
    in: *Io.Reader,
    out: *Io.Writer,
    first: []const u8,
    scratch: *std.heap.ArenaAllocator,
    grace: Io.Duration,
) !void {
    const limits = server.options.limits;
    const upstream = try Upstream.init(io, gpa, .{ .memory = server });
    defer upstream.deinit();
    // After the front end stopped, no listen stream of the front end is left. The server then
    // also ends each listen stream that starts later, as at the end of the stdio transport.
    defer server.shutdownSubscriptions(io);
    var frontend: Frontend = .init(io, gpa, upstream, profile, .writer(out), .{
        // The two paths have the limits of the server.
        .max_line_bytes = limits.stdio.max_line_bytes,
        .json_max_depth = limits.json_max_depth,
        .max_in_flight_requests = limits.max_in_flight_requests,
        .shutdown_grace = grace,
        // The server sends its `serverInfo` with each result. This name is only a fallback.
        .fallback_name = server.options.info.name,
    });
    defer frontend.deinit();
    try frontend.receive(first);
    // The front end has a copy of the line.
    _ = scratch.reset(.free_all);
    // The memory link never loses the server, thus the result is always `.eof`.
    _ = try frontend.run(in);
}

/// The first line of the modern path.
const ModernFirst = union(enum) {
    /// A line for `stdio.Server.receive`.
    line: []const u8,
    /// A line that is not valid UTF-8. The framer dropped it.
    invalid_utf8,
};

/// The modern path: the stdio transport of zig-sdk for `server`. The transport gets `first`,
/// then the next lines from `framer`. The loop is the loop of `stdio.Server.run`, except for
/// these two changes:
///
/// - The reader never waits for a free slot. `run` waits for one.
/// - `run` waits for the requests in flight without a limit at the end of the input. This
///   function stops them after at most `grace` (`stopModern`).
fn serveModern(
    io: Io,
    gpa: Allocator,
    server: *mcp.Server,
    peer: Transport.Peer,
    framer: *line_framer.Framer,
    first: ModernFirst,
    scratch: *std.heap.ArenaAllocator,
    out: *Io.Writer,
    grace: Io.Duration,
) !void {
    var transport: mcp.transport.stdio.Server = .init(io, gpa, server, out);
    transport.peer = peer;
    // As in the front end, a request above the limit gets -32603 at once. A listen stream
    // also holds a slot. Thus the reader always reads the cancellations and the end of the
    // input, also while the slots are full.
    transport.when_full = .{ .reject = server.options.limits.max_in_flight_requests };
    defer transport.deinit();
    defer stopModern(io, server, &transport, grace);
    switch (first) {
        .line => |line| try transport.receive(line),
        .invalid_utf8 => writeParseError(io, &transport),
    }
    while (true) {
        _ = scratch.reset(.{ .retain_with_limit = scratch_retain });
        const line = framer.next(scratch.allocator()) catch |e| switch (e) {
            error.EndOfStream, error.ReadFailed => return,
            error.LineTooLong => {
                log.warn("dropped a frame longer than {d} bytes", .{framer.max_line_bytes});
                continue;
            },
            error.InvalidUtf8, error.ControlCharacter => {
                writeParseError(io, &transport);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try transport.receive(line);
    }
}

/// Stop the modern path at the end of the input:
///
/// 1. Admit no new request, and end the listen streams of the server. A listen stream then
///    ends with its result.
/// 2. Wait for the other requests for at most `grace`. A request that ends in this time
///    writes its response.
/// 3. Fire the cancel token of each request that is left. A canceled request gets no
///    response, as on the legacy path.
/// 4. Cancel the tasks that are left, and wait for their end.
///
/// `stdio.Server.awaitInFlight` alone cancels only the tasks. A handler that examines
/// `ctx.cancel` without a cancel point of `io` then never stops. Step 3 stops it.
fn stopModern(io: Io, server: *mcp.Server, transport: *mcp.transport.stdio.Server, grace: Io.Duration) void {
    transport.stopAdmission();
    server.shutdownSubscriptions(io);
    const deadline = Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = grace, .clock = .awake });
    while (inFlightCount(io, transport) > 0) {
        if (Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw.nanoseconds <= 0) break;
        io.sleep(.fromMilliseconds(5), .awake) catch break;
    }
    transport.cancelAll(eof_cancel_reason, false);
    transport.awaitInFlight(.fromMilliseconds(0));
}

/// The number of requests in flight of `transport`, also the listen streams.
fn inFlightCount(io: Io, transport: *mcp.transport.stdio.Server) usize {
    transport.in_flight_lock.lockUncancelable(io);
    defer transport.in_flight_lock.unlock(io);
    return transport.in_flight.items.len;
}

/// Answer a line that is not valid UTF-8 with the error of `stdio.Server.run`. The function
/// writes under the output lock of the transport.
fn writeParseError(io: Io, transport: *mcp.transport.stdio.Server) void {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    mcp.jsonrpc.message.writeErrorResponse(&w, null, mcp.protocol.errors.parseError("Parse error: invalid UTF-8").toWire()) catch return;
    transport.out_lock.lockUncancelable(io);
    defer transport.out_lock.unlock(io);
    writeLine(transport.out.?, w.buffered());
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "classify: only a request with the method initialize selects the legacy path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { Class, []const u8 }{
        .{ .legacy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"c\",\"version\":\"1\"}}}" },
        .{ .legacy, "{\"jsonrpc\":\"2.0\",\"id\":\"init\",\"method\":\"initialize\"}" },
        .{ .legacy, " { \"method\" : \"initialize\" , \"id\" : 0 , \"jsonrpc\" : \"2.0\" } " },
        .{ .discover, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}" },
        .{ .discover, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}" },
        // A notification is not a request.
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"method\":\"server/discover\"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" },
        // The method must be exactly initialize.
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Initialize\"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize \"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialized\"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover/\"}" },
        // The word initialize only in a value.
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"initialize\"}}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"method\":\"initialize\"}}" },
        // Other requests and responses.
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"x\"}}" },
        // Lines that are not valid JSON-RPC.
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"" },
        .{ .modern, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"initialize\"}" },
        .{ .modern, "{\"id\":1,\"method\":\"initialize\"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"initialize\"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"method\":\"initialize\"}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":[]}" },
        .{ .modern, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"result\":{}}" },
        .{ .modern, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}]" },
        .{ .modern, "\"initialize\"" },
        .{ .modern, "initialize" },
        .{ .modern, "" },
    };
    for (cases) |c| {
        const got = try classify(arena, c[1], 64);
        if (got != c[0]) {
            std.debug.print("classify({s}) = {t}, expected {t}\n", .{ c[1], got, c[0] });
            return error.TestExpectedEqual;
        }
    }
}

test "classify: a line deeper than the depth limit selects the modern path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deep = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"a\":{\"b\":{\"c\":{}}}}}";
    try testing.expectEqual(Class.legacy, try classify(arena, deep, 64));
    // The stdio transport of zig-sdk answers such a line with -32700.
    try testing.expectEqual(Class.modern, try classify(arena, deep, 3));
}

/// The server of the tests. `add` gives a result at once, `ask` asks for a name in a form, and
/// `block` waits for its cancellation for at most five seconds. `spin` examines its cancel
/// token without a cancel point of `io` for at most six seconds.
fn testServer(io: Io, limits: mcp.Limits) !*mcp.Server {
    const gpa = testing.allocator;
    const server = try gpa.create(mcp.Server);
    errdefer gpa.destroy(server);
    server.* = try mcp.Server.init(gpa, io, .{
        .info = .{ .name = "embed-test", .version = "3.0.0" },
        .mrtr = .{ .elicitation = true },
        .limits = limits,
    });
    errdefer server.deinit();
    try server.addTool(.{ .name = "add", .description = "Add two integers" }, testAdd);
    try server.addToolJson(.{ .name = "ask", .description = "Ask for a name" }, testAsk);
    try server.addTool(.{ .name = "block", .description = "Wait for the cancellation" }, testBlock);
    try server.addTool(.{ .name = "spin", .description = "Examine the cancel token without a wait" }, testSpin);
    return server;
}

fn destroyServer(server: *mcp.Server) void {
    server.deinit();
    testing.allocator.destroy(server);
}

fn testAdd(ctx: *mcp.RequestContext, args: struct { a: i64, b: i64 }) anyerror!mcp.Outcome(mcp.CallToolResult) {
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{d}", .{args.a + args.b}) };
}

fn testAsk(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    if (try ctx.elicitResponse("name")) |a| {
        const name = mcp.json.getString(a.content orelse .null, "name") orelse "nobody";
        return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "Hello, {s}.", .{name}) };
    }
    var ir: mcp.InputRequired = .init(ctx.arena);
    try ir.elicitForm("name", "Name?", try mcp.InputRequired.stringSchema(ctx.arena, "name", null, true));
    return .{ .input_required = ir };
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

/// The state of the last call of `spin`. Only one test calls `spin`.
const SpinState = enum(u8) { idle, running, canceled, timed_out };
var spin_state: std.atomic.Value(SpinState) = .init(.idle);

/// The tool `spin`: a handler that examines `ctx.cancel` and has no cancel point of `io`, as
/// a handler of CPU work. Only its cancel token stops it. After six seconds, it stops itself,
/// so that a failed test does not stop the test run.
fn testSpin(ctx: *mcp.RequestContext, args: struct {}) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    spin_state.store(.running, .release);
    const start = Io.Clock.Timestamp.now(ctx.io, .awake);
    while (start.durationTo(Io.Clock.Timestamp.now(ctx.io, .awake)).raw.nanoseconds < 6 * std.time.ns_per_s) {
        ctx.checkCancel() catch |e| {
            spin_state.store(.canceled, .release);
            return e;
        };
        std.atomic.spinLoopHint();
    }
    spin_state.store(.timed_out, .release);
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "not canceled", .{}) };
}

/// The input of a test. The test gives it bytes with `push`, and `close` ends it. The reader
/// task waits for bytes, as on a pipe.
const TestInput = struct {
    reader: Io.Reader,
    io: Io,
    lock: Io.Mutex = .init,
    /// The bytes that the reader did not take. Guarded by `lock`.
    pending: std.ArrayList(u8) = .empty,
    /// Guarded by `lock`.
    closed: bool = false,
    buf: [4096]u8 = undefined,

    /// Make the input in place, because the reader points into `buf`.
    fn init(self: *TestInput, io: Io) void {
        self.* = .{
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &self.buf, .seek = 0, .end = 0 },
            .io = io,
        };
    }

    fn deinit(self: *TestInput) void {
        self.pending.deinit(testing.allocator);
    }

    fn push(self: *TestInput, bytes: []const u8) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.pending.appendSlice(testing.allocator, bytes);
    }

    fn close(self: *TestInput) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.closed = true;
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *TestInput = @alignCast(@fieldParentPtr("reader", r));
        while (true) {
            {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                if (self.pending.items.len > 0) {
                    const n = try w.write(limit.slice(self.pending.items));
                    self.pending.replaceRangeAssumeCapacity(0, n, &.{});
                    return n;
                }
                if (self.closed) return error.EndOfStream;
            }
            self.io.sleep(.fromMilliseconds(1), .awake) catch return error.ReadFailed;
        }
    }
};

/// The output of a test. It keeps all bytes. The test reads them while the paths write.
const TestOutput = struct {
    writer: Io.Writer,
    io: Io,
    lock: Io.Mutex = .init,
    /// Guarded by `lock`.
    bytes: std.ArrayList(u8) = .empty,
    buf: [256]u8 = undefined,

    fn init(self: *TestOutput, io: Io) void {
        self.* = .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.buf }, .io = io };
    }

    fn deinit(self: *TestOutput) void {
        self.bytes.deinit(testing.allocator);
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *TestOutput = @alignCast(@fieldParentPtr("writer", w));
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.bytes.appendSlice(testing.allocator, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.bytes.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
            count += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.bytes.appendSlice(testing.allocator, last) catch return error.WriteFailed;
        return count + last.len * splat;
    }

    /// The complete lines so far, parsed in `arena`.
    fn frames(self: *TestOutput, arena: Allocator) ![]Value {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var list: std.ArrayList(Value) = .empty;
        var rest: []const u8 = self.bytes.items;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try list.append(arena, try mcp.json.parseTree(arena, rest[0..nl]));
            rest = rest[nl + 1 ..];
        }
        return list.items;
    }

    /// Wait for the frame with the id `id`, at most five seconds.
    fn waitId(self: *TestOutput, arena: Allocator, id: Value) !Value {
        var i: usize = 0;
        while (true) : (i += 1) {
            for (try self.frames(arena)) |f| {
                const frame_id = f.object.get("id") orelse continue;
                if (f.object.get("method") != null) continue;
                if (sameId(frame_id, id)) return f;
            }
            if (i > 5000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    /// Wait for the request of the bridge with the method `method`, at most five seconds.
    fn waitRequest(self: *TestOutput, arena: Allocator, method: []const u8) !Value {
        var i: usize = 0;
        while (true) : (i += 1) {
            for (try self.frames(arena)) |f| {
                if (f.object.get("id") == null) continue;
                if (std.mem.eql(u8, mcp.json.getString(f, "method") orelse "", method)) return f;
            }
            if (i > 5000) return error.TestTimeout;
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

fn sameId(a: Value, b: Value) bool {
    return switch (a) {
        .integer => |n| b == .integer and b.integer == n,
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
        .null => b == .null,
        else => false,
    };
}

/// `serveStdioAuto` in its own task, with a `TestInput` and a `TestOutput`.
const TestConnection = struct {
    server: *mcp.Server,
    in: TestInput = undefined,
    out: TestOutput = undefined,
    arena_state: std.heap.ArenaAllocator,
    task: ?Io.Future(void) = null,
    result: anyerror!Era = error.TestNotStarted,

    const profile: Profile = .{ .name = "mcp-bridge-test", .quirks = .{ .normalize_array_items = true } };
    /// The `shutdown_grace` of the tests.
    const grace: Io.Duration = .fromMilliseconds(300);

    fn create(options: struct { limits: mcp.Limits = .{}, discover: Discover = .answer }) !*TestConnection {
        const io = testing.io;
        const self = try testing.allocator.create(TestConnection);
        errdefer testing.allocator.destroy(self);
        const server = try testServer(io, options.limits);
        errdefer destroyServer(server);
        self.* = .{ .server = server, .arena_state = .init(testing.allocator) };
        self.in.init(io);
        self.out.init(io);
        self.task = try io.concurrent(run, .{ self, options.discover });
        return self;
    }

    fn run(self: *TestConnection, discover: Discover) void {
        self.result = serveStdioAuto(testing.io, testing.allocator, self.server, &self.in.reader, &self.out.writer, .{
            .profile = &profile,
            .discover = discover,
            .shutdown_grace = grace,
        });
    }

    /// Close the input and wait for the return of `serveStdioAuto`.
    fn finish(self: *TestConnection) !Era {
        self.in.close();
        if (self.task) |*t| {
            t.await(testing.io);
            self.task = null;
        }
        return self.result;
    }

    fn destroy(self: *TestConnection) void {
        if (self.finish()) |_| {} else |_| {}
        self.in.deinit();
        self.out.deinit();
        self.arena_state.deinit();
        destroyServer(self.server);
        testing.allocator.destroy(self);
    }

    fn arena(self: *TestConnection) Allocator {
        return self.arena_state.allocator();
    }

    fn send(self: *TestConnection, line: []const u8) !void {
        try self.in.push(line);
        try self.in.push("\n");
    }

    /// Send `line`, and wait for the response with the id `id`.
    fn call(self: *TestConnection, id: i64, line: []const u8) !Value {
        try self.send(line);
        return self.out.waitId(self.arena(), .{ .integer = id });
    }

    fn frameCount(self: *TestConnection) !usize {
        return (try self.out.frames(self.arena())).len;
    }
};

/// The `initialize` request of VS Code 1.140.
const vscode_initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}}
;
/// The `_meta` of a request of revision 2026-07-28.
const modern_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;
const modern_discover = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"server/discover\",\"params\":{" ++ modern_meta ++ "}}";
const modern_list = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ modern_meta ++ "}}";
const modern_add = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":3}," ++ modern_meta ++ "}}";
const legacy_add = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":3}}}";
const initialized = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";

fn expectLegacyInitialize(result_frame: Value) !void {
    const result = result_frame.object.get("result") orelse return error.TestExpectedResult;
    try testing.expectEqualStrings("2025-11-25", mcp.json.getString(result, "protocolVersion").?);
    try testing.expectEqualStrings("embed-test", mcp.json.getString(result.object.get("serverInfo").?, "name").?);
    try testing.expect(result.object.get("capabilities").?.object.get("tools") != null);
}

fn expectDiscoverResult(frame: Value) !void {
    const result = frame.object.get("result") orelse return error.TestExpectedResult;
    const versions = result.object.get("supportedVersions").?.array.items;
    try testing.expectEqualStrings("2026-07-28", versions[0].string);
    try testing.expect(result.object.get("protocolVersion") == null);
}

fn expectText(frame: Value, text: []const u8) !void {
    const result = frame.object.get("result") orelse return error.TestExpectedResult;
    const content = result.object.get("content").?.array.items;
    try testing.expectEqualStrings(text, mcp.json.getString(content[0], "text").?);
}

fn expectErrorCode(frame: Value, code: i64) !void {
    const err = frame.object.get("error") orelse return error.TestExpectedError;
    try testing.expectEqual(code, err.object.get("code").?.integer);
}

test "initialize selects the legacy path: the front end answers, and the tool of the form completes" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    const arena = c.arena();
    try expectLegacyInitialize(try c.call(1, vscode_initialize));
    try c.send(initialized);
    try expectText(try c.call(2, legacy_add), "5");
    // The bridge asks the client for the form of the tool, and it gives the answer to the
    // server in the next round.
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ask\"}}");
    const form = try c.out.waitRequest(arena, "elicitation/create");
    try testing.expectEqualStrings("b-1", form.object.get("id").?.string);
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}}");
    try expectText(try c.out.waitId(arena, .{ .integer = 3 }), "Hello, Ada.");
    // A server/discover after initialize goes to the front end, which answers -32601.
    try expectErrorCode(try c.call(4, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"server/discover\",\"params\":{" ++ modern_meta ++ "}}"), -32601);
    try testing.expectEqual(Era.legacy, try c.finish());
}

test "a request of revision 2026-07-28 selects the modern path, and initialize then gets the error of the server" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    const list = try c.call(2, modern_list);
    try testing.expect(list.object.get("result").?.object.get("tools").?.array.items.len == 4);
    try expectText(try c.call(3, modern_add), "5");
    // The connection stays on the modern path: zig-sdk answers initialize with -32601.
    try expectErrorCode(try c.call(1, vscode_initialize), -32601);
    try testing.expectEqual(Era.modern, try c.finish());
}

test "a server/discover first selects no path: initialize then selects the legacy path" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try expectDiscoverResult(try c.call(11, modern_discover));
    // A second discover also selects no path.
    try expectDiscoverResult(try c.call(12, "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"server/discover\",\"params\":{" ++ modern_meta ++ "}}"));
    try expectLegacyInitialize(try c.call(1, vscode_initialize));
    try expectText(try c.call(2, legacy_add), "5");
    try testing.expectEqual(Era.legacy, try c.finish());
}

test "a server/discover first selects no path: a modern request then selects the modern path" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try expectDiscoverResult(try c.call(11, modern_discover));
    try expectText(try c.call(3, modern_add), "5");
    try testing.expectEqual(Era.modern, try c.finish());
}

test "Discover.refuse answers server/discover with -32601, and the client of two revisions sends initialize" {
    const c = try TestConnection.create(.{ .discover = .refuse });
    defer c.destroy();
    // The Copilot harness: server/discover with the _meta of revision 2026-07-28, then the
    // initialize of copilot-cli without roots.
    const refused = try c.call(11, modern_discover);
    try expectErrorCode(refused, -32601);
    try testing.expectEqualStrings("method_not_found", mcp.json.getString(refused.object.get("error").?.object.get("data").?, "cause").?);
    try expectLegacyInitialize(try c.call(2,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"sampling":{},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"copilot-cli","version":"1.0.89"}}}
    ));
    try expectText(try c.call(3, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":1,\"b\":1},\"_meta\":{\"progressToken\":0}}}"), "2");
    try testing.expectEqual(Era.legacy, try c.finish());
}

test "a notification first selects the modern path" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try c.send(initialized);
    try expectText(try c.call(3, modern_add), "5");
    // The notification gets no response.
    try testing.expectEqual(@as(usize, 1), try c.frameCount());
    try testing.expectEqual(Era.modern, try c.finish());
}

test "blank lines select nothing" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try c.in.push("\n  \t\r\n\n");
    try expectLegacyInitialize(try c.call(1, vscode_initialize));
    try testing.expectEqual(Era.legacy, try c.finish());
}

test "malformed JSON first selects the modern path, and zig-sdk answers -32700" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"");
    const err = try c.out.waitId(c.arena(), .null);
    try expectErrorCode(err, -32700);
    try expectText(try c.call(3, modern_add), "5");
    try testing.expectEqual(Era.modern, try c.finish());
}

test "a line that is not valid UTF-8 first selects the modern path with the error of zig-sdk" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\xff\xfe\"}");
    const err = try c.out.waitId(c.arena(), .null);
    try expectErrorCode(err, -32700);
    try testing.expectEqualStrings("Parse error: invalid UTF-8", mcp.json.getString(err.object.get("error").?, "message").?);
    // The next line that is not valid UTF-8 gets the same error on the modern path.
    try c.send("\xc3");
    try expectText(try c.call(3, modern_add), "5");
    var errors: usize = 0;
    for (try c.out.frames(c.arena())) |f| errors += @intFromBool(f.object.get("error") != null);
    try testing.expectEqual(@as(usize, 2), errors);
    try testing.expectEqual(Era.modern, try c.finish());
}

test "a line that is too long first gets no response, and the next line selects the path" {
    // The warning about the dropped line is the correct result here.
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    var limits: mcp.Limits = .{};
    limits.stdio.max_line_bytes = 1024;
    const c = try TestConnection.create(.{ .limits = limits });
    defer c.destroy();
    // The line is longer than the limit and than the buffer of the reader.
    const long = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/list\",\"params\":{\"x\":\"" ++ "x" ** 6000 ++ "\"}}";
    try c.send(long);
    try expectLegacyInitialize(try c.call(1, vscode_initialize));
    try expectText(try c.call(2, legacy_add), "5");
    // The responses of initialize and of the call. The line that is too long got none.
    try testing.expectEqual(@as(usize, 2), try c.frameCount());
    try testing.expectEqual(Era.legacy, try c.finish());
}

test "initialize only in a string value selects the modern path" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    // A request of revision 2025-11-25 with the word initialize in its params. zig-sdk refuses
    // it, because it has no _meta.
    const refused = try c.call(1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"initialize\",\"arguments\":{}}}");
    try expectErrorCode(refused, -32602);
    try testing.expectEqual(Era.modern, try c.finish());
}

test "the end of the input before a request selects no path and writes nothing" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try testing.expectEqual(Era.none, try c.finish());
    try testing.expectEqual(@as(usize, 0), try c.frameCount());
}

test "the end of the input after a server/discover selects no path" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try expectDiscoverResult(try c.call(11, modern_discover));
    try testing.expectEqual(Era.none, try c.finish());
}

test "two messages in one chunk: server/discover and a modern call" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try c.in.push(modern_discover ++ "\n" ++ modern_add ++ "\n");
    try expectDiscoverResult(try c.out.waitId(c.arena(), .{ .integer = 11 }));
    try expectText(try c.out.waitId(c.arena(), .{ .integer = 3 }), "5");
    try testing.expectEqual(Era.modern, try c.finish());
}

test "two messages in one chunk: initialize and notifications/initialized, then a ping" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    // The front end reads the lines after initialize from the buffer of the same reader. The
    // ping gets its answer also while initialize runs.
    try c.in.push(vscode_initialize ++ "\n" ++ initialized ++ "\n" ++ "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n");
    try expectLegacyInitialize(try c.out.waitId(c.arena(), .{ .integer = 1 }));
    const pong = try c.out.waitId(c.arena(), .{ .integer = 2 });
    try testing.expect(pong.object.get("result").? == .object);
    try testing.expectEqual(Era.legacy, try c.finish());
}

/// The time from the end of the input to the return, with a margin for a slow test host.
const stop_bound: Io.Duration = .fromNanoseconds(TestConnection.grace.nanoseconds + 3 * std.time.ns_per_s);

fn expectStopWithin(c: *TestConnection, era: Era) !void {
    const start = Io.Clock.Timestamp.now(testing.io, .awake);
    try testing.expectEqual(era, try c.finish());
    const elapsed = start.durationTo(Io.Clock.Timestamp.now(testing.io, .awake)).raw;
    if (elapsed.nanoseconds > stop_bound.nanoseconds) {
        std.debug.print("the stop took {d} ms\n", .{elapsed.toMilliseconds()});
        return error.TestTooSlow;
    }
}

test "the legacy path stops at the end of the input with a call and a listen stream in flight" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try expectLegacyInitialize(try c.call(1, vscode_initialize));
    // The listen stream of the front end sends a list change after its acknowledgment.
    try c.send(initialized);
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var changed = false;
        for (try c.out.frames(c.arena())) |f| {
            if (std.mem.eql(u8, mcp.json.getString(f, "method") orelse "", "notifications/tools/list_changed")) changed = true;
        }
        if (changed) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.TestTimeout;
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"block\",\"arguments\":{}}}");
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}");
    _ = try c.out.waitId(c.arena(), .{ .integer = 3 });
    try expectStopWithin(c, .legacy);
    // The canceled call got no response.
    for (try c.out.frames(c.arena())) |f| {
        const id = f.object.get("id") orelse continue;
        try testing.expect(!sameId(id, .{ .integer = 2 }));
    }
    // The server has no listen stream: a new stream ends at once.
    try testing.expectEqual(@as(usize, 0), subscriptionCount(c.server));
}

test "the modern path ends the listen streams at the end of the input, and stops a call after the grace period" {
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":true}," ++ modern_meta ++ "}}");
    var i: usize = 0;
    while (subscriptionCount(c.server) == 0) : (i += 1) {
        if (i > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"block\",\"arguments\":{}," ++ modern_meta ++ "}}");
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\",\"params\":{" ++ modern_meta ++ "}}");
    _ = try c.out.waitId(c.arena(), .{ .integer = 7 });
    try expectStopWithin(c, .modern);
    // The listen stream ended with its result, as at the end of the stdio transport.
    const ended = try c.out.waitId(c.arena(), .{ .integer = 5 });
    try testing.expect(ended.object.get("result") != null);
    for (try c.out.frames(c.arena())) |f| {
        const id = f.object.get("id") orelse continue;
        if (f.object.get("method") == null) try testing.expect(!sameId(id, .{ .integer = 6 }));
    }
}

test "the modern path fires the cancel token of a call after the grace period, also for a handler without a cancel point" {
    spin_state.store(.idle, .release);
    const c = try TestConnection.create(.{});
    defer c.destroy();
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"spin\",\"arguments\":{}," ++ modern_meta ++ "}}");
    var i: usize = 0;
    while (spin_state.load(.acquire) != .running) : (i += 1) {
        if (i > 5000) return error.TestTimeout;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    // A cancel of the task alone does not stop the handler. Without its token, the stop takes
    // six seconds.
    try expectStopWithin(c, .modern);
    try testing.expectEqual(SpinState.canceled, spin_state.load(.acquire));
    // The canceled call got no response.
    try testing.expectEqual(@as(usize, 0), try c.frameCount());
}

test "the modern path answers a request above the limit with -32603 at once, and the reader still reads the end of the input" {
    var limits: mcp.Limits = .{};
    limits.max_in_flight_requests = 1;
    const c = try TestConnection.create(.{ .limits = limits });
    defer c.destroy();
    // The call holds the only slot for five seconds. A listen stream can also hold it.
    try c.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"block\",\"arguments\":{}," ++ modern_meta ++ "}}");
    // The reader does not wait for the slot.
    const full = try c.call(7, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\",\"params\":{" ++ modern_meta ++ "}}");
    try expectErrorCode(full, -32603);
    try testing.expectEqualStrings(mcp.transport.stdio.Server.too_many_requests_message, mcp.json.getString(full.object.get("error").?, "message").?);
    try expectStopWithin(c, .modern);
    try testing.expectEqual(@as(usize, 1), try c.frameCount());
}

/// The number of listen streams of `server`.
fn subscriptionCount(server: *mcp.Server) usize {
    server.subscriptions_lock.lockUncancelable(testing.io);
    defer server.subscriptions_lock.unlock(testing.io);
    return server.subscriptions.items.len;
}
