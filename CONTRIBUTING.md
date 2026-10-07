# Contributing

Thank you for your interest in zig-bridge-sdk. This page tells you how the project accepts changes.

## Rules for commits

- Every commit is GPG-signed by the maintainer, Christian Presley.
- The maintainer is the only author and the only committer.
- Commit messages have no attribution trailer. The `commit-msg` hook rejects them.
- The subject follows Conventional Commits: `type(scope): description`. The types are feat, fix, docs, style, refactor, perf, test, build, ci, chore and revert.
- The body has one line for each changed file: `path: what changed`. The `commit-msg` hook and the `commit-policy` CI job check this.
- Pull request descriptions do not carry a generator or attribution line.
- Merges happen on the maintainer's computer with `git merge --ff-only`. The maintainer pushes the signed head of the pull request to `main`. Merges never use the squash merge or the rebase merge of GitHub, because then GitHub becomes the committer.

If you send a pull request, the maintainer applies your change as a signed commit and credits you in `CHANGELOG.md`.

## Set up the repository

1. Install Zig 0.16.0.
2. Clone the repository.
3. Run `git config core.hooksPath .githooks`.
4. Run `zig build test`. The first build fetches the pinned zig-sdk.

## Before you send a change

1. Run `zig build fmt`.
2. Run `zig build test`.
3. Run `zig build lint-docs` when you changed prose.
4. Run `zig build commit-policy` to check the commits of your branch.

## Prose

All prose uses the project profile of ASD-STE100 Simplified Technical English. The profile is in `docs/style/ste-profile.md`. The project dictionary is in `docs/dictionary/`.

## Scope

This repository holds the legacy protocol behavior: the side of a bridge that speaks MCP revision 2025-11-25 to its client. The side of the server always uses zig-sdk, which speaks revision 2026-07-28 only. Do not write a second copy of a part that zig-sdk provides. When a bridge needs a change in zig-sdk, send that change to zig-sdk.

The key of each bridge is its product, after a check of the brand guidelines that the vendor publishes. The maintainer records the result, the URL and the date of the check on the wiki page Package-Model. A new bridge has its files in `bridges/<product>/`, and its module declares a `bridge.Profile`.

## Tests on Linux from Windows

On Windows, you can run the Linux tests in the Windows Subsystem for Linux (WSL). Use the distribution Ubuntu-24.04. The CI uses Ubuntu 24.04 for its Linux tests too.

1. Compile each test module for Linux with `zig test`, `-target x86_64-linux-musl` and `--test-no-exec`.
2. Build the executables with `zig build install fixture-server -Dtarget=x86_64-linux-musl`.
3. Copy the test binaries, `zig-out/bin/` and `test/fixtures/` to a directory in `~/`.
4. Do not run the tests from `/mnt/c`. On that file system, Unix sockets fail, and file modes do not work as on Linux.
5. Write the commands for WSL in a script file with LF line ends.
6. Run the script with `wsl -d Ubuntu-24.04 -- sh <path of the script>`.

A command line that you give to `wsl` directly can change the paths. Thus use a script file.

The next example compiles the tests of the module `bridge`. The other test modules take the same form, with the imports that `build.zig` gives them. Zig keeps the fetched zig-sdk in `zig-pkg/`.

```bash
mkdir -p zig-out/linux
printf 'pub const version: []const u8 = "0.0.0";\n' > zig-out/linux/build_options.zig
zig test -target x86_64-linux-musl --test-no-exec -femit-bin=zig-out/linux/bridge-test \
  --dep mcp --dep build_options -Mroot=src/bridge.zig \
  -Mmcp="$(ls -d zig-pkg/mcp-*)/src/mcp.zig" -Mbuild_options=zig-out/linux/build_options.zig
```

The process test in `test/process_test.zig` starts the two executables. `build.zig` gives it their paths in the import `process_options`. For a run in WSL, give it a file with the constants `bridge_exe` and `fixture_exe`, or set the environment variables `PROCESS_TEST_BRIDGE` and `PROCESS_TEST_FIXTURE`. The test fails when an executable is missing. In WSL, a test that the runner skips is also a failure.

## Accept loops

On Windows, a cancel does not always wake a task that waits in `accept`. Thus every new accept loop uses the wake pattern of zig-sdk, `mcp.util.wake`.[^wake] The loop reads a stop flag after each `accept`. To stop the loop, `cancelAcceptLoop` sets the flag and connects to the listener until the task ends.

[^wake]: zig-sdk `src/mcp/util/wake.zig`. https://github.com/ChristianPresley/zig-sdk/blob/v0.3.0/src/mcp/util/wake.zig
