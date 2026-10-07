//! The negative transcripts. They examine lines that are not valid and responses of VS Code
//! that belong to no request. They also examine the error table with a scripted upstream
//! transport.
const std = @import("std");
const mcp = @import("mcp");
const vscode = @import("vscode");
const h = @import("harness.zig");

const Value = std.json.Value;
const Frontend = vscode.bridge.Frontend;
const Transcript = h.Transcript;
const ExchangeError = mcp.transport.Transport.ExchangeError;
const testing = std.testing;

const parse_error_message = "The request is not valid JSON.";
const too_long_message = "The request is longer than the line limit of the bridge.";
const too_deep_message = "The request has more levels of nesting than the limit of the bridge.";
const shape_message = "The message is not a valid JSON-RPC 2.0 request.";

/// The last frame of the bridge.
fn last(t: *Transcript) !Value {
    const frames = try t.parsedFrames();
    if (frames.len == 0) return error.TestNoFrame;
    return frames[frames.len - 1];
}

/// A request line with nesting deeper than `levels`.
fn deepLine(a: std.mem.Allocator, id: i64, levels: usize) ![]u8 {
    const open = try a.alloc(u8, levels);
    @memset(open, '[');
    const close = try a.alloc(u8, levels);
    @memset(close, ']');
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"echo\",\"arguments\":{{\"text\":{s}1{s}}}}}}}", .{ id, open, close });
}

/// A `tools/call` line with a text argument of `len` bytes.
fn longLine(a: std.mem.Allocator, id: i64, len: usize) ![]u8 {
    const filler = try a.alloc(u8, len);
    @memset(filler, 'y');
    return std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"echo\",\"arguments\":{{\"text\":\"{s}\"}}}}}}", .{ id, filler });
}

test "lines that are not valid get an error with the id of the request" {
    const t = try Transcript.create(.{ .frontend = .{ .max_line_bytes = 1024, .json_max_depth = 10 } });
    defer t.destroy();
    _ = try t.initialize();
    const a = t.arena();

    // A lone surrogate escape. JSON.stringify of VS Code writes it for model text, and the
    // JSON parser of Zig refuses it.
    const surrogate = try t.callInline(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"a\\ud800b\"}}}");
    try h.expectError(surrogate, -32700, parse_error_message, "parse_error");
    // Nesting deeper than the limit.
    const deep = try t.callInline(3, try deepLine(a, 3, 12));
    try h.expectError(deep, -32600, too_deep_message, "too_deep");
    try testing.expectEqualStrings("limit: 10 levels", h.errorDetail(deep).?);
    // A line longer than the limit. The id is at the start of the line.
    const long = try t.callInline(4, try longLine(a, 4, 2000));
    try h.expectError(long, -32600, too_long_message, "line_too_long");
    try testing.expectEqualStrings("limit: 1024 bytes", h.errorDetail(long).?);
    // Bytes that are not UTF-8, and a control character in a string.
    try h.expectError(try t.callInline(5, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"\xff\xfe\"}}}"), -32700, parse_error_message, "parse_error");
    try h.expectError(try t.callInline(6, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"a\x01b\"}}}"), -32700, parse_error_message, "parse_error");
    // A line that ends in the middle of the JSON text.
    try h.expectError(try t.callInline(7, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":"), -32700, parse_error_message, "parse_error");
    // Valid JSON that is not a JSON-RPC 2.0 request.
    try h.expectError(try t.callInline(8, "{\"jsonrpc\":\"1.0\",\"id\":8,\"method\":\"ping\"}"), -32600, shape_message, "invalid_request_shape");

    // A string id.
    const before = t.count();
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":\"req-9\",\"method\":\"tools/call\",\"params\":{\"text\":\"\\udfff\"}}");
    try testing.expectEqual(before + 1, t.count());
    const string_id = try last(t);
    try testing.expectEqualStrings("req-9", string_id.object.get("id").?.string);
    try h.expectError(string_id, -32700, parse_error_message, "parse_error");
    // Without an id, the error has the id null.
    try t.send("this is not JSON");
    try testing.expectEqual(before + 2, t.count());
    const no_id = try last(t);
    try testing.expect(no_id.object.get("id").? == .null);
    try h.expectError(no_id, -32700, parse_error_message, "parse_error");

    // The connection stays open.
    _ = try h.expectResult(try t.requestInline(10, "ping", null));
    _ = try h.expectResult(try t.request(11, "tools/call", "{\"name\":\"echo\",\"arguments\":{\"text\":\"still here\"}}"));
    try t.verify();
}

test "the reader answers lines that are not valid, with a small buffer and with a large buffer" {
    for ([_]usize{ 16, 4096 }) |buffer_len| {
        const t = try Transcript.create(.{ .frontend = .{ .max_line_bytes = 300, .json_max_depth = 10 } });
        defer t.destroy();
        const a = t.arena();
        // `receive` gets complete lines. These lines go through the line reader of `run`.
        const lines = [_][]const u8{
            try longLine(a, 7, 400),
            "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"x\":\"\xc3\x28\"}}",
            "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"x\":\"\\ud800\"}}\r",
            try deepLine(a, 10, 12),
            "",
            "not JSON",
            "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"ping\"}",
        };
        const data = try std.mem.concat(a, u8, &.{ try std.mem.join(a, "\n", &lines), "\n" });
        try testing.expectEqual(Frontend.RunResult.eof, try t.runLines(data, buffer_len));
        const long = (try t.response(7)).?;
        try h.expectError(long, -32600, too_long_message, "line_too_long");
        try testing.expectEqualStrings("limit: 300 bytes", h.errorDetail(long).?);
        try h.expectError((try t.response(8)).?, -32700, parse_error_message, "parse_error");
        try h.expectError((try t.response(9)).?, -32700, parse_error_message, "parse_error");
        try h.expectError((try t.response(10)).?, -32600, too_deep_message, "too_deep");
        _ = try h.expectResult((try t.response(11)).?);
        var null_ids: usize = 0;
        for (try t.parsedFrames()) |frame| if (frame.object.get("id").? == .null) {
            try h.expectError(frame, -32700, parse_error_message, "parse_error");
            null_ids += 1;
        };
        try testing.expectEqual(@as(usize, 1), null_ids);
        try testing.expectEqual(@as(usize, 6), t.count());
        try t.verify();
    }
}

test "responses of VS Code that belong to no request get no answer" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const before = t.count();
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}");
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"cancel\"}}");
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-2\",\"error\":{\"code\":-32000,\"message\":\"The user refused the request.\"}}");
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
    // A late answer with a lone surrogate and the id of a request of the bridge.
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-3\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"\\ud800\"}}}");
    try testing.expectEqual(before, t.count());
    _ = try h.expectResult(try t.requestInline(2, "ping", null));
    try t.verify();
}

const timeout_message = "The upstream server did not answer in time. See the Output channel of the server.";
const closed_message = "The upstream server process stopped. See the Output channel of the server.";
const transport_message = "The connection to the upstream server failed. See the Output channel of the server.";
const invalid_message = "The upstream server sent a response that is not valid. See the Output channel of the server.";
const rounds_message = "The upstream server asked for input too many times. See the Output channel of the server.";
const input_message = "The upstream server needs input that this version of the bridge cannot ask for yet.";

const echo_params = "{\"name\":\"echo\",\"arguments\":{\"text\":\"a\"}}";

test "the error table: each failure of the upstream client gets its code, message and cause" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{ .frontend = .{ .timeouts = .{ .call = .fromSeconds(1), .list = .fromSeconds(1) } } });
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // Timeout: the upstream server does not answer.
    tap.setScript(.wait);
    const timeout = try t.request(2, "tools/call", echo_params);
    try h.expectError(timeout, -32603, timeout_message, "timeout");
    try testing.expectEqualStrings("tools/call: no response in 1 s", h.errorDetail(timeout).?);
    try testing.expectEqual(@as(?ExchangeError, error.Timeout), tap.exchange(0).outcome);

    // Closed: a tools/call goes upstream one time only.
    tap.setScript(.{ .fail = error.Closed });
    try h.expectError(try t.request(3, "tools/call", echo_params), -32603, closed_message, "closed");
    try testing.expectEqual(@as(usize, 2), tap.count());
    // The upstream client sends a list request again after a lost stream, three times.
    try h.expectError(try t.request(4, "tools/list", "{}"), -32603, closed_message, "closed");
    try testing.expectEqual(@as(usize, 6), tap.count());

    // TransportFailed: the stream broke.
    tap.setScript(.{ .fail = error.ReadFailed });
    try h.expectError(try t.request(5, "tools/call", echo_params), -32603, transport_message, "transport_failed");

    // InvalidResponse: a result that is not an object, and a result type that is not known.
    tap.setScript(.{ .result = "[]" });
    try h.expectError(try t.request(6, "tools/call", echo_params), -32603, invalid_message, "invalid_response");
    tap.setScript(.{ .result = "{\"resultType\":\"later\",\"content\":[]}" });
    try h.expectError(try t.request(7, "tools/call", echo_params), -32603, invalid_message, "invalid_response");
    tap.setScript(.{ .fail = error.InvalidFrame });
    try h.expectError(try t.request(8, "tools/call", echo_params), -32603, invalid_message, "invalid_response");

    // TooManyRounds: with one round, the retry after -32022 is one round too many.
    const client = try t.upstreamClient();
    client.options.limits.mrtr_max_rounds_client = 1;
    tap.setScript(.{ .rpc_error = "{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2026-07-28\"}}" });
    const rounds_before = tap.count();
    try h.expectError(try t.request(9, "tools/call", echo_params), -32603, rounds_message, "too_many_rounds");
    try testing.expectEqual(rounds_before + 1, tap.count());
    client.options.limits.mrtr_max_rounds_client = (mcp.Limits{}).mrtr_max_rounds_client;

    // The connection still works.
    tap.setScript(.forward);
    _ = try h.expectResult(try t.request(10, "tools/call", echo_params));
    try t.verify();
}

test "a canceled request gets no response, and an upstream error goes to VS Code unchanged" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();
    const a = t.arena();

    // Canceled: the upstream transport sees the cancellation, and VS Code gets nothing.
    tap.setScript(.wait);
    try t.send(try h.requestLine(a, 2, "tools/call", echo_params));
    try tap.waitStarted(1);
    try t.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":2}}");
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 0), try t.responseCount(2));
    try testing.expectEqual(@as(?ExchangeError, error.Canceled), tap.exchange(0).outcome);

    // Rpc: the code, the message and the data stay the same.
    tap.setScript(.{ .rpc_error = "{\"code\":-32002,\"message\":\"Resource not found\",\"data\":{\"uri\":\"file:///missing\"}}" });
    const missing = try t.request(3, "resources/read", "{\"uri\":\"file:///missing\"}");
    try h.expectError(missing, -32002, "Resource not found", null);
    const data = missing.object.get("error").?.object.get("data").?;
    try testing.expectEqual(@as(usize, 1), data.object.count());
    try testing.expectEqualStrings("file:///missing", data.object.get("uri").?.string);

    // -32042 of revision 2025-11-25 becomes -32603 without data, because VS Code opens each
    // URL in its data.
    tap.setScript(.{ .rpc_error = "{\"code\":-32042,\"message\":\"Open the page to continue.\",\"data\":{\"elicitations\":[{\"mode\":\"url\",\"elicitationId\":\"e-1\",\"url\":\"https://example.com/step\",\"message\":\"Continue\"}]}}" });
    const url = try t.request(4, "tools/call", echo_params);
    try h.expectError(url, -32603, "Open the page to continue.", null);
    try testing.expect(url.object.get("error").?.object.get("data") == null);
    try t.verify();
}

test "the results of a scripted upstream server lose the members of revision 2026-07-28" {
    // The warning about the input request is expected.
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // A nextCursor that is null, with the members of revision 2026-07-28.
    tap.setScript(.{ .result = "{\"resultType\":\"complete\",\"ttlMs\":60000,\"cacheScope\":\"public\",\"tools\":[],\"nextCursor\":null,\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"s\",\"version\":\"1\"}}}" });
    const tools = try h.expectResult(try t.request(2, "tools/list", "{}"));
    try testing.expectEqual(@as(usize, 1), tools.object.count());
    try testing.expectEqual(@as(usize, 0), tools.object.get("tools").?.array.items.len);
    // A nextCursor that is not a string.
    tap.setScript(.{ .result = "{\"resultType\":\"complete\",\"prompts\":[],\"nextCursor\":7}" });
    const prompts = try h.expectResult(try t.request(3, "prompts/list", "{}"));
    try testing.expect(prompts.object.get("nextCursor") == null);
    // A string nextCursor stays. Other `_meta` keys stay.
    tap.setScript(.{ .result = "{\"resultType\":\"complete\",\"resources\":[],\"nextCursor\":\"c2\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"s\",\"version\":\"1\"},\"example.com/k\":1}}" });
    const resources = try h.expectResult(try t.request(4, "resources/list", "{}"));
    try testing.expectEqualStrings("c2", resources.object.get("nextCursor").?.string);
    const meta = resources.object.get("_meta").?;
    try testing.expectEqual(@as(usize, 1), meta.object.count());
    try testing.expect(meta.object.get("example.com/k") != null);

    // An input request never goes to VS Code in this version.
    tap.setScript(.{ .result = "{\"resultType\":\"input_required\",\"inputRequests\":{\"name\":{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"form\",\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}}}},\"requestState\":\"s-1\"}" });
    try h.expectError(try t.request(5, "tools/call", echo_params), -32603, input_message, "input_required");

    // Structured content that is not an object goes to VS Code unchanged, with a text copy.
    tap.setScript(.{ .result = "{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":[1,2,3]}" });
    const array = try h.expectResult(try t.request(6, "tools/call", echo_params));
    try testing.expectEqual(@as(usize, 3), array.object.get("structuredContent").?.array.items.len);
    const content = array.object.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 1), content.len);
    try testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try testing.expectEqualStrings("[1,2,3]", content[0].object.get("text").?.string);
    // A tools/call result without content gets an empty content array.
    tap.setScript(.{ .result = "{\"resultType\":\"complete\"}" });
    const empty = try h.expectResult(try t.request(7, "tools/call", echo_params));
    try testing.expectEqual(@as(usize, 0), empty.object.get("content").?.array.items.len);
    try t.verify();
}

test "an input schema deeper than the default depth limit of zig-sdk does not fail tools/list" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // A chain of 80 `not` schemas. With the response around it, the nesting is deeper than
    // the 64 levels of the default limits of zig-sdk, and deeper than the walk of the schema
    // rules.
    const levels = 80;
    tap.setScript(.{ .result = "{\"resultType\":\"complete\",\"tools\":[{\"name\":\"deep\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"list\":{\"type\":\"array\"},\"deep\":" ++
        "{\"not\":" ** levels ++ "{\"type\":\"string\"}" ++ "}" ** levels ++ "}}}]}" });
    const list = try h.expectResult(try t.request(2, "tools/list", "{}"));
    const schema = list.object.get("tools").?.array.items[0].object.get("inputSchema").?;
    const properties = schema.object.get("properties").?;
    // The array near the root gets its items schema.
    try testing.expect(properties.object.get("list").?.object.get("items") != null);
    // The deep chain stays as it is.
    var node = properties.object.get("deep").?;
    var depth: usize = 0;
    while (node.object.get("not")) |next| : (depth += 1) node = next;
    try testing.expectEqual(@as(usize, levels), depth);
    try testing.expectEqualStrings("string", node.object.get("type").?.string);
    try t.verify();
}
