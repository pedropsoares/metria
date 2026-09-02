import Foundation
import WidgetKit
import MetriaCore
import MetriaMobileKit

@MainActor final class PairingViewModel: ObservableObject {
    @Published private(set) var configuration: PairingConfiguration?
    @Published private(set) var cached: CachedSnapshot?
    @Published private(set) var isRefreshing = false

    private let fetcher = SnapshotFetcher()
    private var refreshTask: Task<Void, Never>?

    init() {
        configuration = PairingStore.load()
        cached = SharedSnapshotCache.load()
    }

    func start() async {
        guard configuration != nil else { return }
        await refresh()
    }

    /// Returns false when the pairing could not be persisted. The caller must surface
    /// that: an in-memory-only pairing looks fine in the app and leaves the widget
    /// permanently unpaired, because the widget is a separate process that can only see
    /// what actually reached the Keychain and the shared container.
    @discardableResult
    func pair(with configuration: PairingConfiguration) -> Bool {
        guard PairingStore.save(configuration) else { return false }
        self.configuration = configuration
        Task { await refresh() }
        return true
    }

    func forget() {
        refreshTask?.cancel()
        PairingStore.forget()
        configuration = nil
        cached = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    func updateNtfyServer(_ server: String) {
        guard let configuration else { return }
        let updated = PairingConfiguration(secretBase64: configuration.secretBase64, ntfyServer: server, localURL: configuration.localURL)
        PairingStore.save(updated)
        self.configuration = updated
    }

    func refresh() async {
        guard let configuration, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let result = await fetcher.fetchAndCache(configuration: configuration) {
            cached = result
        } else {
            cached = SharedSnapshotCache.load()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

#if DEBUG
extension PairingViewModel {
    /// Sample state for SwiftUI previews, so the Canvas renders the paired dashboard
    /// without a Mac on the network or a pairing stored on the device.
    static func preview(percentages: [(String, Double)] = [("Claude", 42), ("Codex", 71), ("Cursor", 93)]) -> PairingViewModel {
        let model = PairingViewModel()
        let snapshot = UsageSnapshot(
            updatedAt: Date().addingTimeInterval(-180),
            providers: percentages.map { .init(name: $0.0, percent: $0.1, resetDate: Date().addingTimeInterval(86_400 * 3)) }
        )
        model.configuration = PairingConfiguration(secretBase64: "preview", ntfyServer: "https://ntfy.sh", localURL: "http://192.168.0.10:8973")
        model.cached = CachedSnapshot(snapshot: snapshot, fetchedAt: Date().addingTimeInterval(-180), transport: .local)
        return model
    }
}
#endif
