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
        .target(name: "MetriaCore", path: "Sources/MetriaCore"),
        .executableTarget(
            name: "Metria",
            dependencies: ["MetriaCore", .product(name: "Sparkle", package: "Sparkle")],
            path: ".",
            exclude: ["Sources/MetriaCore", "AGENTS.md", "README.md", "LICENSE", "MetriaPWA", ".build", "dist", "node_modules", ".github", "scripts", "package.json", "package-lock.json", "tailwind.config.js"],
            sources: [
                "Sources/Metria/MetriaApp.swift",
                "Sources/Metria/Providers/ClaudeProvider.swift",
                "Sources/Metria/Providers/CodexProvider.swift",
                "Sources/Metria/Providers/KeychainReader.swift",
                "Sources/Metria/Providers/OpenCodeGoProvider.swift",
                "Sources/Metria/Providers/ProviderError.swift",
                "Sources/Metria/Providers/ProviderKind+Presentation.swift",
                "Sources/Metria/Providers/ProviderRegistry.swift",
                "Sources/Metria/Updater.swift"
            ],
            resources: [
                .copy("Assets/claude-logo.png"),
                .copy("Assets/codex-logo.png"),
                .copy("Assets/opencode-logo.png")
            ]
        )
    ]
)
