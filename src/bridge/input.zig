//! The input requests of the upstream server. A server of revision 2026-07-28 can answer
//! `tools/call`, `prompts/get` and `resources/read` with an `InputRequiredResult`. It does so
//! when it needs input: an elicitation, a sampling or the roots of the client. A client of
//! revision 2025-11-25 gets these as JSON-RPC requests from the server. The front end sends the
//! upstream request with `allow_input_required`, thus the client of zig-sdk returns the
//! `InputRequiredResult` and calls no hook. A `Session` then does one round for each
//! `InputRequiredResult`:
//!
//! 1. It examines each input request before the client gets one of them (`check`). A request
//!    that the client did not declare, or that is not valid, fails the original request. The
//!    client then gets no request of the round.
//! 2. It sends all input requests of the round to the client through the `Peer` of the front
//!    end. Then it waits for all answers. VS Code cannot show a form without a property. Thus
//!    the client gets a form with one choice instead.
//! 3. It examines each answer (`shapeAnswer`) and makes the `inputResponses` of the next round.
//!
//! The front end then sends the upstream request again with `inputResponses` and
//! `requestState` (`retryParams`). It continues until the upstream server sends a complete
//! result or an error. Two rules apply across the rounds of one original request:
//!
//! - A URL elicitation gets an `elicitationId`, because revision 2025-11-25 needs one. After
//!   the user accepted the URL, the client gets `notifications/elicitation/complete` when an
//!   upstream round no longer asks for that URL (`Session.observe`). The client also gets it
//!   when the rounds stop without a result (`Session.finish`).
//! - When a later round asks again for a URL that the user accepted, the client does not open
//!   the URL again. It gets a form with one required choice, "Continue", instead.
//!
//! When the upstream server refuses the `requestState` of a round, `rejectedState` gives the
//! answer for the client.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const mcp = @import("mcp");
const types = mcp.types;
const validator = mcp.schema.validator;
const translate = @import("translate.zig");

const log = std.log.scoped(.bridge);

/// The default maximum number of input requests in one round. A round with more input
/// requests fails before the client gets one of them. Thus the requests of the bridge that
/// wait for an answer are at most this number times the limit of requests in flight.
pub const default_max_requests_per_round: u32 = 16;

/// The kind of an input request.
pub const Kind = enum {
    elicitation_form,
    elicitation_url,
    sampling,
    roots,

    /// The method of the request to the client.
    pub fn method(self: Kind) []const u8 {
        return switch (self) {
            .elicitation_form, .elicitation_url => "elicitation/create",
            .sampling => "sampling/createMessage",
            .roots => "roots/list",
        };
    }
};

// ---------------------------------------------------------------------------------------------
// The interface to the front end
// ---------------------------------------------------------------------------------------------

/// One request of the bridge to the client.
pub const Question = struct {
    method: []const u8,
    /// Null sends the request without `params`.
    params: ?Value,
};

/// The answer of the client to one `Question`.
pub const Answer = union(enum) {
    /// The `result` of the response.
    result: Value,
    /// The error of the response.
    rpc_error: types.Error,
    /// The client sent a line with the id of the request, but the line is not a valid
    /// message.
    bad_line,
};

pub const AskError = error{
    /// The client canceled the original request, or the connection ends. The original request
    /// gets no response.
    Canceled,
    /// The client did not answer all questions in time.
    Timeout,
    OutOfMemory,
};

/// The functions of the front end for a `Session`.
pub const Peer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send each question to the client as a request with a new id, all at the same time.
        /// Then wait until the client answered each of them, at most `timeout`. Put the answer
        /// to `questions[i]` into `answers[i]`, in `arena`.
        ask: *const fn (context: *anyopaque, arena: Allocator, questions: []const Question, answers: []Answer, timeout: Io.Duration) AskError!void,
        /// Send a notification to the client, before the response of the original request. A
        /// failure has no effect on the request. The notification goes out also after a
        /// cancellation of the original request.
        notify: *const fn (context: *anyopaque, method: []const u8, params: Value) void,
        /// A new `elicitationId`, in `arena`. Each id is unique on the connection.
        newElicitationId: *const fn (context: *anyopaque, arena: Allocator) Allocator.Error![]const u8,
    };

    fn ask(self: Peer, arena: Allocator, questions: []const Question, answers: []Answer, timeout: Io.Duration) AskError!void {
        return self.vtable.ask(self.context, arena, questions, answers, timeout);
    }

    fn notify(self: Peer, method: []const u8, params: Value) void {
        self.vtable.notify(self.context, method, params);
    }

    fn newElicitationId(self: Peer, arena: Allocator) Allocator.Error![]const u8 {
        return self.vtable.newElicitationId(self.context, arena);
    }
};

// ---------------------------------------------------------------------------------------------
// Checks before the client gets a request
// ---------------------------------------------------------------------------------------------

/// One input request after `check`.
pub const Checked = struct {
    kind: Kind,
    /// The params of the request to the client: the params of the upstream server without
    /// `task`. The bridge declares no tasks to the client, thus a request of the bridge is
    /// never a task. Null when the upstream request has no params.
    params: ?Value,
    /// Form mode: the compiled `requestedSchema`. The accepted content must be valid against
    /// it.
    schema: ?validator.Schema = null,
    /// Form mode: the message of the form.
    message: []const u8 = "",
    /// Form mode: true when the `requestedSchema` has no property, for example for a
    /// confirmation. VS Code cannot show such a form, thus the client gets a form with one
    /// choice instead (`choiceForm`).
    no_properties: bool = false,
    /// URL mode: the URL.
    url: []const u8 = "",
    /// URL mode: false when `urlAllowed` refuses the URL. The client then does not get the
    /// request, and the upstream server gets `{"action":"decline"}`.
    url_allowed: bool = true,
};

pub const CheckResult = union(enum) {
    ok: Checked,
    /// The error of the original request. The client gets no request of the round.
    fail: translate.RpcError,
};

/// Examine the input request `request` with the key `key` before the client gets it. The
/// rules:
///
/// - The client must declare the kind of the request in `caps`: `elicitation.form`,
///   `elicitation.url`, `sampling` or `roots`.
/// - A form must have a `requestedSchema` that the validator of zig-sdk compiles.
/// - A sampling request with `tools`, `toolChoice` or a tool content block needs
///   `sampling.tools`. VS Code never declares it. The messages must obey the tool result rules
///   of `mcp.types.checkSamplingMessages`. The client can ignore `includeContext`, thus the
///   function does not examine it.
/// - A URL that `urlAllowed` refuses is not a failure. `Checked.url_allowed` is then false.
///
/// A failure gives -32603 with `data.detail` that names the key. `caps` are the capabilities
/// that the bridge declared to the upstream server, which are those of the client.
pub fn check(arena: Allocator, caps: types.ClientCapabilities, key: []const u8, request: Value, schema_limits: mcp.Limits.Schema) Allocator.Error!CheckResult {
    const parsed = mcp.json.parseValue(types.InputRequest, arena, request) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failKey(arena, .invalid_input_request, key, "the input request does not have the shape of the schema"),
    };
    const params = try clientParams(arena, request);
    switch (parsed) {
        .@"elicitation/create" => |e| switch (e.params) {
            .form => |form| {
                if (!caps.hasElicitation(.form)) return failKey(arena, .undeclared_input_request, key, "the client did not declare elicitation.form");
                const schema = compileRequestedSchema(arena, form, schema_limits) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return failKey(arena, .invalid_input_request, key, "the requestedSchema does not compile"),
                };
                return .{ .ok = .{
                    .kind = .elicitation_form,
                    .params = params,
                    .schema = schema,
                    .message = form.message,
                    .no_properties = form.requestedSchema.properties.map.count() == 0,
                } };
            },
            .url => |u| {
                if (!caps.hasElicitation(.url)) return failKey(arena, .undeclared_input_request, key, "the client did not declare elicitation.url");
                return .{ .ok = .{ .kind = .elicitation_url, .params = params, .url = u.url, .url_allowed = urlAllowed(u.url) } };
            },
        },
        .@"sampling/createMessage" => |s| {
            const sampling = caps.sampling orelse return failKey(arena, .undeclared_input_request, key, "the client did not declare sampling");
            if (sampling.tools == null and usesTools(s.params)) return failKey(arena, .undeclared_input_request, key, "sampling with tools needs sampling.tools, and the client did not declare it");
            types.checkSamplingMessages(s.params.messages) catch
                return failKey(arena, .invalid_input_request, key, "the sampling messages do not obey the tool result rules");
            return .{ .ok = .{ .kind = .sampling, .params = params } };
        },
        .@"roots/list" => {
            if (caps.roots == null) return failKey(arena, .undeclared_input_request, key, "the client did not declare roots");
            return .{ .ok = .{ .kind = .roots, .params = params } };
        },
    }
}

fn failKey(arena: Allocator, cause: translate.Cause, key: []const u8, what: []const u8) Allocator.Error!CheckResult {
    return .{ .fail = try failFor(arena, cause, key, what) };
}

/// The error of `cause` with `data.detail` that names the key of the input request.
fn failFor(arena: Allocator, cause: translate.Cause, key: []const u8, what: []const u8) Allocator.Error!translate.RpcError {
    return translate.errorFor(cause, try std.fmt.allocPrint(arena, "input request '{s}': {s}", .{ key, what }));
}

/// A copy of the params of an input request without `task`, or null without params.
fn clientParams(arena: Allocator, request: Value) Allocator.Error!?Value {
    if (request != .object) return null;
    const params = request.object.get("params") orelse return null;
    if (params != .object) return null;
    var out: ObjectMap = .empty;
    var it = params.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "task")) continue;
        try out.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }
    return .{ .object = out };
}

/// True when a sampling request uses tools: `tools`, `toolChoice`, or a `tool_use` or
/// `tool_result` content block.
fn usesTools(params: types.CreateMessageRequestParams) bool {
    if (params.tools != null or params.toolChoice != null) return true;
    for (params.messages) |*m| for (m.content.blocks()) |b| switch (b) {
        .tool_use, .tool_result => return true,
        else => {},
    };
    return false;
}

/// Compile the `requestedSchema` of a form as `mcp.Client` does: in the dialect of 2020-12,
/// without `$schema`.
fn compileRequestedSchema(arena: Allocator, form: types.ElicitRequestFormParams, limits: mcp.Limits.Schema) validator.CompileError!validator.Schema {
    var requested = form.requestedSchema;
    requested.@"$schema" = null;
    const root = try mcp.Client.toValue(arena, requested);
    return validator.compile(arena, root, .{ .allow_unsupported_keywords = true, .limits = limits });
}

/// True when the bridge sends the URL of a URL elicitation to the client. The URL must be a
/// valid absolute URL (`mcp.types.isValidUrl`). Its scheme must be `https`, or `http` with a
/// loopback host: `localhost`, an address in 127.0.0.0/8, or `[::1]`. VS Code also opens
/// other schemes, for example `file:`, `vscode:` and `command:`. Thus the bridge refuses them.
///
/// The web browser reads a URL with the WHATWG rules, and `std.Uri` reads it with the rules
/// of RFC 3986. The two parsers must find the same host. Thus the function refuses a
/// backslash, which ends the host for WHATWG and not for RFC 3986. An `http` URL also must
/// not have user information.
pub fn urlAllowed(url: []const u8) bool {
    if (!types.isValidUrl(url)) return false;
    if (std.mem.indexOfScalar(u8, url, '\\') != null) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    if (uri.user != null or uri.password != null) return false;
    const component = uri.host orelse return false;
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = component.toRaw(&buf) catch return false;
    return isLoopbackHost(host);
}

/// True for `localhost`, an IPv4 address in 127.0.0.0/8 and the IPv6 loopback address in
/// brackets, also as an IPv4-mapped address.
fn isLoopbackHost(host: []const u8) bool {
    const name = std.mem.trimEnd(u8, host, ".");
    if (std.ascii.eqlIgnoreCase(name, "localhost")) return true;
    if (std.Io.net.Ip4Address.parse(host, 0)) |ip4| return ip4.bytes[0] == 127 else |_| {}
    if (host.len < 2 or host[0] != '[' or host[host.len - 1] != ']') return false;
    const ip6 = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return false;
    if (std.Io.net.Ip4Address.fromIp6(ip6)) |ip4| return ip4.bytes[0] == 127;
    const loopback: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    return std.mem.eql(u8, &ip6.bytes, &loopback);
}

// ---------------------------------------------------------------------------------------------
// Checks of the answers
// ---------------------------------------------------------------------------------------------

/// The value for `inputResponses`, or the error of the original request.
pub const Shaped = union(enum) {
    value: Value,
    fail: translate.RpcError,
};

/// Examine the answer of the client to the input request `checked` with the key `key`, and
/// make the value for `inputResponses`. The rules:
///
/// - Elicitation: an error of the client, or a line that is not valid, gives
///   `{"action":"cancel"}`. The result loses `content` unless the action is `accept`. A URL
///   result always loses `content`. The accepted content of a form must be valid against its
///   `requestedSchema`. Content that is not valid fails the original request.
/// - Sampling and roots: an error of the client fails the original request with the error of
///   the client. VS Code refuses a sampling request with -32000.
/// - Roots: the result loses each root whose URI does not start with `file://`.
/// - A result that does not have the shape of the schema fails the original request.
pub fn shapeAnswer(arena: Allocator, key: []const u8, checked: *const Checked, answer: Answer) Allocator.Error!Shaped {
    switch (checked.kind) {
        .elicitation_form, .elicitation_url => {
            const result = switch (answer) {
                .result => |r| r,
                .rpc_error, .bad_line => return .{ .value = try actionValue(arena, .cancel) },
            };
            const parsed = parseAnswer(types.ElicitResult, arena, result) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return .{ .fail = try failFor(arena, .invalid_client_answer, key, "the elicitation result does not have the shape of the schema") },
            };
            var out: types.ElicitResult = .{ .action = parsed.action };
            if (parsed.action == .accept and checked.kind == .elicitation_form) {
                const content = parsed.content orelse Value{ .object = .empty };
                if (!try contentMatches(arena, &checked.schema.?, content))
                    return .{ .fail = try failFor(arena, .invalid_client_answer, key, "the accepted content is not valid against the requestedSchema") };
                out.content = parsed.content;
            }
            return .{ .value = try mcp.Client.toValue(arena, out) };
        },
        .sampling => switch (answer) {
            .result => |r| {
                _ = parseAnswer(types.CreateMessageResult, arena, r) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => return .{ .fail = try failFor(arena, .invalid_client_answer, key, "the sampling result does not have the shape of the schema") },
                };
                return .{ .value = r };
            },
            .rpc_error => |e| return .{ .fail = clientError(e) },
            .bad_line => return .{ .fail = try failFor(arena, .invalid_client_answer, key, "the answer of the client is not a valid message") },
        },
        .roots => switch (answer) {
            .result => |r| {
                const parsed = parseAnswer(types.ListRootsResult, arena, r) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => return .{ .fail = try failFor(arena, .invalid_client_answer, key, "the roots result does not have the shape of the schema") },
                };
                var kept: std.ArrayList(types.Root) = .empty;
                for (parsed.roots) |root| {
                    if (std.mem.startsWith(u8, root.uri, "file://")) {
                        try kept.append(arena, root);
                    } else log.debug("input request '{s}': dropped a root that is not a file URI", .{key});
                }
                return .{ .value = try mcp.Client.toValue(arena, types.ListRootsResult{ .roots = kept.items }) };
            },
            .rpc_error => |e| return .{ .fail = clientError(e) },
            .bad_line => return .{ .fail = try failFor(arena, .invalid_client_answer, key, "the answer of the client is not a valid message") },
        },
    }
}

/// The error of the client as the error of the original request: the code, the message and
/// the data stay the same.
fn clientError(e: types.Error) translate.RpcError {
    return .{ .code = e.code, .message = e.message, .data = e.data };
}

fn parseAnswer(comptime T: type, arena: Allocator, result: Value) error{ OutOfMemory, Invalid }!T {
    return mcp.json.parseValue(T, arena, result) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

/// True when `content` is valid against the compiled `requestedSchema`.
fn contentMatches(arena: Allocator, schema: *const validator.Schema, content: Value) Allocator.Error!bool {
    const report = validator.validate(arena, schema, content) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return report.valid;
}

const Action = @FieldType(types.ElicitResult, "action");

/// An elicitation result with only `action`.
fn actionValue(arena: Allocator, action: Action) Allocator.Error!Value {
    return mcp.Client.toValue(arena, types.ElicitResult{ .action = action });
}

/// The action of an elicitation result, or null.
fn actionOf(value: Value) ?Action {
    const text = mcp.json.getString(value, "action") orelse return null;
    return std.meta.stringToEnum(Action, text);
}

// ---------------------------------------------------------------------------------------------
// The "Continue" form
// ---------------------------------------------------------------------------------------------

/// The property of the "Continue" form.
pub const continue_property = "continue";
/// The only value of that property.
pub const continue_value = "Continue";

const Text = struct { message: []const u8 };

/// The message of the "Continue" form. The user sees it instead of the URL again.
const continue_text: Text = .{ .message = "Complete the step in the web browser. Then select Continue." };

/// The params of the "Continue" form. The client gets it when a later round asks again for a
/// URL that the user accepted.
pub fn continueForm(arena: Allocator) Allocator.Error!Value {
    return choiceForm(arena, continue_text.message);
}

/// The params of a form elicitation with the message `message` and one required
/// single-select property with the one value "Continue". VS Code reads the first property of
/// a form without a check, thus the client never gets a form without a property.
pub fn choiceForm(arena: Allocator, message: []const u8) Allocator.Error!Value {
    var choices: std.json.Array = .init(arena);
    try choices.append(.{ .string = continue_value });
    var property: ObjectMap = .empty;
    try property.put(arena, "type", .{ .string = "string" });
    try property.put(arena, "title", .{ .string = continue_value });
    try property.put(arena, "enum", .{ .array = choices });
    try property.put(arena, "default", .{ .string = continue_value });
    var properties: ObjectMap = .empty;
    try properties.put(arena, continue_property, .{ .object = property });
    var required: std.json.Array = .init(arena);
    try required.append(.{ .string = continue_property });
    var schema: ObjectMap = .empty;
    try schema.put(arena, "type", .{ .string = "object" });
    try schema.put(arena, "properties", .{ .object = properties });
    try schema.put(arena, "required", .{ .array = required });
    var params: ObjectMap = .empty;
    try params.put(arena, "mode", .{ .string = "form" });
    try params.put(arena, "message", .{ .string = message });
    try params.put(arena, "requestedSchema", .{ .object = schema });
    return .{ .object = params };
}

/// Make the answer to an upstream form without a property from the answer to its
/// `choiceForm`. An accepted answer gets the content `{}`, because the upstream form has no
/// property. Each other answer stays the same. `shapeAnswer` then examines the result.
pub fn noPropertiesAnswer(arena: Allocator, answer: Answer) Allocator.Error!Answer {
    const result = switch (answer) {
        .result => |r| r,
        .rpc_error, .bad_line => return answer,
    };
    if (actionOf(result) != .accept) return answer;
    var out: ObjectMap = .empty;
    try out.put(arena, "action", .{ .string = "accept" });
    try out.put(arena, "content", .{ .object = .empty });
    return .{ .result = .{ .object = out } };
}

/// Make the answer for the upstream server to a URL elicitation from the answer to the
/// "Continue" form. The result is `accept` without content, or the `decline` or `cancel` of
/// the user. An error of the client, or a line that is not valid, gives `cancel`.
pub fn continueAnswer(arena: Allocator, answer: Answer) Allocator.Error!Value {
    const result = switch (answer) {
        .result => |r| r,
        .rpc_error, .bad_line => return actionValue(arena, .cancel),
    };
    return actionValue(arena, actionOf(result) orelse .cancel);
}

// ---------------------------------------------------------------------------------------------
// Rounds
// ---------------------------------------------------------------------------------------------

/// What the front end does after a round.
pub const Outcome = union(enum) {
    /// Send the upstream request again with these members in its params.
    retry: Retry,
    /// Fail the original request with this error.
    fail: translate.RpcError,
    /// The client canceled the original request, or the connection ends. The original request
    /// gets no response.
    canceled,
};

/// The members of the next upstream request.
pub const Retry = struct {
    /// The `inputResponses` object, or null when the round had no input request.
    input_responses: ?Value,
    /// The `requestState` of the upstream server, or null.
    request_state: ?[]const u8,
};

pub const Options = struct {
    /// The maximum number of input requests in one round.
    max_requests_per_round: u32 = default_max_requests_per_round,
    /// The time that the client gets for the answers of one round.
    timeout: Io.Duration = .fromSeconds(3600),
    /// The limits of the validator for the `requestedSchema` of a form.
    schema_limits: mcp.Limits.Schema = .{},
};

/// The rounds of one original request. All memory comes from `arena`, which lives as long as
/// the original request.
pub const Session = struct {
    arena: Allocator,
    io: Io,
    /// The capabilities that the bridge declared to the upstream server: those of the client.
    capabilities: types.ClientCapabilities,
    peer: Peer,
    options: Options = .{},
    /// The URLs of the URL elicitations of the original request.
    urls: std.ArrayList(UrlStep) = .empty,
    /// The time of the last wait for the answers of the client.
    last_wait: Io.Duration = .zero,
    /// The number of rounds that asked the client.
    rounds: u32 = 0,

    const UrlStep = struct {
        url: []const u8,
        elicitation_id: []const u8,
        /// True after the user accepted the URL.
        accepted: bool = false,
        /// True after `notifications/elicitation/complete`.
        completed: bool = false,
    };

    /// What a round does with one input request.
    const Route = enum {
        /// Send the request to the client.
        ask,
        /// Send the "Continue" form to the client instead of the URL.
        continue_form,
        /// Send a form with one choice to the client instead of a form without a property.
        choice_form,
        /// Answer the upstream server with `{"action":"decline"}`, and do not ask the client.
        decline,
    };

    const Item = struct {
        key: []const u8,
        checked: Checked,
        route: Route = .ask,
        /// The index of the question of `ask`, `continue_form` and `choice_form`.
        question: usize = 0,
        /// URL mode: the step of the URL.
        step: ?usize = null,
    };

    /// Do one round for the raw `InputRequiredResult` `raw`: examine the input requests, ask
    /// the client and examine the answers. The function returns the members of the next
    /// upstream request, or the outcome of the original request.
    pub fn round(self: *Session, raw: Value) Allocator.Error!Outcome {
        const arena = self.arena;
        if (raw != .object) return .{ .fail = translate.errorFor(.invalid_input_request, "the result is not an object") };
        const requests: ObjectMap = if (raw.object.get("inputRequests")) |r| switch (r) {
            .object => |o| o,
            .null => .empty,
            else => return .{ .fail = translate.errorFor(.invalid_input_request, "the inputRequests member is not an object") },
        } else .empty;
        const request_state: ?[]const u8 = if (raw.object.get("requestState")) |s| switch (s) {
            .string => |text| text,
            .null => null,
            else => return .{ .fail = translate.errorFor(.invalid_input_request, "the requestState member is not a string") },
        } else null;
        const count = requests.count();
        if (count > self.options.max_requests_per_round) {
            const detail = try std.fmt.allocPrint(arena, "{d} input requests in one round, limit: {d}", .{ count, self.options.max_requests_per_round });
            return .{ .fail = translate.errorFor(.too_many_input_requests, detail) };
        }

        // Examine all input requests before the client gets one of them.
        const items = try arena.alloc(Item, count);
        for (requests.keys(), requests.values(), items) |key, request, *item| {
            switch (try check(arena, self.capabilities, key, request, self.options.schema_limits)) {
                .fail => |e| return .{ .fail = e },
                .ok => |c| item.* = .{ .key = key, .checked = c },
            }
        }

        var questions: std.ArrayList(Question) = .empty;
        for (items) |*item| {
            if (item.checked.kind == .elicitation_form and item.checked.no_properties) {
                item.route = .choice_form;
                item.question = questions.items.len;
                try questions.append(arena, .{ .method = Kind.elicitation_form.method(), .params = try choiceForm(arena, item.checked.message) });
                continue;
            }
            if (item.checked.kind == .elicitation_url) {
                if (!item.checked.url_allowed) {
                    log.warn("input request '{s}': the bridge refused the URL of a URL elicitation, and the upstream server gets decline", .{item.key});
                    item.route = .decline;
                    continue;
                }
                const index = try self.urlStep(item.checked.url);
                item.step = index;
                const step = &self.urls.items[index];
                if (step.accepted and self.capabilities.hasElicitation(.form)) {
                    item.route = .continue_form;
                    item.question = questions.items.len;
                    try questions.append(arena, .{ .method = Kind.elicitation_form.method(), .params = try continueForm(arena) });
                    continue;
                }
                // Revision 2025-11-25 needs an elicitationId in URL mode.
                if (item.checked.params) |*params| try params.object.put(arena, "elicitationId", .{ .string = step.elicitation_id });
            }
            item.question = questions.items.len;
            try questions.append(arena, .{ .method = item.checked.kind.method(), .params = item.checked.params });
        }

        const answers = try arena.alloc(Answer, questions.items.len);
        if (questions.items.len > 0) {
            self.rounds += 1;
            const started = Io.Clock.Timestamp.now(self.io, .awake);
            defer self.last_wait = started.durationTo(Io.Clock.Timestamp.now(self.io, .awake)).raw;
            self.peer.ask(arena, questions.items, answers, self.options.timeout) catch |e| switch (e) {
                error.Canceled => return .canceled,
                error.OutOfMemory => return error.OutOfMemory,
                error.Timeout => {
                    const detail = try std.fmt.allocPrint(arena, "no answers in {f} (input requests of the round: {d})", .{ translate.TimeLimit{ .duration = self.options.timeout }, questions.items.len });
                    return .{ .fail = translate.errorFor(.input_timeout, detail) };
                },
            };
        }

        var responses: ObjectMap = .empty;
        for (items) |item| {
            const value = switch (item.route) {
                .decline => try actionValue(arena, .decline),
                .continue_form => try continueAnswer(arena, answers[item.question]),
                .ask, .choice_form => value: {
                    var answer = answers[item.question];
                    if (item.route == .choice_form) answer = try noPropertiesAnswer(arena, answer);
                    switch (try shapeAnswer(arena, item.key, &item.checked, answer)) {
                        .fail => |e| return .{ .fail = e },
                        .value => |v| break :value v,
                    }
                },
            };
            if (item.step) |index| if (actionOf(value) == .accept) {
                self.urls.items[index].accepted = true;
            };
            try responses.put(arena, item.key, value);
        }
        return .{ .retry = .{
            .input_responses = if (count > 0) .{ .object = responses } else null,
            .request_state = request_state,
        } };
    }

    /// The index of the step of `url`. A new URL, or a URL whose step is complete, gets a new
    /// step with a new `elicitationId`.
    fn urlStep(self: *Session, url: []const u8) Allocator.Error!usize {
        for (self.urls.items, 0..) |step, i| {
            if (std.mem.eql(u8, step.url, url) and !step.completed) return i;
        }
        try self.urls.append(self.arena, .{ .url = url, .elicitation_id = try self.peer.newElicitationId(self.arena) });
        return self.urls.items.len - 1;
    }

    /// Examine the raw result of an upstream round, a complete result or an
    /// `InputRequiredResult`. For each URL that the user accepted, and that `raw` does not ask
    /// for again, send `notifications/elicitation/complete` with its `elicitationId`. Call it
    /// before the response of the original request, and before the next round.
    pub fn observe(self: *Session, raw: Value) void {
        for (self.urls.items) |*step| {
            if (!step.accepted or step.completed) continue;
            if (asksForUrl(raw, step.url)) continue;
            step.completed = true;
            var params: ObjectMap = .empty;
            params.put(self.arena, "elicitationId", .{ .string = step.elicitation_id }) catch continue;
            self.peer.notify("notifications/elicitation/complete", .{ .object = params });
        }
    }

    /// Send `notifications/elicitation/complete` for each URL that the user accepted and that
    /// has no such notification yet. Call it when the rounds stop without a result: after an
    /// error, after the limit of the rounds and after a cancellation. No later round asks for
    /// these URLs, and VS Code shows an accepted URL until this notification.
    pub fn finish(self: *Session) void {
        self.observe(.null);
    }
};

/// True when `raw` is an `InputRequiredResult` with a URL elicitation for `url`.
pub fn asksForUrl(raw: Value, url: []const u8) bool {
    if (!translate.isInputRequired(raw)) return false;
    const requests = raw.object.get("inputRequests") orelse return false;
    if (requests != .object) return false;
    for (requests.object.values()) |request| {
        const method = mcp.json.getString(request, "method") orelse continue;
        if (!std.mem.eql(u8, method, "elicitation/create")) continue;
        const params = request.object.get("params") orelse continue;
        const mode = mcp.json.getString(params, "mode") orelse continue;
        if (!std.mem.eql(u8, mode, "url")) continue;
        if (std.mem.eql(u8, mcp.json.getString(params, "url") orelse continue, url)) return true;
    }
    return false;
}

/// The params of the next upstream request: a copy of `base` with the members of `retry`.
/// The copy has no `inputResponses` and no `requestState` of `base`.
pub fn retryParams(arena: Allocator, base: Value, retry: Retry) Allocator.Error!Value {
    var out: ObjectMap = .empty;
    if (base == .object) {
        var it = base.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            if (std.mem.eql(u8, key, "inputResponses") or std.mem.eql(u8, key, "requestState")) continue;
            try out.put(arena, key, kv.value_ptr.*);
        }
    }
    if (retry.input_responses) |r| try out.put(arena, "inputResponses", r);
    if (retry.request_state) |s| try out.put(arena, "requestState", .{ .string = s });
    return .{ .object = out };
}

// ---------------------------------------------------------------------------------------------
// A refused requestState
// ---------------------------------------------------------------------------------------------

/// The answer for the client when the upstream server refused the `requestState` of a round.
pub const Rejected = union(enum) {
    /// The `tools/call` result for the client.
    result: Value,
    /// The error for the client.
    rpc_error: translate.RpcError,
};

const rejected_text: Text = .{ .message = "The upstream server did not accept the saved state of the request. The answer possibly came after the time limit of the state, or the server started again." };
const rejected_tool_text: Text = .{ .message = "Run the tool again." };
const rejected_request_text: Text = .{ .message = "Send the request again." };

/// True when the upstream error `e` of a round with `requestState` tells that the server
/// refused the state. The rule examines only the code -32602, because a server can send the
/// error without `data.reason`.
pub fn isRejectedState(e: types.Error) bool {
    return e.code == mcp.protocol.errors.Code.invalid_params.int();
}

/// The answer for the client when the upstream server refused the `requestState` of a round
/// with the error `upstream`. A `tools/call` gets a result with `isError: true` and one text
/// block. Another method gets a JSON-RPC error with the code and the data of the upstream
/// error. The text tells the cause, has the upstream message, and tells the user to send the
/// request again.
pub fn rejectedState(arena: Allocator, method: []const u8, upstream: types.Error) Allocator.Error!Rejected {
    const is_tool = std.mem.eql(u8, method, "tools/call");
    const next = if (is_tool) rejected_tool_text else rejected_request_text;
    const text = try std.fmt.allocPrint(arena, "{s} Upstream message: {s}. {s}", .{ rejected_text.message, std.mem.trimEnd(u8, upstream.message, "."), next.message });
    if (!is_tool) return .{ .rpc_error = .{ .code = upstream.code, .message = text, .data = upstream.data } };
    var block: ObjectMap = .empty;
    try block.put(arena, "type", .{ .string = "text" });
    try block.put(arena, "text", .{ .string = text });
    var content: std.json.Array = .init(arena);
    try content.append(.{ .object = block });
    var result: ObjectMap = .empty;
    try result.put(arena, "content", .{ .array = content });
    try result.put(arena, "isError", .{ .bool = true });
    return .{ .result = .{ .object = result } };
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn parse(arena: Allocator, text: []const u8) !Value {
    return mcp.json.parseTree(arena, text);
}

fn expectJson(arena: Allocator, expected: []const u8, value: anytype) !void {
    try testing.expectEqualStrings(expected, try mcp.json.writeAlloc(arena, value));
}

/// The capabilities of VS Code after the mask: elicitation in two modes, sampling and roots.
fn vscodeCaps(arena: Allocator) !types.ClientCapabilities {
    return translate.upstreamCapabilities(arena, try parse(arena,
        \\{"roots":{"listChanged":true},"sampling":{},"elicitation":{"form":{},"url":{}}}
    ), .{});
}

fn expectFail(result: CheckResult, cause: translate.Cause, key: []const u8) !void {
    const e = switch (result) {
        .fail => |e| e,
        .ok => return error.TestExpectedFailure,
    };
    try testing.expectEqual(cause, e.cause.?);
    try testing.expectEqual(@as(i64, -32603), e.code);
    try testing.expect(std.mem.indexOf(u8, e.detail.?, key) != null);
}

const form_request =
    \\{"method":"elicitation/create","params":{"mode":"form","message":"About you","requestedSchema":{"type":"object",
    \\"properties":{"name":{"type":"string","minLength":1},"age":{"type":"integer","minimum":0},"admin":{"type":"boolean"},
    \\"color":{"type":"string","enum":["red","green"]}},"required":["name"]}},"task":{"ttl":1000}}
;

const sample_request =
    \\{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Hi"}}],"maxTokens":10,"includeContext":"thisServer"}}
;

test "urlAllowed accepts https and loopback http only" {
    for ([_][]const u8{
        "https://example.com/auth",
        "HTTPS://example.com/",
        "http://localhost:8080/callback",
        "http://LOCALHOST./x",
        "http://127.0.0.1/x",
        "http://127.9.8.7:1/",
        "http://[::1]:3000/",
        "http://[::ffff:127.0.0.1]/",
    }) |url| try testing.expect(urlAllowed(url));
    for ([_][]const u8{
        "http://example.com/auth",
        "http://localhost.example.com/",
        "http://localhost@example.com/",
        // A web browser reads the host evil.com in these URLs, and std.Uri reads a loopback
        // host after the user information.
        "http://evil.com\\@localhost/",
        "http://evil.com\\@127.0.0.1/",
        "http://localhost\\.evil.com/",
        "https://example.com\\@example.org/",
        "http://user:secret@localhost/",
        "http://user@127.0.0.1/",
        "http://128.0.0.1/",
        "http://[::2]/",
        "file://localhost/etc/passwd",
        "file:///etc/passwd",
        "vscode://ms-vscode.extension/x",
        "command:workbench.action.reloadWindow",
        "javascript:alert(1)",
        "data:text/html,x",
        "https://",
        "https://exa mple.com/",
        "",
    }) |url| try testing.expect(!urlAllowed(url));
}

test "check accepts the input requests that the client declared" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try vscodeCaps(arena);
    // A form: the params lose `task`, and the schema compiles.
    const form = (try check(arena, caps, "about", try parse(arena, form_request), .{})).ok;
    try testing.expectEqual(Kind.elicitation_form, form.kind);
    try testing.expect(form.params.?.object.get("task") == null);
    try testing.expect(form.schema != null);
    // A URL that the bridge sends, and one that it refuses.
    const url = (try check(arena, caps, "auth", try parse(arena,
        \\{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/auth"}}
    ), .{})).ok;
    try testing.expectEqual(Kind.elicitation_url, url.kind);
    try testing.expect(url.url_allowed);
    try testing.expectEqualStrings("https://example.com/auth", url.url);
    const file = (try check(arena, caps, "file", try parse(arena,
        \\{"method":"elicitation/create","params":{"mode":"url","message":"Open","url":"file://localhost/etc/passwd"}}
    ), .{})).ok;
    try testing.expect(!file.url_allowed);
    // Sampling: includeContext stays, the client can ignore it.
    const sample = (try check(arena, caps, "s", try parse(arena, sample_request), .{})).ok;
    try testing.expectEqual(Kind.sampling, sample.kind);
    try testing.expectEqualStrings("thisServer", mcp.json.getString(sample.params.?, "includeContext").?);
    // Roots without params.
    const roots = (try check(arena, caps, "r", try parse(arena, "{\"method\":\"roots/list\"}"), .{})).ok;
    try testing.expectEqual(Kind.roots, roots.kind);
    try testing.expect(roots.params == null);
    try testing.expectEqualStrings("roots/list", roots.kind.method());
}

test "check refuses an input request that the client did not declare" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The Copilot harness: sampling and elicitation, no roots.
    const copilot = try translate.upstreamCapabilities(arena, try parse(arena, "{\"sampling\":{},\"elicitation\":{\"form\":{},\"url\":{}}}"), .{});
    try expectFail(try check(arena, copilot, "where", try parse(arena, "{\"method\":\"roots/list\"}"), .{}), .undeclared_input_request, "where");
    // A client with the form mode only.
    const form_only = try translate.upstreamCapabilities(arena, try parse(arena, "{\"elicitation\":{}}"), .{});
    try expectFail(try check(arena, form_only, "link", try parse(arena,
        \\{"method":"elicitation/create","params":{"mode":"url","message":"Open","url":"https://example.com/"}}
    ), .{}), .undeclared_input_request, "link");
    try expectFail(try check(arena, form_only, "s", try parse(arena, sample_request), .{}), .undeclared_input_request, "s");
    // A client without elicitation.
    try expectFail(try check(arena, .{}, "about", try parse(arena, form_request), .{}), .undeclared_input_request, "about");
}

test "check refuses sampling with tools without sampling.tools" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try vscodeCaps(arena);
    const with_tools = try parse(arena,
        \\{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Hi"}}],"maxTokens":10,
        \\"tools":[{"name":"t","inputSchema":{"type":"object"}}]}}
    );
    try expectFail(try check(arena, caps, "tools", with_tools, .{}), .undeclared_input_request, "tools");
    const tool_choice = try parse(arena,
        \\{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"Hi"}}],"maxTokens":10,"toolChoice":{"mode":"auto"}}}
    );
    try expectFail(try check(arena, caps, "choice", tool_choice, .{}), .undeclared_input_request, "choice");
    const tool_content = try parse(arena,
        \\{"method":"sampling/createMessage","params":{"messages":[{"role":"assistant","content":{"type":"tool_use","id":"u1","name":"t","input":{}}},
        \\{"role":"user","content":{"type":"tool_result","toolUseId":"u1","content":[]}}],"maxTokens":10}}
    );
    try expectFail(try check(arena, caps, "content", tool_content, .{}), .undeclared_input_request, "content");
    // With sampling.tools, the tool rules of the messages apply.
    const tools_caps = try translate.upstreamCapabilities(arena, try parse(arena, "{\"sampling\":{\"tools\":{}}}"), .{});
    try testing.expect(try check(arena, tools_caps, "tools", with_tools, .{}) == .ok);
    try testing.expect(try check(arena, tools_caps, "content", tool_content, .{}) == .ok);
    const unmatched = try parse(arena,
        \\{"method":"sampling/createMessage","params":{"messages":[{"role":"assistant","content":{"type":"tool_use","id":"u1","name":"t","input":{}}}],"maxTokens":10}}
    );
    try expectFail(try check(arena, tools_caps, "unmatched", unmatched, .{}), .invalid_input_request, "unmatched");
}

test "check refuses an input request that is not valid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try vscodeCaps(arena);
    try expectFail(try check(arena, caps, "x", try parse(arena, "{\"method\":\"tools/call\",\"params\":{}}"), .{}), .invalid_input_request, "x");
    try expectFail(try check(arena, caps, "y", try parse(arena, "{\"method\":\"sampling/createMessage\",\"params\":{\"messages\":[]}}"), .{}), .invalid_input_request, "y");
    try expectFail(try check(arena, caps, "z", .{ .integer = 1 }, .{}), .invalid_input_request, "z");
    // A form property that is not a primitive schema.
    try expectFail(try check(arena, caps, "bad", try parse(arena,
        \\{"method":"elicitation/create","params":{"message":"m","requestedSchema":{"type":"object","properties":{"p":{"type":"object"}}}}}
    ), .{}), .invalid_input_request, "bad");
}

test "shapeAnswer: elicitation results lose the content that they must not have" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try vscodeCaps(arena);
    const form = (try check(arena, caps, "about", try parse(arena, form_request), .{})).ok;

    const accepted = try shapeAnswer(arena, "about", &form, .{ .result = try parse(arena,
        \\{"action":"accept","content":{"name":"Ada","age":36,"admin":true,"color":"green"}}
    ) });
    try expectJson(arena,
        \\{"action":"accept","content":{"name":"Ada","age":36,"admin":true,"color":"green"}}
    , accepted.value);
    const declined = try shapeAnswer(arena, "about", &form, .{ .result = try parse(arena, "{\"action\":\"decline\",\"content\":{\"name\":\"x\"}}") });
    try expectJson(arena, "{\"action\":\"decline\"}", declined.value);
    // An error of the client and a line that is not valid give cancel.
    const failed = try shapeAnswer(arena, "about", &form, .{ .rpc_error = .{ .code = -32603, .message = "m" } });
    try expectJson(arena, "{\"action\":\"cancel\"}", failed.value);
    try expectJson(arena, "{\"action\":\"cancel\"}", (try shapeAnswer(arena, "about", &form, .bad_line)).value);

    // A URL result always loses its content.
    const url = (try check(arena, caps, "auth", try parse(arena,
        \\{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/auth"}}
    ), .{})).ok;
    const url_accept = try shapeAnswer(arena, "auth", &url, .{ .result = try parse(arena, "{\"action\":\"accept\",\"content\":{\"a\":1}}") });
    try expectJson(arena, "{\"action\":\"accept\"}", url_accept.value);
}

test "shapeAnswer: accepted form content must be valid against the requested schema" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try vscodeCaps(arena);
    const form = (try check(arena, caps, "about", try parse(arena, form_request), .{})).ok;
    for ([_][]const u8{
        // VS Code sends the value of a form field as text.
        \\{"action":"accept","content":{"name":"Ada","age":"36"}}
        ,
        \\{"action":"accept","content":{"age":1}}
        ,
        \\{"action":"accept","content":{"name":"Ada","color":"blue"}}
        ,
        \\{"action":"accept"}
        ,
        \\{"action":"accept","content":[1]}
    }) |text| {
        const shaped = try shapeAnswer(arena, "about", &form, .{ .result = try parse(arena, text) });
        try testing.expectEqual(translate.Cause.invalid_client_answer, shaped.fail.cause.?);
        try testing.expect(std.mem.indexOf(u8, shaped.fail.detail.?, "'about'") != null);
    }
    // A result without a valid action.
    const no_action = try shapeAnswer(arena, "about", &form, .{ .result = try parse(arena, "{\"action\":\"maybe\"}") });
    try testing.expectEqual(translate.Cause.invalid_client_answer, no_action.fail.cause.?);
}

test "shapeAnswer: sampling and roots" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const caps = try vscodeCaps(arena);
    const sample = (try check(arena, caps, "s", try parse(arena, sample_request), .{})).ok;
    const model_text = "{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"Hello\"},\"model\":\"gpt\",\"stopReason\":\"endTurn\"}";
    try expectJson(arena, model_text, (try shapeAnswer(arena, "s", &sample, .{ .result = try parse(arena, model_text) })).value);
    // The refusal of VS Code fails the original request with its error.
    const refused = try shapeAnswer(arena, "s", &sample, .{ .rpc_error = .{ .code = -32000, .message = "The user refused the request." } });
    try testing.expectEqual(@as(i64, -32000), refused.fail.code);
    try testing.expectEqualStrings("The user refused the request.", refused.fail.message);
    try testing.expect(refused.fail.cause == null);
    try testing.expectEqual(translate.Cause.invalid_client_answer, (try shapeAnswer(arena, "s", &sample, .bad_line)).fail.cause.?);
    try testing.expectEqual(translate.Cause.invalid_client_answer, (try shapeAnswer(arena, "s", &sample, .{ .result = try parse(arena, "{\"role\":\"x\"}") })).fail.cause.?);

    const roots = (try check(arena, caps, "r", try parse(arena, "{\"method\":\"roots/list\"}"), .{})).ok;
    const listed = try shapeAnswer(arena, "r", &roots, .{ .result = try parse(arena,
        \\{"roots":[{"uri":"file:///home/ada/project","name":"project"},{"uri":"vscode-remote://wsl/x"},{"uri":"https://example.com/"}]}
    ) });
    try expectJson(arena,
        \\{"roots":[{"uri":"file:///home/ada/project","name":"project"}]}
    , listed.value);
    const roots_error = try shapeAnswer(arena, "r", &roots, .{ .rpc_error = .{ .code = -32601, .message = "Method not found" } });
    try testing.expectEqual(@as(i64, -32601), roots_error.fail.code);
}

test "the Continue form and its answers" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try continueForm(arena);
    try expectJson(arena,
        \\{"mode":"form","message":"Complete the step in the web browser. Then select Continue.","requestedSchema":{"type":"object","properties":{"continue":{"type":"string","title":"Continue","enum":["Continue"],"default":"Continue"}},"required":["continue"]}}
    , params);
    // The form is a valid form elicitation with one required property.
    const parsed = try mcp.json.parseValue(types.ElicitRequestParams, arena, params);
    try testing.expectEqual(@as(usize, 1), parsed.form.requestedSchema.properties.map.count());
    try testing.expectEqual(@as(usize, 1), parsed.form.requestedSchema.required.?.len);

    try expectJson(arena, "{\"action\":\"accept\"}", try continueAnswer(arena, .{ .result = try parse(arena, "{\"action\":\"accept\",\"content\":{\"continue\":\"Continue\"}}") }));
    try expectJson(arena, "{\"action\":\"decline\"}", try continueAnswer(arena, .{ .result = try parse(arena, "{\"action\":\"decline\"}") }));
    try expectJson(arena, "{\"action\":\"cancel\"}", try continueAnswer(arena, .{ .result = try parse(arena, "{}") }));
    try expectJson(arena, "{\"action\":\"cancel\"}", try continueAnswer(arena, .bad_line));
}

test "a refused requestState" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try parse(arena, "{\"reason\":\"invalid_request_state\"}");
    const upstream: types.Error = .{ .code = -32602, .message = "Invalid or expired requestState", .data = data };
    try testing.expect(isRejectedState(upstream));
    try testing.expect(!isRejectedState(.{ .code = -32603, .message = "x" }));
    const tool = try rejectedState(arena, "tools/call", upstream);
    try testing.expect(tool.result.object.get("isError").?.bool);
    const text = tool.result.object.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.startsWith(u8, text, rejected_text.message));
    try testing.expect(std.mem.indexOf(u8, text, "Upstream message: Invalid or expired requestState.") != null);
    try testing.expect(std.mem.endsWith(u8, text, "Run the tool again."));
    const prompt = try rejectedState(arena, "prompts/get", upstream);
    try testing.expectEqual(@as(i64, -32602), prompt.rpc_error.code);
    try testing.expect(std.mem.endsWith(u8, prompt.rpc_error.message, "Send the request again."));
    try expectJson(arena, "{\"reason\":\"invalid_request_state\"}", prompt.rpc_error.data.?);
    try testing.expect(prompt.rpc_error.cause == null);
}

test "retryParams replaces the input members" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parse(arena, "{\"name\":\"ask\",\"arguments\":{\"a\":1},\"inputResponses\":{\"old\":{}},\"requestState\":\"old\"}");
    try expectJson(arena,
        \\{"name":"ask","arguments":{"a":1},"inputResponses":{"k":{"action":"cancel"}},"requestState":"s2"}
    , try retryParams(arena, base, .{ .input_responses = try parse(arena, "{\"k\":{\"action\":\"cancel\"}}"), .request_state = "s2" }));
    try expectJson(arena,
        \\{"name":"ask","arguments":{"a":1}}
    , try retryParams(arena, base, .{ .input_responses = null, .request_state = null }));
}

/// A client for the tests of `Session`. It answers each question with the next canned
/// answer, and keeps the questions and the notifications.
const FakePeer = struct {
    arena: Allocator,
    /// The answers as JSON text: a result, or an error object when it starts with "error:".
    script: []const []const u8 = &.{},
    used: usize = 0,
    /// The questions of each `ask`, as JSON text.
    asked: std.ArrayList([]const u8) = .empty,
    asks: usize = 0,
    notes: std.ArrayList([]const u8) = .empty,
    next_id: u32 = 1,
    fail: ?AskError = null,

    const vtable: Peer.VTable = .{ .ask = ask, .notify = notify, .newElicitationId = newId };

    fn peer(self: *FakePeer) Peer {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ask(context: *anyopaque, arena: Allocator, questions: []const Question, answers: []Answer, timeout: Io.Duration) AskError!void {
        _ = timeout;
        const self: *FakePeer = @ptrCast(@alignCast(context));
        self.asks += 1;
        for (questions) |q| self.asked.append(self.arena, mcp.json.writeAlloc(self.arena, q) catch return error.OutOfMemory) catch return error.OutOfMemory;
        if (self.fail) |e| return e;
        for (answers) |*a| {
            const text = self.script[self.used];
            self.used += 1;
            if (std.mem.startsWith(u8, text, "error:")) {
                a.* = .{ .rpc_error = mcp.json.parseValue(types.Error, arena, parse(arena, text["error:".len..]) catch unreachable) catch unreachable };
            } else if (std.mem.eql(u8, text, "bad")) {
                a.* = .bad_line;
            } else a.* = .{ .result = parse(arena, text) catch return error.OutOfMemory };
        }
    }

    fn notify(context: *anyopaque, method: []const u8, params: Value) void {
        const self: *FakePeer = @ptrCast(@alignCast(context));
        const text = std.fmt.allocPrint(self.arena, "{s} {s}", .{ method, mcp.json.writeAlloc(self.arena, params) catch return }) catch return;
        self.notes.append(self.arena, text) catch {};
    }

    fn newId(context: *anyopaque, arena: Allocator) Allocator.Error![]const u8 {
        const self: *FakePeer = @ptrCast(@alignCast(context));
        defer self.next_id += 1;
        return std.fmt.allocPrint(arena, "e-{d}", .{self.next_id});
    }
};

fn testSession(arena: Allocator, fake: *FakePeer) !Session {
    return .{ .arena = arena, .io = testing.io, .capabilities = try vscodeCaps(arena), .peer = fake.peer() };
}

test "a round sends all input requests at one time and makes the inputResponses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena, .script = &.{
        "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}",
        "{\"roots\":[{\"uri\":\"file:///w\"},{\"uri\":\"untitled:x\"}]}",
    } };
    var session = try testSession(arena, &fake);
    const raw = try parse(arena, "{\"resultType\":\"input_required\",\"inputRequests\":{\"about\":" ++ form_request ++ ",\"where\":{\"method\":\"roots/list\"}},\"requestState\":\"s1\"}");
    const outcome = try session.round(raw);
    try testing.expectEqual(@as(usize, 1), fake.asks);
    try testing.expectEqual(@as(usize, 2), fake.asked.items.len);
    try testing.expect(std.mem.startsWith(u8, fake.asked.items[0], "{\"method\":\"elicitation/create\""));
    try testing.expect(std.mem.indexOf(u8, fake.asked.items[0], "task") == null);
    try testing.expectEqualStrings("{\"method\":\"roots/list\"}", fake.asked.items[1]);
    try testing.expectEqualStrings("s1", outcome.retry.request_state.?);
    try expectJson(arena,
        \\{"about":{"action":"accept","content":{"name":"Ada"}},"where":{"roots":[{"uri":"file:///w"}]}}
    , outcome.retry.input_responses.?);
}

test "a round with too many input requests or a failed check asks nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena };
    var session = try testSession(arena, &fake);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, "{\"resultType\":\"input_required\",\"inputRequests\":{");
    for (0..default_max_requests_per_round + 1) |i| {
        if (i > 0) try text.append(arena, ',');
        try text.print(arena, "\"r{d}\":{{\"method\":\"roots/list\"}}", .{i});
    }
    try text.appendSlice(arena, "}}");
    const many = try session.round(try parse(arena, text.items));
    try testing.expectEqual(translate.Cause.too_many_input_requests, many.fail.cause.?);
    try testing.expectEqualStrings("17 input requests in one round, limit: 16", many.fail.detail.?);
    // One request with tools fails the round, also the form before it.
    const tools = try session.round(try parse(arena,
        \\{"resultType":"input_required","inputRequests":{"about":
    ++ form_request ++
        \\,"s":{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":5,"tools":[]}}}}
    ));
    try testing.expectEqual(translate.Cause.undeclared_input_request, tools.fail.cause.?);
    try testing.expectEqual(@as(usize, 0), fake.asks);
}

test "a round answers a refused URL with decline and does not ask" {
    const saved = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena };
    var session = try testSession(arena, &fake);
    const outcome = try session.round(try parse(arena,
        \\{"resultType":"input_required","inputRequests":{"open":{"method":"elicitation/create","params":{"mode":"url","message":"Open","url":"vscode://x/y"}}}}
    ));
    try testing.expectEqual(@as(usize, 0), fake.asks);
    try expectJson(arena, "{\"open\":{\"action\":\"decline\"}}", outcome.retry.input_responses.?);
    try testing.expect(outcome.retry.request_state == null);
}

test "URL rounds: the elicitationId, the Continue form and the complete notification" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena, .script = &.{
        "{\"action\":\"accept\"}",
        "{\"action\":\"accept\",\"content\":{\"continue\":\"Continue\"}}",
    } };
    var session = try testSession(arena, &fake);
    const ask_url =
        \\{"resultType":"input_required","inputRequests":{"auth":{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/auth"}}},"requestState":"s"}
    ;
    // Round 1: URL mode with a generated elicitationId.
    var raw = try parse(arena, ask_url);
    session.observe(raw);
    const first = try session.round(raw);
    try testing.expect(std.mem.indexOf(u8, fake.asked.items[0], "\"mode\":\"url\"") != null);
    try testing.expect(std.mem.indexOf(u8, fake.asked.items[0], "\"elicitationId\":\"e-1\"") != null);
    try expectJson(arena, "{\"auth\":{\"action\":\"accept\"}}", first.retry.input_responses.?);
    // Round 2 asks for the same URL: the client gets the Continue form, and no complete.
    raw = try parse(arena, ask_url);
    session.observe(raw);
    try testing.expectEqual(@as(usize, 0), fake.notes.items.len);
    const second = try session.round(raw);
    try testing.expect(std.mem.indexOf(u8, fake.asked.items[1], "\"mode\":\"form\"") != null);
    try testing.expect(std.mem.indexOf(u8, fake.asked.items[1], "example.com") == null);
    try expectJson(arena, "{\"auth\":{\"action\":\"accept\"}}", second.retry.input_responses.?);
    // The complete result: one notification with the elicitationId.
    session.observe(try parse(arena, "{\"resultType\":\"complete\",\"content\":[]}"));
    session.observe(try parse(arena, "{\"resultType\":\"complete\",\"content\":[]}"));
    try testing.expectEqual(@as(usize, 1), fake.notes.items.len);
    try testing.expectEqualStrings("notifications/elicitation/complete {\"elicitationId\":\"e-1\"}", fake.notes.items[0]);
    try testing.expectEqual(@as(u32, 2), session.rounds);
}

test "URL rounds: a next round with only a form sends the complete notification before the form" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena, .script = &.{
        "{\"action\":\"accept\"}",
        "{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}",
    } };
    var session = try testSession(arena, &fake);
    const ask_url =
        \\{"resultType":"input_required","inputRequests":{"auth":{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/auth"}}},"requestState":"s"}
    ;
    var raw = try parse(arena, ask_url);
    session.observe(raw);
    _ = try session.round(raw);
    // After the sign-in, the server asks for a form and no longer for the URL.
    raw = try parse(arena, "{\"resultType\":\"input_required\",\"inputRequests\":{\"about\":" ++ form_request ++ "},\"requestState\":\"s2\"}");
    session.observe(raw);
    // The notification goes out before the client gets the form.
    try testing.expectEqual(@as(usize, 1), fake.asks);
    try testing.expectEqual(@as(usize, 1), fake.notes.items.len);
    try testing.expectEqualStrings("notifications/elicitation/complete {\"elicitationId\":\"e-1\"}", fake.notes.items[0]);
    const second = try session.round(raw);
    try testing.expectEqual(@as(usize, 2), fake.asks);
    try testing.expect(std.mem.indexOf(u8, fake.asked.items[1], "\"mode\":\"form\"") != null);
    try expectJson(arena, "{\"about\":{\"action\":\"accept\",\"content\":{\"name\":\"Ada\"}}}", second.retry.input_responses.?);
    // The complete result sends no second notification.
    session.observe(try parse(arena, "{\"resultType\":\"complete\",\"content\":[]}"));
    session.finish();
    try testing.expectEqual(@as(usize, 1), fake.notes.items.len);
}

test "URL rounds: finish sends the complete notification when the rounds stop without a result" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena, .script = &.{ "{\"action\":\"accept\"}", "{\"action\":\"decline\"}" } };
    var session = try testSession(arena, &fake);
    const ask_urls =
        \\{"resultType":"input_required","inputRequests":{"auth":{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/auth"}},"pay":{"method":"elicitation/create","params":{"mode":"url","message":"Pay","url":"https://example.com/pay"}}}}
    ;
    const raw = try parse(arena, ask_urls);
    session.observe(raw);
    _ = try session.round(raw);
    // The next upstream round fails, or the client cancels. Only the accepted URL gets the
    // notification, and only one time.
    session.finish();
    session.finish();
    try testing.expectEqual(@as(usize, 1), fake.notes.items.len);
    try testing.expectEqualStrings("notifications/elicitation/complete {\"elicitationId\":\"e-1\"}", fake.notes.items[0]);
}

test "a form without a property goes to the client as a form with one choice" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena, .script = &.{
        "{\"action\":\"accept\",\"content\":{\"continue\":\"Continue\"}}",
        "{\"action\":\"decline\"}",
        "error:{\"code\":-32603,\"message\":\"m\"}",
    } };
    var session = try testSession(arena, &fake);
    const confirm =
        \\{"resultType":"input_required","inputRequests":{"ok":{"method":"elicitation/create","params":{"message":"Delete the file?","requestedSchema":{"type":"object","properties":{}}}}}}
    ;
    const checked = (try check(arena, session.capabilities, "ok", (try parse(arena, confirm)).object.get("inputRequests").?.object.get("ok").?, .{})).ok;
    try testing.expect(checked.no_properties);
    try testing.expectEqualStrings("Delete the file?", checked.message);
    const expected = [_][]const u8{
        \\{"ok":{"action":"accept","content":{}}}
        ,
        \\{"ok":{"action":"decline"}}
        ,
        \\{"ok":{"action":"cancel"}}
    };
    for (expected, 0..) |want, i| {
        const outcome = try session.round(try parse(arena, confirm));
        try expectJson(arena, want, outcome.retry.input_responses.?);
        // The client gets the message of the server and one required choice.
        const question = try parse(arena, fake.asked.items[i]);
        const params = question.object.get("params").?;
        try testing.expectEqualStrings("Delete the file?", mcp.json.getString(params, "message").?);
        const properties = params.object.get("requestedSchema").?.object.get("properties").?;
        try testing.expectEqual(@as(usize, 1), properties.object.count());
        try testing.expect(properties.object.get(continue_property) != null);
    }
}

test "URL rounds: a declined URL gets no complete, and a client without form mode gets the URL again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena, .script = &.{ "{\"action\":\"decline\"}", "{\"action\":\"accept\"}", "{\"action\":\"accept\"}" } };
    var session = try testSession(arena, &fake);
    session.capabilities = try translate.upstreamCapabilities(arena, try parse(arena, "{\"elicitation\":{\"url\":{}}}"), .{});
    const ask_url =
        \\{"resultType":"input_required","inputRequests":{"auth":{"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/auth"}}}}
    ;
    _ = try session.round(try parse(arena, ask_url));
    session.observe(try parse(arena, "{\"resultType\":\"complete\"}"));
    try testing.expectEqual(@as(usize, 0), fake.notes.items.len);
    _ = try session.round(try parse(arena, ask_url));
    _ = try session.round(try parse(arena, ask_url));
    for (fake.asked.items) |q| try testing.expect(std.mem.indexOf(u8, q, "\"elicitationId\":\"e-1\"") != null);
}

test "a round that the client cancels or does not answer in time" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakePeer = .{ .arena = arena, .fail = error.Canceled };
    var session = try testSession(arena, &fake);
    const raw = try parse(arena, "{\"resultType\":\"input_required\",\"inputRequests\":{\"r\":{\"method\":\"roots/list\"}}}");
    try testing.expect(try session.round(raw) == .canceled);
    fake.fail = error.Timeout;
    session.options.timeout = .fromMilliseconds(300);
    const late = try session.round(raw);
    try testing.expectEqual(translate.Cause.input_timeout, late.fail.cause.?);
    try testing.expectEqualStrings("no answers in 300 ms (input requests of the round: 1)", late.fail.detail.?);
    // A round with only a requestState asks nothing.
    const state_only = try session.round(try parse(arena, "{\"resultType\":\"input_required\",\"requestState\":\"s\"}"));
    try testing.expect(state_only.retry.input_responses == null);
    try testing.expectEqualStrings("s", state_only.retry.request_state.?);
    try testing.expectEqual(@as(usize, 2), fake.asks);
}

test "asksForUrl" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try parse(arena,
        \\{"resultType":"input_required","inputRequests":{"a":{"method":"elicitation/create","params":{"mode":"url","message":"m","url":"https://a/"}},"b":{"method":"roots/list"}}}
    );
    try testing.expect(asksForUrl(raw, "https://a/"));
    try testing.expect(!asksForUrl(raw, "https://b/"));
    try testing.expect(!asksForUrl(try parse(arena, "{\"resultType\":\"complete\"}"), "https://a/"));
    try testing.expect(!asksForUrl(.null, "https://a/"));
}
