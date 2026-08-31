# Plan 001: Add a maintainable Electron companion without replacing native macOS

> **Executor instructions**: Follow this plan in order. This is a migration
> plan, not authorization to rewrite the current app wholesale. Each phase has
> an explicit gate. If a gate fails, stop and record the evidence in the
> decision record; do not hide platform failure behind conditional code or ship
> a weaker version without a product decision.
>
> **Drift check (run first)**: `git diff --stat f5bbbe2..HEAD -- Package.swift Sources/Metria Sources/MetriaCore MetriaPWA src scripts project.yml .github package.json`
> If any listed path has changed, compare the current behavior described below
> with the live code and update this plan before implementation.

## Status

- **Priority**: P1
- **Effort**: L (three desktop releases plus a protocol-bound companion PWA)
- **Risk**: HIGH
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `f5bbbe2`, 2026-08-31

## Decision

Keep **one repository**. Preserve the existing native Swift/AppKit/SwiftUI macOS
app as the production macOS application and leave its present source layout in
place. Add a **separate Electron + TypeScript desktop companion** under
`apps/electron`, targeting Windows and Linux first and macOS only as an
explicitly separate, co-installable artifact. It must use a different bundle
identifier, application-data directory, keychain-service namespace, updater
feed/channel, executable name, and release asset prefix from native Metria.

Electron is the selected direction. It can provide a shared Chromium-rendered
desktop UI and tray APIs across all three targets. Its engineering cost is its
main/renderer/preload security boundary and runtime weight, both acceptable if
the app stays small and the privileged surface stays narrow. Electron requires
context isolation, sandboxed renderers, `nodeIntegration: false`, a narrow
`contextBridge`, local packaged content, CSP, sender validation, permission
handling, and current dependency updates: https://www.electronjs.org/docs/latest/tutorial/security/.
Electron's tray guide confirms tray support across the targets but documents
Linux desktop-environment differences: https://www.electronjs.org/docs/latest/tutorial/tray/.

Do not build new Windows/Linux shells around the present native Swift app and
do not attempt direct Swift/SwiftUI imports into Electron.
`Package.swift:6-16` declares macOS 13 only and the executable has direct
imports of AppKit, SwiftUI, Security, Network, ServiceManagement, and Sparkle
(`Sources/Metria/MetriaApp.swift:1-8`; `Sources/Metria/Updater.swift:1-29`). A
Swift-only port would still require independently written Windows and Linux
presentation, secure storage, tray, autostart, updater, local-network, and
packaging adapters, preserving little more than conceptual algorithms.

## Why this matters

Metria currently works because macOS APIs provide its menu-bar presence, edge
rail, credential access, launch-at-login, local HTTP server, QR image, and
updater. Electron must reimplement equivalent capabilities behind a secure
preload bridge; it cannot reuse AppKit/SwiftUI. The proposed boundary preserves
the native app and lets the companion share only documented protocol/schema
fixtures, avoiding parallel copies of undocumented behavior.

The effort is driven chiefly by credential discovery and desktop behavior, not
the dashboard. Validate platform support from the actual Codex, OpenCode, and
Claude credential formats on Windows and Linux before promising those providers
there. No claim about Windows versions, Linux desktop environments,
distributions, or architecture support is made by this plan.

## Verified current state

### Product flows

1. On launch, `AppDelegate` starts `UsageStore`, installs a macOS status item,
   popover, edge-attached notch panel, local PWA server, pairing state, and
   ntfy publisher (`Sources/Metria/MetriaApp.swift:1090-1113`).
2. `UsageStore` discovers available providers, restores cached usage, polls at
   five-minute intervals, fetches providers concurrently, caches successful
   windows, and schedules provider-specific retry-after work
   (`Sources/MetriaCore/UsageStore.swift:54-90`, `136-174`, `177-274`).
3. Claude reads and refreshes an OAuth document stored in the macOS Keychain
   using Security.framework and the `/usr/bin/security` executable
   (`Sources/Metria/Providers/KeychainReader.swift:4-60`); its usage request
   retries after a 401 (`Sources/Metria/Providers/ClaudeProvider.swift:4-64`).
4. Codex and OpenCode Go read `~/.local/share/opencode/auth.json`; Codex also
   scans `~/.codex/sessions` and parses the newest JSONL token-count event
   (`Sources/Metria/Providers/CodexProvider.swift:6-96`). OpenCode Go calls its
   usage endpoint with the local bearer credential and bounded 429 retry
   (`Sources/Metria/Providers/OpenCodeGoProvider.swift:4-80`).
5. A 128-bit pairing secret is generated with Security.framework, retained in
   macOS Keychain, rendered into QR/12 words, and deterministically derives an
   ntfy topic and AES-GCM key (`Sources/MetriaCore/PairingSecret.swift:12-82`,
   `Sources/Metria/MetriaApp.swift:21-130`). Usage snapshots are encrypted and
   published to an HTTPS ntfy server (`Sources/Metria/MetriaApp.swift:134-169`).
6. The bundled PWA uses the identical pairing protocol, subscribes to ntfy SSE,
   decrypts snapshots in Web Crypto, has a local HTTP polling fallback, and
   persists pairing/snapshot in `localStorage` (`MetriaPWA/pairing.js:1-113`,
   `MetriaPWA/app.js:83-119`, `159-225`). Cloudflare Worker endpoints retain
   push subscriptions/snapshots in KV and dispatch Web Push every five minutes
   (`src/worker.js:39-153`; `wrangler.jsonc:9-26`).
7. The UI has a dashboard popover, a mutually exclusive menu-bar display mode,
   and a custom non-activating right-edge side notch that expands leftward on
   provider hover, can be dragged vertically, hidden, resized, and has an
   opacity setting (`Sources/Metria/MetriaApp.swift:294-419`, `570-645`,
   `1225-1419`). Settings cover providers, launch at login, PWA, ntfy, and
   persisted display settings (`Sources/Metria/MetriaApp.swift:731-1087`).

### Storage, permissions, releases, and quality baseline

- `UserDefaults` stores enabled providers, cached usage, display mode, notch
  properties, local port, custom PWA URL, and ntfy URL (`UsageStore.swift:61-90,
  239-263`; `MetriaApp.swift:1115-1139`, `1279-1282`, `1409-1425`).
- The local server uses Apple Network.framework, binds a preferred port then up
  to 20 alternatives, exposes only bundled PWA files and an in-memory snapshot
  requiring `X-Metria-Secret` (`Sources/Metria/LocalPWAServer.swift:4-143`).
  The LAN address is selected with Darwin `getifaddrs` (`LocalNetwork.swift:1-28`).
- Packaging is macOS-only: an app bundle, DMG/ZIP, Sparkle framework,
  Developer-ID signing, optional notarization and signed Sparkle appcast
  (`scripts/package-macos.sh:15-93`; `.github/workflows/release.yml:1-105`).
- The repository has `swift build` and `npm ci && npm run build` documented
  (`README.md:66-120`) but no first-party tests, lint, typecheck, or CI tests
  were found. No build was run for this assessment, to preserve the user tree.

## Reuse versus replacement

| Area | Reuse strategy | Replacement required |
|---|---|---|
| Product vocabulary, provider windows/results, refresh/retry rules | Characterize with language-neutral JSON fixtures/contract tests; reimplement in TypeScript | Combine, `@MainActor`, `Task`, and `UserDefaults` coupling |
| Provider registry and response parsing | Reimplement in Electron main-process TypeScript with fixtures; keep endpoint semantics | macOS Security and Unix path assumptions |
| Pairing protocol | Treat as a versioned wire contract; preserve BIP-39-like phrase, HKDF labels, AES-GCM envelope | CryptoKit/Security random generation and QR rendering APIs |
| PWA and Cloudflare worker | Keep in the same repo; add protocol fixture tests | None initially; avoid copying desktop business rules into JS |
| Dashboard/settings/look and assets | Recreate from a written visual/interaction specification | SwiftUI/AppKit views and NSImage/SF Symbols |
| Tray, floating rail, autostart, secrets, paths, network listener, updater | Implement platform adapters behind stable commands | All current AppKit/Network/ServiceManagement/Sparkle code |

## Target repository architecture

```
metria/
  Sources/                        # existing native macOS app; do not move
  apps/
    electron/
      src/main/                   # privileged Electron main process
      src/preload/                # typed, allowlisted contextBridge only
      src/renderer/               # sandboxed TypeScript UI; no Node/Electron imports
      src/platform/               # credential/path/autostart/local-server adapters
      src/domain/                 # Electron-local provider orchestration and refresh state
      resources/                  # Electron-only icon derivatives and static content
      tests/
  packages/
    protocol-fixtures/            # JSON vectors/schema shared by Swift tests, Electron and PWA
    provider-fixtures/            # synthetic response/session fixtures only
  packages/
    desktop-contract/             # generated/hand-maintained TypeScript types only
  MetriaPWA/                      # existing companion web client
  src/worker.js                   # existing Cloudflare worker, migrate later only if justified
  docs/
    architecture.md
    platform-support.md
    provider-discovery.md
    pairing-protocol-v1.md
    release-operations.md
  scripts/
    check, test, package/         # thin, documented cross-platform entrypoints
  .github/workflows/
    verify.yml
    release-desktop.yml
```

This is one repository, one product vocabulary, one issue tracker, and a shared
release calendar—not one binary or one build system. Swift/Xcode stays where it
is and stays independently buildable; Electron owns its npm workspace. Do not
share source by relative imports between Swift and TypeScript. Share only
versioned JSON schemas/vectors and documented provider behavior. Electron main
process selects a small adapter interface; renderer code calls only the typed
preload API. No `process.platform` branches in renderer/domain code except an
isolated, reviewed adapter selection module. This makes ownership clear:

- protocol/fixture owner: schema/vector changes and Swift–TypeScript compatibility;
- Electron provider owner: endpoint/schema and credential discovery changes;
- Electron platform owner: OS storage, paths, LAN, startup, tray/window behavior;
- Electron UI owner: accessible views and approved preload capability calls;
- native macOS owner: `Sources/`, Xcode/Swift Package and Sparkle behavior;
- release owner: signing keys, installers, feed metadata, rollback.

Document a support policy instead of claiming generic "Linux" support. The
initial POC must name the tested Windows edition/architecture and at least two
named Linux desktop/distribution combinations; unsupported tray environments
must fall back to a normal window with a clearly documented limitation.

## Commands the new repository must expose

The migration must add these commands and document tool-version prerequisites in
`docs/development.md`; do not make contributors run undiscoverable platform
scripts. Exact commands are proposed targets, not verified current commands.

| Purpose | macOS / Windows / Linux command | Expected result |
|---|---|---|
| Install frontend | `npm ci` | locked JS dependencies installed |
| Format check | `npm run format:check && cargo fmt --check` | exit 0 |
| Electron static checks | `npm run electron:typecheck` | exit 0 |
| Unit/protocol tests | `npm run electron:test` plus Swift protocol tests | exit 0 |
| PWA build | `npm run pwa:build` | generated PWA CSS/assets only in ignored output |
| Run Electron | `npm run electron:dev` | tray/dashboard with local mock provider fixture |
| Package Electron host | `npm run electron:package` | companion artifact only |
| Native macOS verification | `swift build` | exit 0, unchanged native package |
| Full verification | `npm run check` | runs Electron/PWA checks; native lane runs `swift build` separately |

Use a single top-level task runner only if it is a thin wrapper around these
native commands. Pin Node, npm, Electron, and the packager versions; provide a
`justfile` or `mise.toml` only if the team wants it, but keep npm commands
canonical.

## Scope

**In scope**

- A phased cross-platform architecture and its proof-of-concept criteria.
- One repository, typed contracts, documentation, test fixtures, CI/release
  design, and a feature-parity policy.

**Out of scope**

- Immediate deletion or conversion of the working Swift app.
- Promising support for an untested Windows/Linux credential layout.
- Copying provider credentials into a new app-owned file or backend.
- Replacing the Cloudflare PWA/worker or adding a remote account system.
- Replacing native Metria on macOS, sharing its data container, or moving its
  existing Swift/Xcode files merely to make the repository look uniform.

## Phases and verification gates

### Phase 0: Freeze behavior in executable protocol and provider fixtures

1. Write `docs/architecture.md` with the verified flow above and a component
   diagram. Write `docs/pairing-protocol-v1.md` specifying exact byte lengths,
   word count/checksum, HKDF info values `metria-topic-v1` and `metria-key-v1`,
   AES-GCM combined envelope order, snapshot JSON schema, and versioning rule.
2. Add **non-secret, synthetic** fixtures for every provider success, malformed
   response, 401 refresh, rate-limit/retry-after, missing config, and newest
   session event. Add pairing test vectors produced from a fixed synthetic
   16-byte input, then independently verify them in Swift, Electron Node,
   browser JS,
   and Worker tests. Never add real home-directory files, Keychain exports,
   tokens, pairing phrases, subscriptions, or Cloudflare credentials.
3. Extract a behavior table from `UsageStore`: availability, enabled-provider
   persistence, cache restore, refresh interval, concurrent request behavior,
   failed result display, `empty` result semantics, and retry scheduling.
   Implement it as tests before porting its code.

**Gate**: `swift test` (after a test target is added), `cargo test --workspace`,
and browser/worker tests all pass against the same pairing fixtures; a deliberate
single-byte mutation fails decryption. Review confirms no test contains a live
credential or secret.

### Phase 1: Build a vertical cross-platform proof of concept

Build exactly one provider with a mocked credential source first, then one real
provider only after its target-local credentials are observed and documented.
The POC must demonstrate on macOS, Windows, and two selected Linux desktop
environments:

1. one tray icon and context menu; reopen dashboard from tray;
2. dashboard with cached fixture data and manual refresh;
3. secure pairing-secret persistence and reset; QR/link generation;
4. encrypted ntfy publish plus browser/PWA decrypt using the shared test vector;
5. a local-server alternative or an explicitly approved removal with a
   user-visible explanation; network bind must be LAN-only/scope-controlled and
   snapshot access must require the pairing secret;
6. autostart enable/disable; and
7. package/install/uninstall plus an update check using a non-production feed.

Do **not** port the right-edge floating notch in the POC. It is a distinct
window-manager interaction and must be evaluated after tray/dashboard parity.

**Electron acceptance gate**: each item passes on the named targets; renderer
preferences enforce `contextIsolation: true`, `sandbox: true`, and
`nodeIntegration: false`; no `ipcRenderer` is exposed directly; all native
commands are allowlisted, typed, and validate arguments/sender. Record
memory/startup metrics relative to native Metria rather than assuming equal
weight. Confirm tray actions manually because Linux tray activation behavior
varies by environment.

### Phase 2: Build the platform boundary before provider breadth

Create TypeScript interfaces in `apps/electron/src/platform` and write contract
tests using fakes. Electron main-process provider/domain services receive them
as injected dependencies; the renderer never receives their implementations:

- `SecretStore`: get/set/delete pairing secret and provider credentials; names
  service/account identifiers but never exposes a bulk-dump API.
- `SettingsStore`: typed Electron-companion settings and migration version. It
  must not read/write native Metria's `UserDefaults` container.
- `CredentialLocator`: return a `CredentialAvailability` or typed diagnostic,
  never raw path guesses scattered through providers.
- `UserPathResolver`: platform data/config/session locations with normalized,
  traversalsafe paths.
- `LocalSnapshotServer`: bind/start/stop/current endpoint, interface selection,
  port conflict handling, and authenticated snapshot response.
- `DesktopIntegration`: tray menu, dashboard visibility, autostart, external
  command launch, and updater status.

Implement adapters only in the Electron main process under
`src/platform/<os>/`. For a macOS Electron build, use a **new** keychain service
namespace and separate settings container; do not alter native Metria's current
Keychain items or `UserDefaults`. For Windows use a tested OS credential vault
implementation; for Linux use a tested Secret Service-compatible backend with a
documented fallback when no keyring is available. Both choices are assumptions
to validate in POC, not verified facts about current provider CLIs.

**Gate**: contract tests run unchanged on all three CI hosts; `rg
'process\.platform' apps/electron/src/renderer apps/electron/src/domain` returns
no matches; the renderer imports neither Node nor Electron modules; native
Metria does not import Electron files.

### Phase 3: Port providers and close credential-discovery unknowns

For each provider, maintain `docs/provider-discovery.md` with: supported
credential sources by OS, detection rules, minimum CLI/version if relevant,
read/write requirements, user-facing setup hint, and unsupported state.

- **Claude**: confirm Windows/Linux Claude Code credential storage and whether
  refresh-token writeback is supported/authorized. Do not infer that a macOS
  Keychain item or `security` CLI exists elsewhere. Until confirmed, surface
  "not detected/supported" rather than reading arbitrary browser/CLI files.
- **Codex**: confirm the official local auth/session paths and JSONL schema on
  each target. The current implementation is specifically Unix `~/.codex` and
  `~/.local/share/opencode` (`CodexProvider.swift:6-14`).
- **OpenCode Go**: confirm the auth path and response schema on each target;
  retain bounded retries and preserve no-token logging.

Use a provider capability matrix so a platform can ship with an explicit
unsupported provider status, not a broken toggle. A provider is not feature
complete merely because its network response parser compiles; it must be
discoverable from a real installation and pass synthetic regression fixtures.

**Gate per provider/OS**: synthetic parser/network tests pass; a manual test on
a throwaway account validates detection, fetch, expiration/reconnect, missing
credential behavior, rate limit, and no secret in diagnostics/logs.

### Phase 4: Deliver UI parity intentionally

Use one responsive desktop frontend, but configure platform behavior through a
capability object provided at startup—not user-agent checks. Preserve feature
semantics, not pixel-identical macOS chrome:

| Capability | macOS target | Windows target | Linux target | Release rule |
|---|---|---|---|---|
| Tray / dashboard / settings | menu bar + popover | notification area + window | supported tray DEs + window fallback | required |
| Menu-text display | menu-bar label | tray tooltip/menu/dashboard label | same where tray available | required, native adaptation allowed |
| Side notch | native Metria keeps its current production experience; Electron is optional/co-installable | right-edge floating rail only if POC passes | opt-in only on tested DEs | deferred until POC; no silent imitation |
| Hover provider card / drag / opacity / hide / size | preserve | implement in own window only after POC | only where window manager permits | parity target, platform escape allowed |
| Provider controls/diagnostics | preserve | preserve | preserve | required |
| Launch at login | preserve | startup registration | desktop-session autostart | required with truthful status |
| Local PWA / QR / pairing reset | preserve | preserve | preserve | required |
| Secure secret storage | Keychain | OS vault | Secret Service/fallback policy | required |
| Updates | native Sparkle unchanged; Electron uses a distinct feed/channel | signed installer/feed | distro packages first, optional signed updater | required distribution policy |

Use a normal dashboard window as the reliable control surface everywhere. The
side rail is product differentiation but not a reason to compromise basic
Windows/Linux usability. On Windows and Linux, never claim that the rail is
edge-attached across multiple monitors/virtual desktops until manual tests
prove it. Electron documents explicit Linux tray variations, which also makes
this a real test requirement: https://www.electronjs.org/docs/latest/api/tray/.

**Gate**: Playwright/component tests cover dashboard/settings state with mocked
commands; manual accessibility and multi-monitor scripts pass per supported
platform; each deferred item is marked in `docs/platform-support.md` and release
notes.

### Phase 5: Distribution, updates, security, and operations

1. Split the present tag-only macOS workflow into `verify.yml` (Linux, Windows,
   macOS unit/type/protocol tests) and `release-desktop.yml` (host-native,
   reproducible packages). Cross-building is not a release substitute; sign and
   smoke-test installers on their target OS.
2. Establish artifact policy before public release: macOS universal or separate
   architectures, Windows installer choice and code-signing identity, and named
   Linux formats/repositories. Linux normally needs a distribution strategy,
   not an assumed self-updater; Electron's official updater similarly directs
   Linux users to distribution package managers.
3. Separate secrets by application and platform in CI: native Apple
   certificate/notary and Sparkle keys remain in the native lane; Electron
   Windows signing keys, Electron updater/feed credentials, and Cloudflare
   VAPID/KV access are separate least-privilege secrets. Rotate rather than
   copy an exposed value. Verify signing before upload and retain rollback
   artifacts.
4. Enforce a desktop CSP, local packaged content only, narrowly scoped native
   commands, allowlisted IPC/commands, validated untrusted URLs, HTTPS for
   remote endpoints, secret redaction, dependency updates, and a security
   review of LAN binding. With Electron fallback, additionally enforce
   `contextIsolation: true`, sandboxing, `nodeIntegration: false`, sender
   validation, and an intentionally tiny preload bridge; these are explicit
   Electron security requirements.
5. Add observability that contains no snapshots, tokens, paths, or pairing
   secrets: version, OS family, enabled provider kinds, error category, and
   updater outcome only with opt-in/clear privacy documentation.

**Gate**: CI verifies signatures, installer smoke tests, offline cached launch,
autostart, manual update/rollback, local-server auth rejection, and redaction
checks. Release notes enumerate supported OS/architectures/desktop environments
and known capability gaps.

### Phase 6: Coexistence and release operations

Ship Electron first as an opt-in Windows/Linux preview. Native Metria continues
as the stable macOS product indefinitely; there is no migration/retirement gate.
If an Electron macOS build is later offered, label it "Metria Desktop Preview",
give it a distinct bundle ID/application-support path/keychain namespace/update
channel, and test that it can run beside native Metria without duplicating
autostart, colliding local ports, mutating settings, or racing on provider
credential refresh. Do not promise data import between the variants; an export
feature requires its own approved plan.

## Test plan

- Domain: provider enable/disable, cache, poll, concurrency, empty/failed result,
  retry-after and cancellation behavior taken from `UsageStore`.
- Provider: fixtures for each documented response and failure; no live network
  in default CI.
- Protocol: Swift/Electron-Node/JS/Worker cross-language deterministic vectors and
  negative AES-GCM/phrase tests.
- Platform contracts: mock SecretStore/SettingsStore/LocalSnapshotServer/
  DesktopIntegration; host smoke tests for each real adapter.
- UI: component tests for zero/one/many providers, stale data/error, settings,
  keyboard navigation, contrast, reduced motion, and no-tray fallback.
- End-to-end: a synthetic provider publishes through desktop to the PWA; LAN
  unauthenticated snapshot requests fail; source credentials cannot be read by
  renderer/UI process.
- Release: host-built signed install/update/rollback/uninstall and manual
  multi-monitor/tray/desktop-environment checklist.

## Done criteria

- [ ] A framework decision record contains phase-1 evidence for all named
  targets and names any unsupported environments.
- [ ] One repository contains one documented product contract and no duplicated
  provider/refresh/pairing business rule across desktop shells.
- [ ] `npm run check`, `cargo test --workspace`, and PWA/worker protocol tests
  pass in CI on macOS, Windows, and Linux.
- [ ] Every provider has an OS-specific discovery support state validated from
  actual installations or explicitly marked unsupported.
- [ ] Every release artifact is host-built, signed as applicable, smoke-tested,
  and paired with its platform-appropriate update policy.
- [ ] The compatibility matrix and support policy are published in the README
  and release notes.
- [ ] `swift build` remains successful and native Metria's package/Xcode paths,
  bundle ID, Sparkle feed, settings, and Keychain ownership are unchanged.
- [ ] If Electron macOS is packaged, it is proven to coexist with native Metria
  without port, autostart, storage, credential-refresh, or updater collisions.

## STOP conditions

Stop and obtain a product decision if any of these occurs:

- A provider's Windows/Linux credential location, schema, or permitted
  writeback behavior cannot be verified from an actual installation.
- Secure storage is unavailable on a target and the only workaround is plaintext
  credentials or pairing secrets.
- The selected Linux desktop environment cannot provide a reliable tray or
  required local-server permission; ship a documented dashboard-only fallback
  or reduce support scope rather than pretending parity.
- The floating rail requires unsupported always-on-top/edge behavior or fails
  with multi-monitor/window-manager testing.
- The Electron implementation requires `nodeIntegration`, disabled sandbox or
  context isolation, broad raw IPC, or access to native Metria's storage in
  order to work.
- Any change would expose raw credential values, pairing phrases, VAPID private
  material, or subscriber data in logs, tests, source control, or telemetry.

## Maintenance notes

- Treat `metria-topic-v1` and `metria-key-v1` as protocol-versioned constants;
  changing either strands paired PWAs. Add v2 alongside v1 and migration UI if
  protocol evolution is ever required.
- Do not let the Cloudflare worker become the source of truth for desktop usage;
  it is notification delivery, while the desktop remains the provider client.
- Reviewers should reject platform `if` statements in domain/provider modules,
  raw filesystem/secret access from frontend code, and platform-specific copies
  of provider parsers.
- Keep UI assets platform-neutral (PNG/SVG source plus generated ICNS/ICO/Linux
  packaging assets) and generate derivatives in release tooling.
