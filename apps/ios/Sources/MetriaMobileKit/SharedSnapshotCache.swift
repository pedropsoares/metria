import Foundation
import MetriaCore

/// Which transport most recently answered. Drives the app's connection chip and the
/// widget's freshness copy; never invented — set only when a fetch actually succeeds.
public enum SnapshotTransport: String, Codable {
    case local
    case relay
}

public struct CachedSnapshot: Codable, Equatable {
    public let snapshot: UsageSnapshot
    public let fetchedAt: Date
    public let transport: SnapshotTransport

    public init(snapshot: UsageSnapshot, fetchedAt: Date, transport: SnapshotTransport) {
        self.snapshot = snapshot
        self.fetchedAt = fetchedAt
        self.transport = transport
    }
}

/// The one cache the app and the widget extension both read and write, in the App
/// Group container. Whichever process fetches successfully writes here; the widget's
/// `TimelineProvider` reads from here even on runs where it does not fetch itself.
public enum SharedSnapshotCache {
    private static let fileName = "snapshot.json"

    private static var fileURL: URL? {
        MetriaAppGroup.containerURL?.appendingPathComponent(fileName)
    }

    public static func load() -> CachedSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedSnapshot.self, from: data)
    }

    /// Keeps the newest reading: a relay message can be newer than a stale local read
    /// still in flight, so a fetch never blindly overwrites what is already cached.
    @discardableResult
    public static func store(_ snapshot: UsageSnapshot, transport: SnapshotTransport, fetchedAt: Date = Date()) -> CachedSnapshot {
        let candidate = CachedSnapshot(snapshot: snapshot, fetchedAt: fetchedAt, transport: transport)
        if let existing = load(), existing.snapshot.updatedAt >= snapshot.updatedAt {
            return existing
        }
        guard let fileURL, let data = try? JSONEncoder().encode(candidate) else { return candidate }
        try? data.write(to: fileURL, options: .atomic)
        return candidate
    }

    public static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
