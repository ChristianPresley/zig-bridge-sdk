//! The `mcp-bridge-vscode` executable. Visual Studio Code (VS Code) starts it as a stdio
//! server. The bridge then starts the upstream server, or it connects to the URL of the
//! upstream server, and translates between the two protocol revisions.
//!
//! The exit code is 0 at the end of stdin. It is 1 when the upstream command stops or when the
//! bridge has an internal error. An HTTP upstream server never stops the bridge: a failed
//! request gets an error. The exit code is 2 for arguments that are not valid. This also
//! applies to a missing environment variable, a `--ca-file` that the bridge cannot read and a
//! token store that does not work.
//!
//! Stdout carries only JSON-RPC messages. The log lines go to stderr, each with the tag
//! `mcp-bridge-vscode`.
//!
//! For the URL form, the bridge signs in at the authorization server of the upstream server
//! when the server asks for it (`bridge.oauth`). The executable has no option and no
//! environment variable that accepts `http` for the sign-in or that skips the browser
//! redirect. `SANDBOX_RUNTIME=1` (the sandbox of VS Code) makes a sign-in fail at once.
//! `logout` deletes stored sign-ins and exits.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const bridge = @import("bridge");
const vscode = @import("vscode");
const cli = @import("cli.zig");

const log = std.log.scoped(.vscode);

/// The compiler keeps the log lines of all levels. The level from `--log-level` filters them
/// at run time.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = bridge.log.tagged(vscode.profile.name),
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var diag: cli.Diagnostic = .{};
    const options = cli.parseDiagnostic(arena, if (args.len > 0) args[1..] else args, init.environ_map, &diag) catch |err| {
        var text_buf: [256]u8 = undefined;
        var text: Io.Writer = .fixed(&text_buf);
        diag.write(err, &text) catch {};
        log.err("{s}", .{text.buffered()});
        std.debug.print("\n{s}", .{cli.usage});
        return 2;
    };

    switch (options.action) {
        .serve, .logout => {},
        .help, .version => {
            var buf: [1024]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &buf);
            const out = &stdout.interface;
            if (options.action == .help) {
                try out.writeAll(cli.usage);
            } else {
                try out.print("{s} {s}\n", .{ vscode.profile.name, vscode.bridge.version });
            }
            try out.flush();
            return 0;
        },
    }

    bridge.log.setLevel(options.log_level);
    if (options.action == .logout) return logout(init, options);
    return serve(init, options);
}

/// Serve VS Code until the end of stdin, and return the exit code.
fn serve(init: std.process.Init, options: cli.Options) u8 {
    const io = init.io;
    const gpa = init.gpa;
    var trust: ?std.crypto.Certificate.Bundle = null;
    defer if (trust) |*b| b.deinit(gpa);
    if (options.http.ca_file) |path| {
        trust = bridge.Upstream.loadCaBundle(io, gpa, path) catch |err| {
            log.err("cannot use the CA certificates of --ca-file: {t}", .{err});
            return 2;
        };
    }
    const ca_bundle: ?*const std.crypto.Certificate.Bundle = if (trust) |*b| b else null;

    // The sign-in of the URL form. Without a static authorization header, the command line
    // gives the settings of the sign-in.
    var store: bridge.oauth.TokenStore = undefined;
    var store_open = false;
    defer if (store_open) store.deinit();
    // The browser gets no secret variable of the environment, also not the variables of
    // --header-env. The POSIX opener gives its program an environment without them. On
    // Windows, the browser gets the environment of the process, thus the URL form removes
    // them from it. The bridge reads only the copy in `init.environ_map`, and the URL form
    // starts no child process.
    var system_opener: bridge.oauth.SystemOpener = .{ .environ_map = init.environ_map, .more_secret_variables = options.http.header_variables };
    if (options.url.len != 0) {
        bridge.oauth.removeFromProcessEnvironment(&bridge.oauth.secret_variables);
        bridge.oauth.removeFromProcessEnvironment(options.http.header_variables);
    }
    var authorizer: bridge.oauth.Authorizer = undefined;
    var sign_in: ?*bridge.oauth.Authorizer = null;
    defer if (sign_in) |a| a.deinit();
    if (options.url.len != 0) if (options.oauth) |oauth| {
        store.open(io, gpa, storeOptions(oauth, init.environ_map, oauth.token_store)) catch |err| return storeFailed(err);
        store_open = true;
        authorizer.init(io, gpa, authorizerOptions(options.url, oauth, store.storage(), ca_bundle, init.environ_map, system_opener.opener())) catch {
            log.err("the bridge stopped because of an internal error: OutOfMemory", .{});
            return 1;
        };
        sign_in = &authorizer;
    };

    var watchdog: Watchdog = .{ .io = io };
    const result = vscode.serve(io, gpa, .{
        .upstream = upstreamOptions(options, ca_bundle, init.environ_map),
        .sign_in = sign_in,
        .name = options.name,
        .discover_timeout = options.discover_timeout,
        .max_line_bytes = options.max_line_bytes,
        .hooks = .{ .context = &watchdog, .on_eof = Watchdog.arm, .on_upstream_exit = upstreamExit },
    }) catch |err| {
        log.err("the bridge stopped because of an internal error: {t}", .{err});
        return 1;
    };
    return switch (result) {
        .eof => 0,
        .upstream_exited => 1,
    };
}

/// The settings of the token store for the store `choice`.
fn storeOptions(oauth: cli.OAuth, environ: *const std.process.Environ.Map, choice: cli.TokenStore) bridge.oauth.TokenStore.Options {
    return .{
        .choice = choice,
        .identity = vscode.identity,
        .environ_map = environ,
        .token_key_file = oauth.token_key_file,
    };
}

/// Writes the cause of a token store that does not open, and returns the exit code. The code
/// is 2 for a setting that does not work, and 1 without memory.
fn storeFailed(err: bridge.oauth.TokenStore.OpenError) u8 {
    const text: []const u8 = switch (err) {
        error.InvalidTokenKey => "the token key does not have 64 hexadecimal digits",
        error.TokenKeyFileNotPrivate => "other accounts can read or change the file of --token-key-file: make it private to your account",
        error.TokenKeyFileUnreadable => "the bridge cannot read the file of --token-key-file",
        error.TokenKeyInTokenDirectory => "the file of --token-key-file is in the token directory: keep the key in a different directory",
        error.TokenKeyMissing => "the file store needs a key: set " ++ cli.token_key_variable ++ ", or give --token-key-file",
        error.NoTokenDirectory => "the environment names no directory for the token files (LOCALAPPDATA, XDG_STATE_HOME or HOME)",
        error.FileStoreFailed => "the file store did not start",
        error.KeychainUnavailable => "the keychain of the system does not answer",
        error.KeychainLocked => "the keychain of the system is locked",
        error.KeychainFailed => "the keychain of the system refused the start",
        error.OutOfMemory => {
            log.err("the bridge stopped because of an internal error: OutOfMemory", .{});
            return 1;
        },
    };
    log.err("the token store did not open: {s}", .{text});
    return 2;
}

/// The settings of the sign-in at the upstream server `url`.
fn authorizerOptions(
    url: []const u8,
    oauth: cli.OAuth,
    storage: bridge.mcp.auth.TokenStorage,
    ca_bundle: ?*const std.crypto.Certificate.Bundle,
    environ: *const std.process.Environ.Map,
    opener: bridge.oauth.Opener,
) bridge.oauth.Authorizer.Options {
    return .{
        .identity = vscode.identity,
        .server_url = url,
        .account = oauth.account,
        .redirect_port = oauth.redirect_port,
        .registration = switch (oauth.registration) {
            .pre_registered => |p| .{ .pre_registered = .{ .client_id = p.client_id, .issuer = p.issuer, .client_secret = p.client_secret } },
            .client_metadata_url => |m| .{ .client_metadata_url = m.url },
            .dynamic => .dynamic,
        },
        .storage = storage,
        // Only --ca-file gives a bundle. Without it, the requests of the sign-in use the
        // trust store of the system through std, which also accepts TLS 1.2.
        .ca_bundle = ca_bundle,
        .proxy = .{ .environment = environ },
        .timeout = oauth.sign_in_timeout,
        .no_browser = oauth.no_browser,
        .opener = opener,
        .sandboxed = inSandbox(environ),
    };
}

/// True when the bridge runs in the sandbox of VS Code (`SANDBOX_RUNTIME=1`). The sandbox has
/// no browser, and it blocks the loopback receiver. The variable makes the sign-in stricter,
/// never weaker.
fn inSandbox(environ: *const std.process.Environ.Map) bool {
    const value = environ.get("SANDBOX_RUNTIME") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "1");
}

/// `logout`: delete the stored sign-in of the account at the URL, or each stored sign-in of
/// the bridge with `--all`. With `--token-store auto`, the command examines the keychain and
/// the file store. Returns the exit code.
fn logout(init: std.process.Init, options: cli.Options) u8 {
    const io = init.io;
    const gpa = init.gpa;
    const oauth = options.oauth.?;
    var trust: ?std.crypto.Certificate.Bundle = null;
    defer if (trust) |*b| b.deinit(gpa);
    if (options.http.ca_file) |path| {
        trust = bridge.Upstream.loadCaBundle(io, gpa, path) catch |err| {
            log.err("cannot use the CA certificates of --ca-file: {t}", .{err});
            return 2;
        };
    }
    var buf: [bridge.oauth.max_redirect_uri_len]u8 = undefined;
    const storage_identity = vscode.identity.storageIdentity(gpa, oauth.account, bridge.oauth.writeRedirectUri(&buf, oauth.redirect_port)) catch return 1;
    defer gpa.free(storage_identity);

    const choices: []const cli.TokenStore = switch (oauth.token_store) {
        .memory => {
            log.info("the memory store keeps no sign-in after the end of the process: logout has nothing to delete", .{});
            return 0;
        },
        .keychain => &.{.keychain},
        .file => &.{.file},
        .auto => &.{ .keychain, .file },
    };
    var deleted: usize = 0;
    for (choices) |choice| {
        var store: bridge.oauth.TokenStore = undefined;
        store.open(io, gpa, storeOptions(oauth, init.environ_map, choice)) catch |err| {
            // With auto, a store that is not available has no sign-in to delete.
            if (oauth.token_store == .auto and err != error.OutOfMemory) {
                log.info("logout skips the {t} store: {t}", .{ choice, err });
                continue;
            }
            return storeFailed(err);
        };
        defer store.deinit();
        if (options.logout_all) {
            deleted += bridge.oauth.logoutAll(gpa, store.storage(), vscode.identity) catch |err| {
                log.err("logout failed in the {t} store: {t}", .{ choice, err });
                return 1;
            };
        } else {
            const report = bridge.oauth.logout(io, gpa, store.storage(), .{
                .identity = vscode.identity,
                .url = options.url,
                .storage_identity = storage_identity,
                .ca_bundle = if (trust) |*b| b else null,
                .proxy = .{ .environment = init.environ_map },
            }) catch |err| {
                log.err("logout failed in the {t} store: {t}", .{ choice, err });
                return 1;
            };
            deleted += report.deleted;
        }
    }
    if (options.logout_all) {
        // The deletion of the token directory needs no key.
        const dir = bridge.oauth.defaultTokenDir(gpa, init.environ_map, vscode.identity.product) catch null;
        if (dir) |d| {
            defer gpa.free(d);
            const removed = bridge.oauth.deleteTokenDir(io, d) catch |err| {
                log.err("cannot delete the token directory {s}: {t}", .{ d, err });
                return 1;
            };
            if (removed) log.info("deleted the token directory {s}", .{d});
        }
        log.info("logout deleted {d} stored sign-ins", .{deleted});
    } else if (deleted == 0) {
        log.info("logout found no stored sign-in of the account \"{s}\" for the URL", .{oauth.account});
    } else {
        log.info("logout deleted the stored sign-in of the account \"{s}\". Restart the server in VS Code to sign in again.", .{oauth.account});
    }
    return 0;
}

/// The upstream server of `options`: the upstream command, or the URL with the settings of
/// the HTTP client. The proxy comes from `environ`. The function writes the warnings about
/// the settings to stderr.
fn upstreamOptions(options: cli.Options, ca_bundle: ?*const std.crypto.Certificate.Bundle, environ: *const std.process.Environ.Map) vscode.UpstreamOptions {
    if (options.url.len == 0) return .{ .command = options.command };
    if (options.http.secret_on_command_line) |name| {
        log.warn("the value of the header {s} is on the command line. VS Code writes the command line to its log, and the process list shows it. Use --header-env.", .{name});
    }
    if (options.oauth) |oauth| if (oauth.registration == .dynamic) {
        log.info("the client metadata document of the bridge has only the redirect port {d}. With --redirect-port {d}, the bridge uses dynamic client registration.", .{ cli.default_redirect_port, oauth.redirect_port });
    };
    return .{
        .http = .{
            .url = options.url,
            .headers = options.http.headers,
            .max_response_bytes = options.http.max_response_bytes,
            .ca_bundle = ca_bundle,
            .proxy = .{ .environment = environ },
            // `vscode.serve` gives the provider of `ServeOptions.sign_in` to the HTTP client.
            .auth = null,
        },
    };
}

/// The upstream server stopped, and the bridge answered the requests in flight. The reader
/// can wait for a line that never comes, thus the process exits here. VS Code then shows the
/// server as stopped, and starts it again at the next request.
fn upstreamExit(context: ?*anyopaque) void {
    _ = context;
    std.process.exit(1);
}

/// A hard limit for the stop at the end of stdin. VS Code sends a termination signal 10 s
/// after it closes stdin (POSIX only), and it stops the process tree after 20 s. When the
/// extension host goes away, nothing stops the process. Thus the bridge stops itself before
/// these limits, also when a request does not obey its cancellation.
const Watchdog = struct {
    io: Io,

    /// The time from the end of stdin to the exit.
    const delay_s = 8;

    /// Start the watchdog thread. The thread is a plain thread and not a task of `io`, thus
    /// it runs also when all tasks wait.
    fn arm(context: ?*anyopaque, upstream: *bridge.Upstream) void {
        const self: *Watchdog = @ptrCast(@alignCast(context.?));
        const thread = std.Thread.spawn(.{}, run, .{ self.io, upstream.pid() }) catch |err| {
            log.warn("cannot start the watchdog: {t}", .{err});
            return;
        };
        thread.detach();
    }

    fn run(io: Io, pid: ?i32) void {
        io.sleep(.fromSeconds(delay_s), .awake) catch {};
        log.warn("the bridge did not stop in {d} s after the end of stdin, thus it stops now", .{delay_s});
        // The child process has its own process group on POSIX. On Windows, the job object of
        // the child process stops the tree when this process exits.
        if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            if (pid) |p| std.posix.kill(-p, .KILL) catch {};
        }
        std.process.exit(0);
    }
};

test "the upstream options of the URL form" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "http://proxy.example:3128");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const options = try cli.parse(arena.allocator(), &.{ "--header", "x-a:1", "--max-response-bytes", "2048", "https://mcp.example.com/mcp" }, &env);
    const upstream = upstreamOptions(options, null, &env);
    try std.testing.expectEqualStrings("https://mcp.example.com/mcp", upstream.http.url);
    try std.testing.expectEqualStrings("x-a", upstream.http.headers[0].name);
    try std.testing.expectEqual(@as(usize, 2048), upstream.http.max_response_bytes);
    try std.testing.expect(upstream.http.ca_bundle == null);
    try std.testing.expect(upstream.http.auth == null);
    // The proxy of the environment applies.
    try std.testing.expectEqual(@as(?*const std.process.Environ.Map, &env), upstream.http.proxy.environment);
    const command = try cli.parse(arena.allocator(), &.{ "--", "server", "--stdio" }, &env);
    try std.testing.expectEqualStrings("--stdio", upstreamOptions(command, null, &env).command[1]);
}

test "the settings of the sign-in come from the command line and the environment" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try std.testing.expect(!inSandbox(&env));
    try env.put("SANDBOX_RUNTIME", "1");
    try std.testing.expect(inSandbox(&env));
    try env.put("SANDBOX_RUNTIME", "0");
    try std.testing.expect(!inSandbox(&env));
    try env.put(cli.client_secret_variable, "made-up-secret");

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: bridge.mcp.auth.MemoryTokenStorage = .init(std.testing.io, gpa);
    defer memory.deinit();
    const args = [_][]const u8{ "--client-id", "c1", "--client-issuer", "https://as.example", "--no-browser", "--sign-in-timeout", "30", "--redirect-port", "50000", "--account", "work", "https://mcp.example.com/mcp" };
    const options = try cli.parse(arena.allocator(), &args, &env);
    const a = authorizerOptions(options.url, options.oauth.?, memory.storage(), null, &env, .system);
    const p = a.registration.pre_registered;
    try std.testing.expectEqualStrings("c1", p.client_id);
    try std.testing.expectEqualStrings("https://as.example", p.issuer.?);
    try std.testing.expectEqualStrings("made-up-secret", p.client_secret.?);
    try std.testing.expect(a.no_browser);
    try std.testing.expect(!a.sandboxed);
    try std.testing.expect(!a.allow_http);
    try std.testing.expectEqual(@as(i64, 30), a.timeout.toSeconds());
    try std.testing.expectEqual(@as(u16, 50000), a.redirect_port);
    try std.testing.expectEqualStrings("work", a.account);
    try std.testing.expectEqualStrings("https://mcp.example.com/mcp", a.server_url);
    try std.testing.expectEqualStrings("mcp-bridge-vscode (zig-bridge-sdk)", a.identity.client_name);
    try std.testing.expectEqual(@as(?*const std.process.Environ.Map, &env), a.proxy.environment);

    // Without a registration option, the bridge uses its client ID metadata document.
    const plain = try cli.parse(arena.allocator(), &.{"https://mcp.example.com/mcp"}, &env);
    const d = authorizerOptions(plain.url, plain.oauth.?, memory.storage(), null, &env, .system);
    try std.testing.expectEqualStrings(cli.default_client_metadata_url, d.registration.client_metadata_url);
    try std.testing.expect(!d.no_browser);
    try std.testing.expectEqual(@as(i64, cli.default_sign_in_timeout_s), d.timeout.toSeconds());
    try std.testing.expectEqual(cli.default_redirect_port, d.redirect_port);

    // A static authorization header gives no sign-in.
    try env.put("API_AUTH", "Bearer made-up");
    const static = try cli.parse(arena.allocator(), &.{ "--header-env", "Authorization=API_AUTH", "https://mcp.example.com/mcp" }, &env);
    try std.testing.expect(static.oauth == null);
    try std.testing.expectEqualStrings("API_AUTH", static.http.header_variables[0]);
}

test {
    std.testing.refAllDecls(@This());
    _ = cli;
    _ = &serve;
    _ = &logout;
    _ = &upstreamExit;
    _ = &Watchdog.arm;
}
