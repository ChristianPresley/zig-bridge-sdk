## Summary

Tell what the change does in one or two sentences.

## Checklist

- [ ] `zig build fmt test` passes.
- [ ] `zig build commit-policy` passes.
- [ ] Legacy protocol behavior stays in this repository. The modern side uses zig-sdk.
- [ ] A change of the zig-sdk pin updates the compatibility table of the README and names the zig-sdk version in `CHANGELOG.md`.
- [ ] New behavior has a test.

## Prose and documentation

- [ ] `zig build lint-docs` passes. The step uses `--strict` and `--string-literals`.
- [ ] New prose in the README, the doc comments and the messages obeys the project profile of ASD-STE100 in `docs/style/ste-profile.md`.
- [ ] Each new public declaration has a doc comment with a summary that ends with a period.
- [ ] A new word, abbreviation or technical noun is in `docs/dictionary/`, and `zig build gen-dictionary` wrote the new page.
- [ ] The change disables no lint rule. Only quoted text is exempt.
- [ ] The prose cites ASD-STE100 rules by number only and copies no text of the standard.
- [ ] The wiki pages that describe the changed behavior are up to date, and `zig build lint-docs -- --strict --wiki-dir ../zig-bridge-sdk.wiki` passes.
