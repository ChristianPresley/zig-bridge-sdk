//! The transcripts of the input requests. A tool of the fixture server asks for input with an
//! `InputRequiredResult`. The bridge sends each input request to VS Code as a request with a
//! string id. The test reads these requests from the sink and answers them as VS Code does. A
//! scripted upstream server sends the input requests that the fixture server cannot send.
//!
//! `Transcript.verify` checks each request and each notification of the bridge against the
//! schema of revision 2025-11-25. It also checks each round to the upstream server against the
//! schema of revision 2026-07-28.
const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp");
const vscode = @import("vscode");
const fixture = @import("fixture");
const h = @import("harness.zig");

const Value = std.json.Value;
const Frontend = vscode.bridge.Frontend;
const input = vscode.bridge.input;
const Transcript = h.Transcript;
const ExchangeError = mcp.transport.Transport.ExchangeError;
const testing = std.testing;

const invalid_answer_message = "The client sent an answer that is not valid for the input request of the upstream server.";
const undeclared_message = "The upstream server asked for input that the client did not declare.";
const too_many_message = "The upstream server asked for more inputs at one time than the limit of the bridge.";
const input_timeout_message = "The client did not answer the input request of the upstream server in time.";

/// The answer of the model of VS Code to the request of the tool `sample`.
const sample_answer =
    \\{"role":"assistant","content":{"type":"text","text":"Hello"},"model":"m","stopReason":"endTurn"}
;

/// The complete `tools/call` result of a scripted upstream server.
const done_result =
    \\{"resultType":"complete","content":[{"type":"text","text":"done"}]}
;

/// The error of zig-sdk for a `requestState` that is not valid or that expired.
const refused_state =
    \\{"code":-32602,"message":"Invalid or expired requestState","data":{"reason":"invalid_request_state"}}
;

/// A form with one string property, as an input request of a scripted upstream server.
const name_form =
    \\{"method":"elicitation/create","params":{"mode":"form","message":"Your name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}
;

/// A URL elicitation for `url`, as an input request of a scripted upstream server.
fn urlInput(comptime url: []const u8) []const u8 {
    return "{\"method\":\"elicitation/create\",\"params\":{\"mode\":\"url\",\"message\":\"Open the page.\",\"url\":\"" ++ url ++ "\"}}";
}

/// One round of a scripted upstream server with URLs that the bridge refuses, three loopback
/// URLs and a form.
const refused_urls_round = "{\"resultType\":\"input_required\",\"inputRequests\":{" ++
    "\"script\":" ++ urlInput("javascript:alert(1)") ++ "," ++
    "\"editor\":" ++ urlInput("vscode://ms-python.python/start") ++ "," ++
    "\"command\":" ++ urlInput("command:workbench.action.reloadWindow") ++ "," ++
    "\"plain\":" ++ urlInput("http://example.com/sign-in") ++ "," ++
    "\"lookalike\":" ++ urlInput("http://127.0.0.1.example.com/callback") ++ "," ++
    "\"data\":" ++ urlInput("data:text/html,hello") ++ "," ++
    "\"file\":" ++ urlInput("file:///etc/passwd") ++ "," ++
    "\"text\":" ++ urlInput("not a URL") ++ "," ++
    "\"ip4\":" ++ urlInput("http://127.0.0.1:8080/callback") ++ "," ++
    "\"ip6\":" ++ urlInput("http://[::1]:8080/callback") ++ "," ++
    "\"local\":" ++ urlInput("http://localhost:8080/callback") ++ "," ++
    "\"name\":" ++ name_form ++
    "},\"requestState\":\"s-1\"}";

/// The keys of `refused_urls_round` whose URL the bridge refuses.
const refused_keys = [_][]const u8{ "script", "editor", "command", "plain", "lookalike", "data", "file", "text" };

/// Sampling requests that use tools. A server sends them only to a client that declared
/// `sampling.tools`.
const sampling_with_tools =
    \\{"resultType":"input_required","inputRequests":{"model":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Look up the weather."}}],"maxTokens":50,"tools":[{"name":"lookup","inputSchema":{"type":"object"}}]}}}}
;
const sampling_with_tool_choice =
    \\{"resultType":"input_required","inputRequests":{"model":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Look up the weather."}}],"maxTokens":50,"toolChoice":{"mode":"auto"}}}}}
;
const sampling_with_tool_content =
    \\{"resultType":"input_required","inputRequests":{"model":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Weather?"}},{"role":"assistant","content":{"type":"tool_use","id":"call-1","name":"lookup","input":{}}},{"role":"user","content":{"type":"tool_result","toolUseId":"call-1","content":[{"type":"text","text":"Sunny."}]}}],"maxTokens":50}}}}
;

/// A sampling request with `includeContext`. The bridge does not refuse it, because a client
/// can ignore `includeContext`.
const sampling_with_context =
    \\{"resultType":"input_required","inputRequests":{"model":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Say hello."}}],"maxTokens":50,"includeContext":"thisServer"}}}}
;

/// A round with one URL elicitation.
const url_round = "{\"resultType\":\"input_required\",\"inputRequests\":{\"auth\":" ++ urlInput("https://example.com/auth") ++ "}}";

/// A form round with a `requestState`, for `prompts/get` and `resources/read`.
const name_round_with_state = "{\"resultType\":\"input_required\",\"inputRequests\":{\"name\":" ++ name_form ++ "},\"requestState\":\"sealed-state-1\"}";

/// A confirmation of a scripted upstream server: a form without a property.
const confirm_round =
    \\{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"mode":"form","message":"Delete the file?","requestedSchema":{"type":"object","properties":{}}}}},"requestState":"s-confirm"}
;

// -- Helpers ----------------------------------------------------------------------------------

/// Send `tools/call` for `tool` with the id `id` and without arguments.
fn callTool(t: *Transcript, id: i64, tool: []const u8) !void {
    try callToolArgs(t, id, tool, null);
}

/// Send `tools/call` for `tool` with the id `id`. `arguments` is a JSON object as text, or
/// null.
fn callToolArgs(t: *Transcript, id: i64, tool: []const u8, arguments: ?[]const u8) !void {
    const a = t.arena();
    const params = if (arguments) |args|
        try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ tool, args })
    else
        try std.fmt.allocPrint(a, "{{\"name\":\"{s}\"}}", .{tool});
    try t.send(try h.requestLine(a, id, "tools/call", params));
}

/// Wait for the response with the id `id`, and return the first text of its result.
fn resultText(t: *Transcript, id: i64) ![]const u8 {
    return h.firstText(try h.expectResult(try t.waitResponse(id)));
}

/// Send the error response of VS Code to the request `bridge_request` of the bridge. `err` is
/// the error object as JSON text.
fn replyError(t: *Transcript, bridge_request: Value, err: []const u8) !void {
    const id = bridge_request.object.get("id").?.string;
    try t.send(try std.fmt.allocPrint(t.arena(), "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"error\":{s}}}", .{ id, err }));
}

/// Send the `notifications/cancelled` of VS Code for its request `id`.
fn cancel(t: *Transcript, id: i64) !void {
    try t.send(try std.fmt.allocPrint(t.arena(), "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{{\"requestId\":{d},\"reason\":\"The user stopped the request.\"}}}}", .{id}));
}

/// The `params` of a frame.
fn paramsOf(frame: Value) Value {
    return frame.object.get("params").?;
}

/// The id of a request of the bridge.
fn idOf(frame: Value) []const u8 {
    return frame.object.get("id").?.string;
}

/// The number of requests of the bridge to VS Code.
fn bridgeRequestCount(t: *Transcript) !usize {
    var n: usize = 0;
    for (try t.parsedFrames()) |frame| {
        if (frame.object.get("method") != null and frame.object.get("id") != null) n += 1;
    }
    return n;
}

/// The index of the frame number `n` (from 1) with the method `method`, or null.
fn methodIndex(t: *Transcript, method: []const u8, n: usize) !?usize {
    var seen: usize = 0;
    for (try t.parsedFrames(), 0..) |frame, i| {
        const m = mcp.json.getString(frame, "method") orelse continue;
        if (!std.mem.eql(u8, m, method)) continue;
        seen += 1;
        if (seen == n) return i;
    }
    return null;
}

/// The `elicitationId` of each `notifications/elicitation/complete`, in the order of the
/// frames.
fn completedIds(t: *Transcript) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (try t.parsedFrames()) |frame| {
        const m = mcp.json.getString(frame, "method") orelse continue;
        if (!std.mem.eql(u8, m, "notifications/elicitation/complete")) continue;
        try ids.append(t.arena(), paramsOf(frame).object.get("elicitationId").?.string);
    }
    return ids.items;
}

/// The `requestId` of each `notifications/cancelled` of the bridge, in the order of the
/// frames.
fn cancelledIds(t: *Transcript) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (try t.parsedFrames()) |frame| {
        const m = mcp.json.getString(frame, "method") orelse continue;
        if (!std.mem.eql(u8, m, "notifications/cancelled")) continue;
        try ids.append(t.arena(), paramsOf(frame).object.get("requestId").?.string);
    }
    return ids.items;
}

/// Fail when `actual` is not equal to `expected`, item by item.
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    if (expected.len == actual.len) {
        for (expected, actual) |want, got| {
            if (!std.mem.eql(u8, want, got)) break;
        } else return;
    }
    std.debug.print("\nexpected {d} strings:", .{expected.len});
    for (expected) |s| std.debug.print(" \"{s}\"", .{s});
    std.debug.print("\n     got {d} strings:", .{actual.len});
    for (actual) |s| std.debug.print(" \"{s}\"", .{s});
    std.debug.print("\n", .{});
    return error.TestStringsMismatch;
}

/// The member `key` of the `inputResponses` of the upstream request at `index` of the tap.
fn upstreamAnswer(t: *Transcript, tap: *h.Tap, index: usize, key: []const u8) !Value {
    const params = paramsOf(try tap.request(t.arena(), index));
    const responses = params.object.get("inputResponses") orelse {
        std.debug.print("\nupstream request {d} has no inputResponses\n", .{index});
        return error.TestNoInputResponses;
    };
    return responses.object.get(key) orelse {
        std.debug.print("\nupstream request {d} has no input response '{s}'\n", .{ index, key });
        return error.TestNoInputResponse;
    };
}

/// Fail when `actual` is not equal to the JSON text `expected`. The order of the members of an
/// object does not matter, and an integer is equal to a float with the same value.
fn expectJson(t: *Transcript, expected: []const u8, actual: Value) !void {
    const want = try mcp.json.parseTree(t.arena(), expected);
    if (jsonEqual(want, actual)) return;
    std.debug.print("\nexpected {s}\n     got {f}\n", .{ expected, std.json.fmt(actual, .{}) });
    return error.TestJsonMismatch;
}

fn jsonEqual(a: Value, b: Value) bool {
    if (number(a)) |x| return if (number(b)) |y| x == y else false;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (b != .array or b.array.items.len != x.items.len) return false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q)) return false;
            return true;
        },
        .object => |x| {
            if (b != .object or b.object.count() != x.count()) return false;
            var it = x.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse return false;
                if (!jsonEqual(kv.value_ptr.*, other)) return false;
            }
            return true;
        },
        // A number that `number` cannot read.
        .integer, .float, .number_string => false,
    };
}

fn number(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Send `initialize` with the client capabilities `capabilities` (JSON text), then
/// `notifications/initialized`.
fn initializeWith(t: *Transcript, capabilities: []const u8) !void {
    const params = try std.fmt.allocPrint(t.arena(), "{{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{s},\"clientInfo\":{{\"name\":\"test-client\",\"version\":\"1.0.0\"}}}}", .{capabilities});
    _ = try h.expectResult(try t.request(1, "initialize", params));
    try t.send(h.initialized);
    try testing.expectEqual(Frontend.State.ready, t.frontend.state());
}

// -- Transcripts ------------------------------------------------------------------------------

test "each kind of request and notification of the bridge is valid for revision 2025-11-25" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();

    try callTool(t, 2, "ask_form");
    try t.reply(try t.bridgeRequest("elicitation/create", 1), "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("form: accept {\"name\":\"Ada\"}", try resultText(t, 2));
    try callTool(t, 3, "ask_url");
    try t.reply(try t.bridgeRequest("elicitation/create", 2), "{\"action\":\"accept\"}");
    try testing.expectEqualStrings("url: accept", try resultText(t, 3));
    try callTool(t, 4, "sample");
    try t.reply(try t.bridgeRequest("sampling/createMessage", 1), sample_answer);
    try testing.expectEqualStrings("model: Hello", try resultText(t, 4));
    try callTool(t, 5, "list_roots");
    try t.reply(try t.bridgeRequest("roots/list", 1), "{\"roots\":[{\"uri\":\"file:///work\"}]}");
    try testing.expectEqualStrings("roots: file:///work", try resultText(t, 5));
    // VS Code cancels a call while its form waits, thus the bridge cancels its request.
    try callTool(t, 6, "ask_form");
    _ = try t.bridgeRequest("elicitation/create", 3);
    try cancel(t, 6);
    try t.waitIdle();

    // `verify` checks these frames against ElicitRequest, CreateMessageRequest,
    // ListRootsRequest, ElicitationCompleteNotification and CancelledNotification.
    for ([_][]const u8{ "elicitation/create", "sampling/createMessage", "roots/list", "notifications/elicitation/complete", "notifications/cancelled" }) |method| {
        if (try t.methodCount(method) == 0) {
            std.debug.print("\nthe transcript has no frame with the method {s}\n", .{method});
            return error.TestFrameMissing;
        }
    }
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    try t.verify();
}

test "a form: VS Code accepts, declines or cancels, and the upstream server gets the checked answer" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // The first request of the bridge on the connection has the id "b-1".
    try callTool(t, 2, "ask_form");
    const form = try t.bridgeRequest("elicitation/create", 1);
    try testing.expectEqualStrings("b-1", idOf(form));
    const params = paramsOf(form);
    try testing.expectEqualStrings("Tell us about you.", params.object.get("message").?.string);
    try expectJson(t, fixture.ask_form_schema, params.object.get("requestedSchema").?);
    try testing.expect(params.object.get("task") == null);
    try testing.expectEqual(@as(usize, 1), t.frontend.pendingCount());
    try testing.expect((try t.response(2)) == null);

    // Accept: the content goes upstream as VS Code sent it.
    const content = "{\"name\":\"Ada\",\"age\":36,\"subscribe\":true,\"color\":\"green\"}";
    try t.reply(form, "{\"action\":\"accept\",\"content\":" ++ content ++ "}");
    try testing.expectEqualStrings("form: accept " ++ content, try resultText(t, 2));
    try expectJson(t, "{\"action\":\"accept\",\"content\":" ++ content ++ "}", try upstreamAnswer(t, tap, 1, "profile"));
    // The retry round has the tool name of the first round.
    try testing.expectEqualStrings("ask_form", paramsOf(try tap.request(t.arena(), 1)).object.get("name").?.string);

    // Decline: the content of VS Code does not go upstream.
    try callTool(t, 3, "ask_form");
    const declined = try t.bridgeRequest("elicitation/create", 2);
    try testing.expectEqualStrings("b-2", idOf(declined));
    try t.reply(declined, "{\"action\":\"decline\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("form: decline", try resultText(t, 3));
    try expectJson(t, "{\"action\":\"decline\"}", try upstreamAnswer(t, tap, 3, "profile"));

    // Cancel.
    try callTool(t, 4, "ask_form");
    try t.reply(try t.bridgeRequest("elicitation/create", 3), "{\"action\":\"cancel\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("form: cancel", try resultText(t, 4));
    try expectJson(t, "{\"action\":\"cancel\"}", try upstreamAnswer(t, tap, 5, "profile"));

    // An error of VS Code becomes cancel upstream. The call does not fail.
    try callTool(t, 5, "ask_form");
    try replyError(t, try t.bridgeRequest("elicitation/create", 4), "{\"code\":-32603,\"message\":\"The form failed.\"}");
    try testing.expectEqualStrings("form: cancel", try resultText(t, 5));
    try expectJson(t, "{\"action\":\"cancel\"}", try upstreamAnswer(t, tap, 7, "profile"));

    try t.waitIdle();
    try testing.expectEqual(@as(usize, 8), tap.count());
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    try t.verify();
}

test "accepted content that is not valid against the requestedSchema fails the call, and nothing goes upstream" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    const content_detail = "input request 'profile': the accepted content is not valid against the requestedSchema";
    const shape_detail = "input request 'profile': the elicitation result does not have the shape of the schema";
    const cases = [_]struct { answer: []const u8, detail: []const u8 }{
        // The required name is missing.
        .{ .answer = "{\"action\":\"accept\",\"content\":{\"age\":36}}", .detail = content_detail },
        .{ .answer = "{\"action\":\"accept\"}", .detail = content_detail },
        // The name is shorter than minLength, or it is not a string.
        .{ .answer = "{\"action\":\"accept\",\"content\":{\"name\":\"\"}}", .detail = content_detail },
        .{ .answer = "{\"action\":\"accept\",\"content\":{\"name\":7}}", .detail = content_detail },
        // The age is above the maximum.
        .{ .answer = "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\",\"age\":200}}", .detail = content_detail },
        // The color is not in the enum.
        .{ .answer = "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\",\"color\":\"purple\"}}", .detail = content_detail },
        // The action is not known.
        .{ .answer = "{\"action\":\"maybe\"}", .detail = shape_detail },
    };
    for (cases, 0..) |case, i| {
        const id: i64 = @intCast(i + 2);
        try callTool(t, id, "ask_form");
        try t.reply(try t.bridgeRequest("elicitation/create", i + 1), case.answer);
        const response = try t.waitResponse(id);
        try h.expectError(response, -32603, invalid_answer_message, "invalid_client_answer");
        try testing.expectEqualStrings(case.detail, h.errorDetail(response).?);
        // Only the first round went upstream. The content that is not valid did not.
        try t.waitIdle();
        try testing.expectEqual(i + 1, tap.count());
    }
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    try t.verify();
}

test "a URL: the elicitationId, no content upstream, and the complete notification after the upstream round" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "ask_url");
    const url = try t.bridgeRequest("elicitation/create", 1);
    const params = paramsOf(url);
    try testing.expectEqualStrings("url", params.object.get("mode").?.string);
    try testing.expectEqualStrings(fixture.auth_url, params.object.get("url").?.string);
    try testing.expectEqualStrings("Sign in to continue.", params.object.get("message").?.string);
    const first_id = params.object.get("elicitationId").?.string;
    try testing.expect(first_id.len > 0);
    try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/elicitation/complete"));

    // VS Code accepts with content. A URL answer never has content upstream.
    try t.reply(url, "{\"action\":\"accept\",\"content\":{\"token\":\"secret\"}}");
    try testing.expectEqualStrings("url: accept", try resultText(t, 2));
    try expectJson(t, "{\"action\":\"accept\"}", try upstreamAnswer(t, tap, 1, "auth"));
    // The upstream round after the accept does not ask for the URL. Thus VS Code gets the
    // complete notification with the same id, after the request and before the response.
    try expectStrings(&.{first_id}, try completedIds(t));
    const request_index = (try methodIndex(t, "elicitation/create", 1)).?;
    const complete_index = (try methodIndex(t, "notifications/elicitation/complete", 1)).?;
    try testing.expect(request_index < complete_index);
    try testing.expect(complete_index < (try t.responseIndex(2)).?);

    // Decline: no complete notification. The URL of the new call has a new id.
    try callTool(t, 3, "ask_url");
    const declined = try t.bridgeRequest("elicitation/create", 2);
    const second_id = paramsOf(declined).object.get("elicitationId").?.string;
    try testing.expect(!std.mem.eql(u8, first_id, second_id));
    try t.reply(declined, "{\"action\":\"decline\",\"content\":{\"token\":\"secret\"}}");
    try testing.expectEqualStrings("url: decline", try resultText(t, 3));
    try expectJson(t, "{\"action\":\"decline\"}", try upstreamAnswer(t, tap, 3, "auth"));
    try expectStrings(&.{first_id}, try completedIds(t));

    // ask_url_twice with complete: true gives the result in round 2.
    try callToolArgs(t, 4, "ask_url_twice", "{\"complete\":true}");
    const third = try t.bridgeRequest("elicitation/create", 3);
    const third_id = paramsOf(third).object.get("elicitationId").?.string;
    try t.reply(third, "{\"action\":\"accept\"}");
    try testing.expectEqualStrings("url twice: accept", try resultText(t, 4));
    try expectStrings(&.{ first_id, third_id }, try completedIds(t));
    try t.verify();
}

test "a URL that the user accepted and that a later round asks for again gets the Continue form" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "ask_url_twice");
    const url = try t.bridgeRequest("elicitation/create", 1);
    const elicitation_id = paramsOf(url).object.get("elicitationId").?.string;
    try t.reply(url, "{\"action\":\"accept\"}");

    // Round 2 asks for the same URL. VS Code gets a form with one required choice, and not
    // the URL again.
    const again = try t.bridgeRequest("elicitation/create", 2);
    const form = paramsOf(again);
    try testing.expectEqualStrings("form", form.object.get("mode").?.string);
    try testing.expect(form.object.get("url") == null);
    try testing.expect(form.object.get("elicitationId") == null);
    try testing.expect(form.object.get("message").?.string.len > 0);
    const schema = form.object.get("requestedSchema").?;
    const properties = schema.object.get("properties").?;
    // VS Code reads the first property without a check, thus the schema is never empty.
    try testing.expectEqual(@as(usize, 1), properties.object.count());
    const choice = properties.object.get(input.continue_property).?;
    try expectJson(t, "[\"" ++ input.continue_value ++ "\"]", choice.object.get("enum").?);
    try expectJson(t, "[\"" ++ input.continue_property ++ "\"]", schema.object.get("required").?);
    // Round 2 got the accept of the URL. The server still asks for it, thus no complete
    // notification yet.
    try expectJson(t, "{\"action\":\"accept\"}", try upstreamAnswer(t, tap, 1, "auth"));
    try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/elicitation/complete"));

    // Continue answers the URL with accept and without the content of the form.
    try t.reply(again, "{\"action\":\"accept\",\"content\":{\"" ++ input.continue_property ++ "\":\"" ++ input.continue_value ++ "\"}}");
    try testing.expectEqualStrings("url twice: accept", try resultText(t, 2));
    try expectJson(t, "{\"action\":\"accept\"}", try upstreamAnswer(t, tap, 2, "auth"));
    try expectStrings(&.{elicitation_id}, try completedIds(t));
    try testing.expect((try methodIndex(t, "notifications/elicitation/complete", 1)).? < (try t.responseIndex(2)).?);
    // VS Code opened the URL one time only.
    var url_mode: usize = 0;
    for (try t.parsedFrames()) |frame| {
        const method = mcp.json.getString(frame, "method") orelse continue;
        if (!std.mem.eql(u8, method, "elicitation/create")) continue;
        if (std.mem.eql(u8, paramsOf(frame).object.get("mode").?.string, "url")) url_mode += 1;
    }
    try testing.expectEqual(@as(usize, 1), url_mode);

    // The user declines the Continue form: the upstream server gets decline.
    try callTool(t, 3, "ask_url_twice");
    try t.reply(try t.bridgeRequest("elicitation/create", 3), "{\"action\":\"accept\"}");
    const declined = try t.bridgeRequest("elicitation/create", 4);
    try testing.expectEqualStrings("form", paramsOf(declined).object.get("mode").?.string);
    try t.reply(declined, "{\"action\":\"decline\"}");
    try testing.expectEqualStrings("url twice: decline", try resultText(t, 3));
    try expectJson(t, "{\"action\":\"decline\"}", try upstreamAnswer(t, tap, 5, "auth"));
    try t.verify();
}

test "a client without form mode gets the same URL again in the next round" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    try initializeWith(t, "{\"elicitation\":{\"url\":{}}}");
    const client = try t.upstreamClient();
    try testing.expect(client.options.capabilities.hasElicitation(.url));
    try testing.expect(!client.options.capabilities.hasElicitation(.form));

    try callTool(t, 2, "ask_url_twice");
    const first = try t.bridgeRequest("elicitation/create", 1);
    const elicitation_id = paramsOf(first).object.get("elicitationId").?.string;
    try t.reply(first, "{\"action\":\"accept\"}");
    const second = try t.bridgeRequest("elicitation/create", 2);
    try testing.expectEqualStrings("url", paramsOf(second).object.get("mode").?.string);
    try testing.expectEqualStrings(fixture.auth_url, paramsOf(second).object.get("url").?.string);
    try testing.expectEqualStrings(elicitation_id, paramsOf(second).object.get("elicitationId").?.string);
    try t.reply(second, "{\"action\":\"accept\"}");
    try testing.expectEqualStrings("url twice: accept", try resultText(t, 2));
    try expectStrings(&.{elicitation_id}, try completedIds(t));
    try t.verify();
}

test "the round after an accepted URL asks for a form: the complete notification comes before the form" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "ask_url");
    const url = try t.bridgeRequest("elicitation/create", 1);
    const elicitation_id = paramsOf(url).object.get("elicitationId").?.string;
    // After the sign-in, a scripted server asks for a form and no longer for the URL.
    tap.setScript(.{ .result = name_round_with_state });
    try t.reply(url, "{\"action\":\"accept\"}");
    const form = try t.bridgeRequest("elicitation/create", 2);
    tap.setScript(.{ .result = done_result });
    try testing.expectEqualStrings("form", paramsOf(form).object.get("mode").?.string);
    try expectStrings(&.{elicitation_id}, try completedIds(t));
    try testing.expect((try methodIndex(t, "notifications/elicitation/complete", 1)).? < (try methodIndex(t, "elicitation/create", 2)).?);

    try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("done", try resultText(t, 2));
    try expectJson(t, "{\"action\":\"accept\"}", try upstreamAnswer(t, tap, 1, "auth"));
    try expectJson(t, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}", try upstreamAnswer(t, tap, 2, "name"));
    // One notification for the URL.
    try expectStrings(&.{elicitation_id}, try completedIds(t));
    tap.setScript(.forward);
    try t.verify();
}

test "an accepted URL gets the complete notification when the call fails or VS Code cancels it" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // The upstream round after the accept fails. VS Code gets the notification before the
    // error, because no later round asks for the URL.
    try callTool(t, 2, "ask_url");
    const url = try t.bridgeRequest("elicitation/create", 1);
    const first_id = paramsOf(url).object.get("elicitationId").?.string;
    tap.setScript(.{ .rpc_error = "{\"code\":-32603,\"message\":\"The sign-in failed.\"}" });
    try t.reply(url, "{\"action\":\"accept\"}");
    try h.expectError(try t.waitResponse(2), -32603, "The sign-in failed.", null);
    try expectStrings(&.{first_id}, try completedIds(t));
    try testing.expect((try methodIndex(t, "notifications/elicitation/complete", 1)).? < (try t.responseIndex(2)).?);

    // VS Code cancels the call during the upstream round after the accept. The call gets no
    // response, but VS Code gets the notification.
    tap.setScript(.forward);
    try callTool(t, 3, "ask_url");
    const second = try t.bridgeRequest("elicitation/create", 2);
    const second_id = paramsOf(second).object.get("elicitationId").?.string;
    tap.setScript(.wait);
    try t.reply(second, "{\"action\":\"accept\"}");
    try tap.waitStarted(4);
    try cancel(t, 3);
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 0), try t.responseCount(3));
    try expectStrings(&.{ first_id, second_id }, try completedIds(t));
    tap.setScript(.forward);
    try t.verify();
}

test "a form without a property goes to VS Code as a form with one choice" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    const cases = [_]struct { answer: []const u8, upstream: []const u8 }{
        // Accept: the upstream server gets empty content, which is valid for its form.
        .{ .answer = "{\"action\":\"accept\",\"content\":{\"" ++ input.continue_property ++ "\":\"" ++ input.continue_value ++ "\"}}", .upstream = "{\"action\":\"accept\",\"content\":{}}" },
        .{ .answer = "{\"action\":\"decline\"}", .upstream = "{\"action\":\"decline\"}" },
        .{ .answer = "{\"action\":\"cancel\"}", .upstream = "{\"action\":\"cancel\"}" },
    };
    for (cases, 0..) |case, i| {
        const id: i64 = @intCast(i + 2);
        tap.setScript(.{ .result = confirm_round });
        try callTool(t, id, "confirm");
        const form = try t.bridgeRequest("elicitation/create", i + 1);
        tap.setScript(.{ .result = done_result });
        // VS Code gets the message of the server and one required choice.
        const params = paramsOf(form);
        try testing.expectEqualStrings("form", params.object.get("mode").?.string);
        try testing.expectEqualStrings("Delete the file?", params.object.get("message").?.string);
        const schema = params.object.get("requestedSchema").?;
        try testing.expectEqual(@as(usize, 1), schema.object.get("properties").?.object.count());
        try testing.expect(schema.object.get("properties").?.object.get(input.continue_property) != null);
        try expectJson(t, "[\"" ++ input.continue_property ++ "\"]", schema.object.get("required").?);
        try t.reply(form, case.answer);
        try testing.expectEqualStrings("done", try resultText(t, id));
        try expectJson(t, case.upstream, try upstreamAnswer(t, tap, 2 * i + 1, "confirm"));
    }
    tap.setScript(.forward);
    try t.verify();
}

test "a URL that the bridge refuses never goes to VS Code, and the upstream server gets decline" {
    // The warnings about the refused URLs are expected.
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // The fixture server asks for a file URL.
    try callTool(t, 2, "ask_bad_url");
    try testing.expectEqualStrings("url: decline", try resultText(t, 2));
    try testing.expectEqual(@as(usize, 0), try bridgeRequestCount(t));
    try expectJson(t, "{\"action\":\"decline\"}", try upstreamAnswer(t, tap, 1, "file"));
    try testing.expectEqual(@as(usize, 2), tap.count());

    // A scripted server asks for many URLs and a form in one round. VS Code gets the three
    // loopback URLs and the form, all at one time.
    tap.setScript(.{ .result = refused_urls_round });
    try callTool(t, 3, "open_pages");
    const ip4 = try t.bridgeRequest("elicitation/create", 1);
    const ip6 = try t.bridgeRequest("elicitation/create", 2);
    const local = try t.bridgeRequest("elicitation/create", 3);
    const name = try t.bridgeRequest("elicitation/create", 4);
    tap.setScript(.{ .result = done_result });
    try testing.expectEqual(@as(usize, 4), try bridgeRequestCount(t));
    try testing.expectEqual(@as(usize, 4), t.frontend.pendingCount());
    try testing.expectEqualStrings("http://127.0.0.1:8080/callback", paramsOf(ip4).object.get("url").?.string);
    try testing.expectEqualStrings("http://[::1]:8080/callback", paramsOf(ip6).object.get("url").?.string);
    try testing.expectEqualStrings("http://localhost:8080/callback", paramsOf(local).object.get("url").?.string);
    try testing.expectEqualStrings("form", paramsOf(name).object.get("mode").?.string);
    const ip4_id = paramsOf(ip4).object.get("elicitationId").?.string;
    try testing.expect(!std.mem.eql(u8, ip4_id, paramsOf(ip6).object.get("elicitationId").?.string));

    try t.reply(ip4, "{\"action\":\"accept\"}");
    try t.reply(ip6, "{\"action\":\"decline\"}");
    try t.reply(local, "{\"action\":\"cancel\"}");
    try t.reply(name, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("done", try resultText(t, 3));
    for (refused_keys) |key| try expectJson(t, "{\"action\":\"decline\"}", try upstreamAnswer(t, tap, 3, key));
    try expectJson(t, "{\"action\":\"accept\"}", try upstreamAnswer(t, tap, 3, "ip4"));
    try expectJson(t, "{\"action\":\"decline\"}", try upstreamAnswer(t, tap, 3, "ip6"));
    try expectJson(t, "{\"action\":\"cancel\"}", try upstreamAnswer(t, tap, 3, "local"));
    try expectJson(t, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}", try upstreamAnswer(t, tap, 3, "name"));
    try testing.expectEqualStrings("s-1", paramsOf(try tap.request(t.arena(), 3)).object.get("requestState").?.string);
    // Only the accepted URL gets the complete notification.
    try expectStrings(&.{ip4_id}, try completedIds(t));
    try t.verify();
}

test "sampling: the request to VS Code, its answer upstream, and the refusal of VS Code" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "sample");
    const request = try t.bridgeRequest("sampling/createMessage", 1);
    try testing.expectEqualStrings("b-1", idOf(request));
    const params = paramsOf(request);
    try expectJson(t, "[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Say hello.\"}}]", params.object.get("messages").?);
    try testing.expectEqual(@as(i64, 50), params.object.get("maxTokens").?.integer);
    for ([_][]const u8{ "tools", "toolChoice", "task" }) |key| try testing.expect(params.object.get(key) == null);
    // The result of VS Code goes upstream as it is.
    try t.reply(request, sample_answer);
    try testing.expectEqualStrings("model: Hello", try resultText(t, 2));
    try expectJson(t, sample_answer, try upstreamAnswer(t, tap, 1, "model"));

    // VS Code refuses the request with -32000. The call fails with that error, and the
    // upstream server gets no retry round.
    try callTool(t, 3, "sample");
    try replyError(t, try t.bridgeRequest("sampling/createMessage", 2), "{\"code\":-32000,\"message\":\"The user refused the sampling request.\",\"data\":{\"reason\":\"refused\"}}");
    const refused = try t.waitResponse(3);
    try h.expectError(refused, -32000, "The user refused the sampling request.", null);
    try expectJson(t, "{\"reason\":\"refused\"}", refused.object.get("error").?.object.get("data").?);
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 3), tap.count());

    // A result that is not a CreateMessageResult fails the call.
    try callTool(t, 4, "sample");
    try t.reply(try t.bridgeRequest("sampling/createMessage", 3), "{\"content\":\"Hello\"}");
    const shape = try t.waitResponse(4);
    try h.expectError(shape, -32603, invalid_answer_message, "invalid_client_answer");
    try testing.expectEqualStrings("input request 'model': the sampling result does not have the shape of the schema", h.errorDetail(shape).?);

    // A line with a lone surrogate and the id of the request also fails the call.
    try callTool(t, 5, "sample");
    try t.reply(try t.bridgeRequest("sampling/createMessage", 4), "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"\\ud800\"},\"model\":\"m\"}");
    const surrogate = try t.waitResponse(5);
    try h.expectError(surrogate, -32603, invalid_answer_message, "invalid_client_answer");
    try testing.expectEqualStrings("input request 'model': the answer of the client is not a valid message", h.errorDetail(surrogate).?);
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 5), tap.count());
    try t.verify();
}

test "sampling with tools: VS Code declares no sampling.tools, thus VS Code never gets it" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // The bridge declares no sampling.tools upstream, thus the zig-sdk server does not ask.
    // Its error goes to VS Code unchanged.
    try callTool(t, 2, "sample_tools");
    try h.expectError(try t.waitResponse(2), -32021, null, null);
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 1), tap.count());

    // A server that does not obey the rules asks anyway: with tools, with toolChoice, or with
    // tool content in the messages. The bridge fails the call and names the key.
    for ([_][]const u8{ sampling_with_tools, sampling_with_tool_choice, sampling_with_tool_content }, 0..) |round, i| {
        tap.setScript(.{ .result = round });
        const response = try t.request(@intCast(i + 3), "tools/call", "{\"name\":\"sample_tools\"}");
        try h.expectError(response, -32603, undeclared_message, "undeclared_input_request");
        try testing.expectEqualStrings("input request 'model': sampling with tools needs sampling.tools, and the client did not declare it", h.errorDetail(response).?);
        try testing.expectEqual(i + 2, tap.count());
    }
    try testing.expectEqual(@as(usize, 0), try bridgeRequestCount(t));
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());

    // includeContext is not a failure. VS Code can ignore it.
    tap.setScript(.{ .result = sampling_with_context });
    try callTool(t, 6, "sample");
    const request = try t.bridgeRequest("sampling/createMessage", 1);
    tap.setScript(.{ .result = done_result });
    try testing.expectEqualStrings("thisServer", paramsOf(request).object.get("includeContext").?.string);
    try t.reply(request, sample_answer);
    try testing.expectEqualStrings("done", try resultText(t, 6));
    try t.verify();
}

test "roots: VS Code's roots that are not file URIs do not go upstream, and an error of VS Code fails the call" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "list_roots");
    const request = try t.bridgeRequest("roots/list", 1);
    if (request.object.get("params")) |p| try testing.expect(p.object.get("task") == null);
    try t.reply(request, "{\"roots\":[{\"uri\":\"file:///work\",\"name\":\"work\"},{\"uri\":\"vscode-vfs://github/microsoft/vscode\"},{\"uri\":\"untitled:Untitled-1\"},{\"uri\":\"file:///other\"}]}");
    try testing.expectEqualStrings("roots: file:///work\nfile:///other", try resultText(t, 2));
    try expectJson(t, "{\"roots\":[{\"uri\":\"file:///work\",\"name\":\"work\"},{\"uri\":\"file:///other\"}]}", try upstreamAnswer(t, tap, 1, "roots"));

    // An error of VS Code fails the call with that error.
    try callTool(t, 3, "list_roots");
    try replyError(t, try t.bridgeRequest("roots/list", 2), "{\"code\":-32603,\"message\":\"The workspace has no folders.\",\"data\":{\"folders\":0}}");
    const failed = try t.waitResponse(3);
    try h.expectError(failed, -32603, "The workspace has no folders.", null);
    try expectJson(t, "{\"folders\":0}", failed.object.get("error").?.object.get("data").?);
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 3), tap.count());
    try t.verify();
}

test "the input requests of one round go to VS Code at one time, and a round above the limit sends nothing" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    // Both requests go out before VS Code answers one of them.
    try callTool(t, 2, "multi");
    const name = try t.bridgeRequest("elicitation/create", 1);
    const roots = try t.bridgeRequest("roots/list", 1);
    try testing.expectEqualStrings("b-1", idOf(name));
    try testing.expectEqualStrings("b-2", idOf(roots));
    try testing.expectEqual(@as(usize, 2), t.frontend.pendingCount());
    // VS Code answers in the other order. The call waits for both answers.
    try t.reply(roots, "{\"roots\":[{\"uri\":\"file:///work\"}]}");
    try testing.expect((try t.response(2)) == null);
    try testing.expectEqual(@as(usize, 1), tap.count());
    try t.reply(name, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("name: Ada (accept); roots: 1", try resultText(t, 2));
    try expectJson(t, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}", try upstreamAnswer(t, tap, 1, "name"));
    try expectJson(t, "{\"roots\":[{\"uri\":\"file:///work\"}]}", try upstreamAnswer(t, tap, 1, "roots"));

    // More input requests than the limit of one round: VS Code gets none of them.
    try callTool(t, 3, "many_inputs");
    const many = try t.waitResponse(3);
    try h.expectError(many, -32603, too_many_message, "too_many_input_requests");
    const detail = try std.fmt.allocPrint(t.arena(), "{d} input requests in one round, limit: {d}", .{ fixture.many_inputs_count, input.default_max_requests_per_round });
    try testing.expectEqualStrings(detail, h.errorDetail(many).?);
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 2), try bridgeRequestCount(t));
    try testing.expectEqual(@as(usize, 3), tap.count());
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    try t.verify();
}

test "prompts/get with a form" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    const cases = [_]struct { answer: []const u8, text: []const u8 }{
        .{ .answer = "{\"action\":\"accept\",\"content\":{\"name\":\"Bo\"}}", .text = "Hello, Bo." },
        .{ .answer = "{\"action\":\"decline\"}", .text = "Hello, nobody." },
    };
    for (cases, 0..) |case, i| {
        const id: i64 = @intCast(i + 2);
        try t.send(try h.requestLine(t.arena(), id, "prompts/get", "{\"name\":\"ask_name\"}"));
        const form = try t.bridgeRequest("elicitation/create", i + 1);
        try testing.expectEqualStrings("Your name?", paramsOf(form).object.get("message").?.string);
        try t.reply(form, case.answer);
        const prompt = try h.expectResult(try t.waitResponse(id));
        const message = prompt.object.get("messages").?.array.items[0];
        try testing.expectEqualStrings(case.text, message.object.get("content").?.object.get("text").?.string);
        // The retry round is a prompts/get with the answer.
        const retry = try tap.request(t.arena(), 2 * i + 1);
        try testing.expectEqualStrings("prompts/get", retry.object.get("method").?.string);
        try expectJson(t, case.answer, try upstreamAnswer(t, tap, 2 * i + 1, "name"));
    }
    try t.verify();
}

test "VS Code cancels a tool call while the bridge waits for its answers" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "ask_form");
    const form = try t.bridgeRequest("elicitation/create", 1);
    try testing.expectEqualStrings("b-1", idOf(form));
    try cancel(t, 2);
    try t.waitIdle();
    // The bridge cancels its own request, and VS Code gets no response for the call.
    try expectStrings(&.{"b-1"}, try cancelledIds(t));
    try testing.expectEqual(@as(usize, 0), try t.responseCount(2));
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    // The upstream server got round 1 only.
    try testing.expectEqual(@as(usize, 1), tap.count());
    try testing.expectEqual(@as(?ExchangeError, null), tap.exchange(0).outcome);

    // VS Code ignores the cancellation and answers late. The bridge writes nothing.
    const before = t.count();
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"result\":{\"action\":\"cancel\"}}");
    try t.send("{\"jsonrpc\":\"2.0\",\"id\":\"b-1\",\"error\":{\"code\":-32603,\"message\":\"Canceled\"}}");
    try testing.expectEqual(before, t.count());
    try testing.expectEqual(@as(usize, 1), tap.count());
    const ping = try h.expectResult(try t.requestInline(3, "ping", null));
    try testing.expectEqual(@as(usize, 0), ping.object.count());

    // A round with two requests: the bridge cancels both.
    try callTool(t, 4, "multi");
    _ = try t.bridgeRequest("elicitation/create", 2);
    _ = try t.bridgeRequest("roots/list", 1);
    try cancel(t, 4);
    try t.waitIdle();
    const ids = try cancelledIds(t);
    try testing.expectEqual(@as(usize, 3), ids.len);
    for ([_][]const u8{ "b-2", "b-3" }) |want| {
        var found = false;
        for (ids[1..]) |id| found = found or std.mem.eql(u8, id, want);
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 0), try t.responseCount(4));
    // Round 1 of each call, and no retry round.
    try testing.expectEqual(@as(usize, 2), tap.count());
    try t.verify();
}

test "VS Code cancels a tool call during the retry round: the upstream server gets the cancellation" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "ask_form");
    const form = try t.bridgeRequest("elicitation/create", 1);
    // The retry round waits for its cancellation upstream.
    tap.setScript(.wait);
    try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try tap.waitStarted(2);
    try cancel(t, 2);
    try t.waitIdle();
    try testing.expectEqual(@as(usize, 0), try t.responseCount(2));
    try testing.expectEqual(@as(?ExchangeError, error.Canceled), tap.exchange(1).outcome);
    // The bridge has no request without an answer, thus it sends no cancellation.
    try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/cancelled"));
    tap.setScript(.forward);
    _ = try h.expectResult(try t.requestInline(3, "ping", null));
    try t.verify();
}

test "VS Code cancels a tool call after its result: the bridge sends nothing" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();

    try callTool(t, 2, "ask_form");
    try t.reply(try t.bridgeRequest("elicitation/create", 1), "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("form: accept {\"name\":\"Ada\"}", try resultText(t, 2));
    try t.waitIdle();
    const before = t.count();
    try cancel(t, 2);
    try testing.expectEqual(before, t.count());
    try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/cancelled"));
    try testing.expectEqual(@as(usize, 1), try t.responseCount(2));
    _ = try h.expectResult(try t.requestInline(3, "ping", null));
    try t.verify();
}

test "the end of the input while a request of the bridge has no answer: run returns at once" {
    // A long grace time: without the wake of the waiting task, `run` returns after it.
    const t = try Transcript.create(.{ .frontend = .{ .shutdown_grace = .fromSeconds(30) } });
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "ask_form");
    _ = try t.bridgeRequest("elicitation/create", 1);
    try testing.expectEqual(@as(usize, 1), t.frontend.pendingCount());
    // VS Code closes stdin. `run` reads the end of the input at once.
    const started = Io.Clock.Timestamp.now(t.io, .awake);
    try testing.expectEqual(Frontend.RunResult.eof, try t.runLines("", 16));
    const elapsed_ms = started.durationTo(Io.Clock.Timestamp.now(t.io, .awake)).raw.toMilliseconds();
    if (elapsed_ms >= 2000) {
        std.debug.print("\nrun returned after {d} ms\n", .{elapsed_ms});
        return error.TestSlowShutdown;
    }
    try testing.expectEqual(Frontend.State.closing, t.frontend.state());
    try testing.expectEqual(@as(usize, 0), t.frontend.inFlightCount());
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    try testing.expectEqual(@as(usize, 0), try t.responseCount(2));
    try expectStrings(&.{"b-1"}, try cancelledIds(t));
    try testing.expectEqual(@as(usize, 1), tap.count());
    try t.verify();
}

test "VS Code does not answer in time: the call fails, and the bridge cancels its request" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{ .frontend = .{ .timeouts = .{ .input = .fromMilliseconds(300) } } });
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();

    try callTool(t, 2, "ask_form");
    const form = try t.bridgeRequest("elicitation/create", 1);
    const late = try t.waitResponse(2);
    try h.expectError(late, -32603, input_timeout_message, "input_timeout");
    try testing.expectEqualStrings("no answers in 300 ms (input requests of the round: 1)", h.errorDetail(late).?);
    try t.waitIdle();
    try expectStrings(&.{"b-1"}, try cancelledIds(t));
    try testing.expect((try methodIndex(t, "notifications/cancelled", 1)).? < (try t.responseIndex(2)).?);
    try testing.expectEqual(@as(usize, 1), tap.count());
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    // The late answer gets nothing.
    const before = t.count();
    try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqual(before, t.count());
    try t.verify();
}

test "answers with an unknown, numeric or null id get nothing, and a bad answer line resolves its request" {
    const t = try Transcript.create(.{ .frontend = .{ .max_line_bytes = 2048, .json_max_depth = 10 } });
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();
    const a = t.arena();

    try callTool(t, 2, "ask_form");
    const form = try t.bridgeRequest("elicitation/create", 1);
    try testing.expectEqualStrings("b-1", idOf(form));
    const before = t.count();
    const dropped = [_][]const u8{
        // An id that the bridge did not send, and an id without the prefix of the profile.
        "{\"jsonrpc\":\"2.0\",\"id\":\"b-99\",\"result\":{\"action\":\"accept\",\"content\":{\"name\":\"Eve\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"b-99\",\"error\":{\"code\":-32603,\"message\":\"Failed.\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"x-1\",\"result\":{\"action\":\"accept\"}}",
        // Numeric ids, also the id of the call in flight.
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"action\":\"accept\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"action\":\"accept\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1.5,\"result\":{\"action\":\"accept\"}}",
        // The id null.
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{\"action\":\"accept\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}",
    };
    for (dropped) |line| try t.send(line);
    try testing.expectEqual(before, t.count());
    try testing.expectEqual(@as(usize, 1), t.frontend.pendingCount());
    try testing.expectEqual(@as(usize, 1), tap.count());
    try testing.expect((try t.response(2)) == null);

    // The answer with the right id still reaches its request. A second answer gets nothing.
    try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("form: accept {\"name\":\"Ada\"}", try resultText(t, 2));
    try t.waitIdle();
    const after = t.count();
    try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Bo\"}}");
    try testing.expectEqual(after, t.count());
    try testing.expectEqual(@as(usize, 2), tap.count());

    // A line with the id of a request of the bridge that is not a valid message resolves the
    // request as an error. VS Code gets no error for it, and the upstream server gets cancel.
    const deep = "[" ** 12 ++ "\"x\"" ++ "]" ** 12;
    const bad_answers = [_][]const u8{
        // A lone surrogate, which JSON.stringify of VS Code can write.
        "{\"action\":\"accept\",\"content\":{\"name\":\"\\ud800\"}}",
        // Bytes that are not UTF-8.
        "{\"action\":\"accept\",\"content\":{\"name\":\"\xff\xfe\"}}",
        // Nesting deeper than the limit.
        "{\"action\":\"accept\",\"content\":{\"name\":" ++ deep ++ "}}",
        // A line longer than the limit.
        try std.fmt.allocPrint(a, "{{\"action\":\"accept\",\"content\":{{\"name\":\"{s}\"}}}}", .{"y" ** 3000}),
    };
    for (bad_answers, 0..) |answer, i| {
        const id: i64 = @intCast(i + 3);
        try callTool(t, id, "ask_form");
        const request = try t.bridgeRequest("elicitation/create", i + 2);
        const frames_before = t.count();
        try t.reply(request, answer);
        try testing.expectEqualStrings("form: cancel", try resultText(t, id));
        try expectJson(t, "{\"action\":\"cancel\"}", try upstreamAnswer(t, tap, 2 * i + 3, "profile"));
        // The only new frame is the response of the call.
        try t.waitIdle();
        try testing.expectEqual(frames_before + 1, t.count());
    }
    for (try t.parsedFrames()) |frame| if (frame.object.get("id")) |id| try testing.expect(id != .null);
    try testing.expectEqual(@as(usize, 0), t.frontend.pendingCount());
    try t.verify();
}

test "a refused requestState: tools/call gets an isError result, and prompts/get and resources/read get an error" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();
    const a = t.arena();

    // Round 1 of ask_url_twice has a sealed requestState. In round 2, a scripted server
    // refuses it, as a server does after a restart.
    try callTool(t, 2, "ask_url_twice");
    const url = try t.bridgeRequest("elicitation/create", 1);
    tap.setScript(.{ .rpc_error = refused_state });
    try t.reply(url, "{\"action\":\"accept\"}");
    const result = try h.expectResult(try t.waitResponse(2));
    try testing.expect(result.object.get("isError").?.bool);
    const content = result.object.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 1), content.len);
    const text = content[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "Invalid or expired requestState") != null);
    try testing.expect(std.mem.endsWith(u8, text, "Run the tool again."));
    // The refused round had the state of round 1 and the answer.
    const refused_round = paramsOf(try tap.request(a, 1));
    try testing.expect(refused_round.object.get("requestState").? == .string);
    try expectJson(t, "{\"action\":\"accept\"}", try upstreamAnswer(t, tap, 1, "auth"));

    // prompts/get and resources/read: an error with the code and the data of the upstream
    // server, and the same text.
    const requests = [_]struct { method: []const u8, params: []const u8 }{
        .{ .method = "prompts/get", .params = "{\"name\":\"ask_name\"}" },
        .{ .method = "resources/read", .params = "{\"uri\":\"" ++ h.readme_uri ++ "\"}" },
    };
    for (requests, 0..) |req, i| {
        const id: i64 = @intCast(i + 3);
        tap.setScript(.{ .result = name_round_with_state });
        try t.send(try h.requestLine(a, id, req.method, req.params));
        const form = try t.bridgeRequest("elicitation/create", i + 2);
        tap.setScript(.{ .rpc_error = refused_state });
        try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
        const failed = try t.waitResponse(id);
        try h.expectError(failed, -32602, null, null);
        const err = failed.object.get("error").?;
        const message = err.object.get("message").?.string;
        try testing.expect(std.mem.indexOf(u8, message, "Invalid or expired requestState") != null);
        try testing.expect(std.mem.endsWith(u8, message, "Send the request again."));
        try expectJson(t, "{\"reason\":\"invalid_request_state\"}", err.object.get("data").?);
        try testing.expectEqualStrings("sealed-state-1", paramsOf(try tap.request(a, 2 * i + 3)).object.get("requestState").?.string);
    }

    // -32602 for a round without requestState goes to VS Code unchanged.
    tap.setScript(.forward);
    try callTool(t, 5, "ask_form");
    const form = try t.bridgeRequest("elicitation/create", 4);
    tap.setScript(.{ .rpc_error = "{\"code\":-32602,\"message\":\"Invalid params\",\"data\":{\"field\":\"inputResponses\"}}" });
    try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    const plain = try t.waitResponse(5);
    try h.expectError(plain, -32602, "Invalid params", null);
    try expectJson(t, "{\"field\":\"inputResponses\"}", plain.object.get("error").?.object.get("data").?);
    tap.setScript(.forward);
    try t.verify();
}

test "input kinds that the client did not declare never go to the client" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    const t = try Transcript.create(.{});
    defer t.destroy();
    // A client that declares only form mode.
    try initializeWith(t, "{\"elicitation\":{\"form\":{}}}");
    const client = try t.upstreamClient();
    try testing.expect(client.options.capabilities.hasElicitation(.form));
    try testing.expect(!client.options.capabilities.hasElicitation(.url));
    try testing.expect(client.options.capabilities.sampling == null);
    try testing.expect(client.options.capabilities.roots == null);
    const tap = try t.tapUpstream();

    // The zig-sdk server does not ask for a kind that the bridge did not declare.
    for ([_][]const u8{ "ask_url", "sample", "list_roots" }, 0..) |tool, i| {
        const id: i64 = @intCast(i + 2);
        try callTool(t, id, tool);
        try h.expectError(try t.waitResponse(id), -32021, null, null);
    }

    // A server that does not obey the rules asks anyway. The bridge fails the call and names
    // the key and the capability.
    const rounds = [_]struct { result: []const u8, detail: []const u8 }{
        .{
            .result = url_round,
            .detail = "input request 'auth': the client did not declare elicitation.url",
        },
        .{
            .result = "{\"resultType\":\"input_required\",\"inputRequests\":{\"model\":{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Hi\"}}],\"maxTokens\":5}}}}",
            .detail = "input request 'model': the client did not declare sampling",
        },
        .{
            .result = "{\"resultType\":\"input_required\",\"inputRequests\":{\"where\":{\"method\":\"roots/list\"}}}",
            .detail = "input request 'where': the client did not declare roots",
        },
    };
    for (rounds, 0..) |round, i| {
        tap.setScript(.{ .result = round.result });
        const response = try t.request(@intCast(i + 5), "tools/call", "{\"name\":\"scripted\"}");
        try h.expectError(response, -32603, undeclared_message, "undeclared_input_request");
        try testing.expectEqualStrings(round.detail, h.errorDetail(response).?);
    }
    try testing.expectEqual(@as(usize, 0), try bridgeRequestCount(t));
    try testing.expectEqual(@as(usize, 6), tap.count());

    // A form works.
    tap.setScript(.forward);
    try callTool(t, 8, "ask_form");
    try t.reply(try t.bridgeRequest("elicitation/create", 1), "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
    try testing.expectEqualStrings("form: accept {\"name\":\"Ada\"}", try resultText(t, 8));
    try t.verify();
}
