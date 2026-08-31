// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Metria",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Metria", targets: ["Metria"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "MetriaCore", path: "apps/macos-native/Sources/MetriaCore"),
        .executableTarget(
            name: "Metria",
            dependencies: ["MetriaCore", .product(name: "Sparkle", package: "Sparkle")],
             path: ".",
             exclude: ["AGENTS.md", "README.md", "LICENSE", ".build", "dist", "node_modules", ".github", ".agents", ".claude", "scripts", "src", "plans", "skills-lock.json", "package.json", "package-lock.json", "tailwind.config.js", "wrangler.jsonc", "MetriaPWA/tailwind.input.css", "MetriaPWA/claude-logo.png", "MetriaPWA/codex-logo.png", "MetriaPWA/opencode-logo.png", "MetriaPWA/metria-logo.png", "MetriaPWA/metria-mascot.png", "Assets/Metria.iconset", "apps/electron", "apps/macos-native/Sources/MetriaCore", "apps/macos-native/Metria.xcodeproj", "apps/macos-native/project.yml", "apps/macos-native/scripts"],
            sources: [
                "apps/macos-native/Sources/Metria/MetriaApp.swift",
                "apps/macos-native/Sources/Metria/MetriaResources.swift",
                "apps/macos-native/Sources/Metria/LocalNetwork.swift",
                "apps/macos-native/Sources/Metria/LocalPWAServer.swift",
                "apps/macos-native/Sources/Metria/Providers/ClaudeProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/CodexProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/KeychainReader.swift",
                "apps/macos-native/Sources/Metria/Providers/OpenCodeGoProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/ProviderError.swift",
                 "apps/macos-native/Sources/Metria/Providers/ProviderKind+Presentation.swift",
                 "apps/macos-native/Sources/Metria/Providers/ProviderRegistry.swift",
                 "apps/macos-native/Sources/Metria/Updater.swift"
             ],
             resources: [
                 .copy("Assets/Metria.icns"),
                 .copy("Assets/claude-logo.png"),
                .copy("Assets/codex-logo.png"),
                .copy("Assets/metria-logo.png"),
                .copy("Assets/metria-mascot.png"),
                .copy("Assets/opencode-logo.png"),
                .copy("MetriaPWA/app.css"),
                .copy("MetriaPWA/app.js"),
                .copy("MetriaPWA/icon.svg"),
                .copy("MetriaPWA/index.html"),
                .copy("MetriaPWA/jsQR.js"),
                .copy("MetriaPWA/manifest.json"),
                .copy("MetriaPWA/pairing.js"),
                .copy("MetriaPWA/scanner.js"),
                .copy("MetriaPWA/sw.js"),
                .copy("MetriaPWA/wordlist.js")
            ]
        )
    ]
)
