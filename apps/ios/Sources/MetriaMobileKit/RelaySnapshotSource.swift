import CryptoKit
import Foundation
import MetriaCore

/// Fetches the newest snapshot the Mac has published to its encrypted ntfy topic — the
/// fallback transport, so the widget still has something true to show when the phone is
/// off the Mac's Wi-Fi. Mirrors `apps/pwa/public/pairing.js`'s `decryptSnapshot`: the
/// combined body is IV(12) ‖ ciphertext ‖ tag(16), exactly what CryptoKit's
/// `AES.GCM.SealedBox.combined` produces on the Mac
/// (`apps/macos-native/Sources/Metria/MetriaApp.swift`'s `NtfyPublisher`). A message that
/// fails to decrypt is either the wrong key or forged noise on a guessed topic — either
/// way, skipped rather than surfaced as an error.
public struct RelaySnapshotSource: SnapshotSource {
    public let transport: SnapshotTransport = .relay
    private let requestTimeout: TimeInterval
    private let pollWindow: String

    public init(requestTimeout: TimeInterval = 8, pollWindow: String = "10m") {
        self.requestTimeout = requestTimeout
        self.pollWindow = pollWindow
    }

    public func fetch(configuration: PairingConfiguration) async -> UsageSnapshot? {
        guard let secret = Base64URL.decode(configuration.secretBase64),
              let server = URL(string: configuration.ntfyServer), server.scheme == "https" else { return nil }

        let topic = PairingSecret.topic(from: secret)
        let key = PairingSecret.encryptionKey(from: secret)
        let pollURL = server
            .appendingPathComponent(topic)
            .appendingPathComponent("json")
            .appending(queryItems: [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: pollWindow)])

        var request = URLRequest(url: pollURL)
        request.timeoutInterval = requestTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else {
            return nil
        }

        let decoder = UsageSnapshotCoding.makeDecoder()
        var newest: UsageSnapshot?
        for line in body.split(separator: "\n") {
            guard let messageData = line.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(NtfyMessage.self, from: messageData),
                  let snapshot = decrypt(envelope.message, key: key, decoder: decoder) else { continue }
            if newest == nil || snapshot.updatedAt > newest!.updatedAt { newest = snapshot }
        }
        return newest
    }

    private func decrypt(_ base64Body: String, key: SymmetricKey, decoder: JSONDecoder) -> UsageSnapshot? {
        guard let combined = Data(base64Encoded: base64Body),
              let sealedBox = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(sealedBox, using: key) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: plaintext)
    }

    private struct NtfyMessage: Decodable {
        let message: String
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.queryItems = queryItems
        return components.url ?? self
    }
}
