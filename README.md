# Metria

*A macOS menu-bar app that tracks your AI coding assistant usage in real time.*

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

## Providers

- **Claude** — OAuth token read from the macOS Keychain, usage fetched from the Anthropic usage endpoint.
- **Codex / OpenCode** — credentials read from the local `~/.local/share/opencode/auth.json` and local session files.
- **OpenCode Go** — API key read from the same `auth.json`, usage fetched from the OpenCode Go endpoint.

Providers are enabled automatically only when their local credentials or usage files are detected. Providers that are not installed remain available in Settings with setup guidance.

Credentials are never committed. They are read at runtime from the Keychain and local config files described in [the provider sources](Sources/Metria/Providers/).

## iPhone PWA

Metria serves the iPhone companion locally from your Mac by default. Start Metria, then scan the QR code in **Settings > iPhone** while the iPhone and Mac are on the same Wi-Fi network. The local server port defaults to `8973` and can be changed in Settings; if it is in use, Metria tries subsequent ports automatically.

Local HTTP access works in Safari but cannot be installed as an offline PWA because iOS requires HTTPS for that capability. Metria uses the hosted Cloudflare PWA by default at `https://metria-pwa.yuriramos2406.workers.dev`. Clear **Settings > iPhone > Custom PWA URL** to pair through the local server instead. Build and deploy the static files with:

```sh
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
bash scripts/package-macos.sh
```

This creates `dist/Metria-<version>-<architecture>.zip` and `.dmg`. GitHub Releases build Intel and Apple Silicon archives automatically when a `v*` tag is pushed, then publish the signed Sparkle appcast as `releases/latest/download/appcast.xml`. Configure `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_PRIVATE_ED_KEY` for automatic updates. Apple Developer ID signing and notarization are optional while the project is in development; without them, the archive is unsigned and macOS may show a Gatekeeper warning.

## Project layout

- `Sources/Metria/MetriaApp.swift` — app entrypoint, AppKit coordinator, pairing, and views.
- `Sources/Metria/Providers/` — provider implementations, credential readers, and provider registry.
- `Sources/MetriaCore/UsageStore.swift` — shared usage state, provider seam, and refresh/retry logic.
- `scripts/package-macos.sh` — reproducible macOS app bundle and archive builder.

## Contributing

Contributions are welcome! Feel free to open an issue to report a bug or suggest a feature, or open a pull request with your changes.

- Fork the repository and create a branch from `main`.
- Keep changes focused and follow the existing code style.
- Run `swift build` from the repository root to verify the package compiles.
- For the iPhone PWA, build its stylesheet with `npm ci && npm run build`.
- Keep all repository text in en-US (comments, UI strings, commit messages, docs).
- Do not commit credentials, generated `.build/` output, or local configuration.

See the [project layout](#project-layout) to find where each change belongs. Thanks for helping out!

## License

Metria is open source under MIT; see [LICENSE](LICENSE).
