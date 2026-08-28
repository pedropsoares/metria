# Agent Instructions

- All repository text must be en-us, including Swift comments, UI strings, commit messages, and documentation; do not add Portuguese text.
- This is a Swift Package executable targeting macOS 13+, with the application entrypoint in `Sources/Metria/MetriaApp.swift`.
- The app is a menu-bar AppKit application whose dashboard, settings, and floating sidebar are SwiftUI views coordinated by `AppDelegate`.
- Run `swift build` from the repository root for the required verification; run `swift test` for the core test suite.
- The core usage and refresh logic lives in the `MetriaCore` library target (`Sources/MetriaCore`), tested by `Tests/MetriaCoreTests`.
- The package manifest explicitly lists the source file and copies provider logos from `Logos/`; update `Package.swift` when adding or moving bundled assets.
- Usage credentials are read from macOS Keychain and local OpenCode/Codex files; do not commit credentials, generated `.build/` output, or local configuration.
- Provider selection, display mode, dock side, and sidebar opacity are persisted through `UserDefaults`; preserve these keys when changing settings behavior.
