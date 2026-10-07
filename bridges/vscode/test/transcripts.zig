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
const std = @import("std");

test {
    _ = @import("wire_check.zig");
    _ = @import("lifecycle_test.zig");
    _ = @import("forward_test.zig");
    _ = @import("negative_test.zig");
    _ = @import("input_test.zig");
}
