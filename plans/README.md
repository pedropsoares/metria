# Implementation Plans

Generated on 2026-08-31 at commit `f5bbbe2`. This is a planning-only migration
assessment. Execute the plan in order; it deliberately begins with a proof of
concept rather than committing the project to a framework before its difficult
desktop integrations are demonstrated.

## Execution order & status

| Plan | Title | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| 001 | Add a maintainable Electron companion without replacing native macOS | P1 | L | — | TODO |

## Dependency notes

- The framework decision gate in phase 1 blocks all production-port work. Do
  not start platform UI, credential migration, or release automation until the
  proof of concept passes on all three operating systems.

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
