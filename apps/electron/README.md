# Metria Electron

This is a parallel Electron implementation of Metria for Windows and Linux.
It does the same job as the native macOS application, but it is a separate app
and does not replace or import the native SwiftUI/AppKit code. macOS is served
exclusively by the native app, so Electron releases carry Windows/Linux
installers only.

## Development

```sh
cd apps/electron
npm ci
npm run check
npm run dev
npm run package
```

`npm run package` creates host-native Electron artifacts in `release/`; it does
not publish them. macOS packaging is not configured, so on macOS use the native
app instead, which remains verified from the repository root with
`swift build`.

## Architecture and security

- `src/main/` owns provider files, network calls, settings, tray, and IPC.
- `src/preload/` exposes only the typed `window.metria` methods.
- `src/renderer/` is sandboxed; it has no Node or Electron imports. The
  dashboard, usage widget, and hover card are React apps using TanStack Query
  and Tailwind v4, bundled by Vite into `dist/renderer/`.
- Browser windows use `contextIsolation: true`, `sandbox: true`, and
  `nodeIntegration: false`; every IPC method validates its sender and arguments.

Electron stores its settings in its own `com.metria.electron` application-data
namespace. It must not modify native Metria's UserDefaults, Keychain services,
Sparkle feed, or app bundle.

Phone pairing and phone sync (the hosted-PWA feature) are not included in the
Electron implementation. It does not run a loopback PWA server, generate pairing
links, or post encrypted snapshots to `ntfy.sh`.

## Parity and platform support

| Capability | Native macOS | Metria Electron |
| --- | --- | --- |
| Dashboard, tray, provider controls | Yes | Yes |
| Side notch | Yes | Usage widget window (Windows/Linux) |
| Hosted-PWA QR pairing | Yes | No |
| Launch at login | macOS service | Windows login item, XDG desktop-autostart entry |
| Auto-update | Sparkle, signed appcast | Yes, silent via GitHub Releases |
| Provider data from WSL | No | Yes: providers stored in WSL distros are discovered and selectable per provider |

## Provider data sources

Providers are discovered in the host filesystem and in every installed WSL
distro (Windows only). When the same provider has data in both places, the
dashboard asks which to track once, then remembers the choice in settings:

- Claude reads `~/.claude/.credentials.json` on the host and in WSL and calls
  the Anthropic usage endpoint with the stored access token.
- Codex reads `CODEX_HOME`/`~/.codex` (auth plus newest session) or the same
  files inside WSL.
- OpenCode Go reads `XDG_DATA_HOME`/`~/.local/share/opencode/auth.json` on Unix,
  `%APPDATA%` on Windows, or the WSL path.

These read-only locations are fixture-tested, not runtime-tested on
Windows/Linux.

Windows and Linux packages must be created and runtime-tested on those systems;
they are not claimed as verified from macOS.
