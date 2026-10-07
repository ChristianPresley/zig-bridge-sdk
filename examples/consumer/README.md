# Consumer example

This example is a Zig package that uses zig-bridge-sdk as a dependency. It imports the `vscode` module and the `mcp` module from the package. The `consumer` job of CI builds it and runs `consumer --check`.

The committed `build.zig.zon` has no dependency. CI makes a tarball of the commit and adds it with `zig fetch --save=bridge_sdk`. A fetched package has only the paths in the `.paths` list of its `build.zig.zon`. A `.path` dependency has all the files of the directory. Thus the job finds a file that the package needs but does not ship.

With `--check`, the program writes the name of the bridge and exits with 0 when the name is `mcp-bridge-vscode`. The build stops when the `mcp` module of the consumer is not the `mcp` module of the bridge.

This is the stub of milestone M0. In milestone M5, the example also serves a zig-sdk server through the bridge.

## Steps to build the example

1. In the root of the repository, run `git archive --format=tar.gz HEAD -o ../bridge.tar.gz`.
2. Go to `examples/consumer`.
3. Run `zig fetch --save=bridge_sdk ../../../bridge.tar.gz`. This adds `bridge_sdk` to `build.zig.zon`.
4. Run `zig build`.
5. Run `zig-out/bin/consumer --check`.
6. Run `git restore build.zig.zon`. Do not commit the dependency.
