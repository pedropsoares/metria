import Foundation

/// A pairing link's contents, decoded from the Mac's QR code fragment
/// (`<pwaBaseURL>/#s=<secret>&server=<ntfy>&local=<lan-url>`). Mirrors
/// `parsePairingParams` in `apps/pwa/public/app.js`; the PWA ignores `local`, and this
/// client ignores nothing the PWA relies on, so one QR code pairs both.
public struct PairingConfiguration: Codable, Equatable {
    public let secretBase64: String
    public let ntfyServer: String
    public let localURL: String?

    public init(secretBase64: String, ntfyServer: String, localURL: String?) {
        self.secretBase64 = secretBase64
        self.ntfyServer = ntfyServer
        self.localURL = localURL
    }

    public static func parse(link: URL) -> PairingConfiguration? {
        guard let fragment = link.fragment, !fragment.isEmpty else { return nil }
        return parse(fragment: fragment)
    }

    public static func parse(fragment: String) -> PairingConfiguration? {
        var components = URLComponents()
        components.query = fragment
        guard let items = components.queryItems,
              let secretBase64 = items.first(where: { $0.name == "s" })?.value,
              !secretBase64.isEmpty else { return nil }
        let ntfyServer = items.first(where: { $0.name == "server" })?.value ?? "https://ntfy.sh"
        let localURL = items.first(where: { $0.name == "local" })?.value
        return PairingConfiguration(secretBase64: secretBase64, ntfyServer: ntfyServer, localURL: localURL)
    }
}
