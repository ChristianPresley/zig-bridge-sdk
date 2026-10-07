//! The `mcp-bridge-vscode` executable. Visual Studio Code (VS Code) starts it as a stdio
//! server. The bridge then starts the upstream server and translates between the two protocol
//! revisions.
//!
//! The exit code is 0 at the end of stdin. It is 1 when the upstream server stops or when the
//! bridge has an internal error. It is 2 for arguments that are not valid. Stdout carries
//! only JSON-RPC messages. The log lines go to stderr, each with the tag `mcp-bridge-vscode`.
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
    const options = cli.parseDiagnostic(arena, if (args.len > 0) args[1..] else args, &diag) catch |err| {
        var text_buf: [256]u8 = undefined;
        var text: Io.Writer = .fixed(&text_buf);
        diag.write(err, &text) catch {};
        log.err("{s}", .{text.buffered()});
        std.debug.print("\n{s}", .{cli.usage});
        return 2;
    };

    switch (options.action) {
        .serve => {},
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
    return serve(init, options);
}

/// Serve VS Code until the end of stdin, and return the exit code.
fn serve(init: std.process.Init, options: cli.Options) u8 {
    var watchdog: Watchdog = .{ .io = init.io };
    const result = vscode.serve(init.io, init.gpa, .{
        .command = options.command,
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

test {
    std.testing.refAllDecls(@This());
    _ = cli;
    _ = &serve;
    _ = &upstreamExit;
    _ = &Watchdog.arm;
}
