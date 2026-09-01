import Foundation
import Network
import MetriaCore

/// Fetches `/snapshot` from the Mac over the LAN — the freshest transport, and the one
/// that involves no third party. Resolves the Mac via Bonjour first (`_metria._tcp`,
/// advertised by `LocalPWAServer`) so a DHCP change does not require re-pairing; falls
/// back to the address pinned at pairing time.
///
/// Whether this ever succeeds *from inside the widget extension* is exactly what
/// Plan 004's Phase 0 measures on real hardware — see that plan for the two designs
/// this source is built to serve. This implementation does not special-case either
/// answer: it always attempts the fetch and simply fails fast (see `timeout`) when the
/// Local Network permission does not extend to the calling process, so the caller's
/// `SnapshotFetcher` chain falls through to the relay either way.
public struct LocalSnapshotSource: SnapshotSource {
    public let transport: SnapshotTransport = .local
    private let bonjourTimeout: TimeInterval
    private let requestTimeout: TimeInterval

    public init(bonjourTimeout: TimeInterval = 2, requestTimeout: TimeInterval = 3) {
        self.bonjourTimeout = bonjourTimeout
        self.requestTimeout = requestTimeout
    }

    public func fetch(configuration: PairingConfiguration) async -> UsageSnapshot? {
        guard let secret = Base64URL.decode(configuration.secretBase64) else { return nil }
        let token = PairingSecret.localToken(from: secret)

        for candidate in [await resolveBonjourURL(), configuration.localURL.flatMap(URL.init(string:))].compactMap({ $0 }) {
            if let snapshot = await requestSnapshot(baseURL: candidate, token: token) {
                if candidate.absoluteString != configuration.localURL {
                    PairingStore.updateLocalURL(candidate.absoluteString)
                }
                return snapshot
            }
        }
        return nil
    }

    private func requestSnapshot(baseURL: URL, token: String) async -> UsageSnapshot? {
        var request = URLRequest(url: baseURL.appendingPathComponent("snapshot"))
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "X-Metria-Secret")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        return try? UsageSnapshotCoding.makeDecoder().decode(UsageSnapshot.self, from: data)
    }

    private func resolveBonjourURL() async -> URL? {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_metria._tcp", domain: nil), using: .tcp)
            var didResume = false
            let finish: (URL?) -> Void = { url in
                guard !didResume else { return }
                didResume = true
                browser.cancel()
                continuation.resume(returning: url)
            }

            browser.browseResultsChangedHandler = { results, _ in
                guard let endpoint = results.first?.endpoint else { return }
                resolveHostPort(for: endpoint, completion: finish)
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }
            browser.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + bonjourTimeout) { finish(nil) }
        }
    }

    private func resolveHostPort(for endpoint: NWEndpoint, completion: @escaping (URL?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        var didComplete = false
        let finish: (URL?) -> Void = { url in
            guard !didComplete else { return }
            didComplete = true
            connection.cancel()
            completion(url)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else {
                    finish(nil)
                    return
                }
                finish(URL(string: "http://\(host):\(port)"))
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}
