//! The transcripts of the notifications of the upstream server. They examine the list changes,
//! the resource updates, `resources/subscribe` and `resources/unsubscribe`. They also examine
//! the log messages and the `_meta` keys that go to the upstream server.
//!
//! A `ListenScript` of the tap holds a listen stream, or ends it as an upstream server does.
//! `Transcript.verify` checks each frame of the bridge against the schema of revision
//! 2025-11-25, and each listen stream against the schema of revision 2026-07-28.
const std = @import("std");
const Io = std.Io;
const mcp = @import("mcp");
const vscode = @import("vscode");
const fixture = @import("fixture");
const h = @import("harness.zig");

const Value = std.json.Value;
const Frontend = vscode.bridge.Frontend;
const Transcript = h.Transcript;
const testing = std.testing;

/// The list changes that the acknowledgment of a listen stream gives after a gap, in this
/// order.
const list_changes = [_][]const u8{
    "notifications/tools/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/list_changed",
};

const subscribe_notes = "{\"uri\":\"" ++ fixture.notes_uri ++ "\"}";
const subscribe_readme = "{\"uri\":\"" ++ h.readme_uri ++ "\"}";
const touch_notes = touchParams(fixture.notes_uri);
const toggle_tool_off = "{\"name\":\"toggle\",\"arguments\":{\"enabled\":false}}";
const toggle_prompt_off = "{\"name\":\"toggle\",\"arguments\":{\"enabled\":false,\"target\":\"prompt\"}}";

fn touchParams(comptime uri: []const u8) []const u8 {
    return "{\"name\":\"touch\",\"arguments\":{\"uri\":\"" ++ uri ++ "\"}}";
}

/// A discover result that declares the list changes of the tools, and no other notification.
const tools_only_discover =
    \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true},"prompts":{},"resources":{}}}
;

/// A discover result that declares no notification.
const quiet_discover =
    \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"prompts":{},"resources":{}}}
;

/// A discover result that declares the subscriptions to resources and the log messages, and
/// no list change.
const subscribe_only_discover =
    \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{"subscribe":true},"logging":{}}}
;

/// The method of each frame from `start`, or "response" for a response.
fn methodsFrom(t: *Transcript, start: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ((try t.parsedFrames())[start..]) |v| try out.append(t.arena(), mcp.json.getString(v, "method") orelse "response");
    return out.items;
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

/// True when the `tools/list` or `prompts/list` result `result` names `name` in `member`.
fn listed(result: Value, member: []const u8, name: []const u8) bool {
    for (result.object.get(member).?.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("name").?.string, name)) return true;
    }
    return false;
}

/// Send `initialize` while the tap answers `server/discover` with `discover`. Then send
/// `notifications/initialized`, and wait for the first acknowledgment when the result declares
/// a list change. The other requests go to the fixture server.
fn initializeWith(t: *Transcript, discover: []const u8) !Value {
    t.tap.setScript(.{ .result = discover });
    const frame = try t.call(1, h.vscode_initialize);
    t.tap.setScript(.forward);
    const result = try h.expectResult(frame);
    try t.send(h.initialized);
    try t.waitListening(1);
    return result;
}

/// The value of the flag `key` of the capability `member`, or null.
fn capabilityFlag(result: Value, member: []const u8, key: []const u8) ?bool {
    const caps = result.object.get("capabilities").?;
    const cap = caps.object.get(member) orelse return null;
    const flag = cap.object.get(key) orelse return null;
    return flag.bool;
}

/// The URIs of the filter of the listen stream at `index`.
fn listenUris(t: *Transcript, index: usize) ![]const Value {
    const filter = try t.tap.listenFilter(t.arena(), index);
    const uris = filter.object.get("resourceSubscriptions") orelse return &.{};
    return uris.array.items;
}

fn hasUri(uris: []const Value, uri: []const u8) bool {
    for (uris) |u| if (std.mem.eql(u8, u.string, uri)) return true;
    return false;
}

/// Wait until the listen stream at `index` ended.
fn waitListenEnd(t: *Transcript, index: usize) !void {
    const deadline = Io.Clock.Timestamp.now(t.io, .awake).addDuration(.{ .raw = .fromSeconds(10), .clock = .awake });
    while (!t.tap.listenExchange(index).done) {
        if (Io.Clock.Timestamp.now(t.io, .awake).durationTo(deadline).raw.nanoseconds <= 0) return error.TestTimeout;
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
}

// -- The start of the listen stream ---------------------------------------------------------------

test "notifications/initialized starts the listen stream, and its acknowledgment gives one list change for each list" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    // The initialize result declares the notifications of the fixture server.
    const result = try h.expectResult(try t.call(1, h.vscode_initialize));
    try testing.expect(capabilityFlag(result, "tools", "listChanged").?);
    try testing.expect(capabilityFlag(result, "prompts", "listChanged").?);
    try testing.expect(capabilityFlag(result, "resources", "listChanged").?);
    try testing.expect(capabilityFlag(result, "resources", "subscribe").?);
    try testing.expect(result.object.get("capabilities").?.object.get("logging").? == .object);

    // Before notifications/initialized, the bridge opens no listen stream.
    _ = try h.expectResult(try t.request(2, "tools/list", "{}"));
    try testing.expectEqual(@as(usize, 0), t.tap.listenCount());
    try testing.expect(!t.frontend.listener.isRunning());
    try expectMethods(&.{ "response", "response" }, try methodsFrom(t, 0));

    // One stream for the three lists. Its acknowledgment gives one list change for each list,
    // because a change before the acknowledgment reached no listen stream.
    var start = t.count();
    try t.send(h.initialized);
    try t.waitListening(1);
    try expectMethods(&list_changes, try methodsFrom(t, start));
    for ((try t.parsedFrames())[start..]) |frame| try testing.expect(frame.object.get("params") == null);
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    const filter = try t.tap.listenFilter(t.arena(), 0);
    try testing.expectEqual(@as(usize, 3), filter.object.count());
    for ([_][]const u8{ "toolsListChanged", "promptsListChanged", "resourcesListChanged" }) |key| try testing.expect(filter.object.get(key).?.bool);

    // A second notifications/initialized starts nothing.
    start = t.count();
    try t.send(h.initialized);
    _ = try h.expectResult(try t.requestInline(3, "ping", null));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    try testing.expectEqual(@as(u64, 1), t.frontend.listener.acknowledgments.load(.acquire));
    try t.verify();
}

test "a tool change before the first acknowledgment is not lost" {
    var hold: h.ListenScript = .{ .play = .hold };
    const t = try Transcript.create(.{});
    defer t.destroy();
    t.tap.scriptListen(&hold);
    _ = try h.expectResult(try t.call(1, h.vscode_initialize));
    try t.send(h.initialized);
    // VS Code lists the tools at the same time as notifications/initialized. The listen stream
    // waits in the tap, thus the upstream server has no listen stream yet.
    try t.tap.waitListens(1);
    try testing.expect(listed(try h.expectResult(try t.request(2, "tools/list", "{}")), "tools", "toggled"));
    const start = t.count();
    _ = try h.expectResult(try t.request(3, "tools/call", toggle_tool_off));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));

    // After the acknowledgment, VS Code gets one list change for each list. Thus it lists the
    // tools again, and the change is not lost.
    try hold.finish(t.io);
    try t.waitListening(1);
    try expectMethods(&[_][]const u8{"response"} ++ list_changes, try methodsFrom(t, start));
    try testing.expect(!listed(try h.expectResult(try t.request(4, "tools/list", "{}")), "tools", "toggled"));
    try t.verify();
}

// -- The capabilities of the upstream server ------------------------------------------------------

test "an upstream server with the list changes of the tools only: the bridge declares and sends only those" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    const result = try initializeWith(t, tools_only_discover);
    try testing.expect(capabilityFlag(result, "tools", "listChanged").?);
    try testing.expectEqual(@as(?bool, null), capabilityFlag(result, "prompts", "listChanged"));
    try testing.expectEqual(@as(?bool, null), capabilityFlag(result, "resources", "listChanged"));
    try testing.expectEqual(@as(?bool, null), capabilityFlag(result, "resources", "subscribe"));
    try testing.expect(result.object.get("capabilities").?.object.get("logging") == null);

    // The stream asks for the list changes of the tools only, and the acknowledgment gives one
    // list change for the tools.
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    const filter = try t.tap.listenFilter(t.arena(), 0);
    try testing.expectEqual(@as(usize, 1), filter.object.count());
    try testing.expect(filter.object.get("toolsListChanged").?.bool);
    try expectMethods(&.{ "response", "notifications/tools/list_changed" }, try methodsFrom(t, 0));

    // A change of the prompts does not reach VS Code. A change of the tools does.
    var start = t.count();
    _ = try h.expectResult(try t.request(2, "tools/call", toggle_prompt_off));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));
    start = t.count();
    _ = try h.expectResult(try t.request(3, "tools/call", toggle_tool_off));
    try expectMethods(&.{ "notifications/tools/list_changed", "response" }, try methodsFrom(t, start));
    // VS Code did not get resources.subscribe.
    try h.expectError(try t.request(4, "resources/subscribe", subscribe_notes), -32601, null, "method_not_found");
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    try t.verify();
}

test "an upstream server without notifications: no listen stream and no list change" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    const result = try initializeWith(t, quiet_discover);
    for ([_][]const u8{ "tools", "prompts", "resources" }) |member| try testing.expectEqual(@as(?bool, null), capabilityFlag(result, member, "listChanged"));
    try testing.expectEqual(@as(?bool, null), capabilityFlag(result, "resources", "subscribe"));
    try testing.expect(result.object.get("capabilities").?.object.get("logging") == null);

    _ = try h.expectResult(try t.request(2, "tools/call", toggle_tool_off));
    try h.expectError(try t.request(3, "resources/subscribe", subscribe_notes), -32601, null, "method_not_found");
    try testing.expect(!t.frontend.listener.isRunning());
    try testing.expectEqual(@as(usize, 0), t.tap.listenCount());
    try expectMethods(&.{ "response", "response", "response" }, try methodsFrom(t, 0));
    try t.verify();
}

test "an upstream server with resources.subscribe and no list change: only a URI opens a listen stream" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    const result = try initializeWith(t, subscribe_only_discover);
    try testing.expect(capabilityFlag(result, "resources", "subscribe").?);
    for ([_][]const u8{ "tools", "resources" }) |member| try testing.expectEqual(@as(?bool, null), capabilityFlag(result, member, "listChanged"));
    try testing.expect(result.object.get("capabilities").?.object.get("logging").? == .object);

    // The listener runs, but it has no URI and no list. Thus it opens no stream.
    _ = try h.expectResult(try t.requestInline(2, "ping", null));
    try testing.expect(t.frontend.listener.isRunning());
    try testing.expectEqual(@as(usize, 0), t.tap.listenCount());

    // The first subscribe opens a stream for the URI. Its acknowledgment gives the response,
    // and no list change.
    try testing.expectEqual(@as(usize, 0), (try h.expectResult(try t.request(3, "resources/subscribe", subscribe_notes))).object.count());
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    const filter = try t.tap.listenFilter(t.arena(), 0);
    try testing.expectEqual(@as(usize, 1), filter.object.count());
    const uris = try listenUris(t, 0);
    try testing.expectEqual(@as(usize, 1), uris.len);
    try testing.expectEqualStrings(fixture.notes_uri, uris[0].string);
    var start = t.count();
    _ = try h.expectResult(try t.request(4, "tools/call", touch_notes));
    try expectMethods(&.{ "notifications/resources/updated", "response" }, try methodsFrom(t, start));
    start = t.count();
    _ = try h.expectResult(try t.request(5, "tools/call", toggle_tool_off));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));

    // The last unsubscribe ends the stream, and no new stream starts.
    _ = try h.expectResult(try t.request(6, "resources/unsubscribe", subscribe_notes));
    try waitListenEnd(t, 0);
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    start = t.count();
    _ = try h.expectResult(try t.request(7, "tools/call", touch_notes));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));
    for (list_changes) |m| try testing.expectEqual(@as(usize, 0), try t.methodCount(m));
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    try t.verify();
}

test "the last resources/unsubscribe: an update of the old stream after its cancellation does not reach VS Code" {
    var late: h.ListenScript = .{ .play = .late_update };
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try initializeWith(t, subscribe_only_discover);
    t.tap.scriptListen(&late);
    _ = try h.expectResult(try t.request(2, "resources/subscribe", subscribe_notes));
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    // The first stream follows the gap at the start. Thus VS Code gets one update of the URI
    // after the response, and it reads the resource again.
    try expectMethods(&.{ "response", "response", "notifications/resources/updated" }, try methodsFrom(t, 0));

    // The unsubscribe cancels the stream. The upstream server wrote an update of the URI before
    // it read the cancellation. After the response, VS Code expects no update of the URI.
    const start = t.count();
    _ = try h.expectResult(try t.request(3, "resources/unsubscribe", subscribe_notes));
    try late.finish(t.io);
    try waitListenEnd(t, 0);
    try expectMethods(&.{"response"}, try methodsFrom(t, start));
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    try t.verify();
}

// -- List changes ---------------------------------------------------------------------------------

test "a tool toggle: the list change comes before the result of the call" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    // VS Code lists the tools again after a list change, and before the next turn of the
    // chat. Thus the list change must come before the result of the call that caused it.
    var start = t.count();
    const off = try h.expectResult(try t.request(2, "tools/call", toggle_tool_off));
    try testing.expectEqualStrings("tool toggled: disabled", try h.firstText(off));
    try expectMethods(&.{ "notifications/tools/list_changed", "response" }, try methodsFrom(t, start));
    try testing.expect(!listed(try h.expectResult(try t.request(3, "tools/list", "{}")), "tools", "toggled"));

    start = t.count();
    _ = try h.expectResult(try t.request(4, "tools/call", "{\"name\":\"toggle\",\"arguments\":{\"enabled\":true}}"));
    try expectMethods(&.{ "notifications/tools/list_changed", "response" }, try methodsFrom(t, start));
    try testing.expect(listed(try h.expectResult(try t.request(5, "tools/list", "{}")), "tools", "toggled"));

    start = t.count();
    _ = try h.expectResult(try t.request(6, "tools/call", toggle_prompt_off));
    try expectMethods(&.{ "notifications/prompts/list_changed", "response" }, try methodsFrom(t, start));
    try testing.expect(!listed(try h.expectResult(try t.request(7, "prompts/list", "{}")), "prompts", "toggled"));
    // A call that changes nothing gives no list change.
    start = t.count();
    _ = try h.expectResult(try t.request(8, "tools/call", toggle_prompt_off));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));

    // Many calls: each list change comes before its result.
    var id: i64 = 9;
    for (0..20) |i| {
        start = t.count();
        const params = if (i % 2 == 0)
            toggle_tool_off
        else
            "{\"name\":\"toggle\",\"arguments\":{\"enabled\":true}}";
        _ = try h.expectResult(try t.request(id, "tools/call", params));
        id += 1;
        try expectMethods(&.{ "notifications/tools/list_changed", "response" }, try methodsFrom(t, start));
    }
    // The list changes of the upstream server have no `_meta`.
    for (try t.parsedFrames()) |frame| {
        const method = mcp.json.getString(frame, "method") orelse continue;
        if (!h.isListenEvent(method)) continue;
        try testing.expect(frame.object.get("params") == null);
    }
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    try t.verify();
}

// -- Subscriptions --------------------------------------------------------------------------------

test "resources/subscribe: the response comes before the updates, and resources/unsubscribe ends them" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const a = t.arena();

    // The bridge opens a new listen stream with the URI. The response comes from the
    // acknowledgment of the new stream, and the change gives no list change.
    var start = t.count();
    const subscribed = try h.expectResult(try t.request(2, "resources/subscribe", subscribe_notes));
    try testing.expectEqual(@as(usize, 0), subscribed.object.count());
    try expectMethods(&.{"response"}, try methodsFrom(t, start));
    try testing.expectEqual(@as(usize, 2), t.tap.listenCount());
    const filter = try t.tap.listenFilter(a, 1);
    const uris = filter.object.get("resourceSubscriptions").?.array.items;
    try testing.expectEqual(@as(usize, 1), uris.len);
    try testing.expectEqualStrings(fixture.notes_uri, uris[0].string);
    try testing.expect(filter.object.get("toolsListChanged").?.bool);

    // The update comes before the result of the call that caused it, without the
    // subscription id.
    start = t.count();
    _ = try h.expectResult(try t.request(3, "tools/call", touch_notes));
    try expectMethods(&.{ "notifications/resources/updated", "response" }, try methodsFrom(t, start));
    const update = (try t.parsedFrames())[start];
    try testing.expectEqualStrings(subscribe_notes, try mcp.json.writeAlloc(a, update.object.get("params").?));
    // VS Code reads the resource after the update.
    const read = try h.expectResult(try t.request(4, "resources/read", subscribe_notes));
    try testing.expectEqualStrings(fixture.notes_text, read.object.get("contents").?.array.items[0].object.get("text").?.string);

    // A second subscribe of the URI gets `{}` without a new stream. A second URI gets a new
    // stream with both URIs.
    _ = try h.expectResult(try t.request(5, "resources/subscribe", subscribe_notes));
    try testing.expectEqual(@as(usize, 2), t.tap.listenCount());
    _ = try h.expectResult(try t.request(6, "resources/subscribe", subscribe_readme));
    try testing.expectEqual(@as(usize, 3), t.tap.listenCount());
    try testing.expectEqual(@as(usize, 2), (try listenUris(t, 2)).len);

    // After the unsubscribe, an update of the URI does not reach VS Code. An unknown URI gets
    // `{}` without a new stream.
    _ = try h.expectResult(try t.request(7, "resources/unsubscribe", subscribe_notes));
    try testing.expectEqual(@as(usize, 4), t.tap.listenCount());
    const left = try listenUris(t, 3);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings(h.readme_uri, left[0].string);
    _ = try h.expectResult(try t.request(8, "resources/unsubscribe", "{\"uri\":\"file:///fixture/unknown.txt\"}"));
    try testing.expectEqual(@as(usize, 4), t.tap.listenCount());
    start = t.count();
    _ = try h.expectResult(try t.request(9, "tools/call", touch_notes));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));
    // Parameters that are not valid.
    try h.expectError(try t.request(10, "resources/subscribe", "{\"uri\":7}"), -32602, null, "invalid_params");
    try h.expectError(try t.request(11, "resources/unsubscribe", "{}"), -32602, null, "invalid_params");
    // The changes of the URIs gave no list change after the first acknowledgment.
    for (list_changes) |m| try testing.expectEqual(@as(usize, 1), try t.methodCount(m));
    try t.verify();
}

test "two resources/subscribe at the same time: both URIs get their updates" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const a = t.arena();
    const start = t.count();
    // VS Code subscribes to two resources without a wait for the first response.
    try t.send(try h.requestLine(a, 2, "resources/subscribe", subscribe_notes));
    try t.send(try h.requestLine(a, 3, "resources/subscribe", subscribe_readme));
    for ([_]i64{ 2, 3 }) |id| try testing.expectEqual(@as(usize, 0), (try h.expectResult(try t.waitResponse(id))).object.count());
    try t.waitIdle();
    try expectMethods(&.{ "response", "response" }, try methodsFrom(t, start));

    // The listener does one change at a time. Thus the stream of the second change has the
    // URI of the first change too.
    try testing.expectEqual(@as(usize, 3), t.tap.listenCount());
    try testing.expectEqual(@as(usize, 1), (try listenUris(t, 1)).len);
    const both = try listenUris(t, 2);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expect(hasUri(both, fixture.notes_uri));
    try testing.expect(hasUri(both, h.readme_uri));

    // An update of each URI reaches VS Code before the result of the call.
    const touches = [_]struct { uri: []const u8, params: []const u8 }{
        .{ .uri = fixture.notes_uri, .params = touch_notes },
        .{ .uri = h.readme_uri, .params = touchParams(h.readme_uri) },
    };
    for (touches, 4..) |touch, id| {
        const before = t.count();
        _ = try h.expectResult(try t.request(@intCast(id), "tools/call", touch.params));
        try expectMethods(&.{ "notifications/resources/updated", "response" }, try methodsFrom(t, before));
        const update = (try t.parsedFrames())[before];
        try testing.expectEqualStrings(touch.uri, mcp.json.getString(update.object.get("params").?, "uri").?);
    }
    try t.verify();
}

test "the response of resources/subscribe comes before the first update of the URI" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const a = t.arena();
    const start = t.count();
    // VS Code reads the updates of a URI only after the response of its subscribe. The calls
    // of touch run at the same time as the change of the listen stream.
    const touches = 8;
    try t.send(try h.requestLine(a, 2, "resources/subscribe", subscribe_notes));
    for (0..touches) |i| try t.send(try h.requestLine(a, @intCast(3 + i), "tools/call", touch_notes));
    _ = try h.expectResult(try t.waitResponse(2));
    for (0..touches) |i| _ = try h.expectResult(try t.waitResponse(@intCast(3 + i)));
    try t.waitIdle();
    // A call after the response always gives an update.
    _ = try h.expectResult(try t.request(3 + touches, "tools/call", touch_notes));

    const response_index = (try t.responseIndex(2)).?;
    var updates: usize = 0;
    for ((try t.parsedFrames())[start..], start..) |frame, i| {
        const method = mcp.json.getString(frame, "method") orelse continue;
        try testing.expectEqualStrings("notifications/resources/updated", method);
        if (i < response_index) {
            std.debug.print("\nthe update at frame {d} comes before the response of the subscribe at frame {d}\n", .{ i, response_index });
            return error.TestUpdateBeforeResponse;
        }
        updates += 1;
    }
    try testing.expect(updates >= 1);
    try t.verify();
}

test "the upstream server refuses the stream of a subscribe: VS Code gets the error, and the old stream stays" {
    const saved = h.quiet();
    defer testing.log_level = saved;
    // The filter with the URI of the notes fits the limit of the fixture server. A filter with
    // a second URI does not fit.
    const one_uri = "{\"toolsListChanged\":true,\"promptsListChanged\":true,\"resourcesListChanged\":true,\"resourceSubscriptions\":[\"" ++ fixture.notes_uri ++ "\"]}";
    const t = try Transcript.create(.{ .fixture = .{ .limits = .{ .max_filter_bytes = one_uri.len } } });
    defer t.destroy();
    _ = try t.initialize();
    const a = t.arena();
    _ = try h.expectResult(try t.request(2, "resources/subscribe", subscribe_notes));
    try testing.expectEqualStrings(one_uri, try mcp.json.writeAlloc(a, try t.tap.listenFilter(a, 1)));

    // The new stream fails before its acknowledgment. VS Code gets the error of the upstream
    // server, and the failure gives no list change.
    var start = t.count();
    try h.expectError(try t.request(3, "resources/subscribe", subscribe_readme), -32603, "Subscription filter too large", null);
    try testing.expectEqual(@as(usize, 3), t.tap.listenCount());
    // The old stream stays: the update of the notes and the list change reach VS Code.
    _ = try h.expectResult(try t.request(4, "tools/call", touch_notes));
    _ = try h.expectResult(try t.request(5, "tools/call", toggle_tool_off));
    try expectMethods(&.{ "response", "notifications/resources/updated", "response", "notifications/tools/list_changed", "response" }, try methodsFrom(t, start));

    // The URIs did not change. An unsubscribe of the second URI opens no stream, and an update
    // of it does not reach VS Code.
    start = t.count();
    _ = try h.expectResult(try t.request(6, "resources/unsubscribe", subscribe_readme));
    _ = try h.expectResult(try t.request(7, "tools/call", touchParams(h.readme_uri)));
    try expectMethods(&.{ "response", "response" }, try methodsFrom(t, start));
    try testing.expectEqual(@as(usize, 3), t.tap.listenCount());
    // The listener continues: the unsubscribe of the notes opens a stream without URIs.
    _ = try h.expectResult(try t.request(8, "resources/unsubscribe", subscribe_notes));
    try testing.expectEqual(@as(usize, 4), t.tap.listenCount());
    try testing.expectEqual(@as(usize, 0), (try listenUris(t, 3)).len);
    try t.verify();
}

// -- The end of a listen stream -------------------------------------------------------------------

test "an upstream notifications/cancelled that ends the listen stream never reaches VS Code" {
    // The order of zig-sdk: the result, then the cancellation without `_meta`. The order of
    // other servers: the cancellation with the subscription id, then the result or no result.
    const plays = [_]h.ListenScript.Play{ .result_then_cancelled, .cancelled_then_result, .cancelled_then_close };
    for (plays) |play| {
        var script: h.ListenScript = .{ .play = play };
        const t = try Transcript.create(.{ .frontend = .{ .listen_backoff = .fromMilliseconds(10) } });
        defer t.destroy();
        t.tap.scriptListen(&script);
        _ = try t.initialize();
        const a = t.arena();

        // The ids of VS Code and of the upstream client both start at 1. VS Code sends a
        // request with the id of the listen stream, and the tool waits for the answer of the
        // user.
        const listen_id = (try t.tap.listenRequest(a, 0)).object.get("id").?.integer;
        try t.send(try h.requestLine(a, listen_id, "tools/call", "{\"name\":\"ask_form\"}"));
        const form = try t.bridgeRequest("elicitation/create", 1);

        // The upstream server ends the listen stream with a cancellation of that id.
        const start = t.count();
        try script.finish(t.io);
        // The bridge opens a new stream. Its acknowledgment gives one list change for each
        // list.
        try t.waitListening(2);
        try testing.expectEqual(@as(usize, 2), t.tap.listenCount());
        try testing.expect((try t.tap.listenRequest(a, 1)).object.get("id").?.integer != listen_id);
        for (list_changes) |m| try testing.expectEqual(@as(usize, 1), try t.methodCountFrom(start, m));

        // The request of VS Code with the same id continues and completes.
        try testing.expect((try t.response(listen_id)) == null);
        try testing.expectEqual(@as(usize, 1), t.frontend.pendingCount());
        try t.reply(form, "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}");
        const result = try h.expectResult(try t.waitResponse(listen_id));
        try testing.expectEqualStrings("form: accept {\"name\":\"Ada\"}", try h.firstText(result));
        try t.waitIdle();
        try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/cancelled"));
        try testing.expectEqual(@as(usize, 1), try t.responseCount(listen_id));
        try t.verify();
    }
}

test "the end of the input with open listen streams: run returns at once" {
    var hold: h.ListenScript = .{ .play = .hold };
    // A long grace time: without the stop of the listener, `run` returns after it.
    const t = try Transcript.create(.{ .frontend = .{ .shutdown_grace = .fromSeconds(30) } });
    defer t.destroy();
    _ = try t.initialize();
    const a = t.arena();
    _ = try h.expectResult(try t.request(2, "resources/subscribe", subscribe_notes));
    // A second change waits for the acknowledgment of its stream.
    t.tap.scriptListen(&hold);
    try t.send(try h.requestLine(a, 3, "resources/subscribe", subscribe_readme));
    try t.tap.waitListens(3);
    try testing.expectEqual(@as(usize, 1), t.frontend.inFlightCount());

    // VS Code closes stdin.
    const started = Io.Clock.Timestamp.now(t.io, .awake);
    try testing.expectEqual(Frontend.RunResult.eof, try t.runLines("", 16));
    const elapsed_ms = started.durationTo(Io.Clock.Timestamp.now(t.io, .awake)).raw.toMilliseconds();
    if (elapsed_ms >= 2000) {
        std.debug.print("\nrun returned after {d} ms\n", .{elapsed_ms});
        return error.TestSlowShutdown;
    }
    try testing.expect(!t.frontend.listener.isRunning());
    try testing.expectEqual(Frontend.State.closing, t.frontend.state());
    try testing.expectEqual(@as(usize, 0), t.frontend.inFlightCount());
    // The change that waited gets no response, and each listen stream ended.
    try testing.expectEqual(@as(usize, 0), try t.responseCount(3));
    try testing.expectEqual(@as(usize, 3), t.tap.listenCount());
    for (0..3) |i| {
        const ex = t.tap.listenExchange(i);
        try testing.expect(ex.done);
        try testing.expectEqual(@as(?mcp.transport.Transport.ExchangeError, error.Canceled), ex.outcome);
    }
    try testing.expectEqual(@as(u64, 2), t.frontend.listener.acknowledgments.load(.acquire));
    try t.verify();
}

test "the end of the input while the listener waits to open a new stream: run returns at once" {
    var script: h.ListenScript = .{ .play = .result_then_cancelled };
    // A long wait before the new stream and a long grace time: without the stop of the
    // listener, `run` returns after one of them.
    const t = try Transcript.create(.{ .frontend = .{ .listen_backoff = .fromSeconds(30), .shutdown_grace = .fromSeconds(30) } });
    defer t.destroy();
    t.tap.scriptListen(&script);
    _ = try t.initialize();

    // The upstream server ends the listen stream, and the listener waits 30 s.
    try script.finish(t.io);
    try waitListenEnd(t, 0);
    const deadline = Io.Clock.Timestamp.now(t.io, .awake).addDuration(.{ .raw = .fromSeconds(10), .clock = .awake });
    while (t.frontend.listener.retries.load(.acquire) == 0) {
        if (Io.Clock.Timestamp.now(t.io, .awake).durationTo(deadline).raw.nanoseconds <= 0) return error.TestTimeout;
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }

    // VS Code closes stdin.
    const started = Io.Clock.Timestamp.now(t.io, .awake);
    try testing.expectEqual(Frontend.RunResult.eof, try t.runLines("", 16));
    const elapsed_ms = started.durationTo(Io.Clock.Timestamp.now(t.io, .awake)).raw.toMilliseconds();
    if (elapsed_ms >= 2000) {
        std.debug.print("\nrun returned after {d} ms\n", .{elapsed_ms});
        return error.TestSlowShutdown;
    }
    try testing.expect(!t.frontend.listener.isRunning());
    try testing.expectEqual(Frontend.State.closing, t.frontend.state());
    // No new stream started, and no notifications/cancelled reached VS Code.
    try testing.expectEqual(@as(usize, 1), t.tap.listenCount());
    try testing.expectEqual(@as(usize, 0), try t.methodCount("notifications/cancelled"));
    try t.verify();
}

// -- Log messages ---------------------------------------------------------------------------------

test "logging/setLevel: each upstream request has the level, and the log messages reach VS Code" {
    // Over the memory link, each log message goes to `on_log` of its request. On stdio, the log
    // messages come without a request through the `on_notification` spawn option. The unit
    // test of `bridge.Upstream` and the process test of the log messages examine that path.
    // This transcript does not.
    const t = try Transcript.create(.{});
    defer t.destroy();
    _ = try t.initialize();
    const tap = try t.tapUpstream();
    const a = t.arena();
    // Without a level, the upstream server sends no log message.
    var start = t.count();
    _ = try h.expectResult(try t.request(2, "tools/call", "{\"name\":\"log\"}"));
    try expectMethods(&.{"response"}, try methodsFrom(t, start));
    try testing.expect((try tap.request(a, 0)).object.get("params").?.object.get("_meta").?.object.get("io.modelcontextprotocol/logLevel") == null);

    const cases = [_]struct { level: []const u8, expected: []const []const u8 }{
        .{ .level = "warning", .expected = &.{ "warning", "error" } },
        .{ .level = "debug", .expected = &.{ "debug", "info", "warning", "error" } },
        .{ .level = "error", .expected = &.{"error"} },
    };
    var id: i64 = 3;
    for (cases, 1..) |case, n| {
        _ = try h.expectResult(try t.requestInline(id, "logging/setLevel", try std.fmt.allocPrint(a, "{{\"level\":\"{s}\"}}", .{case.level})));
        id += 1;
        start = t.count();
        _ = try h.expectResult(try t.request(id, "tools/call", "{\"name\":\"log\"}"));
        id += 1;
        const frames = (try t.parsedFrames())[start..];
        try testing.expectEqual(case.expected.len + 1, frames.len);
        // The params of revision 2025-11-25: the level, the logger and the data.
        for (frames[0..case.expected.len], case.expected) |frame, level| {
            try testing.expectEqualStrings("notifications/message", mcp.json.getString(frame, "method").?);
            const params = frame.object.get("params").?;
            try testing.expectEqual(@as(usize, 3), params.object.count());
            try testing.expectEqualStrings(level, mcp.json.getString(params, "level").?);
            try testing.expectEqualStrings(fixture.log_logger, mcp.json.getString(params, "logger").?);
            const data = try std.fmt.allocPrint(a, "a message at the level {s}", .{level});
            try testing.expectEqualStrings(data, mcp.json.getString(params, "data").?);
        }
        try testing.expect(frames[case.expected.len].object.get("result") != null);
        // The upstream request has the level of VS Code.
        const meta = (try tap.request(a, n)).object.get("params").?.object.get("_meta").?;
        try testing.expectEqualStrings(case.level, mcp.json.getString(meta, "io.modelcontextprotocol/logLevel").?);
    }
    // Each listen stream has the level at its start. The first stream started before
    // logging/setLevel, and the stream of a subscribe starts after it.
    try testing.expect((try t.tap.listenRequest(a, 0)).object.get("params").?.object.get("_meta").?.object.get("io.modelcontextprotocol/logLevel") == null);
    _ = try h.expectResult(try t.request(id, "resources/subscribe", subscribe_notes));
    const listen_meta = (try t.tap.listenRequest(a, 1)).object.get("params").?.object.get("_meta").?;
    try testing.expectEqualStrings("error", mcp.json.getString(listen_meta, "io.modelcontextprotocol/logLevel").?);
    try t.verify();
}

// -- The _meta of the requests --------------------------------------------------------------------

/// A tool that sends back the `_meta` of its request as JSON text. Thus a test sees the keys
/// that reach the upstream server.
fn showMeta(ctx: *mcp.RequestContext, args: Value) anyerror!mcp.Outcome(mcp.CallToolResult) {
    _ = args;
    const params = ctx.params orelse return error.InvalidParams;
    const meta = params.object.get("_meta") orelse return error.InvalidParams;
    return .{ .complete = try mcp.CallToolResult.text(ctx.arena, "{s}", .{try mcp.json.writeAlloc(ctx.arena, meta)}) };
}

/// The `_meta` of a tools/call of VS Code. The trace context and the keys of VS Code go
/// upstream. These keys stay with the bridge:
///
/// - The progress token and the log level of VS Code.
/// - A key of the protocol.
/// - A key with a reserved prefix.
/// - A key that is not valid.
/// - A key outside the profile.
const vscode_meta =
    \\{"progressToken":"vs-7","traceparent":"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01","tracestate":"vendor=1","vscode.conversationId":"c-1","vscode.requestId":"r-1","io.modelcontextprotocol/logLevel":"debug","io.modelcontextprotocol/protocolVersion":"2025-11-25","vscode.mcp/x":1,"vscode.bad key":1,"baggage":"b=1"}
;

/// The `_meta` keys that the upstream server can get for a tools/call of VS Code.
const upstream_keys = [_][]const u8{
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/clientInfo",
    "io.modelcontextprotocol/clientCapabilities",
    "io.modelcontextprotocol/logLevel",
    "progressToken",
    "traceparent",
    "tracestate",
    "vscode.conversationId",
    "vscode.requestId",
};

test "_meta: the trace context and the vscode keys reach the upstream server, and the other keys stay with the bridge" {
    const t = try Transcript.create(.{});
    defer t.destroy();
    try t.server.addToolJson(.{ .name = "show_meta", .description = "Send back the _meta of the request" }, showMeta);
    _ = try t.initialize();
    const a = t.arena();
    _ = try h.expectResult(try t.requestInline(2, "logging/setLevel", "{\"level\":\"error\"}"));
    const tap = try t.tapUpstream();

    // One stray key does not make the call fail.
    const result = try h.expectResult(try t.request(3, "tools/call", "{\"name\":\"show_meta\",\"_meta\":" ++ vscode_meta ++ "}"));
    const seen = try mcp.json.parseTree(a, try h.firstText(result));
    try testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", mcp.json.getString(seen, "traceparent").?);
    try testing.expectEqualStrings("vendor=1", mcp.json.getString(seen, "tracestate").?);
    try testing.expectEqualStrings("c-1", mcp.json.getString(seen, "vscode.conversationId").?);
    try testing.expectEqualStrings("r-1", mcp.json.getString(seen, "vscode.requestId").?);
    // The upstream client writes the keys of the protocol. The keys of VS Code do not replace
    // them: the level is the level of logging/setLevel, and the progress token is the id of
    // the upstream request.
    try testing.expectEqualStrings("2026-07-28", mcp.json.getString(seen, "io.modelcontextprotocol/protocolVersion").?);
    try testing.expectEqualStrings("error", mcp.json.getString(seen, "io.modelcontextprotocol/logLevel").?);
    try testing.expectEqual((try tap.request(a, 0)).object.get("id").?.integer, seen.object.get("progressToken").?.integer);
    var it = seen.object.iterator();
    next: while (it.next()) |kv| {
        for (upstream_keys) |k| if (std.mem.eql(u8, k, kv.key_ptr.*)) continue :next;
        std.debug.print("\nthe upstream server got the _meta key {s}\n", .{kv.key_ptr.*});
        return error.TestUnexpectedKey;
    }

    // The log level of VS Code in `_meta` does not change the level of logging/setLevel.
    const start = t.count();
    _ = try h.expectResult(try t.request(4, "tools/call", "{\"name\":\"log\",\"_meta\":{\"io.modelcontextprotocol/logLevel\":\"debug\"}}"));
    try expectMethods(&.{ "notifications/message", "response" }, try methodsFrom(t, start));
    try testing.expectEqualStrings("error", mcp.json.getString((try t.parsedFrames())[start].object.get("params").?, "level").?);

    // The other forwarded requests also have the trace context.
    _ = try h.expectResult(try t.request(5, "resources/read", "{\"uri\":\"" ++ fixture.notes_uri ++ "\",\"_meta\":{\"traceparent\":\"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01\",\"vscode.mcp/x\":1}}"));
    const read_meta = (try tap.request(a, 2)).object.get("params").?.object.get("_meta").?;
    try testing.expectEqualStrings("resources/read", mcp.json.getString(try tap.request(a, 2), "method").?);
    try testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01", mcp.json.getString(read_meta, "traceparent").?);
    try testing.expect(read_meta.object.get("vscode.mcp/x") == null);
    try t.verify();
}
