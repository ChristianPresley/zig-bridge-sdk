//! The transcripts of the forwarded requests. They examine the pages of `tools/list`, the
//! progress, the array schemas and the cancellation. They also examine the completions, the
//! prompts, the resources and an MCP App.
const std = @import("std");
const mcp = @import("mcp");
const fixture = @import("fixture");
const h = @import("harness.zig");

const Value = std.json.Value;
const Transcript = h.Transcript;
const testing = std.testing;

test "the pages of tools/list never have a nextCursor that is null" {
    const t = try Transcript.create(.{ .fixture = .{ .many_tools = 9, .limits = .{ .page_size = 4 } } });
    defer t.destroy();
    _ = try t.initialize();
    const a = t.arena();

    var names: std.ArrayList([]const u8) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    var id: i64 = 2;
    // VS Code asks for the next page while `nextCursor` is present, also when it is null.
    while (true) : (id += 1) {
        const params = if (cursor) |c| try std.fmt.allocPrint(a, "{{\"cursor\":\"{s}\"}}", .{c}) else "{}";
        const result = try h.expectResult(try t.request(id, "tools/list", params));
        pages += 1;
        for (result.object.get("tools").?.array.items) |tool| try names.append(a, tool.object.get("name").?.string);
        const next = result.object.get("nextCursor") orelse break;
        try testing.expect(next == .string);
        cursor = next.string;
        if (pages > 10) return error.TestTooManyPages;
    }
    // echo, add, slow, progress, bare_array, structured, the nine tools that ask for input,
    // toggle, toggled, touch, log, show and tool_0 to tool_8.
    try testing.expectEqual(@as(usize, 29), names.items.len);
    try testing.expectEqual(@as(usize, 8), pages);
    for (names.items, 0..) |n, i| for (names.items[i + 1 ..]) |m| try testing.expect(!std.mem.eql(u8, n, m));
    for (0..t.count()) |i| try testing.expect(std.mem.indexOf(u8, t.text(i), "\"nextCursor\":null") == null);
    try t.verify();
}

test "tools/call with the progress token of VS Code gets the progress with that token" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();
    const a = t.arena();
    const start = t.count();

    // The `_meta` of a tools/call of VS Code: a UUID token, the keys of VS Code and the
    // trace context.
    const uuid = "8f14e45f-ceea-4672-9b2f-0c3b7c2d5a11";
    // A key that is not valid, a key of zig-sdk and a key outside the profile stay with the
    // bridge, and the call does not fail.
    const params = "{\"name\":\"progress\",\"arguments\":{\"count\":3},\"_meta\":{\"progressToken\":\"" ++ uuid ++
        "\",\"vscode.conversationId\":\"c-1\",\"vscode.requestId\":\"r-1\",\"traceparent\":\"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01\",\"tracestate\":\"x=1\"," ++
        "\"vscode.bad key\":1,\"io.modelcontextprotocol/logLevel\":\"debug\",\"baggage\":\"b=1\"}}";
    const result = try h.expectResult(try t.request(2, "tools/call", params));
    try testing.expectEqualStrings("sent 3 progress notifications", try h.firstText(result));

    const response_index = (try t.responseIndex(2)).?;
    var steps: usize = 0;
    for ((try t.parsedFrames())[start..], start..) |frame, i| {
        const method = mcp.json.getString(frame, "method") orelse continue;
        try testing.expectEqualStrings("notifications/progress", method);
        // Each progress comes before the result.
        try testing.expect(i < response_index);
        const p = frame.object.get("params").?;
        try testing.expectEqualStrings(uuid, p.object.get("progressToken").?.string);
        steps += 1;
        try testing.expectEqual(@as(f64, @floatFromInt(steps)), number(p.object.get("progress").?));
        try testing.expectEqual(@as(f64, 3), number(p.object.get("total").?));
        const note = try std.fmt.allocPrint(a, "Step {d} of 3", .{steps});
        try testing.expectEqualStrings(note, p.object.get("message").?.string);
        try testing.expect(p.object.get("_meta") == null);
    }
    try testing.expectEqual(@as(usize, 3), steps);

    // Upstream, the request has the token of the upstream client. The keys of VS Code and the
    // trace context go upstream unchanged. `verify` also checks the keys.
    const req = try tap.request(a, 0);
    const meta = req.object.get("params").?.object.get("_meta").?;
    try testing.expectEqual(req.object.get("id").?.integer, meta.object.get("progressToken").?.integer);
    try testing.expectEqualStrings("c-1", meta.object.get("vscode.conversationId").?.string);
    try testing.expectEqualStrings("r-1", meta.object.get("vscode.requestId").?.string);
    try testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", meta.object.get("traceparent").?.string);
    try testing.expectEqualStrings("x=1", meta.object.get("tracestate").?.string);
    // VS Code set no log level.
    try testing.expect(meta.object.get("io.modelcontextprotocol/logLevel") == null);
    try testing.expect(meta.object.get("vscode.bad key") == null);
    try testing.expect(meta.object.get("baggage") == null);

    // Without a token, VS Code gets no progress.
    const before = t.count();
    _ = try h.expectResult(try t.request(3, "tools/call", "{\"name\":\"progress\",\"arguments\":{\"count\":2}}"));
    try testing.expectEqual(before + 1, t.count());
    try t.verify();
}

fn number(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => std.math.nan(f64),
    };
}

test "each array schema of a tool gets items, thus Copilot accepts the tool" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const list = try h.expectResult(try t.request(2, "tools/list", "{}"));
    var found = false;
    for (list.object.get("tools").?.array.items) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, "bare_array")) continue;
        found = true;
        const props = tool.object.get("inputSchema").?.object.get("properties").?;
        // An array without items gets `items: {}`.
        const values = props.object.get("values").?;
        try testing.expect(values.object.get("items").? == .object);
        try testing.expectEqual(@as(usize, 0), values.object.get("items").?.object.count());
        try testing.expectEqualStrings("Any values", values.object.get("description").?.string);
        // `items: false` after `prefixItems` becomes `items: {}` and `maxItems`.
        const pair = props.object.get("pair").?;
        try testing.expect(pair.object.get("items").? == .object);
        try testing.expectEqual(@as(i64, 2), pair.object.get("maxItems").?.integer);
        try testing.expectEqual(@as(usize, 2), pair.object.get("prefixItems").?.array.items.len);
        // An array in `anyOf`.
        const choice = props.object.get("choice").?.object.get("anyOf").?.array.items;
        try testing.expect(choice[0].object.get("items").? == .object);
        try testing.expect(choice[1].object.get("items") == null);
    }
    try testing.expect(found);
    // The tool still works with the arguments of the changed schema.
    const called = try h.expectResult(try t.request(3, "tools/call", "{\"name\":\"bare_array\",\"arguments\":{\"values\":[1,\"x\",null],\"pair\":[\"a\",2]}}"));
    try testing.expectEqualStrings("3 values", try h.firstText(called));
    // `verify` examines each array schema of each tools/list result as Copilot does.
    try t.verify();
}

test "notifications/cancelled during a slow tool: no response, and the upstream server stops the tool" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();
    const a = t.arena();

    try t.send(try h.requestLine(a, 5, "tools/call", "{\"name\":\"slow\",\"arguments\":{\"ms\":60000}}"));
    try tap.waitStarted(1);
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":5,\"reason\":\"The user stopped the request.\"}}");
    // The tool waits for 60 s without the cancellation. `waitIdle` waits for 10 s at most.
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 0), try t.responseCount(5));
    const ex = tap.exchange(0);
    try testing.expect(ex.done);
    try testing.expectEqual(@as(?mcp.transport.Transport.ExchangeError, error.Canceled), ex.outcome);

    // A cancellation of an id that is not in flight changes nothing.
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":77}}");
    _ = try h.expectResult(try t.requestInline(6, "ping", null));
    _ = try h.expectResult(try t.request(7, "tools/call", "{\"name\":\"slow\",\"arguments\":{\"ms\":1}}"));
    try t.verify();
}

const complete_params =
    \\{"ref":{"type":"ref/prompt","name":"greet"},"argument":{"name":"name","value":"a"}}
;

test "completion/complete goes to the upstream server when the server declares completions" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    const init = try t.initialize();
    try testing.expect(init.object.get("capabilities").?.object.get("completions") != null);
    const result = try h.expectResult(try t.request(2, "completion/complete", complete_params));
    const completion = result.object.get("completion").?;
    const values = completion.object.get("values").?.array.items;
    try testing.expectEqual(fixture.completion_values.len, values.len);
    for (fixture.completion_values, values) |want, got| try testing.expectEqualStrings(want, got.string);
    try testing.expectEqual(@as(i64, 2), completion.object.get("total").?.integer);
    try testing.expect(!completion.object.get("hasMore").?.bool);
    try t.verify();
}

test "completion/complete goes to the upstream server also when the server declares no completions" {
    const t = try Transcript.create(.{ .fixture = .{ .completion = false } });
    defer t.destroy();
    const init = try t.initialize();
    try testing.expect(init.object.get("capabilities").?.object.get("completions") == null);
    // VS Code sends the request also without the capability. The error of the upstream
    // server goes to VS Code unchanged.
    const response = try t.request(2, "completion/complete", complete_params);
    try h.expectError(response, -32601, null, null);
    const err = response.object.get("error").?;
    try testing.expect(std.mem.startsWith(u8, err.object.get("message").?.string, "Method not found: completion/complete"));
    if (err.object.get("data")) |data| try testing.expect(data != .object or data.object.get("cause") == null);
    try t.verify();
}

test "prompts, resources, an MCP App and structured content" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();

    const prompts = try h.expectResult(try t.request(2, "prompts/list", "{}"));
    const greet = prompts.object.get("prompts").?.array.items[0];
    try testing.expectEqualStrings("greet", greet.object.get("name").?.string);
    try testing.expectEqualStrings("name", greet.object.get("arguments").?.array.items[0].object.get("name").?.string);
    const prompt = try h.expectResult(try t.request(3, "prompts/get", "{\"name\":\"greet\",\"arguments\":{\"name\":\"Ada\"}}"));
    const message = prompt.object.get("messages").?.array.items[0];
    try testing.expectEqualStrings("user", message.object.get("role").?.string);
    try testing.expectEqualStrings("Hello, Ada.", message.object.get("content").?.object.get("text").?.string);

    const resources = try h.expectResult(try t.request(4, "resources/list", "{}"));
    var uris: usize = 0;
    for (resources.object.get("resources").?.array.items) |r| {
        const uri = r.object.get("uri").?.string;
        if (std.mem.eql(u8, uri, h.readme_uri) or std.mem.eql(u8, uri, h.app_view_uri)) uris += 1;
    }
    try testing.expectEqual(@as(usize, 2), uris);
    const readme = try h.expectResult(try t.request(5, "resources/read", "{\"uri\":\"" ++ h.readme_uri ++ "\"}"));
    const text = readme.object.get("contents").?.array.items[0];
    try testing.expectEqualStrings(h.readme_text, text.object.get("text").?.string);
    try testing.expectEqualStrings("text/plain", text.object.get("mimeType").?.string);
    _ = try h.expectResult(try t.request(6, "resources/templates/list", "{}"));

    // An MCP App: the tool names its view, and VS Code reads the `ui://` resource.
    const view = try h.expectResult(try t.request(7, "resources/read", "{\"uri\":\"" ++ h.app_view_uri ++ "\"}"));
    const html = view.object.get("contents").?.array.items[0];
    try testing.expectEqualStrings(h.app_view_html, html.object.get("text").?.string);
    try testing.expectEqualStrings("text/html;profile=mcp-app", html.object.get("mimeType").?.string);
    const shown = try h.expectResult(try t.request(8, "tools/call", "{\"name\":\"show\",\"arguments\":{}}"));
    try testing.expectEqualStrings("shown", try h.firstText(shown));

    // Structured content goes to VS Code unchanged. The result has a text block, thus the
    // bridge adds no copy.
    const structured = try h.expectResult(try t.request(9, "tools/call", "{\"name\":\"structured\",\"arguments\":{\"text\":\"abc\"}}"));
    const sc = structured.object.get("structuredContent").?;
    try testing.expectEqualStrings("abc", sc.object.get("text").?.string);
    try testing.expectEqual(@as(i64, 3), sc.object.get("length").?.integer);
    try testing.expectEqual(@as(usize, 1), structured.object.get("content").?.array.items.len);
    try testing.expectEqualStrings("3 bytes", try h.firstText(structured));

    // An error of the upstream server goes to VS Code unchanged.
    const missing = try t.request(10, "resources/read", "{\"uri\":\"file:///fixture/missing.txt\"}");
    const err = missing.object.get("error") orelse return error.TestExpectedError;
    if (err.object.get("data")) |data| try testing.expect(data != .object or data.object.get("cause") == null);
    try t.verify();
}

test "a tool with an array output schema and array structured content" {
    const t = try Transcript.create(.{ .fixture = .{ .array_output = true } });
    defer t.destroy();
    _ = try t.initialize();

    // VS Code does not read the output schema, and revision 2025-11-25 allows only an object
    // schema there. Thus the bridge removes it. The other output schemas stay. The one page
    // ends without a cursor.
    const list = try h.expectResult(try t.request(2, "tools/list", "{}"));
    try testing.expect(list.object.get("nextCursor") == null);
    var seen: usize = 0;
    for (list.object.get("tools").?.array.items) |tool| {
        const name = tool.object.get("name").?.string;
        if (std.mem.eql(u8, name, "array_output")) {
            try testing.expect(tool.object.get("outputSchema") == null);
            seen += 1;
        } else if (std.mem.eql(u8, name, "structured")) {
            try testing.expect(tool.object.get("outputSchema") != null);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), seen);

    // The structured content goes to VS Code unchanged, with a text block that has its JSON.
    // The MCP Apps of VS Code read the structured content.
    const call = try h.expectResult(try t.request(3, "tools/call", "{\"name\":\"array_output\",\"arguments\":{}}"));
    const sc = call.object.get("structuredContent").?;
    try testing.expectEqual(fixture.array_output_values.len, sc.array.items.len);
    for (fixture.array_output_values, sc.array.items) |expected, item| try testing.expectEqual(expected, item.integer);
    try testing.expectEqualStrings("[1,2,3]", try h.firstText(call));
    try t.verify();
}
