import Foundation
import Security

/// Reads credentials that other apps store in the macOS Keychain on the user's behalf.
///
/// Claude Code creates its OAuth credential as a Keychain generic password owned by Claude
/// Code, not by Metria. macOS therefore shows an authorization prompt the first time Metria
/// reads it — and because Metria's release builds are unsigned (`CODE_SIGNING_ALLOWED: NO`),
/// macOS treats every rebuild as a different app and re-prompts each time. To avoid that, the
/// first authorized read is cached to a file Metria owns; later launches read that file and
/// never touch the Keychain again, exactly like the Antigravity/Codex providers do.
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

        // The disk cache (written after the very first authorized Keychain read) is the normal
        // path — it never prompts. Only fall through to the Keychain when there is no cache.
        if let cachedDocument = ClaudeCredentialCache.load(),
           let credentials = makeCredentials(from: cachedDocument) {
            cachedClaudeCredentials = credentials
            return credentials
        }

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
              let credentials = makeCredentials(from: document) else {
            throw ProviderError.unavailable
        }
        cachedClaudeCredentials = credentials
        ClaudeCredentialCache.save(document)
        return credentials
    }

    private static func makeCredentials(from document: [String: Any]) -> ClaudeCredentials? {
        guard let oauth = document["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String else { return nil }
        return ClaudeCredentials(
            document: document,
            accessToken: accessToken,
            refreshToken: refreshToken,
            scopes: oauth["scopes"] as? [String]
        )
    }

    /// The single on-disk copy of Claude Code's credential, kept restricted to the current user.
    /// Deliberately JSON so the same loading logic used for the Keychain document can read it.
    private enum ClaudeCredentialCache {
        private static var fileURL: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Metria", isDirectory: true)
                .appendingPathComponent("claude-credentials.json")
        }

        static func load() -> [String: Any]? {
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }

        static func save(_ document: [String: Any]) {
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                // Best-effort. If the write fails the provider still works; it just re-reads the
                // Keychain (and re-prompts) next launch.
                FileHandle.standardError.write("[KeychainReader] cache save failed: \(error)\n".data(using: .utf8)!)
            }
        }
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
        // Team plan seats come in two tiers ("Standard" and "Premium"); check the more
        // specific "premium" match first so it isn't swallowed by the generic "team" check.
        if normalized.contains("team") {
            if normalized.contains("premium") { return "Team Premium" }
            if normalized.contains("standard") { return "Team Standard" }
            return "Team"
        }
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
