# Metria Desktop (Electron)

This is a parallel Electron implementation of Metria for Windows, Linux, and
macOS. It does the same job as the native macOS application, but it is a
separate app and does not replace or import the native SwiftUI/AppKit code.

## Development

```sh
cd apps/electron
npm ci
npm run check
npm run dev
npm run package
```

`npm run package` creates host-native Electron artifacts in `release/`; it does
not publish them. The existing native macOS application remains verified from
the repository root with `swift build`.

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

| Capability | Native macOS | Electron macOS | Electron Windows/Linux |
| --- | --- | --- | --- |
| Dashboard, tray, provider controls | Yes | Yes | Build support; runtime validation required |
| Side notch | Yes | Tray badges per provider | Usage widget window; tray is unavailable to Linux apps under WSLg |
| Hosted-PWA QR pairing | Yes | No | No |
| Launch at login | macOS service | Electron login item | XDG desktop-autostart entry |
| Claude credentials | macOS Keychain | Existing macOS Keychain, read-only | Unsupported until a verified platform convention is implemented |

Codex discovery uses `CODEX_HOME` or `~/.codex`; OpenCode discovery uses
`XDG_DATA_HOME`/`~/.local/share` on Unix and `%APPDATA%` on Windows. These
read-only locations are fixture-tested, not runtime-tested on Windows/Linux.

Use `METRIA_SYNTHETIC=1 npm run dev` for a no-credential, no-provider-network
smoke run. It generates synthetic provider data.

## Provider status

- Codex: reads the same Unix-style session locations as native Metria when they
  exist. Windows paths are intentionally not guessed.
- OpenCode Go: reads the Unix auth file and calls the existing usage endpoint;
  Windows support awaits verified credential-path evidence.
- Claude: on macOS, reads the existing Claude Code Keychain entry without
  updating it; other platforms show an actionable unsupported state.

Windows and Linux packages must be created and runtime-tested on those systems;
they are not claimed as verified from macOS.
