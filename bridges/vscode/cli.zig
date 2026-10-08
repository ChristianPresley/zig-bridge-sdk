//! The command line of `mcp-bridge-vscode`. It has three forms:
//!
//! ```
//! mcp-bridge-vscode [options] -- <command> [args...]
//! mcp-bridge-vscode [options] <url>
//! mcp-bridge-vscode logout [options] <url>
//! mcp-bridge-vscode logout [options] --all
//! ```
//!
//! The first form starts the upstream command and speaks to it over stdio. The second form
//! speaks to the upstream server at the URL over Streamable HTTP. The URL uses https, or http
//! with a loopback host. The third form deletes the stored sign-in of the server at the URL,
//! or of each server with `--all`.
//!
//! The options come first. An option takes its value from the next argument (`--name x`) or
//! after an equals sign (`--name=x`). When an option occurs two times, the last value applies.
//! Each `--header` and each `--header-env` adds one header. The parser examines no argument
//! after `--`, thus the options of the upstream command go to the upstream command without a
//! change. The URL is the last argument.
//!
//! A secret never goes on the command line, because VS Code writes the command line to its
//! log, and the process list shows it. A header value with a secret comes from an environment
//! variable (`--header-env`). The client secret comes from `MCP_BRIDGE_CLIENT_SECRET`, and the
//! key of the file store from `MCP_BRIDGE_TOKEN_KEY` or from a file. A diagnostic never has a
//! value from the command line or from the environment.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const bridge = @import("bridge");
const vscode = @import("vscode");
const mcp = bridge.mcp;
const http_syntax = mcp.util.http_syntax;

/// The default of `--discover-timeout`, in seconds.
pub const default_discover_timeout_s: u32 = bridge.Frontend.default_discover_timeout_s;
/// The default of `--max-line-bytes`: 64 MiB. VS Code reads lines of all lengths.
pub const default_max_line_bytes: usize = bridge.Upstream.default_max_line_bytes;
/// The largest value of `--max-line-bytes`: 1 GiB. The line reader of zig-sdk adds one to the
/// limit, thus the limit cannot be the maximum of `usize`.
pub const max_line_bytes_limit: usize = 1 << 30;
/// The default of `--max-response-bytes`: 64 MiB, the same as `--max-line-bytes`.
pub const default_max_response_bytes: usize = bridge.Upstream.default_max_response_bytes;
/// The largest value of `--max-response-bytes`: 1 GiB.
pub const max_response_bytes_limit: usize = 1 << 30;
/// The default of `--sign-in-timeout`, in seconds.
pub const default_sign_in_timeout_s: u32 = bridge.oauth.default_sign_in_timeout_s;
/// The default of `--redirect-port`. zig-sdk uses the port 41893, and VS Code uses the port
/// 33418. Thus their listeners and the listener of the bridge do not collide.
pub const default_redirect_port: u16 = bridge.oauth.default_redirect_port;
/// The default client ID metadata document of the bridge. Its `redirect_uris` has only the
/// redirect URI of `default_redirect_port`.
pub const default_client_metadata_url = vscode.client_metadata_url;
/// The default of `--account`.
pub const default_account = bridge.oauth.default_account;
/// The maximum length of the label of `--account`.
pub const max_account_bytes = bridge.oauth.max_account_len;
/// The environment variable with the client secret of `--client-id`.
pub const client_secret_variable = bridge.oauth.client_secret_variable;
/// The environment variable with the key of the file store: 64 hexadecimal digits.
pub const token_key_variable = bridge.oauth.token_key_variable;

/// The header names that `--header` and `--header-env` refuse, in lowercase. zig-sdk sends
/// them, or they change the HTTP connection. A user header comes after the headers of
/// zig-sdk, thus a second copy would make the request ambiguous. The options also refuse
/// each name that starts with `refused_header_prefix`, and `proxy_authorization_header`.
pub const refused_header_names = [_][]const u8{
    "host",             "connection", "content-length", "transfer-encoding", "accept",  "content-type",
    "accept-encoding",  "dpop",       "te",             "trailer",           "upgrade", "keep-alive",
    "proxy-connection", "expect",
};

/// The credential of a proxy. A user header goes to the upstream server, also through the
/// tunnel of a proxy, and never to the proxy. Thus the options refuse this header: the proxy
/// URL of `HTTPS_PROXY` gives the user and the password to the proxy.
pub const proxy_authorization_header = "proxy-authorization";
/// The prefix of the header names of the protocol, for example `mcp-protocol-version`.
pub const refused_header_prefix = "mcp-";

/// The header names whose value is usually a secret, in lowercase. With `--header`, the value
/// is on the command line, and the executable writes a warning.
pub const secret_header_names = [_][]const u8{ "authorization", "cookie", "x-api-key", "api-key" };

/// The text of `--help`. The usage also goes to stderr after an error in the arguments.
pub const usage = std.fmt.comptimePrint(
    \\Usage: mcp-bridge-vscode [options] -- <command> [args...]
    \\       mcp-bridge-vscode [options] <url>
    \\       mcp-bridge-vscode logout [--account <label>] <url>
    \\       mcp-bridge-vscode logout --all
    \\
    \\Connects VS Code (MCP revision 2025-11-25) to an MCP server of revision 2026-07-28.
    \\The bridge starts <command> as the upstream server, or it connects to the upstream
    \\server at <url> over Streamable HTTP. The URL uses https, or http with a loopback
    \\host such as 127.0.0.1. "logout" deletes the stored sign-in of the server at <url>,
    \\or of each server with --all.
    \\
    \\Options:
    \\  --name <name>                The server name for VS Code when the upstream server
    \\                               sends no name. The default is the file name of
    \\                               <command> without its extension, or the host of <url>.
    \\  --log-level <level>          The level of the log lines on stderr: err, warn, info
    \\                               or debug. The default is info.
    \\  --discover-timeout <s>       The time in seconds for the first response of the
    \\                               upstream server. The default is {d}.
    \\  --max-line-bytes <n>         The maximum length of one message in bytes, from 1 to
    \\                               {d}. The default is {d} (64 MiB).
    \\  --help                       Show this text.
    \\  --version                    Show the version.
    \\
    \\Options for <url>:
    \\  --header-env <name>=<var>    Send the header <name> with the value of the
    \\                               environment variable <var> of the bridge. Use it for
    \\                               a secret, for example a static authorization header.
    \\  --header <name>:<value>      Send the header <name> with <value>. VS Code writes
    \\                               the command line to its log, and the process list
    \\                               shows it. Do not use it for a secret.
    \\  --max-response-bytes <n>     The maximum length of one message from the upstream
    \\                               server in bytes, from 1 to {d}. The default
    \\                               is {d} (64 MiB).
    \\  --ca-file <path>             Also trust the CA certificates of this PEM file. The
    \\                               bridge always trusts the CA certificates of the system.
    \\  The proxy comes from the environment variables HTTPS_PROXY, ALL_PROXY and NO_PROXY.
    \\  Put the user and the password of the proxy into its URL.
    \\
    \\Sign-in options for <url> (OAuth):
    \\  --client-id <id>             Use this client ID, which the authorization server
    \\                               issued. The client secret comes from the environment
    \\                               variable {s}.
    \\  --client-issuer <url>        The issuer of --client-id. A client with a secret in
    \\                               {s} needs it.
    \\  --client-metadata-url <url>  Use the client ID metadata document at this URL. The
    \\                               default is the document of the bridge:
    \\                               {s}
    \\  --redirect-port <port>       The port of the redirect URI
    \\                               http://127.0.0.1:<port>/callback. The default is {d}.
    \\                               With a different port and no registration option,
    \\                               the bridge uses dynamic client registration.
    \\  --account <label>            The account of the stored sign-in. The default is
    \\                               "{s}".
    \\  --token-store <store>        Where the bridge keeps the tokens: auto, keychain, file
    \\                               or memory. The default is auto. The file store needs a
    \\                               key of 64 hexadecimal digits in the environment variable
    \\                               {s}, or a file with the key.
    \\  --token-key-file <path>      The file with the key of the file store.
    \\  --no-browser                 Do not open a browser. Write the sign-in URL to stderr.
    \\  --sign-in-timeout <s>        The time in seconds for the sign-in in the browser.
    \\                               The default is {d}.
    \\  A static authorization header and the sign-in options exclude each other.
    \\
    \\Options for logout:
    \\  --account, --all, --redirect-port, --token-store, --token-key-file, --ca-file and
    \\  --log-level.
    \\
, .{
    default_discover_timeout_s, max_line_bytes_limit,        default_max_line_bytes,
    max_response_bytes_limit,   default_max_response_bytes,  client_secret_variable,
    client_secret_variable,     default_client_metadata_url, default_redirect_port,
    default_account,            token_key_variable,          default_sign_in_timeout_s,
});

/// What the executable does with the arguments.
pub const Action = enum {
    /// Serve VS Code with the upstream command or the upstream URL.
    serve,
    /// Delete the stored sign-in of `Options.url`, or of each server with `Options.logout_all`.
    logout,
    /// Show the usage on stdout.
    help,
    /// Show the version on stdout.
    version,
};

/// Where the bridge keeps the tokens of the sign-in: `auto` (the keychain of the system, else
/// the file store with a key, else the memory), `keychain`, `file` (it needs a key) or
/// `memory` (the user signs in at each start). `bridge.oauth.TokenStore` has the policy.
pub const TokenStore = bridge.oauth.TokenStore.Choice;

/// How the bridge gets a client ID from the authorization server.
pub const Registration = union(enum) {
    /// `--client-id`: a client that the authorization server issued.
    pre_registered: PreRegistered,
    /// `--client-metadata-url`, or the default document of the bridge. The authorization
    /// server uses the document when it supports client ID metadata documents. Else the
    /// bridge uses dynamic client registration.
    client_metadata_url: ClientMetadataUrl,
    /// Dynamic client registration only. This applies to a `--redirect-port` that is not the
    /// default, because the default document has only the default redirect URI.
    dynamic,

    pub const PreRegistered = struct {
        client_id: []const u8,
        /// The issuer of `client_id`, from `--client-issuer`. Null binds the client to the
        /// first authorization server that the upstream server names. A client with a secret
        /// always has an issuer.
        issuer: ?[]const u8 = null,
        /// The value of `MCP_BRIDGE_CLIENT_SECRET`, or null for a public client.
        client_secret: ?[]const u8 = null,
    };

    pub const ClientMetadataUrl = struct {
        url: []const u8,
        /// True for `--client-metadata-url`, false for the default document.
        explicit: bool,
    };
};

/// The settings of the HTTP client for the URL form. `logout` uses `ca_file`.
pub const Http = struct {
    /// The headers of `--header` and `--header-env`, in the order of the command line. A
    /// value of `--header-env` points into the environment.
    headers: []const std.http.Header = &.{},
    /// True when `headers` has an `authorization` header. Then the bridge does no sign-in.
    static_authorization: bool = false,
    /// The name of the first header of `--header` (not `--header-env`) in
    /// `secret_header_names`, or null. Its value is on the command line.
    secret_on_command_line: ?[]const u8 = null,
    /// The names of the environment variables of `--header-env`. The browser of the sign-in
    /// does not get them.
    header_variables: []const []const u8 = &.{},
    /// The PEM file of `--ca-file`, or null.
    ca_file: ?[]const u8 = null,
    max_response_bytes: usize = default_max_response_bytes,
};

/// The settings of the sign-in (OAuth) for the URL form and for `logout`.
pub const OAuth = struct {
    registration: Registration = .{ .client_metadata_url = .{ .url = default_client_metadata_url, .explicit = false } },
    redirect_port: u16 = default_redirect_port,
    account: []const u8 = default_account,
    token_store: TokenStore = .auto,
    /// The key of `MCP_BRIDGE_TOKEN_KEY` for the file store, or null.
    token_key: ?[32]u8 = null,
    /// The file of `--token-key-file`, or null. The store reads it and refuses a file that
    /// other users can read.
    token_key_file: ?[]const u8 = null,
    /// `--no-browser`: write the sign-in URL to stderr, and open no browser.
    no_browser: bool = false,
    sign_in_timeout: Io.Duration = .fromSeconds(default_sign_in_timeout_s),

    /// The maximum length of `redirectUri`.
    pub const max_redirect_uri_bytes = bridge.oauth.max_redirect_uri_len;

    /// The redirect URI `http://127.0.0.1:<port>/callback` in `buf`.
    pub fn redirectUri(self: OAuth, buf: *[max_redirect_uri_bytes]u8) []const u8 {
        return bridge.oauth.writeRedirectUri(buf, self.redirect_port);
    }
};

/// The result of `parse`. For `.help` and `.version`, the other fields have their defaults.
pub const Options = struct {
    action: Action = .serve,
    /// The `serverInfo.name` when the upstream server sends no `serverInfo`. It is never
    /// empty for `.serve`. The default is the file name of the upstream command without its
    /// extension, or the host of the URL.
    name: []const u8 = "",
    /// The level of the log lines at run time.
    log_level: std.log.Level = bridge.log.default_level,
    /// The time limit of `server/discover`.
    discover_timeout: Io.Duration = .fromSeconds(default_discover_timeout_s),
    /// The maximum length of one line of JSON-RPC from VS Code, and of one line from a stdio
    /// upstream server.
    max_line_bytes: usize = default_max_line_bytes,
    /// The upstream command and its arguments, for the form with `--`. Else empty. For this
    /// form, the list has at least one item, and the first item is not empty.
    command: []const []const u8 = &.{},
    /// The URL of the upstream server, for the URL form and for `logout`. Else empty.
    url: []const u8 = "",
    /// The settings of the HTTP client.
    http: Http = .{},
    /// The settings of the sign-in for the URL form and for `logout`. Null for the form with
    /// `--`, and with a static authorization header.
    oauth: ?OAuth = null,
    /// `logout --all`.
    logout_all: bool = false,
};

/// The errors of `parse`. The executable exits with code 2 for each of them.
pub const Error = error{
    /// There is no `--` and no URL, or no command after `--`, or the command is an empty
    /// string.
    MissingCommand,
    /// `logout` has no URL and no `--all`.
    MissingUrl,
    /// An argument before `--` is not an option, or an argument comes after the URL.
    UnexpectedArgument,
    /// The parser does not know the option.
    UnknownOption,
    /// The option has no value.
    MissingValue,
    /// The value of the option is not valid, or the option takes no value.
    InvalidValue,
    /// The URL of the upstream server is not valid.
    InvalidUrl,
    /// The option does not apply to this form, or two options exclude each other.
    Conflict,
    /// The header name of `--header` or `--header-env` is a name that the bridge refuses.
    RefusedHeader,
    /// Two headers have the same name.
    DuplicateHeader,
    /// The environment variable of an option is not set, or it is empty.
    MissingVariable,
    /// The value of an environment variable is not valid.
    InvalidVariable,
    /// `--token-store file` has no key.
    MissingTokenKey,
    OutOfMemory,
};

/// The data of a parse error. It holds names from the command line. It never holds a value
/// from the command line or from the environment, because a value can hold a secret.
pub const Diagnostic = struct {
    /// The option with the error, without its value. Empty when the error has no option.
    option: []const u8 = "",
    /// What a valid value is. Empty when the error has no value.
    hint: []const u8 = "",
    /// The header name or the name of the environment variable of the error. Empty when the
    /// error has no such name.
    name: []const u8 = "",

    /// Writes one line of text about `err` to `w`, without a newline.
    pub fn write(d: Diagnostic, err: Error, w: *Io.Writer) Io.Writer.Error!void {
        switch (err) {
            error.MissingCommand => try w.writeAll("the upstream server is missing: give its URL, or put the upstream command after \"--\""),
            error.MissingUrl => try w.writeAll("the URL of the upstream server is missing: give it after the options of logout, or give --all"),
            error.UnexpectedArgument => try w.print("an argument is not an option: {s}", .{d.hint}),
            error.UnknownOption => try w.print("the option {s} is not known", .{d.option}),
            error.MissingValue => try w.print("the option {s} needs a value", .{d.option}),
            error.InvalidValue => if (d.name.len != 0)
                try w.print("the header {s} of {s} is not valid: {s}", .{ d.name, d.option, d.hint })
            else
                try w.print("the value of {s} is not valid: {s}", .{ d.option, d.hint }),
            error.InvalidUrl => try w.print("the URL of the upstream server is not valid: {s}", .{d.hint}),
            error.Conflict => try w.print("the option {s} cannot be used here: {s}", .{ d.option, d.hint }),
            error.RefusedHeader => try w.print("the header {s} of {s} is not permitted: {s}", .{ d.name, d.option, d.hint }),
            error.DuplicateHeader => try w.print("the header {s} occurs more than one time in --header and --header-env", .{d.name}),
            error.MissingVariable => try w.print("the environment variable {s} of {s} is not set, or it is empty", .{ d.name, d.option }),
            error.InvalidVariable => try w.print("the environment variable {s} is not valid: {s}", .{ d.name, d.hint }),
            error.MissingTokenKey => try w.print("--token-store file needs a key: set the environment variable {s}, or give --token-key-file", .{token_key_variable}),
            error.OutOfMemory => try w.writeAll("not enough memory"),
        }
    }
};

const Option = enum {
    name,
    @"log-level",
    @"discover-timeout",
    @"max-line-bytes",
    help,
    version,
    header,
    @"header-env",
    @"max-response-bytes",
    @"ca-file",
    @"client-id",
    @"client-issuer",
    @"client-metadata-url",
    @"redirect-port",
    account,
    @"token-store",
    @"token-key-file",
    @"no-browser",
    @"sign-in-timeout",
    all,

    /// True for an option without a value.
    fn isFlag(o: Option) bool {
        return switch (o) {
            .help, .version, .@"no-browser", .all => true,
            else => false,
        };
    }

    /// True for an option of the sign-in. A static authorization header excludes it.
    fn isSignIn(o: Option) bool {
        return switch (o) {
            .@"client-id",
            .@"client-issuer",
            .@"client-metadata-url",
            .@"redirect-port",
            .account,
            .@"token-store",
            .@"token-key-file",
            .@"no-browser",
            .@"sign-in-timeout",
            => true,
            else => false,
        };
    }

    /// True when the form `form` takes the option.
    fn appliesTo(o: Option, form: Form) bool {
        return switch (o) {
            .help, .version, .@"log-level" => true,
            .name, .@"discover-timeout", .@"max-line-bytes" => form != .logout,
            .header, .@"header-env", .@"max-response-bytes", .@"client-id", .@"client-issuer", .@"client-metadata-url", .@"no-browser", .@"sign-in-timeout" => form == .url,
            .@"ca-file", .@"redirect-port", .account, .@"token-store", .@"token-key-file" => form != .command,
            .all => form == .logout,
        };
    }

    /// The option as the command line writes it, for example `--redirect-port`.
    fn text(comptime o: Option) []const u8 {
        return "--" ++ @tagName(o);
    }
};

/// The three forms of the command line.
const Form = enum {
    /// The form `[options] -- <command> [args...]`.
    command,
    /// The form `[options] <url>`.
    url,
    /// The forms `logout [options] <url>` and `logout [options] --all`.
    logout,

    /// Why the form does not take an option, for `Diagnostic.hint`.
    fn refusal(form: Form) []const u8 {
        return switch (form) {
            .command => "it applies only to the URL of an upstream server, not to an upstream command",
            .url => "only logout takes it",
            .logout => "logout does not take it",
        };
    }
};

/// One `--header` or `--header-env` of the command line.
const HeaderArg = struct {
    /// The option: `--header` or `--header-env`.
    option: []const u8,
    /// The header name, a valid HTTP token.
    name: []const u8,
    /// The value of `--header`, or the name of the variable of `--header-env`.
    source: []const u8,
    from_environment: bool,
};

/// The values of the command line before the checks of the form.
const Raw = struct {
    name: ?[]const u8 = null,
    headers: std.ArrayList(HeaderArg) = .empty,
    max_response_bytes: ?usize = null,
    ca_file: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    client_issuer: ?[]const u8 = null,
    client_metadata_url: ?[]const u8 = null,
    redirect_port: ?u16 = null,
    account: ?[]const u8 = null,
    token_store: ?TokenStore = null,
    token_key_file: ?[]const u8 = null,
    no_browser: bool = false,
    sign_in_timeout: ?u32 = null,
    all: bool = false,
    /// The options of the command line in their order, each one time.
    given: std.EnumSet(Option) = .initEmpty(),
    order: std.ArrayList(Option) = .empty,
};

/// The hint of `UnexpectedArgument` for an argument that is not an option and not a URL.
const hint_forms = "give the URL of the upstream server, or put the upstream command after \"--\"";

/// Parses the arguments of the executable. `args` does not contain the name of the program.
/// `env` is the environment of the process, for `--header-env`, `MCP_BRIDGE_CLIENT_SECRET` and
/// `MCP_BRIDGE_TOKEN_KEY`. Null is an empty environment. The slices of the result point into
/// `args` and `env`. `arena` holds the lists of the result.
pub fn parse(arena: Allocator, args: []const []const u8, env: ?*const Environ.Map) Error!Options {
    var diag: Diagnostic = .{};
    return parseDiagnostic(arena, args, env, &diag);
}

/// Same as `parse`. On an error, `diag` tells the option and a valid value.
pub fn parseDiagnostic(arena: Allocator, args: []const []const u8, env: ?*const Environ.Map, diag: *Diagnostic) Error!Options {
    diag.* = .{};
    var options: Options = .{};
    var raw: Raw = .{};
    var list = args;
    if (list.len > 0 and std.mem.eql(u8, list[0], "logout")) {
        options.action = .logout;
        list = list[1..];
    }
    var command: ?[]const []const u8 = null;
    var url: ?[]const u8 = null;
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        const arg = list[i];
        if (std.mem.eql(u8, arg, "--")) {
            command = list[i + 1 ..];
            break;
        }
        if (arg.len < 2 or arg[0] != '-') {
            // A URL has a scheme. The parser never shows the argument, because it can be a
            // secret at a wrong place.
            diag.option = "";
            if (std.mem.indexOf(u8, arg, "://") == null) {
                diag.hint = hint_forms;
                return error.UnexpectedArgument;
            }
            if (i + 1 != list.len) {
                diag.hint = "put the options before the URL of the upstream server";
                return error.UnexpectedArgument;
            }
            url = arg;
            break;
        }

        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const key = if (eq) |e| arg[0..e] else arg;
        const inline_value: ?[]const u8 = if (eq) |e| arg[e + 1 ..] else null;
        diag.option = key;
        const known: ?Option = if (std.mem.startsWith(u8, key, "--")) std.meta.stringToEnum(Option, key[2..]) else null;
        const option = known orelse return error.UnknownOption;
        if (!raw.given.contains(option)) {
            raw.given.insert(option);
            try raw.order.append(arena, option);
        }

        if (option.isFlag()) {
            if (inline_value != null) {
                diag.hint = "the option takes no value";
                return error.InvalidValue;
            }
            switch (option) {
                .help => return .{ .action = .help },
                .version => return .{ .action = .version },
                .@"no-browser" => raw.no_browser = true,
                .all => raw.all = true,
                else => unreachable,
            }
            continue;
        }

        const value = inline_value orelse value: {
            // A separate value cannot start with "--". Thus `--name -- cmd` is an error and
            // not the name "--".
            if (i + 1 >= list.len or std.mem.startsWith(u8, list[i + 1], "--")) return error.MissingValue;
            i += 1;
            break :value list[i];
        };
        try parseValue(arena, &raw, &options, option, key, value, diag);
    }

    diag.* = .{};
    const form: Form = if (options.action == .logout) .logout else if (url != null) .url else .command;
    switch (form) {
        .command => {
            const c = command orelse return error.MissingCommand;
            if (c.len == 0 or c[0].len == 0) return error.MissingCommand;
        },
        .url => {},
        .logout => {
            if (command != null) {
                diag.hint = "logout takes no upstream command";
                return error.UnexpectedArgument;
            }
            if (raw.all and url != null) {
                diag.option = Option.all.text();
                diag.hint = "give the URL of one server, or --all";
                return error.Conflict;
            }
            if (!raw.all and url == null) return error.MissingUrl;
        },
    }
    for (raw.order.items) |o| if (!o.appliesTo(form)) {
        diag.option = switch (o) {
            inline else => |c| c.text(),
        };
        diag.hint = form.refusal();
        return error.Conflict;
    };
    if (url) |u| if (upstreamUrlHint(u)) |hint| {
        diag.hint = hint;
        return error.InvalidUrl;
    };

    switch (form) {
        .command => {
            options.command = try arena.dupe([]const u8, command.?);
            options.name = raw.name orelse vscode.defaultName(options.command[0]);
        },
        .url => {
            options.url = url.?;
            options.name = raw.name orelse vscode.defaultUrlName(options.url);
            options.http = try httpOptions(arena, &raw, env, diag);
            if (options.http.static_authorization) {
                for (raw.order.items) |o| if (o.isSignIn()) {
                    diag.option = switch (o) {
                        inline else => |c| c.text(),
                    };
                    diag.hint = "a static authorization header and the sign-in options exclude each other";
                    return error.Conflict;
                };
            } else {
                options.oauth = try oauthOptions(&raw, env, diag);
            }
        },
        .logout => {
            options.url = url orelse "";
            options.logout_all = raw.all;
            if (raw.all and raw.account != null) {
                diag.option = Option.account.text();
                diag.hint = "logout --all deletes the sign-in of each account";
                return error.Conflict;
            }
            options.http.ca_file = raw.ca_file;
            options.oauth = try oauthOptions(&raw, env, diag);
        },
    }
    diag.* = .{};
    return options;
}

/// Check the value of one option and keep it in `raw` or `options`.
fn parseValue(arena: Allocator, raw: *Raw, options: *Options, option: Option, key: []const u8, value: []const u8, diag: *Diagnostic) Error!void {
    switch (option) {
        .help, .version, .@"no-browser", .all => unreachable,
        .name => {
            if (value.len == 0) return invalid(diag, "the name cannot be empty");
            raw.name = value;
        },
        .@"log-level" => options.log_level = bridge.log.parseLevel(value) orelse return invalid(diag, "use err, warn, info or debug"),
        .@"discover-timeout" => {
            const seconds = parseNumber(u32, value, 1, std.math.maxInt(u32)) orelse
                return invalid(diag, std.fmt.comptimePrint("use a number of seconds from 1 to {d}", .{std.math.maxInt(u32)}));
            options.discover_timeout = .fromSeconds(seconds);
        },
        .@"max-line-bytes" => options.max_line_bytes = parseNumber(usize, value, 1, max_line_bytes_limit) orelse
            return invalid(diag, std.fmt.comptimePrint("use a number of bytes from 1 to {d}", .{max_line_bytes_limit})),
        .@"max-response-bytes" => raw.max_response_bytes = parseNumber(usize, value, 1, max_response_bytes_limit) orelse
            return invalid(diag, std.fmt.comptimePrint("use a number of bytes from 1 to {d}", .{max_response_bytes_limit})),
        .@"sign-in-timeout" => raw.sign_in_timeout = parseNumber(u32, value, 1, std.math.maxInt(u32)) orelse
            return invalid(diag, std.fmt.comptimePrint("use a number of seconds from 1 to {d}", .{std.math.maxInt(u32)})),
        .@"redirect-port" => raw.redirect_port = parseNumber(u16, value, 1, std.math.maxInt(u16)) orelse
            return invalid(diag, "use a port from 1 to 65535"),
        .header, .@"header-env" => try raw.headers.append(arena, try parseHeader(raw.headers.items, option, key, value, diag)),
        .@"ca-file" => {
            if (value.len == 0) return invalid(diag, "the path cannot be empty");
            raw.ca_file = value;
        },
        .@"token-key-file" => {
            if (value.len == 0) return invalid(diag, "the path cannot be empty");
            raw.token_key_file = value;
        },
        .@"client-id" => {
            if (value.len == 0) return invalid(diag, "the client ID cannot be empty");
            for (value) |c| if (c < ' ' or c > '~') return invalid(diag, "a client ID has only visible ASCII characters and spaces");
            raw.client_id = value;
        },
        .@"client-issuer" => {
            if (issuerHint(value)) |hint| return invalid(diag, hint);
            raw.client_issuer = value;
        },
        .@"client-metadata-url" => {
            if (!http_syntax.isVisibleAscii(value) or !mcp.auth.common.validClientIdUrl(value))
                return invalid(diag, "use an https URL with a path, without a user, a password and a fragment");
            raw.client_metadata_url = value;
        },
        .account => {
            if (!validAccount(value)) return invalid(diag, std.fmt.comptimePrint("use 1 to {d} letters, digits and the characters . _ @ + -", .{max_account_bytes}));
            raw.account = value;
        },
        .@"token-store" => raw.token_store = std.meta.stringToEnum(TokenStore, value) orelse
            return invalid(diag, "use auto, keychain, file or memory"),
    }
}

fn invalid(diag: *Diagnostic, hint: []const u8) Error {
    diag.hint = hint;
    return error.InvalidValue;
}

/// Parse `<name>:<value>` of `--header` or `<name>=<variable>` of `--header-env`. The name is
/// an HTTP token, `refused_header_names` does not have it, and no earlier header has it. A
/// value of `--header` is a field value without spaces at its ends. The diagnostic has the
/// name only when the name is a valid token.
fn parseHeader(earlier: []const HeaderArg, option: Option, key: []const u8, value: []const u8, diag: *Diagnostic) Error!HeaderArg {
    const from_environment = option == .@"header-env";
    const separator: u8 = if (from_environment) '=' else ':';
    const syntax = if (from_environment) "use <name>=<variable>, with an HTTP header name and the name of an environment variable" else "use <name>:<value>, with an HTTP header name";
    const at = std.mem.indexOfScalar(u8, value, separator) orelse return invalid(diag, syntax);
    const name = value[0..at];
    if (!http_syntax.isToken(name)) return invalid(diag, syntax);
    for (refused_header_names) |refused| if (std.ascii.eqlIgnoreCase(name, refused)) {
        diag.name = name;
        diag.hint = "the bridge or the HTTP connection sets this header";
        return error.RefusedHeader;
    };
    if (std.ascii.eqlIgnoreCase(name, proxy_authorization_header)) {
        diag.name = name;
        diag.hint = "the header goes to the upstream server and not to the proxy: put the user and the password in the proxy URL of HTTPS_PROXY";
        return error.RefusedHeader;
    }
    if (std.ascii.startsWithIgnoreCase(name, refused_header_prefix)) {
        diag.name = name;
        diag.hint = "the header names that start with mcp- are for the protocol";
        return error.RefusedHeader;
    }
    for (earlier) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) {
        diag.name = name;
        return error.DuplicateHeader;
    };
    const rest = value[at + 1 ..];
    if (from_environment) {
        if (!validVariableName(rest)) return invalid(diag, syntax);
        return .{ .option = key, .name = name, .source = rest, .from_environment = true };
    }
    const header_value = std.mem.trim(u8, rest, " \t");
    if (header_value.len == 0) {
        diag.name = name;
        return invalid(diag, "the header has no value");
    }
    if (!http_syntax.isFieldValue(header_value)) {
        diag.name = name;
        return invalid(diag, "the value has a control character");
    }
    return .{ .option = key, .name = name, .source = header_value, .from_environment = false };
}

/// The headers of the URL form, with the values of the environment.
fn httpOptions(arena: Allocator, raw: *const Raw, env: ?*const Environ.Map, diag: *Diagnostic) Error!Http {
    var out: Http = .{ .ca_file = raw.ca_file };
    if (raw.max_response_bytes) |n| out.max_response_bytes = n;
    const headers = try arena.alloc(std.http.Header, raw.headers.items.len);
    var variables: std.ArrayList([]const u8) = .empty;
    for (raw.headers.items, headers) |h, *header| {
        if (h.from_environment) try variables.append(arena, h.source);
        const value = if (h.from_environment) value: {
            diag.option = h.option;
            diag.name = h.source;
            const v = variable(env, h.source) orelse return error.MissingVariable;
            if (!http_syntax.isFieldValue(v)) {
                diag.hint = "the value is not a valid HTTP header value";
                return error.InvalidVariable;
            }
            break :value v;
        } else h.source;
        header.* = .{ .name = h.name, .value = value };
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) out.static_authorization = true;
        if (!h.from_environment and out.secret_on_command_line == null) {
            for (secret_header_names) |s| if (std.ascii.eqlIgnoreCase(h.name, s)) {
                out.secret_on_command_line = h.name;
            };
        }
    }
    diag.* = .{};
    out.headers = headers;
    out.header_variables = variables.items;
    return out;
}

/// The settings of the sign-in of the URL form and of `logout`.
fn oauthOptions(raw: *const Raw, env: ?*const Environ.Map, diag: *Diagnostic) Error!OAuth {
    var out: OAuth = .{ .no_browser = raw.no_browser };
    if (raw.redirect_port) |p| out.redirect_port = p;
    if (raw.account) |a| out.account = a;
    if (raw.token_store) |s| out.token_store = s;
    if (raw.sign_in_timeout) |s| out.sign_in_timeout = .fromSeconds(s);

    if (raw.client_issuer != null and raw.client_id == null) {
        diag.option = Option.@"client-issuer".text();
        diag.hint = "it needs --client-id";
        return error.Conflict;
    }
    if (raw.client_id) |id| {
        if (raw.client_metadata_url != null) {
            diag.option = Option.@"client-metadata-url".text();
            diag.hint = "--client-id and --client-metadata-url exclude each other";
            return error.Conflict;
        }
        // Without an issuer, the client binds to the authorization server that the upstream
        // server names. The upstream server is not trusted, thus a secret needs an issuer.
        const secret = variable(env, client_secret_variable);
        if (secret != null and raw.client_issuer == null) {
            diag.option = Option.@"client-id".text();
            diag.hint = "a client with a secret in " ++ client_secret_variable ++ " needs --client-issuer";
            return error.Conflict;
        }
        out.registration = .{ .pre_registered = .{
            .client_id = id,
            .issuer = raw.client_issuer,
            .client_secret = secret,
        } };
    } else if (raw.client_metadata_url) |u| {
        out.registration = .{ .client_metadata_url = .{ .url = u, .explicit = true } };
    } else if (out.redirect_port != default_redirect_port) {
        // The default document lists only the default redirect URI.
        out.registration = .dynamic;
    }

    switch (out.token_store) {
        .keychain, .memory => if (raw.token_key_file != null) {
            diag.option = Option.@"token-key-file".text();
            diag.hint = "only the file store takes a key: use --token-store file or auto";
            return error.Conflict;
        },
        .auto, .file => {
            const key_text = variable(env, token_key_variable);
            if (key_text != null and raw.token_key_file != null) {
                diag.option = Option.@"token-key-file".text();
                diag.hint = "give the key in " ++ token_key_variable ++ " or in a file, not in both";
                return error.Conflict;
            }
            if (key_text) |text| {
                out.token_key = parseKey(text) orelse {
                    diag.name = token_key_variable;
                    diag.hint = "use 64 hexadecimal digits";
                    return error.InvalidVariable;
                };
            }
            out.token_key_file = raw.token_key_file;
            if (out.token_store == .file and out.token_key == null and out.token_key_file == null) return error.MissingTokenKey;
        },
    }
    return out;
}

/// The value of the environment variable `name` without spaces and tabs at its ends, or null
/// when it is not set or empty.
fn variable(env: ?*const Environ.Map, name: []const u8) ?[]const u8 {
    const map = env orelse return null;
    const value = std.mem.trim(u8, map.get(name) orelse return null, " \t");
    return if (value.len == 0) null else value;
}

/// The 32 bytes of a key of 64 hexadecimal digits, or null.
fn parseKey(text: []const u8) ?[32]u8 {
    var key: [32]u8 = undefined;
    if (text.len != 2 * key.len) return null;
    _ = std.fmt.hexToBytes(&key, text) catch return null;
    return key;
}

/// True for the name of an environment variable: a letter or `_`, then letters, digits and
/// `_`.
fn validVariableName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// True for a label of `--account`: 1 to `max_account_bytes` letters, digits and `._@+-`.
/// The label is a part of the storage identity, thus it has no `|`.
const validAccount = bridge.oauth.validAccount;

/// Why `url` is not a valid URL of an upstream server, or null for a valid URL. A valid URL
/// uses `https`, or `http` with a loopback host. It has a host, and no user, no password and
/// no fragment. The hint never has a part of the URL.
pub fn upstreamUrlHint(url: []const u8) ?[]const u8 {
    if (!http_syntax.isRequestUrl(url)) return "use an http or https URL with visible ASCII characters only";
    const uri = std.Uri.parse(url) catch unreachable;
    const secure = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!secure and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return "use https, or http with a loopback host such as 127.0.0.1";
    if (uri.user != null or uri.password != null) return "remove the user and the password from the URL: give a secret with --header-env";
    if (uri.fragment != null) return "remove the fragment from the URL";
    const host = componentText(uri.host orelse return "the URL has no host");
    if (host.len == 0) return "the URL has no host";
    if (uri.port) |p| if (p == 0) return "the port 0 is not valid";
    if (!secure and !mcp.transport.proxy.isLoopback(host)) return "use https: http is permitted only for a loopback host such as 127.0.0.1";
    return null;
}

/// Why `text` is not a valid issuer of `--client-issuer`, or null. An issuer is an https URL
/// with a host and without a query and a fragment (RFC 8414 section 2).
fn issuerHint(text: []const u8) ?[]const u8 {
    const https = "use an https URL";
    if (!http_syntax.isVisibleAscii(text)) return https;
    const uri = std.Uri.parse(text) catch return https;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return https;
    const host = componentText(uri.host orelse return "the URL has no host");
    if (host.len == 0) return "the URL has no host";
    if (uri.user != null or uri.password != null) return "remove the user and the password from the URL";
    if (uri.query != null or uri.fragment != null) return "an issuer has no query and no fragment";
    return null;
}

fn componentText(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw, .percent_encoded => |text| text,
    };
}

/// Parses a decimal number from `min` to `max`. Only the digits 0 to 9 are valid: no sign,
/// no space and no underscore. Returns null for a different text.
fn parseNumber(comptime T: type, text: []const u8, min: T, max: T) ?T {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseUnsigned(T, text, 10) catch return null;
    if (n < min or n > max) return null;
    return n;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

/// A test environment with the variables of `pairs`.
fn testEnv(pairs: []const [2][]const u8) !Environ.Map {
    var map: Environ.Map = .init(testing.allocator);
    errdefer map.deinit();
    for (pairs) |p| try map.put(p[0], p[1]);
    return map;
}

fn testParse(args: []const []const u8) Error!Options {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The tests examine only the scalar fields and the slices of `args`. The lists are in the
    // arena, thus `expectCommand` parses again with its own arena.
    var options = try parse(arena.allocator(), args, null);
    options.command = &.{};
    options.http.headers = &.{};
    return options;
}

fn expectCommand(expected: []const []const u8, args: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options = try parse(arena.allocator(), args, null);
    try testing.expectEqual(expected.len, options.command.len);
    for (expected, options.command) |e, a| try testing.expectEqualStrings(e, a);
}

fn expectErrorEnv(expected: Error, option: []const u8, args: []const []const u8, env: ?*const Environ.Map) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(expected, parseDiagnostic(arena.allocator(), args, env, &diag));
    try testing.expectEqualStrings(option, diag.option);
}

fn expectError(expected: Error, option: []const u8, args: []const []const u8) !void {
    return expectErrorEnv(expected, option, args, null);
}

/// The diagnostic text of the error of `args`.
fn diagnosticText(buf: []u8, args: []const []const u8, env: ?*const Environ.Map) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const err = if (parseDiagnostic(arena.allocator(), args, env, &diag)) |_| return error.TestExpectedError else |e| e;
    var w: Io.Writer = .fixed(buf);
    try diag.write(err, &w);
    return w.buffered();
}

test "the defaults" {
    const options = try testParse(&.{ "--", "server" });
    try testing.expectEqual(Action.serve, options.action);
    try testing.expectEqualStrings("server", options.name);
    try testing.expectEqual(std.log.Level.info, options.log_level);
    try testing.expectEqual(@as(i64, 60), options.discover_timeout.toSeconds());
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), options.max_line_bytes);
    try testing.expectEqualStrings("", options.url);
    try testing.expect(options.oauth == null);
    try expectCommand(&.{"server"}, &.{ "--", "server" });
}

test "the options and the upstream command" {
    const args: []const []const u8 = &.{
        "--name",             "files",
        "--log-level",        "debug",
        "--discover-timeout", "120",
        "--max-line-bytes",   "4096",
        "--",                 "node",
        "server.js",          "--stdio",
    };
    const options = try testParse(args);
    try testing.expectEqual(Action.serve, options.action);
    try testing.expectEqualStrings("files", options.name);
    try testing.expectEqual(std.log.Level.debug, options.log_level);
    try testing.expectEqual(@as(i64, 120), options.discover_timeout.toSeconds());
    try testing.expectEqual(@as(usize, 4096), options.max_line_bytes);
    try expectCommand(&.{ "node", "server.js", "--stdio" }, args);
}

test "the value after an equals sign" {
    const options = try testParse(&.{ "--name=a=b", "--log-level=warn", "--discover-timeout=5", "--max-line-bytes=1", "--", "x" });
    try testing.expectEqualStrings("a=b", options.name);
    try testing.expectEqual(std.log.Level.warn, options.log_level);
    try testing.expectEqual(@as(i64, 5), options.discover_timeout.toSeconds());
    try testing.expectEqual(@as(usize, 1), options.max_line_bytes);
}

test "the last value of an option applies" {
    const options = try testParse(&.{ "--log-level", "err", "--log-level", "warn", "--", "x" });
    try testing.expectEqual(std.log.Level.warn, options.log_level);
}

test "the arguments after -- go to the upstream command" {
    try expectCommand(&.{ "server", "--help", "--name", "--" }, &.{ "--", "server", "--help", "--name", "--" });
    try expectCommand(&.{ "server", "https://example.com/mcp" }, &.{ "--", "server", "https://example.com/mcp" });
    const options = try testParse(&.{ "--", "server", "--version" });
    try testing.expectEqual(Action.serve, options.action);
}

test "help and version" {
    try testing.expectEqual(Action.help, (try testParse(&.{"--help"})).action);
    try testing.expectEqual(Action.version, (try testParse(&.{"--version"})).action);
    // The first of the two options applies, and no command is necessary.
    try testing.expectEqual(Action.help, (try testParse(&.{ "--log-level", "debug", "--help", "--version" })).action);
    try testing.expectEqual(Action.help, (try testParse(&.{ "logout", "--help" })).action);
    try testing.expectEqual(Action.help, (try testParse(&.{ "--header", "x-a:1", "--help" })).action);
    try expectError(error.InvalidValue, "--help", &.{"--help=yes"});
    try expectError(error.InvalidValue, "--version", &.{"--version="});
}

test "a missing -- or a missing command" {
    try expectError(error.MissingCommand, "", &.{});
    try expectError(error.MissingCommand, "", &.{ "--name", "x" });
    try expectError(error.MissingCommand, "", &.{"--"});
    try expectError(error.MissingCommand, "", &.{ "--", "" });
    try expectError(error.UnexpectedArgument, "", &.{"server"});
    try expectError(error.UnexpectedArgument, "", &.{ "server", "--", "x" });
    try expectError(error.UnexpectedArgument, "", &.{ "-", "--", "x" });
}

test "an unknown option" {
    try expectError(error.UnknownOption, "--verbose", &.{ "--verbose", "--", "x" });
    try expectError(error.UnknownOption, "-h", &.{ "-h", "--", "x" });
    try expectError(error.UnknownOption, "-", &.{ "-=x", "--", "x" });
    // The diagnostic has the name of the option, but not the value.
    try expectError(error.UnknownOption, "--token", &.{ "--token=secret", "--", "x" });
    try expectError(error.UnknownOption, "--", &.{ "--=x", "--", "x" });
    try expectError(error.UnknownOption, "---name", &.{ "---name", "x", "--", "x" });
    // There is no option for a secret on the command line.
    try expectError(error.UnknownOption, "--client-secret", &.{ "--client-secret", "s3cr3t", "https://a.example/mcp" });
    try expectError(error.UnknownOption, "--allow-http", &.{ "--allow-http", "http://a.example/mcp" });
    try expectError(error.UnknownOption, "--insecure", &.{ "--insecure", "https://a.example/mcp" });
    try expectError(error.UnknownOption, "--headless", &.{ "--headless", "https://a.example/mcp" });
}

test "a missing value" {
    try expectError(error.MissingValue, "--name", &.{"--name"});
    try expectError(error.MissingValue, "--name", &.{ "--name", "--", "x" });
    try expectError(error.MissingValue, "--log-level", &.{ "--log-level", "--name", "x", "--", "x" });
    try expectError(error.MissingValue, "--max-line-bytes", &.{"--max-line-bytes"});
    try expectError(error.MissingValue, "--header", &.{ "--header", "--header-env", "A=B", "https://a.example/mcp" });
    try expectError(error.MissingValue, "--redirect-port", &.{"--redirect-port"});
}

test "a name that is not valid" {
    try expectError(error.InvalidValue, "--name", &.{ "--name=", "--", "x" });
    try expectError(error.InvalidValue, "--name", &.{ "--name", "", "--", "x" });
}

test "a log level that is not valid" {
    try expectError(error.InvalidValue, "--log-level", &.{ "--log-level", "error", "--", "x" });
    try expectError(error.InvalidValue, "--log-level", &.{ "--log-level", "trace", "--", "x" });
    try expectError(error.InvalidValue, "--log-level", &.{ "--log-level", "DEBUG", "--", "x" });
}

test "numbers that are not valid" {
    const bad: []const []const u8 = &.{ "", "0", "-1", "+1", " 1", "1 ", "1_000", "0x10", "1.5", "abc", "4294967296", "99999999999999999999999" };
    for (bad) |text| {
        try expectError(error.InvalidValue, "--discover-timeout", &.{ "--discover-timeout", text, "--", "x" });
        try expectError(error.InvalidValue, "--max-line-bytes", &.{ "--max-line-bytes", text, "--", "x" });
        try expectError(error.InvalidValue, "--max-response-bytes", &.{ "--max-response-bytes", text, "https://a.example/mcp" });
        try expectError(error.InvalidValue, "--sign-in-timeout", &.{ "--sign-in-timeout", text, "https://a.example/mcp" });
        try expectError(error.InvalidValue, "--redirect-port", &.{ "--redirect-port", text, "https://a.example/mcp" });
    }
    try expectError(error.InvalidValue, "--max-line-bytes", &.{ "--max-line-bytes", "1073741825", "--", "x" });
    try expectError(error.InvalidValue, "--max-response-bytes", &.{ "--max-response-bytes", "1073741825", "https://a.example/mcp" });
    try expectError(error.InvalidValue, "--redirect-port", &.{ "--redirect-port", "65536", "https://a.example/mcp" });

    const options = try testParse(&.{ "--discover-timeout", "4294967295", "--max-line-bytes", "1073741824", "--", "x" });
    try testing.expectEqual(@as(i64, std.math.maxInt(u32)), options.discover_timeout.toSeconds());
    try testing.expectEqual(max_line_bytes_limit, options.max_line_bytes);
    const url = try testParse(&.{ "--max-response-bytes", "1073741824", "--sign-in-timeout", "4294967295", "--redirect-port", "65535", "https://a.example/mcp" });
    try testing.expectEqual(max_response_bytes_limit, url.http.max_response_bytes);
    try testing.expectEqual(@as(i64, std.math.maxInt(u32)), url.oauth.?.sign_in_timeout.toSeconds());
    try testing.expectEqual(@as(u16, 65535), url.oauth.?.redirect_port);
}

test "the default name is the file name of the command without its extension" {
    try testing.expectEqualStrings("server", (try testParse(&.{ "--", "server" })).name);
    try testing.expectEqualStrings("server", (try testParse(&.{ "--", "/opt/mcp/bin/server.exe" })).name);
    try testing.expectEqualStrings("my.server", (try testParse(&.{ "--", "./my.server.py", "arg" })).name);
    try testing.expectEqualStrings("explicit", (try testParse(&.{ "--name", "explicit", "--", "/bin/server" })).name);
}

test "the URL form and its defaults" {
    const options = try testParse(&.{"https://mcp.example.com/v1/mcp"});
    try testing.expectEqual(Action.serve, options.action);
    try testing.expectEqualStrings("https://mcp.example.com/v1/mcp", options.url);
    try testing.expectEqualStrings("mcp.example.com", options.name);
    try testing.expectEqual(@as(usize, 0), options.command.len);
    try testing.expectEqual(default_max_response_bytes, options.http.max_response_bytes);
    try testing.expect(options.http.ca_file == null);
    try testing.expect(!options.http.static_authorization);
    const oauth = options.oauth.?;
    try testing.expectEqualStrings(default_client_metadata_url, oauth.registration.client_metadata_url.url);
    try testing.expect(!oauth.registration.client_metadata_url.explicit);
    try testing.expectEqual(default_redirect_port, oauth.redirect_port);
    try testing.expectEqual(@as(u16, 41894), oauth.redirect_port);
    try testing.expectEqualStrings("default", oauth.account);
    try testing.expectEqual(TokenStore.auto, oauth.token_store);
    try testing.expect(oauth.token_key == null);
    try testing.expect(oauth.token_key_file == null);
    try testing.expect(!oauth.no_browser);
    try testing.expectEqual(@as(i64, 300), oauth.sign_in_timeout.toSeconds());
    var buf: [OAuth.max_redirect_uri_bytes]u8 = undefined;
    try testing.expectEqualStrings("http://127.0.0.1:41894/callback", oauth.redirectUri(&buf));
}

test "the options of the URL form" {
    const options = try testParse(&.{
        "--name",                "example",                         "--log-level",      "debug",
        "--discover-timeout",    "90",                              "--max-line-bytes", "8192",
        "--max-response-bytes",  "1048576",                         "--ca-file",        "certs/ca.pem",
        "--client-metadata-url", "https://client.example/app.json", "--redirect-port",  "50000",
        "--account",             "work@example.com",                "--token-store",    "memory",
        "--no-browser",          "--sign-in-timeout",               "60",               "http://127.0.0.1:3000/mcp",
    });
    try testing.expectEqualStrings("example", options.name);
    try testing.expectEqualStrings("http://127.0.0.1:3000/mcp", options.url);
    try testing.expectEqual(@as(i64, 90), options.discover_timeout.toSeconds());
    try testing.expectEqual(@as(usize, 8192), options.max_line_bytes);
    try testing.expectEqual(@as(usize, 1048576), options.http.max_response_bytes);
    try testing.expectEqualStrings("certs/ca.pem", options.http.ca_file.?);
    const oauth = options.oauth.?;
    // An explicit document applies also with a port that is not the default.
    try testing.expectEqualStrings("https://client.example/app.json", oauth.registration.client_metadata_url.url);
    try testing.expect(oauth.registration.client_metadata_url.explicit);
    try testing.expectEqual(@as(u16, 50000), oauth.redirect_port);
    try testing.expectEqualStrings("work@example.com", oauth.account);
    try testing.expectEqual(TokenStore.memory, oauth.token_store);
    try testing.expect(oauth.no_browser);
    try testing.expectEqual(@as(i64, 60), oauth.sign_in_timeout.toSeconds());
    var buf: [OAuth.max_redirect_uri_bytes]u8 = undefined;
    try testing.expectEqualStrings("http://127.0.0.1:50000/callback", oauth.redirectUri(&buf));
}

test "the URL must be the last argument, and only one form applies" {
    try expectError(error.UnexpectedArgument, "", &.{ "https://a.example/mcp", "--name", "x" });
    try expectError(error.UnexpectedArgument, "", &.{ "https://a.example/mcp", "https://b.example/mcp" });
    try expectError(error.UnexpectedArgument, "", &.{ "https://a.example/mcp", "--", "server" });
    try expectError(error.UnexpectedArgument, "", &.{"a.example/mcp"});
}

test "the URL of the upstream server" {
    for ([_][]const u8{
        "https://mcp.example.com/mcp",
        "HTTPS://mcp.example.com:8443/mcp?tenant=a&x=%20",
        "https://[2001:db8::1]/mcp",
        "http://127.0.0.1:3000/mcp",
        "http://127.8.9.10/mcp",
        "http://localhost:3000/mcp",
        "http://LOCALHOST/mcp",
        "http://mcp.localhost/mcp",
        "http://[::1]:3000/mcp",
    }) |url| {
        errdefer std.debug.print("the URL: {s}\n", .{url});
        try testing.expect(upstreamUrlHint(url) == null);
        try testing.expectEqualStrings(url, (try testParse(&.{url})).url);
    }
    // http only for a loopback host, and never an option that permits more.
    for ([_][]const u8{
        "http://mcp.example.com/mcp",
        "http://10.0.0.1/mcp",
        "http://128.0.0.1/mcp",
        "http://localhost.example.com/mcp",
        "http://[::2]/mcp",
        "ftp://mcp.example.com/mcp",
        "file:///etc/passwd",
        "https:///mcp",
        "https://user:s3cr3t@mcp.example.com/mcp",
        "https://token@mcp.example.com/mcp",
        "https://mcp.example.com/mcp#part",
        "https://mcp.example.com:0/mcp",
        "https://mcp.example.com/a b",
        "https://mcp.example.com/\r\nx: 1",
        "https://mcp.exämple.com/mcp",
    }) |url| {
        errdefer std.debug.print("the URL: {s}\n", .{url});
        try testing.expect(upstreamUrlHint(url) != null);
        try expectError(error.InvalidUrl, "", &.{url});
    }
}

test "the options for a URL are not valid with an upstream command" {
    const cases = [_]struct { option: []const u8, args: []const []const u8 }{
        .{ .option = "--header", .args = &.{ "--header", "x-a:1", "--", "x" } },
        .{ .option = "--header-env", .args = &.{ "--header-env", "x-a=A", "--", "x" } },
        .{ .option = "--max-response-bytes", .args = &.{ "--max-response-bytes", "10", "--", "x" } },
        .{ .option = "--ca-file", .args = &.{ "--ca-file", "ca.pem", "--", "x" } },
        .{ .option = "--client-id", .args = &.{ "--client-id", "c", "--", "x" } },
        .{ .option = "--client-issuer", .args = &.{ "--client-issuer", "https://as.example", "--", "x" } },
        .{ .option = "--client-metadata-url", .args = &.{ "--client-metadata-url", "https://c.example/c.json", "--", "x" } },
        .{ .option = "--redirect-port", .args = &.{ "--redirect-port", "5000", "--", "x" } },
        .{ .option = "--account", .args = &.{ "--account", "work", "--", "x" } },
        .{ .option = "--token-store", .args = &.{ "--token-store", "memory", "--", "x" } },
        .{ .option = "--token-key-file", .args = &.{ "--token-key-file", "key", "--", "x" } },
        .{ .option = "--no-browser", .args = &.{ "--no-browser", "--", "x" } },
        .{ .option = "--sign-in-timeout", .args = &.{ "--sign-in-timeout", "10", "--", "x" } },
        .{ .option = "--all", .args = &.{ "--all", "--", "x" } },
        // The first such option of the command line is in the diagnostic.
        .{ .option = "--no-browser", .args = &.{ "--name", "n", "--no-browser", "--header", "x-a:1", "--", "x" } },
    };
    for (cases) |case| try expectError(error.Conflict, case.option, case.args);
    try expectError(error.Conflict, "--all", &.{ "--all", "https://a.example/mcp" });
}

test "the headers of --header and --header-env" {
    var env = try testEnv(&.{
        .{ "API_TOKEN", "Bearer marker-0c9f" },
        .{ "TENANT", "  blue  " },
    });
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options = try parse(arena.allocator(), &.{
        "--header",                     "X-Client: vscode ",
        "--header-env",                 "Authorization=API_TOKEN",
        "--header-env=X-Tenant=TENANT", "--header=x-empty-ok:a:b",
        "https://mcp.example.com/mcp",
    }, &env);
    const h = options.http.headers;
    try testing.expectEqual(@as(usize, 4), h.len);
    try testing.expectEqualStrings("X-Client", h[0].name);
    try testing.expectEqualStrings("vscode", h[0].value);
    try testing.expectEqualStrings("Authorization", h[1].name);
    try testing.expectEqualStrings("Bearer marker-0c9f", h[1].value);
    try testing.expectEqualStrings("X-Tenant", h[2].name);
    try testing.expectEqualStrings("blue", h[2].value);
    try testing.expectEqualStrings("x-empty-ok", h[3].name);
    try testing.expectEqualStrings("a:b", h[3].value);
    // A static authorization header turns off the sign-in.
    try testing.expect(options.http.static_authorization);
    try testing.expect(options.oauth == null);
    // The value came from the environment, thus no warning applies.
    try testing.expect(options.http.secret_on_command_line == null);
}

test "an authorization header on the command line gives the name for a warning" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options = try parse(arena.allocator(), &.{ "--header", "x-a:1", "--header", "AUTHORIZATION:Bearer t", "https://a.example/mcp" }, null);
    try testing.expectEqualStrings("AUTHORIZATION", options.http.secret_on_command_line.?);
    try testing.expect(options.http.static_authorization);
    const cookie = try parse(arena.allocator(), &.{ "--header", "Cookie:a=b", "https://a.example/mcp" }, null);
    try testing.expectEqualStrings("Cookie", cookie.http.secret_on_command_line.?);
    try testing.expect(!cookie.http.static_authorization);
    try testing.expect(cookie.oauth != null);
}

test "the refused header names" {
    for (refused_header_names) |name| {
        for ([_]Option{ .header, .@"header-env" }) |option| {
            var arg_buf: [64]u8 = undefined;
            var upper_buf: [32]u8 = undefined;
            const upper = std.ascii.upperString(&upper_buf, name);
            const sep: u8 = if (option == .header) ':' else '=';
            for ([_][]const u8{ name, upper }) |n| {
                const arg = try std.fmt.bufPrint(&arg_buf, "{s}{c}VALUE", .{ n, sep });
                const key = if (option == .header) "--header" else "--header-env";
                try expectError(error.RefusedHeader, key, &.{ key, arg, "https://a.example/mcp" });
            }
        }
    }
    for ([_][]const u8{ "mcp-protocol-version:x", "Mcp-Method:x", "MCP-Name:x", "mcp-param-a:x", "mcp-:x", "proxy-authorization:Basic x", "Proxy-Authorization:x" }) |arg| {
        try expectError(error.RefusedHeader, "--header", &.{ "--header", arg, "https://a.example/mcp" });
    }
    try expectError(error.RefusedHeader, "--header-env", &.{ "--header-env", "Proxy-Authorization=VAR", "https://a.example/mcp" });
    // A name that only contains a refused name is valid.
    _ = try testParse(&.{ "--header", "x-host:a", "--header", "accepted:b", "--header", "x-mcp-a:c", "https://a.example/mcp" });
}

test "headers that are not valid" {
    var env = try testEnv(&.{
        .{ "EMPTY", "" },
        .{ "BLANK", " \t " },
        .{ "BROKEN", "Bearer a\r\nx-injected: 1" },
    });
    defer env.deinit();
    const url = "https://a.example/mcp";
    for ([_][]const u8{ "", "novalue", ":v", "a b:v", "a\r\nb:v", "x-a:", "x-a:   ", "x-a:v\r\nx-b: 1", "x-a:v\x00" }) |arg| {
        try expectErrorEnv(error.InvalidValue, "--header", &.{ "--header", arg, url }, &env);
    }
    for ([_][]const u8{ "", "x-a", "x-a=", "=VAR", "x-a=1VAR", "x-a=VAR-NAME", "x-a=A B", "a b=VAR" }) |arg| {
        try expectErrorEnv(error.InvalidValue, "--header-env", &.{ "--header-env", arg, url }, &env);
    }
    // A missing, empty or blank variable.
    for ([_][]const u8{ "x-a=MCP_BRIDGE_TEST_NOT_SET", "x-a=EMPTY", "x-a=BLANK" }) |arg| {
        try expectErrorEnv(error.MissingVariable, "--header-env", &.{ "--header-env", arg, url }, &env);
    }
    try expectErrorEnv(error.MissingVariable, "--header-env", &.{ "--header-env", "x-a=MCP_BRIDGE_TEST_NOT_SET", url }, null);
    try expectErrorEnv(error.InvalidVariable, "--header-env", &.{ "--header-env", "x-a=BROKEN", url }, &env);
    // Two headers with the same name.
    try expectErrorEnv(error.DuplicateHeader, "--header", &.{ "--header", "X-A:1", "--header", "x-a:2", url }, &env);
    try expectErrorEnv(error.DuplicateHeader, "--header-env", &.{ "--header", "authorization:1", "--header-env", "Authorization=BROKEN", url }, &env);
}

test "a static authorization header and the sign-in options exclude each other" {
    var env = try testEnv(&.{.{ "TOKEN", "Bearer t" }});
    defer env.deinit();
    const url = "https://a.example/mcp";
    const cases = [_][]const []const u8{
        &.{ "--client-id", "c" },
        &.{ "--client-issuer", "https://as.example" },
        &.{ "--client-metadata-url", "https://c.example/c.json" },
        &.{ "--redirect-port", "5000" },
        &.{ "--account", "work" },
        &.{ "--token-store", "memory" },
        &.{ "--token-key-file", "key" },
        &.{"--no-browser"},
        &.{ "--sign-in-timeout", "10" },
    };
    for (cases) |sign_in| {
        for ([_][]const []const u8{ &.{ "--header-env", "authorization=TOKEN" }, &.{ "--header", "Authorization:Bearer t" } }) |static| {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const args = try std.mem.concat(arena.allocator(), []const u8, &.{ static, sign_in, &.{url} });
            try expectErrorEnv(error.Conflict, sign_in[0], args, &env);
            // The order on the command line does not matter.
            const reversed = try std.mem.concat(arena.allocator(), []const u8, &.{ sign_in, static, &.{url} });
            try expectErrorEnv(error.Conflict, sign_in[0], reversed, &env);
        }
    }
    // Other headers and the options of the HTTP client are valid with a static header.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options = try parse(arena.allocator(), &.{ "--header-env", "authorization=TOKEN", "--header", "x-a:1", "--ca-file", "ca.pem", "--max-response-bytes", "10", url }, &env);
    try testing.expect(options.oauth == null);
    try testing.expectEqual(@as(usize, 10), options.http.max_response_bytes);
}

test "the client registration options" {
    var env = try testEnv(&.{.{ client_secret_variable, "s3cr3t-marker" }});
    defer env.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://a.example/mcp";

    const pre = (try parse(a, &.{ "--client-id", "bridge-client", "--client-issuer", "https://as.example.com/tenant", url }, &env)).oauth.?;
    try testing.expectEqualStrings("bridge-client", pre.registration.pre_registered.client_id);
    try testing.expectEqualStrings("https://as.example.com/tenant", pre.registration.pre_registered.issuer.?);
    try testing.expectEqualStrings("s3cr3t-marker", pre.registration.pre_registered.client_secret.?);
    // Without the variable, the client is a public client. The issuer is optional.
    const public = (try parse(a, &.{ "--client-id", "bridge-client", url }, null)).oauth.?;
    try testing.expect(public.registration.pre_registered.client_secret == null);
    try testing.expect(public.registration.pre_registered.issuer == null);
    // A client with a secret needs an issuer. Else the secret could go to an authorization
    // server that the upstream server names.
    try expectErrorEnv(error.Conflict, "--client-id", &.{ "--client-id", "bridge-client", url }, &env);
    var blank = try testEnv(&.{.{ client_secret_variable, " \t " }});
    defer blank.deinit();
    try testing.expect((try parse(a, &.{ "--client-id", "bridge-client", url }, &blank)).oauth.?.registration.pre_registered.client_secret == null);
    // The default document does not list another redirect port, thus dynamic registration
    // applies.
    try testing.expectEqual(Registration.dynamic, (try parse(a, &.{ "--redirect-port", "5000", url }, null)).oauth.?.registration);
    try testing.expectEqualStrings(default_client_metadata_url, (try parse(a, &.{ "--redirect-port", "41894", url }, null)).oauth.?.registration.client_metadata_url.url);
    // --client-id with another port stays pre-registered.
    try testing.expectEqualStrings("c", (try parse(a, &.{ "--client-id", "c", "--redirect-port", "5000", url }, null)).oauth.?.registration.pre_registered.client_id);

    try expectError(error.Conflict, "--client-issuer", &.{ "--client-issuer", "https://as.example", url });
    try expectError(error.Conflict, "--client-metadata-url", &.{ "--client-id", "c", "--client-metadata-url", "https://c.example/c.json", url });
    for ([_][]const u8{ "", "a\x01b", "caf\xc3\xa9" }) |id| try expectError(error.InvalidValue, "--client-id", &.{ "--client-id", id, url });
    for ([_][]const u8{ "http://as.example", "as.example", "https://", "https://as.example?x=1", "https://as.example#f", "https://u:p@as.example", "https://as.example/a b" }) |issuer| {
        try expectError(error.InvalidValue, "--client-issuer", &.{ "--client-id", "c", "--client-issuer", issuer, url });
    }
    for ([_][]const u8{ "http://c.example/c.json", "https://c.example", "https://c.example/", "https://c.example/c.json#f", "https://u@c.example/c.json", "https://c.example/../c.json", "https://c.example/a b" }) |doc| {
        try expectError(error.InvalidValue, "--client-metadata-url", &.{ "--client-metadata-url", doc, url });
    }
}

test "the account and the token store" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://a.example/mcp";
    const key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191A1B1C1D1E1F";
    var env = try testEnv(&.{.{ token_key_variable, key_hex }});
    defer env.deinit();

    for ([_][]const u8{ "", "a|b", "a b", "ä", "x" ** (max_account_bytes + 1) }) |label| {
        try expectError(error.InvalidValue, "--account", &.{ "--account", label, url });
    }
    try testing.expectEqualStrings("x" ** max_account_bytes, (try parse(a, &.{ "--account", "x" ** max_account_bytes, url }, null)).oauth.?.account);
    try expectError(error.InvalidValue, "--token-store", &.{ "--token-store", "disk", url });

    // The key of the environment for the stores auto and file.
    for ([_][]const u8{ "auto", "file" }) |store| {
        const oauth = (try parse(a, &.{ "--token-store", store, url }, &env)).oauth.?;
        var expected: [32]u8 = undefined;
        for (&expected, 0..) |*b, i| b.* = @intCast(i);
        try testing.expectEqualSlices(u8, &expected, &oauth.token_key.?);
    }
    // The stores keychain and memory ignore the variable.
    try testing.expect((try parse(a, &.{ "--token-store", "keychain", url }, &env)).oauth.?.token_key == null);
    try testing.expectEqualStrings("key.txt", (try parse(a, &.{ "--token-store", "file", "--token-key-file", "key.txt", url }, null)).oauth.?.token_key_file.?);
    try testing.expectEqualStrings("key.txt", (try parse(a, &.{ "--token-key-file", "key.txt", url }, null)).oauth.?.token_key_file.?);

    try expectErrorEnv(error.MissingTokenKey, "", &.{ "--token-store", "file", url }, null);
    try expectErrorEnv(error.Conflict, "--token-key-file", &.{ "--token-key-file", "key.txt", url }, &env);
    try expectError(error.Conflict, "--token-key-file", &.{ "--token-store", "memory", "--token-key-file", "key.txt", url });
    try expectError(error.Conflict, "--token-key-file", &.{ "--token-store", "keychain", "--token-key-file", "key.txt", url });
    try expectError(error.InvalidValue, "--token-key-file", &.{ "--token-key-file=", url });
    for ([_][]const u8{ "00", key_hex ++ "00", "zz" ++ key_hex[2..], key_hex[0..63] ++ " " }) |bad| {
        var bad_env = try testEnv(&.{.{ token_key_variable, bad }});
        defer bad_env.deinit();
        try expectErrorEnv(error.InvalidVariable, "", &.{url}, &bad_env);
        // The variable does not count for a store without a key.
        _ = try parse(a, &.{ "--token-store", "memory", url }, &bad_env);
    }
}

test "logout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try parse(a, &.{ "logout", "--account", "work", "--redirect-port", "5000", "--token-store", "keychain", "--ca-file", "ca.pem", "--log-level", "debug", "https://a.example/mcp" }, null);
    try testing.expectEqual(Action.logout, one.action);
    try testing.expectEqualStrings("https://a.example/mcp", one.url);
    try testing.expect(!one.logout_all);
    try testing.expectEqualStrings("work", one.oauth.?.account);
    try testing.expectEqual(@as(u16, 5000), one.oauth.?.redirect_port);
    try testing.expectEqual(TokenStore.keychain, one.oauth.?.token_store);
    try testing.expectEqualStrings("ca.pem", one.http.ca_file.?);
    try testing.expectEqual(std.log.Level.debug, one.log_level);
    const all = try parse(a, &.{ "logout", "--all" }, null);
    try testing.expect(all.logout_all);
    try testing.expectEqualStrings("", all.url);
    try testing.expectEqualStrings("default", all.oauth.?.account);

    try expectError(error.MissingUrl, "", &.{"logout"});
    try expectError(error.MissingUrl, "", &.{ "logout", "--account", "work" });
    try expectError(error.Conflict, "--all", &.{ "logout", "--all", "https://a.example/mcp" });
    try expectError(error.Conflict, "--account", &.{ "logout", "--account", "work", "--all" });
    try expectError(error.UnexpectedArgument, "", &.{ "logout", "--", "server" });
    try expectError(error.InvalidUrl, "", &.{ "logout", "http://a.example/mcp" });
    for ([_][]const []const u8{
        &.{ "--name", "x" },
        &.{ "--discover-timeout", "5" },
        &.{ "--max-line-bytes", "5" },
        &.{ "--max-response-bytes", "5" },
        &.{ "--header", "x-a:1" },
        &.{ "--header-env", "x-a=A" },
        &.{ "--client-id", "c" },
        &.{ "--client-metadata-url", "https://c.example/c.json" },
        &.{"--no-browser"},
        &.{ "--sign-in-timeout", "5" },
    }) |extra| {
        const args = try std.mem.concat(a, []const u8, &.{ &.{"logout"}, extra, &.{"https://a.example/mcp"} });
        try expectError(error.Conflict, extra[0], args);
    }
    // "logout" is a subcommand only as the first argument.
    try expectError(error.UnexpectedArgument, "", &.{ "--log-level", "debug", "logout", "--all" });
    try expectCommand(&.{"logout"}, &.{ "--", "logout" });
}

test "the diagnostic text has the option but no value" {
    var buf: [256]u8 = undefined;
    var env = try testEnv(&.{
        .{ "SECRET_HEADER", "Bearer s3cr3t\r\n" },
        .{ token_key_variable, "s3cr3t" },
        .{ client_secret_variable, "s3cr3t" },
    });
    defer env.deinit();
    const cases = [_]struct { args: []const []const u8, text: []const u8 }{
        .{ .args = &.{"server"}, .text = "an argument is not an option: give the URL of the upstream server, or put the upstream command after \"--\"" },
        .{ .args = &.{}, .text = "the upstream server is missing: give its URL, or put the upstream command after \"--\"" },
        .{ .args = &.{ "--token=s3cr3t", "--", "x" }, .text = "the option --token is not known" },
        .{ .args = &.{"--name"}, .text = "the option --name needs a value" },
        .{ .args = &.{ "--log-level=s3cr3t", "--", "x" }, .text = "the value of --log-level is not valid: use err, warn, info or debug" },
        .{ .args = &.{ "--max-line-bytes", "0", "--", "x" }, .text = "the value of --max-line-bytes is not valid: use a number of bytes from 1 to 1073741824" },
        .{ .args = &.{ "https://u:s3cr3t@a.example/mcp", "x" }, .text = "an argument is not an option: put the options before the URL of the upstream server" },
        .{ .args = &.{"https://u:s3cr3t@a.example/mcp"}, .text = "the URL of the upstream server is not valid: remove the user and the password from the URL: give a secret with --header-env" },
        .{ .args = &.{"http://s3cr3t.example/mcp"}, .text = "the URL of the upstream server is not valid: use https: http is permitted only for a loopback host such as 127.0.0.1" },
        .{ .args = &.{ "--header", "Bearer s3cr3t", "https://a.example/mcp" }, .text = "the value of --header is not valid: use <name>:<value>, with an HTTP header name" },
        .{ .args = &.{ "--header", "x-a:s3cr3t\x7f", "https://a.example/mcp" }, .text = "the header x-a of --header is not valid: the value has a control character" },
        .{ .args = &.{ "--header", "Host:s3cr3t", "https://a.example/mcp" }, .text = "the header Host of --header is not permitted: the bridge or the HTTP connection sets this header" },
        .{ .args = &.{ "--header", "mcp-method:s3cr3t", "https://a.example/mcp" }, .text = "the header mcp-method of --header is not permitted: the header names that start with mcp- are for the protocol" },
        .{ .args = &.{ "--header", "Proxy-Authorization:Basic s3cr3t", "https://a.example/mcp" }, .text = "the header Proxy-Authorization of --header is not permitted: the header goes to the upstream server and not to the proxy: put the user and the password in the proxy URL of HTTPS_PROXY" },
        .{ .args = &.{ "--header", "x-a:s3cr3t", "--header", "X-A:s3cr3t", "https://a.example/mcp" }, .text = "the header X-A occurs more than one time in --header and --header-env" },
        .{ .args = &.{ "--header-env", "Authorization=API_TOKEN", "https://a.example/mcp" }, .text = "the environment variable API_TOKEN of --header-env is not set, or it is empty" },
        .{ .args = &.{ "--header-env", "Authorization=SECRET_HEADER", "https://a.example/mcp" }, .text = "the environment variable SECRET_HEADER is not valid: the value is not a valid HTTP header value" },
        .{ .args = &.{"https://a.example/mcp"}, .text = "the environment variable MCP_BRIDGE_TOKEN_KEY is not valid: use 64 hexadecimal digits" },
        .{ .args = &.{ "--client-id", "c1", "--token-store", "memory", "https://a.example/mcp" }, .text = "the option --client-id cannot be used here: a client with a secret in MCP_BRIDGE_CLIENT_SECRET needs --client-issuer" },
        .{ .args = &.{ "--header", "Authorization:s3cr3t", "--no-browser", "https://a.example/mcp" }, .text = "the option --no-browser cannot be used here: a static authorization header and the sign-in options exclude each other" },
        .{ .args = &.{ "--header", "x-a:s3cr3t", "--", "x" }, .text = "the option --header cannot be used here: it applies only to the URL of an upstream server, not to an upstream command" },
        .{ .args = &.{ "--token-store", "memory", "--token-key-file", "s3cr3t", "https://a.example/mcp" }, .text = "the option --token-key-file cannot be used here: only the file store takes a key: use --token-store file or auto" },
        .{ .args = &.{"logout"}, .text = "the URL of the upstream server is missing: give it after the options of logout, or give --all" },
    };
    for (cases) |case| {
        errdefer std.debug.print("the arguments: {f}\n", .{std.json.fmt(case.args, .{})});
        const text = try diagnosticText(&buf, case.args, &env);
        try testing.expectEqualStrings(case.text, text);
        try testing.expect(std.mem.indexOf(u8, text, "s3cr3t") == null);
    }
    var empty = try testEnv(&.{});
    defer empty.deinit();
    try testing.expectEqualStrings(
        "--token-store file needs a key: set the environment variable MCP_BRIDGE_TOKEN_KEY, or give --token-key-file",
        try diagnosticText(&buf, &.{ "--token-store", "file", "https://a.example/mcp" }, &empty),
    );
}

test "the usage has the defaults" {
    try testing.expect(std.mem.indexOf(u8, usage, "The default is 60.") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "The default is 67108864 (64 MiB).") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "-- <command> [args...]") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "mcp-bridge-vscode [options] <url>") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "mcp-bridge-vscode logout --all") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "The default is 41894.") != null);
    try testing.expect(std.mem.indexOf(u8, usage, default_client_metadata_url) != null);
    try testing.expect(std.mem.indexOf(u8, usage, "MCP_BRIDGE_CLIENT_SECRET") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "MCP_BRIDGE_TOKEN_KEY") != null);
    // The shipped executable has no switch for http to other hosts and no switch for a
    // sign-in without a browser.
    for ([_][]const u8{ "--allow-http", "--insecure", "--headless" }) |switch_name| {
        try testing.expect(std.mem.indexOf(u8, usage, switch_name) == null);
    }
}
