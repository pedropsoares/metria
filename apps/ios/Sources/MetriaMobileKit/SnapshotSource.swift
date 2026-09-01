import Foundation
import MetriaCore

public protocol SnapshotSource {
    var transport: SnapshotTransport { get }
    func fetch(configuration: PairingConfiguration) async -> UsageSnapshot?
}

/// Runs the local source first, then the relay, and returns whichever answers — keeping
/// the newest `updatedAt` is `SharedSnapshotCache.store`'s job, not this runner's, since
/// the cache is the single place that compares against what is already on disk.
public struct SnapshotFetcher {
    private let sources: [SnapshotSource]

    public init(sources: [SnapshotSource] = [LocalSnapshotSource(), RelaySnapshotSource()]) {
        self.sources = sources
    }

    /// Tries every source and stores the result from each that answers, so a slower
    /// relay reply arriving after a local timeout still updates the cache instead of
    /// being discarded once the first source responds.
    @discardableResult
    public func fetchAndCache(configuration: PairingConfiguration) async -> CachedSnapshot? {
        var latest: CachedSnapshot?
        for source in sources {
            guard let snapshot = await source.fetch(configuration: configuration) else { continue }
            latest = SharedSnapshotCache.store(snapshot, transport: source.transport)
        }
        return latest
    }
}
