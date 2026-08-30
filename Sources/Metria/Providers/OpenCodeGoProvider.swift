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
            let data = try await requestUsage(key: key)
            let usage = try JSONDecoder().decode(OpenCodeGoResponse.self, from: data).usage
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "Current session", percent: usage.rolling.percent, resetDate: usage.rolling.resetDate),
                UsageWindow(title: "This week", percent: usage.weekly.percent, resetDate: usage.weekly.resetDate),
                UsageWindow(title: "This month", percent: usage.monthly.percent, resetDate: usage.monthly.resetDate)
            ], updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            return .failed(kind, error.localizedDescription, retryAfter: providerError?.retryAfter)
        }
    }

    private func requestUsage(key: String) async throws -> Data {
        for attempt in 0..<3 {
            var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? -1
            if status == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt + 1))
                guard attempt < 2 else { throw ProviderError.rateLimited(retryAfter: retryAfter) }
                try await Task.sleep(for: .seconds(min(retryAfter, 30)))
                continue
            }
            guard status == 200 else { throw ProviderError.http(status) }
            return data
        }
        throw ProviderError.unavailable
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
