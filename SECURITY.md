# Security policy

## Report a vulnerability

Use the private vulnerability report form of GitHub on this repository. Do not open a public issue for a vulnerability.

Give these details:

- The version or the commit you tested.
- The bridge and the product, for example `vscode` and Visual Studio Code (VS Code).
- The steps that show the problem.
- The effect of the problem.

The maintainer answers within seven days.

A vulnerability in zig-sdk itself goes to zig-sdk. Use the security policy of zig-sdk.[^zig-sdk-security]

## Supported versions

Only the newest release receives security fixes. Until the first release, only the branch `main` receives security fixes.

## Security design

The wiki page [Threat-Model](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Threat-Model) holds the security design of the bridges. For each security requirement, that page gives the milestone, the module and the test. From milestone M5, the page gives the test of each requirement of M1 to M5.

A bridge stands between its client and an upstream server. The threat model has these trust boundaries:

- The model trusts the client, for example VS Code, and the user of the client.
- The model does not trust the upstream server or its authorization server. The bridge must check what they send before the client gets it.

### The authorization server

In the URL form, the upstream server names its authorization server, and the authorization server makes the authorization URL. Thus the bridge does not trust the authorization URL, the redirect or the other answers of the authorization server. These rules apply:

- The bridge checks each authorization URL before it writes the URL or opens it. The URL must use `https`, have a host and have no user information. It must have only visible ASCII characters without ``"<>\^`{|}``, and at most 8 KiB. The bridge never writes or opens a URL that fails the check.
- The bridge never starts a shell to open a URL. On Windows, it calls `ShellExecuteW`. On a POSIX host, it starts `$BROWSER`, `open` or `xdg-open` with the URL as the only argument. On each system, the browser gets only the start URL of the receiver (see [Shared hosts](#shared-hosts)).
- Only the first sign-in, before `notifications/initialized`, opens the browser. After it, the bridge never opens the browser itself. The client shows the full URL in a URL elicitation, and the user decides.
- One sign-in runs at a time. After a sign-in through the client that the user declined or that failed, the bridge asks no new question for 60 s.
- The loopback receiver listens only on `127.0.0.1`, before the browser opens. No other socket can share its port. Only a `GET` of the callback path with the expected `state` and a second `GET` of the start path end the wait. The page of the receiver repeats nothing from the request.
- When the bridge opens the browser, the receiver also serves the one-time start path `/start/<token>`. The token has 256 random bits, and the compare of the token takes the same time for each token. The first `GET` gets the status 303 with the checked authorization URL as `Location`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer` and no body. A second `GET` gets 410 and stops the sign-in. A path with a different token gets 404 and does not stop the sign-in. After the time limit of the sign-in, the start path does not work.
- After the receiver gave a redirect with a code to the sign-in, a second `GET` of the start path cannot stop the sign-in. The bridge then writes a warning, and the page tells the user that another program possibly signed in with a different account.
- zig-sdk does the OAuth protocol: PKCE, the check of `state` and `iss`, and the check that the resource of the metadata covers the URL.
- The client secret of `--client-id` goes only to the authorization server of `--client-issuer`.
- `logout` uses the protected resource metadata of a server only when its resource covers the URL. Thus a server cannot name the stored sign-in of a different server.

### Secrets

No option of the bridge takes a secret on the command line. A secret header value comes from an environment variable of `--header-env`, and the client secret comes from `MCP_BRIDGE_CLIENT_SECRET`. `--header` is only for a value that is not secret. The stderr lines and the error messages never have a header value, a token, the client secret or the query of the redirect. The error messages also never have the URL of the upstream server, because its path or its query can hold a key.

The program that opens the browser gets no secret variable of the environment. On a POSIX host, the bridge removes them from the environment of that program. On Windows, the URL form removes them from the environment of its own process at the start.

### Token storage

The URL form of a bridge keeps the tokens of a sign-in. It uses the first store that works:

1. The keychain of the host: Windows Credential Manager, the macOS Keychain or the Secret Service on Linux.
2. Encrypted files, only with a key from outside the token directory: the environment variable `MCP_BRIDGE_TOKEN_KEY` or a private key file.
3. Memory. Then the user signs in at each start.

The file store protects the tokens against other accounts of the host and against a copy of the token directory alone. It does not protect them against a program that runs as the same user. In a remote window of VS Code, a server can run on the remote host: over Secure Shell, in WSL or in a dev container. Its tokens then stay on that host. A rebuild of a dev container removes them, unless the token directory is on a volume.

### The bridge in a zig-sdk server

From milestone M5, `vscode.serveStdio` puts the bridge into the process of a zig-sdk server. These rules apply:

- The first request of the client selects the path. The function reads the first lines with the line limit and the depth limit of the server. It drops a line that is too long without a response. A line that is not valid JSON-RPC selects the stdio transport of zig-sdk, and that transport answers it with an error.
- On the two paths, stdout gets only JSON-RPC messages.
- On the legacy path, the bridge applies its translation rules to the results of the server, as to the results of an upstream process.
- At the end of stdin, the function stops in a bounded time, but it has no watchdog. A handler that does not examine its cancel token and has no cancel point can keep the process alive. An executable can arm its own watchdog.

### Shared hosts

On a POSIX host, other users can read the command lines of the processes. The authorization URL has the `state` and the `code_challenge` of the sign-in. With these values, another user can sign in with a different account and send the redirect to the receiver of the bridge. Thus on each system, the browser opener gets only the start URL `http://127.0.0.1:<port>/start/<token>`, and not the authorization URL. The sign-in line on stderr still has the authorization URL. VS Code shows that line in the Output channel of the server.

A second `GET` of the start URL stops the sign-in, because another program possibly sent one of the two requests. A risk stays: another user can read the start URL and send the first `GET`. That user can then complete a sign-in with a different account before the browser of the user sends its `GET`. Then the bridge gets the code for the account of that user and shows no error. The browser of the user gets an error page or no connection. The same applies when the browser does not open.

On a host that other users share, use `--no-browser`, and open the URL of the sign-in line yourself. This helps only when no program on that host gets the URL as an argument. For example, VS Code on that host starts `xdg-open` with the URL of a link that you click. In a remote window, VS Code opens the link on your computer. After `notifications/initialized`, VS Code gets the authorization URL in a URL elicitation, also with `--no-browser`, and VS Code opens it. On Linux, the administrator can also mount `/proc` with the option `hidepid`, so that users cannot read the command lines of other users.

[^zig-sdk-security]: Security policy of zig-sdk. https://github.com/ChristianPresley/zig-sdk/blob/main/SECURITY.md
