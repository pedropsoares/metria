import AppKit
import SwiftUI
import MetriaCore

/// UI metadata for each `ProviderKind`: the SF Symbol fallback, the bundled logo asset,
/// and the sidebar gauge's gradient. Add a case here alongside every new provider file.
extension ProviderKind {
    var symbol: String {
        switch self { case .claude: "sparkles"; case .codex: "hexagon"; case .openCodeGo: "globe.americas.fill" }
    }

    var logoName: String? {
        switch self { case .claude: "claude-logo"; case .codex: "codex-logo"; case .openCodeGo: "opencode-logo" }
    }

    var logo: NSImage? {
        guard let logoName, let url = Bundle.module.url(forResource: logoName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var sidebarProgressGradient: LinearGradient {
        switch self {
        case .claude:
            LinearGradient(colors: [.orange, .orange], startPoint: .leading, endPoint: .trailing)
        case .codex:
            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .openCodeGo:
            LinearGradient(colors: [.white, .white], startPoint: .leading, endPoint: .trailing)
        }
    }
}
