# Contributing to Metria

Thanks for taking the time to contribute! This guide covers everything you need to set up your environment, understand the project layout, and submit a change.

This repository holds the **native macOS app** and the **mobile companion PWA**. The Windows/Linux Electron app lives in [yurirxmos/metria-win-linux](https://github.com/yurirxmos/metria-win-linux) — see [Related repositories](README.md#related-repositories) for how the two stay in sync.

## Contents

- [Before you start](#before-you-start)
- [Requirements](#requirements)
- [Project layout](#project-layout)
- [Development loop](#development-loop)
- [Adding or moving source files](#adding-or-moving-source-files)
- [Mobile PWA changes](#mobile-pwa-changes)
- [Code style](#code-style)
- [Testing your change](#testing-your-change)
- [Submitting a pull request](#submitting-a-pull-request)
- [What not to commit](#what-not-to-commit)
- [Getting help](#getting-help)

## Before you start

- Open an issue first for anything beyond a small fix — a bug report, a feature idea, or a proposed change in behavior — so we can align on the approach before you put time into it.
- Check open issues and pull requests to avoid duplicate work.
- For questions, feedback, or to talk through an idea before opening an issue, join the [Metria contributors group on WhatsApp](https://chat.whatsapp.com/KE2hbxgNmWYAyrUrjvU6Br?s=cl&p=i&mlu=4).

## Requirements

- macOS 13 or later
- A Swift toolchain (Swift 5.9+) for building from source
- Xcode 26.0+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for opening and building the Xcode project
- Node.js and npm, only if you're working on the [mobile PWA](#mobile-pwa-changes)

## Project layout

- `apps/macos-native/Sources/Metria/MetriaApp.swift` — native macOS entrypoint, AppKit coordinator, pairing, and views.
- `apps/macos-native/Sources/Metria/Providers/` — native macOS provider implementations and credential readers.
- `apps/macos-native/Sources/MetriaCore/UsageStore.swift` — native usage state, provider seam, and refresh/retry logic.
- `apps/macos-native/Resources/AppIcon.icon` — Icon Composer source for the native app icon.
- `apps/macos-native/scripts/package-macos.sh` — reproducible native macOS app bundle and archive builder.
- `apps/macos-native/scripts/dev-run.sh` — fast local dev build and launch, used by `make run`.
- `apps/macos-native/project.yml` — XcodeGen spec that generates `Metria.xcodeproj`.
- `apps/pwa/` — mobile companion PWA and its Cloudflare Worker (`public/` holds the static site, `src/worker.js` the Worker).

## Development loop

Build and launch the app locally with:

```sh
make run
```

This builds the current working tree (including uncommitted changes) as a real, unsigned Debug `.app` via `xcodebuild` and launches it — unlike `swift run`, it produces a proper `CFBundleIdentifier` and a compiled String Catalog, which some app behavior depends on. It quits any running `Metria` instance first, then rebuilds and relaunches, so it's the loop to keep running while you iterate.

To just verify the Swift package compiles, without building the full app bundle:

```sh
swift build
```

Metria is a menu-bar app and does not open a regular application window — look for it in the menu bar after `make run` finishes.

## Adding or moving source files

`swift build` passing is **not** sufficient to know a new file compiles for release: native release archives are built via `xcodebuild` against the checked-in `Metria.xcodeproj`, not SwiftPM directly. Any new file added under `apps/macos-native/Sources/` must also be added to the Xcode project, or `xcodebuild` (and `make run`) will fail to find its types while `swift build` stays green.

Regenerate the project after adding, removing, or moving a source file:

```sh
xcodegen generate --spec apps/macos-native/project.yml
```

Then commit the regenerated `Metria.xcodeproj` along with your change.

## Mobile PWA changes

```sh
cd apps/pwa
npm ci
npm run build
```

`npm run build` copies the shared provider logos from `Assets/` and compiles the Tailwind stylesheet. `npm run deploy` publishes to the hosted Cloudflare Worker — maintainers handle deploys for the hosted PWA; you generally only need `npm run build` to verify your change locally.

## Code style

- Keep all repository text in en-US: comments, UI strings, commit messages, and documentation. Do not add other languages, including in strings intended for a specific locale's catalog — localization is handled through the String Catalog, not by writing non-English text directly.
- Keep changes focused and follow the existing code style in the file you're editing.
- Preserve existing `UserDefaults` keys when changing settings behavior — provider selection, display mode, sidebar position, and opacity are persisted through them, and other code (and the phone pairing flow) may depend on those keys staying stable.

## Testing your change

- Runtime-test native macOS changes on macOS 13 or later — `make run` is the fastest way to do this.
- CI (`.github/workflows/macos-ci.yml`) runs `swift build` and a full Release `xcodebuild` on every pull request that touches native app files; make sure both succeed locally before opening a PR.
- If you touched `apps/macos-native/Sources/MetriaCore/PairingSecret.swift` or `UsageSnapshot.swift`, the pairing derivations must stay byte-identical with the copies in `metria-win-linux` — one phone pairs with either desktop app, and changing a derivation in only one repository breaks pairing. Flag this in your PR description so the corresponding change can be made in the other repository.

## Submitting a pull request

- Fork the repository and create a branch from `main`.
- Keep pull requests focused on a single change; unrelated cleanups make review harder and are easier to land as a separate PR.
- Describe what changed and why in the PR description, and mention any manual testing you did.
- Reference the issue your PR addresses, if any.

## What not to commit

- Credentials, API keys, or tokens. Metria reads provider credentials at runtime from the Keychain and local configuration files — see the [native provider sources](apps/macos-native/Sources/Metria/Providers/) — and none of that should ever be committed.
- Generated build output (`.build/`, `dist/`) or local configuration.

## Getting help

Join the [Metria contributors group on WhatsApp](https://chat.whatsapp.com/KE2hbxgNmWYAyrUrjvU6Br?s=cl&p=i&mlu=4) to ask questions, share feedback, and help shape the project.
