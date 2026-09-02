import AppIntents
import WidgetKit
import MetriaMobileKit

/// The widget's interactive refresh button (iOS 17 `Button(intent:)`). A user-initiated
/// tap is not charged against the system's background reload budget the way a timeline
/// reload is, so this is the fastest path to a fresh number a widget can offer.
struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh usage" }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        if let configuration = PairingStore.load() {
            await SnapshotFetcher().fetchAndCache(configuration: configuration)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
