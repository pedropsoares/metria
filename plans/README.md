# Implementation Plans

Planning-only documents. Each plan records the state of the code at the commit
it was written against and must be re-checked with its own drift check before
implementation. Plan 001 is a migration assessment that deliberately begins
with a proof of concept rather than committing the project to a framework
before its difficult desktop integrations are demonstrated. Plans 002 and 003
add a single provider to each desktop app and begin with a research gate
rather than committing to an undocumented vendor endpoint sight unseen.

## Execution order & status

| Plan | Title | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| 001 | Add a maintainable Electron companion without replacing native macOS | P1 | L | — | TODO |
| 002 | Add a Cursor usage provider to the native macOS app | P2 | M | — | TODO |
| 003 | Add a Cursor usage provider to the Electron app | P2 | M | 002 (phase 0) | TODO |
| 004 | Add a native iOS companion with Home Screen and Lock Screen widgets | P2 | L | — | TODO |

## Dependency notes

- The framework decision gate in phase 1 blocks all production-port work. Do
  not start platform UI, credential migration, or release automation until the
  proof of concept passes on all three operating systems.
- Plan 002 phase 0 is a confirmation step shared by both Cursor plans: the
  credential location and the usage endpoint are documented in Plan 002's
  Evidence section, but they are not a published Cursor contract, so they must
  be confirmed against the Cursor version at hand before code is written. Plan
  003 consumes those findings and must not re-derive them. Once confirmed, 002
  and 003 can be implemented in parallel; neither blocks the other.
- Plan 004 phase 0 is a device gate, not a formality: App Groups, Keychain
  sharing, and Local Network access from inside a widget extension must be
  measured on a real iPhone with the intended signing team before any product
  code is written. The Local Network answer decides only which process owns the
  LAN transport, because plan 004 keeps the existing encrypted relay as a
  fallback. Whether App Groups is available to a free Personal Team
  is deliberately not asserted in the plan — it is measured, because it decides
  whether the paid membership is a convenience or a precondition.

## Findings considered and rejected

- Separate repositories per desktop OS: rejected. The existing native macOS
  app, Electron companion, PWA, assets, provider contracts, and releases should
  evolve together but be built and released in isolated lanes.
- Replacing or rewriting the native Swift macOS app: rejected. It remains the
  production macOS application. Electron is a separately identified companion
  app that may be offered on macOS only after it coexists safely.
- A direct Swift cross-compile or SwiftUI reuse in Electron: rejected. The
  current executable is macOS-native and Electron cannot import SwiftUI/AppKit;
  only versioned data/protocol contracts and test fixtures may be shared.
- Replacing the companion PWA with the iOS app: rejected for now. The PWA is
  the only Android path and must keep parsing the same snapshot JSON; the iOS
  app ships alongside it and shares the transport contracts, not the code.
- A WebView shell or a cross-platform framework for iOS: rejected. The
  deliverable is a WidgetKit extension, which every wrapper reimplements in
  Swift anyway, and widgets cannot render web content.
- A single transport for the iOS widget, either LAN-only or relay-only:
  rejected. The local path is the freshest and involves no third party, and the
  encrypted relay the Mac already publishes to is what keeps the widget useful
  on cellular; plan 004 runs both in that order.
- A single cross-app Cursor implementation: rejected for the same reason. The
  two Cursor plans share the fixture database and the recorded endpoint
  contract, not code.
- Deriving Cursor usage by counting local Cursor session files: rejected. That
  records requests made, not the account quota, so any percentage would be
  invented rather than measured.
- Making the iOS app fully standalone and retiring the Mac mirror: rejected.
  None of the four provider credentials the Mac reads (Claude Keychain OAuth,
  Cursor's session JWT, the OpenCode-managed Codex token, the OpenCode Go key)
  can be discovered by the phone on its own, and Cursor's own dashboard API key
  was confirmed not to authenticate its usage RPC even though the RPC accepted
  the key everywhere else — so the Mac mirror stays the only universal path.
