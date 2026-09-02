import Foundation
import Security

/// Persists the pairing secret in the shared Keychain access group (so the widget
/// extension can read it) and the non-secret half of the configuration — the ntfy
/// server and the last-known LAN address — in the shared App Group's UserDefaults.
public enum PairingStore {
    private static let service = "com.metria.ios.pairing"
    private static let account = "pairing-secret"
    private static let defaultsKey = "pairingConfiguration"
    private static let accessGroupDefaultsKey = "pairingKeychainAccessGroup"
    private static let accessGroupProbeAccount = "access-group-probe"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: MetriaAppGroup.identifier)
    }

    /// The Keychain access group the app and widget actually share, e.g.
    /// `ABCDE12345.com.metria.shared`. Its team-id prefix is only known once code
    /// signing resolves `$(AppIdentifierPrefix)` from the entitlements, so it cannot be
    /// spelled out as a compile-time constant. This asks the Keychain what group it put
    /// an item in when no group was requested — which, since both targets declare
    /// exactly one identical `keychain-access-groups` entry, is that shared group — and
    /// caches the answer in the App Group's UserDefaults so every later query (from
    /// either target) can pass it explicitly instead of relying on that same implicit
    /// default resolution every time, which Apple's TN2415 warns is not guaranteed.
    private static func resolvedAccessGroup() -> String? {
        if let cached = sharedDefaults?.string(forKey: accessGroupDefaultsKey), !cached.isEmpty {
            return cached
        }
        let probeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accessGroupProbeAccount,
            kSecValueData as String: Data([0]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addStatus = SecItemAdd(probeQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else { return nil }

        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accessGroupProbeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String else { return nil }
        sharedDefaults?.set(group, forKey: accessGroupDefaultsKey)
        return group
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrAccessGroup as String] = resolvedAccessGroup()
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func saveSecret(_ secretBase64: String) -> Bool {
        deleteSecret()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secretBase64.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        query[kSecAttrAccessGroup as String] = resolvedAccessGroup()
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteSecret() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        query[kSecAttrAccessGroup as String] = resolvedAccessGroup()
        SecItemDelete(query as CFDictionary)
    }
}
