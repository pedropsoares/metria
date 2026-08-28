// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Metria",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Metria", targets: ["Metria"])],
    targets: [
        .target(name: "MetriaCore", path: "Sources/MetriaCore"),
        .executableTarget(
            name: "Metria",
            dependencies: ["MetriaCore"],
            path: ".",
            exclude: ["Sources/MetriaCore", "Tests", "AGENTS.md", "README.md"],
            sources: ["Sources/Metria/MetriaApp.swift"],
            resources: [
                .copy("Logos/claude-logo.png"),
                .copy("Logos/codex-logo.png"),
                .copy("Logos/opencode-logo.png")
            ]
        ),
        .testTarget(name: "MetriaCoreTests", dependencies: ["MetriaCore"])
    ]
)
