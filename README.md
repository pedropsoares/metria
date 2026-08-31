# Metria

*A native macOS app and parallel Electron app that track your AI coding assistant usage in real time.*

<p align="center">
  <img src="https://i.imgur.com/JrV7abR.png" alt="Metria banner" width="480" />
</p>

<p align="center">
  <a href="https://github.com/yurirxmos/metria/stargazers"><img src="https://img.shields.io/github/stars/yurirxmos/metria?style=flat-square" alt="Stars" /></a>
  <a href="https://github.com/yurirxmos/metria/releases"><img src="https://img.shields.io/github/v/tag/yurirxmos/metria?label=version&style=flat-square" alt="Version" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License" /></a>
  <a href="https://github.com/yurirxmos/metria/commits"><img src="https://img.shields.io/github/commit-activity/m/yurirxmos/metria?style=flat-square" alt="Commits" /></a>
</p>

## What it does

Shows current session and monthly usage percentages for your AI providers, surfaced in three places:

- **Floating sidebar** — hover a provider logo to preview its usage card.
- **Menu bar** — compact text labels for each provider.
- **Dashboard popover** — ring gauges plus detailed per-provider cards.

Provider selection, display mode, and sidebar opacity are persisted in `UserDefaults`. The floating sidebar is fixed to the right side of the screen.

## Download

Pick your platform, open the installer, and you're all set—after that, Metria keeps itself up to date.

<p align="center">
  <a href="https://github.com/yurirxmos/metria/releases">
    <img src="https://img.shields.io/badge/Download%20for%20macOS-000000?style=for-the-badge&logo=apple" alt="Download for macOS" />
  </a>
  <a href="https://github.com/yurirxmos/metria/releases">
    <img src="https://img.shields.io/badge/Download%20for%20Windows%20%2F%20Linux-0078d4?style=for-the-badge" alt="Download for Windows and Linux" />
  </a>
</p>

Prefer to see what you're getting? Browse all installers on the [Releases page](https://github.com/yurirxmos/metria/releases).

## Providers

- **Claude** — OAuth token read from the macOS Keychain, usage fetched from the Anthropic usage endpoint.
- **Codex / OpenCode** — credentials read from the local `~/.local/share/opencode/auth.json` and local session files.
- **OpenCode Go** — API key read from the same `auth.json`, usage fetched from the OpenCode Go endpoint.

Providers are enabled automatically only when their local credentials or usage files are detected. Providers that are not installed remain available in Settings with setup guidance.

Credentials are never committed. The native macOS app reads them at runtime from the Keychain and local config files described in [the provider sources](apps/macos-native/Sources/Metria/Providers/). Electron has its own documented provider-support boundaries in [apps/electron](apps/electron/).

## iPhone PWA

Metria serves the iPhone companion locally from your Mac by default. Start Metria, then scan the QR code in **Settings > iPhone** while the iPhone and Mac are on the same Wi-Fi network. The local server port defaults to `8973` and can be changed in Settings; if it is in use, Metria tries subsequent ports automatically.

Local HTTP access works in Safari but cannot be installed as an offline PWA because iOS requires HTTPS for that capability. Metria uses the hosted Cloudflare PWA by default at `https://metria-pwa.yuriramos2406.workers.dev`. Clear **Settings > iPhone > Custom PWA URL** to pair through the local server instead. Build and deploy the static files with:

```sh
cd apps/pwa
npm ci
npm run build
npm run deploy
```

You can replace the Cloudflare URL in **Settings > iPhone > Custom PWA URL** with any HTTPS static host.

### iPhone alerts

Install the Cloudflare-hosted PWA on your iPhone with **Add to Home Screen**, open it, and select **Enable alerts**. Metria sends the current provider usage whenever the Mac app publishes a new snapshot. The local HTTP server cannot provide system notifications because iOS requires HTTPS for Web Push.

## Requirements

- macOS 13 or later
- A Swift toolchain (Swift 5.9+)
- Xcode 26.0+ and XcodeGen for opening and building the Xcode project

## Quick start

### Install Metria

Download the latest `.dmg` from [GitHub Releases](https://github.com/yurirxmos/metria/releases), choosing the package for your Mac:

- **Apple Silicon** — M-series Macs.
- **Intel** — Intel-based Macs.

Open the disk image, drag `Metria.app` to `Applications`, and launch it from Finder or Spotlight. Metria runs in the menu bar and does not open a regular application window.

### Launch at login

After installing Metria as an app, open **Settings > General**, enable **Launch at login**, and approve Metria in **System Settings > General > Login Items** if macOS requests approval.

The startup option is available for the installed `.app`. It is not registered when running the development command below.

### Run in development

```sh
swift build
swift run Metria
```

To create a local macOS application archive for installation:

```sh
bash apps/macos-native/scripts/package-macos.sh
```

To build the Xcode application without Apple Developer signing credentials:

```sh
xcodegen generate
xcodegen generate --spec apps/macos-native/project.yml
xcodebuild -project apps/macos-native/Metria.xcodeproj -scheme Metria -configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The generated `Metria.app` is at `.build/xcode/Build/Products/Release/Metria.app`.
The Xcode project disables signing by default for local development. A future
Developer ID build can override `CODE_SIGNING_ALLOWED`, `CODE_SIGNING_REQUIRED`,
and `CODE_SIGN_IDENTITY` from the command line or an xcconfig.

This creates `dist/Metria-<version>-<architecture>.zip` and `.dmg`. GitHub Releases build Intel and Apple Silicon archives automatically when a `v*` tag is pushed, then publish the signed Sparkle appcast as `releases/latest/download/appcast.xml`. Configure `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_PRIVATE_ED_KEY` for automatic updates. Apple Developer ID signing and notarization are optional while the project is in development; without them, the archive is unsigned and macOS may show a Gatekeeper warning.

## Project layout

- `apps/macos-native/Sources/Metria/MetriaApp.swift` — native macOS entrypoint, AppKit coordinator, pairing, and views.
- `apps/macos-native/Sources/Metria/Providers/` — native macOS provider implementations and credential readers.
- `apps/macos-native/Sources/MetriaCore/UsageStore.swift` — native usage state, provider seam, and refresh/retry logic.
- `apps/macos-native/scripts/package-macos.sh` — reproducible native macOS app bundle and archive builder.
- `apps/electron/` — parallel Electron implementation with secure main/preload/renderer boundaries.
- `apps/pwa/` — iPhone companion PWA and its Cloudflare Worker (`public/` holds the static site, `src/worker.js` the Worker).

## Contributing

Contributions are welcome! Feel free to open an issue to report a bug or suggest a feature, or open a pull request with your changes.

- Fork the repository and create a branch from `main`.
- Keep changes focused and follow the existing code style.
- Run `swift build` from the repository root to verify the package compiles.
- For the iPhone PWA, build its stylesheet with `cd apps/pwa && npm ci && npm run build`.
- Keep all repository text in en-US (comments, UI strings, commit messages, docs).
- Do not commit credentials, generated `.build/` output, or local configuration.

See the [project layout](#project-layout) to find where each change belongs. Thanks for helping out!

## License

Metria is open source under MIT; see [LICENSE](LICENSE).
