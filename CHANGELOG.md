# Changelog

This file records all notable changes to this project. The format follows Keep a Changelog 1.1.0. The project uses semantic versioning. Each entry starts with the part that it changes: the package, the core module `bridge`, a bridge such as `vscode`, or the repository. Each release names the version of zig-sdk that it pins.

## [Unreleased]

This section has the work of milestone M0, the scaffold. No bridge can connect to a server yet. The runtime comes with milestone M1. The pinned zig-sdk is v0.3.0.

### Added

- Package: the Zig package `bridge_sdk` for Zig 0.16.0. Its only dependency is zig-sdk v0.3.0, pinned in `build.zig.zon` by the commit `c1f55f00deefb3f09ac97126d6405b1820b927dd` and the package hash. The `.paths` list has `build.zig`, `build.zig.zon`, `src`, `bridges`, `LICENSE`, `NOTICE` and `README.md`.
- Package: the package exports the `mcp` module of the pinned zig-sdk, so that an embedder can use the same `mcp` types as the bridges.
- `bridge`: the core module in `src/bridge.zig`. `bridge.Profile` holds the settings of one product, for example its name, the `_meta` keys for the upstream server and the quirk flags. `bridge.version` is the version of the package.
- `vscode`: the module of the bridge for Visual Studio Code (VS Code) in `bridges/vscode/vscode.zig`, with `vscode.profile`. The profile declares `traceparent`, `tracestate` and the `vscode.` keys for the upstream server, and the quirk `normalize_array_items`.
- `vscode`: the executable `mcp-bridge-vscode` in `bridges/vscode/main.zig`, as a stub. It shows its usage with `--help` and its version with `--version`. For other arguments, it writes a message to standard error and exits with code 2.
- `vscode`: `bridges/vscode/README.md`, with the build, the configuration of VS Code and the planned work of each milestone.
- Repository: the upstream server of the tests, `bridge-fixture-server` (`zig build fixture-server`). It is a zig-sdk server on stdio with the tools `echo` and `add`.
- Repository: the MCP schemas of revisions 2025-11-25 and 2026-07-28 in `test/fixtures/`, from the upstream commit `046fa30efd374370afb87ef830bd788eac5f217e`, with the upstream `LICENSE` and an `UPSTREAM.zon` file. A test compiles each schema with the validator of zig-sdk.
- Repository: the build steps `test`, `test-vscode`, `fixture-server`, `run-vscode` and `fmt`, and the option `-Dfuzz` for `zig build test -Dfuzz --fuzz`.
- Repository: the tools `lint-docs`, `commit-policy`, `check-version`, `changelog-section` and `gen-dictionary`, with their build steps. `lint-docs` comes from zig-sdk, with the paths and the wiki of this repository.
- Repository: the `commit-msg` hook in `.githooks/`.
- Repository: the project profile of ASD-STE100 in `docs/style/ste-profile.md` and the project dictionary in `docs/dictionary/`. The dictionary has the abbreviation `VS` and the synonyms `vscode` and `vsc` of VS Code. `gen-dictionary` writes the dictionary as one page to `docs/generated/dictionary.md`.
- Repository: the action `setup-zig` with the pinned Zig 0.16.0. The CI workflow has the jobs `fmt-lint`, `commit-policy`, `test`, `cross` and `consumer`. The `fmt-lint` job also checks that the dictionary page is current.
- Repository: the release workflow. A release publishes notes only, because the distribution is source only.
- Repository: the nightly workflow with the jobs `wiki-lint` and `fuzz`. The `fuzz` job starts when milestone M1 adds the fuzz targets.
- Repository: the Dependabot configuration. Dependabot checks the GitHub Actions each week.
- Repository: the consumer example in `examples/consumer/`, as a stub. It uses the package from a tarball of the commit, as a fetched dependency.
- Repository: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `VERSIONING.md`, `CODE_OF_CONDUCT.md`, `CLAUDE.md`, `AGENTS.md`, `NOTICE`, `THIRD_PARTY_LICENSES.md`, the pull request template and `CODEOWNERS`. `CONTRIBUTING.md` has the recipe for the Linux tests in WSL and the wake rule for accept loops. `VERSIONING.md` has the rules for the zig-sdk pin.
- Repository: the trademark notice for Visual Studio Code in `README.md`, `bridges/vscode/README.md` and the doc comment of `bridges/vscode/vscode.zig`.

[Unreleased]: https://github.com/ChristianPresley/zig-bridge-sdk/commits/main
