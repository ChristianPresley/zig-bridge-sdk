//! The process tests of `mcp-bridge-vscode`. Each test starts the executable as VS Code does,
//! with a pipe for stdin, stdout and stderr. The upstream command is `bridge-fixture-server`.
//!
//! The tests of the URL form use an upstream server over HTTP. Most of them start
//! `bridge-fixture-server` in its HTTPS mode in a second process, and give the test CA to the
//! bridge with `--ca-file`. The test is the browser of the user. It reads the sign-in line on
//! stderr and opens the URL with `fixture.https.browse`. That function follows the redirect
//! into the loopback receiver of the bridge. The bridge gets `--no-browser`, and a token store
//! that never uses the keychain of the host.
//!
//! On a POSIX system, one test of the URL form opens the browser. The environment variable
//! `BROWSER` names a script of the test. The script records its arguments, and then
//! `bridge-fixture-server --browse` opens the start URL. On Windows, the opener of the system
//! starts the real browser, thus that test does not run there.
//!
//! The tests of `vscode.serveStdio` start `bridge-embedded-server`. That executable has the
//! server of `bridge-fixture-server` and the bridge in one process. VS Code speaks to it over
//! the pipes, and a client of revision 2026-07-28 speaks to it through
//! `mcp.transport.stdio.Client.spawn`.
//!
//! The build makes the three executables before it compiles this file. The module
//! `process_options` holds their paths. The environment variables `PROCESS_TEST_BRIDGE`,
//! `PROCESS_TEST_FIXTURE` and `PROCESS_TEST_EMBEDDED` replace these paths, for example for a
//! run in WSL. A missing executable makes the test fail. The tests never skip.
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

    // The answer of VS Code to a form goes upstream, and the log has none of its content.
    b.watchdog.arm("form answer", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_form"}}
    );
    try expectBridgeId(try b.request(arena, "elicitation/create"), "b-1");
    try b.send(
        \\{"jsonrpc":"2.0","id":"b-1","result":{"action":"accept","content":{"name":"marker-form-5d1e","age":36,"subscribe":true,"color":"green"}}}
    );
    try testing.expectEqualStrings(
        \\form: accept {"name":"marker-form-5d1e","age":36,"subscribe":true,"color":"green"}
    , try firstText(try expectResult(try b.response(arena, 3))));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    // The initialize result, the list changes, the echo result, the form request and the
    // result of the form tool.
    try testing.expectEqual(@as(usize, 4 + list_changes.len), try expectFrames(arena, b.out.items));

    // The lines of the bridge have its tag. The fixture server writes to the same stderr with
    // its own tag. No other line is on stderr.
    const err = b.err.bytes.items;
    if (err.len > 0 and err[err.len - 1] != '\n') return fail("stderr ends with a part of a line", .{});
    var lines = std.mem.splitScalar(u8, err[0..err.len -| 1], '\n');
    var bridge_lines: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "mcp-bridge-vscode: ")) {
            bridge_lines += 1;
            // The bridge does not write the content of a frame or of a form answer to the log.
            if (std.mem.indexOf(u8, line, "marker-7f3c") != null) return fail("a stderr line of the bridge has the content of a frame: {s}", .{line});
            if (std.mem.indexOf(u8, line, "marker-form-5d1e") != null) return fail("a stderr line of the bridge has the content of a form answer: {s}", .{line});
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
        // The URL form: http only for a loopback host, a missing environment variable, a
        // refused header name, an option of the URL form with a command, a CA file that the
        // bridge cannot read, and logout without a URL.
        &.{"http://mcp.example.com/mcp"},
        &.{ "--header-env", "authorization=MCP_BRIDGE_PROCESS_TEST_NOT_SET", "https://127.0.0.1:9/mcp" },
        &.{ "--header", "host:x", "https://127.0.0.1:9/mcp" },
        &.{ "--header", "x-a:1", "--", paths.fixture },
        &.{ "--ca-file", "test/fixtures/no-such-ca.pem", "https://127.0.0.1:9/mcp" },
        &.{"logout"},
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

/// The number of calls of the test of the order of the frames.
const ordering_loops = 1000;

/// The time limit of the calls of the test of the order of the frames. Each call is one
/// exchange over the pipes, thus the calls usually take a few seconds.
const ordering_limit: Io.Duration = .fromSeconds(60);

test "a tool that changes the tool list: the list change comes before the result of the call, 1000 times" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // The upstream server writes the list change to the listen stream before the result. The
    // listen stream gives its events to the bridge on the reader task of the upstream client.
    // Thus VS Code gets the list change first, and lists the tools again before the next turn.
    b.watchdog.arm("toggle calls", ordering_limit);
    var inversions: usize = 0;
    for (0..ordering_loops) |i| {
        const id: i64 = @intCast(i + 2);
        // The tool `toggled` is enabled at the start, thus the first call disables it.
        const enabled = i % 2 == 1;
        var buf: [160]u8 = undefined;
        try b.send(try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"toggle\",\"arguments\":{{\"enabled\":{}}}}}}}", .{ id, enabled }));
        const notifications, const msg = try b.responseWithNotifications(arena, id);
        const text = try firstText(try expectResult(msg));
        try testing.expectEqualStrings(if (enabled) "tool toggled: enabled" else "tool toggled: disabled", text);
        if (notifications.len != 1) {
            inversions += 1;
            continue;
        }
        try testing.expectEqualStrings("notifications/tools/list_changed", notifications[0].method);
    }
    if (inversions != 0) return fail("{d} of {d} results came before their list change", .{ inversions, ordering_loops });

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin with an open listen stream");
    try testing.expectEqual(@as(usize, 1 + list_changes.len + 2 * ordering_loops), try expectFrames(arena, b.out.items));
}

test "the log messages of the upstream server reach VS Code at the level of logging/setLevel, and no cancellation of the upstream server does" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // Without a level, the upstream server sends no log message.
    b.watchdog.arm("log without a level", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"log"}}
    );
    const none, _ = try b.responseWithNotifications(arena, 2);
    try testing.expectEqual(@as(usize, 0), none.len);

    // On stdio, a log message has no id of a request. The bridge gets it through the
    // notification callback of the upstream client.
    const cases = [_]struct { level: []const u8, expected: []const []const u8 }{
        .{ .level = "warning", .expected = &.{ "warning", "error" } },
        .{ .level = "debug", .expected = &.{ "debug", "info", "warning", "error" } },
    };
    var id: i64 = 3;
    for (cases) |case| {
        b.watchdog.arm("logging/setLevel", exchange_limit);
        var buf: [128]u8 = undefined;
        try b.send(try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"logging/setLevel\",\"params\":{{\"level\":\"{s}\"}}}}", .{ id, case.level }));
        _ = try expectResult(try b.response(arena, id));
        id += 1;
        b.watchdog.arm("log", exchange_limit);
        try b.send(try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"log\"}}}}", .{id}));
        const notifications, const msg = try b.responseWithNotifications(arena, id);
        try testing.expectEqualStrings("logged 4 messages", try firstText(try expectResult(msg)));
        try testing.expectEqual(case.expected.len, notifications.len);
        for (notifications, case.expected) |n, level| {
            try testing.expectEqualStrings("notifications/message", n.method);
            const params = n.params orelse return fail("a log message without params", .{});
            try testing.expectEqualStrings(level, mcp.json.getString(params, "level") orelse "");
            try testing.expectEqualStrings(fixture.log_logger, mcp.json.getString(params, "logger") orelse "");
            try testing.expect(params.object.get("data").? == .string);
            try testing.expect(params.object.get("_meta") == null);
        }
        id += 1;
    }

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin after the log messages");
    // At the end of stdin, the bridge cancels its listen stream before it closes the upstream
    // server. No request of the bridge waits for VS Code, thus no cancellation goes to VS
    // Code.
    if (std.mem.indexOf(u8, b.out.items, "notifications/cancelled") != null) return fail("stdout has a notifications/cancelled", .{});
    try testing.expectEqual(@as(usize, 1 + list_changes.len + 1 + 2 * 2 + 2 + 4), try expectFrames(arena, b.out.items));
}

test "resources/subscribe: the response comes first, then the updates of the resource until resources/unsubscribe" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    const subscribe =
        \\{"jsonrpc":"2.0","id":2,"method":"resources/subscribe","params":{"uri":"
    ++ fixture.notes_uri ++
        \\"}}
    ;
    const touch =
        \\"method":"tools/call","params":{"name":"touch","arguments":{"uri":"
    ++ fixture.notes_uri ++
        \\"}}}
    ;
    // The bridge opens a new listen stream with the URI. Its acknowledgment gives the
    // response, and the swap gives no list change.
    b.watchdog.arm("resources/subscribe", exchange_limit);
    try b.send(subscribe);
    const before_subscribe, const subscribed = try b.responseWithNotifications(arena, 2);
    try testing.expectEqual(@as(usize, 0), before_subscribe.len);
    try testing.expectEqual(@as(usize, 0), (try expectResult(subscribed)).object.count());

    // The update of the resource comes before the result of the call that caused it.
    b.watchdog.arm("touch", exchange_limit);
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":3," ++ touch);
    const updates, const touched = try b.responseWithNotifications(arena, 3);
    try testing.expectEqualStrings("touched " ++ fixture.notes_uri, try firstText(try expectResult(touched)));
    try testing.expectEqual(@as(usize, 1), updates.len);
    try testing.expectEqualStrings("notifications/resources/updated", updates[0].method);
    const params = updates[0].params orelse return fail("the update has no params", .{});
    try testing.expectEqualStrings(fixture.notes_uri, mcp.json.getString(params, "uri") orelse "");
    // The subscription id of the upstream server does not reach VS Code.
    try testing.expect(params.object.get("_meta") == null);

    b.watchdog.arm("resources/unsubscribe", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":4,"method":"resources/unsubscribe","params":{"uri":"
    ++ fixture.notes_uri ++
        \\"}}
    );
    _ = try expectResult(try b.response(arena, 4));
    b.watchdog.arm("touch after unsubscribe", exchange_limit);
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":5," ++ touch);
    const none, _ = try b.responseWithNotifications(arena, 5);
    try testing.expectEqual(@as(usize, 0), none.len);

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin with a subscription");
    try testing.expectEqual(@as(usize, 1 + list_changes.len + 4 + 1), try expectFrames(arena, b.out.items));
}

test "the upstream server ends its listen stream at its shutdown: VS Code gets no notifications/cancelled, and the bridge exits with code 1" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    // The debug lines tell that the bridge got the cancellation of the upstream server.
    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--log-level", "debug", "--", paths.fixture });
    defer b.deinit();
    errdefer b.failed = true;

    try initialize(b, arena);

    // The fixture server ends its listen stream as at the end of its input. On stdio, the
    // stream gets its result and then a notifications/cancelled with the id of the stream.
    // That id is an id of the bridge, and VS Code can have a request with the same id. The
    // server stops 100 ms later, before the bridge opens a new stream (500 ms).
    b.watchdog.arm("shutdown tools/call", exchange_limit);
    const start = Io.Timestamp.now(b.io, .awake);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shutdown","arguments":{"after_ms":100}}}
    );
    try testing.expectEqualStrings(
        "the server ended its listen streams and stops in 100 ms",
        try firstText(try expectResult(try b.response(arena, 2))),
    );

    // Stdin stays open. The bridge exits by itself.
    const exit = try b.finish(start);
    try expectExit(exit, 1);
    try expectWithin(exit.elapsed, exit_bound, "the exit after the shutdown of the upstream server");
    // The initialize result and the result of the call. A new listen stream can still give
    // list changes when the bridge opens it before the end of the upstream server, but never a
    // cancellation.
    _ = try expectFrames(arena, b.out.items);
    const frames = try sortFrames(arena, b.out.items);
    try testing.expectEqual(@as(usize, 2), frames.responses.len);
    try expectStrings(&.{}, frames.cancelled);
    if (std.mem.indexOf(u8, b.out.items, "notifications/cancelled") != null) return fail("stdout has a notifications/cancelled", .{});
    // The upstream server sent the cancellation, and the bridge dropped it.
    try expectStderr(b, "mcp-bridge-vscode: bridge: debug: dropped the notification notifications/cancelled of the upstream server");
    try expectStderr(b, std.fmt.comptimePrint("mcp-bridge-vscode: bridge: error: the upstream server exited with code {d}\n", .{fixture.shutdown_exit_code}));
}

// ---------------------------------------------------------------------------------------------
// The bridge in the process of the server (`vscode.serveStdio`)
// ---------------------------------------------------------------------------------------------

test "the embedded server: initialize selects the legacy path, a tool asks for a form, and the process exits with code 0 at the end of stdin" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{paths.embedded});
    defer b.deinit();
    errdefer b.failed = true;

    // The server of the process is the upstream server of the bridge. Its listen stream gives
    // the list changes after notifications/initialized.
    try initialize(b, arena);

    // VS Code lists the tools after the list change. The schemas come through the bridge.
    b.watchdog.arm("tools/list", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"progressToken":0}}}
    );
    const list = try expectResult(try b.response(arena, 2));
    const tools = list.object.get("tools") orelse return fail("tools/list has no tools", .{});
    if (tools != .array) return fail("the tools of tools/list are not an array", .{});
    var has_add = false;
    var has_ask_form = false;
    for (tools.array.items) |tool| {
        const name = mcp.json.getString(tool, "name") orelse "";
        if (std.mem.eql(u8, name, "add")) has_add = true;
        if (std.mem.eql(u8, name, "ask_form")) has_ask_form = true;
        const schema = tool.object.get("inputSchema") orelse return fail("the tool {s} has no inputSchema", .{name});
        try testing.expectEqualStrings("object", mcp.json.getString(schema, "type") orelse "");
    }
    try testing.expect(has_add);
    try testing.expect(has_ask_form);
    if (list.object.get("nextCursor")) |cursor| try testing.expect(cursor == .string);

    b.watchdog.arm("tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
    );
    try testing.expectEqualStrings("5", try firstText(try expectResult(try b.response(arena, 3))));

    // The bridge does the MRTR rounds of the tool for VS Code. The test is the user, and it
    // answers the form over stdin.
    b.watchdog.arm("elicitation", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ask_form"}}
    );
    try expectBridgeId(try b.request(arena, "elicitation/create"), "b-1");
    try b.send(
        \\{"jsonrpc":"2.0","id":"b-1","result":{"action":"accept","content":{"name":"Ada","age":36,"subscribe":true,"color":"green"}}}
    );
    try testing.expectEqualStrings(
        \\form: accept {"name":"Ada","age":36,"subscribe":true,"color":"green"}
    , try firstText(try expectResult(try b.response(arena, 4))));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop of the embedded server at the end of stdin");
    // The responses of initialize, tools/list, add and ask_form, the list changes and the
    // form.
    try testing.expectEqual(@as(usize, 5 + list_changes.len), try expectFrames(arena, b.out.items));
}

test "the embedded server with --refuse-discover: the Copilot harness gets -32601 for server/discover and selects the legacy path" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{ paths.embedded, "--refuse-discover" });
    defer b.deinit();
    errdefer b.failed = true;

    b.watchdog.arm("server/discover", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"sampling":{},"elicitation":{"form":{},"url":{}}},"io.modelcontextprotocol/clientInfo":{"name":"copilot-cli","version":"1.0.89"}}}}
    );
    switch (try b.response(arena, 1)) {
        .error_response => |e| try testing.expectEqual(@as(i64, -32601), e.code),
        else => return fail("server/discover did not get an error", .{}),
    }

    b.watchdog.arm("initialize", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"sampling":{},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"copilot-cli","version":"1.0.89"}}}
    );
    const result = try expectResult(try b.response(arena, 2));
    try testing.expectEqualStrings("2025-11-25", mcp.json.getString(result, "protocolVersion") orelse "");
    try b.send(initialized);
    for (list_changes) |method| _ = try b.notification(arena, method);

    b.watchdog.arm("tools/list", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{"progressToken":0}}}
    );
    const list = try expectResult(try b.response(arena, 3));
    const tools = list.object.get("tools") orelse return fail("tools/list has no tools", .{});
    if (tools != .array or tools.array.items.len == 0) return fail("tools/list has no tools", .{});

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop of the embedded server at the end of stdin");
}

test "the embedded server: a client of revision 2026-07-28 selects the modern path, and the process exits with code 0 at the end of stdin" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    // The stdio client of zig-sdk starts the process, as a client of revision 2026-07-28 does.
    // Each request has a time limit, and `close` stops the process after two grace periods.
    const proc = try mcp.transport.stdio.Client.spawn(io, gpa, .{ .argv = &.{paths.embedded} });
    defer proc.deinit();
    var client: mcp.Client = .init(gpa, io, .{ .info = .{ .name = "process-test", .version = "1.0.0" } });
    defer client.deinit();
    client.connect(proc.transport());
    const options: mcp.Client.RequestOptions = .{ .timeout = exchange_limit };

    const discovered = try client.discover(arena, options);
    for (discovered.supportedVersions) |v| {
        if (std.mem.eql(u8, v, "2026-07-28")) break;
    } else return fail("server/discover does not name the revision 2026-07-28", .{});
    try testing.expect(discovered.capabilities.tools != null);

    const listed = try client.listTools(arena, null, options);
    for (listed.tools) |tool| {
        if (std.mem.eql(u8, tool.name, "add")) break;
    } else return fail("tools/list has no tool add", .{});

    const called = try client.callTool(arena, "add", .{ .a = 2, .b = 3 }, options);
    if (called.content.len == 0 or called.content[0] != .text) return fail("the result of add has no text", .{});
    try testing.expectEqualStrings("5", called.content[0].text.text);

    // `close` closes stdin of the process and waits for its exit. A process that does not
    // exit in the grace period gets a signal, and then its status is not the exit code 0.
    const start = Io.Timestamp.now(io, .awake);
    proc.close();
    try expectWithin(start.untilNow(io, .awake), exit_bound, "the stop of the embedded server at the end of stdin");
    const term = proc.exitStatus() orelse return fail("the stdio client has no exit status of the process", .{});
    try expectExit(.{ .term = term, .elapsed = .fromNanoseconds(0) }, 0);
}

test "the embedded server stops at the end of stdin on the legacy path with a listen stream, a slow call, a form and a sampling in flight" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{paths.embedded});
    defer b.deinit();
    errdefer b.failed = true;

    // After the list changes, the listen stream of the bridge is open in the server.
    try initialize(b, arena);

    // The slow call takes one minute when nothing cancels it. Its handler runs on the task of
    // the request in the process. The response of the ping tells that the call started.
    b.watchdog.arm("slow tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow","arguments":{"ms":60000}}}
    );
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    );
    _ = try expectResult(try b.response(arena, 3));

    // One tool asks for a form, and one tool asks for a sampling. VS Code never answers.
    b.watchdog.arm("elicitation", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ask_form"}}
    );
    try expectBridgeId(try b.request(arena, "elicitation/create"), "b-1");
    b.watchdog.arm("sampling", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"sample"}}
    );
    try expectBridgeId(try b.request(arena, "sampling/createMessage"), "b-2");

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop of the embedded server at the end of stdin with requests in flight");
    // The responses of initialize and ping, the list changes, the two requests of the bridge
    // and their cancellations. The canceled calls get no response.
    try testing.expectEqual(@as(usize, 6 + list_changes.len), try expectFrames(arena, b.out.items));
    const frames = try sortFrames(arena, b.out.items);
    try expectStrings(&.{ "b-1", "b-2" }, frames.cancelled);
    try testing.expectEqual(@as(usize, 2), frames.responses.len);
}

test "the embedded server stops at the end of stdin on the modern path with a listen stream and a slow call in flight" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    const b = try Bridge.spawn(gpa, &.{paths.embedded});
    defer b.deinit();
    errdefer b.failed = true;

    // A listen stream of revision 2026-07-28 selects the modern path.
    b.watchdog.arm("subscriptions/listen", exchange_limit);
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":true}," ++ modern_meta ++ "}}");
    _ = try b.notification(arena, "notifications/subscriptions/acknowledged");

    // The slow call takes one minute when nothing cancels it. The response of tools/list tells
    // that the reader took the call. Revision 2026-07-28 has no ping.
    b.watchdog.arm("slow tools/call", exchange_limit);
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"slow\",\"arguments\":{\"ms\":60000}," ++ modern_meta ++ "}}");
    try b.send("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{" ++ modern_meta ++ "}}");
    _ = try expectResult(try b.response(arena, 7));

    // The listen stream ends at once. The slow call gets the grace period, then the server
    // cancels its task.
    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop of the embedded server at the end of stdin on the modern path");
    _ = try expectFrames(arena, b.out.items);
    const frames = try sortModernFrames(arena, b.out.items);
    // The listen stream ends with its result, and the canceled call gets no response.
    const ended = frames.response(5) orelse return fail("the listen stream did not end with a response", .{});
    if (ended != .response) return fail("the listen stream ended with an error", .{});
    if (frames.response(6) != null) return fail("the canceled call got a response", .{});
}

/// The `_meta` member of a request of revision 2026-07-28.
const modern_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"process-test","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}
;

/// The responses of a connection of revision 2026-07-28.
const ModernFrames = struct {
    responses: []const Message,

    /// The response or the error response with the integer id `id`, or null.
    fn response(self: ModernFrames, id: i64) ?Message {
        for (self.responses) |msg| {
            const msg_id: mcp.RequestId = switch (msg) {
                .response => |r| r.id,
                .error_response => |r| r.id orelse continue,
                .request, .notification => continue,
            };
            if (msg_id == .integer and msg_id.integer == id) return msg;
        }
        return null;
    }
};

/// Parse each line of `out`, and keep the responses.
fn sortModernFrames(arena: Allocator, out: []const u8) !ModernFrames {
    var responses: std.ArrayList(Message) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const msg = try parseFrame(arena, line);
        switch (msg) {
            .response, .error_response => try responses.append(arena, msg),
            .notification, .request => {},
        }
    }
    return .{ .responses = responses.items };
}

/// The bearer token of the HTTP upstream server of the tests of the URL form. It is also the
/// marker that must never reach stderr.
const http_token = "process-test-marker-4c2e9a";

/// The environment variable of the bridge with the authorization header.
const http_token_variable = "MCP_BRIDGE_PROCESS_TEST_TOKEN";

test "the URL form: the bridge speaks to an HTTP upstream server with a header from the environment" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    var upstream: HttpUpstream = undefined;
    try upstream.start(gpa);
    defer upstream.stop();
    var environ = try testing.environ.createMap(gpa);
    defer environ.deinit();
    try environ.put(http_token_variable, "Bearer " ++ http_token);

    // The debug lines have each upstream request. They must not have the header value.
    const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "--log-level", "debug", "--header-env", "Authorization=" ++ http_token_variable, upstream.url }, &environ);
    defer b.deinit();
    errdefer b.failed = true;

    // The listen stream goes over HTTP too, thus the list changes come after initialize.
    try initialize(b, arena);
    b.watchdog.arm("tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
    );
    try testing.expectEqualStrings("5", try firstText(try expectResult(try b.response(arena, 2))));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin with an HTTP upstream server");
    try testing.expectEqual(@as(usize, 2 + list_changes.len), try expectFrames(arena, b.out.items));
    try expectStderr(b, "mcp-bridge-vscode: bridge: debug: upstream request ");
    if (std.mem.indexOf(u8, b.err.bytes.items, http_token) != null) return fail("stderr has the value of the authorization header", .{});
}

test "the URL form: a refused request fails alone, and the bridge runs until the end of stdin" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    var upstream: HttpUpstream = undefined;
    try upstream.start(gpa);
    defer upstream.stop();

    // Without the token, the upstream server answers 401. The sign-in of the bridge needs
    // https, thus it fails at once.
    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--token-store", "memory", upstream.url });
    defer b.deinit();
    errdefer b.failed = true;

    b.watchdog.arm("initialize", exchange_limit);
    try b.send(vscode_initialize);
    switch (try b.response(arena, 1)) {
        .error_response => |e| {
            try testing.expectEqual(@as(i64, -32603), e.code);
            const data = e.data orelse return fail("the error has no data", .{});
            try testing.expectEqualStrings("sign_in_failed", mcp.json.getString(data, "cause") orelse "");
            try testing.expectEqualStrings("InsecureEndpoint", mcp.json.getString(data, "detail") orelse "");
        },
        else => return fail("initialize did not fail", .{}),
    }
    // An HTTP upstream server never stops the bridge. It answers until the end of stdin.
    b.watchdog.arm("ping", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    );
    _ = try expectResult(try b.response(arena, 2));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin after a refused request");
    try testing.expectEqual(@as(usize, 2), try expectFrames(arena, b.out.items));
}

test "the URL form signs in: the sign-in line has the URL, the redirect reaches the bridge, a step-up goes through a URL elicitation, and no code reaches stderr" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    var upstream: HttpsUpstream = try .start(arena, paths.fixture, &.{"--oauth"}, null);
    defer upstream.stop();
    const port = try freePort();
    const redirect_uri = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/callback", .{port});
    // The debug lines have each upstream request. They must not have a secret.
    const b = try Bridge.spawn(gpa, &.{ paths.bridge, "--log-level", "debug", "--no-browser", "--token-store", "memory", "--ca-file", fixture.https.ca_file, "--redirect-port", try std.fmt.allocPrint(arena, "{d}", .{port}), upstream.url });
    defer b.deinit();
    errdefer b.failed = true;

    // Before notifications/initialized, the bridge writes the sign-in line. With --no-browser,
    // it opens no browser. The test is the browser of the user: it opens the URL of the line.
    b.watchdog.arm("initialize", exchange_limit);
    try b.send(vscode_initialize);
    const first_url = try waitSignIn(b, arena, 0);
    const first_scope = try expectSignInUrl(arena, first_url, upstream.url, redirect_uri);
    try testing.expect(std.mem.indexOf(u8, first_scope, fixture.https.step_up_scope) == null);
    const first_code = try approveSignIn(b, gpa, arena, first_url);
    const result = try expectResult(try b.response(arena, 1));
    try testing.expectEqualStrings("2025-11-25", mcp.json.getString(result, "protocolVersion") orelse "");
    try b.send(initialized);

    b.watchdog.arm("tools/list", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    const list = try expectResult(try b.response(arena, 2));
    const tools = list.object.get("tools") orelse return fail("tools/list has no tools", .{});
    var names: usize = 0;
    for (tools.array.items) |tool| {
        const name = mcp.json.getString(tool, "name") orelse "";
        if (std.mem.eql(u8, name, "add") or std.mem.eql(u8, name, fixture.guarded_tool)) names += 1;
    }
    try testing.expectEqual(@as(usize, 2), names);

    b.watchdog.arm("tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
    );
    try testing.expectEqualStrings("5", try firstText(try expectResult(try b.response(arena, 3))));

    // After notifications/initialized, the step-up of the tool guarded asks VS Code with a URL
    // elicitation. VS Code shows the URL, the user accepts, and VS Code opens the URL.
    b.watchdog.arm("step-up", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"guarded","arguments":{}}}
    );
    const ask = try b.request(arena, "elicitation/create");
    const params = ask.params orelse return fail("the URL elicitation has no params", .{});
    try testing.expectEqualStrings("url", mcp.json.getString(params, "mode") orelse "");
    const elicitation_id = mcp.json.getString(params, "elicitationId") orelse return fail("the URL elicitation has no elicitationId", .{});
    try testing.expect(elicitation_id.len > 0);
    const second_url = mcp.json.getString(params, "url") orelse return fail("the URL elicitation has no url", .{});
    // The sign-in line comes once for each sign-in, also for a step-up.
    try testing.expectEqualStrings(second_url, try waitSignIn(b, arena, 1));
    const second_scope = try expectSignInUrl(arena, second_url, upstream.url, redirect_uri);
    try testing.expect(std.mem.indexOf(u8, second_scope, fixture.https.step_up_scope) != null);
    const ask_id = switch (ask.id) {
        .string => |s| s,
        else => return fail("the id of the URL elicitation is not a string", .{}),
    };
    try b.send(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"action\":\"accept\"}}}}", .{std.json.fmt(ask_id, .{})}));
    const second_code = try approveSignIn(b, gpa, arena, second_url);
    // The completion of the elicitation comes before the result of the call.
    const notifications, const guarded = try b.responseWithNotifications(arena, 4);
    var completions: usize = 0;
    for (notifications) |n| {
        if (!std.mem.eql(u8, n.method, "notifications/elicitation/complete")) continue;
        try testing.expectEqualStrings(elicitation_id, mcp.json.getString(n.params orelse .null, "elicitationId") orelse "");
        completions += 1;
    }
    try testing.expectEqual(@as(usize, 1), completions);
    try testing.expectEqualStrings(fixture.guarded_text, try firstText(try expectResult(guarded)));

    // The token has the scope now. The next call needs no sign-in, and VS Code gets no request.
    b.watchdog.arm("tools/call guarded", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"guarded","arguments":{}}}
    );
    try testing.expectEqualStrings(fixture.guarded_text, try firstText(try expectResult(try b.response(arena, 5))));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin after a sign-in");
    _ = try expectFrames(arena, b.out.items);
    try expectStderr(b, "the tokens stay in memory (--token-store memory)");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, b.err.bytes.items, sign_in_prefix));
    for ([_][]const u8{ first_code, second_code }) |code| {
        if (std.mem.indexOf(u8, b.err.bytes.items, code) != null) return fail("stderr has the code of a redirect", .{});
    }
    // The only stderr lines are the lines of the bridge: the HTTP upstream server has no
    // stderr in this process.
    try expectTaggedLines(b);
}

/// The length of the token of a start URL: 32 random bytes in base64url without padding.
const start_token_len = std.base64.url_safe_no_pad.Encoder.calcSize(32);

test "the URL form opens the program of BROWSER with only the start URL, and that browser signs in" {
    switch (builtin.os.tag) {
        // On Windows, the opener of the system starts the real browser. The other tests of the
        // URL form use --no-browser.
        .windows, .wasi => return error.SkipZigTest,
        else => {},
    }
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    var upstream: HttpsUpstream = try .start(arena, paths.fixture, &.{"--oauth"}, null);
    defer upstream.stop();
    // The browser of the test: a script that writes its arguments to a file. Then the fixture
    // server opens the first argument, follows each redirect and trusts the test CA.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    for ([_][]const u8{ dir, paths.fixture }) |path| {
        if (std.mem.indexOfScalar(u8, path, '\'') != null) return fail("the path has a quote: {s}", .{path});
    }
    const record = try std.fs.path.join(arena, &.{ dir, "argv.txt" });
    const script = try std.fs.path.join(arena, &.{ dir, "browser.sh" });
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = script,
        .data = try std.fmt.allocPrint(arena, "#!/bin/sh\nprintf '%s\\n' \"$#\" \"$@\" > '{s}'\nexec '{s}' --browse \"$1\"\n", .{ record, paths.fixture }),
    });
    try Io.Dir.cwd().setFilePermissions(testing.io, script, .fromMode(0o700), .{});
    var environ = try bridgeEnviron(gpa);
    defer environ.deinit();
    try environ.put("BROWSER", script);

    const port = try freePort();
    const redirect_uri = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/callback", .{port});
    // No --no-browser: the bridge starts the program of BROWSER.
    const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "--log-level", "debug", "--token-store", "memory", "--ca-file", fixture.https.ca_file, "--redirect-port", try std.fmt.allocPrint(arena, "{d}", .{port}), "--sign-in-timeout", "30", upstream.url }, &environ);
    defer b.deinit();
    errdefer b.failed = true;

    b.watchdog.arm("initialize", exchange_limit);
    try b.send(vscode_initialize);
    // The sign-in line has the authorization URL, for a user whose browser does not open.
    const line_url = try waitSignIn(b, arena, 0);
    _ = try expectSignInUrl(arena, line_url, upstream.url, redirect_uri);
    const result = try expectResult(try b.response(arena, 1));
    try testing.expectEqualStrings("2025-11-25", mcp.json.getString(result, "protocolVersion") orelse "");
    try b.send(initialized);

    b.watchdog.arm("tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
    );
    try testing.expectEqualStrings("5", try firstText(try expectResult(try b.response(arena, 2))));

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin after a sign-in through BROWSER");
    _ = try expectFrames(arena, b.out.items);

    // The program got one argument: the start URL. Other local users can read the arguments
    // of a process, thus the argument has no state and no code challenge.
    const argv = try Io.Dir.cwd().readFileAlloc(testing.io, record, arena, .limited(64 * 1024));
    var lines = std.mem.splitScalar(u8, argv, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "1")) return fail("the program of BROWSER did not get exactly one argument: {s}", .{argv});
    const start_url = lines.next() orelse "";
    if (lines.rest().len != 0) return fail("the program of BROWSER got more than one line: {s}", .{argv});
    const prefix = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/start/", .{port});
    if (!std.mem.startsWith(u8, start_url, prefix)) return fail("the argument is not the start URL on port {d}: {s}", .{ port, start_url });
    const token = start_url[prefix.len..];
    if (token.len != start_token_len) return fail("the token of the start URL has {d} characters, not {d}", .{ token.len, start_token_len });
    for (token) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return fail("the token of the start URL is not base64url: {s}", .{token});
    for ([_][]const u8{ "?", "state=", "code_challenge", "redirect_uri" }) |part| {
        if (std.mem.indexOf(u8, start_url, part) != null) return fail("the start URL has '{s}': {s}", .{ part, start_url });
    }
    // One sign-in, and the browser opened. The fixture server wrote no line, thus each stderr
    // line is a line of the bridge.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, b.err.bytes.items, sign_in_prefix));
    try expectNoStderr(b, "the browser did not open");
    try expectNoStderr(b, "browser opener");
    try expectStderr(b, "the tokens stay in memory (--token-store memory)");
    try expectTaggedLines(b);
}

test "the URL form with a static authorization header from the environment: no sign-in, and the token never reaches stderr" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    // The HTTPS fixture server without an authorization server. It takes only the token of
    // its environment variable.
    var fixture_environ = try testing.environ.createMap(gpa);
    defer fixture_environ.deinit();
    try fixture_environ.put(bearer_variable, http_token);
    var upstream: HttpsUpstream = try .start(arena, paths.fixture, &.{ "--bearer-env", bearer_variable }, &fixture_environ);
    defer upstream.stop();

    var environ = try bridgeEnviron(gpa);
    defer environ.deinit();
    try environ.put(http_token_variable, "Bearer " ++ http_token);
    {
        // The debug lines have each upstream request. They must not have a header value, also
        // not the value of --header on the command line.
        const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "--log-level", "debug", "--header-env", "Authorization=" ++ http_token_variable, "--header", "X-Trace:" ++ header_marker, "--ca-file", fixture.https.ca_file, upstream.url }, &environ);
        defer b.deinit();
        errdefer b.failed = true;

        try initialize(b, arena);
        b.watchdog.arm("tools/list", exchange_limit);
        try b.send(
            \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        );
        const list = try expectResult(try b.response(arena, 2));
        try testing.expect(list.object.get("tools").?.array.items.len > 0);
        b.watchdog.arm("tools/call", exchange_limit);
        try b.send(
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
        );
        try testing.expectEqualStrings("5", try firstText(try expectResult(try b.response(arena, 3))));

        const start = Io.Timestamp.now(b.io, .awake);
        b.closeStdin();
        const exit = try b.finish(start);
        try expectExit(exit, 0);
        try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin with a static authorization header");
        try testing.expectEqual(@as(usize, 3 + list_changes.len), try expectFrames(arena, b.out.items));
        try expectStderr(b, "mcp-bridge-vscode: bridge: debug: upstream request ");
        // A static authorization header excludes the sign-in, thus no token store opens.
        try expectNoStderr(b, sign_in_prefix);
        try expectNoStderr(b, "the tokens ");
        try expectNoStderr(b, http_token);
        try expectNoStderr(b, header_marker);
        try expectTaggedLines(b);
    }

    // A wrong token: initialize fails with the HTTP status, and the bridge does not sign in.
    // It answers the next requests until the end of stdin.
    try environ.put(http_token_variable, "Bearer " ++ wrong_token);
    {
        const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "--log-level", "debug", "--header-env", "Authorization=" ++ http_token_variable, "--ca-file", fixture.https.ca_file, upstream.url }, &environ);
        defer b.deinit();
        errdefer b.failed = true;

        b.watchdog.arm("initialize", exchange_limit);
        try b.send(vscode_initialize);
        switch (try b.response(arena, 1)) {
            .error_response => |e| {
                try testing.expectEqual(@as(i64, -32603), e.code);
                const detail = mcp.json.getString(e.data orelse .null, "detail") orelse "";
                if (std.mem.indexOf(u8, detail, "HTTP status 401") == null) return fail("the error does not name the HTTP status 401: {s}", .{detail});
            },
            else => return fail("initialize did not fail", .{}),
        }
        b.watchdog.arm("ping", exchange_limit);
        try b.send(
            \\{"jsonrpc":"2.0","id":2,"method":"ping"}
        );
        _ = try expectResult(try b.response(arena, 2));

        const start = Io.Timestamp.now(b.io, .awake);
        b.closeStdin();
        const exit = try b.finish(start);
        try expectExit(exit, 0);
        try testing.expectEqual(@as(usize, 2), try expectFrames(arena, b.out.items));
        try expectNoStderr(b, sign_in_prefix);
        try expectNoStderr(b, wrong_token);
    }
}

/// The environment variable of the HTTPS fixture server with the static token.
const bearer_variable = "BRIDGE_FIXTURE_PROCESS_TEST_TOKEN";

/// The value of a `--header` on the command line. It is a marker that must never reach
/// stderr.
const header_marker = "process-test-marker-header-2e8b";

/// A token that the HTTPS fixture server refuses. It is also a marker that must never reach
/// stderr.
const wrong_token = "process-test-marker-wrong-81d0";

test "the options of the URL form that do not go together give exit code 2, no stdout and no value on stderr" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);
    const url = "https://127.0.0.1:9/mcp";
    const marker = "process-test-marker-3b7f";

    var environ = try bridgeEnviron(gpa);
    defer environ.deinit();
    // A token store that opens uses the temporary directory, never the directory of the user.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try environ.put(if (builtin.os.tag == .windows) "LOCALAPPDATA" else "XDG_STATE_HOME", try tmp.dir.realPathFileAlloc(testing.io, ".", arena));
    // The values of these variables are secrets. No diagnostic has them.
    try environ.put(http_token_variable, "Bearer " ++ marker);
    try environ.put(bridge_client_secret_variable, marker);
    const Case = struct {
        args: []const []const u8,
        /// A key of the file store that is not valid, in `MCP_BRIDGE_TOKEN_KEY`, or null.
        token_key: ?[]const u8 = null,
    };
    const cases = [_]Case{
        // The executable has no switch that turns off a check of the sign-in (P10).
        .{ .args = &.{ "--allow-http", "http://127.0.0.1:9/mcp" } },
        .{ .args = &.{ "--insecure", url } },
        .{ .args = &.{ "--headless", url } },
        // A secret never comes from the command line.
        .{ .args = &.{ "--client-secret=" ++ marker, "--client-id", "c1", url } },
        .{ .args = &.{ "--token-key=" ++ marker, url } },
        // A static authorization header and the sign-in options exclude each other.
        .{ .args = &.{ "--header", "Authorization:Bearer " ++ marker, "--client-id", "c1", url } },
        .{ .args = &.{ "--header-env", "Authorization=" ++ http_token_variable, "--no-browser", url } },
        .{ .args = &.{ "--header-env", "authorization=" ++ http_token_variable, "--token-store", "memory", url } },
        // The registration options.
        .{ .args = &.{ "--client-issuer", "https://as.example", url } },
        .{ .args = &.{ "--client-id", "c1", "--client-metadata-url", "https://client.example/c.json", url } },
        .{ .args = &.{ "--client-metadata-url", "http://client.example/c.json", url } },
        .{ .args = &.{ "--client-issuer", "http://as.example", "--client-id", "c1", url } },
        // A client with a secret in the environment needs --client-issuer.
        .{ .args = &.{ "--client-id", "c1", url } },
        // The token store.
        .{ .args = &.{ "--token-store", "memory", "--token-key-file", "key.txt", url } },
        .{ .args = &.{ "--token-store", "keychain", "--token-key-file", "key.txt", url } },
        .{ .args = &.{ "--token-store", "file", url } },
        .{ .args = &.{ "--token-store", "vault", url } },
        .{ .args = &.{ "--token-key-file", "key.txt", url }, .token_key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" },
        .{ .args = &.{url}, .token_key = marker },
        .{ .args = &.{ "--token-store", "file", "--token-key-file", "test/fixtures/no-such-key.txt", url } },
        // The values of the options.
        .{ .args = &.{ "--redirect-port", "0", url } },
        .{ .args = &.{ "--redirect-port", "65536", url } },
        .{ .args = &.{ "--account", "a|b", url } },
        .{ .args = &.{ "--sign-in-timeout", "0", url } },
        .{ .args = &.{ "--max-response-bytes", "0", url } },
        // A file without a certificate.
        .{ .args = &.{ "--ca-file", "test/fixtures/tls/README.md", url } },
        // The headers.
        .{ .args = &.{ "--header", "mcp-protocol-version:2025-11-25", url } },
        .{ .args = &.{ "--header-env", "Content-Type=" ++ http_token_variable, url } },
        .{ .args = &.{ "--header", "x-a:1", "--header", "X-A:2", url } },
        .{ .args = &.{ "--header", "x-a:" ++ marker, "--header-env", "X-A=" ++ http_token_variable, url } },
        .{ .args = &.{ "--header-env", "x-api-key=MCP_BRIDGE_PROCESS_TEST_NOT_SET", url } },
        // The credential of a proxy goes in the proxy URL, never to the upstream server.
        .{ .args = &.{ "--header", "Proxy-Authorization:Basic " ++ marker, url } },
        .{ .args = &.{ "--header-env", "Proxy-Authorization=" ++ http_token_variable, url } },
        // The URL.
        .{ .args = &.{"https://user:" ++ marker ++ "@127.0.0.1:9/mcp"} },
        .{ .args = &.{"https://127.0.0.1:9/mcp#" ++ marker} },
        .{ .args = &.{"https://127.0.0.1:0/mcp"} },
        .{ .args = &.{"ftp://127.0.0.1:9/mcp"} },
        .{ .args = &.{ url, "--no-browser" } },
        // An option of the URL form with an upstream command.
        .{ .args = &.{ "--redirect-port", "41900", "--", paths.fixture } },
        .{ .args = &.{ "--no-browser", "--", paths.fixture } },
        .{ .args = &.{ "--ca-file", fixture.https.ca_file, "--", paths.fixture } },
        // logout.
        .{ .args = &.{ "logout", "--all", "--account", "work" } },
        .{ .args = &.{ "logout", "--all", url } },
        .{ .args = &.{ "logout", "--no-browser", url } },
        .{ .args = &.{ "logout", "--header", "x-a:1", url } },
        .{ .args = &.{ "logout", "--", paths.fixture } },
    };
    for (cases) |case| {
        if (case.token_key) |key| try environ.put(bridge_token_key_variable, key) else _ = environ.swapRemove(bridge_token_key_variable);
        const argv = try std.mem.concat(arena, []const u8, &.{ &.{paths.bridge}, case.args });
        const b = try Bridge.spawnWith(gpa, argv, &environ);
        defer b.deinit();
        errdefer {
            b.failed = true;
            std.debug.print("process test: the arguments were {f}\n", .{std.json.fmt(case.args, .{})});
        }
        const start = Io.Timestamp.now(b.io, .awake);
        b.closeStdin();
        const exit = try b.finish(start);
        try expectExit(exit, 2);
        try testing.expectEqualStrings("", b.out.items);
        try expectStderr(b, "mcp-bridge-vscode: vscode: error: ");
        try expectNoStderr(b, marker);
    }
}

/// The environment variables of the bridge for its secrets.
const bridge_token_key_variable = "MCP_BRIDGE_TOKEN_KEY";
const bridge_client_secret_variable = "MCP_BRIDGE_CLIENT_SECRET";

/// The environment of the test without the secret variables of the bridge, and without a
/// proxy, for the bridge of a test. The caller releases it.
fn bridgeEnviron(gpa: Allocator) !std.process.Environ.Map {
    var environ = try testing.environ.createMap(gpa);
    errdefer environ.deinit();
    for ([_][]const u8{ bridge_token_key_variable, bridge_client_secret_variable, "SANDBOX_RUNTIME", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" }) |name| {
        _ = environ.swapRemove(name);
    }
    return environ;
}

test "the file store keeps the sign-in for the next start, and logout deletes it" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);

    var upstream: HttpsUpstream = try .start(arena, paths.fixture, &.{"--oauth"}, null);
    defer upstream.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const state = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    var environ = try testing.environ.createMap(gpa);
    defer environ.deinit();
    // The token directory is in the temporary directory, and the key is a test value.
    try environ.put(if (builtin.os.tag == .windows) "LOCALAPPDATA" else "XDG_STATE_HOME", state);
    try environ.put("MCP_BRIDGE_TOKEN_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    const port = try std.fmt.allocPrint(arena, "{d}", .{try freePort()});
    const serve_argv: []const []const u8 = &.{ paths.bridge, "--no-browser", "--token-store", "file", "--ca-file", fixture.https.ca_file, "--redirect-port", port, upstream.url };

    // The first start signs in, and the second start uses the stored sign-in.
    for ([_]bool{ true, false }) |sign_in| try serveOnce(gpa, arena, serve_argv, &environ, sign_in);

    {
        const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "logout", "--token-store", "file", "--ca-file", fixture.https.ca_file, "--redirect-port", port, upstream.url }, &environ);
        defer b.deinit();
        errdefer b.failed = true;
        const start = Io.Timestamp.now(b.io, .awake);
        b.closeStdin();
        const exit = try b.finish(start);
        try expectExit(exit, 0);
        try expectStderr(b, "logout deleted the stored sign-in of the account \"default\"");
        try testing.expectEqual(@as(usize, 0), b.out.items.len);
    }

    // After logout, the next start signs in again.
    try serveOnce(gpa, arena, serve_argv, &environ, true);
}

test "in the sandbox of VS Code, initialize fails at once with a message that names the sandbox" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);
    var environ = try testing.environ.createMap(gpa);
    defer environ.deinit();
    try environ.put("SANDBOX_RUNTIME", "1");
    // The bridge makes no connection, thus the port is closed.
    const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "--token-store", "memory", "https://127.0.0.1:9/mcp" }, &environ);
    defer b.deinit();
    errdefer b.failed = true;
    b.watchdog.arm("initialize", exchange_limit);
    try b.send(vscode_initialize);
    switch (try b.response(arena, 1)) {
        .error_response => |e| {
            try testing.expectEqual(@as(i64, -32603), e.code);
            try testing.expect(std.mem.indexOf(u8, e.message, "sandbox") != null);
            try testing.expectEqualStrings("sandbox", mcp.json.getString(e.data orelse .null, "cause") orelse "");
        },
        else => return fail("initialize did not fail", .{}),
    }
    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, b.err.bytes.items, "sign in at"));
}

test "the end of stdin while the sign-in waits for the browser stops the bridge with code 0 inside the limit, 20 times on one redirect port" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);
    var upstream: HttpsUpstream = try .start(arena, paths.fixture, &.{"--oauth"}, null);
    defer upstream.stop();
    var environ = try bridgeEnviron(gpa);
    defer environ.deinit();
    // The same port in each loop: each exit must release the port of the receiver. A port
    // that stays in use makes the next sign-in fail without a sign-in line.
    const port = try std.fmt.allocPrint(arena, "{d}", .{try freePort()});
    for (0..20) |_| {
        const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "--no-browser", "--token-store", "memory", "--ca-file", fixture.https.ca_file, "--redirect-port", port, upstream.url }, &environ);
        defer b.deinit();
        errdefer b.failed = true;
        b.watchdog.arm("initialize", exchange_limit);
        try b.send(vscode_initialize);
        // The receiver listens before the bridge writes the sign-in line.
        _ = try waitSignIn(b, arena, 0);
        const start = Io.Timestamp.now(b.io, .awake);
        b.closeStdin();
        const exit = try b.finish(start);
        try expectExit(exit, 0);
        try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin during a sign-in");
        // A stopped initialize gets no response.
        try testing.expectEqualStrings("", b.out.items);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, b.err.bytes.items, sign_in_prefix));
        try expectTaggedLines(b);
    }
}

test "the URL form: a key in the query of the URL never reaches stderr or an error, also after a step-up that did not complete in time" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);
    var upstream: HttpsUpstream = try .start(arena, paths.fixture, &.{"--oauth"}, null);
    defer upstream.stop();
    var environ = try bridgeEnviron(gpa);
    defer environ.deinit();
    // Some remote servers take a key in the query or the path of their URL.
    const marker = "process-test-marker-query-6a1d";
    const url = try std.fmt.allocPrint(arena, "{s}?key={s}", .{ upstream.url, marker });
    const port = try std.fmt.allocPrint(arena, "{d}", .{try freePort()});
    const b = try Bridge.spawnWith(gpa, &.{ paths.bridge, "--log-level", "debug", "--no-browser", "--token-store", "memory", "--ca-file", fixture.https.ca_file, "--redirect-port", port, "--sign-in-timeout", "5", url }, &environ);
    defer b.deinit();
    errdefer b.failed = true;

    b.watchdog.arm("initialize", exchange_limit);
    try b.send(vscode_initialize);
    _ = try approveSignIn(b, gpa, arena, try waitSignIn(b, arena, 0));
    _ = try expectResult(try b.response(arena, 1));
    try b.send(initialized);

    // The step-up of the tool guarded: VS Code accepts the URL elicitation, but the user does
    // not complete the sign-in in the browser.
    b.watchdog.arm("step-up", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"guarded","arguments":{}}}
    );
    const ask = try b.request(arena, "elicitation/create");
    const ask_id = switch (ask.id) {
        .string => |text| text,
        else => return fail("the id of the URL elicitation is not a string", .{}),
    };
    try b.send(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"action\":\"accept\"}}}}", .{std.json.fmt(ask_id, .{})}));
    switch (try b.response(arena, 2)) {
        .error_response => |e| {
            try testing.expectEqual(@as(i64, -32603), e.code);
            try testing.expectEqualStrings("sign_in_timeout", mcp.json.getString(e.data orelse .null, "cause") orelse "");
            if (std.mem.indexOf(u8, e.message, marker) != null) return fail("the error message has the key of the URL: {s}", .{e.message});
            if (std.mem.indexOf(u8, e.message, upstream.url) != null) return fail("the error message has the URL of the upstream server: {s}", .{e.message});
        },
        else => return fail("the step-up did not fail", .{}),
    }

    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectWithin(exit.elapsed, exit_bound, "the stop at the end of stdin after a step-up that did not complete");
    _ = try expectFrames(arena, b.out.items);
    try expectStderr(b, "The sign-in did not complete in 5 s.");
    try expectNoStderr(b, marker);
    try expectTaggedLines(b);
}

test "logout of the memory store and logout --all of an empty file store exit with code 0" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = try Paths.get(arena);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var environ = try testing.environ.createMap(gpa);
    defer environ.deinit();
    // The token directory is in the temporary directory. The tests never use the keychain of
    // the host: a logout there could delete the stored sign-ins of the user.
    try environ.put(if (builtin.os.tag == .windows) "LOCALAPPDATA" else "XDG_STATE_HOME", try tmp.dir.realPathFileAlloc(testing.io, ".", arena));
    try environ.put("MCP_BRIDGE_TOKEN_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    const cases = [_]struct { argv: []const []const u8, texts: []const []const u8 }{
        .{ .argv = &.{ paths.bridge, "logout", "--token-store", "memory", "https://127.0.0.1:9/mcp" }, .texts = &.{"logout has nothing to delete"} },
        .{ .argv = &.{ paths.bridge, "logout", "--all", "--token-store", "file" }, .texts = &.{ "logout deleted 0 stored sign-ins", "deleted the token directory " } },
    };
    for (cases) |case| {
        const b = try Bridge.spawnWith(gpa, case.argv, &environ);
        defer b.deinit();
        errdefer b.failed = true;
        const start = Io.Timestamp.now(b.io, .awake);
        b.closeStdin();
        const exit = try b.finish(start);
        try expectExit(exit, 0);
        for (case.texts) |text| try expectStderr(b, text);
        try testing.expectEqual(@as(usize, 0), b.out.items.len);
    }
}

/// Start the bridge with `argv` and `environ`, and initialize it. Sign in when `sign_in` is
/// true. Then call a tool, and stop the bridge at the end of stdin. Without `sign_in`, stderr
/// must have no sign-in line.
fn serveOnce(gpa: Allocator, arena: Allocator, argv: []const []const u8, environ: *const std.process.Environ.Map, sign_in: bool) !void {
    const b = try Bridge.spawnWith(gpa, argv, environ);
    defer b.deinit();
    errdefer b.failed = true;
    b.watchdog.arm("initialize", exchange_limit);
    try b.send(vscode_initialize);
    if (sign_in) _ = try approveSignIn(b, gpa, arena, try waitSignIn(b, arena, 0));
    _ = try expectResult(try b.response(arena, 1));
    b.watchdog.arm("tools/call", exchange_limit);
    try b.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
    );
    try testing.expectEqualStrings("5", try firstText(try expectResult(try b.response(arena, 2))));
    const start = Io.Timestamp.now(b.io, .awake);
    b.closeStdin();
    const exit = try b.finish(start);
    try expectExit(exit, 0);
    try expectStderr(b, "the tokens are in encrypted files in ");
    const lines = std.mem.count(u8, b.err.bytes.items, "mcp-bridge-vscode: sign in at ");
    try testing.expectEqual(@as(usize, if (sign_in) 1 else 0), lines);
}

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/// The Streamable HTTP server of zig-sdk with the fixture server, on a loopback port, for the
/// URL form of the bridge. Each request needs the bearer token `http_token`. The value must
/// stay at its address between `start` and `stop`.
const HttpUpstream = struct {
    server: *mcp.Server,
    transport: mcp.transport.http.Server,
    resource: mcp.auth.ResourceServer,
    future: Io.Future(void),
    url_buf: [64]u8,
    url: []const u8,

    fn start(self: *HttpUpstream, gpa: Allocator) !void {
        const io = testing.io;
        self.server = try fixture.build(gpa, io, .{});
        errdefer fixture.destroy(self.server);
        self.transport = .init(io, gpa, self.server, .{ .port = 0, .auth = &self.resource });
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
        _ = ptr;
        _ = arena;
        if (!std.mem.eql(u8, token, http_token)) return error.InvalidToken;
        return .{ .subject = "process-test" };
    }

    fn stop(self: *HttpUpstream) void {
        fixture.https.endAccept(testing.io, &self.transport);
        self.transport.shutdown();
        self.future.await(testing.io);
        self.transport.deinit();
        fixture.destroy(self.server);
    }
};

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

/// The paths of the three executables.
const Paths = struct {
    bridge: []const u8,
    fixture: []const u8,
    embedded: []const u8,

    fn get(arena: Allocator) !Paths {
        return .{
            .bridge = try executable(arena, "PROCESS_TEST_BRIDGE", process_options.bridge_exe),
            .fixture = try executable(arena, "PROCESS_TEST_FIXTURE", process_options.fixture_exe),
            .embedded = try executable(arena, "PROCESS_TEST_EMBEDDED", process_options.embedded_exe),
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
        return spawnWith(gpa, argv, null);
    }

    /// Same as `spawn`, with the environment `environ`. Null gives the environment of the
    /// test.
    fn spawnWith(gpa: Allocator, argv: []const []const u8, environ: ?*const std.process.Environ.Map) !*Bridge {
        const io = testing.io;
        const self = try gpa.create(Bridge);
        errdefer gpa.destroy(self);
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
            .environ_map = environ,
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

    /// Read stdout until the response with `id`. Each line must be one JSON-RPC message.
    /// Returns the notifications before the response, and the response. Each other message
    /// is an error.
    fn responseWithNotifications(self: *Bridge, arena: Allocator, id: i64) !struct { []const Message.Notification, Message } {
        var notifications: std.ArrayList(Message.Notification) = .empty;
        while (true) {
            const line = try self.nextLine(arena);
            const msg = try parseFrame(arena, line);
            const msg_id: ?mcp.RequestId = switch (msg) {
                .notification => |n| {
                    try notifications.append(arena, n);
                    continue;
                },
                .request => null,
                .response => |r| r.id,
                .error_response => |r| r.id,
            };
            if (msg_id) |i| if (i == .integer and i.integer == id) return .{ notifications.items, msg };
            return fail("the bridge sent a message that is not the response {d}: {s}", .{ id, line });
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
    /// Guarded by `lock` until `eof`.
    bytes: std.ArrayList(u8) = .empty,
    lock: Io.Mutex = .init,
    /// True after the end of stderr. The task does not change `bytes` after this.
    eof: std.atomic.Value(bool) = .init(false),

    fn run(self: *Drain, io: Io) void {
        defer self.eof.store(true, .release);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.file.readStreaming(io, &.{&buf}) catch return;
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            if (self.bytes.items.len < max_captured_stderr) self.bytes.appendSlice(self.gpa, buf[0..n]) catch {};
        }
    }

    /// The rest of the complete line number `index` (from 0) of the lines that start with
    /// `prefix`, in `arena`, or null. Another task can call it while stderr is open.
    fn lineAfter(self: *Drain, io: Io, arena: Allocator, prefix: []const u8, index: usize) Allocator.Error!?[]const u8 {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        var lines = std.mem.splitScalar(u8, self.bytes.items, '\n');
        var found: usize = 0;
        while (lines.next()) |line| {
            // The last part has no line end yet.
            if (lines.peek() == null) return null;
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            if (found == index) return try arena.dupe(u8, std.mem.trimEnd(u8, line[prefix.len..], "\r"));
            found += 1;
        }
        return null;
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

/// Check that stderr of the bridge does not have `text`. Call this after `Bridge.finish`.
fn expectNoStderr(b: *Bridge, text: []const u8) !void {
    if (std.mem.indexOf(u8, b.err.bytes.items, text) == null) return;
    return fail("stderr has the text '{s}'", .{text});
}

/// Check that each line on stderr is a complete line of the bridge with its tag. Use it when
/// no child process writes to the same stderr. Call this after `Bridge.finish`.
fn expectTaggedLines(b: *Bridge) !void {
    const err = b.err.bytes.items;
    if (err.len == 0) return;
    if (err[err.len - 1] != '\n') return fail("stderr ends with a part of a line", .{});
    var lines = std.mem.splitScalar(u8, err[0..err.len -| 1], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "mcp-bridge-vscode: ")) return fail("a stderr line without the tag of the bridge: {s}", .{line});
    }
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

/// The HTTPS fixture server in its own process: `--https 0` and the options `options`, for
/// example `--oauth`. `environ` is its environment. Null gives the environment of the test. The
/// server stops at the end of its stdin.
const HttpsUpstream = struct {
    child: std.process.Child,
    /// The URL of the MCP endpoint, in the arena of `start`.
    url: []const u8,

    fn start(arena: Allocator, path: []const u8, options: []const []const u8, environ: ?*const std.process.Environ.Map) !HttpsUpstream {
        const io = testing.io;
        var child = try std.process.spawn(io, .{
            .argv = try std.mem.concat(arena, []const u8, &.{ &.{ path, "--https", "0" }, options }),
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .create_no_window = true,
            .environ_map = environ,
        });
        errdefer child.kill(io);
        // The timer stops the fixture when it does not write its URL in time. The stop closes
        // its stdout, and that ends the read.
        var timer: KillTimer = .{ .io = io, .target = child.id.?, .limit = fixture_limit };
        try timer.start();
        var line: std.ArrayList(u8) = .empty;
        var buf: [256]u8 = undefined;
        while (std.mem.indexOfScalar(u8, line.items, '\n') == null) {
            const n = child.stdout.?.readStreaming(io, &.{&buf}) catch |err| {
                if (timer.stop()) return fail("the HTTPS fixture server did not write its URL in {d} s", .{fixture_limit.toSeconds()});
                return err;
            };
            line.appendSlice(arena, buf[0..n]) catch |err| {
                _ = timer.stop();
                return err;
            };
        }
        if (timer.stop()) return fail("the HTTPS fixture server did not write its URL in {d} s", .{fixture_limit.toSeconds()});
        const nl = std.mem.indexOfScalar(u8, line.items, '\n').?;
        return .{ .child = child, .url = std.mem.trimEnd(u8, line.items[0..nl], "\r") };
    }

    /// Close stdin of the fixture and wait for its exit. The timer stops a fixture that does
    /// not stop in time, and the function writes that.
    fn stop(self: *HttpsUpstream) void {
        const io = testing.io;
        if (self.child.stdin) |f| f.close(io);
        self.child.stdin = null;
        var timer: KillTimer = .{ .io = io, .target = self.child.id.?, .limit = fixture_limit };
        timer.start() catch {
            self.child.kill(io);
            return;
        };
        _ = self.child.wait(io) catch self.child.kill(io);
        if (timer.stop()) std.debug.print("process test: the HTTPS fixture server did not stop in {d} s at the end of its stdin\n", .{fixture_limit.toSeconds()});
    }
};

/// The time limit of the start and of the stop of the HTTPS fixture server.
const fixture_limit: Io.Duration = .fromSeconds(15);

/// A thread that stops a process when a phase does not end in `limit`. A stop of the process
/// closes its pipes, thus each blocked read of the test ends.
const KillTimer = struct {
    io: Io,
    target: std.process.Child.Id,
    limit: Io.Duration,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *KillTimer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// End the timer. Returns true when the timer stopped the process.
    fn stop(self: *KillTimer) bool {
        self.done.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        return self.fired.load(.acquire);
    }

    fn run(self: *KillTimer) void {
        const deadline = Io.Timestamp.now(self.io, .awake).addDuration(self.limit);
        while (!self.done.load(.acquire)) {
            if (Io.Timestamp.now(self.io, .awake).nanoseconds >= deadline.nanoseconds) {
                self.fired.store(true, .release);
                Watchdog.killProcess(self.target);
                return;
            }
            self.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }
};

/// A free port on 127.0.0.1 for the redirect URI of one test.
fn freePort() !u16 {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(testing.io, .{});
    defer listener.deinit(testing.io);
    return listener.socket.address.getPort();
}

/// The prefix of the sign-in line of the bridge on stderr.
const sign_in_prefix = "mcp-bridge-vscode: sign in at ";

/// Wait for the sign-in line number `index` (from 0) on stderr, and return its URL in `arena`.
fn waitSignIn(b: *Bridge, arena: Allocator, index: usize) ![]const u8 {
    const deadline = Io.Timestamp.now(b.io, .awake).addDuration(exchange_limit);
    while (true) {
        if (try b.err.lineAfter(b.io, arena, sign_in_prefix, index)) |url| return url;
        if (b.err.eof.load(.acquire)) return fail("stderr ended without the sign-in line {d}", .{index + 1});
        if (Io.Timestamp.now(b.io, .awake).nanoseconds >= deadline.nanoseconds) return fail("no sign-in line {d} in {d} s", .{ index + 1, exchange_limit.toSeconds() });
        try b.io.sleep(.fromMilliseconds(10), .awake);
    }
}

/// Open the URL of a sign-in as the browser of the user, and return the code of the redirect
/// to the bridge. The authorization server of the fixture approves each request.
fn approveSignIn(b: *Bridge, gpa: Allocator, arena: Allocator, url: []const u8) ![]const u8 {
    const visit = try fixture.https.browse(b.io, gpa, arena, url, .{});
    if (visit.status != 200) return fail("the redirect of the sign-in gave the status {d}: {s}", .{ visit.status, visit.url });
    return (try mcp.auth.common.parseQuery(arena, visit.url)).get("code") orelse return fail("the redirect has no code: {s}", .{visit.url});
}

/// Check the URL of a sign-in as the bridge must give it (P1). The URL uses https and has
/// visible ASCII characters only. It is at the origin of `upstream_url`, because the
/// authorization server of the fixture has the origin of the upstream server. Its parameters
/// start an authorization code flow with PKCE for the resource `upstream_url`, with the
/// redirect URI `redirect_uri`. Returns the scopes.
fn expectSignInUrl(arena: Allocator, url: []const u8, upstream_url: []const u8, redirect_uri: []const u8) ![]const u8 {
    const origin = originOf(upstream_url);
    if (!std.mem.startsWith(u8, origin, "https://")) return fail("the upstream URL does not use https: {s}", .{upstream_url});
    if (!std.mem.startsWith(u8, url, origin) or url.len == origin.len or url[origin.len] != '/') return fail("the sign-in URL is not at the origin {s}: {s}", .{ origin, url });
    for (url) |c| if (c < 0x21 or c > 0x7e) return fail("the sign-in URL has a character that is not visible ASCII: {s}", .{url});
    if (std.mem.indexOfScalar(u8, url, '#') != null) return fail("the sign-in URL has a fragment: {s}", .{url});
    const query = try mcp.auth.common.parseQuery(arena, url);
    const expected = [_][2][]const u8{
        .{ "response_type", "code" },
        .{ "code_challenge_method", "S256" },
        .{ "redirect_uri", redirect_uri },
        .{ "resource", upstream_url },
    };
    for (expected) |e| {
        const value: []const u8 = query.get(e[0]) orelse "";
        if (!std.mem.eql(u8, value, e[1])) return fail("the parameter {s} of the sign-in URL is '{s}', not '{s}'", .{ e[0], value, e[1] });
    }
    for ([_][]const u8{ "client_id", "state", "code_challenge" }) |name| {
        const value: []const u8 = query.get(name) orelse "";
        if (value.len == 0) return fail("the sign-in URL has no {s}: {s}", .{ name, url });
    }
    return query.get("scope") orelse "";
}

/// The origin `https://host:port` of `url`.
fn originOf(url: []const u8) []const u8 {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    const path = std.mem.indexOfScalarPos(u8, url, scheme_end, '/') orelse url.len;
    return url[0..path];
}
