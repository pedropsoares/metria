import Foundation
import Security

/// Reads credentials that other apps store in the macOS Keychain on the user's behalf.
enum KeychainReader {
    private static let claudeCredentialsLock = NSLock()
    private static var cachedClaudeCredentials: ClaudeCredentials?
    private static var attemptedClaudeCredentialsRead = false

    static var hasClaudeCredentials: Bool {
        claudeCredentialsLock.lock()
        let isReadSuccessful = cachedClaudeCredentials != nil
        let hasAttemptedRead = attemptedClaudeCredentialsRead
        claudeCredentialsLock.unlock()
        // Do not probe the Keychain while UsageStore is being initialized. The first actual
        // provider fetch performs the single protected read instead.
        return isReadSuccessful || !hasAttemptedRead
    }

    static func readClaudeCredentials() throws -> ClaudeCredentials {
        claudeCredentialsLock.lock()
        defer { claudeCredentialsLock.unlock() }
        if let cachedClaudeCredentials { return cachedClaudeCredentials }
        guard !attemptedClaudeCredentialsRead else { throw ProviderError.unavailable }
        attemptedClaudeCredentialsRead = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            throw ProviderError.unavailable
        }
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = document["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String else {
            throw ProviderError.unavailable
        }
        let credentials = ClaudeCredentials(
            document: document,
            accessToken: accessToken,
            refreshToken: refreshToken,
            scopes: oauth["scopes"] as? [String]
        )
        cachedClaudeCredentials = credentials
        return credentials
    }

    static func accountEmail(from credentials: ClaudeCredentials) -> String? {
        if let oauth = credentials.document["claudeAiOauth"] as? [String: Any],
           let email = oauth["email"] as? String,
           email.contains("@") {
            return email
        }
        return tokenEmail(credentials.accessToken)
    }

    /// Reads the plan name Claude Code caches locally next to the OAuth tokens: prefers
    /// `subscriptionType` (e.g. "max", "claude_pro_2025"), falling back to `rateLimitTier`
    /// (e.g. "default_claude_max_5x") when that's missing. Best-effort — both fields are
    /// undocumented and have been observed absent in some Claude Code versions.
    static func planLabel(from credentials: ClaudeCredentials) -> String? {
        guard let oauth = credentials.document["claudeAiOauth"] as? [String: Any] else { return nil }
        if let subscriptionType = oauth["subscriptionType"] as? String, !subscriptionType.isEmpty {
            return planDisplayName(subscriptionType)
        }
        if let rateLimitTier = oauth["rateLimitTier"] as? String, !rateLimitTier.isEmpty {
            return planDisplayName(rateLimitTier)
        }
        return nil
    }

    private static func planDisplayName(_ raw: String) -> String {
        let normalized = raw.lowercased()
        let multiplier = normalized.range(of: #"\d+x"#, options: .regularExpression).map { String(normalized[$0]) }
        if normalized.contains("max") { return ["Max", multiplier].compactMap { $0 }.joined(separator: " ") }
        if normalized.contains("enterprise") { return "Enterprise" }
        if normalized.contains("team") { return "Team" }
        if normalized.contains("pro") { return "Pro" }
        return raw.capitalized
    }

    static func tokenEmail(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64Encoded: String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - parts[1].count % 4) % 4)),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ["email", "preferred_username", "unique_name"].compactMap { claims[$0] as? String }.first { $0.contains("@") }
    }

    struct ClaudeCredentials {
        fileprivate let document: [String: Any]
        let accessToken: String
        let refreshToken: String
        let scopes: [String]?
    }
}
