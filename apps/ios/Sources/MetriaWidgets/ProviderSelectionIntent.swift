import AppIntents
import MetriaCore

enum ProviderSelection: String, AppEnum {
    case highest
    case claude
    case codex
    case openCodeGo
    case cursor

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Provider" }
    static var caseDisplayRepresentations: [ProviderSelection: DisplayRepresentation] = [
        .highest: "Highest usage",
        .claude: "Claude",
        .codex: "Codex",
        .openCodeGo: "OpenCode Go",
        .cursor: "Cursor"
    ]

    var providerKind: ProviderKind? {
        switch self {
        case .highest: nil
        case .claude: .claude
        case .codex: .codex
        case .openCodeGo: .openCodeGo
        case .cursor: .cursor
        }
    }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Provider" }
    static var description: IntentDescription { "Choose which provider this widget shows." }

    @Parameter(title: "Provider", default: .highest)
    var provider: ProviderSelection
}
