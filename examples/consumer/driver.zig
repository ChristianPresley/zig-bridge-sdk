//! The check of the consumer for CI. It starts the consumer two times with pipes for stdin and
//! stdout:
//!
//! 1. As VS Code: `initialize`, `notifications/initialized`, a call of `greet`, and a call of
//!    `ask_name` with the answer to its form. The consumer takes the legacy path.
//! 2. As a client of revision 2026-07-28 through the stdio client of zig-sdk:
//!    `server/discover`, `tools/list` and a call of `greet`. The consumer takes the modern
//!    path.
//!
//! After each connection, the driver closes stdin of the consumer, and the consumer must exit
//! with code 0. The driver exits with 0 when each check passes, and with 1 at the first
//! failure. A watchdog thread stops the driver after `limit_s` seconds.
//!
//! Usage: `consumer-driver <consumer>`. `zig build drive` builds the two programs and runs the
//! driver.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp");
const Message = mcp.jsonrpc.Message;

/// The time limit of the whole check.
const limit_s = 120;

/// The time limit of each request of the modern connection.
const request_limit: Io.Duration = .fromSeconds(30);

/// The `initialize` request of VS Code 1.140, without the tasks capability.
const vscode_initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}}
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: consumer-driver <consumer>\n", .{});
        return 2;
    }
    const consumer = args[1];
    const watchdog = try std.Thread.spawn(.{}, stopLater, .{io});
    watchdog.detach();

    legacy(io, gpa, consumer) catch |err| {
        std.debug.print("consumer-driver: the legacy connection failed: {t}\n", .{err});
        return 1;
    };
    std.debug.print("consumer-driver: the legacy connection passed\n", .{});
    modern(io, gpa, consumer) catch |err| {
        std.debug.print("consumer-driver: the modern connection failed: {t}\n", .{err});
        return 1;
    };
    std.debug.print("consumer-driver: the modern connection passed\n", .{});
    return 0;
}

/// Stop the driver after `limit_s` seconds. The thread is a plain thread, thus it runs also
/// when the driver waits for a read.
fn stopLater(io: Io) void {
    io.sleep(.fromSeconds(limit_s), .awake) catch {};
    std.debug.print("consumer-driver: the check did not end in {d} s\n", .{limit_s});
    std.process.exit(1);
}

/// The connection of VS Code. The driver writes each request as one line, and reads the lines
/// of the consumer until the response.
fn legacy(io: Io, gpa: Allocator, consumer: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var child = try std.process.spawn(io, .{
        .argv = &.{consumer},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    });
    defer if (child.id != null) child.kill(io);
    var buf: [64 << 10]u8 = undefined;
    var stdout = child.stdout.?.readerStreaming(io, &buf);
    const lines = &stdout.interface;

    try send(io, &child, vscode_initialize);
    const result = try expectResult(try response(arena, lines, 1));
    try expectString(result, "protocolVersion", "2025-11-25");
    try expectString(result.object.get("serverInfo") orelse .null, "name", "consumer");
    try send(io, &child,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    try send(io, &child,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Ada"}}}
    );
    try expectText(try expectResult(try response(arena, lines, 2)), "Hello, Ada.");

    // The bridge asks for the form of `ask_name` as its request `b-1`.
    try send(io, &child,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_name"}}
    );
    const form = try request(arena, lines, "elicitation/create");
    if (form.id != .string or !std.mem.eql(u8, form.id.string, "b-1")) return fail("the form does not have the id b-1", .{});
    try send(io, &child,
        \\{"jsonrpc":"2.0","id":"b-1","result":{"action":"accept","content":{"name":"Grace"}}}
    );
    try expectText(try expectResult(try response(arena, lines, 3)), "Hello, Grace.");

    child.stdin.?.close(io);
    child.stdin = null;
    try expectExit(try child.wait(io));
}

/// The connection of a client of revision 2026-07-28: the stdio client of zig-sdk.
fn modern(io: Io, gpa: Allocator, consumer: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const proc = try mcp.transport.stdio.Client.spawn(io, gpa, .{ .argv = &.{consumer} });
    defer proc.deinit();
    var client: mcp.Client = .init(gpa, io, .{ .info = .{ .name = "consumer-driver", .version = "0.1.0" } });
    defer client.deinit();
    client.connect(proc.transport());
    const options: mcp.Client.RequestOptions = .{ .timeout = request_limit };

    const discovered = try client.discover(arena, options);
    for (discovered.supportedVersions) |v| {
        if (std.mem.eql(u8, v, "2026-07-28")) break;
    } else return fail("server/discover does not name the revision 2026-07-28", .{});

    const listed = try client.listTools(arena, null, options);
    for ([_][]const u8{ "greet", "ask_name" }) |name| {
        for (listed.tools) |tool| {
            if (std.mem.eql(u8, tool.name, name)) break;
        } else return fail("tools/list has no tool {s}", .{name});
    }

    const called = try client.callTool(arena, "greet", .{ .name = "Ada" }, options);
    if (called.content.len == 0 or called.content[0] != .text) return fail("the result of greet has no text", .{});
    if (!std.mem.eql(u8, called.content[0].text.text, "Hello, Ada.")) return fail("greet gave '{s}'", .{called.content[0].text.text});

    // `close` closes stdin of the consumer and waits for its exit. A consumer that does not
    // exit in the grace period gets a signal, and then its status is not the exit code 0.
    proc.close();
    try expectExit(proc.exitStatus() orelse return fail("the stdio client has no exit status of the consumer", .{}));
}

/// Write `line` and a newline to stdin of the consumer.
fn send(io: Io, child: *std.process.Child, line: []const u8) !void {
    const stdin = child.stdin orelse return error.StdinClosed;
    try stdin.writeStreamingAll(io, line);
    try stdin.writeStreamingAll(io, "\n");
}

/// The next line of stdout, parsed in `arena`. Each line must be one JSON-RPC message.
fn next(arena: Allocator, lines: *Io.Reader) !Message {
    const raw = lines.takeDelimiterInclusive('\n') catch |err| return fail("cannot read a line of the consumer: {t}", .{err});
    const line = std.mem.trimEnd(u8, raw, "\r\n");
    return Message.parse(arena, line) catch |err| fail("a line of stdout is not one JSON-RPC message ({t}): {s}", .{ err, line });
}

/// Read until the response with the id `id`. The function skips the notifications.
fn response(arena: Allocator, lines: *Io.Reader, id: i64) !Message {
    while (true) {
        const msg = try next(arena, lines);
        const msg_id: mcp.RequestId = switch (msg) {
            .notification => continue,
            .request => |r| return fail("an unexpected request {s}", .{r.method}),
            .response => |r| r.id,
            .error_response => |e| e.id orelse return fail("an error without an id: {s}", .{e.message}),
        };
        if (msg_id == .integer and msg_id.integer == id) return msg;
        return fail("a response for a different request", .{});
    }
}

/// Read until the next request of the bridge, and check its method.
fn request(arena: Allocator, lines: *Io.Reader, method: []const u8) !Message.Request {
    while (true) {
        switch (try next(arena, lines)) {
            .notification => continue,
            .request => |r| {
                if (std.mem.eql(u8, r.method, method)) return r;
                return fail("the request {s}, not {s}", .{ r.method, method });
            },
            else => return fail("a response, not the request {s}", .{method}),
        }
    }
}

fn expectResult(msg: Message) !Value {
    return switch (msg) {
        .response => |r| if (r.result == .object) r.result else fail("the result is not an object", .{}),
        .error_response => |e| fail("the error {d}: {s}", .{ e.code, e.message }),
        else => fail("the message is not a response", .{}),
    };
}

fn expectString(object: Value, key: []const u8, expected: []const u8) !void {
    const actual = mcp.json.getString(object, key) orelse return fail("no string member {s}", .{key});
    if (!std.mem.eql(u8, actual, expected)) return fail("{s} is '{s}', not '{s}'", .{ key, actual, expected });
}

/// Check the text of the first content block of a `tools/call` result.
fn expectText(result: Value, expected: []const u8) !void {
    const content = result.object.get("content") orelse return fail("the result has no content", .{});
    if (content != .array or content.array.items.len == 0) return fail("the content of the result is empty", .{});
    try expectString(content.array.items[0], "text", expected);
}

fn expectExit(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return fail("the consumer exited with code {d}", .{code}),
        else => return fail("the consumer stopped without an exit code: {any}", .{term}),
    }
}

/// Write the reason of a failure and return an error.
fn fail(comptime format: []const u8, args: anytype) error{CheckFailed} {
    std.debug.print("consumer-driver: " ++ format ++ "\n", args);
    return error.CheckFailed;
}
