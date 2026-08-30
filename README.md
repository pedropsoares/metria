# Metria

![Metria banner](https://i.imgur.com/JrV7abR.png)

A macOS menu-bar app that tracks your AI coding assistant usage in real time.

## What it does

Shows current session and monthly usage percentages for your AI providers, surfaced in three places:

- **Floating sidebar** — hover a provider logo to preview its usage card.
- **Menu bar** — compact text labels for each provider.
- **Dashboard popover** — ring gauges plus detailed per-provider cards.

Provider selection, display mode, and sidebar opacity are persisted in `UserDefaults`. The floating sidebar is fixed to the right side of the screen.

## Providers

- **Claude** — OAuth token read from the macOS Keychain, usage fetched from the Anthropic usage endpoint.
- **Codex / OpenCode** — credentials read from the local `~/.local/share/opencode/auth.json` and local session files.
- **OpenCode Go** — API key read from the same `auth.json`, usage fetched from the OpenCode Go endpoint.

Providers are enabled automatically only when their local credentials or usage files are detected. Providers that are not installed remain available in Settings with setup guidance.

Credentials are never committed. They are read at runtime from the Keychain and local config files described in [the provider sources](Sources/Metria/Providers/).

## iPhone PWA

The iPhone companion is a static PWA in `MetriaPWA/`. Build its Tailwind stylesheet before deploying:

```sh
npm ci
npm run build
```

The PWA can be deployed to any HTTPS static host. The Mac app currently uses the hosted pairing URL configured in `PairingManager`.

## Requirements

- macOS 13 or later
- A Swift toolchain (Swift 5.9+)

## Build and run

```sh
swift build
swift run Metria
```

To create a local macOS application archive:

```sh
bash scripts/package-macos.sh
```

This creates `dist/Metria-<version>-<architecture>.zip` and `.dmg`. For local signed distribution, set `CODESIGN_IDENTITY` to an installed Developer ID certificate. To notarize locally, also set `NOTARY_PROFILE` to a stored `notarytool` keychain profile. GitHub Releases build Intel and Apple Silicon archives automatically when a `v*` tag is pushed, then publish the signed Sparkle appcast as `releases/latest/download/appcast.xml`. Configure the Apple signing/notarization secrets and `SPARKLE_PUBLIC_ED_KEY` plus `SPARKLE_PRIVATE_ED_KEY` for automatic updates; without them, the app is intentionally built without a production update feed.

## Project layout

- `Sources/Metria/MetriaApp.swift` — app entrypoint, AppKit coordinator, pairing, and views.
- `Sources/Metria/Providers/` — provider implementations, credential readers, and provider registry.
- `Sources/MetriaCore/UsageStore.swift` — shared usage state, provider seam, and refresh/retry logic.
- `scripts/package-macos.sh` — reproducible macOS app bundle and archive builder.
