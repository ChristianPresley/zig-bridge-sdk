# Consumer example

This example is a Zig package that uses zig-bridge-sdk as a dependency. It imports the `vscode` module and the `mcp` module from the package. The program `consumer` is a zig-sdk server with two tools. It calls `vscode.serveStdio` in place of `mcp.transport.stdio.serve`. Thus VS Code and a client of revision 2026-07-28 can use the same executable.

- The tool `greet` greets a person.
- The tool `ask_name` asks for a name in a form, and then greets the person. On the legacy path, VS Code gets the form as an `elicitation/create` request.

The committed `build.zig.zon` has no dependency. CI makes a tarball of the commit and adds it with `zig fetch --save=bridge_sdk`. A fetched package has only the paths in the `.paths` list of its `build.zig.zon`. A `.path` dependency has all the files of the directory. Thus the job finds a file that the package needs but does not ship.

With `--check`, the program writes the name of the bridge and exits with 0 when the name is `mcp-bridge-vscode`. The build stops when the `mcp` module of the consumer is not the `mcp` module of the bridge.

The program `consumer-driver` is the check of the `consumer` job of CI. `zig build drive` runs it. It starts `consumer` two times over pipes:

1. As VS Code: `initialize`, a call of `greet`, and a call of `ask_name` with the answer to its form.
2. As a client of revision 2026-07-28, with the stdio client of zig-sdk: `server/discover`, `tools/list` and a call of `greet`.

After each connection, the driver closes stdin of `consumer`, and `consumer` must exit with code 0.

## Steps to build the example

1. In the root of the repository, run `git archive --format=tar.gz HEAD -o ../bridge.tar.gz`.
2. Go to `examples/consumer`.
3. Run `zig fetch --save=bridge_sdk ../../../bridge.tar.gz`. This adds `bridge_sdk` to `build.zig.zon`.
4. Run `zig build`.
5. Run `zig-out/bin/consumer --check`.
6. Run `zig build drive`.
7. Run `git restore build.zig.zon`. Do not commit the dependency.
