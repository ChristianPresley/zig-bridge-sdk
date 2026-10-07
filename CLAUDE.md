# Instructions for AI agents in this repository

- The only author and committer of every commit is Christian Presley <chrispresley@outlook.com>. Never add `Co-Authored-By`, `Signed-off-by` or other attribution trailers. Every commit and tag is GPG-signed.
- Every commit subject follows Conventional Commits (`type(scope): description`) and the body has one line per changed file (`path: what changed`). Pull request descriptions carry no generator or attribution line.
- Merge a pull request with a signed fast-forward push of its head to `main`. Never use a squash merge or a rebase merge of GitHub.
- Zig 0.16.0 only. The only dependency is zig-sdk, pinned by commit and hash in `build.zig.zon`. No vendored third-party code except the licensed test fixtures under `test/fixtures/`.
- This repository holds the legacy protocol behavior (MCP revision 2025-11-25). The modern side (revision 2026-07-28) always uses zig-sdk. Do not write a second copy of a part that zig-sdk provides.
- The key of each bridge is its product, after a check of the brand guidelines that the vendor publishes. Record the result, the URL and the date of the check on the wiki page Package-Model. The files of a bridge are in `bridges/<product>/`, and its module declares a `bridge.Profile`.
- Prose (README, wiki, `///` and `//!` doc comments) follows the project ASD-STE100 profile in `docs/style/ste-profile.md`. Cite STE rules by number only. Never copy ASD-STE100 rule text or dictionary entries.
- `zig build lint-docs` does not check `CHANGELOG.md`. Write new changelog entries in the profile, but do not rewrite released entries. Record a correction under `[Unreleased]`.
- Before you commit, run `zig build fmt test lint-docs`. After you commit and before you push, run `zig build commit-policy`. It checks the commits of `origin/main..HEAD`.
- The plan of record is the wiki page [Roadmap](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Roadmap). It has the milestones and their state.
