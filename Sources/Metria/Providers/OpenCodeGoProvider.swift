import Foundation
import MetriaCore

/// Fetches OpenCode Go usage using the API key OpenCode stores in its local auth file.
struct OpenCodeGoProvider: UsageProvider {
    let kind = ProviderKind.openCodeGo
    var isAvailable: Bool { FileManager.default.fileExists(atPath: authURL.path) }
    let setupHint = "Sign in to OpenCode Go to create a local API credential."

    private var authURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/auth.json") }

    func fetch() async -> ProviderFetchResult {
        do {
            let key = try readAPIKey()
            var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw ProviderError.unavailable }
            let usage = try JSONDecoder().decode(OpenCodeGoResponse.self, from: data).usage
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "Current session", percent: usage.rolling.percent, resetDate: usage.rolling.resetDate),
                UsageWindow(title: "This week", percent: usage.weekly.percent, resetDate: usage.weekly.resetDate),
                UsageWindow(title: "This month", percent: usage.monthly.percent, resetDate: usage.monthly.resetDate)
            ], updatedAt: Date(), error: nil))
        } catch {
            return .failed(kind, error.localizedDescription)
        }
    }

    private func readAPIKey() throws -> String {
        let data = try Data(contentsOf: authURL)
        return try JSONDecoder().decode(OpenCodeAuth.self, from: data).openCodeGo.key
    }

    private struct OpenCodeAuth: Decodable {
        let openCodeGo: Credentials

        enum CodingKeys: String, CodingKey { case openCodeGo = "opencode-go" }
    }

    private struct Credentials: Decodable { let key: String }

    private struct OpenCodeGoResponse: Decodable {
        let usage: Usage

        struct Usage: Decodable {
            let rolling: Limit
            let weekly: Limit
            let monthly: Limit
        }

        struct Limit: Decodable {
            let percent: Double
            let resetsAt: String

            var resetDate: Date? {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: resetsAt)
            }
        }
    }
}
