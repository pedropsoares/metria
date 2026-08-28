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
            exclude: ["Sources/MetriaCore", "AGENTS.md", "README.md", "LICENSE"],
            sources: ["Sources/Metria/MetriaApp.swift"],
            resources: [
                .copy("Assets/claude-logo.png"),
                .copy("Assets/codex-logo.png"),
                .copy("Assets/opencode-logo.png")
            ]
        )
    ]
)
