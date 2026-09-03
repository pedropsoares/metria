import CryptoKit
import Foundation
import Security

struct WebPushSubscription: Codable, Equatable {
    let endpoint: String
    let expirationTime: Double?
    let keys: Keys

    struct Keys: Codable, Equatable {
        let p256dh: String
        let auth: String
    }
}

/// A small RFC 8291 Web Push sender. The private VAPID key never leaves this Mac.
final class WebPushSender {
    private let privateKey: P256.Signing.PrivateKey
    let publicKey: String

    init() {
        if let saved = UserDefaults.standard.string(forKey: "webPushVapidPrivateKey"),
           let data = Data(base64Encoded: saved),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            privateKey = key
        } else {
            let key = P256.Signing.PrivateKey()
            privateKey = key
            UserDefaults.standard.set(key.rawRepresentation.base64EncodedString(), forKey: "webPushVapidPrivateKey")
        }
        publicKey = privateKey.publicKey.rawRepresentation.base64URLEncodedString
    }

    func send(_ payload: Data, to subscription: WebPushSubscription) async throws {
        guard let endpoint = URL(string: subscription.endpoint), let host = endpoint.host,
              let receiverData = Data(base64URL: subscription.keys.p256dh),
              let receiver = try? P256.KeyAgreement.PublicKey(rawRepresentation: receiverData),
              let auth = Data(base64URL: subscription.keys.auth) else { return }
        let sender = P256.KeyAgreement.PrivateKey()
        let shared = try sender.sharedSecretFromKeyAgreement(with: receiver)
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let authSecret = SymmetricKey(data: auth)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let prk = HMAC<SHA256>.authenticationCode(for: sharedBytes, using: authSecret)
        let info = Data("WebPush: info\0".utf8) + receiver.rawRepresentation + sender.publicKey.rawRepresentation
        let ikm = hkdfExpand(prk: Data(prk), info: info, count: 32)
        let contentPrk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        let cek = hkdfExpand(prk: Data(contentPrk), info: Data("Content-Encoding: aes128gcm\0".utf8), count: 16)
        let nonce = hkdfExpand(prk: Data(contentPrk), info: Data("Content-Encoding: nonce\0".utf8), count: 12)
        let sealed = try AES.GCM.seal(payload + Data([2]), using: SymmetricKey(data: cek), nonce: AES.GCM.Nonce(data: nonce))
        let recordSize = UInt32(4096).bigEndian
        var body = Data()
        body.append(salt)
        body.append(withUnsafeBytes(of: recordSize) { Data($0) })
        body.append(Data([65]))
        body.append(sender.publicKey.rawRepresentation)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("TTL=86400", forHTTPHeaderField: "TTL")
        request.setValue("vapid t=\(try jwt(audience: "\(endpoint.scheme ?? "https")://\(host)")), k=\(publicKey)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func jwt(audience: String) throws -> String {
        let header = Data("{\"typ\":\"JWT\",\"alg\":\"ES256\"}".utf8).base64URLEncodedString
        let claims = Data("{\"aud\":\"\(audience)\",\"exp\":\(Int(Date().timeIntervalSince1970) + 43_200),\"sub\":\"mailto:notifications@metria.app\"}".utf8).base64URLEncodedString
        let input = Data("\(header).\(claims)".utf8)
        let signature = try privateKey.signature(for: SHA256.hash(data: input))
        let der = signature.derRepresentation
        let values = der.dropFirst(2)
        guard let rStart = values.firstIndex(of: 0x02), let rLength = values[safe: rStart + 1], let sStart = values.firstIndex(of: 0x02, after: rStart + 2), let sLength = values[safe: sStart + 1] else { throw URLError(.cannotParseResponse) }
        let r = Data(values[(rStart + 2)..<(rStart + 2 + Int(rLength))]).suffix(32)
        let s = Data(values[(sStart + 2)..<(sStart + 2 + Int(sLength))]).suffix(32)
        return "\(input.base64URLEncodedString).\((r + s).base64URLEncodedString)"
    }

    private func hkdfExpand(prk: Data, info: Data, count: Int) -> Data {
        var result = Data(); var previous = Data(); var counter: UInt8 = 1
        while result.count < count {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous + info + Data([counter]), using: SymmetricKey(data: prk)))
            result.append(previous); counter += 1
        }
        return result.prefix(count)
    }
}

private extension Data {
    var base64URLEncodedString: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL value: String) { self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)) }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
    func firstIndex(of element: Element, after index: Index) -> Index? where Element: Equatable { dropFirst(distance(from: startIndex, to: index) + 1).firstIndex(of: element) }
}
