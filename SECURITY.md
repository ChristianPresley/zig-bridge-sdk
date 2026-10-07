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

The wiki page [Threat-Model](https://github.com/ChristianPresley/zig-bridge-sdk/wiki/Threat-Model) holds the security design of the bridges. For each security requirement, that page gives the milestone, the module and the test. At milestone M0, each requirement is a plan.

A bridge stands between its client and an upstream server. The threat model has these trust boundaries:

- The model trusts the client, for example VS Code, and the user of the client.
- The model does not trust the upstream server or its authorization server. The bridge must check what they send before the client gets it.

[^zig-sdk-security]: Security policy of zig-sdk. https://github.com/ChristianPresley/zig-sdk/blob/main/SECURITY.md
