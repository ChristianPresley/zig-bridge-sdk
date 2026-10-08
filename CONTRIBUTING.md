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
4. Run `zig build test --test-timeout 10m`. The first build fetches the pinned zig-sdk.

## Before you send a change

1. Run `zig build fmt`.
2. Run `zig build test --test-timeout 10m`.
3. Run `zig build lint-docs` when you changed prose.
4. Run `zig build commit-policy` to check the commits of your branch.

### The test timeout

Always give `--test-timeout 10m` to `zig build test`. The CI does this too. Without the option, the build runner waits only 60 s for each answer of a test runner. On Windows, a race of Zig 0.16.0 in parallel process starts (an inherited pipe) can delay that answer. The build runner then reports "test runner failed to respond", although no test hangs. With the option, each test has a limit of 10 minutes, and the build runner waits as long for each answer.

On Windows, the build can also stop with "unable to read results of configure phase" or "unable to load ...: Unexpected". These errors are transient. Run the command again.

## The interop checks

The CI job `interop` connects the legacy TypeScript SDK client to the bridge with two scripts in `.github/interop/`. To run them on your computer, install Node.js and the pinned packages, and build the three executables:

```bash
npm ci --ignore-scripts --no-audit --no-fund --prefix .github/interop
zig build install fixture-server embedded-server
node .github/interop/legacy_stdio_client.mjs zig-out/bin/mcp-bridge-vscode -- \
  zig-out/bin/bridge-fixture-server --many-tools 150
node .github/interop/legacy_stdio_client.mjs zig-out/bin/bridge-embedded-server \
  --many-tools 150
node .github/interop/oauth_stdio_client.mjs zig-out/bin/mcp-bridge-vscode \
  zig-out/bin/bridge-fixture-server test/fixtures/tls/ca.crt
```

Run the scripts from the root of the repository. The first script runs two times. The first run starts the bridge executable with `bridge-fixture-server` as its upstream command. The second run starts `bridge-embedded-server`, which has the bridge in its process. The second script starts `bridge-fixture-server` in its HTTPS mode with the test CA. It reads the sign-in URL from the stderr of the bridge, and opens the URL as a browser does.

## Prose

All prose uses the project profile of ASD-STE100 Simplified Technical English. The profile is in `docs/style/ste-profile.md`. The project dictionary is in `docs/dictionary/`.

## Scope

This repository holds the legacy protocol behavior: the side of a bridge that speaks MCP revision 2025-11-25 to its client. The side of the server always uses zig-sdk, which speaks revision 2026-07-28 only. Do not write a second copy of a part that zig-sdk provides. When a bridge needs a change in zig-sdk, send that change to zig-sdk.

The key of each bridge is its product, after a check of the brand guidelines that the vendor publishes. The maintainer records the result, the URL and the date of the check on the wiki page Package-Model. A new bridge has its files in `bridges/<product>/`, and its module declares a `bridge.Profile`.

## Tests on Linux from Windows

On Windows, you can run the Linux tests in the Windows Subsystem for Linux (WSL). Use the distribution Ubuntu-24.04. The CI uses Ubuntu 24.04 for its Linux tests too.

1. Compile each test module for Linux with `zig test`, `-target x86_64-linux-musl` and `--test-no-exec`.
2. Build the executables with `zig build install fixture-server embedded-server -Dtarget=x86_64-linux-musl`.
3. Copy the test binaries, `zig-out/bin/` and `test/fixtures/` to a directory in `~/`. Keep the path `test/fixtures/` below that directory.
4. Run the test binaries in that directory. The tests read the test CA from `test/fixtures/tls` in the current directory.
5. Do not run the tests from `/mnt/c`. On that file system, Unix sockets fail, and file modes do not work as on Linux.
6. Write the commands for WSL in a script file with LF line ends.
7. Run the script with `wsl -d Ubuntu-24.04 -- sh <path of the script>`.

A command line that you give to `wsl` directly can change the paths. Thus use a script file.

The next example compiles the tests of the module `bridge`. The other test modules take the same form, with the imports that `build.zig` gives them. Zig keeps the fetched zig-sdk in `zig-pkg/`. After a change of the pin, `zig-pkg/` has more than one zig-sdk. Thus the example takes the directory of the pinned zig-sdk from its hash in `build.zig.zon`.

```bash
mkdir -p zig-out/linux
printf 'pub const version: []const u8 = "0.0.0";\n' > zig-out/linux/build_options.zig
mcp_dir="zig-pkg/$(sed -n 's/.*\.hash = "\(mcp-[^"]*\)".*/\1/p' build.zig.zon)"
zig test -target x86_64-linux-musl --test-no-exec -femit-bin=zig-out/linux/bridge-test \
  --dep mcp --dep build_options -Mroot=src/bridge.zig \
  -Mmcp="$mcp_dir/src/mcp.zig" -Mbuild_options=zig-out/linux/build_options.zig
```

The process test in `test/process_test.zig` starts the three executables. `build.zig` gives it their paths in the import `process_options`. For a run in WSL, give it a file with the constants `bridge_exe`, `fixture_exe` and `embedded_exe`. As an alternative, set the environment variables `PROCESS_TEST_BRIDGE`, `PROCESS_TEST_FIXTURE` and `PROCESS_TEST_EMBEDDED`. The test fails when an executable is missing.

In WSL, examine each test that the runner skips. Only these skips are correct there:

- The test of the keychain of the host. WSL usually has no Secret Service, and then the test skips.
- The tests for Windows only, for example the environment of the browser.
- The tests of the CA store of the system, when the distribution has no CA certificates. Install the package `ca-certificates` to run them.

Each other skip in WSL is a failure.

## Accept loops

On Windows, a cancel does not always wake a task that waits in `accept`. Thus every new accept loop uses the wake pattern of zig-sdk, `mcp.util.wake`.[^wake] The loop reads a stop flag after each `accept`. To stop the loop, `cancelAcceptLoop` sets the flag and connects to the listener until the task ends.

[^wake]: zig-sdk `src/mcp/util/wake.zig`. https://github.com/ChristianPresley/zig-sdk/blob/v0.3.0/src/mcp/util/wake.zig
