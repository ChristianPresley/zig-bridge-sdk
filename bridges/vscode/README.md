# `mcp-bridge-vscode`: MCP bridge for Visual Studio Code

`mcp-bridge-vscode` is a bridge between Visual Studio Code (VS Code) and an MCP server of specification revision 2026-07-28.[^mcp-2026] The MCP clients of VS Code speak revision 2025-11-25.[^mcp-2025] The bridge is a stdio server for VS Code. It will start the upstream server as a child process and connect to it with the `mcp.Client` of zig-sdk.

This version is milestone M0, the scaffold. The runtime of the bridge arrives in M1. The [Status](#status) section tells what each milestone adds.

Visual Studio Code and VS Code are trademarks of Microsoft Corporation. This project has no affiliation with Microsoft, and Microsoft does not endorse it.

## Why VS Code needs a bridge

VS Code 1.140 has two MCP clients: the Local harness and the Copilot harness.

- The Local harness operates the MCP user interface of VS Code: the server list, the prompts, the resources and the Output channel. It speaks only revision 2025-11-25 and starts each connection with an `initialize` request. A zig-sdk server answers `initialize` with the error -32601 (method not found), so the Local harness cannot use it.
- The Copilot harness first sends `server/discover`. When the server answers with -32601, the harness sends `initialize` instead. It has no support for multi round-trip requests (MRTR).[^copilot-mrtr] It can list and call the tools of a 2026-07-28 server, but a tool that asks for input cannot complete.

VS Code marks the Local harness for removal in a future release. Until VS Code speaks revision 2026-07-28,[^vscode-2026] the bridge gives the two harnesses a server of revision 2025-11-25:

- The bridge answers `initialize` and translates each request to revision 2026-07-28 (M1).
- The bridge answers `server/discover` with -32601 at once, so that the Copilot harness sends `initialize` (M1).
- For a tool that needs input, the bridge completes the MRTR rounds with the upstream server. It sends each input request to VS Code as an elicitation, sampling or roots request of revision 2025-11-25 (M2).

## Status

This is milestone M0. The `mcp-bridge-vscode` executable builds, but it cannot connect to a server yet. It shows its usage (`--help`) and its version (`--version`). For all other arguments, it writes a message to stderr and exits with code 2.

The [Roadmap](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Roadmap) on the wiki is the plan of record. Each milestone adds these parts:

| Milestone | What it adds |
| --- | --- |
| M1 | The runtime: the bridge starts the upstream server, answers `initialize`, and forwards the requests and the results with the translation rules. It also adds the error table, the timeouts and the `--log-level` option. |
| M2 | Input requests: the bridge sends the elicitation, sampling and roots requests of the upstream server to VS Code, and forwards the answers. |
| M3 | Notifications of list changes, resource subscriptions, the log level and the `_meta` keys of VS Code. M3 needs zig-sdk v0.4.0. |
| M4 | An upstream server at an HTTPS URL, with OAuth sign-in and token storage. |
| M5 | An API that puts the bridge into a zig-sdk server, so that one executable serves the two revisions. |

From M1, the two harnesses can list and call the tools of the upstream server. From M2, they can also complete the tools that need input.

## Build and install

You need Zig 0.16.0. The project gives source code only, without prebuilt executables. The first build fetches zig-sdk v0.3.0, the only dependency, from GitHub.

1. Get the source code:

   ```bash
   git clone https://github.com/ChristianPresley/zig-bridge-sdk
   cd zig-bridge-sdk
   ```

2. Build the bridge:

   ```bash
   zig build -Doptimize=ReleaseSafe
   ```

3. Find the executable at `zig-out/bin/mcp-bridge-vscode`. On Windows, the name is `mcp-bridge-vscode.exe`.
4. Copy the executable to a directory that you keep. Write its absolute path in the configuration.
5. Make sure that it starts: run `mcp-bridge-vscode --version`.

If you write your server with zig-sdk, the API of M5 (planned) will put the bridge into your server executable. Then you will not need a separate bridge process.

### Remote windows

A remote window of VS Code connects to a host over Secure Shell, to WSL or to a dev container. In such a window, a server of the workspace configuration or of the remote user configuration runs on the remote host. A server of the local user configuration runs on the local computer.

For a server on the remote host, put the bridge and the upstream server on that host. Build the bridge for the target of the host, for example:

```bash
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
```

VS Code for the Web cannot start stdio servers. The bridge does not operate there.

## Configuration

The examples in this section work from M1. The M0 executable exits with code 2.

### The file `.vscode/mcp.json`

This file is the primary configuration of VS Code. Put the entry in `.vscode/mcp.json` of the workspace, or in the user configuration (**MCP: Open User Configuration**):

```json
{
  "servers": {
    "demo": {
      "type": "stdio",
      "command": "/abs/path/mcp-bridge-vscode",
      "args": ["--", "/abs/path/your-server", "--its-args"]
    }
  }
}
```

The `--` separates the options of the bridge from the command of the upstream server. The bridge starts that command and speaks revision 2026-07-28 to it over stdio. Write absolute paths. In this file, you can also use the variables of VS Code, such as `${workspaceFolder}`. On Windows, write each backslash two times, for example `"C:\\tools\\mcp-bridge-vscode.exe"`.

VS Code writes the full command line to the Output channel at the Debug level. Do not write a secret in `args`. Give a secret to the upstream server in an environment variable from a password input:

```json
{
  "inputs": [
    { "type": "promptString", "id": "api-key", "description": "API key", "password": true }
  ],
  "servers": {
    "demo": {
      "type": "stdio",
      "command": "/abs/path/mcp-bridge-vscode",
      "args": ["--", "/abs/path/your-server"],
      "env": { "API_KEY": "${input:api-key}" }
    }
  }
}
```

The upstream server gets the environment of the bridge (M1). VS Code 1.140 marks `.vscode/mcp.json` as deprecated when you add a server, but it continues to read the file. Only this file has password inputs for secrets.

### Other configuration files (VS Code 1.140 and later)

VS Code 1.140 also reads these files:

| File | Key of the servers | Variables |
| --- | --- | --- |
| `.mcp.json` in the root of the workspace | `mcpServers` | No `${...}` variables and no inputs. Write absolute paths. |
| `$COPILOT_HOME/mcp-config.json` | `mcpServers` | No `${input:...}` variables. |

```json
{
  "mcpServers": {
    "demo": {
      "type": "stdio",
      "command": "/abs/path/mcp-bridge-vscode",
      "args": ["--", "/abs/path/your-server", "--its-args"]
    }
  }
}
```

The `copilot` command line tool and the Copilot harness also read these files. Never write a secret in a `.mcp.json` file that you commit to a repository.

The Copilot harness does not get the entries of `.vscode/mcp.json` that use `${input:...}` or `${command:...}`.

### Planned forms

- The URL form (M4): `mcp-bridge-vscode <https-url>` will connect to an upstream server over HTTPS, with OAuth sign-in. The secret values of HTTP headers will come from environment variables, not from `args`.
- The API of M5: a zig-sdk server will serve the two revisions in one process, without the separate executable.

## Troubleshooting

VS Code writes the messages of each MCP server to an Output channel. The channel also shows the stderr lines of the bridge and, from M1, of the upstream server. VS Code writes each stderr line at the Warning level.

1. Open the Output channel of the server: run **MCP: List Servers**, select the server, then select **Show Output**.
2. To see more lines, set the level of the channel to Debug or Trace in the Output view. At the Debug level, VS Code writes each JSON-RPC message that it sends and receives.
3. As an alternative to step 2, add `"dev": {}` to the server entry. Then VS Code writes the JSON-RPC messages at the Info level. It also opens the channel when the server starts.
4. From M1, add `--log-level debug` before the `--` in `args`. Then the bridge also writes its debug lines:

   ```json
   "args": ["--log-level", "debug", "--", "/abs/path/your-server"]
   ```

These messages can occur in the channel:

| Message | What it means |
| --- | --- |
| `mcp-bridge-vscode: this version cannot connect to a server yet` | This is the M0 scaffold. Build a version with the runtime (M1 or later). |
| `` Waiting for server to respond to `initialize` request... `` | VS Code sent `initialize` and has no response yet. From M1, the bridge responds after the upstream server answers `server/discover`. If the message stays, examine the stderr lines of the upstream server. |
| `Process exited with code N` | The bridge stopped. Code 2 means bad arguments. The M0 scaffold exits with code 2 for all arguments other than `--help` and `--version`. From M1, code 1 means an internal failure, or the upstream server stopped. VS Code starts the bridge again at the next tool call. |
| `N tools have invalid JSON schemas and will be omitted` | VS Code checks the input schema of each tool against JSON Schema draft-07. It does not show the tools that fail, and a notification names the server. Correct the schemas in the upstream server. |
| `MPC <code>: <message>` | The server sent an error response. VS Code writes "MPC" in place of "MCP". From M1, the error table of the bridge gives the code and the message. |

## License

Apache License 2.0. See [`LICENSE`](../../LICENSE).

[^mcp-2025]: Model Context Protocol Specification 2025-11-25. https://modelcontextprotocol.io/specification/2025-11-25
[^mcp-2026]: Model Context Protocol Specification 2026-07-28. https://modelcontextprotocol.io/specification/2026-07-28
[^copilot-mrtr]: github/copilot-cli issue 4834. https://github.com/github/copilot-cli/issues/4834
[^vscode-2026]: microsoft/vscode issue 329848. https://github.com/microsoft/vscode/issues/329848
