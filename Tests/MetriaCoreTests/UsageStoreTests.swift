import Foundation
import Testing
@testable import MetriaCore

@MainActor
struct UsageStoreTests {
    @Test func emptyResultClearsPreviousUsage() async {
        let loaded = ProviderUsage(kind: .codex, windows: [UsageWindow(title: "Session", percent: 42, resetDate: nil)], updatedAt: Date(), error: nil)
        let empty = ProviderUsage(kind: .codex, windows: [], updatedAt: nil, error: nil)
        let provider = StubProvider(kind: .codex, results: [.loaded(loaded), .empty(empty)])
        let store = UsageStore(providers: [provider], defaults: testDefaults())

        store.refresh()
        await yieldToRefresh()
        #expect(store.providers.first?.primary?.percent == 42)

        store.refresh()
        await yieldToRefresh()
        #expect(store.providers.first?.windows == [UsageWindow]())
        #expect(store.providers.first?.error == nil)
    }

    @Test func failedResultPreservesPreviousUsageAndShowsRetryMessage() async {
        let loaded = ProviderUsage(kind: .claude, windows: [UsageWindow(title: "Session", percent: 67, resetDate: nil)], updatedAt: Date(), error: nil)
        let provider = StubProvider(kind: .claude, results: [.loaded(loaded), .failed(.claude, "Network unavailable")])
        let store = UsageStore(providers: [provider], defaults: testDefaults())

        store.refresh()
        await yieldToRefresh()
        store.refresh()
        await yieldToRefresh()

        #expect(store.providers.first?.primary?.percent == 67)
        #expect(store.providers.first?.error == "Network unavailable. Retrying in a moment.")
    }

    @Test func initialFailureRemainsVisibleWithRetryMessage() async {
        let provider = StubProvider(kind: .openCodeGo, results: [.failed(.openCodeGo, "Missing credentials")])
        let store = UsageStore(providers: [provider], defaults: testDefaults())

        store.refresh()
        await yieldToRefresh()

        #expect(store.providers.count == 1)
        #expect(store.providers.first?.kind == .openCodeGo)
        #expect(store.providers.first?.error == "Missing credentials. Retrying in a moment.")
    }

    private func testDefaults() -> UserDefaults {
        let suite = "MetriaCoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func yieldToRefresh() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

private final class StubProvider: UsageProvider {
    let kind: ProviderKind
    private var results: [ProviderFetchResult]

    init(kind: ProviderKind, results: [ProviderFetchResult]) {
        self.kind = kind
        self.results = results
    }

    func fetch() async -> ProviderFetchResult {
        results.removeFirst()
    }
}
