//! The transcripts of the lifecycle: `initialize`, the requests before `initialize`, the
//! failures of `server/discover` and the sequence of the Copilot harness.
const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");
const vscode = @import("vscode");
const fixture = @import("fixture");
const h = @import("harness.zig");

const Value = std.json.Value;
const Frontend = vscode.bridge.Frontend;
const Transcript = h.Transcript;
const testing = std.testing;

/// A command that exits at once and writes nothing.
const exit_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/d", "/c", "exit 3" }
else
    &.{ "/bin/sh", "-c", "exit 3" };

/// A command that reads its input until the end and writes nothing.
const silent_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/d", "/c", "sort > NUL" }
else
    &.{ "/bin/sh", "-c", "cat > /dev/null" };

const not_initialized_message = "The client did not initialize the connection. Send initialize first.";
const already_initialized_message = "The client already sent initialize on this connection.";
const method_not_found_message = "The server does not have this method.";

test "the initialize of VS Code gives the result that VS Code needs" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    const result = try t.initialize();

    // VS Code ignores the version, but the bridge replies with its own revision.
    try testing.expectEqualStrings("2025-11-25", result.object.get("protocolVersion").?.string);
    const caps = result.object.get("capabilities").?;
    // Without `tools`, VS Code never sends tools/list.
    const tools = caps.object.get("tools") orelse return error.TestNoToolsCapability;
    try testing.expect(tools == .object);
    // The bridge sends the list changes, the resource updates and the log messages of the
    // upstream server to VS Code. Thus it declares them as the upstream server does.
    try testing.expect(tools.object.get("listChanged").?.bool);
    try testing.expect(caps.object.get("prompts").?.object.get("listChanged").?.bool);
    const resources = caps.object.get("resources").?;
    try testing.expect(resources.object.get("listChanged").?.bool);
    try testing.expect(resources.object.get("subscribe").?.bool);
    try testing.expect(caps.object.get("logging") != null);
    try testing.expect(caps.object.get("completions") != null);
    try testing.expect(caps.object.get("tasks") == null);
    const extensions = caps.object.get("extensions").?;
    try testing.expect(extensions.object.get(mcp.apps.extension_id) != null);
    try testing.expect(extensions.object.get(mcp.tasks.extension_id) == null);
    // The server information of the upstream server.
    const info = result.object.get("serverInfo").?;
    try testing.expectEqualStrings(fixture.server_name, info.object.get("name").?.string);
    try testing.expectEqualStrings("0.0.0", info.object.get("version").?.string);
    try testing.expectEqualStrings("The upstream server of the zig-bridge-sdk tests.", result.object.get("instructions").?.string);
    for ([_][]const u8{ "resultType", "ttlMs", "cacheScope", "supportedVersions", "_meta" }) |key| {
        try testing.expect(result.object.get(key) == null);
    }

    // The upstream client has the client information of VS Code. It declares the input kinds
    // of VS Code: the two elicitation modes, sampling without tools and roots. It never
    // declares the Tasks extension. The MCP Apps extension goes upstream.
    const client = try t.upstreamClient();
    try testing.expectEqualStrings("Visual Studio Code", client.options.info.name);
    try testing.expectEqualStrings("1.140.0", client.options.info.version);
    const upstream_caps = client.options.capabilities;
    try testing.expect(upstream_caps.hasElicitation(.form));
    try testing.expect(upstream_caps.hasElicitation(.url));
    try testing.expect(upstream_caps.sampling.?.tools == null);
    try testing.expect(upstream_caps.sampling.?.context == null);
    try testing.expect(upstream_caps.roots != null);
    try testing.expect(upstream_caps.hasExtension(mcp.apps.extension_id));
    try testing.expect(!upstream_caps.hasExtension(mcp.tasks.extension_id));

    // After `notifications/initialized`, the bridge opens one listen stream for the three
    // lists. After its acknowledgment, VS Code gets one list change for each list. Thus a
    // change before the first tools/list of VS Code is not lost.
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    const listen = (try t.tap.listenRequest(t.arena(), 0)).object.get("params").?.object.get("notifications").?;
    try testing.expectEqual(@as(usize, 3), listen.object.count());
    const frames = try t.parsedFrames();
    try testing.expectEqual(@as(usize, 4), frames.len);
    for (frames[1..], [_][]const u8{ "notifications/tools/list_changed", "notifications/prompts/list_changed", "notifications/resources/list_changed" }) |frame, method| {
        try testing.expectEqualStrings(method, mcp.json.getString(frame, "method").?);
        try testing.expect(frame.object.get("params") == null);
    }

    // The first request of VS Code after `notifications/initialized`.
    const tap = try t.tapUpstream();
    const list = try h.expectResult(try t.request(2, "tools/list", "{}"));
    try testing.expect(list.object.get("nextCursor") == null);
    // The upstream server knows the MCP Apps extension of VS Code, thus the tool has its view.
    var found = false;
    for (list.object.get("tools").?.array.items) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, "show")) continue;
        const ui = tool.object.get("_meta").?.object.get("ui").?;
        try testing.expectEqualStrings(h.app_view_uri, ui.object.get("resourceUri").?.string);
        found = true;
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 1), tap.count());
    try t.verify();
}

test "before initialize, the bridge answers ping and setLevel, and refuses other requests" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());

    _ = try h.expectResult(try t.requestInline(101, "ping", null));
    _ = try h.expectResult(try t.requestInline(102, "logging/setLevel", "{\"level\":\"debug\"}"));
    try testing.expectEqual(mcp.types.LoggingLevel.debug, t.frontend.clientLogLevel().?);
    // A notification gets no answer, also before `initialize`.
    const before = t.count();
    try t.send(h.initialized);
    try testing.expectEqual(before, t.count());

    // Each other request gets -32600 at once, also a method that the bridge does not know.
    try h.expectError(try t.requestInline(103, "tools/list", "{}"), -32600, not_initialized_message, "not_initialized");
    try h.expectError(try t.requestInline(104, "tools/call", "{\"name\":\"echo\",\"arguments\":{\"text\":\"a\"}}"), -32600, not_initialized_message, "not_initialized");
    try h.expectError(try t.requestInline(105, "resources/subscribe", "{\"uri\":\"file:///x\"}"), -32600, not_initialized_message, "not_initialized");
    try h.expectError(try t.requestInline(106, "unknown/method", null), -32600, not_initialized_message, "not_initialized");
    // Nothing went to the upstream server.
    try testing.expect(t.upstream.conn == null);
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());

    // `logging/setLevel` can also come between the result and `notifications/initialized`.
    _ = try t.initialize();
    _ = try h.expectResult(try t.requestInline(2, "logging/setLevel", "{\"level\":\"warning\"}"));
    try testing.expectEqual(mcp.types.LoggingLevel.warning, t.frontend.clientLogLevel().?);
    _ = try h.expectResult(try t.requestInline(3, "ping", null));
    try t.verify();
}

test "two initialize requests at the same time, then initialize after ready" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    try t.send(h.vscode_initialize);
    // The first request changed the state on the reader, thus the second gets -32600 at once.
    const second = try t.callInline(2, try h.requestLine(t.arena(), 2, "initialize", h.vscode_initialize_params));
    try h.expectError(second, -32600, already_initialized_message, "already_initialized");
    _ = try h.expectResult(try t.waitResponse(1));
    try t.waitIdle();
    try testing.expectEqual(Frontend.State.ready, t.frontend.state());
    const conn = t.upstream.conn.?;

    try t.send(h.initialized);
    try h.expectError(try t.requestInline(3, "initialize", h.vscode_initialize_params), -32600, already_initialized_message, "already_initialized");
    // The bridge keeps its upstream connection.
    try testing.expect(t.upstream.conn.? == conn);
    _ = try h.expectResult(try t.request(4, "tools/list", "{}"));
    try t.verify();
}

test "server/discover fails, then a new initialize succeeds" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    // The fixture server cannot read the discover request with this depth limit, thus the
    // upstream client gets an answer that is not valid.
    t.server.options.limits.json_max_depth = 2;
    const failed = try t.call(1, h.vscode_initialize);
    try h.expectError(failed, -32603, "The upstream server sent a response that is not valid. See the Output channel of the server.", "invalid_response");
    try testing.expectEqualStrings("server/discover", h.errorDetail(failed).?);
    // The bridge stays alive and returns to `awaiting_initialize`.
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());
    try testing.expect(t.upstream.conn == null);
    try h.expectError(try t.requestInline(2, "tools/list", "{}"), -32600, not_initialized_message, "not_initialized");

    t.server.options.limits.json_max_depth = (mcp.Limits{}).json_max_depth;
    const result = try h.expectResult(try t.request(3, "initialize", h.vscode_initialize_params));
    try testing.expectEqualStrings(fixture.server_name, result.object.get("serverInfo").?.object.get("name").?.string);
    try testing.expectEqual(Frontend.State.ready, t.frontend.state());
    try t.send(h.initialized);
    _ = try h.expectResult(try t.request(4, "tools/list", "{}"));
    try t.verify();
}

test "an upstream command that does not start, then a new initialize succeeds" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    const argv = [_][]const u8{"mcp-bridge-vscode-test-command-that-does-not-exist"};
    t.upstream.config = .{ .stdio = .{ .argv = &argv } };
    const failed = try t.call(1, h.vscode_initialize);
    try h.expectError(failed, -32603, "The bridge cannot start the upstream server. Examine the command in the configuration of the server. See the Output channel of the server.", "spawn_failed");
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());

    t.upstream.config = t.upstreamConfig();
    _ = try h.expectResult(try t.request(2, "initialize", h.vscode_initialize_params));
    try testing.expectEqual(Frontend.State.ready, t.frontend.state());
    try t.verify();
}

test "an upstream process that exits before the discover result, then a new initialize succeeds" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    t.upstream.config = .{ .stdio = .{ .argv = exit_argv } };
    const failed = try t.call(1, h.vscode_initialize);
    try h.expectError(failed, -32603, "The upstream server process stopped. See the Output channel of the server.", "closed");
    try testing.expectEqualStrings("server/discover", h.errorDetail(failed).?);
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());
    try testing.expect(t.upstream.conn == null);

    t.upstream.config = t.upstreamConfig();
    _ = try h.expectResult(try t.request(2, "initialize", h.vscode_initialize_params));
    try t.verify();
}

test "an upstream process that never answers server/discover" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{ .frontend = .{ .discover_timeout = .fromSeconds(1) } });
    defer t.destroy();
    t.upstream.config = .{ .stdio = .{ .argv = silent_argv } };
    try t.send(h.vscode_initialize);
    try testing.expectEqual(Frontend.State.initializing, t.frontend.state());

    // While the bridge waits for the upstream server, the reader answers at once.
    try h.expectError(try t.requestInline(2, "tools/list", "{}"), -32600, not_initialized_message, "not_initialized");
    _ = try h.expectResult(try t.requestInline(3, "ping", null));
    _ = try h.expectResult(try t.requestInline(4, "logging/setLevel", "{\"level\":\"info\"}"));
    try h.expectError(try t.requestInline(5, "initialize", h.vscode_initialize_params), -32600, already_initialized_message, "already_initialized");
    try h.expectError(try t.requestInline(6, "server/discover", "{}"), -32601, method_not_found_message, "method_not_found");

    // VS Code sets no time limit for `initialize`. The bridge answers after its own limit.
    const failed = try t.waitResponse(1);
    try h.expectError(failed, -32603, "The upstream server did not answer server/discover. It is not an MCP server of revision 2026-07-28, or it does not respond. See the Output channel of the server.", "discover_failed");
    try testing.expectEqualStrings("no response in 1 s", h.errorDetail(failed).?);
    try t.waitIdle();
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());
    try testing.expect(t.upstream.conn == null);

    t.upstream.config = t.upstreamConfig();
    _ = try h.expectResult(try t.request(7, "initialize", h.vscode_initialize_params));
    try t.verify();
}

const discover_failed_message = "The upstream server did not answer server/discover. It is not an MCP server of revision 2026-07-28, or it does not respond. See the Output channel of the server.";

test "a legacy upstream server answers server/discover with -32601, then a new initialize succeeds" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    // A server of revision 2025-11-25 does not know server/discover.
    t.tap.setScript(.{ .rpc_error = "{\"code\":-32601,\"message\":\"Method not found\"}" });
    const failed = try t.call(1, h.vscode_initialize);
    // The code of the upstream server stays. The message tells why, and data.detail has the
    // message of the upstream server.
    try h.expectError(failed, -32601, discover_failed_message, "discover_failed");
    try testing.expectEqualStrings("Method not found", h.errorDetail(failed).?);
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());
    try testing.expect(t.upstream.conn == null);
    // The bridge sent server/discover one time.
    try testing.expectEqual(@as(usize, 1), t.tap.count());
    try testing.expectEqualStrings("server/discover", mcp.json.getString(try t.tap.request(t.arena(), 0), "method").?);

    t.tap.setScript(.forward);
    _ = try h.expectResult(try t.request(2, "initialize", h.vscode_initialize_params));
    try t.verify();
}

test "server/discover without a response in a time limit below one second" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{ .frontend = .{ .discover_timeout = .fromMilliseconds(300) } });
    defer t.destroy();
    t.tap.setScript(.wait);
    const failed = try t.call(1, h.vscode_initialize);
    try h.expectError(failed, -32603, discover_failed_message, "discover_failed");
    try testing.expectEqualStrings("no response in 300 ms", h.errorDetail(failed).?);
    try testing.expectEqual(@as(?mcp.transport.Transport.ExchangeError, error.Timeout), t.tap.exchange(0).outcome);
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());
    try t.verify();
}

/// A discover result without `_meta`, thus without the server information.
const anonymous_discover =
    \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}
;

test "an upstream server without serverInfo gets the name from the settings and the version of the bridge" {
    const command: []const []const u8 = &.{ "/opt/mcp/bin/files-server.exe", "--stdio" };
    const cases = [_]struct { options: Frontend.Options, expected: []const u8 }{
        // `serve` with a name, as from `--name`.
        .{ .options = vscode.frontendOptions(.{ .upstream = .{ .command = command }, .name = "my-server" }), .expected = "my-server" },
        // `serve` without a name: the file name of the command.
        .{ .options = vscode.frontendOptions(.{ .upstream = .{ .command = command } }), .expected = "files-server" },
        // A library that gives the front end no name gets the name of the profile, and never
        // an empty name.
        .{ .options = .{ .fallback_name = "" }, .expected = vscode.profile.name },
    };
    for (cases) |case| {
        const t = try Transcript.create(.{ .frontend = case.options });
        defer t.destroy();
        t.tap.setScript(.{ .result = anonymous_discover });
        const result = try h.expectResult(try t.call(1, h.vscode_initialize));
        const info = result.object.get("serverInfo").?;
        try testing.expectEqualStrings(case.expected, info.object.get("name").?.string);
        try testing.expectEqualStrings(vscode.bridge.version, info.object.get("version").?.string);
        try testing.expect(result.object.get("capabilities").?.object.get("tools") != null);
        try testing.expect(result.object.get("instructions") == null);

        // The requests after initialize go to the fixture server.
        t.tap.setScript(.forward);
        try t.send(h.initialized);
        _ = try h.expectResult(try t.request(2, "tools/list", "{}"));
        try t.verify();
    }
}

/// The `_meta` of a request of revision 2026-07-28 from the Copilot harness.
const copilot_meta =
    \\{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"copilot-cli","version":"1.0.89"},"io.modelcontextprotocol/clientCapabilities":{"sampling":{},"elicitation":{"form":{},"url":{}}}}
;

/// The `initialize` params of the Copilot harness: sampling and the two elicitation modes,
/// and no roots.
const copilot_initialize_params =
    \\{"protocolVersion":"2025-11-25","capabilities":{"sampling":{},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"copilot-cli","version":"1.0.89"}}
;

test "the Copilot harness: discover first, then initialize, then requests with progress token 0 and an eliciting call" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    const a = t.arena();

    // The first frame of the harness is `server/discover`. The bridge answers -32601 at once
    // and sends nothing upstream. Thus the harness continues with `initialize`.
    const discover = try t.requestInline(0, "server/discover", try std.fmt.allocPrint(a, "{{\"_meta\":{s}}}", .{copilot_meta}));
    try h.expectError(discover, -32601, method_not_found_message, "method_not_found");
    try testing.expectEqual(Frontend.State.awaiting_initialize, t.frontend.state());
    try testing.expect(t.upstream.conn == null);
    // Each request of revision 2026-07-28 before `initialize` gets -32601 too.
    const modern_list = try std.fmt.allocPrint(a, "{{\"_meta\":{s}}}", .{copilot_meta});
    try h.expectError(try t.requestInline(1, "tools/list", modern_list), -32601, method_not_found_message, "method_not_found");
    try testing.expect(t.upstream.conn == null);

    const result = try h.expectResult(try t.request(2, "initialize", copilot_initialize_params));
    try testing.expect(result.object.get("capabilities").?.object.get("tools") != null);
    try testing.expectEqualStrings(fixture.server_name, result.object.get("serverInfo").?.object.get("name").?.string);
    const client = try t.upstreamClient();
    try testing.expectEqualStrings("copilot-cli", client.options.info.name);
    // The input kinds of the harness go upstream: sampling and the two elicitation modes, and
    // no roots.
    try testing.expect(client.options.capabilities.sampling != null);
    try testing.expect(client.options.capabilities.hasElicitation(.url));
    try testing.expect(client.options.capabilities.roots == null);
    try t.send(h.initialized);
    try t.waitListening(1);

    // The harness sends `_meta.progressToken: 0` with each request.
    const tap = try t.tapUpstream();
    const list = try h.expectResult(try t.request(3, "tools/list", "{\"_meta\":{\"progressToken\":0}}"));
    var names: usize = 0;
    for (list.object.get("tools").?.array.items) |tool| {
        names += 1;
        // The harness declared no MCP Apps extension, thus the tool has no view.
        if (std.mem.eql(u8, tool.object.get("name").?.string, "show")) {
            if (tool.object.get("_meta")) |meta| try testing.expect(meta.object.get("ui") == null);
        }
    }
    try testing.expect(names >= 7);
    _ = try h.expectResult(try t.request(4, "tools/call", "{\"name\":\"progress\",\"arguments\":{\"count\":2},\"_meta\":{\"progressToken\":0}}"));

    // An eliciting call. The harness answers the form, and the retry round with the answer
    // goes upstream.
    try t.send(try h.requestLine(a, 5, "tools/call", "{\"name\":\"ask_form\",\"_meta\":{\"progressToken\":0}}"));
    const form = try t.bridgeRequest("elicitation/create", 1);
    try testing.expectEqualStrings("b-1", form.object.get("id").?.string);
    try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("form: accept {\"name\":\"Ada\"}", try h.firstText(try h.expectResult(try t.waitResponse(5))));
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 4), tap.count());
    const retry = (try tap.request(a, 3)).object.get("params").?;
    try testing.expectEqualStrings("ask_form", retry.object.get("name").?.string);
    const answer = retry.object.get("inputResponses").?.object.get("profile").?;
    try testing.expectEqualStrings("accept", answer.object.get("action").?.string);

    // The harness declared no roots. Thus the zig-sdk server does not ask for them, and its
    // error goes to the harness.
    try h.expectError(try t.request(6, "tools/call", "{\"name\":\"list_roots\",\"_meta\":{\"progressToken\":0}}"), -32021, null, null);
    try testing.expectEqual(@as(usize, 1), try t.methodCount("elicitation/create"));
    try testing.expectEqual(@as(usize, 0), try t.methodCount("roots/list"));

    // The progress of the call goes to the token 0 of the harness. The list request and the
    // other calls have no progress.
    var progress: usize = 0;
    for (try t.parsedFrames()) |frame| {
        const method = mcp.json.getString(frame, "method") orelse continue;
        if (std.mem.eql(u8, method, "elicitation/create")) continue;
        // The list changes after the acknowledgment of the listen stream.
        if (h.isListenEvent(method)) continue;
        try testing.expectEqualStrings("notifications/progress", method);
        try testing.expectEqual(@as(i64, 0), frame.object.get("params").?.object.get("progressToken").?.integer);
        progress += 1;
    }
    try testing.expectEqual(@as(usize, 2), progress);
    // Upstream, each request has the progress token of the upstream client, not the 0 of
    // the harness.
    for (0..tap.count()) |i| {
        const req = try tap.request(a, i);
        const meta = req.object.get("params").?.object.get("_meta").?;
        try testing.expectEqual(req.object.get("id").?.integer, meta.object.get("progressToken").?.integer);
    }
    try t.verify();
}
