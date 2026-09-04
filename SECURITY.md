# Security Policy

## Supported versions

Metria ships a single rolling release line for the native macOS app: only the
[latest `macos-v*` release](https://github.com/yurirxmos/metria/releases)
receives security fixes. The app checks for updates automatically through
Sparkle, so users are expected to stay on the latest version. The mobile PWA
(`apps/pwa`) is deployed continuously to Cloudflare Workers, so only the
currently deployed build is supported.

## Reporting a vulnerability

Please report security vulnerabilities privately through
[GitHub Security Advisories](https://github.com/yurirxmos/metria/security/advisories/new)
instead of opening a public issue or posting in the contributors WhatsApp
group. This keeps the details out of public view until a fix is available.

Include as much of the following as you can:

- A description of the vulnerability and its potential impact.
- Steps to reproduce, or a proof of concept.
- The affected component (`apps/macos-native`, `apps/pwa`, or the pairing
  code in `apps/macos-native/Sources/MetriaCore`) and version/commit.

You should expect an initial response within a few days. If the issue is
confirmed, a fix will be prioritized and a coordinated release published
before public disclosure. Credit is given in the release notes unless you
prefer to stay anonymous.

## Scope

This policy covers:

- The native macOS app (`apps/macos-native`), including Keychain and local
  file access for provider credentials.
- The mobile companion PWA and its Cloudflare Worker (`apps/pwa`).
- The pairing protocol between the Mac app and the PWA
  (`apps/macos-native/Sources/MetriaCore/PairingSecret.swift` and
  `UsageSnapshot.swift`).

`PairingSecret.swift` and `UsageSnapshot.swift` are duplicated
byte-for-byte in [yurirxmos/metria-win-linux](https://github.com/yurirxmos/metria-win-linux)
because a phone pairs with either desktop app. A vulnerability in the pairing
derivation affects both repositories — report it in whichever repository you
found it, and the fix will be coordinated across both.

Vulnerabilities specific to the Windows/Linux Electron app should be reported
in [yurirxmos/metria-win-linux](https://github.com/yurirxmos/metria-win-linux)
instead.

## Out of scope

- Vulnerabilities in third-party provider APIs or CLIs that Metria reads
  usage from (Anthropic, Cursor, Antigravity's `agy` CLI, OpenCode). These
  endpoints and formats are not published or controlled by this project;
  report them to the respective vendor.
- Issues that require physical access to an already-unlocked device, or a
  compromised macOS Keychain.
- Denial of service against the local PWA pairing server, which is scoped to
  same-network use only.

## How Metria handles credentials

For context when evaluating a report: Metria reads provider credentials at
runtime and never commits or transmits them anywhere other than directly to
that provider's own usage endpoint from the user's Mac.

- **Claude** — OAuth token read from the macOS Keychain.
- **Codex / OpenCode / OpenCode Go** — credentials read from
  `~/.local/share/opencode/auth.json` and local session files.
- **Cursor** — session JWT read from Cursor's local `state.vscdb`.
- **Antigravity** — no credential is read; usage comes from running the
  locally installed `agy` CLI, which authenticates itself.

See the [native provider sources](apps/macos-native/Sources/Metria/Providers/)
for the exact implementation of each reader.
</content>
</invoke>
