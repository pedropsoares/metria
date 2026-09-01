import Foundation
import Security

/// Persists the pairing secret in the shared Keychain access group (so the widget
/// extension can read it) and the non-secret half of the configuration — the ntfy
/// server and the last-known LAN address — in the shared App Group's UserDefaults.
public enum PairingStore {
    private static let service = "com.metria.ios.pairing"
    private static let account = "pairing-secret"
    private static let defaultsKey = "pairingConfiguration"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: MetriaAppGroup.identifier)
    }

    public static func load() -> PairingConfiguration? {
        guard let secretBase64 = loadSecret(),
              let data = sharedDefaults?.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(PairingConfiguration.self, from: data) else {
            return nil
        }
        return PairingConfiguration(secretBase64: secretBase64, ntfyServer: stored.ntfyServer, localURL: stored.localURL)
    }

    /// Fails rather than half-succeeding: both halves — the secret in the Keychain and
    /// the configuration in the shared container — must land, or the widget reads a
    /// pairing that does not exist. The App Group is checked first so a secret is never
    /// written that nothing can complete.
    @discardableResult
    public static func save(_ configuration: PairingConfiguration) -> Bool {
        guard let sharedDefaults,
              let data = try? JSONEncoder().encode(configuration),
              saveSecret(configuration.secretBase64) else { return false }
        sharedDefaults.set(data, forKey: defaultsKey)
        return true
    }

    /// Updates only the LAN address, e.g. after Bonjour re-resolves the Mac at a new IP.
    public static func updateLocalURL(_ localURL: String?) {
        guard let current = load() else { return }
        save(PairingConfiguration(secretBase64: current.secretBase64, ntfyServer: current.ntfyServer, localURL: localURL))
    }

    public static func forget() {
        deleteSecret()
        sharedDefaults?.removeObject(forKey: defaultsKey)
        SharedSnapshotCache.clear()
    }

    private static func loadSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func saveSecret(_ secretBase64: String) -> Bool {
        deleteSecret()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secretBase64.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteSecret() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
