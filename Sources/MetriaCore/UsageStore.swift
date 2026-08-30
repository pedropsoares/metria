import Combine
import Foundation

public struct UsageWindow: Equatable {
    public let title: String
    public let percent: Double
    public let resetDate: Date?

    public init(title: String, percent: Double, resetDate: Date?) {
        self.title = title
        self.percent = percent
        self.resetDate = resetDate
    }
}

public enum ProviderKind: String, CaseIterable, Identifiable, Hashable {
    case claude = "Claude"
    case codex = "Codex"
    case openCodeGo = "OpenCode Go"

    public var id: String { rawValue }
}

public struct ProviderUsage: Identifiable, Equatable {
    public let kind: ProviderKind
    public var windows: [UsageWindow]
    public var updatedAt: Date?
    public var error: String?

    public var id: ProviderKind { kind }
    public var primary: UsageWindow? { windows.first }

    public init(kind: ProviderKind, windows: [UsageWindow], updatedAt: Date?, error: String?) {
        self.kind = kind
        self.windows = windows
        self.updatedAt = updatedAt
        self.error = error
    }
}

public enum ProviderFetchResult: Equatable {
    case loaded(ProviderUsage)
    case empty(ProviderUsage)
    case failed(ProviderKind, String)
}

public protocol UsageProvider {
    var kind: ProviderKind { get }
    var isAvailable: Bool { get }
    var setupHint: String { get }
    func fetch() async -> ProviderFetchResult
}

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var providers: [ProviderUsage] = []
    @Published public var refreshInterval = 300.0
    @Published public private(set) var enabledProviderKinds: Set<ProviderKind>

    private let sources: [any UsageProvider]
    private let defaults: UserDefaults
    private var refreshOperation: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var retryTasks: [ProviderKind: Task<Void, Never>] = [:]
    private var isRefreshing = false
    private let enabledProvidersKey = "enabledProviderKinds"

    public init(providers: [any UsageProvider], defaults: UserDefaults = .standard) {
        self.sources = providers
        self.defaults = defaults
        let savedKinds = (defaults.array(forKey: enabledProvidersKey) as? [String] ?? [])
            .compactMap(ProviderKind.init(rawValue:))
        let availableKinds = Set(providers.filter(\.isAvailable).map(\.kind))
        enabledProviderKinds = savedKinds.isEmpty ? availableKinds : Set(savedKinds)
    }

    public func isProviderAvailable(_ kind: ProviderKind) -> Bool {
        sources.first(where: { $0.kind == kind })?.isAvailable ?? false
    }

    public func setupHint(for kind: ProviderKind) -> String? {
        sources.first(where: { $0.kind == kind })?.setupHint
    }

    public func setProviderEnabled(_ kind: ProviderKind, isEnabled: Bool) {
        var updatedKinds = enabledProviderKinds
        if isEnabled {
            updatedKinds.insert(kind)
        } else if updatedKinds.count > 1 {
            updatedKinds.remove(kind)
        }
        enabledProviderKinds = updatedKinds
        defaults.set(updatedKinds.map(\.rawValue), forKey: enabledProvidersKey)
        refresh()
    }

    public func start() {
        refresh()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.refreshInterval))
                guard !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    public func refresh() {
        let providers = sources.filter { enabledProviderKinds.contains($0.kind) && $0.isAvailable }
        refresh(providers: providers)
    }

    private func refresh(providers: [any UsageProvider]) {
        guard !providers.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        refreshOperation = Task { [weak self] in
            let results = await withTaskGroup(of: ProviderFetchResult.self, returning: [ProviderFetchResult].self) { group in
                for provider in providers {
                    group.addTask { await provider.fetch() }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }

            guard let self else { return }
            for result in results {
                self.apply(result)
            }
            self.isRefreshing = false
            self.refreshOperation = nil
        }
    }

    private func apply(_ result: ProviderFetchResult) {
        let kind: ProviderKind
        switch result {
        case .loaded(let usage), .empty(let usage): kind = usage.kind
        case .failed(let failedKind, _): kind = failedKind
        }
        guard enabledProviderKinds.contains(kind) else {
            retryTasks[kind]?.cancel()
            retryTasks[kind] = nil
            return
        }

        switch result {
        case .loaded(let usage), .empty(let usage):
            replace(usage)
            retryTasks[usage.kind]?.cancel()
            retryTasks[usage.kind] = nil
        case .failed(let kind, let message):
            if let index = providers.firstIndex(where: { $0.kind == kind }) {
                providers[index].error = "\(message). Retrying in a moment."
            } else {
                providers.append(ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: "\(message). Retrying in a moment."))
            }
            scheduleRetry(for: kind)
        }
        providers.sort { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func replace(_ usage: ProviderUsage) {
        if let index = providers.firstIndex(where: { $0.kind == usage.kind }) {
            providers[index] = usage
        } else {
            providers.append(usage)
        }
    }

    private func scheduleRetry(for kind: ProviderKind) {
        guard retryTasks[kind] == nil, let provider = sources.first(where: { $0.kind == kind }) else { return }
        retryTasks[kind] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[kind] = nil
            guard self.enabledProviderKinds.contains(kind) else { return }
            self.refresh(providers: [provider])
        }
    }

    deinit {
        refreshOperation?.cancel()
        scheduleTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
    }
}
