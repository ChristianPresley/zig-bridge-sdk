//! The sign-in of a bridge at an HTTP upstream server. `mcp.auth.OAuthClient` speaks OAuth
//! 2.1 with the authorization server. This file has the parts that the bridge owns:
//!
//! - `validateAuthorizationUrl` checks each authorization URL before the bridge writes it to
//!   stderr or opens it.
//! - `Opener` opens the browser. On Windows it calls `ShellExecuteW`. On POSIX systems it
//!   starts `$BROWSER`, `open` or `xdg-open` with the URL as the only argument. It never starts
//!   a shell. The browser gets the one-time start URL, and not the authorization URL.
//! - `Receiver` receives the redirect of the browser on `127.0.0.1`. It also serves the start
//!   URL.
//! - `SignIn` gives `OAuthClient` its `authorize` callback, and records the cause of a failure.
//! - `Gate` decides how the URL gets to the user. Before `notifications/initialized` it opens
//!   the browser. After it, the client gets a URL elicitation, and the user decides.
//! - `Authorizer` holds the `OAuthClient` of the bridge. Its provider records the cause of
//!   each challenge that it did not answer, for the error of the request.
//! - `TokenStore` selects the token storage: the keychain, encrypted files or memory.
//! - `IndexedStorage` keeps an index of the stored sign-ins. `logout` and `logoutAll` delete
//!   them.
//! - `Identity` holds the names that the authorization server and the keychain see.
//!
//! Header values, the client secret, the token key, the tokens and the query of the redirect
//! never go to stderr. The program that the POSIX opener starts gets no secret variable of
//! the environment.
//!
//! On a POSIX host, each local user can read the arguments of each process. The authorization
//! URL has the `state` and the `code_challenge` of the sign-in. With these values, another
//! local user can sign in with a different account. The receiver accepts a redirect from each
//! local user, thus the bridge then receives a code for that account.
//!
//! For this reason, the opener gets only the start URL `http://127.0.0.1:<port>/start/<token>`,
//! on each system. The token has 256 random bits. The first `GET` of the start URL gets a
//! redirect to the authorization URL. A second `GET` stops the sign-in, because another
//! program possibly sent one of the two requests. This applies until `Receiver.wait` gives the
//! redirect to its caller.
//!
//! A risk stays. Another local user can read the start URL and send the first `GET`. That user
//! can then complete a sign-in with a different account before the browser of the user sends
//! its `GET`. The same applies when the browser does not open. In these cases, the bridge
//! receives a code for the account of the other user, and it shows no error. The browser of
//! the user then gets an error page, or it cannot connect.
//!
//! On a host with other users, use `--no-browser` (`Authorizer.Options.no_browser`). Then the
//! bridge opens no browser before `notifications/initialized`, and the user opens the URL of
//! the sign-in line. This helps only when no program on that host gets the URL as an argument.
//! For example, VS Code on that host starts `xdg-open` with the URL of a link that the user
//! clicks. After `notifications/initialized`, the client gets the authorization URL also with
//! `--no-browser`, and it opens the URL. On Linux, a `/proc` with `hidepid` also helps.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp");
const auth = mcp.auth;

const log = std.log.scoped(.bridge);

// ---------------------------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------------------------

/// The port of the default redirect URI of `mcp-bridge-vscode`. It is not the port of zig-sdk
/// (41893) and not the port of VS Code (33418). Thus these programs can sign in at the same
/// time. A bridge for a different product uses a different port.
pub const default_redirect_port: u16 = 41894;

/// The path of the redirect URI.
pub const callback_path = "/callback";

/// The length of the longest redirect URI.
pub const max_redirect_uri_len = "http://127.0.0.1:65535".len + callback_path.len;

/// The default time limit of one sign-in, in seconds.
pub const default_sign_in_timeout_s: u32 = 300;

/// The account label when the command line gives none.
pub const default_account = "default";

/// The maximum length of an account label.
pub const max_account_len = 64;

/// The names of a bridge that other parties see, and the keys of its stored records. The
/// values are part of the stored records. Thus a change makes the stored tokens unusable,
/// and the unit test "the OAuth identity of mcp-bridge-vscode stays the same" pins them.
pub const Identity = struct {
    /// The name of the executable, for example `mcp-bridge-vscode`.
    bridge_name: []const u8,
    /// The key of the product, for example `vscode`. The path of the token directory has it.
    product: []const u8,
    /// The `client_name` of dynamic client registration. The consent page of the
    /// authorization server shows it. It is never the name of VS Code.
    client_name: []const u8,
    /// The service of `KeychainTokenStorage`. The bridge owns it. It is never "zig-sdk".
    keychain_service: []const u8,
    /// The client ID metadata document of the bridge, or null. It is the default document of
    /// the command line. A record of this document has the base storage identity.
    client_metadata_url: ?[]const u8 = null,

    /// The identity of the executable `bridge_name` for the product `product`. `document` is
    /// the URL of the client ID metadata document of the bridge, or null.
    pub fn of(comptime bridge_name: []const u8, comptime product: []const u8, comptime document: ?[]const u8) Identity {
        return .{
            .bridge_name = bridge_name,
            .product = product,
            .client_name = bridge_name ++ " (zig-bridge-sdk)",
            .keychain_service = "zig-bridge-sdk/" ++ bridge_name,
            .client_metadata_url = document,
        };
    }

    /// The base storage identity `<bridge name>|<account>|<redirect URI>`, in `gpa`. The
    /// account keeps the records of two accounts apart. A new redirect port gives a new key,
    /// because dynamic client registration binds the exact redirect URI. `logout` deletes each
    /// record whose identity starts with this text.
    pub fn storageIdentity(self: Identity, gpa: Allocator, account: []const u8, redirect_uri: []const u8) Allocator.Error![]u8 {
        return std.mem.concat(gpa, u8, &.{ self.bridge_name, "|", account, "|", redirect_uri });
    }

    /// The `storage_identity` of `OAuthClient` for `registration`, in `gpa`. Dynamic client
    /// registration and the document of the bridge have the base identity
    /// (`storageIdentity`). A pre-registered client adds `|client=<client ID>`, and a different
    /// document adds `|cimd=<URL>`. Thus a stored registration of one source never replaces
    /// the source that the command line gives.
    pub fn clientIdentity(self: Identity, gpa: Allocator, account: []const u8, redirect_uri: []const u8, registration: Registration) Allocator.Error![]u8 {
        const suffix: [2][]const u8 = switch (registration) {
            .pre_registered => |p| .{ "|client=", p.client_id },
            .client_metadata_url => |url| if (self.client_metadata_url != null and std.mem.eql(u8, url, self.client_metadata_url.?)) .{ "", "" } else .{ "|cimd=", url },
            .dynamic => .{ "", "" },
        };
        return std.mem.concat(gpa, u8, &.{ self.bridge_name, "|", account, "|", redirect_uri, suffix[0], suffix[1] });
    }

    /// True when `client` is the base storage identity `base` or `base` with a suffix of
    /// `clientIdentity`.
    pub fn sameAccount(client: []const u8, base: []const u8) bool {
        if (!std.mem.startsWith(u8, client, base)) return false;
        return client.len == base.len or client[base.len] == '|';
    }
};

/// Returns true for an account label of 1 to `max_account_len` bytes: letters, digits and
/// the characters `-`, `.`, `_`, `@` and `+`. Thus a label cannot change the other parts of
/// the storage identity.
pub fn validAccount(label: []const u8) bool {
    if (label.len == 0 or label.len > max_account_len) return false;
    for (label) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._@+", c) == null) return false;
    }
    return true;
}

/// Writes the redirect URI `http://127.0.0.1:<port>/callback` into `buf` and returns it. The
/// host is always the literal `127.0.0.1`, never `localhost` and never `[::1]`.
pub fn writeRedirectUri(buf: *[max_redirect_uri_len]u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}" ++ callback_path, .{port}) catch unreachable;
}

/// The start of the path of the one-time start URL. The token follows it.
pub const start_path_prefix = "/start/";

/// The number of random bytes of a start token: 256 bits, as the `state` of `OAuthClient`.
pub const start_token_bytes = 32;

/// The length of a start token: base64url without padding.
pub const start_token_len = std.base64.url_safe_no_pad.Encoder.calcSize(start_token_bytes);

/// The token of a start URL.
pub const StartToken = [start_token_len]u8;

/// The length of the longest start URL.
pub const max_start_url_len = "http://127.0.0.1:65535".len + start_path_prefix.len + start_token_len;

/// Makes a start token from the secure random source of `io`, as `OAuthClient` makes its
/// `state`.
pub fn newStartToken(io: Io) Io.RandomSecureError!StartToken {
    var bytes: [start_token_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    try io.randomSecure(&bytes);
    var token: StartToken = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&token, &bytes);
    return token;
}

/// Writes the start URL `http://127.0.0.1:<port>/start/<token>` into `buf` and returns it.
pub fn writeStartUrl(buf: *[max_start_url_len]u8, port: u16, token: *const StartToken) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}" ++ start_path_prefix ++ "{s}", .{ port, token }) catch unreachable;
}

/// The settings of `clientOptions`.
pub const ClientConfig = struct {
    identity: Identity,
    /// The sign-in of the client. It must stay valid while the client lives, because the
    /// redirect URI of the options points into it.
    sign_in: *SignIn,
    registration: auth.OAuthClient.Registration = .dynamic,
    storage: ?auth.TokenStorage = null,
    /// The value of `Identity.storageIdentity`.
    storage_identity: ?[]const u8 = null,
    /// The trust of the requests of the client, as `OAuthClient.Options.ca_bundle`.
    ca_bundle: ?*const std.crypto.Certificate.Bundle = null,
    /// The proxy of the requests of the client, as `OAuthClient.Options.proxy`.
    proxy: mcp.transport.proxy.Config = .{ .environment = null },
};

/// The options of `mcp.auth.OAuthClient` for a bridge. They have the client name of the
/// identity, and the redirect URI and the `authorize` callback of the sign-in. Each request
/// gets one step-up flow.
pub fn clientOptions(config: ClientConfig) auth.OAuthClient.Options {
    return .{
        .registration = config.registration,
        .client_name = config.identity.client_name,
        .redirect_uri = config.sign_in.redirectUri(),
        .authorize = config.sign_in.authorize(),
        .max_step_up_attempts = 1,
        .storage = config.storage,
        .storage_identity = config.storage_identity,
        .ca_bundle = config.ca_bundle,
        .proxy = config.proxy,
    };
}

// ---------------------------------------------------------------------------------------------
// The check of an authorization URL
// ---------------------------------------------------------------------------------------------

/// The maximum length of an authorization URL.
pub const max_url_bytes = 8 * 1024;

/// The characters that an authorization URL must not have. A Windows shell parses some of
/// them again, and the bridge refuses all of them on all systems.
const forbidden_url_characters = "\"<>\\^`{|}";

pub const UrlOptions = struct {
    /// Accept `http` for a loopback host. Only tests set it. The executables have no option
    /// and no environment variable for it.
    allow_http: bool = false,
};

pub const UrlError = error{
    /// The URL is empty, or it has more than `max_url_bytes` bytes.
    UrlLength,
    /// A byte is not in the range 0x21 to 0x7E, or it is one of `"<>\^`{|}`, or a `%` does
    /// not start an escape of two hexadecimal digits.
    UrlCharacter,
    /// The scheme is not `https`. An `http` URL needs `allow_http` and a loopback host.
    UrlScheme,
    /// The host is empty, or the URL has user information or a port that is not valid.
    UrlAuthority,
    /// The URL has a fragment.
    UrlFragment,
};

/// Checks an authorization URL before the bridge writes it to stderr or opens it. The
/// authorization server controls the start of the URL. Thus a URL that fails the check never
/// goes to a browser, to a process or to the log.
pub fn validateAuthorizationUrl(url: []const u8, options: UrlOptions) UrlError!void {
    if (url.len == 0 or url.len > max_url_bytes) return error.UrlLength;
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        const c = url[i];
        if (c < 0x21 or c > 0x7e) return error.UrlCharacter;
        if (std.mem.indexOfScalar(u8, forbidden_url_characters, c) != null) return error.UrlCharacter;
        if (c == '%') {
            if (i + 2 >= url.len) return error.UrlCharacter;
            if (!std.ascii.isHex(url[i + 1]) or !std.ascii.isHex(url[i + 2])) return error.UrlCharacter;
            i += 2;
        }
    }
    const sep = std.mem.indexOf(u8, url, "://") orelse return error.UrlScheme;
    const scheme = url[0..sep];
    const is_https = std.ascii.eqlIgnoreCase(scheme, "https");
    const is_http = std.ascii.eqlIgnoreCase(scheme, "http");
    if (!is_https and !(is_http and options.allow_http)) return error.UrlScheme;
    if (std.mem.indexOfScalar(u8, url, '#') != null) return error.UrlFragment;
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..end];
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.UrlAuthority;
    const host = try hostOf(authority);
    if (is_http and !isLoopbackHost(host)) return error.UrlScheme;
}

/// The host of an authority without the port and without the brackets of an IPv6 address.
fn hostOf(authority: []const u8) UrlError![]const u8 {
    var host: []const u8 = authority;
    var port: ?[]const u8 = null;
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.UrlAuthority;
        host = authority[1..close];
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.UrlAuthority;
            port = after[1..];
        }
        for (host) |c| if (!std.ascii.isHex(c) and c != ':' and c != '.') return error.UrlAuthority;
    } else if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = authority[colon + 1 ..];
    }
    if (host.len == 0) return error.UrlAuthority;
    if (port) |p| {
        if (p.len == 0 or p.len > 5) return error.UrlAuthority;
        for (p) |c| if (!std.ascii.isDigit(c)) return error.UrlAuthority;
        const value = std.fmt.parseInt(u32, p, 10) catch return error.UrlAuthority;
        if (value > 65535) return error.UrlAuthority;
    }
    return host;
}

/// True for `localhost`, an address in `127.0.0.0/8` and `::1`.
fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "::1")) return true;
    const ip = Io.net.Ip4Address.parse(host, 0) catch return false;
    return ip.bytes[0] == 127;
}

// ---------------------------------------------------------------------------------------------
// Output and the opener of the browser
// ---------------------------------------------------------------------------------------------

/// The destination of the sign-in line. The default writes to stderr. Tests keep the lines.
pub const Output = struct {
    context: ?*anyopaque = null,
    /// Writes one line. The line ends with a newline.
    write_line: *const fn (context: ?*anyopaque, line: []const u8) void,

    /// Writes each line to stderr with one write under the stderr lock.
    pub const stderr: Output = .{ .write_line = writeStderr };
};

fn writeStderr(context: ?*anyopaque, line: []const u8) void {
    _ = context;
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    const stderr_lock = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    stderr_lock.file_writer.interface.writeAll(line) catch {};
}

pub const OpenerError = error{
    /// The browser did not open.
    BrowserLaunchFailed,
    /// The user did not agree to open the URL, for example in a URL elicitation of the client.
    /// The sign-in ends at once.
    Declined,
    /// The client cannot ask the user to open the URL. The sign-in ends at once.
    NoConsent,
    /// A short time ago, the user declined a sign-in through the client, or such a sign-in
    /// failed. The sign-in ends at once, and the user gets no new question.
    Cooldown,
} || Io.Cancelable;

/// The destination of the URL that an opener gets.
pub const Delivery = enum {
    /// A browser. The opener gets the one-time start URL of the receiver, and not the
    /// authorization URL. On a POSIX host, other local users can read the arguments of the
    /// program that the opener starts.
    browser,
    /// The user, for example in a URL elicitation of the client. The opener gets the
    /// authorization URL, because the user must see the full URL before the consent.
    user,
    /// No destination: the opener opens nothing. The opener gets the authorization URL, and
    /// the receiver serves no start URL.
    none,
};

/// Opens a URL in a browser. Tests give an opener of their own, and the tests never open a
/// browser. `SignIn` checks the URL before it calls the opener.
pub const Opener = struct {
    context: ?*anyopaque = null,
    /// Opens `url`: the start URL for `Delivery.browser`, else the authorization URL. The
    /// function gives `error.Canceled` only after a cancel point of `io` gave it.
    open: *const fn (context: ?*anyopaque, io: Io, url: []const u8) OpenerError!void,
    /// Optional. `SignIn` calls it with the checked URL before the receiver listens and before
    /// the sign-in line. An error ends the sign-in at once: there is no line and no receiver.
    check: ?*const fn (context: ?*anyopaque, url: []const u8) OpenerError!void = null,
    /// Optional. `SignIn` calls it after `check` and before the receiver listens. It gives the
    /// destination of the URL of this sign-in. Null gives `Delivery.browser`.
    delivery: ?*const fn (context: ?*anyopaque) Delivery = null,
    /// Optional. `SignIn` calls it at the end of each sign-in that passed `check`, after the
    /// wait for the redirect. `outcome` is null after a redirect with a code. Else it is the
    /// cause of the failure.
    finish: ?*const fn (context: ?*anyopaque, outcome: ?Reason) void = null,

    /// The browser of the system with the settings of `SystemOpener{}`.
    pub const system: Opener = .{ .open = openSystem };
};

/// The environment variable with the client secret of a pre-registered client.
pub const client_secret_variable = "MCP_BRIDGE_CLIENT_SECRET";

/// The environment variables of the bridge with secrets. The POSIX opener removes them from
/// the environment of the program that it starts. On Windows, `removeFromProcessEnvironment`
/// removes them from the environment of the process.
pub const secret_variables = [_][]const u8{ token_key_variable, client_secret_variable };

/// Removes the variables `names` from the environment of the process on Windows. The browser
/// that `ShellExecuteW` starts gets the environment of the process, and each process that the
/// browser starts gets it too. Thus the URL form removes the variables with secrets before the
/// first sign-in. The bridge reads its environment only from the copy of
/// `std.process.Init.environ_map`, thus the removal does not change the bridge. On the other
/// systems, the function does nothing: the POSIX opener gives its program an environment
/// without these variables. A name that is not valid or that is too long stays.
pub fn removeFromProcessEnvironment(names: []const []const u8) void {
    if (builtin.os.tag != .windows) return;
    for (names) |name| {
        var wide: [256:0]u16 = undefined;
        if (name.len == 0 or name.len >= wide.len) continue;
        const len = std.unicode.wtf8ToWtf16Le(&wide, name) catch continue;
        wide[len] = 0;
        _ = win.SetEnvironmentVariableW(wide[0..len :0], null);
    }
}

/// The settings of the browser opener of the system.
pub const SystemOpener = struct {
    /// The environment of the bridge. On POSIX systems, the opener reads `BROWSER` from it.
    /// The program that the opener starts gets this environment without the variables of
    /// `secret_variables` and `more_secret_variables`. Null gives the program the environment
    /// of the process, and the opener reads no `BROWSER`. On Windows, the browser gets the
    /// environment of the process: call `removeFromProcessEnvironment` first.
    environ_map: ?*const std.process.Environ.Map = null,
    /// The names of more variables with secrets, for example the variables of `--header-env`.
    more_secret_variables: []const []const u8 = &.{},

    /// The opener. The `SystemOpener` must stay valid while the opener lives.
    pub fn opener(self: *const SystemOpener) Opener {
        return .{ .context = @constCast(self), .open = openSystem };
    }
};

/// The time that the POSIX opener waits for the exit status of the program that it starts.
/// A program that runs longer is a browser, and the opener counts it as a success.
const opener_exit_wait: Io.Duration = .fromSeconds(3);

fn openSystem(context: ?*anyopaque, io: Io, url: []const u8) OpenerError!void {
    switch (builtin.os.tag) {
        .windows => return openWindows(url),
        .wasi => return error.BrowserLaunchFailed,
        else => {
            const settings: SystemOpener = if (context) |c| @as(*const SystemOpener, @ptrCast(@alignCast(c))).* else .{};
            return openPosix(io, browserArgv(settings.environ_map, url), settings);
        },
    }
}

/// The argument list of the POSIX opener. The program is `$BROWSER` when it is not empty,
/// else `open` on macOS and `xdg-open` on the other systems. The URL is the only argument,
/// and no shell parses the list.
pub fn browserArgv(environ_map: ?*const std.process.Environ.Map, url: []const u8) [2][]const u8 {
    if (environ_map) |env| if (env.get("BROWSER")) |b| if (b.len > 0) return .{ b, url };
    return .{ if (builtin.os.tag == .macos) "open" else "xdg-open", url };
}

/// The state that the opener and the thread that waits for the program share. The last of
/// the two frees it.
const Reaper = struct {
    io: Io,
    child: std.process.Child,
    exited: Io.Event = .unset,
    failed: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u8) = .init(2),

    fn run(self: *Reaper) void {
        const term = self.child.wait(self.io) catch null;
        const ok = if (term) |t| (t == .exited and t.exited == 0) else false;
        self.failed.store(!ok, .release);
        self.exited.set(self.io);
        self.release();
    }

    fn release(self: *Reaper) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(self);
    }
};

/// Starts the program of `argv` with stdin and stdout on the null device and with the stderr
/// of the bridge. Thus a text browser cannot read or write the MCP pipe. A plain thread waits
/// for the program and collects its exit status.
fn openPosix(io: Io, argv: [2][]const u8, settings: SystemOpener) OpenerError!void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    var child_env: ?std.process.Environ.Map = null;
    if (settings.environ_map) |env| {
        var copy = env.clone(arena_state.allocator()) catch return error.BrowserLaunchFailed;
        for (secret_variables) |name| _ = copy.swapRemove(name);
        for (settings.more_secret_variables) |name| _ = copy.swapRemove(name);
        child_env = copy;
    }
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = if (child_env) |*env| env else null,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => {
            log.warn("the bridge cannot start the browser opener: {t}", .{e});
            return error.BrowserLaunchFailed;
        },
    };
    const reaper = std.heap.page_allocator.create(Reaper) catch {
        child.kill(io);
        return error.BrowserLaunchFailed;
    };
    reaper.* = .{ .io = io, .child = child };
    const thread = std.Thread.spawn(.{}, Reaper.run, .{reaper}) catch {
        reaper.child.kill(io);
        std.heap.page_allocator.destroy(reaper);
        return error.BrowserLaunchFailed;
    };
    thread.detach();
    defer reaper.release();
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = opener_exit_wait, .clock = .awake });
    if (!try waitUntil(io, &reaper.exited, deadline)) return;
    if (reaper.failed.load(.acquire)) {
        log.warn("the browser opener stopped with an error", .{});
        return error.BrowserLaunchFailed;
    }
}

const win = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;

    const COINIT_APARTMENTTHREADED: DWORD = 0x2;
    const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;
    const SW_SHOWNORMAL: c_int = 1;

    extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "shell32" fn ShellExecuteW(
        hwnd: ?*anyopaque,
        lpOperation: ?[*:0]const u16,
        lpFile: [*:0]const u16,
        lpParameters: ?[*:0]const u16,
        lpDirectory: ?[*:0]const u16,
        nShowCmd: c_int,
    ) callconv(.winapi) ?*anyopaque;

    // The access control list of the token key file.
    const ACL = extern struct { AclRevision: u8, Sbz1: u8, AclSize: u16, AceCount: u16, Sbz2: u16 };
    const ACE_HEADER = extern struct { AceType: u8, AceFlags: u8, AceSize: u16 };
    const ACCESS_ALLOWED_ACE = extern struct { Header: ACE_HEADER, Mask: DWORD, SidStart: DWORD };
    const SID_AND_ATTRIBUTES = extern struct { Sid: *anyopaque, Attributes: DWORD };
    const TOKEN_USER = extern struct { User: SID_AND_ATTRIBUTES };

    const SE_FILE_OBJECT: c_int = 1;
    const OWNER_SECURITY_INFORMATION: DWORD = 0x1;
    const DACL_SECURITY_INFORMATION: DWORD = 0x4;
    const PROTECTED_DACL_SECURITY_INFORMATION: DWORD = 0x80000000;
    const TokenUser: c_int = 1;
    const TOKEN_QUERY: DWORD = 0x0008;
    const SECURITY_MAX_SID_SIZE = 68;
    const ACL_REVISION: DWORD = 2;
    const INHERIT_ONLY_ACE: u8 = 0x8;
    const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
    const ACCESS_ALLOWED_OBJECT_ACE_TYPE: u8 = 5;
    const ACCESS_ALLOWED_CALLBACK_ACE_TYPE: u8 = 9;
    const ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE: u8 = 11;
    const WinWorldSid: c_int = 1;
    const WinLocalSystemSid: c_int = 22;
    const WinBuiltinAdministratorsSid: c_int = 26;
    const FILE_ALL_ACCESS: DWORD = 0x001F01FF;
    const FILE_GENERIC_READ: DWORD = 0x00120089;
    /// The rights that let an account read or change the file or its list.
    const sensitive_rights: DWORD = 0x0001 | 0x0002 | 0x0004 | 0x00010000 | 0x00040000 | 0x00080000 | 0x10000000 | 0x40000000 | 0x80000000;

    const TokenUserBuffer = [@sizeOf(TOKEN_USER) + SECURITY_MAX_SID_SIZE]u8;

    extern "advapi32" fn OpenProcessToken(ProcessHandle: windows.HANDLE, DesiredAccess: DWORD, TokenHandle: *windows.HANDLE) callconv(.winapi) c_int;
    extern "advapi32" fn GetTokenInformation(TokenHandle: windows.HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: DWORD, ReturnLength: *DWORD) callconv(.winapi) c_int;
    extern "advapi32" fn EqualSid(pSid1: *anyopaque, pSid2: *anyopaque) callconv(.winapi) c_int;
    extern "advapi32" fn IsWellKnownSid(pSid: *anyopaque, WellKnownSidType: c_int) callconv(.winapi) c_int;
    extern "advapi32" fn GetSecurityInfo(handle: windows.HANDLE, ObjectType: c_int, SecurityInfo: DWORD, ppsidOwner: ?*?*anyopaque, ppsidGroup: ?*?*anyopaque, ppDacl: ?*?*ACL, ppSacl: ?*?*ACL, ppSecurityDescriptor: *?*anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn InitializeAcl(pAcl: *anyopaque, nAclLength: DWORD, dwAclRevision: DWORD) callconv(.winapi) c_int;
    extern "advapi32" fn AddAccessAllowedAce(pAcl: *anyopaque, dwAceRevision: DWORD, AccessMask: DWORD, pSid: *anyopaque) callconv(.winapi) c_int;
    extern "advapi32" fn CreateWellKnownSid(WellKnownSidType: c_int, DomainSid: ?*anyopaque, pSid: *anyopaque, cbSid: *DWORD) callconv(.winapi) c_int;
    extern "advapi32" fn GetLengthSid(pSid: *anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn SetNamedSecurityInfoW(pObjectName: [*:0]u16, ObjectType: c_int, SecurityInfo: DWORD, psidOwner: ?*anyopaque, psidGroup: ?*anyopaque, pDacl: ?*anyopaque, pSacl: ?*anyopaque) callconv(.winapi) DWORD;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const u16, lpValue: ?[*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.winapi) DWORD;

    fn currentUserSid(buf: *align(@alignOf(TOKEN_USER)) TokenUserBuffer) ?*anyopaque {
        var token: windows.HANDLE = undefined;
        if (OpenProcessToken(windows.GetCurrentProcess(), TOKEN_QUERY, &token) == 0) return null;
        defer windows.CloseHandle(token);
        var len: DWORD = 0;
        if (GetTokenInformation(token, TokenUser, buf, buf.len, &len) == 0) return null;
        const user: *const TOKEN_USER = @ptrCast(buf);
        return user.User.Sid;
    }

    /// The user of the process, the local system account and the Administrators group.
    fn trusted(sid: *anyopaque, user: *anyopaque) bool {
        if (EqualSid(sid, user) != 0) return true;
        return IsWellKnownSid(sid, WinLocalSystemSid) != 0 or IsWellKnownSid(sid, WinBuiltinAdministratorsSid) != 0;
    }

    /// True when only trusted accounts own the file and can read or change it.
    fn fileIsPrivate(handle: windows.HANDLE) bool {
        var token_user: TokenUserBuffer align(@alignOf(TOKEN_USER)) = undefined;
        const user = currentUserSid(&token_user) orelse return false;
        var owner: ?*anyopaque = null;
        var dacl: ?*ACL = null;
        var descriptor: ?*anyopaque = null;
        if (GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &owner, null, &dacl, null, &descriptor) != 0) return false;
        defer _ = LocalFree(descriptor);
        if (!trusted(owner orelse return false, user)) return false;
        // A null list gives every account all rights.
        const acl = dacl orelse return false;
        const bytes: [*]const u8 = @ptrCast(acl);
        var offset: usize = @sizeOf(ACL);
        for (0..acl.AceCount) |_| {
            const header: *const ACE_HEADER = @ptrCast(@alignCast(bytes + offset));
            defer offset += header.AceSize;
            if (header.AceFlags & INHERIT_ONLY_ACE != 0) continue;
            const ace: *const ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(header));
            switch (header.AceType) {
                ACCESS_ALLOWED_ACE_TYPE => if (ace.Mask & sensitive_rights != 0 and !trusted(@ptrCast(@constCast(&ace.SidStart)), user)) return false,
                // These types keep the SID at another offset. Refuse them when they give a right.
                ACCESS_ALLOWED_OBJECT_ACE_TYPE, ACCESS_ALLOWED_CALLBACK_ACE_TYPE, ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE => if (ace.Mask & sensitive_rights != 0) return false,
                else => {},
            }
        }
        return true;
    }

    // The listener of the loopback receiver.
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
    const AF_INET: i32 = 2;
    const SOCK_STREAM: i32 = 1;
    const IPPROTO_TCP: i32 = 6;
    const SOL_SOCKET: i32 = 0xffff;
    const SO_REUSEADDR: i32 = 4;
    /// `~SO_REUSEADDR`.
    const SO_EXCLUSIVEADDRUSE: i32 = ~SO_REUSEADDR;
    const WSA_FLAG_OVERLAPPED: DWORD = 0x01;
    const WSA_FLAG_NO_HANDLE_INHERIT: DWORD = 0x80;
    const WSAEADDRINUSE: i32 = 10048;
    const sockaddr_in = extern struct { family: u16 = @intCast(AF_INET), port: u16, addr: u32, zero: [8]u8 = @splat(0) };
    const WSADATA = [512]u8;

    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *align(8) WSADATA) callconv(.winapi) i32;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
    extern "ws2_32" fn WSASocketW(af: i32, ty: i32, protocol: i32, lpProtocolInfo: ?*anyopaque, g: u32, dwFlags: DWORD) callconv(.winapi) SOCKET;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: *const anyopaque, optlen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn getsockname(s: SOCKET, name: *anyopaque, namelen: *i32) callconv(.winapi) i32;
    extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;

    /// Listens on `127.0.0.1:<port>` with `SO_EXCLUSIVEADDRUSE`. The listener of std in Zig
    /// 0.16.0 lets each later listener of std share the port. Then the redirect can go to the
    /// wrong process. The accept of `Io` works on this socket.
    fn listenExclusive(port: u16) error{ AddressInUse, ListenFailed }!Io.net.Server {
        var data: WSADATA align(8) = undefined;
        if (WSAStartup(0x0202, &data) != 0) return error.ListenFailed;
        errdefer _ = WSACleanup();
        const s = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
        if (s == INVALID_SOCKET) return socketFailure("WSASocketW", port);
        errdefer _ = closesocket(s);
        const one: i32 = 1;
        if (setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, &one, @sizeOf(i32)) != 0) return socketFailure("setsockopt", port);
        var address: sockaddr_in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (bind(s, &address, @sizeOf(sockaddr_in)) != 0) {
            if (WSAGetLastError() == WSAEADDRINUSE) return error.AddressInUse;
            return socketFailure("bind", port);
        }
        var len: i32 = @sizeOf(sockaddr_in);
        if (getsockname(s, &address, &len) != 0) return socketFailure("getsockname", port);
        if (listen(s, 16) != 0) return socketFailure("listen", port);
        return .{
            .socket = .{ .handle = @ptrFromInt(s), .address = .{ .ip4 = .loopback(std.mem.bigToNative(u16, address.port)) } },
            .options = .{ .mode = .stream, .protocol = .tcp },
        };
    }

    fn socketFailure(comptime function: []const u8, port: u16) error{ListenFailed} {
        log.warn("the loopback receiver cannot listen on port {d}: " ++ function ++ " failed with Windows Sockets error {d}", .{ port, WSAGetLastError() });
        return error.ListenFailed;
    }

    fn closeListener(server: *Io.net.Server) void {
        _ = closesocket(@intFromPtr(server.socket.handle));
        _ = WSACleanup();
    }

    /// True when a socket with `SO_REUSEADDR` can bind `127.0.0.1:<port>`. For tests. In Zig
    /// 0.16.0, the listen of std reports the refusal of Windows as an unexpected error, and it
    /// writes a stack trace. Thus the test uses this function.
    fn canBindShared(port: u16) bool {
        var data: WSADATA align(8) = undefined;
        if (WSAStartup(0x0202, &data) != 0) return false;
        defer _ = WSACleanup();
        const s = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
        if (s == INVALID_SOCKET) return false;
        defer _ = closesocket(s);
        const one: i32 = 1;
        if (setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(i32)) != 0) return false;
        const address: sockaddr_in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        return bind(s, &address, @sizeOf(sockaddr_in)) == 0;
    }

    /// Gives the file at `path` a protected list: all rights for the user, and read for
    /// Everyone when `everyone` is true. For tests.
    fn setTestAcl(path: []const u8, everyone: bool) !void {
        var token_user: TokenUserBuffer align(@alignOf(TOKEN_USER)) = undefined;
        const user = currentUserSid(&token_user) orelse return error.AccessControlFailed;
        var world: [SECURITY_MAX_SID_SIZE]u8 align(@alignOf(u32)) = undefined;
        var world_len: DWORD = world.len;
        if (CreateWellKnownSid(WinWorldSid, null, &world, &world_len) == 0) return error.AccessControlFailed;
        var acl_buf: [512]u8 align(@alignOf(u32)) = undefined;
        const ace_len = @sizeOf(ACCESS_ALLOWED_ACE) - @sizeOf(DWORD);
        const acl_len: DWORD = @sizeOf(ACL) + 2 * ace_len + GetLengthSid(user) + GetLengthSid(&world);
        if (InitializeAcl(&acl_buf, acl_len, ACL_REVISION) == 0) return error.AccessControlFailed;
        if (AddAccessAllowedAce(&acl_buf, ACL_REVISION, FILE_ALL_ACCESS, user) == 0) return error.AccessControlFailed;
        if (everyone and AddAccessAllowedAce(&acl_buf, ACL_REVISION, FILE_GENERIC_READ, &world) == 0) return error.AccessControlFailed;
        var path_w: [1024:0]u16 = undefined;
        const len = std.unicode.wtf8ToWtf16Le(&path_w, path) catch return error.AccessControlFailed;
        path_w[len] = 0;
        if (SetNamedSecurityInfoW(path_w[0..len :0], SE_FILE_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, null, null, &acl_buf, null) != 0) return error.AccessControlFailed;
    }
} else struct {};

/// Opens `url` with the handler of its scheme. The function never starts cmd.exe, `start`,
/// PowerShell, rundll32 or explorer. A return value of 32 or less from `ShellExecuteW` is a
/// failure.
fn openWindows(url: []const u8) OpenerError!void {
    if (url.len > max_url_bytes) return error.BrowserLaunchFailed;
    var wide: [max_url_bytes + 1]u16 = undefined;
    // The check of the URL allows only ASCII bytes.
    for (url, 0..) |c, i| wide[i] = c;
    wide[url.len] = 0;
    const hr = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED | win.COINIT_DISABLE_OLE1DDE);
    // S_OK and S_FALSE need a call of CoUninitialize. A different apartment model of the
    // thread gives an error, and the call works without COM.
    defer if (hr >= 0) win.CoUninitialize();
    const operation = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const result = win.ShellExecuteW(null, operation, wide[0..url.len :0], null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) {
        log.warn("ShellExecuteW failed with the value {d}", .{@intFromPtr(result)});
        return error.BrowserLaunchFailed;
    }
}

// ---------------------------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------------------------

/// The awake clock in nanoseconds.
fn nowNs(io: Io) i64 {
    return @intCast(Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

/// A duration in nanoseconds, from 0 to the maximum of `i64`.
fn durationNs(d: Io.Duration) i64 {
    if (d.nanoseconds <= 0) return 0;
    return @intCast(@min(d.nanoseconds, std.math.maxInt(i64)));
}

fn awakeAt(ns: i64) Io.Clock.Timestamp {
    return .{ .raw = .fromNanoseconds(ns), .clock = .awake };
}

/// Waits until `event` is set or `deadline` passes. Returns false at the deadline.
fn waitUntil(io: Io, event: *Io.Event, deadline: Io.Clock.Timestamp) Io.Cancelable!bool {
    while (true) {
        event.waitTimeout(io, .{ .deadline = deadline }) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.Timeout => {
                if (event.isSet()) return true;
                if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return false;
                continue;
            },
        };
        return true;
    }
}

/// Sets `value` to `limit` when `limit` is earlier.
fn lowerDeadline(value: *std.atomic.Value(i64), limit: i64) void {
    var cur = value.load(.acquire);
    while (limit < cur) {
        cur = value.cmpxchgWeak(cur, limit, .acq_rel, .acquire) orelse return;
    }
}

/// Closes a connection with a reset on POSIX systems. Thus the port of the receiver keeps no
/// connection in the `TIME_WAIT` state, and the next sign-in can listen on it again at once.
fn abortiveClose(io: Io, stream: Io.net.Stream) void {
    switch (builtin.os.tag) {
        .windows, .wasi => {},
        else => {
            const value: std.posix.linger = .{ .onoff = 1, .linger = 0 };
            std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&value)) catch {};
        },
    }
    stream.close(io);
}

/// Listens on `127.0.0.1:<port>` without `reuse_address`. Thus no other listener shares the
/// port. A port of zero takes a free port.
fn listenLoopback(io: Io, port: u16) Receiver.StartError!Io.net.Server {
    if (builtin.os.tag == .windows) return win.listenExclusive(port);
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    return address.listen(io, .{ .reuse_address = false }) catch |e| switch (e) {
        error.AddressInUse => error.AddressInUse,
        error.Canceled => error.Canceled,
        else => {
            log.warn("the loopback receiver cannot listen on port {d}: {t}", .{ port, e });
            return error.ListenFailed;
        },
    };
}

fn closeListener(io: Io, listener: *Io.net.Server) void {
    if (builtin.os.tag == .windows) return win.closeListener(listener);
    listener.deinit(io);
}

/// Compares two texts in a time that does not depend on the first different byte.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ---------------------------------------------------------------------------------------------
// The loopback receiver
// ---------------------------------------------------------------------------------------------

/// The longest error code of a redirect that the bridge keeps.
pub const max_error_code_len = 48;

/// The `error` code of a redirect. The text comes from the authorization server. Thus the
/// bridge keeps it only when it has the characters of the codes of RFC 6749: lowercase
/// letters and `_`.
pub const ErrorCode = struct {
    buf: [max_error_code_len]u8 = undefined,
    len: u8 = 0,

    pub fn init(text: []const u8) ErrorCode {
        var out: ErrorCode = .{};
        if (text.len == 0 or text.len > max_error_code_len) return out;
        for (text) |c| if (!std.ascii.isLower(c) and c != '_') return out;
        @memcpy(out.buf[0..text.len], text);
        out.len = @intCast(text.len);
        return out;
    }

    /// The code, or null when the bridge did not keep it.
    pub fn slice(self: *const ErrorCode) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }
};

/// Receives the redirect of the browser on `127.0.0.1` for one sign-in. The receiver listens
/// before the browser opens. Each connection has its own task with a limit of the request
/// head and a time limit. Only a `GET` of the callback path with the expected `state` and a
/// second `GET` of the start path end the wait. Each other request gets 404 or 400, and the
/// wait continues.
///
/// The receiver answers each request with a static page and `Connection: close`. It reads no
/// request body, and the page has no text from the request.
///
/// With `Options.start`, the receiver also serves the one-time start path `/start/<token>`:
///
/// - The first `GET` gets `303 See Other` to the authorization URL, with
///   `Cache-Control: no-store`, `Referrer-Policy: no-referrer` and no body.
/// - A second `GET` gets 410 and a page that tells the user to start the sign-in again. It
///   stops the wait with `error.StartReused`, because another program possibly sent one of the
///   two requests. The wait ends after the receiver sent the page.
/// - After the caller of `wait` took a redirect with a code, a second `GET` cannot stop the
///   sign-in. The receiver then writes a warning, and the page of the 410 tells the user that
///   another program possibly signed in with a different account.
/// - A path with a different token gets 404, and the wait continues. Thus a guess cannot stop
///   the sign-in. The compare of the token takes the same time for each token.
/// - After `stop`, the start path does not work, as the callback path.
pub const Receiver = struct {
    io: Io,
    gpa: Allocator,
    limits: Limits,
    listener: Io.net.Server,
    /// The port of the listener.
    port: u16,
    path: []const u8,
    /// The expected `state`, owned.
    state: []u8,
    /// The token of the start path, or null when the receiver serves no start path.
    start_token: ?StartToken = null,
    /// The `Location` of the start path: the checked authorization URL, owned. It is empty
    /// without a start path.
    start_location: []u8 = &.{},
    stopping: std.atomic.Value(bool) = .init(false),
    accept_future: Io.Future(void),
    connections: Io.Group = .init,
    /// The number of connection tasks.
    active: std.atomic.Value(u32) = .init(0),
    /// Guards `conns`, `closing`, `claimed`, `result`, `taken`, `taken_code`, `start_used` and
    /// `start_reused`.
    lock: Io.Mutex = .init,
    conns: std.DoublyLinkedList = .{},
    closing: bool = false,
    /// A request took the redirect. The receiver refuses each later match.
    claimed: bool = false,
    result: ?Callback = null,
    /// `wait` gave the redirect to its caller.
    taken: bool = false,
    /// The redirect of `taken` has a code.
    taken_code: bool = false,
    /// The start path got its `GET`.
    start_used: bool = false,
    /// The start path got a second `GET` before `taken`. The wait ends with
    /// `error.StartReused`.
    start_reused: bool = false,
    aborted: std.atomic.Value(bool) = .init(false),
    /// Set when `result` or `aborted` changes, and after the page of a second `GET` of the
    /// start path (`Connection.work`).
    done: Io.Event = .unset,

    pub const Limits = struct {
        /// The time limit of a connection until the end of the request head.
        head_timeout: Io.Duration = .fromSeconds(10),
        /// The maximum size of a request head.
        max_head_bytes: usize = 16 * 1024,
        /// The maximum number of connections at the same time. The receiver closes each
        /// connection above the limit at once.
        max_connections: u32 = 16,
        /// After the response, the time that the receiver waits for the client to close the
        /// connection. After that time it closes the connection with a reset.
        close_grace: Io.Duration = .fromSeconds(2),
    };

    pub const Options = struct {
        /// The port on `127.0.0.1`. Zero takes a free port: only tests use it.
        port: u16,
        path: []const u8 = callback_path,
        /// The `state` of the authorization request.
        state: []const u8,
        /// The one-time start path, or null.
        start: ?Start = null,
        limits: Limits = .{},
    };

    /// The one-time start path `/start/<token>` of a browser.
    pub const Start = struct {
        /// A random token from `newStartToken`.
        token: StartToken,
        /// The checked authorization URL. The first `GET` of the start path gets it as
        /// `Location`. It has only the bytes 0x21 to 0x7E (`validateAuthorizationUrl`).
        location: []const u8,
    };

    /// The redirect that ended the wait.
    pub const Callback = struct {
        /// The redirect URL `http://127.0.0.1:<port><target>` in the allocator of the
        /// receiver. Its query has the authorization code. Never write it to a log.
        url: []u8,
        outcome: Outcome,
        /// The `error` code of the redirect, for `denied` and `failed`.
        error_code: ErrorCode = .{},

        pub const Outcome = enum {
            /// The redirect has a code.
            code,
            /// The redirect has `error=access_denied`.
            denied,
            /// The redirect has a different error.
            failed,
        };

        /// Erases and frees the URL.
        pub fn deinit(self: *Callback, gpa: Allocator) void {
            std.crypto.secureZero(u8, self.url);
            gpa.free(self.url);
            self.url = &.{};
        }
    };

    pub const StartError = error{
        /// Another socket uses the port.
        AddressInUse,
        /// The receiver cannot listen for another cause. The log has it.
        ListenFailed,
        OutOfMemory,
    } || Io.Cancelable;

    pub const WaitError = error{
        /// The deadline passed.
        Timeout,
        /// `abort` stopped the wait.
        Aborted,
        /// The start path got a second `GET`.
        StartReused,
    } || Io.Cancelable;

    /// Listens on `127.0.0.1:<port>` and starts the accept loop. The receiver must not move
    /// until `stop`. No second listener can share the port and receive the redirect: the
    /// listener never uses `reuse_address`, and on Windows it has `SO_EXCLUSIVEADDRUSE`.
    pub fn start(self: *Receiver, io: Io, gpa: Allocator, options: Options) StartError!void {
        var listener = try listenLoopback(io, options.port);
        errdefer closeListener(io, &listener);
        const state = try gpa.dupe(u8, options.state);
        errdefer gpa.free(state);
        const location: []u8 = if (options.start) |s| try gpa.dupe(u8, s.location) else &.{};
        errdefer gpa.free(location);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .limits = options.limits,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .path = options.path,
            .state = state,
            .start_token = if (options.start) |s| s.token else null,
            .start_location = location,
            .accept_future = undefined,
        };
        self.accept_future = io.concurrent(acceptLoop, .{self}) catch |e| {
            log.warn("the loopback receiver cannot start its accept loop: {t}", .{e});
            return error.ListenFailed;
        };
    }

    /// Waits for the redirect until `deadline`. The caller owns the result and frees it with
    /// `Callback.deinit` and the allocator of the receiver. After the receiver gave its
    /// redirect, no other redirect can arrive, and `wait` gives `error.Timeout` at once.
    pub fn wait(self: *Receiver, deadline: Io.Clock.Timestamp) WaitError!Callback {
        while (true) {
            if (try self.poll()) |callback| return callback;
            if (!try waitUntil(self.io, &self.done, deadline)) {
                if (try self.poll()) |callback| return callback;
                return error.Timeout;
            }
        }
    }

    /// Stops the wait with `error.Aborted`. Another task or thread can call it.
    pub fn abort(self: *Receiver) void {
        self.aborted.store(true, .release);
        self.done.set(self.io);
    }

    /// Stops the accept loop and the connections, and closes the listener. A connection that
    /// has its response gets `Limits.close_grace` to close. The function ignores a cancel of
    /// the task, and it returns when all connection tasks ended.
    pub fn stop(self: *Receiver) void {
        const io = self.io;
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        mcp.util.wake.cancelAcceptLoop(io, &self.accept_future, self.listener.socket.address, &self.stopping);
        {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            self.closing = true;
            const now = nowNs(io);
            var it = self.conns.first;
            while (it) |node| : (it = node.next) {
                const conn: *Connection = @fieldParentPtr("node", node);
                conn.expireForStop(now);
            }
        }
        self.connections.await(io) catch {};
        closeListener(io, &self.listener);
        if (self.result) |*callback| callback.deinit(self.gpa);
        self.result = null;
        std.crypto.secureZero(u8, self.state);
        self.gpa.free(self.state);
        if (self.start_token) |*token| std.crypto.secureZero(u8, token);
        std.crypto.secureZero(u8, self.start_location);
        self.gpa.free(self.start_location);
    }

    /// The state of the wait, under the lock. The function gives one of these values:
    ///
    /// - `error.StartReused` after a second `GET` of the start path. It wins over a redirect
    ///   that the caller did not take.
    /// - The redirect.
    /// - `error.Aborted` after `abort`.
    /// - `error.Timeout` after the caller took the redirect.
    /// - Null.
    ///
    /// A connection task can publish the redirect at each time, thus the function decides
    /// under the lock. After `done` is set, the function never gives null.
    fn poll(self: *Receiver) error{ Aborted, Timeout, StartReused }!?Callback {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.start_reused) return error.StartReused;
        if (self.result) |callback| {
            self.result = null;
            self.taken = true;
            self.taken_code = callback.outcome == .code;
            return callback;
        }
        if (self.aborted.load(.acquire)) return error.Aborted;
        if (self.taken) return error.Timeout;
        return null;
    }

    fn publish(self: *Receiver, callback: Callback) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.result = callback;
        self.done.set(self.io);
    }

    fn track(self: *Receiver, conn: *Connection) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.conns.append(&conn.node);
        // A connection that starts after `stop` began ends at once.
        if (self.closing) conn.expireForStop(nowNs(self.io));
    }

    fn untrack(self: *Receiver, conn: *Connection) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.conns.remove(&conn.node);
    }

    fn acceptLoop(self: *Receiver) void {
        const io = self.io;
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(io) catch |e| switch (e) {
                error.Canceled, error.SocketNotListening => return,
                else => {
                    io.sleep(.fromMilliseconds(10), .awake) catch return;
                    continue;
                },
            };
            // The connection of `cancelAcceptLoop`, or a client during the stop.
            if (self.stopping.load(.acquire)) {
                abortiveClose(io, stream);
                return;
            }
            if (self.active.fetchAdd(1, .acq_rel) >= self.limits.max_connections) {
                _ = self.active.fetchSub(1, .acq_rel);
                abortiveClose(io, stream);
                continue;
            }
            self.connections.concurrent(io, Connection.run, .{ self, stream }) catch {
                _ = self.active.fetchSub(1, .acq_rel);
                abortiveClose(io, stream);
            };
        }
    }

    /// The answer to one request.
    const Verdict = enum {
        /// The redirect with the expected `state`.
        accepted,
        /// The first `GET` of the start path.
        start,
        /// A second `GET` of the start path. It stops the wait.
        start_reused,
        /// A second `GET` of the start path after `wait` gave a redirect with a code to its
        /// caller.
        start_late,
        not_found,
        bad_request,
        too_large,
    };

    /// Decides the answer to one request head. A match claims the redirect and writes it to
    /// `claim`.
    fn evaluate(self: *Receiver, arena: Allocator, head: []const u8, claim: *?Callback) Allocator.Error!Verdict {
        const line = head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len];
        var parts = std.mem.splitScalar(u8, line, ' ');
        const method = parts.next() orelse return .bad_request;
        const target = parts.next() orelse return .bad_request;
        const version = parts.next() orelse return .bad_request;
        if (parts.next() != null) return .bad_request;
        if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) return .bad_request;
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. query_start orelse target.len];
        if (self.start_token != null and std.mem.startsWith(u8, path, start_path_prefix)) {
            return self.evaluateStart(method, path[start_path_prefix.len..]);
        }
        if (!std.mem.eql(u8, path, self.path)) return .not_found;
        if (!std.mem.eql(u8, method, "GET")) return .bad_request;
        const query = if (query_start) |q| target[q + 1 ..] else "";
        const params = try auth.common.parseForm(arena, query);
        const state = params.get("state") orelse return .bad_request;
        if (!constantTimeEql(state, self.state)) return .bad_request;
        const code = params.get("code") orelse "";
        const error_text = params.get("error") orelse "";
        if (code.len == 0 and error_text.len == 0) return .bad_request;

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.claimed or self.closing or self.start_reused) return .bad_request;
        const url = try std.fmt.allocPrint(self.gpa, "http://127.0.0.1:{d}{s}", .{ self.port, target });
        self.claimed = true;
        claim.* = .{
            .url = url,
            .outcome = if (error_text.len == 0) .code else if (std.mem.eql(u8, error_text, "access_denied")) .denied else .failed,
            .error_code = .init(error_text),
        };
        return .accepted;
    }

    /// Decides the answer to a request of the start path. `text` is the part of the path after
    /// `start_path_prefix`.
    fn evaluateStart(self: *Receiver, method: []const u8, text: []const u8) Verdict {
        const token = self.start_token orelse return .not_found;
        // A different token gets 404 and does not stop the wait. Thus a guess cannot stop the
        // sign-in. The length of a token is not secret, and the compare of the bytes takes the
        // same time for each token of that length.
        if (text.len != start_token_len) return .not_found;
        if (!std.crypto.timing_safe.eql(StartToken, text[0..start_token_len].*, token)) return .not_found;
        if (!std.mem.eql(u8, method, "GET")) return .bad_request;
        const verdict = self.useStart();
        if (verdict == .start_late) log.warn("the start URL of the sign-in received a second request after the redirect. Another program possibly signed in with a different account. To be sure, run logout and sign in again", .{});
        return verdict;
    }

    /// Records a `GET` of the start path with the correct token, under the lock.
    fn useStart(self: *Receiver) Verdict {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        // At the deadline, `stop` starts. Then the start path does not work, as the callback.
        if (self.closing) return .not_found;
        if (self.start_used) {
            // The caller has the redirect, thus the sign-in cannot stop. The code of the
            // redirect possibly is for the account of another program.
            if (self.taken) return if (self.taken_code) .start_late else .not_found;
            // Another program possibly opened the start URL. Stop the sign-in. The connection
            // wakes the waiter after the page (`Connection.work`).
            self.start_reused = true;
            return .start_reused;
        }
        // The redirect came without the start URL: the user opened the URL of the sign-in
        // line. The sign-in needs no second authorization request.
        if (self.claimed) return .not_found;
        self.start_used = true;
        return .start;
    }

    const page =
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>Sign-in</title></head>
        \\<body><p>The bridge received the answer of the authorization server. You can close this page.</p></body></html>
        \\
    ;

    const start_reused_page =
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>Sign-in</title></head>
        \\<body><p>The start URL of the sign-in received a second request, thus the bridge stopped the sign-in. Another program on the host of the bridge possibly opened the URL. Start the sign-in again. When this occurs again on a host that other users share, use the option --no-browser of the bridge. You can close this page.</p></body></html>
        \\
    ;

    const start_late_page =
        \\<!doctype html>
        \\<html><head><meta charset="utf-8"><title>Sign-in</title></head>
        \\<body><p>The start URL of the sign-in received a second request after the bridge received the redirect. Another program on the host of the bridge possibly signed in with a different account. To be sure, sign out with the logout command of the bridge, and sign in again. You can close this page.</p></body></html>
        \\
    ;

    /// The head of a page of the receiver without `content-length`.
    const page_head = "content-type: text/html; charset=utf-8\r\ncache-control: no-store\r\n" ++
        "referrer-policy: no-referrer\r\nx-content-type-options: nosniff\r\n" ++
        "content-security-policy: default-src 'none'\r\n";

    /// Writes the response for `verdict`. Only the `Location` of the start path comes from
    /// outside the receiver: it is the checked authorization URL, and it has no line end.
    fn writeResponse(self: *const Receiver, out: *Io.Writer, verdict: Verdict) Io.Writer.Error!void {
        const text: []const u8 = switch (verdict) {
            .accepted => std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\n" ++ page_head ++ "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ page.len, page },
            ),
            .start => {
                try out.writeAll("HTTP/1.1 303 See Other\r\nlocation: ");
                try out.writeAll(self.start_location);
                try out.writeAll("\r\ncache-control: no-store\r\nreferrer-policy: no-referrer\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
                return;
            },
            .start_reused => std.fmt.comptimePrint(
                "HTTP/1.1 410 Gone\r\n" ++ page_head ++ "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ start_reused_page.len, start_reused_page },
            ),
            .start_late => std.fmt.comptimePrint(
                "HTTP/1.1 410 Gone\r\n" ++ page_head ++ "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ start_late_page.len, start_late_page },
            ),
            .not_found => "HTTP/1.1 404 Not Found\r\ncontent-type: text/plain\r\ncontent-length: 10\r\nconnection: close\r\n\r\nnot found\n",
            .bad_request => "HTTP/1.1 400 Bad Request\r\ncontent-type: text/plain\r\ncontent-length: 12\r\nconnection: close\r\n\r\nbad request\n",
            .too_large => "HTTP/1.1 431 Request Header Fields Too Large\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        };
        try out.writeAll(text);
    }

    /// One connection. The connection task supervises the time limit, and a worker task reads
    /// the request and writes the response. At the limit, the connection task cancels the
    /// worker, because on Windows a shutdown of the socket does not stop a read.
    const Connection = struct {
        receiver: *Receiver,
        stream: Io.net.Stream,
        /// The awake time in nanoseconds when the connection must end.
        deadline: std.atomic.Value(i64),
        /// The worker sent its response, and it waits for the end of the input.
        responded: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        /// The client closed the connection first. Only the worker writes it, before
        /// `finished`.
        client_closed: bool = false,
        /// Wakes the connection task for a new deadline or the end of the worker.
        wake: Io.Event = .unset,
        node: std.DoublyLinkedList.Node = .{},

        fn run(r: *Receiver, stream: Io.net.Stream) void {
            const io = r.io;
            defer _ = r.active.fetchSub(1, .acq_rel);
            var conn: Connection = .{
                .receiver = r,
                .stream = stream,
                .deadline = .init(nowNs(io) +| durationNs(r.limits.head_timeout)),
            };
            r.track(&conn);
            defer r.untrack(&conn);
            var worker = io.concurrent(work, .{&conn}) catch {
                abortiveClose(io, stream);
                return;
            };
            conn.supervise(&worker);
            if (conn.client_closed) stream.close(io) else abortiveClose(io, stream);
        }

        /// Waits until the worker ends or the deadline passes, and cancels the worker at the
        /// deadline.
        fn supervise(conn: *Connection, worker: *Io.Future(void)) void {
            const io = conn.receiver.io;
            while (!conn.finished.load(.acquire)) {
                const d = conn.deadline.load(.acquire);
                if (nowNs(io) >= d) break;
                conn.wake.waitTimeout(io, .{ .deadline = awakeAt(d) }) catch |e| switch (e) {
                    error.Timeout => {},
                    error.Canceled => break,
                };
                conn.wake.reset();
            }
            if (conn.finished.load(.acquire)) worker.await(io) else worker.cancel(io);
        }

        /// At the stop: a connection without a response ends at once, and a connection with a
        /// response gets the close grace. The caller holds the lock of the receiver.
        fn expireForStop(conn: *Connection, now: i64) void {
            const r = conn.receiver;
            const limit = if (conn.responded.load(.acquire)) now +| durationNs(r.limits.close_grace) else now;
            lowerDeadline(&conn.deadline, limit);
            conn.wake.set(r.io);
        }

        fn work(conn: *Connection) void {
            const r = conn.receiver;
            const io = r.io;
            var claim: ?Callback = null;
            // A second `GET` of the start path must wake the waiter.
            var reused = false;
            defer {
                // A claimed redirect and the stop of a second `GET` of the start path always
                // reach the waiter, also after a failed write.
                if (claim) |callback| r.publish(callback);
                if (reused) r.done.set(io);
                conn.finished.store(true, .release);
                conn.wake.set(io);
            }
            var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const in_buf = arena.alloc(u8, r.limits.max_head_bytes) catch return;
            var out_buf: [512]u8 = undefined;
            var socket_reader = conn.stream.reader(io, in_buf);
            var socket_writer = conn.stream.writer(io, &out_buf);
            var http_reader: std.http.Reader = .{
                .in = &socket_reader.interface,
                .interface = undefined,
                .state = .ready,
                .max_head_len = in_buf.len,
            };
            const verdict: Verdict = if (http_reader.receiveHead()) |head|
                r.evaluate(arena, head, &claim) catch .bad_request
            else |e| switch (e) {
                error.HttpHeadersOversize => .too_large,
                error.HttpConnectionClosing => {
                    conn.client_closed = true;
                    return;
                },
                error.HttpRequestTruncated, error.ReadFailed => return,
            };
            reused = verdict == .start_reused;
            const out = &socket_writer.interface;
            r.writeResponse(out, verdict) catch return;
            out.flush() catch return;
            // The response is out. Thus the browser has the page before the receiver stops. The
            // close grace starts first, because `stop` gives no grace to a connection without
            // a response.
            conn.startCloseGrace();
            if (claim) |callback| {
                claim = null;
                r.publish(callback);
            }
            if (reused) {
                reused = false;
                r.done.set(io);
            }
            _ = socket_reader.interface.discardRemaining() catch return;
            conn.client_closed = true;
        }

        fn startCloseGrace(conn: *Connection) void {
            const r = conn.receiver;
            lowerDeadline(&conn.deadline, nowNs(r.io) +| durationNs(r.limits.close_grace));
            conn.responded.store(true, .release);
            conn.wake.set(r.io);
        }
    };
};

// ---------------------------------------------------------------------------------------------
// The sign-in
// ---------------------------------------------------------------------------------------------

/// The cause of a failed sign-in.
pub const Reason = enum {
    /// The authorization URL failed `validateAuthorizationUrl`, or it has no `state`, or its
    /// redirect URI is not the redirect URI of the receiver.
    invalid_url,
    /// Another socket uses the redirect port.
    address_in_use,
    /// The receiver cannot listen on the redirect port for a different cause.
    listen_failed,
    /// The browser did not open, and `SignIn.Options.opener_failure_fatal` is set.
    browser_launch_failed,
    /// The opener gave `error.Declined`: the user did not agree to open the URL.
    declined,
    /// The opener gave `error.NoConsent`: the client cannot ask the user to open the URL.
    no_consent,
    /// The opener gave `error.Cooldown`: a short time ago, the user declined a sign-in through
    /// the client, or such a sign-in failed.
    cooldown,
    /// The bridge runs in the sandbox of VS Code (`SignIn.Options.sandboxed`). The sandbox
    /// blocks the browser and the redirect port.
    sandbox,
    /// The redirect did not arrive in the time limit.
    timeout,
    /// The redirect has `error=access_denied`.
    denied,
    /// The redirect has a different error.
    authorization_error,
    /// The start URL got a second `GET`. Another program possibly opened it, thus the bridge
    /// stopped the sign-in.
    start_reused,
    /// An Io cancel stopped the sign-in, for example the cancel of the request.
    canceled,
    /// `SignIn.abort` stopped the sign-in, for example at the end of the input of the client.
    closed,
};

/// A fixed message. The field name lets `zig build lint-docs` check the text.
const Text = struct { message: []const u8 };

fn textOf(reason: Reason) Text {
    return switch (reason) {
        .invalid_url => .{ .message = "The authorization server sent an authorization URL that is not valid. The bridge did not open it." },
        .address_in_use => .{ .message = "Another program uses the redirect port {port}. Stop that program, or set a different port with --redirect-port." },
        .listen_failed => .{ .message = "The bridge cannot listen on the redirect port {port}. Set a different port with --redirect-port." },
        .browser_launch_failed => .{ .message = "The bridge cannot open a browser for the sign-in." },
        .declined => .{ .message = "The user declined the sign-in." },
        .no_consent => .{ .message = "The client cannot ask the user to open the URL of the sign-in, thus the bridge did not start the sign-in." },
        .cooldown => .{ .message = "A sign-in through the client did not complete a short time ago, thus the bridge does not ask the user again yet." },
        .sandbox => .{ .message = "The bridge runs in the sandbox of VS Code, thus it cannot start the sign-in." },
        .timeout => .{ .message = "The sign-in did not complete in {seconds} s." },
        .denied => .{ .message = "The authorization server refused the access." },
        .authorization_error => .{ .message = "The authorization server sent an error for the sign-in." },
        .start_reused => .{ .message = "The start URL of the sign-in received a second request, thus the bridge stopped the sign-in. Another program on the host of the bridge possibly opened the URL. Start the sign-in again. When this occurs again on a host that other users share, use --no-browser." },
        .canceled => .{ .message = "The request stopped before the sign-in completed." },
        .closed => .{ .message = "The client closed the connection before the sign-in completed." },
    };
}

const browser_hint: Text = .{ .message = "The browser did not open. Open the URL of the sign-in line in a browser." };
const code_hint: Text = .{ .message = "The error code is {code}." };

/// The record of a failed sign-in. `write` gives the message for the client and for stderr.
pub const Failure = struct {
    reason: Reason,
    /// The redirect port, for `address_in_use` and `listen_failed`.
    port: u16 = 0,
    /// The time limit in seconds, for `timeout`.
    seconds: u64 = 0,
    /// The browser did not open, also when that was not fatal.
    browser_failed: bool = false,
    /// The `error` code of the redirect, for `authorization_error`.
    error_code: ErrorCode = .{},

    /// Writes the message of the failure, without a newline.
    pub fn write(self: *const Failure, w: *Io.Writer) Io.Writer.Error!void {
        try self.writeTemplate(w, textOf(self.reason).message);
        if (self.reason == .authorization_error and self.error_code.slice() != null) {
            try w.writeByte(' ');
            try self.writeTemplate(w, code_hint.message);
        }
        if (self.reason == .timeout and self.browser_failed) {
            try w.writeByte(' ');
            try self.writeTemplate(w, browser_hint.message);
        }
    }

    pub fn format(self: *const Failure, w: *Io.Writer) Io.Writer.Error!void {
        return self.write(w);
    }

    fn writeTemplate(self: *const Failure, w: *Io.Writer, template: []const u8) Io.Writer.Error!void {
        var rest = template;
        while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
            try w.writeAll(rest[0..open]);
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse {
                rest = rest[open..];
                break;
            };
            const name = rest[open + 1 .. close];
            if (std.mem.eql(u8, name, "port")) {
                try w.print("{d}", .{self.port});
            } else if (std.mem.eql(u8, name, "seconds")) {
                try w.print("{d}", .{self.seconds});
            } else if (std.mem.eql(u8, name, "code")) {
                try w.writeAll(self.error_code.slice() orelse "");
            } else {
                try w.writeAll(rest[open .. close + 1]);
            }
            rest = rest[close + 1 ..];
        }
        try w.writeAll(rest);
    }
};

/// The `authorize` callback of `mcp.auth.OAuthClient` for one bridge. For each sign-in, the
/// callback does these steps:
///
/// 1. It checks the authorization URL with `validateAuthorizationUrl`, and with `Opener.check`
///    when the opener has it.
/// 2. It gets the destination of the URL from `Opener.delivery`. For a browser, it makes a
///    random start token with `newStartToken`.
/// 3. It starts a `Receiver` on the redirect port before the browser opens. For a browser,
///    the receiver also serves the start path `/start/<token>`.
/// 4. It writes the line `<name>: sign in at <url>` to the output one time. The line has the
///    authorization URL. Thus the user can open it when the browser does not open.
/// 5. It opens the URL, unless `no_browser` is set. A browser gets only the start URL
///    `http://127.0.0.1:<port>/start/<token>`. The user gets the authorization URL.
/// 6. It waits for the redirect until the time limit, a cancel or `abort`. A second `GET` of
///    the start URL also ends the wait. Then it calls `Opener.finish` when the opener has it.
///
/// The callback records the cause of each failure (`lastFailure`) and writes the message of
/// the failure to stderr. `OAuthClient` gives the error of the callback to the transport as
/// `AuthorizationFailed`. The `SignIn` must stay at the same address while a client uses it.
pub const SignIn = struct {
    io: Io,
    gpa: Allocator,
    options: Options,
    redirect_buf: [max_redirect_uri_len]u8 = undefined,
    redirect_len: usize = 0,
    /// Guards `current`, `closed` and `failure`.
    lock: Io.Mutex = .init,
    /// The receiver of the sign-in that waits now, or null.
    current: ?*Receiver = null,
    closed: bool = false,
    failure: ?Failure = null,

    pub const Options = struct {
        /// The tag of the sign-in line: the name of the executable.
        name: []const u8,
        /// The port of the redirect URI `http://127.0.0.1:<port>/callback`. It is not zero,
        /// because `OAuthClient` gets the redirect URI before the receiver listens.
        redirect_port: u16 = default_redirect_port,
        /// The time limit of one sign-in, from the start of the receiver.
        timeout: Io.Duration = .fromSeconds(default_sign_in_timeout_s),
        /// Write the sign-in line only, and open no browser. The receiver then serves no start
        /// path, and the user opens the URL of the sign-in line. The command line option
        /// `--no-browser` does not set it: it sets `Authorizer.Options.no_browser`. The top of
        /// this file tells the risk that stays on a host with other users.
        no_browser: bool = false,
        /// The opener of the browser. The bridge gives `SystemOpener.opener` with its
        /// environment, thus the browser gets no secret of the environment.
        opener: Opener = .system,
        /// A browser that does not open ends the sign-in. Else the bridge writes a warning and
        /// waits for the redirect, because the user can open the URL from the sign-in line.
        opener_failure_fatal: bool = false,
        /// The bridge runs in the sandbox of VS Code. Each sign-in then fails at once with the
        /// reason `sandbox`, before the sign-in line and before the receiver listens.
        sandboxed: bool = false,
        output: Output = .stderr,
        limits: Receiver.Limits = .{},
        /// Accept an `http` authorization URL for a loopback host. Only tests set it.
        allow_http: bool = false,
    };

    pub const Error = error{
        /// The sign-in failed. `lastFailure` has the cause.
        SignInFailed,
        OutOfMemory,
    } || Io.Cancelable;

    pub fn init(io: Io, gpa: Allocator, options: Options) SignIn {
        std.debug.assert(options.redirect_port != 0);
        var self: SignIn = .{ .io = io, .gpa = gpa, .options = options };
        self.redirect_len = writeRedirectUri(&self.redirect_buf, options.redirect_port).len;
        return self;
    }

    /// The redirect URI of the receiver. The slice points into the `SignIn`.
    pub fn redirectUri(self: *const SignIn) []const u8 {
        return self.redirect_buf[0..self.redirect_len];
    }

    /// The value of `OAuthClient.Options.authorize`.
    pub fn authorize(self: *SignIn) auth.OAuthClient.Authorize {
        return .{ .callback = .{ .userdata = self, .open = openCallback } };
    }

    /// The cause of the last failed sign-in, or null. A new sign-in clears it.
    pub fn lastFailure(self: *SignIn) ?Failure {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.failure;
    }

    /// Stops the sign-in that waits now, and makes each later sign-in fail at once. The bridge
    /// calls it at the end of the input of the client. Another task or thread can call it.
    pub fn abort(self: *SignIn) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.closed = true;
        if (self.current) |r| r.abort();
    }

    fn openCallback(userdata: ?*anyopaque, arena: Allocator, url: []const u8) anyerror![]const u8 {
        const self: *SignIn = @ptrCast(@alignCast(userdata.?));
        return self.run(arena, url);
    }

    /// Runs one sign-in for the authorization URL `url` and returns the redirect URL in
    /// `arena`. A cancel of the task gives `error.Canceled`, and the next cancel point of the
    /// task gives it again.
    pub fn run(self: *SignIn, arena: Allocator, url: []const u8) Error![]const u8 {
        var canceled = false;
        const result = self.flow(arena, url, &canceled);
        // `flow` released the receiver. Now the next cancel point of the task sees the cancel.
        if (canceled) self.io.recancel();
        return result;
    }

    fn flow(self: *SignIn, arena: Allocator, url: []const u8, canceled: *bool) Error![]const u8 {
        const io = self.io;
        self.setFailure(null);
        if (self.isClosed()) return self.fail(.{ .reason = .closed });
        if (self.options.sandboxed) return self.fail(.{ .reason = .sandbox });
        validateAuthorizationUrl(url, .{ .allow_http = self.options.allow_http }) catch |e| {
            log.warn("the authorization URL is not valid ({t}), thus the bridge does not open it", .{e});
            return self.fail(.{ .reason = .invalid_url });
        };
        const params = try auth.common.parseQuery(arena, url);
        const state = params.get("state") orelse "";
        if (state.len == 0) {
            log.warn("the authorization URL has no state, thus the bridge does not open it", .{});
            return self.fail(.{ .reason = .invalid_url });
        }
        if (params.get("redirect_uri")) |uri| if (!std.mem.eql(u8, uri, self.redirectUri())) {
            log.warn("the redirect URI of the authorization URL is not the redirect URI of the receiver", .{});
            return self.fail(.{ .reason = .invalid_url });
        };
        const opener = self.options.opener;
        if (opener.check) |check| check(opener.context, url) catch |e| return self.openerFailure(e, canceled);
        // The defers below run first. Thus the receiver is closed when `finish` runs.
        defer if (opener.finish) |finish| finish(opener.context, self.failureReason());

        // A browser gets the one-time start URL, and never the authorization URL. Without a
        // token, the bridge does not open the browser: the user opens the URL of the line.
        const delivery: Delivery = if (self.options.no_browser) .none else if (opener.delivery) |d| d(opener.context) else .browser;
        var token: ?StartToken = null;
        defer if (token) |*t| std.crypto.secureZero(u8, t);
        if (delivery == .browser) {
            token = newStartToken(io) catch |e| switch (e) {
                error.Canceled => {
                    canceled.* = true;
                    return self.fail(.{ .reason = .canceled });
                },
                error.EntropyUnavailable => null,
            };
            if (token == null) log.warn("the bridge has no random data for the start URL, thus it does not open the browser", .{});
        }

        var receiver: Receiver = undefined;
        receiver.start(io, self.gpa, .{
            .port = self.options.redirect_port,
            .state = state,
            .start = if (token) |t| .{ .token = t, .location = url } else null,
            .limits = self.options.limits,
        }) catch |e| switch (e) {
            error.AddressInUse => return self.fail(.{ .reason = .address_in_use, .port = self.options.redirect_port }),
            error.Canceled => {
                canceled.* = true;
                return self.fail(.{ .reason = .canceled });
            },
            error.ListenFailed, error.OutOfMemory => return self.fail(.{ .reason = .listen_failed, .port = self.options.redirect_port }),
        };
        defer receiver.stop();
        if (!self.register(&receiver)) return self.fail(.{ .reason = .closed });
        defer self.unregister();

        const line = try std.mem.concat(arena, u8, &.{ self.options.name, ": sign in at ", url, "\n" });
        self.options.output.write_line(self.options.output.context, line);

        // The time limit starts before the opener, because the opener can take some seconds.
        const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = self.options.timeout, .clock = .awake });
        var browser_failed = false;
        if (!self.options.no_browser) {
            var start_buf: [max_start_url_len]u8 = undefined;
            const target: ?[]const u8 = switch (delivery) {
                .browser => if (token) |*t| writeStartUrl(&start_buf, receiver.port, t) else null,
                .user, .none => url,
            };
            const opened: OpenerError!void = if (target) |t| opener.open(opener.context, io, t) else error.BrowserLaunchFailed;
            opened catch |e| switch (e) {
                error.BrowserLaunchFailed => {
                    browser_failed = true;
                    if (self.options.opener_failure_fatal) return self.fail(.{ .reason = .browser_launch_failed });
                    log.warn("the browser did not open: open the URL of the sign-in line in a browser", .{});
                },
                else => |other| return self.openerFailure(other, canceled),
            };
        }

        var callback = receiver.wait(deadline) catch |e| switch (e) {
            error.Timeout => return self.fail(.{
                .reason = .timeout,
                .seconds = @intCast(@divFloor(durationNs(self.options.timeout) +| (std.time.ns_per_s - 1), std.time.ns_per_s)),
                .browser_failed = browser_failed,
            }),
            error.Aborted => return self.fail(.{ .reason = .closed }),
            error.StartReused => return self.fail(.{ .reason = .start_reused }),
            error.Canceled => {
                canceled.* = true;
                return self.fail(.{ .reason = .canceled });
            },
        };
        defer callback.deinit(self.gpa);
        return switch (callback.outcome) {
            .code => try arena.dupe(u8, callback.url),
            .denied => self.fail(.{ .reason = .denied, .error_code = callback.error_code }),
            .failed => self.fail(.{ .reason = .authorization_error, .error_code = callback.error_code }),
        };
    }

    /// Records the failure for an error of the opener and returns the error of the sign-in.
    fn openerFailure(self: *SignIn, err: OpenerError, canceled: *bool) Error {
        return switch (err) {
            error.Canceled => {
                canceled.* = true;
                return self.fail(.{ .reason = .canceled });
            },
            error.BrowserLaunchFailed => self.fail(.{ .reason = .browser_launch_failed }),
            error.Declined => self.fail(.{ .reason = .declined }),
            error.NoConsent => self.fail(.{ .reason = .no_consent }),
            error.Cooldown => self.fail(.{ .reason = .cooldown }),
        };
    }

    /// The reason of the recorded failure, or null.
    fn failureReason(self: *SignIn) ?Reason {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return if (self.failure) |f| f.reason else null;
    }

    fn isClosed(self: *SignIn) bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.closed;
    }

    fn register(self: *SignIn, receiver: *Receiver) bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.closed) return false;
        self.current = receiver;
        return true;
    }

    fn unregister(self: *SignIn) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.current = null;
    }

    fn setFailure(self: *SignIn, failure: ?Failure) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.failure = failure;
    }

    /// Records `failure`, writes its message to stderr, and returns the error of the sign-in.
    fn fail(self: *SignIn, failure: Failure) Error {
        self.setFailure(failure);
        switch (failure.reason) {
            // The user or the client stopped the sign-in. This is not a fault of the bridge.
            .canceled, .closed, .declined, .cooldown => log.info("{f}", .{&failure}),
            else => log.warn("{f}", .{&failure}),
        }
        return if (failure.reason == .canceled) error.Canceled else error.SignInFailed;
    }
};

// ---------------------------------------------------------------------------------------------
// When the browser may open
// ---------------------------------------------------------------------------------------------

/// The number of a URL elicitation of the client for a sign-in.
pub const Ticket = u64;

pub const ConsentError = error{
    /// The user declined or canceled the URL, or the client did not answer in the time limit,
    /// or it answered with an error.
    Declined,
    OutOfMemory,
} || Io.Cancelable;

/// The client of the bridge asks the user to open the URL of a sign-in, as a URL elicitation.
/// The front end gives this interface after `notifications/initialized` when the client
/// declared URL elicitation. The client shows the full URL, asks the user, and opens the URL
/// after the user accepted.
pub const Consent = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Asks the user to open `url`, and waits at most `timeout` for the answer. Returns the
        /// ticket of the elicitation after the user accepted. A cancel of the task gives
        /// `error.Canceled`.
        ask: *const fn (context: *anyopaque, io: Io, url: []const u8, timeout: Io.Duration) ConsentError!Ticket,
        /// Tells the client that the elicitation `ticket` is complete.
        complete: *const fn (context: *anyopaque, ticket: Ticket) void,
    };
};

/// The default time after a declined or failed sign-in through the client. In this time, the
/// bridge asks the user no new question.
pub const default_consent_cooldown_s: u32 = 60;

/// Decides how the URL of a sign-in gets to the user. `opener` gives the `Opener` of a
/// `SignIn`, which must have `no_browser = false`.
///
/// - Before `notifications/initialized`, the gate opens the browser directly. This is the
///   first sign-in, and the user configured the server for it. The browser gets the start URL
///   (`Delivery.browser`).
/// - After it (`useConsent`), the gate never opens the browser. It asks the client through
///   `Consent`, and the client asks the user. The client gets the authorization URL
///   (`Delivery.user`). After the redirect, the client gets the completion of its
///   elicitation. Without `Consent`, each sign-in fails at once.
/// - When the user declined a sign-in through the client, the gate asks no new question until
///   the cooldown ends. The same applies when such a sign-in failed after the question. The
///   cooldown applies to all scopes, because the upstream server chooses the scopes of each
///   challenge. A sign-in that failed before the question, for example at the redirect port,
///   starts no cooldown.
///
/// `OAuthClient` runs one sign-in at a time. Thus the gate keeps the state of one sign-in.
pub const Gate = struct {
    io: Io,
    /// The opener before `notifications/initialized`. Null only writes the sign-in line.
    direct: ?Opener,
    /// The time that the client gets for the answer to a URL elicitation.
    consent_timeout: Io.Duration,
    cooldown: Io.Duration,
    /// Guards the fields below.
    lock: Io.Mutex = .init,
    /// True after `useConsent`.
    after_initialized: bool = false,
    consent: ?Consent = null,
    /// The client of the sign-in that runs now, or null for the direct opener.
    flow_consent: ?Consent = null,
    /// The client asked the user about the sign-in that runs now.
    flow_asked: bool = false,
    /// The elicitation of the sign-in that runs now, after the user accepted it.
    flow_ticket: ?Ticket = null,
    /// The awake time in nanoseconds at the end of the cooldown, or 0.
    cooldown_until: i64 = 0,

    pub fn init(io: Io, direct: ?Opener, consent_timeout: Io.Duration, cooldown: Io.Duration) Gate {
        return .{ .io = io, .direct = direct, .consent_timeout = consent_timeout, .cooldown = cooldown };
    }

    pub fn deinit(self: *Gate) void {
        self.* = undefined;
    }

    /// The opener of the gate. The gate must stay at the same address while a sign-in uses it.
    pub fn opener(self: *Gate) Opener {
        return .{ .context = self, .open = open, .check = check, .delivery = delivery, .finish = finish };
    }

    /// Call it after `notifications/initialized`. From now on, the gate asks the user through
    /// `consent`. Null: the client cannot ask the user, thus each later sign-in fails at once.
    pub fn useConsent(self: *Gate, consent: ?Consent) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.after_initialized = true;
        self.consent = consent;
    }

    fn check(context: ?*anyopaque, url: []const u8) OpenerError!void {
        _ = url;
        const self: *Gate = @ptrCast(@alignCast(context.?));
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.clearFlow();
        if (!self.after_initialized) return;
        const consent = self.consent orelse return error.NoConsent;
        if (nowNs(self.io) < self.cooldown_until) return error.Cooldown;
        self.flow_consent = consent;
    }

    /// The destination of the sign-in that `check` accepted. The client gets the authorization
    /// URL (`Delivery.user`), because the user must see the full URL before the consent. The
    /// direct opener gets the start URL. Without a direct opener, the gate opens nothing.
    fn delivery(context: ?*anyopaque) Delivery {
        const self: *Gate = @ptrCast(@alignCast(context.?));
        self.lock.lockUncancelable(self.io);
        const asks = self.flow_consent != null;
        self.lock.unlock(self.io);
        if (asks) return .user;
        const direct = self.direct orelse return .none;
        const d = direct.delivery orelse return .browser;
        return d(direct.context);
    }

    fn open(context: ?*anyopaque, io: Io, url: []const u8) OpenerError!void {
        const self: *Gate = @ptrCast(@alignCast(context.?));
        self.lock.lockUncancelable(self.io);
        const consent = self.flow_consent;
        if (consent != null) self.flow_asked = true;
        self.lock.unlock(self.io);
        const c = consent orelse {
            const direct = self.direct orelse return;
            return direct.open(direct.context, io, url);
        };
        // The wait for the answer of the user holds no lock of the gate.
        const ticket = c.vtable.ask(c.context, io, url, self.consent_timeout) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.Declined, error.OutOfMemory => return error.Declined,
        };
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.flow_ticket = ticket;
    }

    fn finish(context: ?*anyopaque, outcome: ?Reason) void {
        const self: *Gate = @ptrCast(@alignCast(context.?));
        var completion: ?struct { Consent, Ticket } = null;
        {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            if (self.flow_consent) |c| {
                if (self.flow_ticket) |t| completion = .{ c, t };
                if (outcome) |reason| {
                    if (startsCooldown(reason, self.flow_asked)) self.cooldown_until = nowNs(self.io) +| durationNs(self.cooldown);
                } else self.cooldown_until = 0;
            }
            self.clearFlow();
        }
        if (completion) |c| c[0].vtable.complete(c[0].context, c[1]);
    }

    /// True when the failure `reason` of a sign-in through the client starts the cooldown.
    /// `asked` is true when the client asked the user. A cancel of the request and the end of
    /// the connection are not a decision of the user.
    fn startsCooldown(reason: Reason, asked: bool) bool {
        return switch (reason) {
            .canceled, .closed => false,
            else => asked,
        };
    }

    fn clearFlow(self: *Gate) void {
        self.flow_consent = null;
        self.flow_asked = false;
        self.flow_ticket = null;
    }
};

// ---------------------------------------------------------------------------------------------
// The authorization of the upstream requests
// ---------------------------------------------------------------------------------------------

/// How the bridge gets a client ID from the authorization server. The command line gives the
/// first that applies: a pre-registered client, a client ID metadata document, or dynamic
/// client registration.
pub const Registration = union(enum) {
    /// A client that the authorization server issued.
    pre_registered: PreRegistered,
    /// The URL of a client ID metadata document. The authorization server uses it when it
    /// supports such documents. Else the bridge uses dynamic client registration.
    client_metadata_url: []const u8,
    /// Dynamic client registration only.
    dynamic,

    pub const PreRegistered = struct {
        client_id: []const u8,
        /// The issuer of the client. Null binds the client to the first authorization server
        /// that the upstream server names. The bridge does not trust the upstream server. Thus
        /// give an issuer for each client with a secret: the command line refuses a secret
        /// without `--client-issuer`.
        issuer: ?[]const u8 = null,
        /// The client secret from the environment, or null for a public client.
        client_secret: ?[]const u8 = null,
    };
};

/// The record of a challenge of the upstream server that the bridge did not answer.
pub const Problem = struct {
    /// Each new problem has a larger number.
    generation: u64,
    /// The HTTP status of the challenge: 401 or 403.
    status: u16,
    err: auth.OAuthClient.Error,
    /// The failure of the sign-in, for `error.AuthorizationFailed`.
    sign_in: ?Failure = null,
    /// The answer of the authorization server to a failed registration or token request.
    answer: ?Answer = null,

    pub const Answer = struct {
        step: auth.OAuthClient.Failure.Step,
        /// The HTTP status, or 0 when the request did not complete.
        status: u16,
        /// The `error` code of the answer.
        code: ErrorCode = .{},
    };
};

/// The authorization of the requests to an HTTP upstream server. It holds the
/// `mcp.auth.OAuthClient` of the bridge, its `SignIn`, its `Gate` and its token storage with
/// the index of the stored sign-ins. `provider` gives the provider for the HTTP client
/// transport. The provider records the error of each challenge that it did not answer
/// (`lastProblem`), because the transport gives the request only `error.HttpStatus`. The front
/// end then answers with a message that names the option to use and the redirect URI.
///
/// The `Authorizer` must not move after `init`.
pub const Authorizer = struct {
    io: Io,
    gpa: Allocator,
    identity: Identity,
    /// The URL of the upstream server, owned.
    server_url: []u8,
    /// The value of `Identity.clientIdentity`, owned.
    storage_identity: []u8,
    credentials: [1]auth.OAuthClient.Credentials = undefined,
    /// The client ID of a pre-registered client, or null.
    client_id: ?[]const u8 = null,
    sign_in: SignIn,
    gate: Gate,
    indexed: IndexedStorage,
    client: auth.OAuthClient,
    sandboxed: bool,
    /// The number of challenges that the provider answered with a token. A listen stream
    /// that got 401 or 403 waits until it changes (`notify.Options.sign_ins`).
    answered: std.atomic.Value(u64) = .init(0),
    /// Guards `problem`, `generation` and `on_answer`.
    lock: Io.Mutex = .init,
    problem: ?Problem = null,
    generation: u64 = 0,
    on_answer: ?Hook = null,

    /// A function that the provider calls after each challenge that it answered with a token.
    /// It runs on the task of the request, thus it must not wait.
    pub const Hook = struct {
        context: *anyopaque,
        call: *const fn (context: *anyopaque) void,
    };

    pub const Options = struct {
        identity: Identity,
        /// The URL of the upstream server.
        server_url: []const u8,
        /// The account label of `--account`. It is a part of the storage identity.
        account: []const u8 = default_account,
        redirect_port: u16 = default_redirect_port,
        /// The slices must stay valid while the `Authorizer` lives.
        registration: Registration = .dynamic,
        /// The token storage, for example `TokenStore.storage`. It must stay valid while the
        /// `Authorizer` lives.
        storage: auth.TokenStorage,
        /// The trust of the requests to the authorization server. Give the bundle of the MCP
        /// connection.
        ca_bundle: ?*const std.crypto.Certificate.Bundle = null,
        /// The proxy of the requests to the authorization server, as for the MCP connection.
        proxy: mcp.transport.proxy.Config = .{ .environment = null },
        /// The time limit of one sign-in.
        timeout: Io.Duration = .fromSeconds(default_sign_in_timeout_s),
        /// Before `notifications/initialized`, write the sign-in line only and open no
        /// browser. The receiver then serves no start path. After it, the client gets the
        /// authorization URL also with this setting. This is `--no-browser`.
        no_browser: bool = false,
        /// The opener of the browser before `notifications/initialized`.
        opener: Opener = .system,
        output: Output = .stderr,
        limits: Receiver.Limits = .{},
        /// The bridge runs in the sandbox of VS Code (`SANDBOX_RUNTIME=1`). Then each sign-in
        /// fails at once with the reason `sandbox`.
        sandboxed: bool = false,
        consent_cooldown: Io.Duration = .fromSeconds(default_consent_cooldown_s),
        /// Accept `http` for the endpoints of a loopback authorization server and for the
        /// authorization URL. Only tests set it. The executables have no option and no
        /// environment variable for it.
        allow_http: bool = false,
    };

    pub fn init(self: *Authorizer, io: Io, gpa: Allocator, options: Options) Allocator.Error!void {
        const server_url = try gpa.dupe(u8, options.server_url);
        errdefer gpa.free(server_url);
        var buf: [max_redirect_uri_len]u8 = undefined;
        const storage_identity = try options.identity.clientIdentity(gpa, options.account, writeRedirectUri(&buf, options.redirect_port), options.registration);
        errdefer gpa.free(storage_identity);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .identity = options.identity,
            .server_url = server_url,
            .storage_identity = storage_identity,
            .sign_in = .init(io, gpa, .{
                .name = options.identity.bridge_name,
                .redirect_port = options.redirect_port,
                .timeout = options.timeout,
                .opener = undefined,
                .opener_failure_fatal = options.sandboxed,
                .sandboxed = options.sandboxed,
                .output = options.output,
                .limits = options.limits,
                .allow_http = options.allow_http,
            }),
            .gate = .init(io, if (options.no_browser) null else options.opener, options.timeout, options.consent_cooldown),
            .indexed = .{ .io = io, .gpa = gpa, .inner = options.storage, .identity = options.identity, .server_url = server_url },
            .client = undefined,
            .sandboxed = options.sandboxed,
        };
        self.sign_in.options.opener = self.gate.opener();
        const registration: auth.OAuthClient.Registration = switch (options.registration) {
            .pre_registered => |p| registration: {
                self.credentials[0] = .{ .issuer = p.issuer, .client_id = p.client_id, .client_secret = p.client_secret };
                self.client_id = p.client_id;
                break :registration .{ .pre_registered = &self.credentials };
            },
            .client_metadata_url => |u| .{ .client_metadata_url = u },
            .dynamic => .dynamic,
        };
        var client_options = clientOptions(.{
            .identity = options.identity,
            .sign_in = &self.sign_in,
            .registration = registration,
            .storage = self.indexed.storage(),
            .storage_identity = self.storage_identity,
            .ca_bundle = options.ca_bundle,
            .proxy = options.proxy,
        });
        client_options.allow_http = options.allow_http;
        self.client = .init(io, gpa, client_options);
    }

    pub fn deinit(self: *Authorizer) void {
        self.client.deinit();
        self.gate.deinit();
        self.gpa.free(self.storage_identity);
        self.gpa.free(self.server_url);
        self.* = undefined;
    }

    /// The provider for `Upstream.Auth`: the provider of `OAuthClient` that also records the
    /// error of each challenge that it did not answer.
    pub fn provider(self: *Authorizer) auth.Provider {
        return .{ .ptr = self, .vtable = &provider_vtable };
    }

    /// The redirect URI `http://127.0.0.1:<port>/callback`.
    pub fn redirectUri(self: *const Authorizer) []const u8 {
        return self.sign_in.redirectUri();
    }

    /// The time limit of one sign-in.
    pub fn signInTimeout(self: *const Authorizer) Io.Duration {
        return self.sign_in.options.timeout;
    }

    /// The number of the last problem, or 0. Read it before a request. After the request
    /// failed, `problemSince` gives a newer problem.
    pub fn problemGeneration(self: *Authorizer) u64 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.generation;
    }

    /// The last problem when it is newer than `generation`, else null.
    pub fn problemSince(self: *Authorizer, generation: u64) ?Problem {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const p = self.problem orelse return null;
        return if (p.generation > generation) p else null;
    }

    /// Call it after `notifications/initialized` (`Gate.useConsent`).
    pub fn useConsent(self: *Authorizer, consent: ?Consent) void {
        self.gate.useConsent(consent);
    }

    /// Stops the sign-in that waits now, and makes each later sign-in fail at once. The bridge
    /// calls it at the end of the input of the client.
    pub fn abort(self: *Authorizer) void {
        self.sign_in.abort();
    }

    /// Sets the function that the provider calls after each challenge that it answered with a
    /// token, or null. The front end sets it to wake its listen stream after a sign-in.
    pub fn setAnswerHook(self: *Authorizer, hook: ?Hook) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.on_answer = hook;
    }

    /// The refresh margin of `OAuthClient`: it refreshes an access token that expires in this
    /// number of seconds.
    const refresh_margin_s: i64 = (auth.OAuthClient.Options{}).refresh_margin_seconds;

    /// True when a request can start an interactive sign-in: the storage has no usable token
    /// for the upstream server and the account. The index gives the keys of the records of the
    /// upstream server. A record is usable only when it has an access token that does not
    /// expire in the refresh margin of `OAuthClient`. A refresh token alone is not sufficient:
    /// the authorization server can refuse it, and then the same request starts a sign-in in
    /// the browser. A pre-registered client also needs a record with its client ID.
    pub fn interactive(self: *Authorizer) bool {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const storage = self.indexed.inner;
        // A cancel stays for the next cancel point of the task.
        const entries = loadIndex(arena_state.allocator(), storage, self.identity) catch |err| {
            if (err == error.Canceled) self.io.recancel();
            return true;
        };
        const now = Io.Clock.Timestamp.now(self.io, .real).raw.toSeconds();
        for (entries) |e| {
            if (!std.mem.eql(u8, e.url, self.server_url) or !std.mem.eql(u8, e.client, self.storage_identity)) continue;
            var stored = (storage.load(self.gpa, e.key()) catch |err| {
                if (err == error.Canceled) {
                    self.io.recancel();
                    return true;
                }
                continue;
            }) orelse continue;
            defer stored.deinit(self.gpa);
            if (self.usable(stored, now)) return false;
        }
        return true;
    }

    /// True when `record` has an access token that does not expire in the refresh margin after
    /// `now`, in seconds. A pre-registered client also needs its client ID in the record.
    fn usable(self: *const Authorizer, record: auth.token_storage.Record, now: i64) bool {
        if (record.access_token == null) return false;
        if (record.expires_at) |expires| if (expires <= now +| refresh_margin_s) return false;
        if (self.client_id) |id| {
            const registration = record.registration orelse return false;
            if (!std.mem.eql(u8, registration.client_id, id)) return false;
        }
        return true;
    }

    const provider_vtable: auth.Provider.VTable = .{
        .token = providerToken,
        .handle_challenge = providerChallenge,
        .credentials = providerCredentials,
        .dpop_nonce = providerNonce,
    };

    fn providerToken(ptr: *anyopaque, arena: Allocator) ?[]const u8 {
        const self: *Authorizer = @ptrCast(@alignCast(ptr));
        return self.client.provider().token(arena);
    }

    fn providerCredentials(ptr: *anyopaque, arena: Allocator, method: []const u8, url: []const u8) ?auth.common.Credentials {
        const self: *Authorizer = @ptrCast(@alignCast(ptr));
        return self.client.provider().credentials(arena, method, url);
    }

    fn providerNonce(ptr: *anyopaque, url: []const u8, nonce: []const u8) void {
        const self: *Authorizer = @ptrCast(@alignCast(ptr));
        self.client.provider().rememberDpopNonce(url, nonce);
    }

    fn providerChallenge(ptr: *anyopaque, arena: Allocator, server_url: []const u8, status: u16, www_authenticate: ?[]const u8, attempt: u8) anyerror!void {
        const self: *Authorizer = @ptrCast(@alignCast(ptr));
        _ = self.client.handleChallenge(arena, server_url, status, www_authenticate, attempt) catch |e| {
            self.recordProblem(arena, e, status);
            return e;
        };
        _ = self.answered.fetchAdd(1, .release);
        self.lock.lockUncancelable(self.io);
        const hook = self.on_answer;
        self.lock.unlock(self.io);
        if (hook) |h| h.call(h.context);
    }

    /// Records the error `err` of a challenge with the HTTP status `status`.
    fn recordProblem(self: *Authorizer, arena: Allocator, err: auth.OAuthClient.Error, status: u16) void {
        var problem: Problem = .{ .generation = 0, .status = status, .err = err };
        if (err == error.AuthorizationFailed) problem.sign_in = self.sign_in.lastFailure();
        if (err == error.RegistrationFailed or err == error.TokenRequestFailed) {
            if (self.client.lastFailure(arena) catch null) |f| problem.answer = .{
                .step = f.step,
                .status = f.status,
                .code = .init(f.code orelse ""),
            };
        }
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.generation += 1;
        problem.generation = self.generation;
        self.problem = problem;
    }
};

// ---------------------------------------------------------------------------------------------
// The index of the stored sign-ins, and logout
// ---------------------------------------------------------------------------------------------

/// The issuer and the resource of the key of the index. The text is not a URL, thus no record
/// of `OAuthClient` has this key.
const index_marker = "urn:zig-bridge-sdk:index";

/// The maximum number of entries in the index. A new entry above the limit replaces the oldest
/// entry.
pub const max_index_entries = 256;

/// One stored sign-in: the URL of the upstream server and the key of its record.
pub const IndexEntry = struct {
    url: []const u8,
    issuer: []const u8,
    resource: []const u8,
    /// The storage identity of the record.
    client: []const u8,

    pub fn key(self: IndexEntry) auth.token_storage.Key {
        return .{ .issuer = self.issuer, .resource = self.resource, .client = self.client };
    }
};

/// The key of the index of a bridge in its token storage. The index is in the same storage as
/// the records: in the keychain service of the bridge, or in the file store.
pub fn indexKey(identity: Identity) auth.token_storage.Key {
    return .{ .issuer = index_marker, .resource = index_marker, .client = identity.bridge_name };
}

const IndexDocument = struct {
    version: u32 = 1,
    entries: []const IndexEntry = &.{},
};

/// The entries of the index in `storage`, in `arena`. An index that is not valid has no entries.
pub fn loadIndex(arena: Allocator, storage: auth.TokenStorage, identity: Identity) auth.TokenStorage.Error![]const IndexEntry {
    const data = storage.vtable.load(storage.ptr, arena, indexKey(identity)) catch |e| switch (e) {
        error.InvalidRecord => return &.{},
        else => return e,
    } orelse return &.{};
    const doc = std.json.parseFromSliceLeaky(IndexDocument, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        log.warn("the index of the stored sign-ins is not valid, thus the bridge ignores it", .{});
        return &.{};
    };
    if (doc.version != 1) return &.{};
    return doc.entries;
}

/// Writes the index. An empty index deletes its record.
fn saveIndex(gpa: Allocator, storage: auth.TokenStorage, identity: Identity, entries: []const IndexEntry) auth.TokenStorage.Error!void {
    if (entries.len == 0) return storage.vtable.delete(storage.ptr, indexKey(identity));
    const text = try mcp.json.writeAlloc(gpa, IndexDocument{ .entries = entries });
    defer gpa.free(text);
    return storage.vtable.save(storage.ptr, indexKey(identity), text);
}

fn sameKey(entry: IndexEntry, key: auth.token_storage.Key) bool {
    return std.mem.eql(u8, entry.issuer, key.issuer) and std.mem.eql(u8, entry.resource, key.resource) and std.mem.eql(u8, entry.client, key.client);
}

/// A token storage around another one for the records of one upstream server. On each save of
/// a record, it adds `server URL -> key` to the index. On each delete, it removes the entry.
/// `logout` reads the index. A failed change of the index writes a warning, and the record
/// stays saved.
pub const IndexedStorage = struct {
    io: Io,
    gpa: Allocator,
    inner: auth.TokenStorage,
    identity: Identity,
    /// The URL of the upstream server of the records.
    server_url: []const u8,
    lock: Io.Mutex = .init,
    /// The digest of the key that this process added to the index last. Thus a refresh does
    /// not write the index again.
    indexed: ?[32]u8 = null,

    pub fn storage(self: *IndexedStorage) auth.TokenStorage {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .delete = delete } };
    }

    fn load(ptr: *anyopaque, gpa: Allocator, key: auth.token_storage.Key) auth.TokenStorage.Error!?[]u8 {
        const self: *IndexedStorage = @ptrCast(@alignCast(ptr));
        return self.inner.vtable.load(self.inner.ptr, gpa, key);
    }

    fn save(ptr: *anyopaque, key: auth.token_storage.Key, data: []const u8) auth.TokenStorage.Error!void {
        const self: *IndexedStorage = @ptrCast(@alignCast(ptr));
        try self.inner.vtable.save(self.inner.ptr, key, data);
        self.addEntry(key) catch |e| self.indexFailed(e, "cannot add the sign-in to the index of the stored sign-ins: {t}");
    }

    fn delete(ptr: *anyopaque, key: auth.token_storage.Key) auth.TokenStorage.Error!void {
        const self: *IndexedStorage = @ptrCast(@alignCast(ptr));
        try self.inner.vtable.delete(self.inner.ptr, key);
        self.removeEntry(key) catch |e| self.indexFailed(e, "cannot remove the sign-in from the index of the stored sign-ins: {t}");
    }

    /// A failed change of the index does not fail the record. A cancel stays for the next
    /// cancel point of the task.
    fn indexFailed(self: *IndexedStorage, err: auth.TokenStorage.Error, comptime format: []const u8) void {
        if (err == error.Canceled) return self.io.recancel();
        log.warn(format, .{err});
    }

    fn addEntry(self: *IndexedStorage, key: auth.token_storage.Key) auth.TokenStorage.Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const digest = key.digest();
        if (self.indexed) |d| if (std.mem.eql(u8, &d, &digest)) return;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const entries = try loadIndex(arena, self.inner, self.identity);
        var list: std.ArrayList(IndexEntry) = .empty;
        for (entries) |e| {
            if (std.mem.eql(u8, e.url, self.server_url) and sameKey(e, key)) continue;
            try list.append(arena, e);
        }
        try list.append(arena, .{ .url = self.server_url, .issuer = key.issuer, .resource = key.resource, .client = key.client });
        const start = list.items.len -| max_index_entries;
        try saveIndex(self.gpa, self.inner, self.identity, list.items[start..]);
        self.indexed = digest;
    }

    fn removeEntry(self: *IndexedStorage, key: auth.token_storage.Key) auth.TokenStorage.Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.indexed = null;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const entries = try loadIndex(arena, self.inner, self.identity);
        var list: std.ArrayList(IndexEntry) = .empty;
        for (entries) |e| if (!sameKey(e, key)) try list.append(arena, e);
        if (list.items.len != entries.len) try saveIndex(self.gpa, self.inner, self.identity, list.items);
    }
};

pub const LogoutOptions = struct {
    identity: Identity,
    /// The URL of the upstream server, as the configuration of the server gives it.
    url: []const u8,
    /// The base storage identity (`Identity.storageIdentity`) for the account and the redirect
    /// URI. `logout` deletes the records of each registration of the account.
    storage_identity: []const u8,
    /// The trust of the discovery request, as for the sign-in.
    ca_bundle: ?*const std.crypto.Certificate.Bundle = null,
    /// The proxy of the discovery request, as for the sign-in.
    proxy: mcp.transport.proxy.Config = .{ .environment = null },
    /// Accept an `http` URL for the discovery. Only tests set it.
    allow_http: bool = false,
};

pub const LogoutReport = struct {
    /// The number of records that `logout` deleted.
    deleted: usize = 0,
    discovery: Discovery = .not_needed,

    pub const Discovery = enum {
        /// The index had an entry for the server and the account.
        not_needed,
        /// The index had no entry. The protected resource metadata of the server gave the key.
        found,
        /// The index had no entry, and the server did not give usable protected resource
        /// metadata. The log has the cause.
        failed,
    };
};

/// Deletes the stored sign-in of one account at the upstream server `options.url`. The index
/// gives the keys of the records of each registration of the account (`Identity.sameAccount`).
/// The function never lists the keychain, because zig-sdk cannot list it.
///
/// Without an entry, the function gets the protected resource metadata of the server. The key
/// then has its resource, its first authorization server and the base storage identity, as in
/// `OAuthClient`. As in `OAuthClient`, the resource of the metadata must cover the URL. Thus a
/// server cannot name the record of a different server.
pub fn logout(io: Io, gpa: Allocator, storage: auth.TokenStorage, options: LogoutOptions) auth.TokenStorage.Error!LogoutReport {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: LogoutReport = .{};
    const entries = try loadIndex(arena, storage, options.identity);
    var kept: std.ArrayList(IndexEntry) = .empty;
    for (entries) |e| {
        if (std.mem.eql(u8, e.url, options.url) and Identity.sameAccount(e.client, options.storage_identity)) {
            if (try deleteRecord(gpa, storage, e.key())) report.deleted += 1;
        } else try kept.append(arena, e);
    }
    if (kept.items.len != entries.len) {
        try saveIndex(gpa, storage, options.identity, kept.items);
        return report;
    }

    var fetcher: auth.common.Fetcher = .init(io, gpa, 1 << 20, options.allow_http);
    defer fetcher.deinit();
    fetcher.ca_bundle = options.ca_bundle;
    fetcher.proxy = options.proxy;
    const prm = fetcher.resourceMetadata(arena, options.url, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("the index has no sign-in for the URL, and the server gave no protected resource metadata: {t}", .{e});
            report.discovery = .failed;
            return report;
        },
    };
    if (prm.authorization_servers.len == 0) {
        log.warn("the index has no sign-in for the URL, and the protected resource metadata of the server names no authorization server", .{});
        report.discovery = .failed;
        return report;
    }
    if (!auth.common.resourceCoversServer(prm.resource, options.url)) {
        log.warn("the index has no sign-in for the URL, and the protected resource metadata of the server names a different resource", .{});
        report.discovery = .failed;
        return report;
    }
    report.discovery = .found;
    const key: auth.token_storage.Key = .{ .issuer = prm.authorization_servers[0], .resource = prm.resource, .client = options.storage_identity };
    if (try deleteRecord(gpa, storage, key)) report.deleted += 1;
    return report;
}

/// Deletes each record of the index and the index of `identity`. Returns the number of
/// deleted records.
pub fn logoutAll(gpa: Allocator, storage: auth.TokenStorage, identity: Identity) auth.TokenStorage.Error!usize {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const entries = try loadIndex(arena_state.allocator(), storage, identity);
    var deleted: usize = 0;
    for (entries) |e| {
        if (try deleteRecord(gpa, storage, e.key())) deleted += 1;
    }
    try storage.vtable.delete(storage.ptr, indexKey(identity));
    return deleted;
}

/// Deletes the token directory of the file store with its files (`logout --all`). This needs no
/// token key. Returns false when the directory does not exist.
pub fn deleteTokenDir(io: Io, dir: []const u8) Io.Dir.DeleteTreeError!bool {
    Io.Dir.cwd().access(io, dir, .{}) catch return false;
    try Io.Dir.cwd().deleteTree(io, dir);
    return true;
}

/// Deletes the record of `key`. Returns true when the storage had a record.
fn deleteRecord(gpa: Allocator, storage: auth.TokenStorage, key: auth.token_storage.Key) auth.TokenStorage.Error!bool {
    const existed = if (storage.vtable.load(storage.ptr, gpa, key)) |data| existed: {
        const d = data orelse break :existed false;
        std.crypto.secureZero(u8, d);
        gpa.free(d);
        break :existed true;
    } else |e| switch (e) {
        // A record that does not decrypt is also a record.
        error.InvalidRecord => true,
        else => return e,
    };
    try storage.vtable.delete(storage.ptr, key);
    return existed;
}

// ---------------------------------------------------------------------------------------------
// The token store
// ---------------------------------------------------------------------------------------------

/// The environment variable with the key of the file store: 64 hexadecimal digits.
pub const token_key_variable = "MCP_BRIDGE_TOKEN_KEY";

/// The token storage of a bridge, with this policy:
///
/// - `auto` tries the keychain of the host first, on every system. Without a display on
///   Linux and the other POSIX systems except macOS, the keychain shows no unlock prompt.
/// - When the keychain gives `KeychainUnavailable` or `KeychainLocked`, at the start or
///   later, the store uses the fallback for the rest of the process. It writes one warning.
/// - The fallback is the file store when a key comes from outside the token directory: the
///   environment variable `MCP_BRIDGE_TOKEN_KEY` or a private key file. Else it is memory,
///   and the user signs in at each start.
/// - An explicit choice (`keychain`, `file` or `memory`) that does not work is an error.
///
/// `open` writes one stderr line that names the active storage.
pub const TokenStore = struct {
    io: Io,
    gpa: Allocator,
    choice: Choice,
    /// The keychain service.
    service: []const u8,
    active: std.atomic.Value(Kind) = .init(.memory),
    host_keychain: ?auth.KeychainTokenStorage = null,
    replacement_keychain: ?auth.TokenStorage = null,
    file: ?auth.FileTokenStorage = null,
    memory: auth.MemoryTokenStorage,
    /// The key of the file store, or null.
    key: ?[32]u8 = null,
    /// The token directory, owned, or null when the environment names none.
    dir: ?[]u8 = null,
    /// Guards the change from the keychain to the fallback.
    switch_lock: Io.Mutex = .init,
    memory_reason: MemoryReason = .chosen,
    keychain_error: ?auth.TokenStorage.Error = null,
    file_error: ?anyerror = null,

    pub const Kind = enum(u8) { keychain, file, memory };

    pub const Choice = enum { auto, keychain, file, memory };

    const MemoryReason = enum { chosen, no_key, file_failed };

    /// The keychain of the store.
    pub const Keychain = union(enum) {
        /// The keychain of the host.
        host,
        /// A storage in place of the keychain of the host. Tests use it.
        replacement: auth.TokenStorage,
        /// The start of the keychain gives this error. Tests use it.
        init_error: auth.TokenStorage.Error,
    };

    pub const Options = struct {
        choice: Choice = .auto,
        identity: Identity,
        /// The environment of the process: the token key, the token directory, the display
        /// and the D-Bus address of the Secret Service.
        environ_map: *const std.process.Environ.Map,
        /// The path of a file with the token key, from `--token-key-file`. Only the user of
        /// the process can read it.
        token_key_file: ?[]const u8 = null,
        /// The token directory. Null uses `zig-bridge-sdk/<product>/tokens` in the state
        /// directory of the user.
        token_dir: ?[]const u8 = null,
        keychain: Keychain = .host,
        /// The keychain service. Null uses `Identity.keychain_service`. Tests use a random
        /// name.
        keychain_service: ?[]const u8 = null,
        /// The unlock prompt of the Secret Service. Null shows it only when the process has a
        /// display.
        allow_prompt: ?bool = null,
    };

    pub const OpenError = error{
        /// The token key does not have 64 hexadecimal digits.
        InvalidTokenKey,
        /// Other accounts can read or change the token key file.
        TokenKeyFileNotPrivate,
        /// The bridge cannot read the token key file.
        TokenKeyFileUnreadable,
        /// The token key file is in the token directory.
        TokenKeyInTokenDirectory,
        /// The file store needs a token key.
        TokenKeyMissing,
        /// The environment names no state directory for the token files.
        NoTokenDirectory,
        /// The file store did not start. The log has the cause.
        FileStoreFailed,
        /// The keychain of the host does not answer.
        KeychainUnavailable,
        /// The user did not unlock the keychain, and the store shows no unlock prompt.
        KeychainLocked,
        /// The keychain refused the start. The log has the cause.
        KeychainFailed,
        OutOfMemory,
    };

    /// Selects the storage with the policy of `TokenStore` and writes the stderr line. The
    /// store must not move until `deinit`.
    pub fn open(self: *TokenStore, io: Io, gpa: Allocator, options: Options) OpenError!void {
        self.* = .{
            .io = io,
            .gpa = gpa,
            .choice = options.choice,
            .service = options.keychain_service orelse options.identity.keychain_service,
            .memory = .init(io, gpa),
        };
        errdefer self.deinit();
        if (options.token_dir) |d| {
            self.dir = try gpa.dupe(u8, d);
        } else {
            self.dir = defaultTokenDir(gpa, options.environ_map, options.identity.product) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoTokenDirectory => null,
            };
        }
        // Only `auto` and `file` can use the file store, thus only they read the key.
        if (options.choice == .auto or options.choice == .file) self.key = try readTokenKey(io, gpa, options, self.dir);

        switch (options.choice) {
            .memory => self.memory_reason = .chosen,
            .keychain => {
                self.openKeychain(options) catch |e| return switch (e) {
                    error.KeychainUnavailable => error.KeychainUnavailable,
                    error.KeychainLocked => error.KeychainLocked,
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.KeychainFailed,
                };
                self.active.store(.keychain, .release);
            },
            .file => {
                if (self.key == null) return error.TokenKeyMissing;
                if (self.dir == null) return error.NoTokenDirectory;
                self.openFileStore() catch |e| {
                    log.warn("the file store did not start: {t}", .{e});
                    return error.FileStoreFailed;
                };
                self.active.store(.file, .release);
            },
            .auto => {
                if (self.openKeychain(options)) |_| {
                    self.active.store(.keychain, .release);
                } else |e| {
                    self.keychain_error = e;
                    self.useFallback();
                }
            },
        }
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        self.describe(&w) catch {};
        log.info("{s}", .{w.buffered()});
    }

    pub fn deinit(self: *TokenStore) void {
        if (self.host_keychain) |*k| k.deinit();
        if (self.file) |*f| f.deinit();
        self.memory.deinit();
        if (self.key) |*k| std.crypto.secureZero(u8, k);
        if (self.dir) |d| self.gpa.free(d);
        self.* = undefined;
    }

    /// The storage for `OAuthClient.Options.storage`.
    pub fn storage(self: *TokenStore) auth.TokenStorage {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .delete = delete } };
    }

    /// The active storage.
    pub fn activeKind(self: *TokenStore) Kind {
        return self.active.load(.acquire);
    }

    /// Writes the text of the stderr line that names the active storage, without a newline.
    pub fn describe(self: *TokenStore, w: *Io.Writer) Io.Writer.Error!void {
        switch (self.active.load(.acquire)) {
            .keychain => try w.print("the tokens are in the keychain of the host (service \"{s}\")", .{self.service}),
            .file => try w.print("the tokens are in encrypted files in {s}", .{self.dir.?}),
            .memory => switch (self.memory_reason) {
                .chosen => try w.writeAll("the tokens stay in memory (--token-store memory): each start needs a new sign-in"),
                .no_key => try w.print(
                    "the tokens stay in memory: the keychain is not available ({t}), and no token key is set ({s} or --token-key-file). Each start needs a new sign-in",
                    .{ self.keychain_error orelse error.KeychainUnavailable, token_key_variable },
                ),
                .file_failed => try w.print(
                    "the tokens stay in memory: the keychain is not available ({t}), and the file store did not start ({t}). Each start needs a new sign-in",
                    .{ self.keychain_error orelse error.KeychainUnavailable, self.file_error orelse error.FileStoreFailed },
                ),
            },
        }
    }

    fn openKeychain(self: *TokenStore, options: Options) auth.TokenStorage.Error!void {
        switch (options.keychain) {
            .host => self.host_keychain = try auth.KeychainTokenStorage.init(self.io, self.gpa, .{
                .service = self.service,
                .environ_map = options.environ_map,
                .allow_prompt = options.allow_prompt orelse defaultAllowPrompt(options.environ_map),
            }),
            .replacement => |s| self.replacement_keychain = s,
            .init_error => |e| return e,
        }
    }

    /// Starts the file store in the token directory. The parents of the directory get the
    /// default mode, and the directory itself is private.
    fn openFileStore(self: *TokenStore) !void {
        const dir = self.dir orelse return error.NoTokenDirectory;
        if (std.fs.path.dirname(dir)) |parent| try Io.Dir.cwd().createDirPath(self.io, parent);
        self.file = try auth.FileTokenStorage.init(self.io, self.gpa, .{ .dir = dir, .key = self.key.? });
    }

    /// Selects the fallback of the keychain: the file store with a key, else memory.
    fn useFallback(self: *TokenStore) void {
        if (self.key == null) {
            self.memory_reason = .no_key;
            self.active.store(.memory, .release);
            return;
        }
        self.openFileStore() catch |e| {
            log.warn("the file store did not start: {t}", .{e});
            self.file_error = e;
            self.memory_reason = .file_failed;
            self.active.store(.memory, .release);
            return;
        };
        self.active.store(.file, .release);
    }

    fn backend(self: *TokenStore, kind: Kind) auth.TokenStorage {
        return switch (kind) {
            .keychain => if (self.host_keychain) |*k| k.storage() else self.replacement_keychain.?,
            .file => self.file.?.storage(),
            .memory => self.memory.storage(),
        };
    }

    /// True when an error of `kind` makes the store use the fallback.
    fn switches(self: *TokenStore, kind: Kind, err: auth.TokenStorage.Error) bool {
        if (kind != .keychain or self.choice != .auto) return false;
        return err == error.KeychainUnavailable or err == error.KeychainLocked;
    }

    fn switchToFallback(self: *TokenStore, cause: auth.TokenStorage.Error) void {
        self.switch_lock.lockUncancelable(self.io);
        defer self.switch_lock.unlock(self.io);
        if (self.active.load(.acquire) != .keychain) return;
        self.keychain_error = cause;
        self.useFallback();
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        self.describe(&w) catch {};
        log.warn("the keychain stopped to answer ({t}). For the rest of the process, {s}", .{ cause, w.buffered() });
    }

    fn load(ptr: *anyopaque, gpa: Allocator, key: auth.token_storage.Key) auth.TokenStorage.Error!?[]u8 {
        const self: *TokenStore = @ptrCast(@alignCast(ptr));
        while (true) {
            const kind = self.active.load(.acquire);
            const s = self.backend(kind);
            return s.vtable.load(s.ptr, gpa, key) catch |e| {
                if (self.switches(kind, e)) {
                    self.switchToFallback(e);
                    continue;
                }
                return e;
            };
        }
    }

    fn save(ptr: *anyopaque, key: auth.token_storage.Key, data: []const u8) auth.TokenStorage.Error!void {
        const self: *TokenStore = @ptrCast(@alignCast(ptr));
        while (true) {
            const kind = self.active.load(.acquire);
            const s = self.backend(kind);
            return s.vtable.save(s.ptr, key, data) catch |e| {
                if (self.switches(kind, e)) {
                    self.switchToFallback(e);
                    continue;
                }
                return e;
            };
        }
    }

    fn delete(ptr: *anyopaque, key: auth.token_storage.Key) auth.TokenStorage.Error!void {
        const self: *TokenStore = @ptrCast(@alignCast(ptr));
        while (true) {
            const kind = self.active.load(.acquire);
            const s = self.backend(kind);
            return s.vtable.delete(s.ptr, key) catch |e| {
                if (self.switches(kind, e)) {
                    self.switchToFallback(e);
                    continue;
                }
                return e;
            };
        }
    }
};

/// The unlock prompt of the Secret Service needs a display. Windows and macOS have no Secret
/// Service, and the option has no effect there.
fn defaultAllowPrompt(environ_map: *const std.process.Environ.Map) bool {
    switch (builtin.os.tag) {
        .windows, .macos => return true,
        else => {},
    }
    const display = environ_map.get("DISPLAY") orelse "";
    const wayland = environ_map.get("WAYLAND_DISPLAY") orelse "";
    return display.len > 0 or wayland.len > 0;
}

/// The token directory `zig-bridge-sdk/<product>/tokens` in the state directory of the user:
/// `%LOCALAPPDATA%` on Windows, else `$XDG_STATE_HOME` or `~/.local/state`. The path is in
/// `gpa`.
pub fn defaultTokenDir(gpa: Allocator, environ_map: *const std.process.Environ.Map, product: []const u8) error{ NoTokenDirectory, OutOfMemory }![]u8 {
    if (builtin.os.tag == .windows) {
        const base = environ_map.get("LOCALAPPDATA") orelse return error.NoTokenDirectory;
        if (base.len == 0) return error.NoTokenDirectory;
        return std.fs.path.join(gpa, &.{ base, "zig-bridge-sdk", product, "tokens" });
    }
    if (environ_map.get("XDG_STATE_HOME")) |state| if (state.len > 0 and std.fs.path.isAbsolute(state)) {
        return std.fs.path.join(gpa, &.{ state, "zig-bridge-sdk", product, "tokens" });
    };
    const home = environ_map.get("HOME") orelse return error.NoTokenDirectory;
    if (home.len == 0) return error.NoTokenDirectory;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "zig-bridge-sdk", product, "tokens" });
}

/// Parses a token key of 64 hexadecimal digits. The function ignores spaces and line ends
/// around the digits.
fn parseTokenKey(text: []const u8) TokenStore.OpenError![32]u8 {
    const digits = std.mem.trim(u8, text, " \t\r\n");
    if (digits.len != 64) return error.InvalidTokenKey;
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, digits) catch return error.InvalidTokenKey;
    return key;
}

/// The token key of the options: the key file, else `MCP_BRIDGE_TOKEN_KEY`, else null. A key
/// that is set and not valid is an error in each mode.
fn readTokenKey(io: Io, gpa: Allocator, options: TokenStore.Options, dir: ?[]const u8) TokenStore.OpenError!?[32]u8 {
    if (options.token_key_file) |path| return try readKeyFile(io, gpa, path, dir);
    const text = options.environ_map.get(token_key_variable) orelse return null;
    if (text.len == 0) return null;
    return try parseTokenKey(text);
}

fn readKeyFile(io: Io, gpa: Allocator, path: []const u8, dir: ?[]const u8) TokenStore.OpenError![32]u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return error.TokenKeyFileUnreadable;
    defer file.close(io);
    if (!fileIsPrivate(file)) return error.TokenKeyFileNotPrivate;
    if (dir) |d| if (try isInside(io, gpa, path, d)) return error.TokenKeyInTokenDirectory;
    var buf: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    const n = file.readPositionalAll(io, &buf, 0) catch return error.TokenKeyFileUnreadable;
    if (n == buf.len) return error.InvalidTokenKey;
    return parseTokenKey(buf[0..n]);
}

/// True when the file at `path` is in the directory `dir` or below it. A directory that does
/// not exist has no files.
fn isInside(io: Io, gpa: Allocator, path: []const u8, dir: []const u8) error{OutOfMemory}!bool {
    const real_file = Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(real_file);
    const real_dir = Io.Dir.cwd().realPathFileAlloc(io, dir, gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(real_dir);
    if (real_file.len <= real_dir.len) return false;
    const prefix = real_file[0..real_dir.len];
    const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(prefix, real_dir) else std.mem.eql(u8, prefix, real_dir);
    return same and std.fs.path.isSep(real_file[real_dir.len]);
}

/// True when only the user of the process can read or change the open file. On Windows the
/// local system account and the Administrators group can also have rights.
fn fileIsPrivate(file: Io.File) bool {
    switch (builtin.os.tag) {
        .windows => return win.fileIsPrivate(file.handle),
        .wasi => return false,
        .linux => {
            const linux = std.os.linux;
            var sx = std.mem.zeroes(linux.Statx);
            if (linux.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .MODE = true, .UID = true }, &sx)) != .SUCCESS) return false;
            return sx.uid == linux.geteuid() and sx.mode & 0o077 == 0;
        },
        else => {
            var st: std.c.Stat = undefined;
            if (std.c.errno(std.c.fstat(file.handle, &st)) != .SUCCESS) return false;
            return st.uid == std.c.geteuid() and st.mode & 0o077 == 0;
        },
    }
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

test "the OAuth identity of mcp-bridge-vscode stays the same" {
    const identity: Identity = .of("mcp-bridge-vscode", "vscode", null);
    try testing.expectEqualStrings("mcp-bridge-vscode (zig-bridge-sdk)", identity.client_name);
    try testing.expectEqualStrings("zig-bridge-sdk/mcp-bridge-vscode", identity.keychain_service);
    try testing.expectEqualStrings("vscode", identity.product);

    var buf: [max_redirect_uri_len]u8 = undefined;
    const uri = writeRedirectUri(&buf, default_redirect_port);
    try testing.expectEqualStrings("http://127.0.0.1:41894/callback", uri);
    const id = try identity.storageIdentity(testing.allocator, default_account, uri);
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("mcp-bridge-vscode|default|http://127.0.0.1:41894/callback", id);

    // The port is not the port of zig-sdk and not the port of VS Code.
    try testing.expect(default_redirect_port != 41893 and default_redirect_port != 33418);
    try testing.expectEqualStrings("http://127.0.0.1:65535/callback", writeRedirectUri(&buf, 65535));

    // The options of the OAuth client have the identity, the redirect URI and one step-up.
    var sign_in: SignIn = .init(testing.io, testing.allocator, .{ .name = "mcp-bridge-vscode" });
    const options = clientOptions(.{ .identity = identity, .sign_in = &sign_in, .storage_identity = id });
    try testing.expectEqualStrings("mcp-bridge-vscode (zig-bridge-sdk)", options.client_name);
    try testing.expectEqualStrings("http://127.0.0.1:41894/callback", options.redirect_uri);
    try testing.expectEqualStrings(id, options.storage_identity.?);
    try testing.expectEqual(@as(u8, 1), options.max_step_up_attempts);
    try testing.expect(!options.allow_http);
    try testing.expect(options.authorize == .callback);
}

test "the storage identity of each registration source" {
    const gpa = testing.allocator;
    const document = "https://bridge.example/client.json";
    const identity: Identity = .of("mcp-bridge-test", "test", document);
    const uri = "http://127.0.0.1:41894/callback";
    const base = "mcp-bridge-test|work|" ++ uri;
    const cases = [_]struct { registration: Registration, want: []const u8 }{
        // Dynamic client registration and the document of the bridge have the base identity.
        .{ .registration = .dynamic, .want = base },
        .{ .registration = .{ .client_metadata_url = document }, .want = base },
        // An explicit document and a pre-registered client have their own identity.
        .{ .registration = .{ .client_metadata_url = "https://corp.example/c.json" }, .want = base ++ "|cimd=https://corp.example/c.json" },
        .{ .registration = .{ .pre_registered = .{ .client_id = "c1", .issuer = "https://as.example" } }, .want = base ++ "|client=c1" },
    };
    for (cases) |case| {
        const id = try identity.clientIdentity(gpa, "work", uri, case.registration);
        defer gpa.free(id);
        try testing.expectEqualStrings(case.want, id);
        try testing.expect(Identity.sameAccount(id, base));
    }
    // A bridge without a document of its own gives each document its own identity.
    const plain: Identity = .of("mcp-bridge-test", "test", null);
    const id = try plain.clientIdentity(gpa, "work", uri, .{ .client_metadata_url = document });
    defer gpa.free(id);
    try testing.expectEqualStrings(base ++ "|cimd=" ++ document, id);
    // Another account and another redirect port are not the same account.
    try testing.expect(!Identity.sameAccount("mcp-bridge-test|work2|" ++ uri, "mcp-bridge-test|work|" ++ uri));
    try testing.expect(!Identity.sameAccount("mcp-bridge-test|work|http://127.0.0.1:418940/callback", "mcp-bridge-test|work|http://127.0.0.1:41894/callback"));
    try testing.expect(!Identity.sameAccount("mcp-bridge-test|work|" ++ uri ++ "x", base));
}

test "account labels" {
    try testing.expect(validAccount("default"));
    try testing.expect(validAccount("work.user+1@example.com"));
    try testing.expect(!validAccount(""));
    try testing.expect(!validAccount("a|b"));
    try testing.expect(!validAccount("a b"));
    try testing.expect(!validAccount("x" ** (max_account_len + 1)));
}

test "the URL check refuses the characters, schemes and parts of P1" {
    const refused = [_][]const u8{
        "https://a.example/x\"&calc&\"",
        "https://a.example/x^y",
        "https://a.example/x|y",
        "https://a.example/?u=%USERNAME%",
        "https://a.example/?u=%4",
        "https://a.example/?u=%",
        "https://a.example/x\r\ny",
        "https://a.example/x\ny",
        "https://a.example/x y",
        "https://a.example/x\ty",
        "https://a.example/\x00",
        "https://a.example/\u{e9}",
        "https://a.example/x<y>",
        "https://a.example/x\\y",
        "https://a.example/x`y",
        "https://a.example/x{y}",
        "file:///C:/Windows/System32/calc.exe",
        "ms-settings:privacy",
        "javascript:alert(1)",
        "http://a.example/authorize",
        "https://user:pass@a.example/authorize",
        "https://user@a.example/authorize",
        "https:///authorize",
        "https://:443/authorize",
        "https://a.example:/authorize",
        "https://a.example:99999/authorize",
        "https://a.example:44x/authorize",
        "https://a.example/authorize#fragment",
        "",
        "https://a.example/?" ++ "a" ** max_url_bytes,
    };
    for (refused) |url| {
        if (validateAuthorizationUrl(url, .{})) |_| {
            std.debug.print("accepted: {f}\n", .{std.json.fmt(url, .{})});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try testing.expectError(error.UrlCharacter, validateAuthorizationUrl("https://a.example/x\"&calc&\"", .{}));
    try testing.expectError(error.UrlCharacter, validateAuthorizationUrl("https://a.example/?u=%USERNAME%", .{}));
    try testing.expectError(error.UrlScheme, validateAuthorizationUrl("javascript:alert(1)", .{}));
    try testing.expectError(error.UrlAuthority, validateAuthorizationUrl("https://user@a.example/", .{}));
    try testing.expectError(error.UrlLength, validateAuthorizationUrl("https://a.example/?" ++ "a" ** max_url_bytes, .{}));
    try testing.expectError(error.UrlFragment, validateAuthorizationUrl("https://a.example/#x", .{}));
}

test "the URL check accepts an authorization URL of OAuthClient with many fields" {
    const url = "https://auth.example.com/oauth2/authorize?response_type=code&client_id=mcp-bridge-vscode%20%28zig-bridge-sdk%29" ++
        "&redirect_uri=http%3A%2F%2F127.0.0.1%3A41894%2Fcallback&state=Zm9vYmFyYmF6cXV4LV9fLS0tX19fLS0tX19fLS0tX18" ++
        "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256" ++
        "&resource=https%3A%2F%2Fmcp.example.com%2Fmcp&scope=mcp%3Aread%20mcp%3Awrite%20offline_access";
    try validateAuthorizationUrl(url, .{});
    try validateAuthorizationUrl("HTTPS://AUTH.EXAMPLE.COM:8443/authorize?x=1", .{});
    try validateAuthorizationUrl("https://[2001:db8::1]:443/authorize?x=1", .{});
    try validateAuthorizationUrl("https://a.example?x=1", .{});
    try validateAuthorizationUrl("https://a.example/?" ++ "a" ** (max_url_bytes - "https://a.example/?".len), .{});
}

test "http needs allow_http and a loopback host" {
    try testing.expectError(error.UrlScheme, validateAuthorizationUrl("http://127.0.0.1:8080/authorize", .{}));
    try validateAuthorizationUrl("http://127.0.0.1:8080/authorize", .{ .allow_http = true });
    try validateAuthorizationUrl("http://127.1.2.3/authorize", .{ .allow_http = true });
    try validateAuthorizationUrl("http://localhost:8080/authorize", .{ .allow_http = true });
    try validateAuthorizationUrl("http://[::1]:8080/authorize", .{ .allow_http = true });
    try testing.expectError(error.UrlScheme, validateAuthorizationUrl("http://a.example/authorize", .{ .allow_http = true }));
    try testing.expectError(error.UrlScheme, validateAuthorizationUrl("http://128.0.0.1/authorize", .{ .allow_http = true }));
}

test "the POSIX opener gives the URL as the only argument and starts no shell" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const url = "https://a.example/authorize?a=1&b=2&c=%20";
    const default_argv = browserArgv(&env, url);
    try testing.expectEqual(@as(usize, 2), default_argv.len);
    try testing.expectEqualStrings(if (builtin.os.tag == .macos) "open" else "xdg-open", default_argv[0]);
    try testing.expectEqualStrings(url, default_argv[1]);
    try testing.expectEqualStrings(default_argv[0], browserArgv(null, url)[0]);

    try env.put("BROWSER", "");
    try testing.expectEqualStrings(default_argv[0], browserArgv(&env, url)[0]);
    try env.put("BROWSER", "/usr/bin/helper with space");
    const argv = browserArgv(&env, url);
    try testing.expectEqualStrings("/usr/bin/helper with space", argv[0]);
    try testing.expectEqualStrings(url, argv[1]);
}

test "the POSIX opener reports the exit status, and the program gets no secret of the environment" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    switch (builtin.os.tag) {
        .windows, .wasi => return error.SkipZigTest,
        else => {},
    }
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const settings: SystemOpener = .{ .environ_map = &env, .more_secret_variables = &.{"API_AUTH"} };
    const opener = settings.opener();
    const url = "https://a.example/authorize?x=1";
    try env.put("BROWSER", "true");
    try opener.open(opener.context, testing.io, url);
    try env.put("BROWSER", "false");
    try testing.expectError(error.BrowserLaunchFailed, opener.open(opener.context, testing.io, url));
    try env.put("BROWSER", "/nonexistent/mcp-bridge-test-browser");
    try testing.expectError(error.BrowserLaunchFailed, opener.open(opener.context, testing.io, url));

    // The program gets the URL as its only argument, no secret of the environment, and stdin
    // and stdout on the null device. Thus a text browser cannot read or write the MCP pipe.
    // The test `-ef` compares the files themselves. A command substitution such as
    // `$(readlink /proc/self/fd/1)` would examine its own pipe.
    var dir: TestDir = try .init();
    defer dir.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const script = try dir.join(arena_state.allocator(), "browser.sh");
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = script,
        .data = "#!/bin/sh\n[ \"$#\" = 1 ] && [ \"$1\" = '" ++ url ++ "' ] && [ -z \"$MCP_BRIDGE_TOKEN_KEY\" ] && " ++
            "[ -z \"$MCP_BRIDGE_CLIENT_SECRET\" ] && [ -z \"$API_AUTH\" ] && [ -n \"$KEEP_ME\" ] && " ++
            "[ /dev/stdin -ef /dev/null ] && [ /dev/stdout -ef /dev/null ]\n",
    });
    try Io.Dir.cwd().setFilePermissions(testing.io, script, .fromMode(0o700), .{});
    try env.put("BROWSER", script);
    try env.put("KEEP_ME", "1");
    try opener.open(opener.context, testing.io, url);
    try env.put(token_key_variable, test_key_hex);
    try env.put("MCP_BRIDGE_CLIENT_SECRET", "made-up-secret");
    try env.put("API_AUTH", "Bearer made-up");
    try opener.open(opener.context, testing.io, url);
    // The script really checks: without the removal of API_AUTH, it fails.
    const partial: SystemOpener = .{ .environ_map = &env };
    try testing.expectError(error.BrowserLaunchFailed, partial.opener().open(@constCast(&partial), testing.io, url));
}

test "on Windows, the variables with secrets leave the environment of the process before a sign-in" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const names = [_][]const u8{ "MCP_BRIDGE_TEST_SECRET_A", "MCP_BRIDGE_TEST_SECRET_B" };
    const keep = std.unicode.utf8ToUtf16LeStringLiteral("MCP_BRIDGE_TEST_KEEP");
    const value = std.unicode.utf8ToUtf16LeStringLiteral("made-up-value");
    var wide: [2][64:0]u16 = undefined;
    for (names, &wide) |name, *w| {
        const len = try std.unicode.wtf8ToWtf16Le(w, name);
        w[len] = 0;
        try testing.expect(win.SetEnvironmentVariableW(w[0..len :0], value) != 0);
    }
    try testing.expect(win.SetEnvironmentVariableW(keep, value) != 0);
    defer _ = win.SetEnvironmentVariableW(keep, null);
    removeFromProcessEnvironment(&names);
    var buf: [64]u16 = undefined;
    for (names, &wide) |name, *w| {
        const z: [*:0]const u16 = w[0..name.len :0];
        // Zero characters and ERROR_ENVVAR_NOT_FOUND: the variable is gone.
        try testing.expectEqual(@as(win.DWORD, 0), win.GetEnvironmentVariableW(z, &buf, buf.len));
        try testing.expectEqual(std.os.windows.Win32Error.ENVVAR_NOT_FOUND, std.os.windows.GetLastError());
    }
    // Another variable stays.
    try testing.expect(win.GetEnvironmentVariableW(keep, &buf, buf.len) != 0);
}

// -- Test helpers -----------------------------------------------------------------------------

/// A raw HTTP response head of a test request.
const TestResponse = struct {
    status: u16,
    location: ?[]const u8 = null,
    /// The whole head, in the arena of the request.
    head: []const u8 = "",
    /// The body of a response with `content-length`, in the arena of the request.
    body: []const u8 = "",

    /// The value of the header `name`, or null.
    fn header(self: TestResponse, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }
};

/// Sends `request` to `127.0.0.1:<port>` on a new connection and reads the response head.
/// The connection closes after the head.
fn testExchange(io: Io, arena: Allocator, port: u16, request: []const u8) !TestResponse {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var out_buf: [1024]u8 = undefined;
    var socket_writer = stream.writer(io, &out_buf);
    try socket_writer.interface.writeAll(request);
    try socket_writer.interface.flush();
    return testReadHead(io, arena, stream);
}

fn testReadHead(io: Io, arena: Allocator, stream: Io.net.Stream) !TestResponse {
    const in_buf = try arena.alloc(u8, 16 * 1024);
    var socket_reader = stream.reader(io, in_buf);
    var http_reader: std.http.Reader = .{ .in = &socket_reader.interface, .interface = undefined, .state = .ready, .max_head_len = in_buf.len };
    const head = try arena.dupe(u8, try http_reader.receiveHead());
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.")) return error.InvalidResponse;
    const status = try std.fmt.parseInt(u16, head[9..12], 10);
    var response: TestResponse = .{ .status = status, .head = head };
    response.location = response.header("location");
    // A test that needs the body checks it. A reset after the head only loses the body.
    if (response.header("content-length")) |text| {
        const body = try arena.alloc(u8, try std.fmt.parseInt(usize, text, 10));
        if (socket_reader.interface.readSliceAll(body)) |_| {
            response.body = body;
        } else |_| {}
    }
    return response;
}

/// The port and the target of an `http://127.0.0.1:<port>/...` URL.
fn testSplitUrl(url: []const u8) !struct { port: u16, target: []const u8 } {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidUrl;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUrl;
    return .{ .port = try std.fmt.parseInt(u16, rest[0..slash], 10), .target = rest[slash..] };
}

/// GETs an `http://127.0.0.1` URL and follows redirects, as a browser does. Returns the status
/// of the last response.
fn testFollow(io: Io, arena: Allocator, url: []const u8) !u16 {
    var current = url;
    for (0..5) |_| {
        const parts = try testSplitUrl(current);
        const request = try std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\nconnection: close\r\n\r\n", .{ parts.target, parts.port });
        const response = try testExchange(io, arena, parts.port, request);
        if (response.status < 300 or response.status >= 400) return response.status;
        current = response.location orelse return error.InvalidResponse;
    }
    return error.TooManyRedirects;
}

fn testGet(io: Io, arena: Allocator, port: u16, target: []const u8) !u16 {
    const request = try std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n", .{target});
    return (try testExchange(io, arena, port, request)).status;
}

/// A free port on `127.0.0.1`. Another program can take it before the test uses it, but that
/// is improbable.
fn testFreePort(io: Io) !u16 {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

/// A deadline `ms` milliseconds from now.
fn testDeadline(io: Io, ms: i64) Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromMilliseconds(ms), .clock = .awake });
}

const test_limits: Receiver.Limits = .{
    .head_timeout = .fromMilliseconds(300),
    .close_grace = .fromMilliseconds(300),
};

// -- Receiver tests -----------------------------------------------------------------------------

test "the receiver answers a wrong state with 400 and then takes the correct state" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "s-123", .limits = test_limits });
    defer r.stop();

    try testing.expectEqual(@as(u16, 400), try testGet(io, arena, r.port, "/callback?code=c1&state=wrong"));
    try testing.expectEqual(@as(u16, 400), try testGet(io, arena, r.port, "/callback?code=c1"));
    try testing.expectEqual(@as(u16, 400), try testGet(io, arena, r.port, "/callback?state=s-123"));
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 100)));

    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c2&state=s-123&iss=https%3A%2F%2Fas.example"));
    var callback = try r.wait(testDeadline(io, 5000));
    defer callback.deinit(testing.allocator);
    try testing.expectEqual(Receiver.Callback.Outcome.code, callback.outcome);
    const want = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/callback?code=c2&state=s-123&iss=https%3A%2F%2Fas.example", .{r.port});
    try testing.expectEqualStrings(want, callback.url);

    // A second match after the first gets 400, and a second wait ends at once.
    try testing.expectEqual(@as(u16, 400), try testGet(io, arena, r.port, "/callback?code=c3&state=s-123"));
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 60_000)));
}

test "the receiver answers favicon, POST, HEAD and other paths, and the wait goes on" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();

    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, "/favicon.ico"));
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, "/callback/?code=c&state=st"));
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, "/"));
    const post = "POST /callback?code=c&state=st HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 5\r\nconnection: close\r\n\r\nhello";
    try testing.expectEqual(@as(u16, 400), (try testExchange(io, arena, r.port, post)).status);
    const head_request = "HEAD /callback?code=c&state=st HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n";
    try testing.expectEqual(@as(u16, 400), (try testExchange(io, arena, r.port, head_request)).status);
    try testing.expectEqual(@as(u16, 400), (try testExchange(io, arena, r.port, "GET /callback?code=c&state=st HTTP/2.0\r\n\r\n")).status);
    try testing.expectEqual(@as(u16, 400), (try testExchange(io, arena, r.port, "garbage\r\n\r\n")).status);
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 100)));

    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    var callback = try r.wait(testDeadline(io, 5000));
    callback.deinit(testing.allocator);
}

test "an idle preconnect does not stop the redirect, and the head time limit closes it" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(r.port) };
    const idle = try address.connect(io, .{ .mode = .stream });
    defer idle.close(io);

    // The receiver closes the idle connection after the head time limit.
    const start = nowNs(io);
    var buf: [64]u8 = undefined;
    var idle_reader = idle.reader(io, &buf);
    if (idle_reader.interface.takeByte()) |_| return error.TestUnexpectedResult else |_| {}
    const elapsed_ms = @divFloor(nowNs(io) - start, std.time.ns_per_ms);
    try testing.expect(elapsed_ms < 5000);

    // A second idle connection stays open while the redirect arrives on a third one.
    const idle2 = try address.connect(io, .{ .mode = .stream });
    defer idle2.close(io);
    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    var callback = try r.wait(testDeadline(io, 5000));
    callback.deinit(testing.allocator);
}

test "an oversize head gets 431 and does not end the wait" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();

    const request = "GET /callback?code=c&state=st HTTP/1.1\r\nx-filler: " ++ "a" ** (17 * 1024) ++ "\r\n\r\n";
    if (testExchange(io, arena, r.port, request)) |response| {
        try testing.expectEqual(@as(u16, 431), response.status);
    } else |_| {
        // The reset of the receiver can arrive before the test reads the response.
    }
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 100)));
    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    var callback = try r.wait(testDeadline(io, 5000));
    callback.deinit(testing.allocator);
}

test "a slow head ends at the head time limit and does not end the wait" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(r.port) };
    const slow = try address.connect(io, .{ .mode = .stream });
    defer slow.close(io);
    var out_buf: [256]u8 = undefined;
    var slow_writer = slow.writer(io, &out_buf);
    try slow_writer.interface.writeAll("GET /callback?code=c&state=st HTTP/1.1\r\n");
    try slow_writer.interface.flush();
    // The receiver closes the connection at the head time limit. The test waits for that
    // event and not for a fixed time, because the connection task can start late.
    const start = nowNs(io);
    var in_buf: [64]u8 = undefined;
    var slow_reader = slow.reader(io, &in_buf);
    if (slow_reader.interface.takeByte()) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expect(nowNs(io) - start < 5 * std.time.ns_per_s);
    // The rest of the head after the time limit does not reach the receiver.
    slow_writer.interface.writeAll("host: 127.0.0.1\r\n\r\n") catch {};
    slow_writer.interface.flush() catch {};
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 200)));

    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    var callback = try r.wait(testDeadline(io, 5000));
    callback.deinit(testing.allocator);
}

test "error=access_denied ends the wait with denied, and another error with its code" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    {
        var r: Receiver = undefined;
        try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
        defer r.stop();
        try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?error=access_denied&error_description=No&state=st"));
        var callback = try r.wait(testDeadline(io, 5000));
        defer callback.deinit(testing.allocator);
        try testing.expectEqual(Receiver.Callback.Outcome.denied, callback.outcome);
        try testing.expectEqualStrings("access_denied", callback.error_code.slice().?);
    }
    {
        var r: Receiver = undefined;
        try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
        defer r.stop();
        try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?error=Bad%20Code%0A&state=st"));
        var callback = try r.wait(testDeadline(io, 5000));
        defer callback.deinit(testing.allocator);
        try testing.expectEqual(Receiver.Callback.Outcome.failed, callback.outcome);
        // A code with other characters stays out of the record.
        try testing.expect(callback.error_code.slice() == null);
    }
}

test "the deadline and abort end the wait" {
    const io = testing.io;
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();
    const start = nowNs(io);
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 200)));
    try testing.expect(nowNs(io) - start >= 150 * std.time.ns_per_ms);
    r.abort();
    try testing.expectError(error.Aborted, r.wait(testDeadline(io, 5000)));
}

test "a port in use gives AddressInUse, and the receiver never shares a port" {
    const io = testing.io;
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();
    var second: Receiver = undefined;
    try testing.expectError(error.AddressInUse, second.start(io, testing.allocator, .{ .port = r.port, .state = "st" }));
    // A socket with `SO_REUSEADDR` cannot share the port either. Windows refuses it because
    // of `SO_EXCLUSIVEADDRUSE`, and the POSIX systems because the receiver did not set
    // `SO_REUSEPORT`. Any error is correct.
    if (builtin.os.tag == .windows) {
        try testing.expect(!win.canBindShared(r.port));
    } else {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(r.port) };
        if (address.listen(io, .{ .reuse_address = true })) |listener| {
            var shared = listener;
            shared.deinit(io);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "the wait gives a redirect that came before it, then Timeout at once, and Aborted after abort" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();
    // The connection task publishes the redirect before the first wait. The wait decides
    // under the lock of the receiver, thus a redirect is never lost as a timeout.
    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    const until = nowNs(io) + 5 * std.time.ns_per_s;
    while (!r.done.isSet()) {
        if (nowNs(io) > until) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    var callback = try r.wait(testDeadline(io, 0));
    callback.deinit(testing.allocator);
    const start = nowNs(io);
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 60_000)));
    try testing.expect(nowNs(io) - start < std.time.ns_per_s);
    r.abort();
    try testing.expectError(error.Aborted, r.wait(testDeadline(io, 60_000)));
}

/// A start token for the receiver tests.
const test_token: StartToken = ("0123456789" ** 4 ++ "abc").*;
const test_location = "https://as.example/authorize?response_type=code&client_id=c1&state=st&code_challenge=abc&code_challenge_method=S256";

fn testStartRequest(arena: Allocator, method: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s} {s} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n", .{ method, path });
}

test "the first GET of the start path gets 303 to the authorization URL, and a second GET ends the wait" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .start = .{ .token = test_token, .location = test_location }, .limits = test_limits });
    defer r.stop();
    const path = start_path_prefix ++ test_token;

    // Only GET uses the start path. HEAD and POST get 400 and do not use it.
    try testing.expectEqual(@as(u16, 400), (try testExchange(io, arena, r.port, try testStartRequest(arena, "HEAD", path))).status);
    try testing.expectEqual(@as(u16, 400), (try testExchange(io, arena, r.port, try testStartRequest(arena, "POST", path))).status);

    // The first GET: 303 See Other to the authorization URL, no store, no referrer, no body.
    const first = try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path));
    try testExpectStartResponse(first);
    try testing.expectEqualStrings(test_location, first.location.?);
    try testing.expectEqual(@as(usize, 0), first.body.len);
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 100)));

    // The second GET: an error page that tells the user to start the sign-in again, and the
    // wait ends at once.
    const second = try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path ++ "?x=1"));
    try testing.expectEqual(@as(u16, 410), second.status);
    try testing.expect(second.location == null);
    try testing.expectEqualStrings("no-store", second.header("cache-control").?);
    try testing.expect(std.mem.startsWith(u8, second.header("content-type").?, "text/html"));
    try testing.expect(std.mem.indexOf(u8, second.body, "Start the sign-in again.") != null);
    try testing.expect(std.mem.indexOf(u8, second.body, "--no-browser") != null);
    try testing.expectError(error.StartReused, r.wait(testDeadline(io, 5000)));

    // After that, the redirect does not end the sign-in, and each GET of the start path gets
    // the error page.
    try testing.expectEqual(@as(u16, 400), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    try testing.expectEqual(@as(u16, 410), try testGet(io, arena, r.port, path));
    try testing.expectError(error.StartReused, r.wait(testDeadline(io, 5000)));
}

test "a different start token gets 404 and does not end the wait" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .start = .{ .token = test_token, .location = test_location }, .limits = test_limits });
    defer r.stop();

    // One different character at the start, in the middle and at the end, a different case, a
    // shorter and a longer token, and no token. The compare takes the same time for each token
    // of the correct length. A guess never ends the wait.
    var wrong: std.ArrayList([]const u8) = .empty;
    for ([_]usize{ 0, start_token_len / 2, start_token_len - 1 }) |i| {
        var token = test_token;
        token[i] = if (token[i] == 'z') 'y' else 'z';
        try wrong.append(arena, try arena.dupe(u8, &token));
    }
    try wrong.append(arena, "0123456789" ** 4 ++ "ABC");
    try wrong.append(arena, test_token[0 .. start_token_len - 1]);
    try wrong.append(arena, test_token ++ "d");
    try wrong.append(arena, "");
    for (wrong.items) |token| {
        const target = try std.mem.concat(arena, u8, &.{ start_path_prefix, token });
        try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, target));
    }
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, "/start"));
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, "/start/" ++ test_token ++ "/x"));
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 100)));

    // The start path still works one time, and the redirect ends the wait.
    const first = try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", start_path_prefix ++ test_token));
    try testExpectStartResponse(first);
    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    var callback = try r.wait(testDeadline(io, 5000));
    callback.deinit(testing.allocator);
}

test "the start path refuses a GET after a redirect without the start URL" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .start = .{ .token = test_token, .location = test_location }, .limits = test_limits });
    defer r.stop();
    // The user opened the URL of the sign-in line, and the redirect came first. A late GET of
    // the start path gets no second authorization request, and the redirect stays.
    try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, start_path_prefix ++ test_token));
    var callback = try r.wait(testDeadline(io, 5000));
    defer callback.deinit(testing.allocator);
    try testing.expectEqual(Receiver.Callback.Outcome.code, callback.outcome);
}

test "a second GET of the start path wakes a wait that waits, and its page arrives before the stop" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = start_path_prefix ++ test_token;
    // Waits for the redirect with a long deadline, and stops the receiver at once after the
    // wait, as `SignIn` does.
    const Waiter = struct {
        receiver: *Receiver,
        waits: Io.Event = .unset,

        fn run(self: *@This()) Receiver.WaitError!void {
            defer self.receiver.stop();
            self.waits.set(testing.io);
            var callback = try self.receiver.wait(testDeadline(testing.io, 30_000));
            callback.deinit(testing.allocator);
        }
    };
    for (0..5) |_| {
        var r: Receiver = undefined;
        try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .start = .{ .token = test_token, .location = test_location }, .limits = test_limits });
        var waiter: Waiter = .{ .receiver = &r };
        var task = try io.concurrent(Waiter.run, .{&waiter});
        var awaited = false;
        defer if (!awaited) task.cancel(io) catch {};
        // The waiter waits in `wait` before the two requests, as `SignIn` after the opener.
        if (!try waitUntil(io, &waiter.waits, testDeadline(io, 5000))) return error.TestUnexpectedResult;
        try io.sleep(.fromMilliseconds(100), .awake);
        try testExpectStartResponse(try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path)));

        // The second GET wakes the waiter. The waiter stops the receiver at once, but the
        // receiver sent the whole page first.
        const start = nowNs(io);
        const second = try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path));
        try testing.expectEqual(@as(u16, 410), second.status);
        try testing.expect(std.mem.indexOf(u8, second.body, "Start the sign-in again.") != null);
        awaited = true;
        try testing.expectError(error.StartReused, task.await(io));
        // The deadline of the wait is 30 s. Only the wake can end it in this time.
        try testing.expect(nowNs(io) - start < 5 * std.time.ns_per_s);
    }
}

test "a second GET of the start path after the caller took a redirect with a code writes a warning and stops nothing" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = start_path_prefix ++ test_token;
    {
        // Another program sent the first GET and the redirect, and the caller took the
        // redirect. The sign-in cannot stop now. Thus the late GET of the browser of the user
        // gets a page that tells the user about the different account.
        var r: Receiver = undefined;
        try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .start = .{ .token = test_token, .location = test_location }, .limits = test_limits });
        defer r.stop();
        try testExpectStartResponse(try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path)));
        try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
        var callback = try r.wait(testDeadline(io, 5000));
        defer callback.deinit(testing.allocator);
        try testing.expectEqual(Receiver.Callback.Outcome.code, callback.outcome);
        const late = try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path));
        try testing.expectEqual(@as(u16, 410), late.status);
        try testing.expectEqualStrings("no-store", late.header("cache-control").?);
        try testing.expect(std.mem.indexOf(u8, late.body, "different account") != null);
        try testing.expect(std.mem.indexOf(u8, late.body, "stopped") == null);
        // The caller keeps the redirect, and a new wait gives Timeout at once.
        const start = nowNs(io);
        try testing.expectError(error.Timeout, r.wait(testDeadline(io, 60_000)));
        try testing.expect(nowNs(io) - start < std.time.ns_per_s);
    }
    {
        // After a redirect with an error, the sign-in fails anyway. A late GET gets 404.
        var r: Receiver = undefined;
        try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .start = .{ .token = test_token, .location = test_location }, .limits = test_limits });
        defer r.stop();
        try testExpectStartResponse(try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path)));
        try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?error=access_denied&state=st"));
        var callback = try r.wait(testDeadline(io, 5000));
        defer callback.deinit(testing.allocator);
        try testing.expectEqual(Receiver.Callback.Outcome.denied, callback.outcome);
        try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, path));
    }
    {
        // Before the caller took the redirect, the same order stops the wait. The stop wins
        // over the redirect.
        var r: Receiver = undefined;
        try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .start = .{ .token = test_token, .location = test_location }, .limits = test_limits });
        defer r.stop();
        try testExpectStartResponse(try testExchange(io, arena, r.port, try testStartRequest(arena, "GET", path)));
        try testing.expectEqual(@as(u16, 200), try testGet(io, arena, r.port, "/callback?code=c&state=st"));
        try testing.expectEqual(@as(u16, 410), try testGet(io, arena, r.port, path));
        try testing.expectError(error.StartReused, r.wait(testDeadline(io, 5000)));
    }
}

test "a receiver without a start path answers each start path with 404" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Receiver = undefined;
    try r.start(io, testing.allocator, .{ .port = 0, .state = "st", .limits = test_limits });
    defer r.stop();
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, start_path_prefix ++ test_token));
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, r.port, start_path_prefix ++ test_token));
    try testing.expectError(error.Timeout, r.wait(testDeadline(io, 100)));
}

// -- SignIn tests -----------------------------------------------------------------------------

/// Keeps the lines of `SignIn` and sets `written` at each line.
const TestOutput = struct {
    lines: std.ArrayList(u8) = .empty,
    count: usize = 0,
    written: Io.Event = .unset,
    lock: Io.Mutex = .init,

    fn output(self: *TestOutput) Output {
        return .{ .context = self, .write_line = writeLine };
    }

    fn writeLine(context: ?*anyopaque, line: []const u8) void {
        const self: *TestOutput = @ptrCast(@alignCast(context.?));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.lines.appendSlice(testing.allocator, line) catch {};
        self.count += 1;
        self.written.set(testing.io);
    }

    fn deinit(self: *TestOutput) void {
        self.lines.deinit(testing.allocator);
    }
};

/// A browser for the tests. It records each call, and it never opens a real browser.
const TestBrowser = struct {
    mode: Mode,
    /// The redirect port of the sign-in, for `redirect_code` and `redirect_denied`.
    port: u16 = 0,
    calls: std.atomic.Value(u32) = .init(0),
    /// The URL that the opener got.
    url: std.ArrayList(u8) = .empty,
    /// The `Location` of the first `GET` of the start URL, or empty.
    location: std.ArrayList(u8) = .empty,
    opened: Io.Event = .unset,
    /// Set after the first `GET` of the start URL in the mode `start_once`.
    resolved: Io.Event = .unset,
    status: u16 = 0,

    const Mode = enum {
        /// GET the URL and follow the redirects into the receiver.
        follow,
        /// Send the redirect with a code and the state of the authorization URL to the
        /// receiver.
        redirect_code,
        /// Send the redirect with `error=access_denied` to the receiver.
        redirect_denied,
        /// GET the start URL two times, and keep the status of the second response.
        start_twice,
        /// GET the start URL one time, set `resolved` and send no redirect.
        start_once,
        /// Only record the call.
        record,
        /// Give `BrowserLaunchFailed`.
        fail,
        /// Give `Declined`.
        decline,
    };

    fn opener(self: *TestBrowser) Opener {
        return .{ .context = self, .open = open };
    }

    fn open(context: ?*anyopaque, io: Io, url: []const u8) OpenerError!void {
        const self: *TestBrowser = @ptrCast(@alignCast(context.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.url.clearRetainingCapacity();
        self.url.appendSlice(testing.allocator, url) catch {};
        self.opened.set(io);
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        switch (self.mode) {
            .follow => self.status = testFollow(io, arena, url) catch 0,
            .redirect_code, .redirect_denied => {
                const authorization_url = self.resolveStart(io, arena, url) catch return error.BrowserLaunchFailed;
                const params = auth.common.parseQuery(arena, authorization_url) catch return error.BrowserLaunchFailed;
                const state = params.get("state") orelse return error.BrowserLaunchFailed;
                const target = std.fmt.allocPrint(arena, "/callback?{s}&state={s}", .{
                    if (self.mode == .redirect_code) "code=test-code" else "error=access_denied",
                    state,
                }) catch return error.BrowserLaunchFailed;
                self.status = testGet(io, arena, self.port, target) catch 0;
            },
            .start_twice => {
                _ = self.resolveStart(io, arena, url) catch return error.BrowserLaunchFailed;
                const parts = testSplitUrl(url) catch return error.BrowserLaunchFailed;
                self.status = testGet(io, arena, parts.port, parts.target) catch 0;
            },
            .start_once => {
                _ = self.resolveStart(io, arena, url) catch return error.BrowserLaunchFailed;
                self.resolved.set(io);
            },
            .record => {},
            .fail => return error.BrowserLaunchFailed,
            .decline => return error.Declined,
        }
    }

    /// The authorization URL behind the start URL `url`: the `Location` of its first `GET`.
    /// The response must have the headers of the start path.
    fn resolveStart(self: *TestBrowser, io: Io, arena: Allocator, url: []const u8) ![]const u8 {
        const parts = try testSplitUrl(url);
        if (!std.mem.startsWith(u8, parts.target, start_path_prefix)) return error.NotStartUrl;
        const request = try std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\n\r\n", .{ parts.target, parts.port });
        const response = try testExchange(io, arena, parts.port, request);
        try testExpectStartResponse(response);
        const location = response.location.?;
        self.location.clearRetainingCapacity();
        try self.location.appendSlice(testing.allocator, location);
        return location;
    }

    fn deinit(self: *TestBrowser) void {
        self.url.deinit(testing.allocator);
        self.location.deinit(testing.allocator);
    }
};

/// Checks the response to the first `GET` of a start path. It must have the status 303 and a
/// `Location`. It also must have no store, no referrer, no body and the end of the connection.
fn testExpectStartResponse(response: TestResponse) !void {
    try testing.expectEqual(@as(u16, 303), response.status);
    try testing.expect(response.location != null);
    try testing.expectEqualStrings("no-store", response.header("cache-control").?);
    try testing.expectEqualStrings("no-referrer", response.header("referrer-policy").?);
    try testing.expectEqualStrings("0", response.header("content-length").?);
    try testing.expectEqualStrings("close", response.header("connection").?);
}

/// Checks that `url` is a start URL on `port`. Its token must have `start_token_len` base64url
/// characters, and the URL must have no query. Returns the token.
fn testExpectStartUrl(url: []const u8, port: u16) ![]const u8 {
    var buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}" ++ start_path_prefix, .{port});
    try testing.expect(std.mem.startsWith(u8, url, prefix));
    const token = url[prefix.len..];
    try testing.expectEqual(start_token_len, token.len);
    for (token) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    try testing.expect(std.mem.indexOfScalar(u8, url, '?') == null);
    return token;
}

fn testAuthorizationUrl(arena: Allocator, port: u16, state: []const u8) ![]const u8 {
    var buf: [max_redirect_uri_len]u8 = undefined;
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("https://as.example/authorize?response_type=code&client_id=c1");
    try auth.common.formField(w, "redirect_uri", writeRedirectUri(&buf, port), false);
    try auth.common.formField(w, "state", state, false);
    try w.writeAll("&code_challenge=abc&code_challenge_method=S256");
    return aw.written();
}

test "a sign-in writes one line, opens the start URL one time and returns the redirect" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .redirect_code, .port = port };
    defer browser.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{
        .name = "mcp-bridge-test",
        .redirect_port = port,
        .opener = browser.opener(),
        .output = out.output(),
        .limits = test_limits,
        .timeout = .fromSeconds(10),
    });
    const url = try testAuthorizationUrl(arena, port, "state-1");
    const redirect = try sign_in.run(arena, url);
    const want = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/callback?code=test-code&state=state-1", .{port});
    try testing.expectEqualStrings(want, redirect);
    // The line has the authorization URL, thus the user can open it without the browser.
    try testing.expectEqual(@as(usize, 1), out.count);
    const line = try std.fmt.allocPrint(arena, "mcp-bridge-test: sign in at {s}\n", .{url});
    try testing.expectEqualStrings(line, out.lines.items);
    // The browser got only the start URL: no state and no code challenge. Its first GET gave
    // the authorization URL.
    try testing.expectEqual(@as(u32, 1), browser.calls.load(.acquire));
    const first_token = try arena.dupe(u8, try testExpectStartUrl(browser.url.items, port));
    try testing.expect(std.mem.indexOf(u8, browser.url.items, "state") == null);
    try testing.expect(std.mem.indexOf(u8, browser.url.items, "code_challenge") == null);
    try testing.expectEqualStrings(url, browser.location.items);
    try testing.expectEqual(@as(u16, 200), browser.status);
    try testing.expect(sign_in.lastFailure() == null);

    // Each sign-in has a new token.
    _ = try sign_in.run(arena, try testAuthorizationUrl(arena, port, "state-2"));
    try testing.expectEqual(@as(u32, 2), browser.calls.load(.acquire));
    try testing.expect(!std.mem.eql(u8, first_token, try testExpectStartUrl(browser.url.items, port)));
}

test "a start token has 256 random bits in base64url, and each token is new" {
    const io = testing.io;
    try testing.expectEqual(@as(usize, 43), start_token_len);
    try testing.expect(start_token_bytes * 8 >= 128);
    var tokens: [8]StartToken = undefined;
    for (&tokens, 0..) |*t, i| {
        t.* = try newStartToken(io);
        for (t) |c| try testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
        var decoded: [start_token_bytes]u8 = undefined;
        try std.base64.url_safe_no_pad.Decoder.decode(&decoded, t);
        for (tokens[0..i]) |*other| try testing.expect(!std.mem.eql(u8, other, t));
    }
    var buf: [max_start_url_len]u8 = undefined;
    const url = writeStartUrl(&buf, default_redirect_port, &tokens[0]);
    try testing.expectEqualStrings(try testExpectStartUrl(url, default_redirect_port), &tokens[0]);
    try testing.expectEqual(max_start_url_len, writeStartUrl(&buf, 65535, &tokens[1]).len);
}

test "a second GET of the start URL stops the sign-in with the reason start_reused" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .start_twice };
    defer browser.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = browser.opener(), .output = out.output(), .limits = test_limits, .timeout = .fromSeconds(10) });
    const url = try testAuthorizationUrl(arena, port, "st");
    const start = nowNs(io);
    try testing.expectError(error.SignInFailed, sign_in.run(arena, url));
    // The wait ended at the second GET, and not at the time limit.
    try testing.expect(nowNs(io) - start < 5 * std.time.ns_per_s);
    const failure = sign_in.lastFailure().?;
    try testing.expectEqual(Reason.start_reused, failure.reason);
    try testing.expectEqualStrings(url, browser.location.items);
    try testing.expectEqual(@as(u16, 410), browser.status);
    const message = try std.fmt.allocPrint(arena, "{f}", .{&failure});
    try testing.expect(std.mem.indexOf(u8, message, "second request") != null);
    try testing.expect(std.mem.indexOf(u8, message, "Start the sign-in again.") != null);
    // The message names the host of the bridge and the option to use.
    try testing.expect(std.mem.indexOf(u8, message, "on the host of the bridge") != null);
    try testing.expect(std.mem.indexOf(u8, message, "--no-browser") != null);
}

test "a second GET of the start URL during the wait stops the sign-in at once" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    // The browser sends only the first GET. The opener returns, and the sign-in waits.
    var browser: TestBrowser = .{ .mode = .start_once };
    defer browser.deinit();
    const timeout: Io.Duration = .fromSeconds(30);
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = browser.opener(), .output = out.output(), .limits = test_limits, .timeout = timeout });
    // Another program sends the second GET while the sign-in waits.
    const Other = struct {
        status: u16 = 0,
        page: std.ArrayList(u8) = .empty,

        fn run(self: *@This(), b: *TestBrowser) void {
            const tio = testing.io;
            if (!(waitUntil(tio, &b.resolved, testDeadline(tio, 10_000)) catch false)) return;
            tio.sleep(.fromMilliseconds(200), .awake) catch return;
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            const parts = testSplitUrl(b.url.items) catch return;
            const request = testStartRequest(a.allocator(), "GET", parts.target) catch return;
            const response = testExchange(tio, a.allocator(), parts.port, request) catch return;
            self.status = response.status;
            self.page.appendSlice(testing.allocator, response.body) catch {};
        }
    };
    var other: Other = .{};
    defer other.page.deinit(testing.allocator);
    var task = try io.concurrent(Other.run, .{ &other, &browser });
    var awaited = false;
    defer if (!awaited) task.await(io);
    const start = nowNs(io);
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "st")));
    const elapsed = nowNs(io) - start;
    awaited = true;
    task.await(io);
    try testing.expectEqual(Reason.start_reused, sign_in.lastFailure().?.reason);
    // The time limit of the sign-in is 30 s. Only the second GET can end it this early.
    try testing.expect(elapsed < 5 * std.time.ns_per_s);
    // The other program got the whole page, although the sign-in stopped the receiver.
    try testing.expectEqual(@as(u16, 410), other.status);
    try testing.expect(std.mem.indexOf(u8, other.page.items, "Start the sign-in again.") != null);
}

test "the start URL stops working at the deadline, as the callback" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var silent: TestBrowser = .{ .mode = .record };
    defer silent.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = silent.opener(), .output = out.output(), .limits = test_limits, .timeout = .fromMilliseconds(300) });
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "st")));
    try testing.expectEqual(Reason.timeout, sign_in.lastFailure().?.reason);
    // After the deadline, the receiver closed the port: a new receiver can listen on it. The
    // old start URL then gets 404 and no redirect, and it does not end the new wait.
    _ = try testExpectStartUrl(silent.url.items, port);
    const parts = try testSplitUrl(silent.url.items);
    var next: Receiver = undefined;
    try next.start(io, testing.allocator, .{ .port = port, .state = "st", .start = .{ .token = try newStartToken(io), .location = test_location }, .limits = test_limits });
    defer next.stop();
    try testing.expectEqual(@as(u16, 404), try testGet(io, arena, port, parts.target));
    try testing.expectError(error.Timeout, next.wait(testDeadline(io, 100)));
}

test "with no_browser the opener does not run, and the redirect from the sign-in line works" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .record };
    defer browser.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{
        .name = "t",
        .redirect_port = port,
        .no_browser = true,
        .opener = browser.opener(),
        .output = out.output(),
        .limits = test_limits,
    });
    const Helper = struct {
        fn run(o: *TestOutput, p: u16) void {
            o.written.wait(testing.io) catch return;
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            _ = testGet(testing.io, a.allocator(), p, "/callback?code=k&state=st-2") catch {};
        }
    };
    var helper = try io.concurrent(Helper.run, .{ &out, port });
    defer helper.await(io);
    const redirect = try sign_in.run(arena, try testAuthorizationUrl(arena, port, "st-2"));
    try testing.expect(std.mem.endsWith(u8, redirect, "/callback?code=k&state=st-2"));
    try testing.expectEqual(@as(u32, 0), browser.calls.load(.acquire));
    try testing.expectEqual(@as(usize, 1), out.count);
}

test "with no_browser the receiver serves no start path" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .no_browser = true, .output = out.output(), .limits = test_limits });
    const Helper = struct {
        /// The number of start paths that did not get 404.
        others: std.atomic.Value(u32) = .init(0),

        fn run(self: *@This(), o: *TestOutput, p: u16) void {
            o.written.wait(testing.io) catch return;
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            // Each start path gets 404, and the sign-in goes on.
            for ([_][]const u8{ start_path_prefix, start_path_prefix ++ "A" ** start_token_len, start_path_prefix ++ "x" }) |target| {
                const status = testGet(testing.io, a.allocator(), p, target) catch 0;
                if (status != 404) _ = self.others.fetchAdd(1, .acq_rel);
            }
            _ = testGet(testing.io, a.allocator(), p, "/callback?code=k&state=st-3") catch {};
        }
    };
    var helper: Helper = .{};
    var task = try io.concurrent(Helper.run, .{ &helper, &out, port });
    defer task.await(io);
    const url = try testAuthorizationUrl(arena, port, "st-3");
    const redirect = try sign_in.run(arena, url);
    try testing.expect(std.mem.endsWith(u8, redirect, "/callback?code=k&state=st-3"));
    try testing.expectEqual(@as(u32, 0), helper.others.load(.acquire));
    // The line has the authorization URL.
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "t: sign in at {s}\n", .{url}), out.lines.items);
}

test "a URL that is not valid gives no line, no browser and the reason invalid_url" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .record };
    defer browser.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = browser.opener(), .output = out.output() });
    for ([_][]const u8{
        "https://a.example/x\"&calc&\"",
        "https://a.example/authorize?state=%USERNAME%",
        "file:///C:/Windows/System32/calc.exe?state=x",
        // No state.
        "https://a.example/authorize?code_challenge=x",
        // A redirect URI of another port.
        "https://a.example/authorize?state=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback",
    }) |url| {
        try testing.expectError(error.SignInFailed, sign_in.run(arena, url));
        try testing.expectEqual(Reason.invalid_url, sign_in.lastFailure().?.reason);
    }
    try testing.expectEqual(@as(usize, 0), out.count);
    try testing.expectEqual(@as(u32, 0), browser.calls.load(.acquire));
}

test "a redirect port in use fails at once with a message that names the port and the option" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var other = try address.listen(io, .{});
    defer other.deinit(io);
    const port = other.socket.address.getPort();
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .record };
    defer browser.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = browser.opener(), .output = out.output() });
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "s")));
    const failure = sign_in.lastFailure().?;
    try testing.expectEqual(Reason.address_in_use, failure.reason);
    const message = try std.fmt.allocPrint(arena, "{f}", .{&failure});
    const port_text = try std.fmt.allocPrint(arena, "{d}", .{port});
    try testing.expect(std.mem.indexOf(u8, message, port_text) != null);
    try testing.expect(std.mem.indexOf(u8, message, "--redirect-port") != null);
    try testing.expectEqual(@as(usize, 0), out.count);
    try testing.expectEqual(@as(u32, 0), browser.calls.load(.acquire));
}

test "access_denied, the deadline and a browser that does not open" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();

    // Denied.
    var denied: TestBrowser = .{ .mode = .redirect_denied, .port = port };
    defer denied.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = denied.opener(), .output = out.output(), .limits = test_limits });
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "s1")));
    try testing.expectEqual(Reason.denied, sign_in.lastFailure().?.reason);

    // The deadline: the message names the time limit.
    var silent: TestBrowser = .{ .mode = .record };
    defer silent.deinit();
    sign_in = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = silent.opener(), .output = out.output(), .limits = test_limits, .timeout = .fromMilliseconds(300) });
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "s2")));
    var failure = sign_in.lastFailure().?;
    try testing.expectEqual(Reason.timeout, failure.reason);
    try testing.expectEqualStrings("The sign-in did not complete in 1 s.", try std.fmt.allocPrint(arena, "{f}", .{&failure}));

    // A browser that does not open: by default the sign-in waits, and the message says so.
    var broken: TestBrowser = .{ .mode = .fail };
    defer broken.deinit();
    sign_in = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = broken.opener(), .output = out.output(), .limits = test_limits, .timeout = .fromMilliseconds(300) });
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "s3")));
    failure = sign_in.lastFailure().?;
    try testing.expectEqual(Reason.timeout, failure.reason);
    try testing.expect(failure.browser_failed);
    try testing.expect(std.mem.indexOf(u8, try std.fmt.allocPrint(arena, "{f}", .{&failure}), "The browser did not open.") != null);

    // With opener_failure_fatal, the sign-in ends at once.
    sign_in = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = broken.opener(), .output = out.output(), .limits = test_limits, .opener_failure_fatal = true });
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "s4")));
    try testing.expectEqual(Reason.browser_launch_failed, sign_in.lastFailure().?.reason);

    // A declined URL ends the sign-in at once, also without opener_failure_fatal.
    var declining: TestBrowser = .{ .mode = .decline };
    defer declining.deinit();
    sign_in = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = declining.opener(), .output = out.output(), .limits = test_limits });
    const start = nowNs(io);
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testAuthorizationUrl(arena, port, "s5")));
    try testing.expectEqual(Reason.declined, sign_in.lastFailure().?.reason);
    try testing.expect(nowNs(io) - start < 5 * std.time.ns_per_s);

    // A different error code of the redirect is part of the message.
    const failed: Failure = .{ .reason = .authorization_error, .error_code = .init("invalid_scope") };
    try testing.expectEqualStrings("The authorization server sent an error for the sign-in. The error code is invalid_scope.", try std.fmt.allocPrint(arena, "{f}", .{&failed}));
}

test "a cancel or an abort during the wait ends the sign-in well inside 10 s, 20 times" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    const Task = struct {
        fn run(s: *SignIn, url: []const u8) SignIn.Error!void {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            _ = try s.run(a.allocator(), url);
        }
    };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const url = try testAuthorizationUrl(arena_state.allocator(), port, "st");
    for (0..20) |i| {
        var browser: TestBrowser = .{ .mode = .record };
        defer browser.deinit();
        var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = browser.opener(), .output = out.output(), .limits = test_limits });
        const start = nowNs(io);
        var task = try io.concurrent(Task.run, .{ &sign_in, url });
        // The browser opens after the receiver listens: the wait starts then.
        if (!try waitUntil(io, &browser.opened, testDeadline(io, 5000))) return error.TestUnexpectedResult;
        if (i % 2 == 0) {
            try testing.expectError(error.Canceled, task.cancel(io));
            try testing.expectEqual(Reason.canceled, sign_in.lastFailure().?.reason);
        } else {
            sign_in.abort();
            try testing.expectError(error.SignInFailed, task.await(io));
            try testing.expectEqual(Reason.closed, sign_in.lastFailure().?.reason);
            // After an abort, each new sign-in fails at once.
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            try testing.expectError(error.SignInFailed, sign_in.run(a.allocator(), url));
        }
        try testing.expect(nowNs(io) - start < 10 * std.time.ns_per_s);
    }
}

// -- The sign-in with OAuthClient ---------------------------------------------------------------

/// A protected resource and an authorization server in one plain HTTP listener for the test
/// of the whole flow. It answers one request on each connection.
const FakeServer = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    stopping: std.atomic.Value(bool) = .init(false),
    future: Io.Future(void) = undefined,
    register_body: std.ArrayList(u8) = .empty,
    token_requests: u32 = 0,
    /// The authorization server has no registration endpoint.
    no_registration: bool = false,

    fn start(self: *FakeServer, io: Io) !void {
        return self.startWith(io, false);
    }

    fn startWith(self: *FakeServer, io: Io, no_registration: bool) !void {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const listener = try address.listen(io, .{});
        self.* = .{ .io = io, .listener = listener, .port = listener.socket.address.getPort(), .no_registration = no_registration };
        self.future = try io.concurrent(loop, .{self});
    }

    fn stop(self: *FakeServer) void {
        mcp.util.wake.cancelAcceptLoop(self.io, &self.future, self.listener.socket.address, &self.stopping);
        self.listener.deinit(self.io);
        self.register_body.deinit(testing.allocator);
    }

    fn loop(self: *FakeServer) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            if (self.stopping.load(.acquire)) return;
            self.serve(stream) catch {};
        }
    }

    fn serve(self: *FakeServer, stream: Io.net.Stream) !void {
        const io = self.io;
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var socket_reader = stream.reader(io, &in_buf);
        var socket_writer = stream.writer(io, &out_buf);
        var http_reader: std.http.Reader = .{ .in = &socket_reader.interface, .interface = undefined, .state = .ready, .max_head_len = in_buf.len };
        const head = try arena.dupe(u8, try http_reader.receiveHead());
        const line = head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len];
        var parts = std.mem.splitScalar(u8, line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;
        var content_length: usize = 0;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        _ = lines.next();
        while (lines.next()) |h| {
            const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(h[0..colon], "content-length")) content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, h[colon + 1 ..], " "), 10);
        }
        const body = try arena.alloc(u8, content_length);
        try socket_reader.interface.readSliceAll(body);

        const origin = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{self.port});
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        var status: []const u8 = "404 Not Found";
        var reply: []const u8 = "{}";
        var location: ?[]const u8 = null;
        if (std.mem.startsWith(u8, path, "/.well-known/oauth-protected-resource")) {
            status = "200 OK";
            reply = try std.fmt.allocPrint(arena, "{{\"resource\":\"{s}/mcp\",\"authorization_servers\":[\"{s}\"]}}", .{ origin, origin });
        } else if (std.mem.startsWith(u8, path, "/.well-known/oauth-authorization-server")) {
            status = "200 OK";
            const registration = if (self.no_registration) "" else try std.fmt.allocPrint(arena, "\"registration_endpoint\":\"{s}/register\",", .{origin});
            reply = try std.fmt.allocPrint(arena, "{{\"issuer\":\"{s}\",\"authorization_endpoint\":\"{s}/authorize\",\"token_endpoint\":\"{s}/token\"," ++
                "{s}\"code_challenge_methods_supported\":[\"S256\"]," ++
                "\"token_endpoint_auth_methods_supported\":[\"none\"],\"response_types_supported\":[\"code\"]}}", .{ origin, origin, origin, registration });
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/register")) {
            try self.register_body.appendSlice(testing.allocator, body);
            status = "201 Created";
            reply = "{\"client_id\":\"bridge-client-1\",\"token_endpoint_auth_method\":\"none\"}";
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/authorize")) {
            const params = try auth.common.parseQuery(arena, target);
            var aw: Io.Writer.Allocating = .init(arena);
            try aw.writer.writeAll(params.get("redirect_uri") orelse return error.MissingRedirectUri);
            try aw.writer.writeAll("?code=fake-code");
            try auth.common.formField(&aw.writer, "state", params.get("state") orelse "", false);
            try auth.common.formField(&aw.writer, "iss", origin, false);
            status = "302 Found";
            location = aw.written();
            reply = "";
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/token")) {
            self.token_requests += 1;
            status = "200 OK";
            reply = "{\"access_token\":\"fake-access-token\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
        }
        const w = &socket_writer.interface;
        try w.print("HTTP/1.1 {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n", .{ status, reply.len });
        if (location) |l| try w.print("location: {s}\r\n", .{l});
        try w.print("\r\n{s}", .{reply});
        try w.flush();
    }
};

test "OAuthClient signs in through the receiver with the identity of the bridge" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server: FakeServer = undefined;
    try server.start(io);
    defer server.stop();

    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .follow };
    defer browser.deinit();
    var sign_in: SignIn = .init(io, gpa, .{
        .name = "mcp-bridge-vscode",
        .redirect_port = port,
        .opener = browser.opener(),
        .output = out.output(),
        .limits = test_limits,
        .allow_http = true,
    });
    const identity: Identity = .of("mcp-bridge-vscode", "vscode", null);
    const storage_identity = try identity.storageIdentity(gpa, default_account, sign_in.redirectUri());
    defer gpa.free(storage_identity);
    var memory: auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    var options = clientOptions(.{ .identity = identity, .sign_in = &sign_in, .storage = memory.storage(), .storage_identity = storage_identity });
    options.allow_http = true;
    var client: auth.OAuthClient = .init(io, gpa, options);
    defer client.deinit();

    const server_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/mcp", .{server.port});
    const token = try client.handleChallenge(arena, server_url, 401, null, 1);
    try testing.expectEqualStrings("fake-access-token", token);

    // The registration has the client name and the redirect URI of the bridge.
    const register = server.register_body.items;
    try testing.expect(std.mem.indexOf(u8, register, "\"client_name\":\"mcp-bridge-vscode (zig-bridge-sdk)\"") != null);
    const redirect_field = try std.fmt.allocPrint(arena, "\"redirect_uris\":[\"http://127.0.0.1:{d}/callback\"]", .{port});
    try testing.expect(std.mem.indexOf(u8, register, redirect_field) != null);

    // One sign-in line with the authorization URL, one browser call with the start URL, and
    // the browser saw the page of the receiver.
    try testing.expectEqual(@as(usize, 1), out.count);
    const line_start = try std.fmt.allocPrint(arena, "mcp-bridge-vscode: sign in at http://127.0.0.1:{d}/authorize?", .{server.port});
    try testing.expect(std.mem.startsWith(u8, out.lines.items, line_start));
    try testing.expectEqual(@as(u32, 1), browser.calls.load(.acquire));
    _ = try testExpectStartUrl(browser.url.items, port);
    try testing.expectEqual(@as(u16, 200), browser.status);
    try testing.expectEqual(@as(u32, 1), server.token_requests);

    // The record has the storage identity of the bridge.
    const origin = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.port});
    var record = (try memory.storage().load(gpa, .{ .issuer = origin, .resource = server_url, .client = storage_identity })).?;
    defer record.deinit(gpa);
    try testing.expectEqualStrings("fake-access-token", record.access_token.?);
    try testing.expectEqualStrings("bridge-client-1", record.registration.?.client_id);
}

// -- TokenStore tests ---------------------------------------------------------------------------

const test_identity: Identity = .of("mcp-bridge-test", "test", "https://client.example/bridge.json");
const test_key_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
const test_record_key: auth.token_storage.Key = .{ .issuer = "https://as.example", .resource = "https://mcp.example/mcp", .client = "mcp-bridge-test|default|http://127.0.0.1:41894/callback" };

/// A storage that answers like a keychain that locks after some calls.
const TestKeychain = struct {
    memory: auth.MemoryTokenStorage,
    fail_with: ?auth.TokenStorage.Error = null,
    calls: u32 = 0,

    fn storage(self: *TestKeychain) auth.TokenStorage {
        return .{ .ptr = self, .vtable = &.{ .load = load, .save = save, .delete = delete } };
    }

    fn load(ptr: *anyopaque, gpa: Allocator, key: auth.token_storage.Key) auth.TokenStorage.Error!?[]u8 {
        const self: *TestKeychain = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.fail_with) |e| return e;
        return self.memory.storage().vtable.load(&self.memory, gpa, key);
    }

    fn save(ptr: *anyopaque, key: auth.token_storage.Key, data: []const u8) auth.TokenStorage.Error!void {
        const self: *TestKeychain = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.fail_with) |e| return e;
        return self.memory.storage().vtable.save(&self.memory, key, data);
    }

    fn delete(ptr: *anyopaque, key: auth.token_storage.Key) auth.TokenStorage.Error!void {
        const self: *TestKeychain = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (self.fail_with) |e| return e;
        return self.memory.storage().vtable.delete(&self.memory, key);
    }
};

/// A temporary directory with an absolute path.
const TestDir = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,

    fn init() !TestDir {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .path = path };
    }

    fn join(self: *const TestDir, arena: Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(arena, &.{ self.path, name });
    }

    fn deinit(self: *TestDir) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

/// Writes a token key file. `private` gives it the mode 0600, or a list with the user only on
/// Windows. Else other accounts can read it.
fn testWriteKeyFile(path: []const u8, text: []const u8, private: bool) !void {
    const io = testing.io;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
    if (builtin.os.tag == .windows) {
        try win.setTestAcl(path, !private);
    } else {
        try Io.Dir.cwd().setFilePermissions(io, path, .fromMode(if (private) 0o600 else 0o644), .{});
    }
}

test "auto: a keychain that is not available at the start gives memory without a key" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var store: TokenStore = undefined;
    try store.open(testing.io, testing.allocator, .{ .identity = test_identity, .environ_map = &env, .keychain = .{ .init_error = error.KeychainUnavailable }, .token_dir = "unused" });
    defer store.deinit();
    try testing.expectEqual(TokenStore.Kind.memory, store.activeKind());
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try store.describe(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "KeychainUnavailable") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), token_key_variable) != null);
    // No secret in the line.
    try store.storage().save(testing.allocator, test_record_key, .{ .access_token = "secret-token" });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "secret") == null);
}

test "auto: a locked keychain with a key gives the file store, and the record survives a second start" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir: TestDir = try .init();
    defer dir.deinit();
    const token_dir = try dir.join(arena, "state/zig-bridge-sdk/test/tokens");
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put(token_key_variable, test_key_hex);
    {
        var store: TokenStore = undefined;
        try store.open(io, testing.allocator, .{ .identity = test_identity, .environ_map = &env, .keychain = .{ .init_error = error.KeychainLocked }, .token_dir = token_dir });
        defer store.deinit();
        try testing.expectEqual(TokenStore.Kind.file, store.activeKind());
        try store.storage().save(testing.allocator, test_record_key, .{ .access_token = "made-up-token" });
    }
    {
        var store: TokenStore = undefined;
        try store.open(io, testing.allocator, .{ .identity = test_identity, .environ_map = &env, .keychain = .{ .init_error = error.KeychainLocked }, .token_dir = token_dir });
        defer store.deinit();
        var record = (try store.storage().load(testing.allocator, test_record_key)).?;
        defer record.deinit(testing.allocator);
        try testing.expectEqualStrings("made-up-token", record.access_token.?);
    }
}

test "auto: a keychain that locks later switches to the fallback one time" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var keychain: TestKeychain = .{ .memory = .init(testing.io, testing.allocator) };
    defer keychain.memory.deinit();
    var store: TokenStore = undefined;
    try store.open(testing.io, testing.allocator, .{ .identity = test_identity, .environ_map = &env, .keychain = .{ .replacement = keychain.storage() }, .token_dir = "unused" });
    defer store.deinit();
    const s = store.storage();
    try testing.expectEqual(TokenStore.Kind.keychain, store.activeKind());
    try s.save(testing.allocator, test_record_key, .{ .access_token = "in-keychain" });
    try testing.expectEqual(@as(usize, 1), keychain.memory.count());

    keychain.fail_with = error.KeychainLocked;
    try testing.expect((try s.load(testing.allocator, test_record_key)) == null);
    try testing.expectEqual(TokenStore.Kind.memory, store.activeKind());
    const calls = keychain.calls;
    try s.save(testing.allocator, test_record_key, .{ .access_token = "in-memory" });
    var record = (try s.load(testing.allocator, test_record_key)).?;
    defer record.deinit(testing.allocator);
    try testing.expectEqualStrings("in-memory", record.access_token.?);
    // The keychain gets no more calls.
    try testing.expectEqual(calls, keychain.calls);

    // Another error of the keychain does not switch.
    var other: TestKeychain = .{ .memory = .init(testing.io, testing.allocator), .fail_with = error.StorageFailed };
    defer other.memory.deinit();
    var store2: TokenStore = undefined;
    try store2.open(testing.io, testing.allocator, .{ .identity = test_identity, .environ_map = &env, .keychain = .{ .replacement = other.storage() }, .token_dir = "unused" });
    defer store2.deinit();
    try testing.expectError(error.StorageFailed, store2.storage().load(testing.allocator, test_record_key));
    try testing.expectEqual(TokenStore.Kind.keychain, store2.activeKind());
}

test "an explicit choice that does not work is an error" {
    const io = testing.io;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var store: TokenStore = undefined;
    try testing.expectError(error.KeychainUnavailable, store.open(io, testing.allocator, .{ .choice = .keychain, .identity = test_identity, .environ_map = &env, .keychain = .{ .init_error = error.KeychainUnavailable }, .token_dir = "unused" }));
    try testing.expectError(error.KeychainLocked, store.open(io, testing.allocator, .{ .choice = .keychain, .identity = test_identity, .environ_map = &env, .keychain = .{ .init_error = error.KeychainLocked }, .token_dir = "unused" }));
    try testing.expectError(error.TokenKeyMissing, store.open(io, testing.allocator, .{ .choice = .file, .identity = test_identity, .environ_map = &env, .token_dir = "unused" }));

    // An explicit keychain that locks later does not switch.
    var keychain: TestKeychain = .{ .memory = .init(io, testing.allocator) };
    defer keychain.memory.deinit();
    try store.open(io, testing.allocator, .{ .choice = .keychain, .identity = test_identity, .environ_map = &env, .keychain = .{ .replacement = keychain.storage() }, .token_dir = "unused" });
    defer store.deinit();
    keychain.fail_with = error.KeychainLocked;
    try testing.expectError(error.KeychainLocked, store.storage().load(testing.allocator, test_record_key));
    try testing.expectEqual(TokenStore.Kind.keychain, store.activeKind());

    // Memory needs nothing, and it does not read the token key.
    try env.put(token_key_variable, "not-a-key");
    var memory_store: TokenStore = undefined;
    try memory_store.open(io, testing.allocator, .{ .choice = .memory, .identity = test_identity, .environ_map = &env, .token_dir = "unused" });
    defer memory_store.deinit();
    try testing.expectEqual(TokenStore.Kind.memory, memory_store.activeKind());
}

test "the token key: a bad length, a key file that is not private, and a private key file" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir: TestDir = try .init();
    defer dir.deinit();
    const token_dir = try dir.join(arena, "tokens");

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var store: TokenStore = undefined;
    try env.put(token_key_variable, "0011");
    try testing.expectError(error.InvalidTokenKey, store.open(io, testing.allocator, .{ .identity = test_identity, .environ_map = &env, .keychain = .{ .init_error = error.KeychainUnavailable }, .token_dir = token_dir }));
    try env.put(token_key_variable, "zz" ** 32);
    try testing.expectError(error.InvalidTokenKey, store.open(io, testing.allocator, .{ .identity = test_identity, .environ_map = &env, .keychain = .{ .init_error = error.KeychainUnavailable }, .token_dir = token_dir }));
    _ = env.swapRemove(token_key_variable);

    const open_file = try dir.join(arena, "open.key");
    try testWriteKeyFile(open_file, test_key_hex ++ "\n", false);
    try testing.expectError(error.TokenKeyFileNotPrivate, store.open(io, testing.allocator, .{ .choice = .file, .identity = test_identity, .environ_map = &env, .token_key_file = open_file, .token_dir = token_dir }));

    try testing.expectError(error.TokenKeyFileUnreadable, store.open(io, testing.allocator, .{ .choice = .file, .identity = test_identity, .environ_map = &env, .token_key_file = try dir.join(arena, "missing.key"), .token_dir = token_dir }));

    const short_file = try dir.join(arena, "short.key");
    try testWriteKeyFile(short_file, "0011\n", true);
    try testing.expectError(error.InvalidTokenKey, store.open(io, testing.allocator, .{ .choice = .file, .identity = test_identity, .environ_map = &env, .token_key_file = short_file, .token_dir = token_dir }));

    const private_file = try dir.join(arena, "private.key");
    try testWriteKeyFile(private_file, test_key_hex ++ "\n", true);
    try store.open(io, testing.allocator, .{ .choice = .file, .identity = test_identity, .environ_map = &env, .token_key_file = private_file, .token_dir = token_dir });
    defer store.deinit();
    try testing.expectEqual(TokenStore.Kind.file, store.activeKind());
    try store.storage().save(testing.allocator, test_record_key, .{ .access_token = "made-up-token" });

    // A key file in the token directory is refused.
    const inside = try std.fs.path.join(arena, &.{ token_dir, "key.txt" });
    try testWriteKeyFile(inside, test_key_hex, true);
    var store2: TokenStore = undefined;
    try testing.expectError(error.TokenKeyInTokenDirectory, store2.open(io, testing.allocator, .{ .choice = .file, .identity = test_identity, .environ_map = &env, .token_key_file = inside, .token_dir = token_dir }));
}

test "the default token directory and the prompt policy" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.NoTokenDirectory, defaultTokenDir(testing.allocator, &env, "vscode"));
    if (builtin.os.tag == .windows) {
        try env.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
        const dir = try defaultTokenDir(testing.allocator, &env, "vscode");
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\zig-bridge-sdk\\vscode\\tokens", dir);
        try testing.expect(defaultAllowPrompt(&env));
    } else {
        try env.put("HOME", "/home/u");
        const home_dir = try defaultTokenDir(testing.allocator, &env, "vscode");
        defer testing.allocator.free(home_dir);
        try testing.expectEqualStrings("/home/u/.local/state/zig-bridge-sdk/vscode/tokens", home_dir);
        try env.put("XDG_STATE_HOME", "/state");
        const state_dir = try defaultTokenDir(testing.allocator, &env, "vscode");
        defer testing.allocator.free(state_dir);
        try testing.expectEqualStrings("/state/zig-bridge-sdk/vscode/tokens", state_dir);
        if (builtin.os.tag != .macos) {
            try testing.expect(!defaultAllowPrompt(&env));
            try env.put("WAYLAND_DISPLAY", "wayland-0");
            try testing.expect(defaultAllowPrompt(&env));
        }
    }
}

test "the keychain of the host with a random service, when the host has one" {
    const io = testing.io;
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    var random: [8]u8 = undefined;
    io.random(&random);
    var service_buf: [64]u8 = undefined;
    const service = try std.fmt.bufPrint(&service_buf, "zig-bridge-sdk-test-{s}", .{&std.fmt.bytesToHex(random, .lower)});
    var store: TokenStore = undefined;
    store.open(io, testing.allocator, .{
        .choice = .keychain,
        .identity = test_identity,
        .environ_map = &env,
        .keychain_service = service,
        .allow_prompt = false,
        .token_dir = "unused",
    }) catch |e| switch (e) {
        error.KeychainUnavailable, error.KeychainLocked, error.KeychainFailed => return error.SkipZigTest,
        else => return e,
    };
    defer store.deinit();
    const s = store.storage();
    defer s.delete(test_record_key) catch {};
    s.save(testing.allocator, test_record_key, .{ .access_token = "made-up-token" }) catch |e| switch (e) {
        error.KeychainUnavailable, error.KeychainLocked => return error.SkipZigTest,
        else => return e,
    };
    var record = (try s.load(testing.allocator, test_record_key)).?;
    defer record.deinit(testing.allocator);
    try testing.expectEqualStrings("made-up-token", record.access_token.?);
    try s.delete(test_record_key);
    try testing.expect((try s.load(testing.allocator, test_record_key)) == null);
}

// -- Gate, Authorizer and logout tests ---------------------------------------------------------

/// A client for the tests of the gate. It records each question and each completion. It never
/// opens a browser: in the mode `accept`, it sends the redirect with a code to the receiver.
const TestConsent = struct {
    mode: enum { accept, decline },
    /// The redirect port of the receiver, for `accept`.
    port: u16 = 0,
    asks: std.atomic.Value(u32) = .init(0),
    lock: Io.Mutex = .init,
    completed: std.ArrayList(Ticket) = .empty,
    /// The URL of the last question.
    url: std.ArrayList(u8) = .empty,

    const ticket: Ticket = 7;
    const vtable: Consent.VTable = .{ .ask = ask, .complete = complete };

    fn consent(self: *TestConsent) Consent {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ask(context: *anyopaque, io: Io, url: []const u8, timeout: Io.Duration) ConsentError!Ticket {
        _ = timeout;
        const self: *TestConsent = @ptrCast(@alignCast(context));
        _ = self.asks.fetchAdd(1, .acq_rel);
        {
            self.lock.lockUncancelable(testing.io);
            defer self.lock.unlock(testing.io);
            self.url.clearRetainingCapacity();
            try self.url.appendSlice(testing.allocator, url);
        }
        if (self.mode == .decline) return error.Declined;
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const params = try auth.common.parseQuery(arena, url);
        const target = try std.fmt.allocPrint(arena, "/callback?code=consent-code&state={s}", .{params.get("state") orelse ""});
        _ = testGet(io, arena, self.port, target) catch return error.Declined;
        return ticket;
    }

    fn complete(context: *anyopaque, t: Ticket) void {
        const self: *TestConsent = @ptrCast(@alignCast(context));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.completed.append(testing.allocator, t) catch {};
    }

    fn deinit(self: *TestConsent) void {
        self.completed.deinit(testing.allocator);
        self.url.deinit(testing.allocator);
    }
};

fn testScopedUrl(arena: Allocator, port: u16, state: []const u8, scope: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ try testAuthorizationUrl(arena, port, state), "&scope=", scope });
}

test "the gate opens the browser before notifications/initialized, and asks the client after it" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .redirect_code, .port = port };
    defer browser.deinit();
    var gate: Gate = .init(io, browser.opener(), .fromSeconds(10), .fromSeconds(60));
    defer gate.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = gate.opener(), .output = out.output(), .limits = test_limits, .timeout = .fromSeconds(10) });

    const first_url = try testAuthorizationUrl(arena, port, "s1");
    _ = try sign_in.run(arena, first_url);
    try testing.expectEqual(@as(u32, 1), browser.calls.load(.acquire));
    // The browser got the start URL, and the start URL gave the authorization URL.
    _ = try testExpectStartUrl(browser.url.items, port);
    try testing.expectEqualStrings(first_url, browser.location.items);

    var client: TestConsent = .{ .mode = .accept, .port = port };
    defer client.deinit();
    gate.useConsent(client.consent());
    const second_url = try testAuthorizationUrl(arena, port, "s2");
    const redirect = try sign_in.run(arena, second_url);
    try testing.expect(std.mem.endsWith(u8, redirect, "/callback?code=consent-code&state=s2"));
    // The bridge did not open the browser. The client got the question with the full
    // authorization URL, and the completion after the redirect.
    try testing.expectEqual(@as(u32, 1), browser.calls.load(.acquire));
    try testing.expectEqual(@as(u32, 1), client.asks.load(.acquire));
    try testing.expectEqualStrings(second_url, client.url.items);
    try testing.expectEqualSlices(Ticket, &.{TestConsent.ticket}, client.completed.items);
    // Each sign-in writes its line.
    try testing.expectEqual(@as(usize, 2), out.count);
}

test "the gate gives the start URL to the browser, the authorization URL to the client, and no destination without a browser" {
    const io = testing.io;
    const url = "https://as.example/authorize?state=s";
    var browser: TestBrowser = .{ .mode = .record };
    defer browser.deinit();
    var client: TestConsent = .{ .mode = .decline };
    defer client.deinit();
    // The system opener and a test browser without `delivery` get the start URL.
    try testing.expect(Opener.system.delivery == null);
    try testing.expect(browser.opener().delivery == null);
    {
        var gate: Gate = .init(io, browser.opener(), .fromSeconds(10), .fromSeconds(60));
        defer gate.deinit();
        const o = gate.opener();
        try o.check.?(o.context, url);
        try testing.expectEqual(Delivery.browser, o.delivery.?(o.context));
        o.finish.?(o.context, null);
        gate.useConsent(client.consent());
        try o.check.?(o.context, url);
        try testing.expectEqual(Delivery.user, o.delivery.?(o.context));
        o.finish.?(o.context, .canceled);
    }
    {
        // `--no-browser`: the gate opens nothing before notifications/initialized.
        var gate: Gate = .init(io, null, .fromSeconds(10), .fromSeconds(60));
        defer gate.deinit();
        const o = gate.opener();
        try o.check.?(o.context, url);
        try testing.expectEqual(Delivery.none, o.delivery.?(o.context));
        o.finish.?(o.context, null);
    }
    try testing.expectEqual(@as(u32, 0), browser.calls.load(.acquire));
}

test "a declined sign-in starts a cooldown for all scopes, a failure before the question starts none, and without consent each sign-in fails at once" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var gate: Gate = .init(io, null, .fromSeconds(10), .fromMilliseconds(1500));
    defer gate.deinit();
    var sign_in: SignIn = .init(io, testing.allocator, .{ .name = "t", .redirect_port = port, .opener = gate.opener(), .output = out.output(), .limits = test_limits, .timeout = .fromSeconds(10) });
    var client: TestConsent = .{ .mode = .decline };
    defer client.deinit();
    gate.useConsent(client.consent());

    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testScopedUrl(arena, port, "s1", "mcp%3Aread")));
    try testing.expectEqual(Reason.declined, sign_in.lastFailure().?.reason);
    try testing.expectEqual(@as(u32, 1), client.asks.load(.acquire));
    try testing.expectEqual(@as(usize, 0), client.completed.items.len);
    try testing.expectEqual(@as(usize, 1), out.count);

    // In the cooldown, the same scopes and other scopes get no question, no line and no
    // receiver. The upstream server chooses the scopes, thus new scopes do not end the
    // cooldown.
    for ([_][]const u8{ "mcp%3Aread", "mcp%3Awrite", "x1", "x2" }, 0..) |scope, i| {
        const state = try std.fmt.allocPrint(arena, "c{d}", .{i});
        try testing.expectError(error.SignInFailed, sign_in.run(arena, try testScopedUrl(arena, port, state, scope)));
        try testing.expectEqual(Reason.cooldown, sign_in.lastFailure().?.reason);
    }
    try testing.expectEqual(@as(u32, 1), client.asks.load(.acquire));
    try testing.expectEqual(@as(usize, 1), out.count);

    // After the cooldown, a sign-in that fails before the question starts no cooldown: here
    // another socket uses the redirect port.
    try io.sleep(.fromMilliseconds(1600), .awake);
    {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var other = try address.listen(io, .{});
        defer other.deinit(io);
        try testing.expectError(error.SignInFailed, sign_in.run(arena, try testScopedUrl(arena, port, "s2", "mcp%3Awrite")));
        try testing.expectEqual(Reason.address_in_use, sign_in.lastFailure().?.reason);
        try testing.expectEqual(@as(u32, 1), client.asks.load(.acquire));
    }
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testScopedUrl(arena, port, "s3", "mcp%3Awrite")));
    try testing.expectEqual(Reason.declined, sign_in.lastFailure().?.reason);
    try testing.expectEqual(@as(u32, 2), client.asks.load(.acquire));

    // A client without URL elicitation: each sign-in fails at once, with no line.
    gate.useConsent(null);
    const lines = out.count;
    try testing.expectError(error.SignInFailed, sign_in.run(arena, try testScopedUrl(arena, port, "s6", "other")));
    try testing.expectEqual(Reason.no_consent, sign_in.lastFailure().?.reason);
    try testing.expectEqual(lines, out.count);
    try testing.expectEqual(@as(u32, 2), client.asks.load(.acquire));
}

test "the index keeps each stored sign-in, and logout deletes the sign-in of one account" {
    const io = testing.io;
    const gpa = testing.allocator;
    var memory: auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const Key = auth.token_storage.Key;
    const a_url = "https://a.example/mcp";
    const default_id = "mcp-bridge-test|default|http://127.0.0.1:41894/callback";
    const work_id = "mcp-bridge-test|work|http://127.0.0.1:41894/callback";
    const key_a: Key = .{ .issuer = "https://as.example", .resource = a_url, .client = default_id };
    const key_work: Key = .{ .issuer = "https://as.example", .resource = a_url, .client = work_id };
    const key_b: Key = .{ .issuer = "https://as.example", .resource = "https://b.example/mcp", .client = default_id };
    // The record of a pre-registered client of the same account has a suffix.
    const key_client: Key = .{ .issuer = "https://as.example", .resource = a_url, .client = default_id ++ "|client=c1" };
    var a: IndexedStorage = .{ .io = io, .gpa = gpa, .inner = memory.storage(), .identity = test_identity, .server_url = a_url };
    var b: IndexedStorage = .{ .io = io, .gpa = gpa, .inner = memory.storage(), .identity = test_identity, .server_url = "https://b.example/mcp" };
    try a.storage().save(gpa, key_a, .{ .access_token = "made-up-1" });
    // A refresh saves the record again, and the index keeps one entry.
    try a.storage().save(gpa, key_a, .{ .access_token = "made-up-2", .refresh_token = "made-up-r" });
    try a.storage().save(gpa, key_work, .{ .access_token = "made-up-w" });
    try a.storage().save(gpa, key_client, .{ .access_token = "made-up-c" });
    try b.storage().save(gpa, key_b, .{ .access_token = "made-up-b" });
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 4), (try loadIndex(arena, memory.storage(), test_identity)).len);
    // The index is a record of the storage.
    try testing.expectEqual(@as(usize, 5), memory.count());

    // logout of the account deletes the record of each registration of the account.
    const report = try logout(io, gpa, memory.storage(), .{ .identity = test_identity, .url = a_url, .storage_identity = default_id });
    try testing.expectEqual(@as(usize, 2), report.deleted);
    try testing.expectEqual(LogoutReport.Discovery.not_needed, report.discovery);
    try testing.expect((try memory.storage().load(gpa, key_a)) == null);
    try testing.expect((try memory.storage().load(gpa, key_client)) == null);
    var work = (try memory.storage().load(gpa, key_work)).?;
    work.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), (try loadIndex(arena, memory.storage(), test_identity)).len);

    // A delete of OAuthClient removes the entry too.
    try a.storage().delete(key_work);
    try testing.expectEqual(@as(usize, 1), (try loadIndex(arena, memory.storage(), test_identity)).len);

    // logout --all deletes each indexed record and the index.
    try testing.expectEqual(@as(usize, 1), try logoutAll(gpa, memory.storage(), test_identity));
    try testing.expectEqual(@as(usize, 0), memory.count());
}

test "without an index entry, logout finds the key through the protected resource metadata" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var server: FakeServer = undefined;
    try server.start(io);
    defer server.stop();
    const origin = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.port});
    const url = try std.fmt.allocPrint(arena, "{s}/mcp", .{origin});
    const id = "mcp-bridge-test|default|http://127.0.0.1:41894/callback";
    var memory: auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    try memory.storage().save(gpa, .{ .issuer = origin, .resource = url, .client = id }, .{ .access_token = "made-up" });

    // The metadata of the server at another URL names the resource of the record. The
    // resource does not cover that URL, thus logout deletes nothing: a server cannot name the
    // record of a different server.
    const other = try logout(io, gpa, memory.storage(), .{ .identity = test_identity, .url = try std.fmt.allocPrint(arena, "{s}/other", .{origin}), .storage_identity = id, .allow_http = true });
    try testing.expectEqual(@as(usize, 0), other.deleted);
    try testing.expectEqual(LogoutReport.Discovery.failed, other.discovery);
    try testing.expectEqual(@as(usize, 1), memory.count());

    const report = try logout(io, gpa, memory.storage(), .{ .identity = test_identity, .url = url, .storage_identity = id, .allow_http = true });
    try testing.expectEqual(@as(usize, 1), report.deleted);
    try testing.expectEqual(LogoutReport.Discovery.found, report.discovery);
    try testing.expectEqual(@as(usize, 0), memory.count());

    // A discovery that fails deletes nothing. Here the URL uses http without `allow_http`.
    const none = try logout(io, gpa, memory.storage(), .{ .identity = test_identity, .url = url, .storage_identity = id });
    try testing.expectEqual(@as(usize, 0), none.deleted);
    try testing.expectEqual(LogoutReport.Discovery.failed, none.discovery);
}

test "the authorizer records the error of a challenge, and a stored token needs no interactive sign-in" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory: auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const port = try testFreePort(io);
    var out: TestOutput = .{};
    defer out.deinit();
    var browser: TestBrowser = .{ .mode = .follow };
    defer browser.deinit();

    // An authorization server without dynamic client registration.
    {
        var server: FakeServer = undefined;
        try server.startWith(io, true);
        defer server.stop();
        const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/mcp", .{server.port});
        var authorizer: Authorizer = undefined;
        try authorizer.init(io, gpa, .{ .identity = test_identity, .server_url = url, .redirect_port = port, .storage = memory.storage(), .opener = browser.opener(), .output = out.output(), .limits = test_limits, .allow_http = true });
        defer authorizer.deinit();
        try testing.expect(authorizer.interactive());
        const before = authorizer.problemGeneration();
        try testing.expectError(error.RegistrationUnavailable, authorizer.provider().handleChallenge(arena, url, 401, null, 1));
        const problem = authorizer.problemSince(before).?;
        try testing.expectEqual(error.RegistrationUnavailable, problem.err);
        try testing.expectEqual(@as(u16, 401), problem.status);
        try testing.expect(problem.sign_in == null);
        try testing.expect(authorizer.problemSince(problem.generation) == null);
        try testing.expectEqual(@as(u32, 0), browser.calls.load(.acquire));
    }

    var server: FakeServer = undefined;
    try server.start(io);
    defer server.stop();
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/mcp", .{server.port});
    const options: Authorizer.Options = .{ .identity = test_identity, .server_url = url, .redirect_port = port, .storage = memory.storage(), .opener = browser.opener(), .output = out.output(), .limits = test_limits, .allow_http = true };
    {
        var authorizer: Authorizer = undefined;
        try authorizer.init(io, gpa, options);
        defer authorizer.deinit();
        const Counter = struct {
            calls: std.atomic.Value(u32) = .init(0),
            fn call(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                _ = self.calls.fetchAdd(1, .acq_rel);
            }
        };
        var counter: Counter = .{};
        authorizer.setAnswerHook(.{ .context = &counter, .call = Counter.call });
        try testing.expect(authorizer.interactive());
        try authorizer.provider().handleChallenge(arena, url, 401, null, 1);
        try testing.expectEqualStrings("fake-access-token", authorizer.provider().token(arena).?);
        try testing.expectEqual(@as(u32, 1), browser.calls.load(.acquire));
        // Before notifications/initialized, the browser gets the start URL.
        _ = try testExpectStartUrl(browser.url.items, port);
        try testing.expectEqual(@as(u16, 200), browser.status);
        try testing.expect(!authorizer.interactive());
        // The answered challenge counts, and the hook ran one time.
        try testing.expectEqual(@as(u64, 1), authorizer.answered.load(.acquire));
        try testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));

        // After notifications/initialized, a step-up asks the client. The user declines, and
        // the problem has the reason.
        var client: TestConsent = .{ .mode = .decline };
        defer client.deinit();
        authorizer.useConsent(client.consent());
        const before = authorizer.problemGeneration();
        try testing.expectError(error.AuthorizationFailed, authorizer.provider().handleChallenge(arena, url, 403, "Bearer error=\"insufficient_scope\", scope=\"more\"", 1));
        const problem = authorizer.problemSince(before).?;
        try testing.expectEqual(Reason.declined, problem.sign_in.?.reason);
        try testing.expectEqual(@as(u32, 1), client.asks.load(.acquire));
        try testing.expectEqual(@as(u32, 1), browser.calls.load(.acquire));
        // A challenge that the provider did not answer does not count.
        try testing.expectEqual(@as(u64, 1), authorizer.answered.load(.acquire));
        try testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
        // In the cooldown, a challenge with other scopes gets no question either. The upstream
        // server chooses the scopes, thus new scopes cannot end the cooldown.
        for ([_][]const u8{ "other", "x1", "more" }) |scope| {
            const header = try std.fmt.allocPrint(arena, "Bearer error=\"insufficient_scope\", scope=\"{s}\"", .{scope});
            const generation = authorizer.problemGeneration();
            try testing.expectError(error.AuthorizationFailed, authorizer.provider().handleChallenge(arena, url, 403, header, 1));
            try testing.expectEqual(Reason.cooldown, authorizer.problemSince(generation).?.sign_in.?.reason);
        }
        try testing.expectEqual(@as(u32, 1), client.asks.load(.acquire));
        authorizer.setAnswerHook(null);
    }

    // A new process with the same storage has a usable token.
    {
        var authorizer: Authorizer = undefined;
        try authorizer.init(io, gpa, options);
        defer authorizer.deinit();
        try testing.expect(!authorizer.interactive());
    }
    // Another account has its own record.
    {
        var work = options;
        work.account = "work";
        var authorizer: Authorizer = undefined;
        try authorizer.init(io, gpa, work);
        defer authorizer.deinit();
        try testing.expect(authorizer.interactive());
    }
}

test "a record needs a fresh access token to skip the long time limit of a sign-in" {
    const io = testing.io;
    const gpa = testing.allocator;
    var memory: auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    const url = "https://mcp.example/mcp";
    const now = Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    const Case = struct { record: auth.token_storage.Record, interactive: bool };
    const registration: auth.token_storage.Record.Registration = .{ .client_id = "c1", .auth_method = .none };
    const other_client: auth.token_storage.Record.Registration = .{ .client_id = "c2", .auth_method = .none };
    for ([_]bool{ false, true }) |pre_registered| {
        const cases = [_]Case{
            .{ .record = .{ .registration = registration, .access_token = "a", .expires_at = now + 3600 }, .interactive = false },
            .{ .record = .{ .registration = registration, .access_token = "a" }, .interactive = false },
            // A refresh token alone: the authorization server can refuse it, and then the
            // request signs in through the browser.
            .{ .record = .{ .registration = registration, .refresh_token = "r" }, .interactive = true },
            .{ .record = .{ .registration = registration, .access_token = "a", .expires_at = now + 30, .refresh_token = "r" }, .interactive = true },
            .{ .record = .{ .registration = registration, .access_token = "a", .expires_at = now - 10 }, .interactive = true },
            // Another client ID: a pre-registered client cannot use the record.
            .{ .record = .{ .registration = other_client, .access_token = "a", .expires_at = now + 3600 }, .interactive = pre_registered },
            .{ .record = .{ .access_token = "a", .expires_at = now + 3600 }, .interactive = pre_registered },
        };
        for (cases) |case| {
            var authorizer: Authorizer = undefined;
            try authorizer.init(io, gpa, .{
                .identity = test_identity,
                .server_url = url,
                .storage = memory.storage(),
                .registration = if (pre_registered) .{ .pre_registered = .{ .client_id = "c1", .issuer = "https://as.example" } } else .dynamic,
            });
            defer authorizer.deinit();
            try testing.expect(authorizer.interactive());
            const key: auth.token_storage.Key = .{ .issuer = "https://as.example", .resource = url, .client = authorizer.storage_identity };
            try authorizer.indexed.storage().save(gpa, key, case.record);
            defer authorizer.indexed.storage().delete(key) catch {};
            errdefer std.debug.print("the record: {f}, pre-registered: {}\n", .{ std.json.fmt(case.record, .{}), pre_registered });
            try testing.expectEqual(case.interactive, authorizer.interactive());
        }
    }
}

test "an authorizer in the sandbox fails each sign-in at once, and abort stops each later sign-in" {
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    const io = testing.io;
    const gpa = testing.allocator;
    var memory: auth.MemoryTokenStorage = .init(io, gpa);
    defer memory.deinit();
    var broken: TestBrowser = .{ .mode = .fail };
    defer broken.deinit();
    var out: TestOutput = .{};
    defer out.deinit();
    var authorizer: Authorizer = undefined;
    try authorizer.init(io, gpa, .{ .identity = test_identity, .server_url = "https://mcp.example/mcp", .storage = memory.storage(), .opener = broken.opener(), .output = out.output(), .sandboxed = true });
    defer authorizer.deinit();
    try testing.expect(authorizer.sandboxed);
    try testing.expect(authorizer.sign_in.options.opener_failure_fatal);
    try testing.expectEqualStrings("http://127.0.0.1:41894/callback", authorizer.redirectUri());
    try testing.expectEqualStrings("mcp-bridge-test|default|http://127.0.0.1:41894/callback", authorizer.storage_identity);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // In the sandbox, the sign-in fails before the line, the receiver and the browser.
    try testing.expectError(error.SignInFailed, authorizer.sign_in.run(arena, try testAuthorizationUrl(arena, default_redirect_port, "s0")));
    try testing.expectEqual(Reason.sandbox, authorizer.sign_in.lastFailure().?.reason);
    try testing.expectEqual(@as(usize, 0), out.count);
    try testing.expectEqual(@as(u32, 0), broken.calls.load(.acquire));
    authorizer.abort();
    try testing.expectError(error.SignInFailed, authorizer.sign_in.run(arena, try testAuthorizationUrl(arena, default_redirect_port, "s")));
    try testing.expectEqual(Reason.closed, authorizer.sign_in.lastFailure().?.reason);
}

test "the token directory of logout --all" {
    const io = testing.io;
    var dir: TestDir = try .init();
    defer dir.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tokens = try dir.join(arena, "tokens");
    try testing.expect(!try deleteTokenDir(io, tokens));
    try Io.Dir.cwd().createDirPath(io, tokens);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ tokens, "x.token" }), .data = "x" });
    try testing.expect(try deleteTokenDir(io, tokens));
    try testing.expect(!try deleteTokenDir(io, tokens));
}
