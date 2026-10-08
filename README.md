# zig-bridge-sdk

Bridges for the Model Context Protocol (MCP) in Zig.

A bridge connects an MCP client of revision 2025-11-25 to an MCP server of revision 2026-07-28.[^mcp-2025][^mcp-2026] The bridge speaks the earlier revision to the client. On the side of the server, the bridge always uses the client of zig-sdk, the MCP SDK for Zig.[^zig-sdk] Thus a client that cannot speak revision 2026-07-28 can use a server that you build with zig-sdk.

## Status

The project is in development. Milestones M0 to M5 of the `vscode` bridge are complete. The bridge starts the upstream command and speaks to it over stdio. It can also connect to an upstream server at an HTTPS URL over Streamable HTTP.

The bridge answers `initialize`, and it forwards the requests for tools, prompts, resources and completion. It also forwards the progress notifications of the upstream server and the cancellations of the client. When the upstream server asks for input, the bridge sends each input request to the client and sends the answers to the upstream server.

The bridge also sends the list changes, the resource updates and the log messages of the upstream server to the client. When the upstream server declares them, the bridge keeps a listen stream open for the list changes and the resource updates. The log messages come with the requests. The client can subscribe to a resource and set the log level. The trace context and the `vscode.` keys in the `_meta` of the client go to the upstream server.

When an upstream server at a URL asks for a sign-in, the bridge signs in at its authorization server with OAuth. The first sign-in opens the browser during `initialize`. For a later sign-in, the client gets a URL elicitation. The bridge keeps the tokens in the keychain of the host, in encrypted files or in memory. `mcp-bridge-vscode logout` deletes a stored sign-in.

A zig-sdk server can also put the bridge into its own executable with `vscode.serveStdio`. The first request of the client then selects revision 2025-11-25 or revision 2026-07-28. The section [The bridge in a zig-sdk server](#the-bridge-in-a-zig-sdk-server) gives the steps.

The [Roadmap](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Roadmap) on the wiki shows the milestones, the state of each part and the planned work. `CHANGELOG.md` lists the changes.

## The bridges

The first bridge is for Visual Studio Code (VS Code).

| Bridge | Product | Client revision | Executable | Status |
| --- | --- | --- | --- | --- |
| `vscode` | Visual Studio Code | 2025-11-25 | `mcp-bridge-vscode` | M5: runtime, input requests, notifications, an HTTPS upstream server with OAuth, and `vscode.serveStdio` |

Each bridge has its own README. [`bridges/vscode/README.md`](bridges/vscode/README.md) tells how to build the `vscode` bridge and how to configure VS Code.

## Why a bridge is necessary

VS Code has two MCP clients. The Local harness operates the MCP user interface of VS Code. It speaks only revision 2025-11-25, and it starts each connection with `initialize`. A server of zig-sdk speaks only revision 2026-07-28. On stdio, it answers `initialize` with error -32601. Thus the Local harness cannot use a server of zig-sdk without a bridge.

The Copilot harness first sends `server/discover`, so it can list and call the tools of a server of zig-sdk. But it has no support for multi round-trip requests, so a tool that asks for input cannot complete. `bridges/vscode/README.md` gives the details. The issue `microsoft/vscode#329848` records the request for revision 2026-07-28 in VS Code, and it is open.[^vscode-issue]

## The package model

The package `bridge_sdk` has one bridge for each product. The key of a bridge is the name of its product. For the key `vscode`, the package has these parts:

- The module `vscode` in `bridges/vscode/vscode.zig`. It declares the settings of the product as a `bridge.Profile`.
- The executable `mcp-bridge-vscode` from `bridges/vscode/main.zig`.

The module `bridge` in `src/bridge.zig` is the core that all bridges use. The package also exports the `mcp` module of the pinned zig-sdk. The wiki page [Package Model](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Package-Model) gives the steps to add a bridge for a product and the rules for embedders.

### Use the `mcp` module of the package

If your package uses the `mcp` module and a bridge module, the two must use the same `mcp` module. Do one of these steps:

- Get `mcp` from this package: `b.dependency("bridge_sdk", .{ .target = target, .optimize = optimize }).module("mcp")` in `build.zig`, or `@import("vscode").mcp` in your source code.
- Pin the zig-sdk commit and hash of the `build.zig.zon` of this package. Give `b.dependency` the same `.target` and `.optimize` arguments for zig-sdk and for `bridge_sdk`.

When the two `mcp` modules are not the same, Zig shows an error. The [table of errors](#troubleshooting) gives the cause of each error.

## The bridge in a zig-sdk server

If you write your server with zig-sdk, you do not need the separate executable. Call `vscode.serveStdio` in place of `mcp.transport.stdio.serve`. Then your executable serves the two harnesses of VS Code and each client of revision 2026-07-28 on stdio. The first request of the client selects the path:

- `initialize` selects the bridge. Its upstream server is your server in the same process.
- Each other request selects the stdio transport of zig-sdk, without the bridge.
- A `server/discover` before the first other request selects no path.

In `build.zig`, take the modules `vscode` and `mcp` from this package:

```zig
const dep = b.dependency("bridge_sdk", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("vscode", dep.module("vscode"));
exe.root_module.addImport("mcp", dep.module("mcp"));
```

Do not pin zig-sdk a second time for `mcp`. `vscode.serveStdio` takes the `mcp.Server` of this package, and a second pin gives a different type. The section [Use the `mcp` module of the package](#use-the-mcp-module-of-the-package) gives the rule.

In your source code, give your server to `vscode.serveStdio`:

```zig
var server = try mcp.Server.init(gpa, io, .{ .info = .{ .name = "my-server", .version = "1.0.0" } });
defer server.deinit();
// Add the tools, the prompts and the resources here.
try vscode.serveStdio(io, gpa, &server, .{});
```

[`bridges/vscode/README.md`](bridges/vscode/README.md#the-bridge-in-a-zig-sdk-server) gives the limits and the behavior of the Copilot harness. The example in `examples/consumer/` is a complete program.

## Requirements

- Zig 0.16.0. The package sets `minimum_zig_version` to this version.
- zig-sdk, the only dependency. `build.zig.zon` pins it with a commit and a hash, and `zig build` fetches it.

## Build

The project gives the source only. It does not publish executables. Build the executables with this command:

```bash
zig build -Doptimize=ReleaseSafe
```

The result is `zig-out/bin/mcp-bridge-vscode`, or `zig-out/bin/mcp-bridge-vscode.exe` on Windows. The usage has these forms:

```
mcp-bridge-vscode [options] -- <command> [args...]
mcp-bridge-vscode [options] <url>
mcp-bridge-vscode logout [--account <label>] <url>
mcp-bridge-vscode logout --all
```

[`bridges/vscode/README.md`](bridges/vscode/README.md) gives the options and the configuration of VS Code.

## Test

```bash
zig build test --test-timeout 10m
```

Always give `--test-timeout 10m`. `CONTRIBUTING.md` tells why. `zig build test` also runs the transcript tests, the process tests, the tests of the HTTPS mode of `bridge-fixture-server` and the test of the files in `site/`. The process tests start the three executables `mcp-bridge-vscode`, `bridge-fixture-server` and `bridge-embedded-server`.

The CI job `interop` connects a client of the TypeScript SDK to the bridge. To run it on your computer, you need Node.js. Run these commands in the root of the repository:

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

The first script also starts `bridge-embedded-server`, which has the bridge in its process. The second script starts `bridge-fixture-server` in its HTTPS mode with the test CA, and it signs in as a browser does.

Other build steps: `test-vscode`, `fixture-server`, `embedded-server`, `run-vscode`, `fmt`, `lint-docs`, `commit-policy`, `gen-dictionary`, `check-version` and `changelog-section`. The option `-Dfuzz` prepares the tests for `zig build test -Dfuzz --fuzz` (not on Windows).

## Troubleshooting

If your package does not use the `mcp` module of this package, Zig 0.16.0 can show these errors:

| Error | Cause |
| --- | --- |
| `expected type '*mcp.server.Server', found '*mcp.server.Server'` | Your package has a second zig-sdk, for example from a different commit. The types of the two `mcp` modules are then different. The error can also name a different type of `mcp`. |
| `file exists in modules 'mcp' and 'mcp0'` | Your package pins the same zig-sdk, but it gives `b.dependency` different arguments, for example no `.target` or no `.optimize`. Zig then makes two `mcp` modules from the same files. |

To correct the error, use the `mcp` module of this package. The section [Use the `mcp` module of the package](#use-the-mcp-module-of-the-package) gives the steps.

## Compatibility

Each release of zig-bridge-sdk pins one release of zig-sdk. `VERSIONING.md` gives the rules.

| zig-bridge-sdk | zig-sdk | zig-sdk commit |
| --- | --- | --- |
| 0.0.0 (no release) | 0.4.0 (`v0.4.0`) | `8334b1501644c9f8e1f65f7e24b1ef86b335093f` |

Milestones M3 to M5 need the changes of zig-sdk 0.4.0. The pin is the commit `8334b15` of the tag `v0.4.0` of zig-sdk.

## Documentation

The wiki holds the plan and the design.[^wiki] Start with these pages:

- [Roadmap](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Roadmap): the plan of record, the milestones and the open items.
- [Threat-Model](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Threat-Model): the trust boundaries and the security requirements of each milestone.

All prose in this repository uses ASD-STE100 Simplified Technical English, customized for this project.[^ste] The profile is in `docs/style/ste-profile.md`. `zig build lint-docs` checks the prose.

## Trademarks

Visual Studio Code and VS Code are trademarks of Microsoft Corporation. This project has no affiliation with Microsoft, and Microsoft does not endorse it.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`. The file `THIRD_PARTY_LICENSES.md` lists the third-party material.

[^mcp-2025]: Model Context Protocol Specification 2025-11-25. https://modelcontextprotocol.io/specification/2025-11-25
[^mcp-2026]: Model Context Protocol Specification 2026-07-28. https://modelcontextprotocol.io/specification/2026-07-28
[^zig-sdk]: zig-sdk, the unofficial Zig SDK for the Model Context Protocol. https://github.com/ChristianPresley/zig-sdk
[^vscode-issue]: microsoft/vscode issue 329848. https://github.com/microsoft/vscode/issues/329848
[^wiki]: zig-bridge-sdk wiki. https://github.com/ChristianPresley/zig-bridge-sdk/wiki
[^ste]: ASD-STE100 Simplified Technical English, Issue 9. https://www.asd-ste100.org/
