//! The transcript tests of the VS Code bridge. Each test sends the lines of VS Code, or of the
//! Copilot harness of VS Code, to the front end. The upstream server is the fixture server in
//! the same process, or a scripted transport. At the end, each test checks every frame of the
//! bridge against the schema of revision 2025-11-25.
//!
//! - `lifecycle_test.zig`: `initialize`, the requests before `initialize`, the failures of
//!   `server/discover` and the sequence of the Copilot harness.
//! - `forward_test.zig`: the forwarded requests, the pages, the progress, the cancellation and
//!   the changes to the results.
//! - `negative_test.zig`: the lines that are not valid, the responses of VS Code and the error
//!   table.
//! - `input_test.zig`: the input requests of the upstream server and the answers of VS Code.
//! - `notify_test.zig`: the list changes, the resource updates and the log messages of the
//!   upstream server.
//! - `oauth_test.zig`: the sign-in at an HTTPS upstream server.
//! - `https_test.zig`: the HTTPS upstream server with the upstream configuration of the
//!   executable. The tests cover the registration modes, the stored sign-ins and the step-up.
//!   They also cover the stop of a sign-in, the trust, the icons and a proxy.
const std = @import("std");

test {
    _ = @import("wire_check.zig");
    _ = @import("lifecycle_test.zig");
    _ = @import("forward_test.zig");
    _ = @import("negative_test.zig");
    _ = @import("input_test.zig");
    _ = @import("notify_test.zig");
    _ = @import("oauth_test.zig");
    _ = @import("https_test.zig");
}
