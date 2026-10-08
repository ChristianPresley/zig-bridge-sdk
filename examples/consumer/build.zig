const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // `bridge_sdk` is not in the committed build.zig.zon. Add it first with
    // `zig fetch --save=bridge_sdk <tarball>`, as the README of this example tells.
    const dep = b.dependency("bridge_sdk", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vscode", .module = dep.module("vscode") },
                // The package exports the `mcp` module of its zig-sdk pin. Take it from the
                // package, so that the consumer and the bridge use the same `mcp` types.
                .{ .name = "mcp", .module = dep.module("mcp") },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the consumer").dependOn(&run.step);

    // The check of CI: the driver speaks to the consumer as VS Code, then as a client of
    // revision 2026-07-28. It also takes `mcp` from the package.
    const driver = b.addExecutable(.{
        .name = "consumer-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mcp", .module = dep.module("mcp") }},
        }),
    });
    b.installArtifact(driver);
    const drive = b.addRunArtifact(driver);
    drive.addArtifactArg(exe);
    b.step("drive", "Run the consumer as VS Code and as a client of revision 2026-07-28").dependOn(&drive.step);
}
