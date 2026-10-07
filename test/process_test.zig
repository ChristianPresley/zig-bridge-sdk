//! The process tests of `mcp-bridge-vscode`. Each test starts the executable as VS Code does,
//! with a pipe for stdin, stdout and stderr. The upstream command is `bridge-fixture-server`.
//!
//! The build makes the two executables before it compiles this file. The module
//! `process_options` holds their paths. The environment variables `PROCESS_TEST_BRIDGE` and
//! `PROCESS_TEST_FIXTURE` replace these paths, for example for a run in WSL. A missing
//! executable makes the test fail. The tests never skip.
//!
//! A watchdog thread sets a time limit for each phase of a test. At the limit, the watchdog
//! stops the bridge, and the test fails. Thus a test that does not end cannot stop the CI.
//! The tests do not cancel a blocked read, because a cancel does not always wake it on
//! Windows. The stop of the bridge closes its pipes, and that wakes each blocked read.
//!
//! The child process of the bridge writes to the stderr of the bridge. Thus stderr ends only
//! after the exit of the bridge and of its child process. Each test waits for the end of
//! stderr, and so it also examines that no child process is left.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const testing = std.testing;
const mcp = @import("mcp");
const Message = mcp.jsonrpc.Message;
const fixture = @import("fixture");
const build_options = @import("build_options");
const process_options = @import("process_options");

/// The `shutdown_grace` of the bridge. The front end and the upstream client use the default
/// of zig-sdk.
const shutdown_grace: Io.Duration = (mcp.Limits{}).shutdown_grace;

/// The time from the end of stdin to the exit of the bridge and of its child process: two
/// times `shutdown_grace` and two seconds.
const exit_bound: Io.Duration = .fromNanoseconds(2 * shutdown_grace.nanoseconds + 2 * std.time.ns_per_s);

/// The limit of the watchdog for the exit. It is longer than `exit_bound`, so that a slow
/// exit gives a clear error and not a stop by the watchdog.
const exit_limit: Io.Duration = .fromNanoseconds(exit_bound.nanoseconds + 4 * std.time.ns_per_s);

/// The limit of the watchdog for the start of the processes and for each exchange.
const exchange_limit: Io.Duration = .fromSeconds(30);

/// The time from a stop by the watchdog to a panic, when the test does not end.
const hard_stop: Io.Duration = .fromSeconds(15);

/// The maximum number of stderr bytes that a test keeps.
const max_captured_stderr = 1 << 20;

/// The `initialize` request of VS Code 1.140.
const vscode_initialize =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}},"tasks":{"list":{},"cancel":{},"requests":{"sampling":{"createMessage":{}},"elicitation":{"create":{}}}},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}},"clientInfo":{"name":"Visual Studio Code","version":"1.140.0"}}}
;
const initialized =
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
;

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

test "a session gives one JSON-RPC message for each line, and the bridge stops at the end of stdin while idle" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    b.watchdog.arm("tools/list", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    const list = try expectResult(try b.response(arena, 2));
    const tools = list.object.get("tools") orelse return fail("tools/list has no tools", .{});
    if (tools != .array) return fail("the tools of tools/list are not an array", .{});
    var has_add = false;
    for (tools.array.items) |tool| {
        if (std.mem.eql(u8, mcp.json.getString(tool, "name") orelse "", "add")) has_add = true;
    }
    try testing.expect(has_add);
    if (list.object.get("nextCursor")) |cursor| try testing.expect(cursor == .string);

    b.watchdog.arm("tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
    );
    const call = try expectResult(try b.response(arena, 3));
    try testing.expectEqualStrings("5", try firstText(call));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin while idle");
    try testing.expectEqual(@as(usize, 3 + list_changes.len), try expectFrames(arena, b.out.items));
}

test "the bridge stops at the end of stdin during a slow tools/call, and the child process stops" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // The slow call takes one minute when nothing cancels it. The responses of the ping and
    // of the next call tell that the bridge took the slow call and that the upstream server
    // reads its input.
    b.watchdog.arm("slow tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow","arguments":{"ms":60000}}}
    );
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    );
    _ = try expectResult(try b.response(arena, 3));
    try b.send(
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add","arguments":{"a":1,"b":1}}}
    );
    try testing.expectEqualStrings("2", try firstText(try expectResult(try b.response(arena, 4))));
    try b.io.sleep(.fromMilliseconds(100), .awake);

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin during a tools/call");
    // The responses of initialize, ping and add. A canceled request gets no response.
    try testing.expectEqual(@as(usize, 3 + list_changes.len), try expectFrames(arena, b.out.items));
}

test "VS Code answers the form of a tool over the pipe, and the result of the tool has the answer" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // The tool asks for a form. The bridge sends the form to VS Code as its request b-1, and
    // the answer of VS Code goes upstream in the next round of the tool call.
    b.watchdog.arm("elicitation accept", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_form"}}
    );
    const form = try b.request(arena, "elicitation/create");
    try expectBridgeId(form, "b-1");
    const params = form.params orelse return fail("the elicitation request has no params", .{});
    try testing.expectEqualStrings("Tell us about you.", mcp.json.getString(params, "message") orelse "");
    const schema = params.object.get("requestedSchema") orelse return fail("the elicitation request has no requestedSchema", .{});
    const properties = schema.object.get("properties") orelse return fail("the requestedSchema has no properties", .{});
    for ([_][]const u8{ "name", "age", "subscribe", "color" }) |name| {
        if (properties.object.get(name) == null) return fail("the requestedSchema has no property '{s}'", .{name});
    }
    try b.send(
        \\{"jsonrpc":"2.0","id":"b-1","result":{"action":"accept","content":{"name":"Ada","age":36,"subscribe":true,"color":"green"}}}
    );
    try testing.expectEqualStrings(
        \\form: accept {"name":"Ada","age":36,"subscribe":true,"color":"green"}
    , try firstText(try expectResult(try b.response(arena, 2))));

    // The next request of the bridge has the next id.
    b.watchdog.arm("elicitation decline", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_form"}}
    );
    try expectBridgeId(try b.request(arena, "elicitation/create"), "b-2");
    try b.send(
        \\{"jsonrpc":"2.0","id":"b-2","result":{"action":"decline"}}
    );
    try testing.expectEqualStrings("form: decline", try firstText(try expectResult(try b.response(arena, 3))));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin after the answered forms");
    // The initialize result, and for each tool call the elicitation request and the result.
    try testing.expectEqual(@as(usize, 5 + list_changes.len), try expectFrames(arena, b.out.items));
}

test "the bridge stops at the end of stdin while its requests to VS Code wait for answers" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // One tool asks for a form, and one tool asks for a sampling. The bridge sends both to VS
    // Code, and VS Code never answers.
    b.watchdog.arm("elicitation", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_form"}}
    );
    try expectBridgeId(try b.request(arena, "elicitation/create"), "b-1");
    b.watchdog.arm("sampling", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sample"}}
    );
    try expectBridgeId(try b.request(arena, "sampling/createMessage"), "b-2");

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin with requests of the bridge");
    // The initialize result, the two requests of the bridge and their cancellations. The
    // canceled tools/call requests get no response.
    try testing.expectEqual(@as(usize, 5 + list_changes.len), try expectFrames(arena, b.out.items));
    const frames = try sortFrames(arena, b.out.items);
    try expectStrings(&.{ "b-1", "b-2" }, frames.cancelled);
    try testing.expectEqual(@as(usize, 1), frames.responses.len);
}

test "a crash of the upstream server while a request of the bridge waits fails the calls, and the bridge exits with code 1" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // The form of a tool waits for VS Code. Then the upstream server stops.
    b.watchdog.arm("elicitation", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_form"}}
    );
    try expectBridgeId(try b.request(arena, "elicitation/create"), "b-1");
    b.watchdog.arm("crash tools/call", exchange_limit);
    const start = Io.Timestamp.now(b.io, .awake);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"crash","arguments":{}}}
    );

    // Stdin stays open. The bridge exits by itself.
    const exit = try b.finish(start);
    try expectExit(exit, 1);
    try expectWithin(exit.elapsed, exit_bound, "the exit after the crash of the upstream server with a request of the bridge");
    // The initialize result, the elicitation request, the two errors and the cancellation of
    // the request of the bridge.
    try testing.expectEqual(@as(usize, 5 + list_changes.len), try expectFrames(arena, b.out.items));
    const frames = try sortFrames(arena, b.out.items);
    try expectStrings(&.{"b-1"}, frames.cancelled);
    try expectStrings(&.{"the upstream server stopped"}, frames.cancel_reasons);
    // The initialize result and one error for each call.
    try testing.expectEqual(@as(usize, 3), frames.responses.len);
    for ([_]i64{ 2, 3 }) |id| {
        var found: usize = 0;
        for (frames.responses) |msg| {
            if (msg != .error_response) continue;
            const e = msg.error_response;
            const msg_id = e.id orelse continue;
            if (msg_id != .integer or msg_id.integer != id) continue;
            try testing.expectEqual(@as(i64, -32603), e.code);
            try testing.expectEqualStrings("upstream_exited", mcp.json.getString(e.data orelse .null, "cause") orelse "");
            found += 1;
        }
        if (found != 1) return fail("the request {d} has {d} error responses, not 1", .{ id, found });
    }
    try expectStderr(b, crash_line);
}

test "a crash of the upstream server fails the call in flight with -32603, and the bridge exits with code 1" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    b.watchdog.arm("crash tools/call", exchange_limit);
    const start = Io.Timestamp.now(b.io, .awake);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"crash","arguments":{}}}
    );
    const msg = try b.response(arena, 2);
    if (msg != .error_response) return fail("the crash call got a result and not an error", .{});
    try testing.expectEqual(@as(i64, -32603), msg.error_response.code);
    const data = msg.error_response.data orelse return fail("the error of the crash call has no data", .{});
    try testing.expectEqualStrings("upstream_exited", mcp.json.getString(data, "cause") orelse "");

    // Stdin stays open. The bridge exits by itself.
    const exit = try b.finish(start);
    try expectExit(exit, 1);
    try expectWithin(exit.elapsed, exit_bound, "the exit after the crash of the upstream server");
    try testing.expectEqual(@as(usize, 2 + list_changes.len), try expectFrames(arena, b.out.items));
    // The bridge tells the reason on stderr.
    try expectStderr(b, crash_line);
}

/// The stderr line of the bridge after the crash of the fixture server.
const crash_line = std.fmt.comptimePrint("mcp-bridge-vscode: bridge: error: the upstream server exited with code {d}\n", .{fixture.crash_exit_code});

test "a crash of the upstream server while no request is in flight makes the bridge exit with code 1" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // The call gets its result, and the fixture server stops 200 ms later.
    b.watchdog.arm("delayed crash tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"crash","arguments":{"after_ms":200}}}
    );
    try testing.expectEqualStrings("the server stops in 200 ms", try firstText(try expectResult(try b.response(arena, 2))));
    const start = Io.Timestamp.now(b.io, .awake);

    // Stdin stays open, and no request is in flight. The bridge exits by itself.
    const exit = try b.finish(start);
    try expectExit(exit, 1);
    try expectWithin(exit.elapsed, exit_bound, "the exit after the crash of the upstream server while idle");
    try testing.expectEqual(@as(usize, 2 + list_changes.len), try expectFrames(arena, b.out.items));
    try expectStderr(b, crash_line);
}

test "an upstream server that closes its stdout and continues to run fails initialize, and the bridge stops it" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const discover_timeout_s = 5;
    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--discover-timeout", std.fmt.comptimePrint("{d}", .{discover_timeout_s}), "--", paths.fixture, "--close-stdout" });
    defer b.deinit();
    errdefer b.failed = true;

    // The bridge answers in the time limit of server/discover and the stop of the child
    // process.
    const initialize_bound: Io.Duration = .fromNanoseconds(discover_timeout_s * std.time.ns_per_s + 2 * shutdown_grace.nanoseconds);
    b.watchdog.arm("initialize", exchange_limit);
    const start = Io.Timestamp.now(b.io, .awake);
    try b.send(vscode_initialize);
    const msg = try b.response(arena, 1);
    if (msg != .error_response) return fail("initialize got a result and not an error", .{});
    try testing.expectEqual(@as(i64, -32603), msg.error_response.code);
    try expectWithin(start.untilNow(b.io, .awake), initialize_bound, "the error of initialize");

    // The child process is gone. Thus stderr ends at the exit of the bridge.
    const stop = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(stop);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin after the failed initialize");
    try testing.expectEqual(@as(usize, 1), try expectFrames(arena, b.out.items));
}

test "with --log-level debug, stdout has only JSON-RPC messages, and each stderr line of the bridge has the tag" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--log-level", "debug", "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);
    b.watchdog.arm("tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"marker-7f3c"}}}
    );
    try testing.expectEqualStrings("marker-7f3c", try firstText(try expectResult(try b.response(arena, 2))));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try testing.expectEqual(@as(usize, 2 + list_changes.len), try expectFrames(arena, b.out.items));

    // The lines of the bridge have its tag. The fixture server writes to the same stderr with
    // its own tag. No other line is on stderr.
    const err = b.err.bytes.items;
    if (err.len > 0 and err[err.len - 1] != '\n') return fail("stderr ends with a part of a line", .{});
    var lines = std.mem.splitScalar(u8, err[0..err.len -| 1], '\n');
    var bridge_lines: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "mcp-bridge-vscode: ")) {
            bridge_lines += 1;
            // The bridge does not write the content of a frame to the log.
            if (std.mem.indexOf(u8, line, "marker-7f3c") != null) return fail("a stderr line of the bridge has the content of a frame: {s}", .{line});
        } else if (!std.mem.startsWith(u8, line, "bridge-fixture-server: ")) {
            return fail("a stderr line without a tag: {s}", .{line});
        }
    }
    try testing.expect(bridge_lines > 0);
    // The debug lines tell the round of each upstream request and the request of VS Code.
    try expectStderr(b, "mcp-bridge-vscode: bridge: debug: upstream request ");
    try expectStderr(b, "(tools/call, round 1 of client request 2): response after ");
}

test "the bridge exits with code 0 when stdin ends before initialize" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin before initialize");
    try testing.expectEqualStrings("", b.out.items);
}

test "arguments that are not valid give exit code 2 and no stdout" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const cases = [_][]const []const u8{
        &.{},
        &.{"--"},
        &.{paths.fixture},
        &.{ "--unknown", "--", paths.fixture },
        &.{ "--log-level", "loud", "--", paths.fixture },
        &.{ "--name", "--", paths.fixture },
        &.{ "--max-line-bytes", "0", "--", paths.fixture },
        &.{ "--version=1", "--", paths.fixture },
    };
    for (cases) |args| {
        const argv = try std.mem.concat(arena, []const u8, &.{ &.{paths.bridge}, args });
        const b = try Bridge.spawn(gpa, argv);
        defer b.deinit();
        errdefer {
            b.failed = true;
            std.debug.print("process test: the arguments were {f}\n", .{std.json.fmt(args, .{})});
        }
        const start = Io.Timestamp.now(b.io, .awake);
        b.closeStdin();
        const exit = try b.finish(start);
        try expectExit(exit, 2);
        try testing.expectEqualStrings("", b.out.items);
        try testing.expect(b.err.bytes.items.len > 0);
    }
}

test "--version and --help write to stdout and exit with code 0" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    {
        const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--version" });
        defer b.deinit();
        errdefer b.failed = true;
        b.closeStdin();
        try expectExit(try b.finish(Io.Timestamp.now(b.io, .awake)), 0);
        try testing.expectEqualStrings("mcp-bridge-vscode " ++ build_options.version ++ "\n", b.out.items);
    }
    {
        const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--help" });
        defer b.deinit();
        errdefer b.failed = true;
        b.closeStdin();
        try expectExit(try b.finish(Io.Timestamp.now(b.io, .awake)), 0);
        try testing.expect(std.mem.startsWith(u8, b.out.items, "Usage: mcp-bridge-vscode "));
    }
}

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/// The list changes after the acknowledgment of the first listen stream, in their order. The
/// fixture server declares the list changes of its tools, prompts and resources.
const list_changes = [_][]const u8{
    "notifications/tools/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/list_changed",
};

/// Send `initialize` and `notifications/initialized`, and examine the `initialize` result.
/// Then read the list changes after the acknowledgment of the first listen stream. Thus the
/// number of frames of a test does not depend on the time of the acknowledgment.
fn initialize(b: *Bridge, arena: Allocator) !void {
    b.watchdog.arm("initialize", exchange_limit);
    try b.send(vscode_initialize);
    const result = try expectResult(try b.response(arena, 1));
    try testing.expectEqualStrings("2025-11-25", mcp.json.getString(result, "protocolVersion") orelse "");
    const server_info = result.object.get("serverInfo") orelse return fail("the initialize result has no serverInfo", .{});
    try testing.expectEqualStrings(fixture.server_name, mcp.json.getString(server_info, "name") orelse "");
    const capabilities = result.object.get("capabilities") orelse return fail("the initialize result has no capabilities", .{});
    try testing.expect(capabilities == .object);
    try testing.expect(capabilities.object.get("tools") != null);
    try testing.expect(capabilities.object.get("tasks") == null);
    try testing.expect(capabilities.object.get("logging") != null);
    try testing.expect(result.object.get("resultType") == null);
    try b.send(initialized);
    for (list_changes) |method| _ = try b.notification(arena, method);
}

/// The paths of the two executables.
const Paths = struct {
    bridge: []const u8,
    fixture: []const u8,

    fn get(arena: Allocator) !Paths {
        return .{
            .bridge = try executable(arena, "PROCESS_TEST_BRIDGE", process_options.bridge_exe),
            .fixture = try executable(arena, "PROCESS_TEST_FIXTURE", process_options.fixture_exe),
        };
    }

    /// The path from the environment variable `name`, else `built`. The file must exist.
    fn executable(arena: Allocator, name: []const u8, built: []const u8) ![]const u8 {
        const path = testing.environ.getAlloc(arena, name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => built,
            else => return err,
        };
        Io.Dir.cwd().access(testing.io, path, .{}) catch |err| {
            std.debug.print(
                "process test: the executable '{s}' is missing ({t}). Run the tests with 'zig build test', or set {s}.\n",
                .{ path, err, name },
            );
            return error.MissingExecutable;
        };
        return path;
    }
};

/// A process of the bridge with pipes for stdin, stdout and stderr. The test reads stdout.
/// A task reads stderr until its end. The bridge must not move, thus `spawn` allocates it.
const Bridge = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    stdin: ?Io.File,
    stdout: Io.File,
    /// All bytes of stdout so far.
    out: std.ArrayList(u8) = .empty,
    /// The number of bytes of `out` that `nextLine` gave.
    consumed: usize = 0,
    out_eof: bool = false,
    err: Drain,
    /// Holds the task of `err`.
    group: Io.Group = .init,
    watchdog: Watchdog,
    /// True after a failed check. Then `deinit` writes stdout and stderr of the bridge.
    failed: bool = false,

    /// Start the bridge with `argv`, and start the watchdog and the stderr task.
    fn spawn(gpa: Allocator, argv: []const []const u8) !*Bridge {
        const io = testing.io;
        const self = try gpa.create(Bridge);
        errdefer gpa.destroy(self);
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        self.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .stdin = child.stdin,
            .stdout = child.stdout.?,
            .err = .{ .file = child.stderr.?, .gpa = gpa },
            .watchdog = .{ .io = io, .target = child.id.? },
        };
        // The bridge owns the pipes. Thus `wait` does not close them while a task reads them.
        self.child.stdin = null;
        self.child.stdout = null;
        self.child.stderr = null;
        errdefer {
            if (self.stdin) |f| f.close(io);
            self.child.kill(io);
            self.stdout.close(io);
            self.err.file.close(io);
        }
        try self.watchdog.start();
        errdefer self.watchdog.stop();
        try self.group.concurrent(io, Drain.run, .{ &self.err, io });
        return self;
    }

    /// Stop the bridge when it still runs, wait for the stderr task and release all.
    fn deinit(self: *Bridge) void {
        const io = self.io;
        const gpa = self.gpa;
        self.closeStdin();
        if (self.child.id != null) {
            // The test did not wait for the exit. After `forget`, the watchdog does not use
            // the process id, because `kill` releases it.
            self.watchdog.forget();
            self.watchdog.arm("cleanup", exchange_limit);
            self.child.kill(io);
        }
        self.group.await(io) catch {};
        if (self.failed) self.report();
        self.watchdog.stop();
        self.stdout.close(io);
        self.err.file.close(io);
        self.out.deinit(gpa);
        self.err.bytes.deinit(gpa);
        gpa.destroy(self);
    }

    fn report(self: *Bridge) void {
        std.debug.print("process test: stdout of the bridge ({d} bytes):\n{s}\n", .{ self.out.items.len, self.out.items });
        if (self.err.eof.load(.acquire)) {
            std.debug.print("process test: stderr of the bridge:\n{s}\n", .{self.err.bytes.items});
        } else {
            std.debug.print("process test: stderr of the bridge did not end\n", .{});
        }
    }

    /// Write `line` and a newline to stdin of the bridge.
    fn send(self: *Bridge, line: []const u8) !void {
        const stdin = self.stdin orelse return error.StdinClosed;
        const frame = try std.mem.concat(self.gpa, u8, &.{ line, "\n" });
        defer self.gpa.free(frame);
        stdin.writeStreamingAll(self.io, frame) catch |err| {
            std.debug.print("process test: cannot write to stdin of the bridge: {t}\n", .{err});
            return err;
        };
    }

    fn closeStdin(self: *Bridge) void {
        if (self.stdin) |f| {
            f.close(self.io);
            self.stdin = null;
        }
    }

    /// Read more bytes of stdout. A read error or the end of the stream sets `out_eof`.
    fn fill(self: *Bridge) !void {
        var buf: [16 << 10]u8 = undefined;
        const n = self.stdout.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => {
                self.out_eof = true;
                return;
            },
            error.Canceled => return error.Canceled,
            else => {
                std.debug.print("process test: cannot read stdout of the bridge: {t}\n", .{err});
                self.out_eof = true;
                return;
            },
        };
        try self.out.appendSlice(self.gpa, buf[0..n]);
    }

    /// Return the next line of stdout without its newline. The memory is in `arena`.
    fn nextLine(self: *Bridge, arena: Allocator) ![]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.out.items, self.consumed, '\n')) |nl| {
                const line = try arena.dupe(u8, self.out.items[self.consumed..nl]);
                self.consumed = nl + 1;
                return line;
            }
            if (self.out_eof) {
                if (self.watchdog.expiredPhase()) |phase| return fail("the phase '{s}' did not end in time", .{phase});
                return fail("stdout of the bridge ended before the expected response", .{});
            }
            try self.fill();
        }
    }

    /// Read stdout until the response with `id`. Each line must be one JSON-RPC message. The
    /// function ignores notifications. Each other message is an error.
    fn response(self: *Bridge, arena: Allocator, id: i64) !Message {
        while (true) {
            const line = try self.nextLine(arena);
            const msg = try parseFrame(arena, line);
            const msg_id: ?mcp.RequestId = switch (msg) {
                .notification => continue,
                .request => null,
                .response => |r| r.id,
                .error_response => |r| r.id,
            };
            if (msg_id) |i| if (i == .integer and i.integer == id) return msg;
            return fail("the bridge sent a message that is not the response {d}: {s}", .{ id, line });
        }
    }

    /// Read the next message of stdout, and check that it is a notification with the method
    /// `method`. Returns its params, or null.
    fn notification(self: *Bridge, arena: Allocator, method: []const u8) !?Value {
        const line = try self.nextLine(arena);
        switch (try parseFrame(arena, line)) {
            .notification => |n| {
                if (std.mem.eql(u8, n.method, method)) return n.params;
                return fail("the bridge sent the notification {s}, not {s}", .{ n.method, method });
            },
            else => return fail("the bridge sent a message that is not the notification {s}: {s}", .{ method, line }),
        }
    }

    /// Read stdout until the next request of the bridge, and check that its method is
    /// `method`. The function ignores notifications. Each other message is an error.
    fn request(self: *Bridge, arena: Allocator, method: []const u8) !Message.Request {
        while (true) {
            const line = try self.nextLine(arena);
            switch (try parseFrame(arena, line)) {
                .notification => continue,
                .request => |r| {
                    if (std.mem.eql(u8, r.method, method)) return r;
                    return fail("the bridge sent the request {s}, not {s}: {s}", .{ r.method, method, line });
                },
                else => return fail("the bridge sent a message that is not the request {s}: {s}", .{ method, line }),
            }
        }
    }

    /// Read stdout and stderr to their end, and wait for the exit of the bridge. The end of
    /// stderr comes only after the exit of each process with a copy of the stderr of the
    /// bridge. The upstream child process gets that copy. Thus the function also waits for
    /// the exit of the child process. `start` is the start of the measured time.
    fn finish(self: *Bridge, start: Io.Timestamp) !Exit {
        const io = self.io;
        self.watchdog.arm("exit", exit_limit);
        while (!self.out_eof) try self.fill();
        try self.group.await(io);
        if (self.watchdog.expiredPhase()) |phase| return fail("the phase '{s}' did not end in time", .{phase});
        self.watchdog.forget();
        const term = try self.child.wait(io);
        self.watchdog.disarm();
        return .{ .term = term, .elapsed = start.untilNow(io, .awake) };
    }
};

const Exit = struct {
    term: std.process.Child.Term,
    /// The time from the start of the measurement to the end of stdout and stderr and the
    /// exit of the bridge.
    elapsed: Io.Duration,
};

/// Reads stderr of the bridge until its end.
const Drain = struct {
    file: Io.File,
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// True after the end of stderr. The task does not change `bytes` after this.
    eof: std.atomic.Value(bool) = .init(false),

    fn run(self: *Drain, io: Io) void {
        defer self.eof.store(true, .release);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(io, &.{&buf}) catch return;
            if (self.bytes.items.len < max_captured_stderr) self.bytes.appendSlice(self.gpa, buf[0..n]) catch {};
        }
    }
};

/// A thread that stops the bridge when a phase of the test does not end in time. A stop of
/// the bridge closes its pipes. Thus each blocked read of the test ends, and the test fails.
/// When the test then does not end in `hard_stop`, the thread stops the test process.
const Watchdog = struct {
    io: Io,
    /// The process of the bridge, or null after `forget`. Guarded by `lock`.
    target: ?std.process.Child.Id,
    lock: Io.Mutex = .init,
    /// The phase with a time limit, or null. Guarded by `lock`.
    phase: ?[]const u8 = null,
    /// The end of the time limit of `phase`. Guarded by `lock`.
    deadline: Io.Timestamp = .{ .nanoseconds = 0 },
    /// The first phase that did not end in time, or null. Guarded by `lock`.
    expired: ?[]const u8 = null,
    /// The time of the panic after an expired phase. Guarded by `lock`.
    panic_at: Io.Timestamp = .{ .nanoseconds = 0 },
    quit: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    const poll_interval: Io.Duration = .fromMilliseconds(20);

    fn start(self: *Watchdog) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *Watchdog) void {
        self.quit.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Start a time limit of `limit` for `phase`. The limit replaces the limit before it.
    fn arm(self: *Watchdog, phase: []const u8, limit: Io.Duration) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.phase = phase;
        self.deadline = Io.Timestamp.now(self.io, .awake).addDuration(limit);
    }

    fn disarm(self: *Watchdog) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.phase = null;
    }

    /// Do not stop the process from now on. Call this before `wait` or `kill` releases the
    /// process id.
    fn forget(self: *Watchdog) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.target = null;
    }

    fn expiredPhase(self: *Watchdog) ?[]const u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.expired;
    }

    fn run(self: *Watchdog) void {
        while (!self.quit.load(.acquire)) {
            self.io.sleep(poll_interval, .awake) catch {};
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const now = Io.Timestamp.now(self.io, .awake);
            if (self.phase) |phase| if (now.nanoseconds >= self.deadline.nanoseconds) {
                std.debug.print("process test: the phase '{s}' did not end in time. The watchdog stops the bridge.\n", .{phase});
                if (self.target) |id| killProcess(id);
                if (self.expired == null) self.expired = phase;
                self.phase = null;
                self.panic_at = now.addDuration(hard_stop);
            };
            if (self.expired) |phase| if (!self.quit.load(.acquire) and now.nanoseconds >= self.panic_at.nanoseconds) {
                std.debug.panic("process test: the test did not end after the phase '{s}' expired", .{phase});
            };
        }
    }

    /// Stop the process at once. The function does not release the process id.
    fn killProcess(id: std.process.Child.Id) void {
        switch (builtin.os.tag) {
            .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
            .wasi => {},
            else => std.posix.kill(id, .KILL) catch {},
        }
    }
};

/// Parse one line of stdout. The line must be exactly one JSON-RPC message.
fn parseFrame(arena: Allocator, line: []const u8) !Message {
    return Message.parse(arena, line) catch |err| fail("a line of stdout is not one JSON-RPC message ({t}): {s}", .{ err, line });
}

/// Check that each line of `out` is one JSON-RPC message and that `out` ends with a newline.
/// Return the number of messages.
fn expectFrames(arena: Allocator, out: []const u8) !usize {
    if (out.len > 0 and out[out.len - 1] != '\n') return fail("stdout of the bridge ends with a part of a line", .{});
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (lines.peek() == null) break; // The empty text after the last newline.
        _ = try parseFrame(arena, line);
        count += 1;
    }
    return count;
}

/// The messages of stdout by kind.
const Frames = struct {
    /// The responses and the error responses.
    responses: []const Message,
    /// The `requestId` of each `notifications/cancelled`, in alphabetical order.
    cancelled: []const []const u8,
    /// The `reason` of each `notifications/cancelled`, in alphabetical order.
    cancel_reasons: []const []const u8,
};

/// Parse each line of `out`, and sort the messages by kind. The tasks of the bridge write
/// their frames at the same time, thus the order of two cancellations can change.
fn sortFrames(arena: Allocator, out: []const u8) !Frames {
    var responses: std.ArrayList(Message) = .empty;
    var cancelled: std.ArrayList([]const u8) = .empty;
    var reasons: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const msg = try parseFrame(arena, line);
        switch (msg) {
            .response, .error_response => try responses.append(arena, msg),
            .notification => |n| if (std.mem.eql(u8, n.method, "notifications/cancelled")) {
                const params = n.params orelse return fail("a cancellation without params: {s}", .{line});
                try cancelled.append(arena, mcp.json.getString(params, "requestId") orelse return fail("a cancellation without a string id: {s}", .{line}));
                try reasons.append(arena, mcp.json.getString(params, "reason") orelse "");
            },
            .request => {},
        }
    }
    std.mem.sort([]const u8, cancelled.items, {}, lessThan);
    std.mem.sort([]const u8, reasons.items, {}, lessThan);
    return .{ .responses = responses.items, .cancelled = cancelled.items, .cancel_reasons = reasons.items };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Check that `actual` has the strings of `expected` in the same order.
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    if (expected.len == actual.len) {
        for (expected, actual) |want, got| {
            if (!std.mem.eql(u8, want, got)) break;
        } else return;
    }
    return fail("expected the strings {f}, got {f}", .{ std.json.fmt(expected, .{}), std.json.fmt(actual, .{}) });
}

/// Return the `result` of a response, or fail for an error response.
fn expectResult(msg: Message) !Value {
    return switch (msg) {
        .response => |r| if (r.result == .object) r.result else fail("the result is not an object", .{}),
        .error_response => |e| fail("the bridge sent the error {d}: {s}", .{ e.code, e.message }),
        else => fail("the message is not a response", .{}),
    };
}

/// Check that the id of a request of the bridge is the string `id`.
fn expectBridgeId(r: Message.Request, id: []const u8) !void {
    switch (r.id) {
        .string => |s| if (std.mem.eql(u8, s, id)) return else return fail("the request {s} of the bridge has the id '{s}', not '{s}'", .{ r.method, s, id }),
        else => return fail("the request {s} of the bridge has an id that is not a string", .{r.method}),
    }
}

/// Return the text of the first content block of a `tools/call` result.
fn firstText(result: Value) ![]const u8 {
    const content = result.object.get("content") orelse return fail("the tools/call result has no content", .{});
    if (content != .array or content.array.items.len == 0) return fail("the content of the tools/call result is empty", .{});
    return mcp.json.getString(content.array.items[0], "text") orelse fail("the first content block has no text", .{});
}

fn expectExit(exit: Exit, code: u8) !void {
    switch (exit.term) {
        .exited => |c| if (c == code) return else return fail("the exit code of the bridge is {d}, not {d}", .{ c, code }),
        else => return fail("the bridge stopped without an exit code ({any}), not with code {d}", .{ exit.term, code }),
    }
}

/// Check that stderr of the bridge has `text`. Call this after `Bridge.finish`.
fn expectStderr(b: *Bridge, text: []const u8) !void {
    if (std.mem.indexOf(u8, b.err.bytes.items, text) != null) return;
    return fail("stderr does not have the text '{s}'", .{text});
}

fn expectWithin(elapsed: Io.Duration, bound: Io.Duration, what: []const u8) !void {
    if (elapsed.nanoseconds <= bound.nanoseconds) return;
    return fail("{s} took {d} ms. The limit is {d} ms.", .{ what, elapsed.toMilliseconds(), bound.toMilliseconds() });
}

/// Write the reason of a failure and return an error.
fn fail(comptime format: []const u8, args: anytype) error{TestFailed} {
    std.debug.print("process test: " ++ format ++ "\n", args);
    return error.TestFailed;
}
