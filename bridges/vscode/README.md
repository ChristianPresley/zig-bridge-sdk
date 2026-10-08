# `mcp-bridge-vscode`: MCP bridge for Visual Studio Code

`mcp-bridge-vscode` is a bridge between Visual Studio Code (VS Code) and an MCP server of specification revision 2026-07-28.[^mcp-2026] The MCP clients of VS Code speak revision 2025-11-25.[^mcp-2025] The bridge is a stdio server for VS Code. It starts the upstream server as a child process, or it connects to an upstream server at a URL over Streamable HTTP. It speaks to the upstream server with the `mcp.Client` of zig-sdk.

This version is milestone M4. The bridge sends the input requests, the list changes, the resource updates and the log messages of the upstream server to VS Code. It also connects to an upstream server at an HTTPS URL, and it signs in with OAuth when that server asks for it. The [Status](#status) section tells what each milestone adds.

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

This is milestone M4. The bridge starts the upstream command and speaks to it over stdio, or it connects to the upstream server at a URL. It answers `initialize`, and it forwards the requests for tools, prompts, resources and completion. It also forwards the progress notifications of the upstream server and the cancellations of VS Code. When a tool, a prompt or a resource needs input, the bridge asks VS Code. The section [Input requests](#input-requests) gives the rules.

The bridge sends the list changes, the resource updates and the log messages of the upstream server to VS Code. It also sends the trace context of VS Code to the upstream server. The section [Notifications](#notifications) gives the rules. The section [Options](#options) gives the command line.

For an upstream server at a URL, the bridge signs in at the authorization server of the upstream server, and it keeps the tokens. The sections [The URL form](#the-url-form), [Sign-in and accounts](#sign-in-and-accounts), [Token storage](#token-storage) and [Environment limits](#environment-limits) give the rules.

The [Roadmap](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Roadmap) on the wiki is the plan of record. Each milestone adds these parts:

| Milestone | What it adds |
| --- | --- |
| M1 | The runtime: the bridge starts the upstream server, answers `initialize`, and forwards the requests and the results with the translation rules. It also forwards the progress notifications and the cancellations. It adds the error table, the timeouts and the options of the command line. |
| M2 | Input requests: the bridge sends the elicitation, sampling and roots requests of the upstream server to VS Code, and forwards the answers. |
| M3 | Notifications of list changes, resource subscriptions, the log level and the `_meta` keys of VS Code. M3 needs zig-sdk v0.4.0. |
| M4 | An upstream server at an HTTPS URL, with OAuth sign-in, token storage and `logout`. M4 also needs zig-sdk v0.4.0. |
| M5 | An API that puts the bridge into a zig-sdk server, so that one executable serves the two revisions. |

From M1, the two harnesses can list and call the tools of the upstream server. From M2, they can also complete the tools that need input. From M3, the Local harness lists the tools again after a call that changes them, before the next turn of the same chat request. An editor of a resource also shows the changes of the resource. The Copilot harness has no manual check of this yet.

## Build and install

You need Zig 0.16.0. The project gives source code only, without prebuilt executables. The first build fetches zig-sdk, the only dependency, from GitHub. `build.zig.zon` pins the release commit of zig-sdk 0.4.0.

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

For the URL form, the sign-in also happens on the host of the bridge. The section [Environment limits](#environment-limits) tells how the browser and the redirect reach a remote host.

## Options

The usage has these forms:

```
mcp-bridge-vscode [options] -- <command> [args...]
mcp-bridge-vscode [options] <url>
mcp-bridge-vscode logout [--account <label>] <url>
mcp-bridge-vscode logout --all
```

The options of the bridge come first. The bridge does not examine the arguments after `--`. They go to the upstream command without a change. The URL is the last argument. It uses `https`, or `http` with a loopback host: `localhost`, a name that ends in `.localhost`, an address in `127.0.0.0/8`, or `[::1]`. The URL has no user, no password and no fragment.

These options apply to each form that serves VS Code:

| Option | What it does | Default |
| --- | --- | --- |
| `--name <name>` | The server name for VS Code when the upstream server sends no name. VS Code makes the ids of the tools and the keys of the tool approvals from this name. | The file name of `<command>` without its extension, or the host of `<url>` |
| `--log-level <level>` | The level of the log lines on stderr: `err`, `warn`, `info` or `debug`. | `info` |
| `--discover-timeout <s>` | The time in seconds for the answer of the upstream server to `server/discover`. After this time, VS Code gets an error for `initialize`. | 60 |
| `--max-line-bytes <n>` | The maximum length of one message in bytes, from 1 to 1073741824 (1 GiB). The limit applies to the messages of VS Code and of a stdio upstream server. | 67108864 (64 MiB) |
| `--help` | Show the usage on stdout. | |
| `--version` | Show the version on stdout. | |

These options apply only to the URL form:

| Option | What it does | Default |
| --- | --- | --- |
| `--header-env <name>=<var>` | Send the header `<name>` with the value of the environment variable `<var>` of the bridge. Use it for a secret. A variable that is not set is an error. | |
| `--header <name>:<value>` | Send the header `<name>` with `<value>`. VS Code writes the command line to its log, and the process list shows it. Never use it for a secret. | |
| `--max-response-bytes <n>` | The maximum length of one message from the upstream server in bytes, from 1 to 1073741824 (1 GiB). | 67108864 (64 MiB) |
| `--ca-file <path>` | Also trust the CA certificates of this PEM file, for the MCP requests and for the requests of the sign-in. The bridge always trusts the CA certificates of the system. | |
| `--client-id <id>` | Use this client ID, which the authorization server issued. The client secret comes from the environment variable `MCP_BRIDGE_CLIENT_SECRET`. | |
| `--client-issuer <url>` | The issuer of `--client-id`. A client with a secret needs it. | |
| `--client-metadata-url <url>` | Use the client ID metadata document at this URL. | The document of the bridge |
| `--redirect-port <port>` | The port of the redirect URI `http://127.0.0.1:<port>/callback`. | 41894 |
| `--account <label>` | The account of the stored sign-in. | `default` |
| `--token-store <store>` | Where the bridge keeps the tokens: `auto`, `keychain`, `file` or `memory`. | `auto` |
| `--token-key-file <path>` | The file with the key of the file store. Only your account can read it. | |
| `--no-browser` | Do not open a browser. Write the URL of the sign-in to stderr only. | |
| `--sign-in-timeout <s>` | The time in seconds for the sign-in in the browser. | 300 |

A static `Authorization` header (from `--header-env` or `--header`) and the sign-in options exclude each other. With such a header, the bridge does no sign-in. The bridge refuses the headers that the bridge or the HTTP connection sets, for example `Host`, `Content-Type` and `Accept`. It also refuses each name that starts with `mcp-`, and `Proxy-Authorization`. The executable has no option that permits `http` to other hosts. It also has no option that disables a check of the sign-in.

`logout` takes `--account`, `--all`, `--redirect-port`, `--token-store`, `--token-key-file`, `--ca-file` and `--log-level`. The section [Sign-in and accounts](#sign-in-and-accounts) tells how to use it.

VS Code has no limit for the length of a message. A message of VS Code that is longer than `--max-line-bytes` gets the error -32600 with the id of the request. The bridge cannot read a response of a stdio upstream server that is longer than the limit. The request then gets -32603 at once. For the URL form, `--max-response-bytes` is the limit of one JSON response and of one event of a stream. A larger response also gets -32603 at once.

Each forwarded request has a time limit. The limit is 120 s for the list requests, `completion/complete`, `prompts/get` and `resources/read`, and 1 h for `tools/call`. The answers of VS Code to the input requests of one round have a limit of 1 h. After the first round, each round of `prompts/get` and `resources/read` also has a limit of 1 h. For the URL form, `server/discover` waits for `--discover-timeout` and `--sign-in-timeout` together when a sign-in can start. A sign-in can start when the store has no access token for the account that is valid for more than one minute.

The exit code of the bridge tells why it stopped:

| Exit code | Cause |
| --- | --- |
| 0 | Stdin ended: VS Code closed the connection. |
| 1 | The upstream command stopped, or the bridge has an internal error. An upstream server at a URL never stops the bridge: a failed request gets an error. |
| 2 | The arguments are not valid. The code is also 2 for a missing variable of `--header-env` and for a `--ca-file` that the bridge cannot use. It is also 2 for a token store that does not open. The bridge writes the cause and the usage to stderr. |

At the end of stdin, the bridge cancels the requests in flight and stops the upstream server. A sign-in that waits for the browser also stops. A watchdog stops the bridge and the process tree of the upstream server 8 s after the end of stdin.

The exit code of `logout` is 0 when the deletion succeeded, also when there was nothing to delete. It is 1 when a deletion failed, and 2 for arguments that are not valid or for a token store that does not open.

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

### The URL form

With a URL in place of `--` and a command, the bridge connects to a remote upstream server over Streamable HTTP:

```json
{
  "servers": {
    "remote": {
      "type": "stdio",
      "command": "/abs/path/mcp-bridge-vscode",
      "args": ["https://mcp.example.com/mcp"]
    }
  }
}
```

When the server needs a static token, give the token in an environment variable from a password input, and name the variable with `--header-env`. VS Code keeps the value of a password input in its secret storage. Never write the token in `args`: VS Code writes the command line to its log, and the process list shows it.

```json
{
  "inputs": [
    { "type": "promptString", "id": "api-auth", "description": "Authorization header", "password": true }
  ],
  "servers": {
    "remote": {
      "type": "stdio",
      "command": "/abs/path/mcp-bridge-vscode",
      "args": ["--header-env", "Authorization=API_AUTH", "https://mcp.example.com/mcp"],
      "env": { "API_AUTH": "Bearer ${input:api-auth}" }
    }
  }
}
```

A static `Authorization` header disables the sign-in. Use it when the server accepts static tokens. Without such a header, the bridge signs in when the server asks for it. The section [Sign-in and accounts](#sign-in-and-accounts) gives the rules.

The client secret of a pre-registered client also comes from an environment variable, `MCP_BRIDGE_CLIENT_SECRET`. A client with a secret needs `--client-issuer`:

```json
{
  "inputs": [
    { "type": "promptString", "id": "client-secret", "description": "Client secret", "password": true }
  ],
  "servers": {
    "remote": {
      "type": "stdio",
      "command": "/abs/path/mcp-bridge-vscode",
      "args": ["--client-id", "my-client", "--client-issuer", "https://auth.example.com", "https://mcp.example.com/mcp"],
      "env": { "MCP_BRIDGE_CLIENT_SECRET": "${input:client-secret}" }
    }
  }
}
```

The `oauth` keys of an HTTP server entry in `mcp.json`, for example `clientId` and `enterpriseManaged`, do not apply to the stdio entry of the bridge. The bridge does not support the enterprise-managed authorization of VS Code yet. When a server accepts a static token, use `--header-env` with `Authorization` in its place.

For an upstream server at a URL, VS Code gets only `data:` icons: of the server, its tools, its prompts and its resources. VS Code does not load an `http:` or `https:` icon of a stdio server. The bridge also removes `file:` icons, because a remote server must not get the trust of a local process.

### Planned forms

- The API of M5: a zig-sdk server will serve the two revisions in one process, without the separate executable.

## Sign-in and accounts

An upstream server at a URL can ask for a sign-in with the status 401 or 403. The bridge then signs in at the authorization server of the upstream server with OAuth 2.1 and PKCE:

1. The bridge listens for the redirect on `http://127.0.0.1:<port>/callback`, before the browser opens. The default port is 41894.
2. The bridge writes the URL of the sign-in to stderr: `mcp-bridge-vscode: sign in at <url>`. VS Code shows the line in the Output channel of the server.
3. During `initialize`, the bridge opens the URL in the browser. With `--no-browser`, it only writes the line.
4. After `initialize`, the bridge never opens the browser itself. VS Code gets a URL elicitation with the URL. VS Code shows the full URL and asks you. When you accept, VS Code opens the URL.
5. You sign in, and the browser goes to the redirect URI. The bridge gets the code and the tokens.

A sign-in has a time limit, `--sign-in-timeout` (300 s). When you decline a URL elicitation, the request gets an error. Then for 60 s, the bridge asks no new question, and each sign-in fails at once. When VS Code does not declare URL elicitation, a sign-in after `initialize` fails. A restart of the server then signs in during `initialize` again.

The authorization server shows the name `mcp-bridge-vscode (zig-bridge-sdk)` on its consent page. The bridge gets a client ID in this order:

1. `--client-id`: a client that you registered at the authorization server. Register the exact redirect URI of the bridge, for example `http://127.0.0.1:41894/callback`. A client with a secret needs `--client-issuer`, so that the secret goes only to that issuer.
2. A client ID metadata document. The default is the document of the bridge, `https://christianpresley.github.io/zig-bridge-sdk/vscode/client.json`. `--client-metadata-url` gives a different document, which must list the redirect URI of the bridge. The authorization server uses a document only when it supports such documents.
3. Dynamic client registration. The bridge uses it when the authorization server does not use the document. The document of the bridge lists only the redirect port 41894. Thus with a different `--redirect-port` and no registration option, the bridge uses dynamic client registration.

Two servers with a sign-in in one `mcp.json` need different redirect ports. Only one program can listen on a port.

The bridge keeps one stored sign-in for each server URL, account and redirect URI. `--account <label>` keeps the sign-ins of two accounts apart, for example a work account and a personal account. To sign out, or to sign in as a different account:

1. Run `mcp-bridge-vscode logout <url>` with the URL and the options of the server entry. Add `--account <label>` for an account that is not `default`. `logout --all` deletes each stored sign-in of the bridge.
2. Run **MCP: Restart Server** in VS Code. The next request signs in again.

`logout` does not tell the authorization server. When `logout` cannot run, delete the entries yourself:

| Store | How to delete the entries |
| --- | --- |
| Windows Credential Manager | Delete each generic credential whose name starts with `zig-bridge-sdk/mcp-bridge-vscode/`. A large entry has more credentials that end in `/1`, `/2` and so on. `cmdkey /list` shows them, and `cmdkey /delete:<name>` deletes one. |
| macOS Keychain | Run `security delete-generic-password -s zig-bridge-sdk/mcp-bridge-vscode` until it finds no more items. |
| Secret Service on Linux | Run `secret-tool clear service zig-bridge-sdk/mcp-bridge-vscode`. |
| File store | Delete the token directory: `%LOCALAPPDATA%\zig-bridge-sdk\vscode\tokens` on Windows, else `$XDG_STATE_HOME/zig-bridge-sdk/vscode/tokens` or `~/.local/state/zig-bridge-sdk/vscode/tokens`. |

When the authorization server forgets a stored client, the sign-in page can show an error and send no redirect. The sign-in then ends at its time limit, and the error tells you to run `logout`.

## Token storage

`--token-store auto` uses the first store that works:

1. The keychain of the host: Windows Credential Manager, the macOS Keychain or the Secret Service on Linux. The service is `zig-bridge-sdk/mcp-bridge-vscode`. On Linux without a display, the bridge shows no unlock prompt. When the keychain stops to answer later, the bridge uses the next store for the rest of the process.
2. Encrypted files, only with a key from outside the token directory. The key has 64 hexadecimal digits. It comes from the environment variable `MCP_BRIDGE_TOKEN_KEY`, or from the file of `--token-key-file`. A password input can give the variable. The key file must be private to your account.
3. Memory. Then you sign in at each start of the server.

`--token-store keychain`, `file` and `memory` use only that store. A store that does not open is then an error. At the start, the bridge writes one line that names the store.

The file store protects the tokens against other accounts of the host and against a copy of the token directory alone. It does not protect them against a program that runs as your account.

## Environment limits

- Proxies: the bridge uses the proxy of `HTTPS_PROXY` or `ALL_PROXY` for the MCP requests and for the requests of the sign-in. `NO_PROXY` names the hosts without a proxy. A loopback host never uses a proxy. Put the user and the password of the proxy into the proxy URL. VS Code does not give its setting `http.proxy` to a stdio server. Thus set the variables in the `env` of the server entry, or in the environment of VS Code.
- The sandbox of VS Code: with `sandboxEnabled`, the sandbox blocks the browser, the redirect port and the keychain. The variable `SANDBOX_RUNTIME=1` tells the bridge. A sign-in in the sandbox fails at once with an error that names the sandbox. Disable the sandbox for a server at a URL that needs a sign-in. This limit does not apply to the form with `--`.
- Remote windows: a server of the workspace configuration runs on the remote host, for example over Secure Shell, in WSL or in a dev container. The bridge then opens the browser with the `$BROWSER` helper of VS Code. When the browser does not open, open the URL of the sign-in line in the Output channel. The redirect of the browser must reach the redirect port on the remote host. VS Code can forward the port. Else forward it in the Ports view of VS Code.
- Tokens on a remote host: the tokens of a server on a remote host stay on that host. A rebuild of a dev container removes them, unless the token directory is on a volume.
- Shared hosts: on a POSIX host, other users can read the command lines of the processes. The browser opener gets the URL of the sign-in as its argument. Another user of the host can then send a redirect with the code of a different account to the bridge. On a host that other users share, use `--no-browser`, and open the URL of the sign-in line yourself.
- VS Code for the Web cannot start the bridge.

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
- On an upstream server at a URL, a stream can fail with the status 401 or 403, because its sign-in did not complete. Then the bridge opens a new stream after the next sign-in of a different request.

### Subscriptions

`resources/subscribe` adds the URI of a resource to the stream, and `resources/unsubscribe` removes it. The bridge does one change at a time:

1. The bridge opens a new stream with all the subscribed URIs.
2. When the upstream server acknowledges the new stream, VS Code gets the response `{}`. Thus the response comes before the first update of the resource.
3. The bridge then stops the old stream.

A URI that the bridge has already, and a URI that it does not have, get `{}` at once without a new stream. When the upstream server refuses the new stream, VS Code gets the error of the upstream server. The old stream and the old URIs then stay. A change of the subscriptions alone sends no list change and no update.

### The order of notifications and results

A tool can change the tool list during a call. VS Code lists the tools again before the next turn of the chat. It does so only when the list change comes before the result of the call. On a stdio upstream server, the bridge sends each notification of the listen stream in the order of the upstream server. Thus a list change that the upstream server writes before the result of a call reaches VS Code before that result.

On an upstream server at a URL, the listen stream and the call are different HTTP requests. Then a list change can reach VS Code after the result of the call, and VS Code lists the tools again one turn later.

### Log messages

VS Code sends `logging/setLevel`, and the bridge keeps the level. Each request to the upstream server has this level. The upstream server then sends the log messages of the request at this level and above. VS Code gets each message as `notifications/message` with `level`, `logger` and `data`. Without `logging/setLevel`, the upstream server sends no log messages.

A request that starts before a change of the level has the old level. The bridge does not send a message below the new level to VS Code.

### The `_meta` keys of VS Code

VS Code puts keys into the `_meta` of a request. The bridge sends `traceparent`, `tracestate` and the keys that start with `vscode.` to the upstream server. It does not send the progress token, the log level or other keys of VS Code. It also removes a key that zig-sdk does not accept, for example a key with a space. Thus such a key does not make the request fail. The bridge also removes a key with a reserved prefix of the protocol, for example `vscode.mcp/`.

## Troubleshooting

VS Code writes the messages of each MCP server to an Output channel. The channel also shows the stderr lines of the bridge and of the upstream server. VS Code writes each stderr line at the Warning level. Each line of the bridge has the form `mcp-bridge-vscode: <scope>: <level>: <text>`. The sign-in line has the form `mcp-bridge-vscode: sign in at <url>`. A line without one of these starts comes from the upstream server.

1. Open the Output channel of the server: run **MCP: List Servers**, select the server, then select **Show Output**.
2. To see more lines, set the level of the channel to Debug or Trace in the Output view. At the Debug level, VS Code writes each JSON-RPC message that it sends and receives.
3. As an alternative to step 2, add `"dev": {}` to the server entry. Then VS Code writes the JSON-RPC messages at the Info level. It also opens the channel when the server starts.
4. Add `--log-level debug` before the `--` in `args`. Then the bridge also writes its debug lines:

   ```json
   "args": ["--log-level", "debug", "--", "/abs/path/your-server"]
   ```

   For the URL form, put the option before the URL. The debug lines never have a header value, a token or the query of the redirect:

   ```json
   "args": ["--log-level", "debug", "https://mcp.example.com/mcp"]
   ```

These messages can occur in the channel:

| Message | What it means |
| --- | --- |
| `` Waiting for server to respond to `initialize` request... `` | VS Code sent `initialize` and has no response yet. The bridge responds after the upstream server answers `server/discover`. After the time of `--discover-timeout` (60 s), the bridge responds with an error. If the message stays, examine the stderr lines of the upstream server. |
| `mcp-bridge-vscode: bridge: warning: cannot start the upstream command: <error>` | The bridge cannot start `<command>`, and VS Code gets an error for `initialize`. Examine the path of the command in `args`. |
| `mcp-bridge-vscode: bridge: warning: server/discover failed: <error>` | The upstream server did not answer `server/discover`, or it answered with an error. VS Code gets an error for `initialize`. For an upstream server at a URL, the line can end with the HTTP status, for example `(HTTP status 404)`. |
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
| `mcp-bridge-vscode: vscode: error: <cause>`, then the usage | The arguments are not valid, and the bridge exits with code 2. `<cause>` names the option, the header or the environment variable, but never a value. |
| `mcp-bridge-vscode: vscode: error: cannot use the CA certificates of --ca-file: <error>` | The bridge cannot read the file of `--ca-file`, or the file has no certificate that the bridge can use. The bridge exits with code 2. |
| `mcp-bridge-vscode: vscode: warning: the value of the header <name> is on the command line. ...` | A `--header` has a name that usually carries a secret. Use `--header-env`. |
| `mcp-bridge-vscode: vscode: info: the client metadata document of the bridge has only the redirect port 41894. With --redirect-port N, the bridge uses dynamic client registration.` | A `--redirect-port` that is not the default needs dynamic client registration or `--client-id`. |
| `mcp-bridge-vscode: bridge: warning: cannot make the HTTP client for the upstream server: <error>` | The URL, a proxy variable or the CA certificates are not valid. VS Code gets an error for `initialize`. |
| `mcp-bridge-vscode: vscode: error: the token store did not open: <cause>` | The store of `--token-store` does not open, or the token key is not valid. `<cause>` tells what to correct. The bridge exits with code 2. |
| `mcp-bridge-vscode: bridge: info: the tokens are in the keychain of the host (service "zig-bridge-sdk/mcp-bridge-vscode")` | The store of the tokens. Other forms of the line name the token directory of the file store, or tell why the tokens stay in memory. |
| `mcp-bridge-vscode: bridge: info: the tokens stay in memory: the keychain is not available (<error>), and no token key is set (MCP_BRIDGE_TOKEN_KEY or --token-key-file). Each start needs a new sign-in` | The host has no keychain that answers, for example over Secure Shell or in WSL. Set a token key for the file store, or sign in at each start. |
| `mcp-bridge-vscode: bridge: warning: the file store did not start: <error>` | The bridge has a token key, but it cannot use the token directory. With `--token-store auto`, the tokens then stay in memory. Examine the permissions of the token directory. |
| `mcp-bridge-vscode: bridge: warning: the keychain stopped to answer (<error>). For the rest of the process, ...` | The keychain refused a request after the start, for example because the user locked it. The bridge uses the next store until it stops. |
| `mcp-bridge-vscode: bridge: warning: the index of the stored sign-ins is not valid, thus the bridge ignores it` | The bridge cannot read its index of the stored sign-ins. The sign-in continues. `logout <url>` then finds the stored sign-in through the server. |
| `mcp-bridge-vscode: bridge: warning: cannot add the sign-in to the index of the stored sign-ins: <error>` | The store has the tokens, but the index does not have the sign-in. Then `logout --all` does not find it. Use `logout <url>`, or delete the entries yourself. A similar line tells that the bridge cannot remove a sign-in from the index. |
| `mcp-bridge-vscode: sign in at <url>` | The upstream server at a URL needs a sign-in. When no browser opens, open the URL in a browser. After `initialize`, VS Code also shows the URL in a URL elicitation. |
| `mcp-bridge-vscode: bridge: warning: the bridge cannot start the browser opener: <error>` | The bridge cannot start `$BROWSER`, `open` or `xdg-open`. The line about the browser that did not open comes next. |
| `mcp-bridge-vscode: bridge: warning: the browser opener stopped with an error` | The program that opens the browser stopped with an error. The line about the browser that did not open comes next. |
| `mcp-bridge-vscode: bridge: warning: ShellExecuteW failed with the value N` | Windows did not open the URL, for example because no program opens `https` links. The line about the browser that did not open comes next. |
| `mcp-bridge-vscode: bridge: warning: the browser did not open: open the URL of the sign-in line in a browser` | The bridge cannot start a browser, for example on a host without a desktop. Open the URL of the sign-in line yourself. |
| `mcp-bridge-vscode: bridge: warning: the authorization URL is not valid (<error>), thus the bridge does not open it` | The authorization server sent a URL that is not safe to open. The bridge did not write it and did not open it. |
| `mcp-bridge-vscode: bridge: warning: the authorization URL has no state, thus the bridge does not open it` | Without the `state`, the bridge cannot identify the redirect. The bridge did not write the URL and did not open it. |
| `mcp-bridge-vscode: bridge: warning: the redirect URI of the authorization URL is not the redirect URI of the receiver` | The URL sends the browser to a different redirect URI. The bridge did not write the URL and did not open it. |
| `mcp-bridge-vscode: bridge: warning: The authorization server sent an authorization URL that is not valid. The bridge did not open it.` | This line comes after each of the three lines above. The request gets an error. |
| `mcp-bridge-vscode: bridge: warning: the loopback receiver cannot listen on port N: <error>` | The bridge cannot listen for the redirect, and the sign-in fails. The next line tells the cause. |
| `mcp-bridge-vscode: bridge: warning: Another program uses the redirect port N. ...` | A different program, or a second server with a sign-in, listens on the redirect port. Set a different `--redirect-port` for one of them. |
| `mcp-bridge-vscode: bridge: warning: The bridge cannot listen on the redirect port N. ...` | The bridge cannot listen on the redirect port for a different cause, for example a permission of the system. Set a different `--redirect-port`. |
| `mcp-bridge-vscode: bridge: warning: the loopback receiver cannot start its accept loop: <error>` | The bridge cannot start the task that receives the redirect. The sign-in fails. |
| `mcp-bridge-vscode: bridge: warning: The sign-in did not complete in N s.` | Nobody completed the sign-in in the browser in the time limit. The error of the request tells what to do. |
| `mcp-bridge-vscode: bridge: warning: The authorization server refused the access.` | The redirect has the error `access_denied`, for example because you denied the access in the browser. |
| `mcp-bridge-vscode: bridge: warning: The authorization server sent an error for the sign-in. The error code is <code>.` | The redirect has a different error, for example `invalid_scope`. |
| `mcp-bridge-vscode: bridge: info: the client did not declare URL elicitation: a later sign-in fails, and a restart of the server signs in again` | This client of VS Code cannot ask you to open a URL. A sign-in after `initialize` fails at once. |
| `mcp-bridge-vscode: bridge: warning: The client cannot ask the user to open the URL of the sign-in, ...` | The upstream server asked for a sign-in after `initialize`, but VS Code did not declare URL elicitation. Restart the server to sign in during `initialize`. |
| `mcp-bridge-vscode: bridge: warning: the client did not answer the URL elicitation of the sign-in in <time>` | VS Code did not answer the question of the sign-in in the time limit of the sign-in. The request gets an error. |
| `mcp-bridge-vscode: bridge: info: The user declined the sign-in.` | You declined the URL elicitation of the sign-in. The request gets an error. For 60 s, the bridge then asks no new question. |
| `mcp-bridge-vscode: bridge: info: A sign-in through the client did not complete a short time ago, ...` | Less than 60 s ago, a sign-in through VS Code failed, or you declined it. The bridge does not ask again yet, and the request gets an error. |
| `mcp-bridge-vscode: bridge: info: The request stopped before the sign-in completed.` | VS Code canceled the request, or the time limit of the request stopped the sign-in. |
| `mcp-bridge-vscode: bridge: info: The client closed the connection before the sign-in completed.` | Stdin ended during the sign-in. The bridge stopped the wait for the redirect. |
| `mcp-bridge-vscode: bridge: warning: The bridge runs in the sandbox of VS Code, ...` | `SANDBOX_RUNTIME=1` is set, and the store has no token that the bridge can use. Disable the sandbox for this server. |
| `mcp-bridge-vscode: bridge: warning: <message>` | A different failure of the sign-in, for example a refused registration. The line has the message of the error of the request. The next table tells the cause of each message. |
| `mcp-bridge-vscode: bridge: warning: the listen stream ended with the HTTP status N. A new stream follows in <time>.` | The upstream server or a proxy answered the listen stream with the status 408, 429 or 5xx, but not 501. The bridge opens a new stream after the wait. |
| `mcp-bridge-vscode: bridge: warning: the listen stream failed with the HTTP status N. A new stream follows after the next sign-in.` | The sign-in of the listen stream did not complete. The next sign-in of a different request opens the stream again. |
| `mcp-bridge-vscode: bridge: info: a sign-in completed. The bridge opens the listen stream again.` | A different request signed in after the listen stream failed with 401 or 403. |
| `mcp-bridge-vscode: bridge: warning: the listen stream failed with the HTTP status N. The bridge sends no more list changes.` | The listen stream failed with a status that does not change with time, for example 404. VS Code gets no more notifications until the next change of the subscriptions. |
| `Process exited with code N` | The bridge stopped. Code 1 means that the upstream command stopped, or that the bridge has an internal error. Code 2 means that the arguments are not valid, or that the token store does not open. VS Code starts the bridge again at the next tool call. |
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
| `MPC -32603: The upstream server sent a response that is not valid. ...` | zig-sdk cannot read the response of the upstream server, for example because it is longer than `--max-line-bytes` or `--max-response-bytes`. For an upstream server at a URL, `data.detail` can give the HTTP status. |
| `MPC -32603: The bridge cannot make the client for the URL of the upstream server. ...` | The URL, the proxy variables or the CA certificates are not valid. |
| `MPC -32603: The connection to the upstream server failed. ...` | The bridge cannot connect to the upstream server at the URL, or the TLS handshake failed. An example is a certificate of a CA that the bridge does not trust. Examine the URL, the proxy and `--ca-file`. |
| `MPC -32603: The sign-in did not complete in N s. ...` | Nobody completed the sign-in in the time limit. Get more time with `--sign-in-timeout`, and during `initialize` also with `--discover-timeout`. When the authorization server shows no sign-in page, run `mcp-bridge-vscode logout <url>` and restart the server. |
| `MPC -32603: The upstream server needs a new sign-in, and the client did not open the URL of the sign-in. ...` | You declined the URL elicitation, a sign-in failed a short time ago, or VS Code did not declare URL elicitation. `data.detail` gives the cause. Restart the server to sign in again. |
| `MPC -32603: The authorization server has no client registration that the bridge can use. ...` | The authorization server supports no client ID metadata document and no dynamic client registration. Register a client with the redirect URI of the message, and give `--client-id` and `--client-issuer`. |
| `MPC -32603: The authorization server refused the registration of the client. ...` | The dynamic client registration failed. `data.detail` gives the HTTP status and the error code. |
| `MPC -32603: The client ID of --client-id is not for the authorization server of the upstream server. ...` | `--client-issuer` names a different authorization server. |
| `MPC -32603: The bridge cannot listen on the redirect port N. ...` | Another program uses the redirect port, or the bridge cannot listen on it. Set a different `--redirect-port`. |
| `MPC -32603: The URL of --client-metadata-url is not valid for a client ID metadata document. ...` | The document needs an `https` URL with a path. |
| `MPC -32603: The authorization server sent an authorization URL that is not valid. ...` | The authorization URL failed a check of the bridge. The bridge did not write it and did not open it. The Output channel tells which check failed. |
| `MPC -32603: The authorization server refused the access. ...` | You denied the access in the browser. |
| `MPC -32603: The authorization server sent an error for the sign-in. ...` | The redirect has an error other than `access_denied`. The Output channel gives the error code. |
| `MPC -32603: The upstream server refused the access after the sign-in. ...` | The account possibly does not have the necessary permissions. |
| `MPC -32603: The upstream server needs a sign-in, but the bridge runs in the sandbox of VS Code. ...` | Disable the sandbox for this server. |
| `MPC -32603: The sign-in at the authorization server of the upstream server failed. ...` | A different failure of the sign-in. `data.detail` gives the cause, and the Output channel has more lines. |
| `MPC -32603: The connection has too many requests in flight` | VS Code sent a new request at the limit of requests in flight. |
| `MPC -32600: The request is longer than the line limit of the bridge.` | The message of VS Code is longer than `--max-line-bytes`. |

`logout` writes these lines:

| Message | What it means |
| --- | --- |
| `mcp-bridge-vscode: vscode: info: logout deleted the stored sign-in of the account "<label>". ...` | `logout` deleted the tokens and the client of the account for the URL. Restart the server in VS Code to sign in again. |
| `mcp-bridge-vscode: vscode: info: logout found no stored sign-in of the account "<label>" for the URL` | The stores have no sign-in of this account for the URL. Give the same URL, `--account` and `--redirect-port` as the server entry. |
| `mcp-bridge-vscode: bridge: warning: the index has no sign-in for the URL, and ...` | The index of the stored sign-ins has no entry for the URL. The protected resource metadata of the server also does not identify the sign-in, or the server has no such metadata. Thus `logout` cannot find the stored sign-in. Use `logout --all`, or delete the entries yourself. |
| `mcp-bridge-vscode: vscode: info: logout deleted N stored sign-ins` | `logout --all` deleted the sign-ins of the index in each store. |
| `mcp-bridge-vscode: vscode: info: deleted the token directory <path>` | `logout --all` also deleted the directory of the file store. |
| `mcp-bridge-vscode: vscode: error: cannot delete the token directory <path>: <error>` | Delete the directory yourself. The exit code is 1. |
| `mcp-bridge-vscode: vscode: info: logout skips the <store> store: <error>` | With `--token-store auto`, `logout` does not examine a store that does not open. Such a store has no sign-in to delete. |
| `mcp-bridge-vscode: vscode: error: logout failed in the <store> store: <error>` | The store refused the deletion, for example a locked keychain. Unlock the keychain and run `logout` again, or delete the entries yourself. The exit code is 1. |
| `mcp-bridge-vscode: vscode: info: the memory store keeps no sign-in after the end of the process: logout has nothing to delete` | With `--token-store memory`, no sign-in stays after the end of the process. |

## License

Apache License 2.0. See [`LICENSE`](../../LICENSE).

[^mcp-2025]: Model Context Protocol Specification 2025-11-25. https://modelcontextprotocol.io/specification/2025-11-25
[^mcp-2026]: Model Context Protocol Specification 2026-07-28. https://modelcontextprotocol.io/specification/2026-07-28
[^copilot-mrtr]: github/copilot-cli issue 4834. https://github.com/github/copilot-cli/issues/4834
[^vscode-2026]: microsoft/vscode issue 329848. https://github.com/microsoft/vscode/issues/329848
