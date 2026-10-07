# `mcp-bridge-vscode`: MCP bridge for Visual Studio Code

`mcp-bridge-vscode` is a bridge between Visual Studio Code (VS Code) and an MCP server of specification revision 2026-07-28.[^mcp-2026] The MCP clients of VS Code speak revision 2025-11-25.[^mcp-2025] The bridge is a stdio server for VS Code. It starts the upstream server as a child process and connects to it with the `mcp.Client` of zig-sdk.

This version is milestone M1, the runtime. The input requests of the upstream server arrive in M2. The [Status](#status) section tells what each milestone adds.

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

This is milestone M1. The bridge starts the upstream command and speaks to it over stdio. It answers `initialize`, and it forwards the requests for tools, prompts, resources and completion. It also forwards the progress notifications of the upstream server and the cancellations of VS Code.

A tool that asks for input gets an error until M2. Until M3, the `initialize` result does not announce list changes, resource subscriptions or log messages. The section [Options](#options) gives the command line.

The [Roadmap](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Roadmap) on the wiki is the plan of record. Each milestone adds these parts:

| Milestone | What it adds |
| --- | --- |
| M1 | The runtime: the bridge starts the upstream server, answers `initialize`, and forwards the requests and the results with the translation rules. It also forwards the progress notifications and the cancellations. It adds the error table, the timeouts and the options of the command line. |
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

## Options

The usage is:

```
mcp-bridge-vscode [options] -- <command> [args...]
```

The options of the bridge come before `--`. The bridge does not examine the arguments after `--`. They go to the upstream command without a change.

| Option | What it does | Default |
| --- | --- | --- |
| `--name <name>` | The server name for VS Code when the upstream server sends no name. VS Code makes the ids of the tools and the keys of the tool approvals from this name. | The file name of `<command>` without its extension |
| `--log-level <level>` | The level of the log lines on stderr: `err`, `warn`, `info` or `debug`. | `info` |
| `--discover-timeout <s>` | The time in seconds for the answer of the upstream server to `server/discover`. After this time, VS Code gets an error for `initialize`. | 60 |
| `--max-line-bytes <n>` | The maximum length of one message in bytes, from 1 to 1073741824 (1 GiB). The limit applies to the messages of VS Code and of the upstream server. | 67108864 (64 MiB) |
| `--help` | Show the usage on stdout. | |
| `--version` | Show the version on stdout. | |

VS Code has no limit for the length of a message. A message of VS Code that is longer than `--max-line-bytes` gets the error -32600 with the id of the request. The bridge cannot read a response of the upstream server that is longer than the limit. The request then gets -32603 at the end of its time limit.

Each forwarded request has a time limit. The limit is 120 s for the list requests, `completion/complete`, `prompts/get` and `resources/read`, and 1 h for `tools/call`.

The exit code of the bridge tells why it stopped:

| Exit code | Cause |
| --- | --- |
| 0 | Stdin ended: VS Code closed the connection. |
| 1 | The upstream server stopped, or the bridge has an internal error. |
| 2 | The arguments are not valid. The bridge writes the cause and the usage to stderr. |

At the end of stdin, the bridge cancels the requests in flight and stops the upstream server. A watchdog stops the bridge and the process tree of the upstream server 8 s after the end of stdin.

## Configuration

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

The upstream server gets the environment of the bridge. VS Code 1.140 marks `.vscode/mcp.json` as deprecated when you add a server, but it continues to read the file. Only this file has password inputs for secrets.

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

VS Code writes the messages of each MCP server to an Output channel. The channel also shows the stderr lines of the bridge and of the upstream server. VS Code writes each stderr line at the Warning level. Each line of the bridge has the form `mcp-bridge-vscode: <scope>: <level>: <text>`. A line without this start comes from the upstream server.

1. Open the Output channel of the server: run **MCP: List Servers**, select the server, then select **Show Output**.
2. To see more lines, set the level of the channel to Debug or Trace in the Output view. At the Debug level, VS Code writes each JSON-RPC message that it sends and receives.
3. As an alternative to step 2, add `"dev": {}` to the server entry. Then VS Code writes the JSON-RPC messages at the Info level. It also opens the channel when the server starts.
4. Add `--log-level debug` before the `--` in `args`. Then the bridge also writes its debug lines:

   ```json
   "args": ["--log-level", "debug", "--", "/abs/path/your-server"]
   ```

These messages can occur in the channel:

| Message | What it means |
| --- | --- |
| `` Waiting for server to respond to `initialize` request... `` | VS Code sent `initialize` and has no response yet. The bridge responds after the upstream server answers `server/discover`. After the time of `--discover-timeout` (60 s), the bridge responds with an error. If the message stays, examine the stderr lines of the upstream server. |
| `mcp-bridge-vscode: bridge: warning: cannot start the upstream command: <error>` | The bridge cannot start `<command>`, and VS Code gets an error for `initialize`. Examine the path of the command in `args`. |
| `mcp-bridge-vscode: bridge: warning: server/discover failed: <error>` | The upstream server did not answer `server/discover`, or it answered with an error. VS Code gets an error for `initialize`. |
| `mcp-bridge-vscode: bridge: info: still waiting for the upstream server: <method> (request <id>, <N> s)` | The upstream server did not answer the request in 10 s. The line comes again each 30 s until the response or the time limit. |
| `mcp-bridge-vscode: bridge: info: tool '<name>': added an items schema at '<pointer>' of the input schema` | An array schema of the tool had no `items`, or its `items` was false in JavaScript. The bridge added `items: {}`, so that VS Code shows the tool. |
| `mcp-bridge-vscode: bridge: error: the upstream server exited with code N` | The upstream server stopped while VS Code was connected. The bridge answered each request in flight with -32603, and it exits with code 1. The lines before this line can tell the cause. On POSIX, the line can also tell the signal that stopped the upstream server. |
| `mcp-bridge-vscode: vscode: warning: the bridge did not stop in 8 s after the end of stdin, thus it stops now` | A request did not stop after its cancellation. The watchdog stopped the bridge and the upstream server. |
| `Process exited with code N` | The bridge stopped. Code 1 means that the upstream server stopped, or that the bridge has an internal error. Code 2 means that the arguments are not valid. VS Code starts the bridge again at the next tool call. |
| `N tools have invalid JSON schemas and will be omitted` | VS Code checks the input schema of each tool against JSON Schema draft-07. It does not show the tools that fail, and a notification names the server. Correct the schemas in the upstream server. |
| `MPC <code>: <message>` | The server sent an error response. VS Code writes "MPC" in place of "MCP". The next table gives the messages of the bridge. A different message comes from the upstream server. |

The bridge sends these error messages. Each error also has `data.cause`. The table shows the start of each message:

| Message | What it means |
| --- | --- |
| `MPC <code>: The upstream server did not answer server/discover. ...` | The upstream server did not answer `server/discover` in the time of `--discover-timeout`, or it answered with an error. It is not a server of revision 2026-07-28, or it does not respond. A server of an earlier revision answers with -32601. The bridge stays open, and VS Code can send `initialize` again. |
| `MPC -32603: The bridge cannot start the upstream server. ...` | The bridge cannot start `<command>`. Examine the path of the command in `args`. |
| `MPC -32603: The upstream server process stopped. ...` | The upstream server stopped, or it closed its stdout. |
| `MPC -32603: The upstream server did not answer in time. ...` | The request did not get a response in its time limit. `data.detail` gives the method and the limit. |
| `MPC -32603: The upstream server needs input that this version of the bridge cannot ask for yet.` | The tool asked for input: an elicitation, a sampling or the roots. M2 adds this function. |
| `MPC -32603: The connection has too many requests in flight` | VS Code sent a new request at the limit of requests in flight. |
| `MPC -32600: The request is longer than the line limit of the bridge.` | The message of VS Code is longer than `--max-line-bytes`. |

## License

Apache License 2.0. See [`LICENSE`](../../LICENSE).

[^mcp-2025]: Model Context Protocol Specification 2025-11-25. https://modelcontextprotocol.io/specification/2025-11-25
[^mcp-2026]: Model Context Protocol Specification 2026-07-28. https://modelcontextprotocol.io/specification/2026-07-28
[^copilot-mrtr]: github/copilot-cli issue 4834. https://github.com/github/copilot-cli/issues/4834
[^vscode-2026]: microsoft/vscode issue 329848. https://github.com/microsoft/vscode/issues/329848
