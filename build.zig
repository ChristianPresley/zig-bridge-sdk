const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The pinned zig-sdk. The package exports its `mcp` module again, so that an embedder
    // uses the same `mcp` types as the bridges (one zig-sdk hash for both).
    const mcp_dep = b.dependency("mcp", .{ .target = target, .optimize = optimize });
    const mcp = mcp_dep.module("mcp");
    b.modules.put(b.graph.arena, "mcp", mcp) catch @panic("OOM");

    // The version of the package, for `--version` and the serverInfo fallback.
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    const build_options = options.createModule();

    // The core module that every bridge uses.
    const bridge = b.addModule("bridge", .{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp },
            .{ .name = "build_options", .module = build_options },
        },
    });

    // One module and one executable for each product. The name of the module is the key of
    // the product.
    const vscode = b.addModule("vscode", .{
        .root_source_file = b.path("bridges/vscode/vscode.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp },
            .{ .name = "bridge", .module = bridge },
        },
    });
    const vscode_exe = b.addExecutable(.{
        .name = "mcp-bridge-vscode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bridges/vscode/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vscode", .module = vscode },
                .{ .name = "bridge", .module = bridge },
                .{ .name = "mcp", .module = mcp },
            },
        }),
    });
    b.installArtifact(vscode_exe);
    const run_vscode = b.addRunArtifact(vscode_exe);
    if (b.args) |args| run_vscode.addArgs(args);
    b.step("run-vscode", "Run mcp-bridge-vscode").dependOn(&run_vscode.step);

    // The upstream server of the tests: a zig-sdk server with the tools that the tests need.
    // The module `fixture` makes the server. The executable serves it over stdio, and a test
    // can make it in its own process.
    const fixture = b.createModule(.{
        .root_source_file = b.path("test/fixture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mcp", .module = mcp }},
    });
    const fixture_server = b.addExecutable(.{
        .name = "bridge-fixture-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixture_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp },
                .{ .name = "fixture", .module = fixture },
            },
        }),
    });
    const install_fixture = b.addInstallArtifact(fixture_server, .{});
    b.step("fixture-server", "Build the upstream server of the tests").dependOn(&install_fixture.step);

    // Unit tests. `-Dfuzz` prepares them for `zig build test -Dfuzz --fuzz` on Zig 0.16.0: a test
    // runner whose fuzz path compiles, and the LLVM backend, because the self-hosted backend of
    // Debug builds emits no `__sancov_pcs1` table and the fuzzer then sees no coverage.
    const fuzz = b.option(bool, "fuzz", "Prepare the unit tests for --fuzz on Zig 0.16.0") orelse false;
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (fuzz) fuzzTestRunner(b) else null;
    const use_llvm: ?bool = if (fuzz) true else null;

    const test_step = b.step("test", "Run all tests");
    const test_vscode_step = b.step("test-vscode", "Run the tests of the vscode bridge");

    // The tests of `bridge.Upstream` read the test CA from `test/fixtures/tls` in the current
    // directory. Thus the tests run in the root also for `zig build test` in a subdirectory.
    const bridge_tests = b.addTest(.{ .root_module = bridge, .test_runner = test_runner, .use_llvm = use_llvm });
    const run_bridge_tests = b.addRunArtifact(bridge_tests);
    run_bridge_tests.setCwd(b.path("."));
    test_step.dependOn(&run_bridge_tests.step);

    const vscode_tests = b.addTest(.{ .root_module = vscode, .test_runner = test_runner, .use_llvm = use_llvm });
    const run_vscode_tests = b.addRunArtifact(vscode_tests);
    test_step.dependOn(&run_vscode_tests.step);
    test_vscode_step.dependOn(&run_vscode_tests.step);

    // The tests of the executable: the command line parser.
    const vscode_exe_tests = b.addTest(.{ .root_module = vscode_exe.root_module, .test_runner = test_runner, .use_llvm = use_llvm });
    const run_vscode_exe_tests = b.addRunArtifact(vscode_exe_tests);
    test_step.dependOn(&run_vscode_exe_tests.step);
    test_vscode_step.dependOn(&run_vscode_exe_tests.step);

    // The tests of the fixture server: its tools through the memory transport of zig-sdk, and
    // its HTTPS variant through the HTTP client of zig-sdk. The authorization server of the
    // HTTPS variant reads the test CA from `test/fixtures/tls` in the current directory.
    const fixture_tests = b.addTest(.{ .name = "fixture", .root_module = fixture, .test_runner = test_runner, .use_llvm = use_llvm });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    run_fixture_tests.setCwd(b.path("."));
    test_step.dependOn(&run_fixture_tests.step);

    // The transcript tests of the vscode bridge: the lines of VS Code go through the front
    // end, and the fixture server in the same process is the upstream server. The tests check
    // each frame against the vendored schemas.
    const vscode_transcripts = b.addTest(.{
        .name = "vscode-transcripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bridges/vscode/test/transcripts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mcp", .module = mcp },
                .{ .name = "vscode", .module = vscode },
                .{ .name = "fixture", .module = fixture },
            },
        }),
        .test_runner = test_runner,
        .use_llvm = use_llvm,
    });
    addSchemaImports(b, vscode_transcripts.root_module);
    const run_vscode_transcripts = b.addRunArtifact(vscode_transcripts);
    // The HTTPS variant of the fixture reads the test CA from `test/fixtures/tls`.
    run_vscode_transcripts.setCwd(b.path("."));
    test_step.dependOn(&run_vscode_transcripts.step);
    test_vscode_step.dependOn(&run_vscode_transcripts.step);

    // The process tests start the two executables and speak to them over pipes. The options
    // give the paths of the executables to the tests. Thus the build makes the executables
    // first, and a test fails, and never skips, when an executable is missing.
    const process_options = b.addOptions();
    process_options.addOptionPath("bridge_exe", vscode_exe.getEmittedBin());
    process_options.addOptionPath("fixture_exe", fixture_server.getEmittedBin());
    const process_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/process_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp },
            .{ .name = "fixture", .module = fixture },
            .{ .name = "build_options", .module = build_options },
            .{ .name = "process_options", .module = process_options.createModule() },
        },
    }), .test_runner = test_runner, .use_llvm = use_llvm });
    const run_process_tests = b.addRunArtifact(process_tests);
    // The paths of the options can be relative to the build root.
    run_process_tests.setCwd(b.path("."));
    test_step.dependOn(&run_process_tests.step);
    test_vscode_step.dependOn(&run_process_tests.step);

    // The process test of the HTTPS mode of the fixture server. It needs only that executable.
    const fixture_process_options = b.addOptions();
    fixture_process_options.addOptionPath("fixture_exe", fixture_server.getEmittedBin());
    const fixture_server_tests = b.addTest(.{ .name = "fixture-server", .root_module = b.createModule(.{
        .root_source_file = b.path("test/fixture_server_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mcp", .module = mcp },
            .{ .name = "fixture", .module = fixture },
            .{ .name = "process_options", .module = fixture_process_options.createModule() },
        },
    }), .test_runner = test_runner, .use_llvm = use_llvm });
    const run_fixture_server_tests = b.addRunArtifact(fixture_server_tests);
    run_fixture_server_tests.setCwd(b.path("."));
    test_step.dependOn(&run_fixture_server_tests.step);

    // The checks of the vendored schemas. The fixtures come in as anonymous imports, because
    // Zig 0.16 does not embed a file outside the module root.
    const schema_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/schema_fixtures_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mcp", .module = mcp }},
    }) });
    addSchemaImports(b, schema_tests.root_module);
    test_step.dependOn(&b.addRunArtifact(schema_tests).step);

    // The tests of the repository tools.
    for ([_][]const u8{
        "tools/lint_docs/main.zig",
        "tools/gen_dictionary.zig",
        "tools/changelog_section.zig",
        "tools/commit_policy.zig",
        "tools/check_version.zig",
    }) |tool_source| {
        const tool_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(tool_source),
            .target = b.graph.host,
        }) });
        const run_tool_tests = b.addRunArtifact(tool_tests);
        run_tool_tests.setCwd(b.path("."));
        test_step.dependOn(&run_tool_tests.step);
    }

    // Formatting check.
    const fmt_step = b.step("fmt", "Check formatting");
    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src", "bridges", "tools", "test", "examples" }, .check = true });
    fmt_step.dependOn(&fmt.step);

    // Tools written in Zig and run through `zig build <step>`.
    addTool(b, "lint-docs", "Check prose against the project STE profile", "tools/lint_docs/main.zig", &.{ "--strict", "--string-literals" });
    addTool(b, "commit-policy", "Check commits for a sole signed author", "tools/commit_policy.zig", &.{});
    addTool(b, "gen-dictionary", "Render the project dictionary", "tools/gen_dictionary.zig", &.{ "--out", "docs/generated/dictionary.md" });
    addTool(b, "check-version", "Check that a release tag matches the package version", "tools/check_version.zig", &.{});
    addTool(b, "changelog-section", "Print the changelog section of a version", "tools/changelog_section.zig", &.{});
}

/// Gives a test module the vendored schemas as the imports `schema_2025_11_25` and
/// `schema_2026_07_28`.
fn addSchemaImports(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("schema_2025_11_25", .{ .root_source_file = b.path("test/fixtures/mcp_schema_2025_11_25/schema.json") });
    module.addAnonymousImport("schema_2026_07_28", .{ .root_source_file = b.path("test/fixtures/mcp_schema_2026_07_28/schema.json") });
}

/// The fuzz path of the test runner of Zig 0.16.0 gives a `builtin.StackTrace` to
/// `std.debug.writeStackTrace`, but that function takes a `debug.StackTrace`. Thus no test
/// with a fuzz target compiles with `-ffuzz`. This makes a copy of the runner of the installed
/// toolchain with `std.debug.writeErrorReturnTrace` in that call. The repository keeps no copy.
fn fuzzTestRunner(b: *std.Build) std.Build.Step.Compile.TestRunner {
    const sub_path = "compiler/test_runner.zig";
    const source = b.graph.zig_lib_directory.handle.readFileAlloc(b.graph.io, sub_path, b.allocator, .limited(1 << 20)) catch |err|
        std.debug.panic("cannot read {s} of the Zig library: {t}", .{ sub_path, err });
    const needle = "std.debug.writeStackTrace(trace, stderr)";
    if (std.mem.count(u8, source, needle) != 1)
        std.debug.panic("{s} of the Zig library does not have one '{s}'; remove -Dfuzz", .{ sub_path, needle });
    const fixed = std.mem.replaceOwned(u8, b.allocator, source, needle, "std.debug.writeErrorReturnTrace(trace, stderr)") catch @panic("OOM");
    const files = b.addWriteFiles();
    return .{ .path = files.add("fuzz_test_runner.zig", fixed), .mode = .server };
}

fn addTool(b: *std.Build, step_name: []const u8, description: []const u8, source: []const u8, default_args: []const []const u8) void {
    const exe = b.addExecutable(.{
        .name = step_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args) else run.addArgs(default_args);
    b.step(step_name, description).dependOn(&run.step);
}
