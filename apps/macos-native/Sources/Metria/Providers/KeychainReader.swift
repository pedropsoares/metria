import Foundation
import Security

/// Reads credentials that other apps store in the macOS Keychain on the user's behalf.
enum KeychainReader {
    static var hasClaudeCredentials: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func readClaudeCredentials() async throws -> ClaudeCredentials {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w", "-g"]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProviderError.unavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = document["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String else {
            throw ProviderError.unavailable
        }
        return ClaudeCredentials(
            document: document,
            accessToken: accessToken,
            refreshToken: refreshToken,
            scopes: oauth["scopes"] as? [String]
        )
    }

    static func accountEmail(from credentials: ClaudeCredentials) -> String? {
        if let oauth = credentials.document["claudeAiOauth"] as? [String: Any],
           let email = oauth["email"] as? String,
           email.contains("@") {
            return email
        }
        return tokenEmail(credentials.accessToken)
    }

    static func tokenEmail(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64Encoded: String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - parts[1].count % 4) % 4)),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ["email", "preferred_username", "unique_name"].compactMap { claims[$0] as? String }.first { $0.contains("@") }
    }

    static func saveClaudeCredentials(
        _ credentials: ClaudeCredentials,
        accessToken: String,
        refreshToken: String,
        expiresIn: TimeInterval
    ) throws {
        guard var oauth = credentials.document["claudeAiOauth"] as? [String: Any] else {
            throw ProviderError.unavailable
        }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1_000)

        var document = credentials.document
        document["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: document)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials"
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw ProviderError.unavailable }
    }

    struct ClaudeCredentials {
        fileprivate let document: [String: Any]
        let accessToken: String
        let refreshToken: String
        let scopes: [String]?
    }
}
