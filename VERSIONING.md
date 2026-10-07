# Versioning

zig-bridge-sdk uses semantic versioning with a major version of zero.

## Rules

- A minor release (`0.y.0`) can change the public API, add a bridge, or move to a new release of zig-sdk or Zig.
- A patch release (`0.y.z`) contains fixes only.
- Each release pins one Zig version in `build.zig.zon` (`minimum_zig_version`).
- Each bridge speaks one MCP revision to its client. A change of that revision is a minor release.

## The zig-sdk pin

- Each release pins exactly one release of zig-sdk: one tag and its commit. `build.zig.zon` records the commit and the hash of the package.
- Between two releases, a milestone can need a change of zig-sdk that has no release yet. Then the pin can be a commit of zig-sdk before its release. Before the next release of zig-bridge-sdk, the pin moves to the commit of the tag.
- A change of the pin is a minor release. Milestone M5 plans a way to embed a bridge in a server of zig-sdk. From then on, the `mcp` types are a part of the public API of the `vscode` module.
- Each release entry in `CHANGELOG.md` names the version of zig-sdk.
- The README has one compatibility table. It has one row for each release, with the version and the commit of zig-sdk.

## Move to a new release of zig-sdk

1. Find the commit of the new tag of zig-sdk.
2. Run `zig fetch --save=mcp git+https://github.com/ChristianPresley/zig-sdk#<commit>`.
3. Update the bridges until `zig build test` passes.
4. If the new release speaks a new MCP revision, vendor its schema in `test/fixtures/mcp_schema_<rev>/`.
5. Put an `UPSTREAM.zon` file and the upstream `LICENSE` file in each new fixture directory.
6. Add the new version of zig-sdk to the compatibility table of the README.
7. Record the new version of zig-sdk in `CHANGELOG.md` under "Changed".
8. Make a minor release.

## Make a release

1. Make the signed commit `chore(release): X.Y.Z` with one body line for each of these files:
   - `build.zig.zon`: `.version = "X.Y.Z"`.
   - `CHANGELOG.md`: the section `## [X.Y.Z] - <date>` with the version of zig-sdk, and the link definitions.
   - `README.md`: the row of the release in the compatibility table.
2. Run `zig build check-version -- vX.Y.Z`.
3. Merge the pull request with a signed fast-forward push after the CI passes.
4. Push the signed tag `vX.Y.Z`.

The release workflow verifies the tag, runs the tests and publishes the release notes from `CHANGELOG.md`. The distribution is source only, so a release has no executables.

## Tags

Release tags have the form `vX.Y.Z` and are GPG-signed.
