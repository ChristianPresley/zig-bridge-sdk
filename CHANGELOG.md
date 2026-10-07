# Changelog

This file records all notable changes to this project. The format follows Keep a Changelog 1.1.0. The project uses semantic versioning. Each entry starts with the part that it changes: the package, the core module `bridge`, a bridge such as `vscode`, or the repository. Each release names the version of zig-sdk that it pins.

## [Unreleased]

This section has the work of milestones M0 and M1. M0 is the scaffold: the package, the build, the tools and the documents. M1 is the runtime of the `vscode` bridge over stdio.

The bridge starts the upstream command, answers `initialize`, and forwards the requests for tools, prompts, resources and completion. It also forwards the progress notifications and the cancellations. The input requests of the upstream server come with milestone M2. The pinned zig-sdk is v0.3.0.

### Added

- Package: the Zig package `bridge_sdk` for Zig 0.16.0. Its only dependency is zig-sdk v0.3.0, pinned in `build.zig.zon` by the commit `c1f55f00deefb3f09ac97126d6405b1820b927dd` and the package hash. The `.paths` list has `build.zig`, `build.zig.zon`, `src`, `bridges`, `LICENSE`, `NOTICE` and `README.md`.
- Package: the package exports the `mcp` module of the pinned zig-sdk, so that an embedder can use the same `mcp` types as the bridges.
- `bridge`: the core module in `src/bridge.zig`. `bridge.Profile` holds the settings of one product, for example its name, the `_meta` keys for the upstream server and the quirk flags. `bridge.version` is the version of the package.
- `bridge`: the quirk `drop_non_object_output_schema` of `bridge.Profile`. It removes each tool `outputSchema` whose root does not have `type: "object"`.
- `bridge`: `bridge.legacy`, the part of revision 2025-11-25 that a bridge receives from its client. It parses the params of `initialize`, `logging/setLevel` and `notifications/cancelled`, and it gives the kind of each method.
- `bridge`: `bridge.translate`, the translation without I/O. It has the capability masks for the two sides. It makes the `initialize` result from the `server/discover` result. A forwarded request loses `_meta` and `task`.
- `bridge`: the result rules of `bridge.translate`. A result loses `resultType`, `ttlMs`, `cacheScope` and the server information in `_meta`. A list result loses a `nextCursor` that is not a string.
- `bridge`: the schema rule R6 of `bridge.translate`. Each array schema of a tool `inputSchema` gets `items: {}` when its `items` is missing or false in JavaScript. The bridge writes one log line for each change.
- `bridge`: a `tools/call` result always has a `content` array. When it has `structuredContent` and no text block, it gets a text block with the serialized `structuredContent`.
- `bridge`: the error table of `bridge.translate`. Each error of the bridge has a fixed message, a JSON-RPC code and `data.cause`. An upstream error goes to the client without a change, except -32042.
- `bridge`: `bridge.Frontend`, the legacy stdio server for one client connection. It has the lifecycle states `awaiting_initialize`, `initializing`, `ready` and `closing`, and only the first `initialize` starts the upstream server.
- `bridge`: `bridge.Frontend` answers `ping` and `logging/setLevel` itself, and it answers `server/discover` with -32601. It sends the progress of the upstream server to the progress token of the client. It sends a cancellation of the client to the upstream server.
- `bridge`: in this version, the `initialize` result of `bridge.Frontend` has no `listChanged`, no `subscribe` and no `logging`. A tool that asks for input gets the error -32603 with `data.cause` `input_required`.
- `bridge`: the reader of `bridge.Frontend` never waits. At the limit of requests in flight, it answers a new request with -32603 at once. A canceled request gets no response.
- `bridge`: the line reader of `bridge.Frontend` keeps the start and the end of a line that is too long. The error for a line that is not valid has the id of the request, also when the id is the last member.
- `bridge`: when the upstream server stops, `bridge.Frontend` answers each request in flight with -32603 and stops. At the end of the input, it cancels the requests in flight and stops in `shutdown_grace`. `Frontend.Hooks` lets an executable act on these two events.
- `bridge`: `bridge.Upstream`, the `mcp.Client` of zig-sdk and its transport: stdio, memory or a transport of the caller. On stdio, `max_restarts` is 0 and the line limit is 64 MiB. `gone`, `reap` and `pid` tell the state of the child process.
- `bridge`: the debug log lines of `bridge.Upstream`. Each upstream exchange gives one line with the round, the method, the outcome and the time, but no content of a frame.
- `bridge`: `bridge.log`, the log function of the executables. Each stderr line has a fixed tag, the scope and the level. `bridge.log.setLevel` changes the level at run time.
- `vscode`: the module of the bridge for Visual Studio Code (VS Code) in `bridges/vscode/vscode.zig`, with `vscode.profile`. The profile declares `traceparent`, `tracestate` and the `vscode.` keys for the upstream server, and the quirks `normalize_array_items` and `drop_non_object_output_schema`.
- `vscode`: `vscode.serve` serves VS Code over stdin and stdout. Without a name, the server name for VS Code is the file name of the upstream command without its extension.
- `vscode`: the executable `mcp-bridge-vscode` in `bridges/vscode/main.zig` and `bridges/vscode/cli.zig`. Its usage is `mcp-bridge-vscode [options] -- <command> [args...]`, with the options `--name`, `--log-level`, `--discover-timeout`, `--max-line-bytes`, `--help` and `--version`.
- `vscode`: the exit codes of `mcp-bridge-vscode`. The code is 0 at the end of stdin and 1 when the upstream server stops or for an internal error. It is 2 for arguments that are not valid. A watchdog stops the bridge and the upstream server 8 s after the end of stdin.
- `vscode`: `bridges/vscode/README.md`, with the build, the configuration of VS Code, the options, the messages of the Output channel and the planned work of each milestone.
- Repository: the upstream server of the tests, `bridge-fixture-server` (`zig build fixture-server`), with its tools in `test/fixture.zig`. It is a zig-sdk server on stdio with the tools `echo`, `add`, `slow`, `progress`, `bare_array`, `structured` and `crash`, the prompt `greet` and a completion handler. A test in the same process can also add the tool `array_output`.
- Repository: the options `--many-tools N` and `--close-stdout` of `bridge-fixture-server`. `--many-tools N` adds N generated tools. With `--close-stdout`, the server closes its stdout and continues to run.
- Repository: the transcript tests of the `vscode` bridge in `bridges/vscode/test/`. They check each frame of the bridge against the schema of revision 2025-11-25 and each upstream request against the schema of revision 2026-07-28.
- Repository: the process tests in `test/process_test.zig`, as a part of `zig build test`. They start `mcp-bridge-vscode` and `bridge-fixture-server` and examine the frames, the exit codes, the stderr lines and the stop of the child process.
- Repository: the fuzz targets in `src/bridge/fuzz_test.zig`.
- Repository: the MCP schemas of revisions 2025-11-25 and 2026-07-28 in `test/fixtures/`, from the upstream commit `046fa30efd374370afb87ef830bd788eac5f217e`, with the upstream `LICENSE` and an `UPSTREAM.zon` file. A test compiles each schema with the validator of zig-sdk.
- Repository: the build steps `test`, `test-vscode`, `fixture-server`, `run-vscode` and `fmt`, and the option `-Dfuzz` for `zig build test -Dfuzz --fuzz`.
- Repository: the tools `lint-docs`, `commit-policy`, `check-version`, `changelog-section` and `gen-dictionary`, with their build steps. `lint-docs` comes from zig-sdk, with the paths and the wiki of this repository.
- Repository: the `commit-msg` hook in `.githooks/`.
- Repository: the project profile of ASD-STE100 in `docs/style/ste-profile.md` and the project dictionary in `docs/dictionary/`. The dictionary has the abbreviation `VS` and the synonyms `vscode` and `vsc` of VS Code. `gen-dictionary` writes the dictionary as one page to `docs/generated/dictionary.md`.
- Repository: the action `setup-zig` with the pinned Zig 0.16.0. The CI workflow has the jobs `fmt-lint`, `commit-policy`, `test`, `cross`, `interop` and `consumer`. The `fmt-lint` job also checks that the dictionary page is current.
- Repository: the CI job `interop`. A legacy client of the TypeScript SDK 1.32.1 connects to the bridge over stdio and checks each tool schema with Ajv 8.20.0. `.github/interop/` has the client and the lockfile.
- Repository: the release workflow. A release publishes notes only, because the distribution is source only.
- Repository: the nightly workflow with the jobs `wiki-lint` and `fuzz`. The `fuzz` job runs the fuzz targets each night. It fails when a fuzz target crashed.
- Repository: the Dependabot configuration. Dependabot checks the GitHub Actions and the npm packages of `.github/interop/` each week.
- Repository: the consumer example in `examples/consumer/`, as a stub. It uses the package from a tarball of the commit, as a fetched dependency.
- Repository: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `VERSIONING.md`, `CODE_OF_CONDUCT.md`, `CLAUDE.md`, `AGENTS.md`, `NOTICE`, `THIRD_PARTY_LICENSES.md`, the pull request template and `CODEOWNERS`. `CONTRIBUTING.md` has the recipe for the Linux tests in WSL and the wake rule for accept loops. `VERSIONING.md` has the rules for the zig-sdk pin.
- Repository: the trademark notice for Visual Studio Code in `README.md`, `bridges/vscode/README.md` and the doc comment of `bridges/vscode/vscode.zig`.

[Unreleased]: https://github.com/ChristianPresley/zig-bridge-sdk/commits/main
