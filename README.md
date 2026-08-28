# Metria

![Metria banner](https://i.imgur.com/JrV7abR.png)

A macOS menu-bar app that tracks your AI coding assistant usage in real time.

## What it does

Shows current session and monthly usage percentages for your AI providers, surfaced in three places:

- **Floating sidebar** — hover a provider logo to preview its usage card.
- **Menu bar** — compact text labels for each provider.
- **Dashboard popover** — ring gauges plus detailed per-provider cards.

Provider selection, display mode, dock side, and sidebar opacity are persisted in `UserDefaults`.

## Providers

- **Claude** — OAuth token read from the macOS Keychain, usage fetched from the Anthropic usage endpoint.
- **Codex / OpenCode** — credentials read from the local `~/.local/share/opencode/auth.json` and local session files.
- **OpenCode Go** — API key read from the same `auth.json`, usage fetched from the OpenCode Go endpoint.

Credentials are never committed. They are read at runtime from the Keychain and local config files described [in the source](Sources/Metria/MetriaApp.swift).

## Requirements

- macOS 13 or later
- A Swift toolchain (Swift 5.9+)

## Build and run

```sh
swift build
swift run Metria
```

## Test

```sh
swift test
```

The `MetriaCore` module isolates the usage refresh and retention rules behind an injectable provider seam, which is what the tests exercise.

## Project layout

- `Sources/Metria/MetriaApp.swift` — app entrypoint, providers, and views.
- `Sources/MetriaCore/UsageStore.swift` — shared usage state, provider seam, and refresh/retry logic.
- `Tests/MetriaCoreTests/` — tests for the usage store.
