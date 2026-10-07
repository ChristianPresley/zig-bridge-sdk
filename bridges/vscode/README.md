# `mcp-bridge-vscode`: MCP bridge for Visual Studio Code

`mcp-bridge-vscode` is a bridge between Visual Studio Code (VS Code) and an MCP server of specification revision 2026-07-28.[^mcp-2026] The MCP clients of VS Code speak revision 2025-11-25.[^mcp-2025] The bridge is a stdio server for VS Code. It starts the upstream server as a child process and connects to it with the `mcp.Client` of zig-sdk.

This version is milestone M3. The bridge sends the input requests, the list changes, the resource updates and the log messages of the upstream server to VS Code. The [Status](#status) section tells what each milestone adds.

Visual Studio Code and VS Code are trademarks of Microsoft Corporation. This project has no affiliation with Microsoft, and Microsoft does not endorse it.

## Why VS Code needs a bridge

VS Code 1.140 has two MCP clients: the Local harness and the Copilot harness.

- The Local harness operates the MCP user interface of VS Code: the server list, the prompts, the resources and the Output channel. It speaks only revision 2025-11-25 and starts each connection with an `initialize` request. A zig-sdk server answers `initialize` with the error -32601 (method not found), so the Local harness cannot use it.
- The Copilot harness first sends `server/discover`. When the server answers with -32601, the harness sends `initialize` instead. It has no support for multi round-trip requests (MRTR).[^copilot-mrtr] It can list and call the tools of a 2026-07-28 server, but a tool that asks for input cannot complete.

VS Code marks the Local harness for removal in a future release. Until VS Code speaks revision 2026-07-28,[^vscode-2026] the bridge gives the two harnesses a server of revision 2025-11-25:

- The bridge answers `initialize` and translates each request to revision 2026-07-28 (M1).
- The bridge answers `server/discover` with -32601 at once, so that the Copilot harness sends `initialize` (M1).
- For a tool that needs input, the bridge completes the MRTR rounds with the upstream server. It sends each input request to VS Code as an elicitation, sampling or roots request of revision 2025-11-25 (M2).
- Revision 2026-07-28 sends the list changes and the resource updates on a listen stream. The bridge keeps a listen stream open, and it sends these notifications to VS Code as revision 2025-11-25 does (M3).

## Status

This is milestone M3. The bridge starts the upstream command and speaks to it over stdio. It answers `initialize`, and it forwards the requests for tools, prompts, resources and completion. It also forwards the progress notifications of the upstream server and the cancellations of VS Code. When a tool, a prompt or a resource needs input, the bridge asks VS Code. The section [Input requests](#input-requests) gives the rules.

The bridge sends the list changes, the resource updates and the log messages of the upstream server to VS Code. It also sends the trace context of VS Code to the upstream server. The section [Notifications](#notifications) gives the rules. The section [Options](#options) gives the command line.

The [Roadmap](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Roadmap) on the wiki is the plan of record. Each milestone adds these parts:

| Milestone | What it adds |
| --- | --- |
| M1 | The runtime: the bridge starts the upstream server, answers `initialize`, and forwards the requests and the results with the translation rules. It also forwards the progress notifications and the cancellations. It adds the error table, the timeouts and the options of the command line. |
| M2 | Input requests: the bridge sends the elicitation, sampling and roots requests of the upstream server to VS Code, and forwards the answers. |
| M3 | Notifications of list changes, resource subscriptions, the log level and the `_meta` keys of VS Code. M3 needs zig-sdk v0.4.0. |
| M4 | An upstream server at an HTTPS URL, with OAuth sign-in and token storage. |
| M5 | An API that puts the bridge into a zig-sdk server, so that one executable serves the two revisions. |

From M1, the two harnesses can list and call the tools of the upstream server. From M2, they can also complete the tools that need input. From M3, the Local harness lists the tools again after a call that changes them, before the next turn of the same chat request. An editor of a resource also shows the changes of the resource. The Copilot harness has no manual check of this yet.

## Build and install

You need Zig 0.16.0. The project gives source code only, without prebuilt executables. The first build fetches zig-sdk, the only dependency, from GitHub. `build.zig.zon` pins a commit of zig-sdk 0.4.0 before its release.

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

VS Code has no limit for the length of a message. A message of VS Code that is longer than `--max-line-bytes` gets the error -32600 with the id of the request. The bridge cannot read a response of the upstream server that is longer than the limit. The request then gets -32603 at once.

Each forwarded request has a time limit. The limit is 120 s for the list requests, `completion/complete`, `prompts/get` and `resources/read`, and 1 h for `tools/call`. The answers of VS Code to the input requests of one round have a limit of 1 h. After the first round, each round of `prompts/get` and `resources/read` also has a limit of 1 h.

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

## Input requests

A server of revision 2026-07-28 asks for input with a result of the type `input_required`. That result has one or more input requests. The bridge sends each input request to VS Code as a request of revision 2025-11-25, with an id such as `b-1`. It sends all input requests of one round at one time. When VS Code answers all of them, the bridge sends the upstream request again with the answers. The next result can ask for more input, or it can be the result for VS Code.

| Input request | Request to VS Code | What VS Code does |
| --- | --- | --- |
| A form | `elicitation/create` with `mode: "form"` | It shows the questions of the form to the user. |
| A URL | `elicitation/create` with `mode: "url"` | It shows the URL, and the user can open it in the web browser. |
| Sampling | `sampling/createMessage` | It asks the user for consent, then it sends the messages to a language model. |
| Roots | `roots/list` | It gives the folders of the workspace. |

The bridge declares to the upstream server the input kinds that VS Code declares. The Copilot harness declares no roots. Before VS Code gets an input request, the bridge examines it:

- VS Code must declare the kind of the input request.
- VS Code declares no `sampling.tools`. Thus a sampling request with tools fails.
- One round has at most 16 input requests.
- VS Code gets a URL only with the scheme `https`, or with the scheme `http` and a loopback host (`localhost`, an address in `127.0.0.0/8`, or `[::1]`). VS Code can also open other schemes, such as `file:`, `vscode:` and `command:`. For such a URL, the upstream server gets the answer decline, and the bridge writes a warning.
- A URL with a backslash, or an `http` URL with user information before the host, also gets decline. The web browser can find a different host in such a URL.
- VS Code cannot show a form without a property, for example a confirmation. For such a form, VS Code gets a form with the message of the server and one choice, Continue. When the user accepts, the upstream server gets accept with empty content.

When a check fails, the request of VS Code gets the error -32603, and VS Code gets no request of that round. The `data.detail` of the error names the key of the input request.

The bridge also examines the answers of VS Code:

- The accepted content of a form must be valid against the schema of the form. VS Code does not examine it. Content that is not valid gives the error -32603.
- The upstream server gets only the roots with a `file://` URI.
- An answer to a URL never has content. An answer that declines or cancels never has content.
- When VS Code answers an elicitation with an error, the upstream server gets the answer cancel. When VS Code answers a sampling or roots request with an error, the original request gets that error. VS Code refuses a sampling request with the error -32000.

These rules apply across the rounds of one request:

- A URL request has an `elicitationId`. After the user accepts the URL, VS Code gets `notifications/elicitation/complete` when the upstream server does not ask for the URL again. VS Code also gets it when the request ends with an error or a cancellation. Then VS Code hides the URL in the chat.
- A server can ask for an accepted URL again in the next round. It does so when it has no result of the step in the web browser yet. VS Code then does not show the URL again. It shows a form with one choice, Continue. Select Continue after you complete the step in the web browser.
- One request has at most 10 rounds.
- The upstream server keeps the state of the request for a time limit, 600 s for a zig-sdk server. It refuses an answer that comes after this limit. Then a tool call gets a result with an error text that tells you to run the tool again. Another request gets an error with the same text.

VS Code ignores the cancellation of a request of the bridge. When you stop a request in the chat, a question of the bridge can stay open. The bridge ignores a late answer.

## Notifications

Revision 2025-11-25 sends the notifications of a server on the connection. Revision 2026-07-28 sends them on a `subscriptions/listen` stream, which the client opens. The bridge opens this stream for VS Code. VS Code then gets the notifications as revision 2025-11-25 sends them.

The `initialize` result declares a notification only when the upstream server declares it:

| Capability in the `initialize` result | What VS Code gets |
| --- | --- |
| `tools.listChanged`, `prompts.listChanged`, `resources.listChanged` | `notifications/tools/list_changed`, `notifications/prompts/list_changed` and `notifications/resources/list_changed`. VS Code then lists the tools, the prompts or the resources again. |
| `resources.subscribe` | `resources/subscribe` and `resources/unsubscribe` operate. VS Code gets `notifications/resources/updated` for each subscribed resource that changes. |
| `logging` | `notifications/message` at the level of `logging/setLevel` and above. |

When the upstream server declares no list change and no subscription, the bridge opens no listen stream. Then `resources/subscribe` and `resources/unsubscribe` get the error -32601.

### The listen stream

The bridge opens the listen stream after `notifications/initialized` of VS Code. The stream asks for the list changes that the `initialize` result declares, and for the subscribed resources. These rules apply to the stream:

- VS Code gets only the four notifications of the table above. They do not have the subscription id of the upstream server.
- VS Code never gets a `notifications/cancelled` of the upstream server. The ids of the upstream server and the ids of VS Code can be equal. Thus such a notification could cancel a different request of VS Code.
- VS Code lists the tools at the same time as `notifications/initialized`. A change before the stream opens reaches no stream. Thus after the acknowledgment of the first stream, VS Code gets one list change for each declared list. VS Code then lists them again.
- When the stream stops, the bridge opens a new stream after 0.5 s. Each later wait is two times longer, up to 30 s. Only a stream that lives for 10 s after its acknowledgment makes the next wait 0.5 s again.
- The upstream server does not send the notifications of a gap again. Thus after the acknowledgment of a new stream after a loss, VS Code gets one list change for each declared list again. It also gets one `notifications/resources/updated` for each subscribed resource, and it reads the resource again.
- When the upstream server refuses the stream with an error, the bridge opens no new stream. Then only a change of the subscriptions opens a stream.

### Subscriptions

`resources/subscribe` adds the URI of a resource to the stream, and `resources/unsubscribe` removes it. The bridge does one change at a time:

1. The bridge opens a new stream with all the subscribed URIs.
2. When the upstream server acknowledges the new stream, VS Code gets the response `{}`. Thus the response comes before the first update of the resource.
3. The bridge then stops the old stream.

A URI that the bridge has already, and a URI that it does not have, get `{}` at once without a new stream. When the upstream server refuses the new stream, VS Code gets the error of the upstream server. The old stream and the old URIs then stay. A change of the subscriptions alone sends no list change and no update.

### The order of notifications and results

A tool can change the tool list during a call. VS Code lists the tools again before the next turn of the chat. It does so only when the list change comes before the result of the call. On a stdio upstream server, the bridge sends each notification of the listen stream in the order of the upstream server. Thus a list change that the upstream server writes before the result of a call reaches VS Code before that result.

### Log messages

VS Code sends `logging/setLevel`, and the bridge keeps the level. Each request to the upstream server has this level. The upstream server then sends the log messages of the request at this level and above. VS Code gets each message as `notifications/message` with `level`, `logger` and `data`. Without `logging/setLevel`, the upstream server sends no log messages.

A request that starts before a change of the level has the old level. The bridge does not send a message below the new level to VS Code.

### The `_meta` keys of VS Code

VS Code puts keys into the `_meta` of a request. The bridge sends `traceparent`, `tracestate` and the keys that start with `vscode.` to the upstream server. It does not send the progress token, the log level or other keys of VS Code. It also removes a key that zig-sdk does not accept, for example a key with a space. Thus such a key does not make the request fail. The bridge also removes a key with a reserved prefix of the protocol, for example `vscode.mcp/`.

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
| `mcp-bridge-vscode: bridge: info: still waiting for the answers of the client to the input requests of <method> (request <id>, <N> s)` | The upstream server asked for input, and VS Code did not answer all input requests yet. The user must answer the form, the URL or the sampling request in VS Code. The line comes again each 30 s until the answers or the time limit. |
| `mcp-bridge-vscode: bridge: info: tool '<name>': added an items schema at '<pointer>' of the input schema` | An array schema of the tool had no `items`, or its `items` was false in JavaScript. The bridge added `items: {}`, so that VS Code shows the tool. |
| `mcp-bridge-vscode: bridge: warning: input request '<key>': the bridge refused the URL of a URL elicitation, and the upstream server gets decline` | The URL does not use `https`, or it uses `http` to a host that is not a loopback host. The URL can also have a backslash, or user information before the host. VS Code did not get the URL. |
| `mcp-bridge-vscode: bridge: warning: request <id> (<method>): the input requests of the upstream server failed: <detail>` | An input request or an answer of VS Code did not pass a check, or VS Code did not answer in time. `<detail>` gives the cause. The request of VS Code gets an error. |
| `mcp-bridge-vscode: bridge: info: request <id> (<method>): the client answered an input request with an error: <message>` | VS Code answered a sampling or roots request with an error. For example, the user refused a sampling request. The request of VS Code gets that error. |
| `mcp-bridge-vscode: bridge: warning: request <id> (<method>): the upstream server refused the request state after an input wait of <time>` | The answers came after the time limit of the state of the request, or the upstream server started again. Send the request again. |
| `mcp-bridge-vscode: bridge: warning: the listen stream ended: <error>. A new stream follows in <time>.` | The listen stream stopped, for example after a lost connection. The bridge opens a new stream after the wait. VS Code then gets one list change for each declared list and one update for each subscribed resource. |
| `mcp-bridge-vscode: bridge: info: the upstream server ended the listen stream. A new stream follows in <time>.` | The upstream server ended the listen stream with a result, for example at its stop. The bridge opens a new stream after the wait. |
| `mcp-bridge-vscode: bridge: warning: the upstream server refused the listen stream with the error <code>: <message>. The bridge sends no more list changes.` | The upstream server answered the listen stream with an error. VS Code gets no more notifications until the next change of the subscriptions. |
| `mcp-bridge-vscode: bridge: warning: the listen stream for a change of the subscriptions failed: <error>` | The new stream of a `resources/subscribe` or `resources/unsubscribe` failed before its acknowledgment. VS Code gets an error, and the old subscriptions stay. |
| `mcp-bridge-vscode: mcp_stdio: warning: stdio server exited (exit code N); no restart is left` | zig-sdk writes this line when the upstream server stops. The line of the bridge about the exit comes after it. |
| `mcp-bridge-vscode: mcp_router: warning: dropped <frame>: <outcome>` | zig-sdk dropped a frame of the upstream server that it cannot read, for example a frame that is longer than `--max-line-bytes`. When the frame names a request in flight, that request fails. |
| `mcp-bridge-vscode: bridge: error: the upstream server exited with code N` | The upstream server stopped while VS Code was connected. The bridge answered each request in flight with -32603, and it exits with code 1. The lines before this line can tell the cause. On POSIX, the line can also tell the signal that stopped the upstream server. |
| `mcp-bridge-vscode: vscode: warning: the bridge did not stop in 8 s after the end of stdin, thus it stops now` | A request did not stop after its cancellation. The watchdog stopped the bridge and the upstream server. |
| `Process exited with code N` | The bridge stopped. Code 1 means that the upstream server stopped, or that the bridge has an internal error. Code 2 means that the arguments are not valid. VS Code starts the bridge again at the next tool call. |
| `N tools have invalid JSON schemas and will be omitted` | VS Code checks the input schema of each tool against JSON Schema draft-07. It does not show the tools that fail, and a notification names the server. Correct the schemas in the upstream server. |
| `MPC <code>: <message>` | The server sent an error response. VS Code writes "MPC" in place of "MCP". The next table gives the messages of the bridge. A different message comes from the upstream server. |

The bridge sends these error messages. Each error also has `data.cause`, except the -32602 error for a refused request state, which keeps the `data` of the upstream server. The table shows the start of each message:

| Message | What it means |
| --- | --- |
| `MPC <code>: The upstream server did not answer server/discover. ...` | The upstream server did not answer `server/discover` in the time of `--discover-timeout`, or it answered with an error. It is not a server of revision 2026-07-28, or it does not respond. A server of an earlier revision answers with -32601. The bridge stays open, and VS Code can send `initialize` again. |
| `MPC -32603: The bridge cannot start the upstream server. ...` | The bridge cannot start `<command>`. Examine the path of the command in `args`. |
| `MPC -32603: The upstream server process stopped. ...` | The upstream server stopped, or it closed its stdout. |
| `MPC -32603: The upstream server did not answer in time. ...` | The request did not get a response in its time limit. `data.detail` gives the method and the limit. |
| `MPC -32603: The upstream server asked for input that the client did not declare.` | The upstream server sent an input request of a kind that VS Code did not declare, or a sampling request with tools. `data.detail` names the key of the input request. |
| `MPC -32603: The upstream server sent an input request that is not valid for the client. ...` | The input request does not have the shape of the schema, or the schema of its form has an error. |
| `MPC -32603: The upstream server asked for more inputs at one time than the limit of the bridge.` | One round has more than 16 input requests. |
| `MPC -32603: The upstream server asked for input too many times. ...` | The request has more than 10 rounds. |
| `MPC -32603: The client did not answer the input request of the upstream server in time.` | VS Code did not answer all input requests of a round in 1 h. |
| `MPC -32603: The client sent an answer that is not valid for the input request of the upstream server.` | The content of a form is not valid against the schema of the form, or an answer does not have the shape of the schema. |
| `MPC -32602: The upstream server did not accept the saved state of the request. ...` | The answers came after the time limit of the state of the request, or the upstream server started again. Send the request again. A tool call gets this text in a result with `isError: true`. |
| `MPC -32602: The request has a _meta key that the bridge cannot send to the upstream server.` | zig-sdk refused a `_meta` key of the request. The bridge removes such keys first, thus this error tells of a fault in the bridge. |
| `MPC -32603: The upstream server sent a response that is not valid. ...` | zig-sdk cannot read the response of the upstream server, for example because it is longer than `--max-line-bytes`. |
| `MPC -32603: The connection has too many requests in flight` | VS Code sent a new request at the limit of requests in flight. |
| `MPC -32600: The request is longer than the line limit of the bridge.` | The message of VS Code is longer than `--max-line-bytes`. |

## License

Apache License 2.0. See [`LICENSE`](../../LICENSE).

[^mcp-2025]: Model Context Protocol Specification 2025-11-25. https://modelcontextprotocol.io/specification/2025-11-25
[^mcp-2026]: Model Context Protocol Specification 2026-07-28. https://modelcontextprotocol.io/specification/2026-07-28
[^copilot-mrtr]: github/copilot-cli issue 4834. https://github.com/github/copilot-cli/issues/4834
[^vscode-2026]: microsoft/vscode issue 329848. https://github.com/microsoft/vscode/issues/329848
