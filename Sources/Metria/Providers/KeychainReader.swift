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

    static func readClaudeToken() async throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w", "-g"]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProviderError.unavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
        return credentials.claudeAiOauth.accessToken
    }
    private struct ClaudeCredentials: Decodable { let claudeAiOauth: OAuth; struct OAuth: Decodable { let accessToken: String } }
}
