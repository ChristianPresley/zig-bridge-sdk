//! The upstream server of the tests. It is a zig-sdk server of revision 2026-07-28 over stdio.
//! `test/fixture.zig` has its tools, its prompt and its completion handler. Each milestone adds
//! the tools that its tests need.
//!
//! Usage: `bridge-fixture-server [--many-tools N] [--close-stdout]`. With `--many-tools N`, the
//! server also has the generated tools `tool_0` to `tool_<N-1>`. The tool `crash` stops the
//! process with the exit code 3. The tool `shutdown` ends the listen streams as at the end of
//! the input, and then stops the process with the exit code 0.
//!
//! With `--close-stdout`, the process is a server that does not operate correctly. It closes
//! its stdout at once, and then it waits for `close_stdout_wait_s` seconds without a read. Thus
//! a test can examine that the bridge stops a child process that continues to run.
//!
//! Each log line of the server starts with `bridge-fixture-server: `. The server writes to the
//! stderr of the bridge, thus a test can tell the lines of the two processes apart.
//!
//! With `--https PORT`, the server serves `fixture.https.HttpsServer` on 127.0.0.1 and does not
//! read MCP messages on stdin. Port 0 takes a free port. The server writes one line to stdout:
//! the URL of the MCP endpoint. Then it reads stdin until its end, and stops. These options
//! need `--https`:
//!
//! - `--host NAME`: the host of the URLs of the server, for example `fixture.test` for a test
//!   with a proxy. The listener stays on 127.0.0.1.
//! - `--untrusted-cert`: the certificate of the CA that the tests do not trust.
//! - `--oauth`: each request needs an access token of the authorization server in the same
//!   process. The authorization server offers dynamic client registration.
//! - `--bearer-env VAR`: each request needs the header `Authorization: Bearer <token>`, with
//!   the token in the environment variable `VAR`. The server has no authorization server. The
//!   option does not go with `--oauth`.
//!
//! These options need `--oauth`:
//!
//! - `--no-registration`: the authorization server has no registration endpoint.
//! - `--cimd`: the authorization server accepts client ID metadata documents. The server
//!   serves its own document at `fixture.https.client_metadata_path`.
//! - `--ca-file PATH`: the CA file of the authorization server for these documents. The
//!   default is `test/fixtures/tls/ca.crt` in the current directory.
//! - `--deny`: the authorization server denies each authorization request.
//! - `--token-lifetime S`: the lifetime of the access tokens in seconds.
//! - `--no-refresh-tokens`: the authorization server issues no refresh tokens.
const std = @import("std");
const mcp = @import("mcp");
const fixture = @import("fixture");

pub const std_options: std.Options = .{ .logFn = logFn };

/// The start of each log line.
const tag = "bridge-fixture-server: ";

/// Writes one log line with the tag in one write under the stderr lock.
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const prefix = tag ++ comptime level.asText() ++ "(" ++ @tagName(scope) ++ "): ";
    const line = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch line: {
        // The message is too long for the buffer. Keep its start.
        buf[buf.len - 1] = '\n';
        break :line &buf;
    };
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    const stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.writeAll(line) catch {};
}

const usage =
    \\Usage: bridge-fixture-server [--many-tools N] [--close-stdout]
    \\       bridge-fixture-server --https PORT [--host NAME] [--untrusted-cert] [--many-tools N]
    \\           [--oauth [--no-registration] [--cimd] [--ca-file PATH] [--deny]
    \\                    [--token-lifetime S] [--no-refresh-tokens]]
    \\           [--bearer-env VAR]
    \\
;

/// The time that the process waits after `--close-stdout` closed its stdout. A test fails
/// earlier when the bridge does not stop the process.
const close_stdout_wait_s = 120;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: fixture.Options = .{ .crash = true };
    var close_stdout = false;
    var https_port: ?u16 = null;
    var host: ?[]const u8 = null;
    var chain: fixture.https.Chain = .trusted;
    var oauth: fixture.https.OAuth = .{};
    var with_oauth = false;
    // The name of the environment variable of `--bearer-env`, or null.
    var bearer_variable: ?[]const u8 = null;
    // The options that need `--oauth`, for the check after the loop.
    var oauth_option: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "--many-tools") and value != null) {
            i += 1;
            options.many_tools = parseNumber(u32, arg, value.?) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--close-stdout")) {
            close_stdout = true;
        } else if (std.mem.eql(u8, arg, "--https") and value != null) {
            i += 1;
            https_port = parseNumber(u16, arg, value.?) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--host") and value != null) {
            i += 1;
            host = value.?;
        } else if (std.mem.eql(u8, arg, "--untrusted-cert")) {
            chain = .untrusted;
        } else if (std.mem.eql(u8, arg, "--oauth")) {
            with_oauth = true;
        } else if (std.mem.eql(u8, arg, "--bearer-env") and value != null) {
            i += 1;
            bearer_variable = value.?;
        } else if (std.mem.eql(u8, arg, "--no-registration")) {
            oauth.dynamic_registration = false;
            oauth_option = arg;
        } else if (std.mem.eql(u8, arg, "--cimd")) {
            oauth.client_metadata = true;
            oauth_option = arg;
        } else if (std.mem.eql(u8, arg, "--ca-file") and value != null) {
            i += 1;
            oauth.ca_file = value.?;
            oauth_option = arg;
        } else if (std.mem.eql(u8, arg, "--deny")) {
            oauth.deny = true;
            oauth_option = arg;
        } else if (std.mem.eql(u8, arg, "--token-lifetime") and value != null) {
            i += 1;
            oauth.access_token_lifetime_seconds = parseNumber(u32, arg, value.?) orelse return 2;
            oauth_option = arg;
        } else if (std.mem.eql(u8, arg, "--no-refresh-tokens")) {
            oauth.refresh_tokens = false;
            oauth_option = arg;
        } else {
            std.debug.print("bridge-fixture-server: unknown argument '{s}'\n{s}", .{ arg, usage });
            return 2;
        }
    }
    if (oauth_option) |o| if (!with_oauth) {
        std.debug.print("bridge-fixture-server: {s} needs --oauth\n{s}", .{ o, usage });
        return 2;
    };
    if (https_port == null and (with_oauth or chain != .trusted or host != null or bearer_variable != null)) {
        std.debug.print("bridge-fixture-server: --oauth, --bearer-env, --host and --untrusted-cert need --https\n{s}", .{usage});
        return 2;
    }
    if (with_oauth and bearer_variable != null) {
        std.debug.print("bridge-fixture-server: --bearer-env does not go with --oauth\n{s}", .{usage});
        return 2;
    }
    // The token comes from the environment, thus it is not on the command line.
    const bearer_token: ?[]const u8 = if (bearer_variable) |name| token: {
        const token = init.environ_map.get(name) orelse "";
        if (token.len == 0) {
            std.debug.print("bridge-fixture-server: the environment variable {s} of --bearer-env is not set, or it is empty\n", .{name});
            return 2;
        }
        break :token token;
    } else null;
    if (https_port != null and close_stdout) {
        std.debug.print("bridge-fixture-server: --close-stdout does not go with --https\n{s}", .{usage});
        return 2;
    }
    if (close_stdout) {
        std.Io.File.stdout().close(io);
        io.sleep(.fromSeconds(close_stdout_wait_s), .awake) catch {};
        return 0;
    }
    if (https_port) |port| {
        try serveHttps(gpa, io, .{
            .port = port,
            .host = host orelse "127.0.0.1",
            .chain = chain,
            .server = options,
            .oauth = if (with_oauth) oauth else null,
            .bearer_token = bearer_token,
        });
        return 0;
    }
    const server = try fixture.build(gpa, io, options);
    defer fixture.destroy(server);
    try mcp.transport.stdio.serve(io, gpa, server);
    return 0;
}

/// The number in `text`, or null after a message for the option `option`.
fn parseNumber(comptime T: type, option: []const u8, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 10) catch {
        std.debug.print("bridge-fixture-server: {s} needs a number, not '{s}'\n{s}", .{ option, text, usage });
        return null;
    };
}

/// Serve over HTTPS until the end of stdin. The first line on stdout is the URL of the MCP
/// endpoint.
fn serveHttps(gpa: std.mem.Allocator, io: std.Io, options: fixture.https.Options) !void {
    const server = try fixture.https.HttpsServer.start(gpa, io, options);
    defer server.stop();
    std.log.info("listening on {s}", .{server.url()});
    if (server.issuer()) |issuer| std.log.info("the authorization server has the issuer {s}", .{issuer});
    var line_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{s}\n", .{server.url()});
    try std.Io.File.stdout().writeStreamingAll(io, line);
    // The end of stdin stops the server. Thus the server also stops when the test process
    // ends without a stop.
    var buf: [4096]u8 = undefined;
    while (true) {
        _ = std.Io.File.stdin().readStreaming(io, &.{&buf}) catch break;
    }
}
