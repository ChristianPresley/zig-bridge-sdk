//! The process tests of the HTTPS mode of `bridge-fixture-server`. The first test starts the
//! executable with `--https 0 --oauth` and reads the URL of the MCP endpoint from its stdout.
//! Then it signs in with `HttpClient` and `OAuthClient` of zig-sdk and the trust of the test CA.
//! The second test starts it with `--bearer-env` and sends the static token in a header.
//!
//! The module `process_options` holds the path of the executable. The environment variable
//! `PROCESS_TEST_FIXTURE` replaces it, as in `process_test.zig`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const mcp = @import("mcp");
const fixture = @import("fixture");
const process_options = @import("process_options");

/// The path of the executable: the environment variable `PROCESS_TEST_FIXTURE`, else the path
/// from the build. The file must exist.
fn executable(arena: Allocator) ![]const u8 {
    const path = testing.environ.getAlloc(arena, "PROCESS_TEST_FIXTURE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => process_options.fixture_exe,
        else => return err,
    };
    Io.Dir.cwd().access(testing.io, path, .{}) catch |err| {
        std.debug.print("fixture server test: the executable '{s}' is missing ({t}). Run the tests with 'zig build test'.\n", .{ path, err });
        return error.MissingExecutable;
    };
    return path;
}

/// The time limit of each phase of a test: the URL on stdout and the exit after the end of
/// stdin. At the limit, a timer stops the fixture, and the test fails with a clear error.
const phase_limit: Io.Duration = .fromSeconds(15);

/// A thread that stops a process when a phase does not end in `phase_limit`. A stop of the
/// process closes its pipes, thus a blocked read of the test ends.
const KillTimer = struct {
    io: Io,
    target: std.process.Child.Id,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(io: Io, target: std.process.Child.Id) !*KillTimer {
        const self = try testing.allocator.create(KillTimer);
        errdefer testing.allocator.destroy(self);
        self.* = .{ .io = io, .target = target };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// End the timer and release it. Returns true when the timer stopped the process.
    fn stop(self: *KillTimer) bool {
        self.done.store(true, .release);
        if (self.thread) |t| t.join();
        const fired = self.fired.load(.acquire);
        testing.allocator.destroy(self);
        return fired;
    }

    fn run(self: *KillTimer) void {
        const deadline = Io.Timestamp.now(self.io, .awake).addDuration(phase_limit);
        while (!self.done.load(.acquire)) {
            if (Io.Timestamp.now(self.io, .awake).nanoseconds >= deadline.nanoseconds) {
                self.fired.store(true, .release);
                switch (builtin.os.tag) {
                    .windows => _ = std.os.windows.ntdll.NtTerminateProcess(self.target, @enumFromInt(1)),
                    .wasi => {},
                    else => std.posix.kill(self.target, .KILL) catch {},
                }
                return;
            }
            self.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }
};

/// The first line of stdout of `child` without its newline, in `arena`. A fixture that does
/// not write the line in `phase_limit` fails the test.
fn readLine(io: Io, child: *std.process.Child, arena: Allocator) ![]const u8 {
    const timer = try KillTimer.start(io, child.id.?);
    var line: std.ArrayList(u8) = .empty;
    var buf: [256]u8 = undefined;
    while (true) {
        if (std.mem.indexOfScalar(u8, line.items, '\n')) |nl| {
            if (timer.stop()) return error.FixtureTooSlow;
            return std.mem.trimEnd(u8, line.items[0..nl], "\r");
        }
        const n = child.stdout.?.readStreaming(io, &.{&buf}) catch |err| {
            if (timer.stop()) {
                std.debug.print("fixture server test: the fixture did not write its URL in {d} s\n", .{phase_limit.toSeconds()});
                return error.FixtureTooSlow;
            }
            return err;
        };
        line.appendSlice(arena, buf[0..n]) catch |err| {
            _ = timer.stop();
            return err;
        };
    }
}

/// Close stdin of `child` and wait for its exit. A fixture that does not stop in
/// `phase_limit` fails the test.
fn stopChild(io: Io, child: *std.process.Child) !std.process.Child.Term {
    child.stdin.?.close(io);
    child.stdin = null;
    // The caller does not stop the child after this call.
    const timer = KillTimer.start(io, child.id.?) catch |err| {
        child.kill(io);
        return err;
    };
    const term = child.wait(io) catch |err| {
        _ = timer.stop();
        child.kill(io);
        return err;
    };
    if (timer.stop()) {
        std.debug.print("fixture server test: the fixture did not stop in {d} s at the end of its stdin\n", .{phase_limit.toSeconds()});
        return error.FixtureTooSlow;
    }
    return term;
}

test "bridge-fixture-server --https 0 --oauth signs a client in, and it stops at the end of stdin" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var child = try std.process.spawn(io, .{
        .argv = &.{ try executable(arena), "--https", "0", "--oauth" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
    var running = true;
    defer if (running) child.kill(io);

    const url = try readLine(io, &child, arena);
    try testing.expect(std.mem.startsWith(u8, url, "https://127.0.0.1:"));
    try testing.expect(std.mem.endsWith(u8, url, fixture.https.mcp_path));

    {
        var bundle = try fixture.https.certificateBundle(gpa, io, fixture.https.ca_pem);
        defer bundle.deinit(gpa);
        var oauth: mcp.auth.OAuthClient = .init(io, gpa, .{ .redirect_uri = "http://127.0.0.1:41999/callback", .ca_bundle = &bundle });
        defer oauth.deinit();
        const http_client = try mcp.transport.HttpClient.init(io, gpa, .{ .url = url, .auth = &oauth, .tls = .{ .trust = .{ .bundle = &bundle } } });
        defer http_client.deinit();
        var client: mcp.Client = .init(gpa, io, .{ .info = .{ .name = "fixture-server-test", .version = "0.0.0" } });
        defer client.deinit();
        client.connect(http_client.transport());

        const discovered = try client.discover(arena, .{ .timeout = .fromSeconds(30) });
        try testing.expectEqualStrings(mcp.protocol.version.version, discovered.supportedVersions[0]);
        // The tool guarded needs a step-up to the second scope.
        const result = try client.callTool(arena, fixture.guarded_tool, std.json.Value{ .object = .empty }, .{ .timeout = .fromSeconds(30) });
        try testing.expectEqualStrings(fixture.guarded_text, result.content[0].text.text);
    }

    running = false;
    const term = try stopChild(io, &child);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

test "bridge-fixture-server --bearer-env takes the token of the environment, and refuses options that do not go with it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try executable(arena);
    const variable = "BRIDGE_FIXTURE_SERVER_TEST_TOKEN";
    var environ = try testing.environ.createMap(gpa);
    defer environ.deinit();
    _ = environ.swapRemove(variable);

    // Without --https, with --oauth, or without the variable: exit code 2.
    for ([_][]const []const u8{
        &.{ path, "--bearer-env", variable },
        &.{ path, "--https", "0", "--oauth", "--bearer-env", variable },
        &.{ path, "--https", "0", "--bearer-env", variable },
    }) |argv| {
        var refused = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true, .environ_map = &environ });
        try testing.expectEqual(std.process.Child.Term{ .exited = 2 }, try refused.wait(io));
    }

    const token = "fixture-server-test-token";
    try environ.put(variable, token);
    var child = try std.process.spawn(io, .{
        .argv = &.{ path, "--https", "0", "--bearer-env", variable },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
        .environ_map = &environ,
    });
    var running = true;
    defer if (running) child.kill(io);
    const url = try readLine(io, &child, arena);

    {
        var bundle = try fixture.https.certificateBundle(gpa, io, fixture.https.ca_pem);
        defer bundle.deinit(gpa);
        const http_client = try mcp.transport.HttpClient.init(io, gpa, .{
            .url = url,
            .extra_headers = &.{.{ .name = "authorization", .value = "Bearer " ++ token }},
            .tls = .{ .trust = .{ .bundle = &bundle } },
        });
        defer http_client.deinit();
        var client: mcp.Client = .init(gpa, io, .{ .info = .{ .name = "fixture-server-test", .version = "0.0.0" } });
        defer client.deinit();
        client.connect(http_client.transport());
        const result = try client.callTool(arena, "add", .{ .a = 2, .b = 3 }, .{ .timeout = .fromSeconds(30) });
        try testing.expectEqualStrings("5", result.content[0].text.text);
    }

    running = false;
    const term = try stopChild(io, &child);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}
