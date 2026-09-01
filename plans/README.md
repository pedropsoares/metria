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

## Dependency notes

- The framework decision gate in phase 1 blocks all production-port work. Do
  not start platform UI, credential migration, or release automation until the
  proof of concept passes on all three operating systems.
- Plan 002 phase 0 is a research gate shared by both Cursor plans: it must
  establish, on a real machine, where Cursor keeps its credential and which
  usage endpoint answers for an individual account. Plan 003 consumes those
  findings and must not re-derive them. Once that gate passes, 002 and 003 can
  be implemented in parallel; neither blocks the other.

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
- A single cross-app Cursor implementation: rejected for the same reason. The
  two Cursor plans share the fixture database and the recorded endpoint
  contract, not code.
- Deriving Cursor usage by counting local Cursor session files: rejected. That
  records requests made, not the account quota, so any percentage would be
  invented rather than measured.
